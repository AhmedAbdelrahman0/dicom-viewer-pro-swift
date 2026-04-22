import Foundation

/// Client for **MONAI Deploy Informatics Gateway** (`monai-deploy-informatics-gateway`).
///
/// The Informatics Gateway is the DICOM/DICOMweb ingress tier for MONAI's
/// deploy stack. It exposes a REST API for AE-title configuration, C-ECHO
/// tests, STOW-RS upload, ACR-DSI inference job submission, and service
/// health. This Swift client covers the subset a radiologist/workstation
/// user would drive from the viewer. License: Apache-2.0.
///
/// Reference: `docs/api/rest/` in the informatics-gateway repo.
public final class MONAIDeployClient: @unchecked Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var baseURL: URL
        public var authToken: String?
        public var timeoutSeconds: TimeInterval = 60

        public init(baseURL: URL, authToken: String? = nil,
                    timeoutSeconds: TimeInterval = 60) {
            self.baseURL = baseURL
            self.authToken = authToken
            self.timeoutSeconds = timeoutSeconds
        }

        /// Default IG dev deployment (`http://localhost:5000`).
        public static let localhost = Configuration(
            baseURL: URL(string: "http://localhost:5000")!
        )
    }

    public enum ClientError: Error, LocalizedError {
        case invalidResponse
        case httpError(status: Int, body: String)
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Informatics Gateway returned no response."
            case .httpError(let status, let body):
                let snippet = body.count > 200 ? String(body.prefix(200)) + "…" : body
                return "IG HTTP \(status): \(snippet)"
            case .decodingFailed(let m): return "IG decode failed: \(m)"
            }
        }
    }

    public private(set) var configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration = .localhost,
                session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = configuration.timeoutSeconds
            cfg.timeoutIntervalForResource = configuration.timeoutSeconds
            self.session = URLSession(configuration: cfg)
        }
    }

    public func update(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - /health

    /// Aggregate service-health snapshot: DIMSE active connections +
    /// subservice status. Useful as a tiny dashboard widget.
    public func healthStatus() async throws -> HealthStatus {
        let request = makeRequest(path: "/health/status", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decode(HealthStatus.self, from: data)
    }

    // MARK: - /config/ae

    public func listAETitles() async throws -> [AETitleConfig] {
        try await listConfig(path: "/config/ae", as: [AETitleConfig].self)
    }

    public func listDestinations() async throws -> [AEEndpointConfig] {
        try await listConfig(path: "/config/destination", as: [AEEndpointConfig].self)
    }

    public func listSources() async throws -> [AEEndpointConfig] {
        try await listConfig(path: "/config/source", as: [AEEndpointConfig].self)
    }

    /// Issue a DICOM C-ECHO to a configured destination to verify
    /// connectivity. Returns the raw response body.
    public func cecho(destinationName name: String) async throws -> String {
        let path = "/config/destination/cecho/\(name.urlPathPercentEncoded)"
        let request = makeRequest(path: path, method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - /dicomweb/studies — STOW-RS

    /// Push a DICOM instance (already in Part 10 form) into the gateway
    /// via STOW-RS. `workflowID` is optional; when set, the gateway routes
    /// the study into that workflow.
    public func stowPushInstance(data: Data,
                                 studyInstanceUID: String? = nil,
                                 workflowID: String? = nil) async throws {
        var path = "/dicomweb"
        if let workflowID { path += "/\(workflowID.urlPathPercentEncoded)" }
        path += "/studies"
        if let studyInstanceUID, !studyInstanceUID.isEmpty {
            path += "/\(studyInstanceUID.urlPathPercentEncoded)"
        }

        let boundary = "IG-\(UUID().uuidString)"
        var request = makeRequest(path: path, method: "POST")
        request.setValue(
            "multipart/related; type=\"application/dicom\"; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/dicom+json", forHTTPHeaderField: "Accept")

        var body = Data()
        let lb = "\r\n"
        body.append("--\(boundary)\(lb)")
        body.append("Content-Type: application/dicom\(lb)\(lb)")
        body.append(data)
        body.append(lb)
        body.append("--\(boundary)--\(lb)")
        request.httpBody = body

        let (respData, response) = try await session.data(for: request)
        try validate(response, data: respData)
    }

    // MARK: - /inference (ACR-DSI)

    /// Submit an inference job in the ACR Data Science Institute (ACR-DSI)
    /// request shape. Returns the server-assigned `transactionID`.
    @discardableResult
    public func submitInference(request inference: InferenceRequest) async throws -> InferenceSubmission {
        var request = makeRequest(path: "/inference", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(inference)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decode(InferenceSubmission.self, from: data)
    }

    public func inferenceStatus(transactionID: String) async throws -> InferenceStatus {
        let path = "/inference/status/\(transactionID.urlPathPercentEncoded)"
        let request = makeRequest(path: path, method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decode(InferenceStatus.self, from: data)
    }

    // MARK: - Helpers

    private func listConfig<T: Decodable>(path: String, as type: T.Type) async throws -> T {
        let request = makeRequest(path: path, method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decode(T.self, from: data)
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(
            url: configuration.baseURL.appendingPathComponent(path),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.timeoutSeconds
        )
        request.httpMethod = method
        if let token = configuration.authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("Tracer/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ClientError.decodingFailed(String(describing: error)) }
    }
}

// MARK: - Codable models

public struct HealthStatus: Codable, Sendable {
    public let services: [String: String]?
    public let activeDimseConnections: Int?

    enum CodingKeys: String, CodingKey {
        case services
        case activeDimseConnections = "activeDimseConnections"
    }
}

public struct AETitleConfig: Codable, Identifiable, Sendable {
    public let name: String
    public let aeTitle: String?
    public let allowedSopClasses: [String]?

    public var id: String { name }
}

public struct AEEndpointConfig: Codable, Identifiable, Sendable {
    public let name: String
    public let aeTitle: String?
    public let hostIp: String?
    public let port: Int?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, aeTitle, hostIp = "hostIp", port
    }
}

/// ACR-DSI inference request body — see `docs/api/rest/inference.md`.
public struct InferenceRequest: Codable, Sendable {
    public struct InputResource: Codable, Sendable {
        public var `interface`: String
        public var connectionDetails: ConnectionDetails

        public struct ConnectionDetails: Codable, Sendable {
            public var operations: [String]?
            public var uri: String?
            public var authID: String?
            public var authType: String?
        }
    }

    public struct OutputResource: Codable, Sendable {
        public var `interface`: String
        public var connectionDetails: InputResource.ConnectionDetails
    }

    public var transactionID: String
    public var priority: Int
    public var inputMetadata: InputMetadata
    public var inputResources: [InputResource]
    public var outputResources: [OutputResource]

    public struct InputMetadata: Codable, Sendable {
        public struct Details: Codable, Sendable {
            public var type: String
            public var studyInstanceUID: String?
            public var seriesInstanceUID: String?
            public var sopInstanceUID: String?
        }
        public var details: Details
    }

    public init(transactionID: String = UUID().uuidString,
                priority: Int = 128,
                inputMetadata: InputMetadata,
                inputResources: [InputResource],
                outputResources: [OutputResource]) {
        self.transactionID = transactionID
        self.priority = priority
        self.inputMetadata = inputMetadata
        self.inputResources = inputResources
        self.outputResources = outputResources
    }
}

public struct InferenceSubmission: Codable, Sendable {
    public let transactionID: String
    public let status: String?
}

public struct InferenceStatus: Codable, Sendable {
    public let transactionID: String
    public let status: String?
    public let message: String?
}

private extension Data {
    mutating func append(_ text: String) {
        if let d = text.data(using: .utf8) { append(d) }
    }
}

private extension String {
    var urlPathPercentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
