import Foundation

/// A REST client for the **MONAI Label** server (Apache-2.0, Project MONAI).
///
/// MONAI Label is a human-in-the-loop labeling framework. A researcher runs
/// a MONAI Label server locally or on a workstation; it hosts pre-trained
/// segmentation models (DeepEdit, DeepGrow, Segmentation, etc.) plus
/// active-learning strategies and a datastore. This client lets the Swift
/// viewer:
///
///   • enumerate available models and active-learning strategies
///   • upload the currently-open `ImageVolume` and run inference
///   • fetch the returned segmentation mask back into a `LabelMap`
///   • submit a finalized label into the datastore for continued training
///   • trigger a training job and poll its logs
///
/// The client is deliberately transport-only — higher layers (view models,
/// UI) own the translation between MONAI Label's NIfTI results and our
/// in-memory `ImageVolume` / `LabelMap` types.
///
/// ### API surface covered
/// Based on MONAI Label's public REST routes (stable since 0.5):
///
/// ```
/// GET   /info/
/// GET   /infer/                   (list registered models)
/// POST  /infer/{model}            (upload + run)
/// GET   /activelearning/{strategy}
/// GET   /datastore/               (list items)
/// PUT   /datastore/label/{image}  (submit finalized label)
/// POST  /scribbles/{model}
/// POST  /train/{task}
/// GET   /logs/{task}
/// ```
///
/// References:
///  - docs.monai.io/projects/label — REST API reference
///  - github.com/Project-MONAI/MONAILabel — license: Apache-2.0
public final class MONAILabelClient: @unchecked Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var baseURL: URL
        /// Bearer token for servers deployed behind an auth proxy. Nil for the
        /// default local developer deployment.
        public var authToken: String?
        /// Request timeout in seconds. Model inference can take minutes on
        /// large volumes; default is generous.
        public var timeoutSeconds: TimeInterval = 600

        public init(baseURL: URL, authToken: String? = nil,
                    timeoutSeconds: TimeInterval = 600) {
            self.baseURL = baseURL
            self.authToken = authToken
            self.timeoutSeconds = timeoutSeconds
        }

        /// Default MONAI Label local dev server URL (`http://127.0.0.1:8000`).
        public static let localhost = Configuration(
            baseURL: URL(string: "http://127.0.0.1:8000")!
        )
    }

    // MARK: - Errors

    public enum ClientError: Error, LocalizedError {
        case invalidResponse
        case httpError(status: Int, body: String)
        case decodingFailed(String)
        case noCurrentVolume
        case modelRequired

        public var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "MONAI Label server returned no response."
            case .httpError(let status, let body):
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
                return "MONAI Label HTTP \(status): \(snippet.isEmpty ? "<empty>" : snippet)"
            case .decodingFailed(let m):
                return "Could not decode MONAI Label response: \(m)"
            case .noCurrentVolume:
                return "No volume is currently loaded; cannot run inference."
            case .modelRequired:
                return "A model name is required."
            }
        }
    }

    // MARK: - State

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

    // MARK: - /info/

    /// Returns the server's `info` payload — registered models, labels,
    /// datastore summary, and active-learning strategies.
    public func fetchInfo() async throws -> ServerInfo {
        let request = makeRequest(path: "/info/", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        do {
            return try JSONDecoder().decode(ServerInfo.self, from: data)
        } catch {
            throw ClientError.decodingFailed(String(describing: error))
        }
    }

    // MARK: - /infer/{model}

    /// Run inference using `model` on the given image file (NIfTI-1). The
    /// server responds with a multipart form containing a NIfTI label file
    /// (`image`) and a params JSON (`params`). This method writes the
    /// returned label to `outputLabelURL` and returns the decoded params.
    @discardableResult
    public func runInference(model: String,
                             imageURL: URL,
                             outputLabelURL: URL,
                             params: [String: Any] = [:]) async throws -> InferenceParams {
        guard !model.isEmpty else { throw ClientError.modelRequired }

        let boundary = "DVPro-\(UUID().uuidString)"
        var request = makeRequest(
            path: "/infer/\(model.urlPathPercentEncoded)",
            method: "POST"
        )
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = try buildMultipartBody(
            boundary: boundary,
            fileField: "file",
            fileURL: imageURL,
            extraFields: [
                "params": String(
                    data: try JSONSerialization.data(withJSONObject: params),
                    encoding: .utf8
                ) ?? "{}"
            ]
        )

        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)

        // MONAI Label's /infer/ response is multipart with parts named
        // `image` (the label as NIfTI) and `params` (JSON).
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("multipart/") {
            let parts = try MultipartParser.parse(data: data, contentType: contentType)
            guard let imagePart = parts.first(where: { $0.name == "image" }) else {
                throw ClientError.decodingFailed("no 'image' part in multipart response")
            }
            try imagePart.body.write(to: outputLabelURL)

            if let paramsPart = parts.first(where: { $0.name == "params" }),
               let obj = try? JSONSerialization.jsonObject(with: paramsPart.body) {
                return InferenceParams(raw: (obj as? [String: Any]) ?? [:])
            }
            return InferenceParams(raw: [:])
        }

        // Single-file responses (some models return just the NIfTI).
        try data.write(to: outputLabelURL)
        return InferenceParams(raw: [:])
    }

    // MARK: - /infer/{model} with user label (scribbles / DeepEdit)

    /// Interactive inference variant: uploads both the image and an existing
    /// label (e.g. user scribbles, a partial segmentation, or DeepEdit click
    /// points encoded as a binary mask) in the same multipart request.
    ///
    /// This is the canonical MONAI Label flow for scribbles and DeepEdit —
    /// there is **no** dedicated `/scribbles/` route; the server recognizes
    /// the label part on the standard `/infer/{model}` endpoint.
    @discardableResult
    public func runInterativeInference(model: String,
                                       imageURL: URL,
                                       labelURL: URL,
                                       outputLabelURL: URL,
                                       params: [String: Any] = [:]) async throws -> InferenceParams {
        guard !model.isEmpty else { throw ClientError.modelRequired }

        let boundary = "DVPro-\(UUID().uuidString)"
        var request = makeRequest(
            path: "/infer/\(model.urlPathPercentEncoded)",
            method: "POST"
        )
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = try buildMultipartBody(
            boundary: boundary,
            files: [
                ("file",  imageURL),
                ("label", labelURL)
            ],
            extraFields: [
                "params": String(
                    data: try JSONSerialization.data(withJSONObject: params),
                    encoding: .utf8
                ) ?? "{}"
            ]
        )

        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("multipart/") {
            let parts = try MultipartParser.parse(data: data, contentType: contentType)
            guard let imagePart = parts.first(where: { $0.name == "image" }) else {
                throw ClientError.decodingFailed("no 'image' part in interactive response")
            }
            try imagePart.body.write(to: outputLabelURL)
            if let paramsPart = parts.first(where: { $0.name == "params" }),
               let obj = try? JSONSerialization.jsonObject(with: paramsPart.body) {
                return InferenceParams(raw: (obj as? [String: Any]) ?? [:])
            }
            return InferenceParams(raw: [:])
        }
        try data.write(to: outputLabelURL)
        return InferenceParams(raw: [:])
    }

    // MARK: - /activelearning/{strategy}

    /// Request the next sample for labeling from an active-learning strategy.
    /// The returned payload includes the image id the server recommends.
    public func nextSample(strategy: String) async throws -> ActiveLearningSample {
        let request = makeRequest(
            path: "/activelearning/\(strategy.urlPathPercentEncoded)",
            method: "GET"
        )
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decode(ActiveLearningSample.self, from: data)
    }

    // MARK: - /datastore/

    /// List all image ids and summary metadata in the server's datastore.
    public func listDatastore() async throws -> DatastoreSummary {
        let request = makeRequest(path: "/datastore/", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decode(DatastoreSummary.self, from: data)
    }

    /// Upload a finalized label NIfTI for `imageID` into the datastore so
    /// the server can include it in the next training round.
    public func submitLabel(imageID: String,
                            labelURL: URL,
                            tag: String = "final",
                            params: [String: Any] = [:]) async throws {
        let boundary = "DVPro-\(UUID().uuidString)"
        var request = makeRequest(
            path: "/datastore/label/\(imageID.urlPathPercentEncoded)?tag=\(tag.urlPathPercentEncoded)",
            method: "PUT"
        )
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = try buildMultipartBody(
            boundary: boundary,
            fileField: "label",
            fileURL: labelURL,
            extraFields: [
                "params": String(
                    data: try JSONSerialization.data(withJSONObject: params),
                    encoding: .utf8
                ) ?? "{}"
            ]
        )
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    // MARK: - /train/{task}

    /// Kick off a training task. Returns the server's response payload
    /// (task id, status, etc.).
    public func startTraining(task: String,
                              params: [String: Any] = [:]) async throws -> [String: Any] {
        var request = makeRequest(
            path: "/train/\(task.urlPathPercentEncoded)",
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? [:]
    }

    /// Fetch recent log output for a training task.
    public func logs(task: String, lines: Int = 200) async throws -> String {
        let request = makeRequest(
            path: "/logs/\(task.urlPathPercentEncoded)?lines=\(lines)",
            method: "GET"
        )
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Private helpers

    private func makeRequest(path: String, method: String) -> URLRequest {
        let url = configuration.baseURL.appendingPathComponent(path)
        var request = URLRequest(
            url: url,
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
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.httpError(status: http.statusCode, body: body)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ClientError.decodingFailed(String(describing: error))
        }
    }

    private func buildMultipartBody(boundary: String,
                                    fileField: String,
                                    fileURL: URL,
                                    extraFields: [String: String]) throws -> Data {
        try buildMultipartBody(
            boundary: boundary,
            files: [(fileField, fileURL)],
            extraFields: extraFields
        )
    }

    private func buildMultipartBody(boundary: String,
                                    files: [(field: String, url: URL)],
                                    extraFields: [String: String]) throws -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        for (key, value) in extraFields {
            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"\(key)\"\(lineBreak)\(lineBreak)")
            body.append("\(value)\(lineBreak)")
        }

        for (field, url) in files {
            let fileData = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\(lineBreak)")
            body.append("Content-Type: application/octet-stream\(lineBreak)\(lineBreak)")
            body.append(fileData)
            body.append(lineBreak)
        }

        body.append("--\(boundary)--\(lineBreak)")
        return body
    }
}

// MARK: - Response models

public struct MONAILabelModelInfo: Codable, Identifiable, Sendable {
    public let type: String?
    public let labels: [String: Int]?
    public let dimension: Int?
    public let description: String?
    public let config: [String: AnyCodable]?

    public var id: String { description ?? "unnamed" }
}

public struct MONAILabelStrategy: Codable, Identifiable, Sendable {
    public let description: String?
    public var id: String { description ?? UUID().uuidString }
}

public struct ServerInfo: Codable, Sendable {
    public let name: String?
    public let description: String?
    public let version: String?
    public let labels: [String: AnyCodable]?
    public let models: [String: MONAILabelModelInfo]?
    public let strategies: [String: MONAILabelStrategy]?
    public let datastore: DatastoreSummary?

    public var modelNames: [String] {
        Array(models?.keys ?? [:].keys).sorted()
    }

    public var strategyNames: [String] {
        Array(strategies?.keys ?? [:].keys).sorted()
    }
}

public struct DatastoreSummary: Codable, Sendable {
    public let name: String?
    public let description: String?
    public let total: Int?
    public let completed: Int?
    public let objects: [String: AnyCodable]?
}

public struct ActiveLearningSample: Codable, Sendable {
    public let id: String?
    public let path: String?
    public let weight: Double?
}

public struct InferenceParams: Sendable {
    public let raw: [String: AnyCodable]

    init(raw: [String: Any]) {
        var converted: [String: AnyCodable] = [:]
        for (k, v) in raw {
            converted[k] = AnyCodable(v)
        }
        self.raw = converted
    }

    public var labels: [String: Int]? {
        guard case .dictionary(let d)? = raw["label_names"]?.value else { return nil }
        var out: [String: Int] = [:]
        for (k, v) in d {
            if case .integer(let i) = v.value {
                out[k] = i
            }
        }
        return out.isEmpty ? nil : out
    }
}

/// A lightweight `Any`-equivalent `Codable` used for the untyped parts of
/// MONAI Label's JSON payloads.
public struct AnyCodable: Codable, Sendable {
    public enum Value: Sendable {
        case null
        case bool(Bool)
        case integer(Int)
        case number(Double)
        case string(String)
        case array([AnyCodable])
        case dictionary([String: AnyCodable])
    }
    public let value: Value

    public init(_ any: Any?) {
        if any == nil {
            self.value = .null
        } else if let b = any as? Bool {
            self.value = .bool(b)
        } else if let i = any as? Int {
            self.value = .integer(i)
        } else if let d = any as? Double {
            self.value = .number(d)
        } else if let s = any as? String {
            self.value = .string(s)
        } else if let arr = any as? [Any] {
            self.value = .array(arr.map { AnyCodable($0) })
        } else if let dict = any as? [String: Any] {
            var out: [String: AnyCodable] = [:]
            for (k, v) in dict { out[k] = AnyCodable(v) }
            self.value = .dictionary(out)
        } else {
            self.value = .null
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = .null
        } else if let b = try? c.decode(Bool.self) {
            self.value = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self.value = .integer(i)
        } else if let d = try? c.decode(Double.self) {
            self.value = .number(d)
        } else if let s = try? c.decode(String.self) {
            self.value = .string(s)
        } else if let arr = try? c.decode([AnyCodable].self) {
            self.value = .array(arr)
        } else if let dict = try? c.decode([String: AnyCodable].self) {
            self.value = .dictionary(dict)
        } else {
            self.value = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case .null:                try c.encodeNil()
        case .bool(let b):         try c.encode(b)
        case .integer(let i):      try c.encode(i)
        case .number(let d):       try c.encode(d)
        case .string(let s):       try c.encode(s)
        case .array(let a):        try c.encode(a)
        case .dictionary(let d):   try c.encode(d)
        }
    }
}

// MARK: - Helpers

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

// MARK: - Minimal multipart parser

/// A purpose-built multipart/form-data response parser for MONAI Label's
/// `/infer/` response. Handles the subset MONAI emits: two parts named
/// `image` (binary NIfTI) and `params` (JSON).
enum MultipartParser {
    struct Part {
        let name: String
        let filename: String?
        let contentType: String?
        let body: Data
    }

    enum ParseError: Error, LocalizedError {
        case missingBoundary
        case truncated

        var errorDescription: String? {
            switch self {
            case .missingBoundary: return "Content-Type lacked a multipart boundary"
            case .truncated:       return "multipart body was truncated"
            }
        }
    }

    static func parse(data: Data, contentType: String) throws -> [Part] {
        guard let boundary = extractBoundary(from: contentType) else {
            throw ParseError.missingBoundary
        }
        let boundaryData = Data("--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8)

        // Split on --boundary.
        var parts: [Part] = []
        var cursor = 0
        while cursor < data.count {
            guard let openRange = data.range(of: boundaryData, in: cursor..<data.count) else {
                break
            }
            cursor = openRange.upperBound
            // Skip trailing "--" on close boundary.
            if cursor + 2 <= data.count,
               data[cursor] == 0x2D, data[cursor + 1] == 0x2D {
                break
            }
            // Skip CRLF after boundary line.
            if cursor + 2 <= data.count, data[cursor..<cursor+2] == crlf {
                cursor += 2
            }

            // Find the end of headers.
            let headerTerminator = Data("\r\n\r\n".utf8)
            guard let headerEnd = data.range(of: headerTerminator, in: cursor..<data.count) else {
                throw ParseError.truncated
            }
            let headerData = data.subdata(in: cursor..<headerEnd.lowerBound)
            cursor = headerEnd.upperBound

            // Find the next boundary to bound the body.
            guard let nextBoundary = data.range(of: boundaryData, in: cursor..<data.count) else {
                throw ParseError.truncated
            }
            // Body excludes the CRLF immediately before the next boundary.
            var bodyEnd = nextBoundary.lowerBound
            if bodyEnd >= 2,
               data.subdata(in: (bodyEnd - 2)..<bodyEnd) == crlf {
                bodyEnd -= 2
            }
            let body = data.subdata(in: cursor..<bodyEnd)

            let headers = String(data: headerData, encoding: .utf8) ?? ""
            let (name, filename) = parseDisposition(headers)
            let contentType = parseHeader(named: "Content-Type", in: headers)
            if let name {
                parts.append(Part(name: name,
                                  filename: filename,
                                  contentType: contentType,
                                  body: body))
            }
            cursor = nextBoundary.lowerBound
        }
        return parts
    }

    private static func extractBoundary(from contentType: String) -> String? {
        let items = contentType.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for item in items where item.lowercased().hasPrefix("boundary=") {
            var raw = String(item.dropFirst("boundary=".count))
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast())
            }
            return raw
        }
        return nil
    }

    private static func parseHeader(named name: String, in headers: String) -> String? {
        let lower = name.lowercased() + ":"
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix(lower) {
                return String(line.dropFirst(lower.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func parseDisposition(_ headers: String) -> (name: String?, filename: String?) {
        guard let line = parseHeader(named: "Content-Disposition", in: headers) else {
            return (nil, nil)
        }
        var name: String?
        var filename: String?
        let parts = line.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for p in parts {
            if p.hasPrefix("name=") {
                name = stripQuotes(String(p.dropFirst("name=".count)))
            } else if p.hasPrefix("filename=") {
                filename = stripQuotes(String(p.dropFirst("filename=".count)))
            }
        }
        return (name, filename)
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        return String(s.dropFirst().dropLast())
    }
}
