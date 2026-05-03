import Foundation

public final class DICOMwebClient: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var connection: VNAConnection

        public init(connection: VNAConnection) {
            self.connection = connection
        }
    }

    public enum ClientError: Error, LocalizedError {
        case invalidBaseURL(String)
        case invalidResponse
        case httpError(status: Int, body: String)
        case invalidDICOMJSON
        case missingStudyUID
        case missingSeriesUID
        case missingSOPInstanceUID
        case emptyRetrieveResponse

        public var errorDescription: String? {
            switch self {
            case .invalidBaseURL(let url):
                return "Invalid VNA DICOMweb URL: \(url)"
            case .invalidResponse:
                return "DICOMweb server returned no HTTP response."
            case .httpError(let status, let body):
                let snippet = body.count > 220 ? String(body.prefix(220)) + "..." : body
                return "DICOMweb HTTP \(status): \(snippet)"
            case .invalidDICOMJSON:
                return "DICOMweb response was not valid DICOM JSON."
            case .missingStudyUID:
                return "Remote study is missing Study Instance UID."
            case .missingSeriesUID:
                return "Remote series is missing Series Instance UID."
            case .missingSOPInstanceUID:
                return "Remote instance is missing SOP Instance UID."
            case .emptyRetrieveResponse:
                return "DICOMweb retrieve response did not include a DICOM instance."
            }
        }
    }

    public private(set) var configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration,
                session: URLSession? = nil) throws {
        guard configuration.connection.baseURL != nil else {
            throw ClientError.invalidBaseURL(configuration.connection.baseURLString)
        }
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = configuration.connection.timeoutSeconds
            cfg.timeoutIntervalForResource = configuration.connection.timeoutSeconds
            self.session = URLSession(configuration: cfg)
        }
    }

    public func searchStudies(query: VNAStudyQuery) async throws -> [VNAStudy] {
        let candidates = Self.expandedStudyQueries(from: query)
        if candidates.count <= 1 {
            return try await searchStudiesSingle(query: candidates.first ?? query)
        }

        var byUID: [String: VNAStudy] = [:]
        var fallback: [VNAStudy] = []
        var completedRequest = false
        var lastError: Error?
        for candidate in candidates {
            do {
                let studies = try await searchStudiesSingle(query: candidate)
                completedRequest = true
                for study in studies {
                    if study.studyInstanceUID.isEmpty {
                        fallback.append(study)
                    } else {
                        byUID[study.studyInstanceUID] = study
                    }
                }
            } catch {
                lastError = error
            }
        }
        if !completedRequest, let lastError {
            throw lastError
        }
        return (Array(byUID.values) + fallback).sorted(by: studySort)
    }

    public func searchSeries(study: VNAStudy) async throws -> [VNASeries] {
        guard !study.studyInstanceUID.isEmpty else { throw ClientError.missingStudyUID }
        let url = makeURL(path: ["studies", study.studyInstanceUID, "series"],
                          queryItems: [
                              URLQueryItem(name: "includefield", value: "all")
                          ])
        let data = try await get(url: url, accept: "application/dicom+json")
        guard !data.isEmpty else { return [] }
        return try DICOMwebMetadataDecoder.decodeSeries(data: data,
                                                        connection: configuration.connection,
                                                        studyUID: study.studyInstanceUID)
    }

    public func searchInstances(studyUID: String, seriesUID: String) async throws -> [VNAInstance] {
        guard !studyUID.isEmpty else { throw ClientError.missingStudyUID }
        guard !seriesUID.isEmpty else { throw ClientError.missingSeriesUID }
        let url = makeURL(path: ["studies", studyUID, "series", seriesUID, "instances"],
                          queryItems: [
                              URLQueryItem(name: "includefield", value: "all")
                          ])
        let data = try await get(url: url, accept: "application/dicom+json")
        guard !data.isEmpty else { return [] }
        return try DICOMwebMetadataDecoder.decodeInstances(data: data,
                                                           connection: configuration.connection,
                                                           studyUID: studyUID,
                                                           seriesUID: seriesUID)
    }

    public func retrieveInstance(studyUID: String,
                                 seriesUID: String,
                                 sopInstanceUID: String) async throws -> Data {
        guard !studyUID.isEmpty else { throw ClientError.missingStudyUID }
        guard !seriesUID.isEmpty else { throw ClientError.missingSeriesUID }
        guard !sopInstanceUID.isEmpty else { throw ClientError.missingSOPInstanceUID }
        let url = makeURL(path: [
            "studies",
            studyUID,
            "series",
            seriesUID,
            "instances",
            sopInstanceUID
        ])
        let (data, response) = try await send(url: url,
                                              accept: "multipart/related; type=\"application/dicom\"; transfer-syntax=*, application/dicom")
        let parts = DICOMwebMultipartParser.extractParts(from: data,
                                                         contentType: response.value(forHTTPHeaderField: "Content-Type"))
        guard let first = parts.first, !first.isEmpty else { throw ClientError.emptyRetrieveResponse }
        return first
    }

    public func storeInstances(_ instances: [Data],
                               studyInstanceUID: String? = nil) async throws {
        guard !instances.isEmpty else { return }
        var path = ["studies"]
        if let studyInstanceUID,
           !studyInstanceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            path.append(studyInstanceUID)
        }
        let url = makeURL(path: path)
        let boundary = "TRACER-STOW-\(UUID().uuidString)"
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: configuration.connection.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("multipart/related; type=\"application/dicom\"; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("application/dicom+json", forHTTPHeaderField: "Accept")
        request.setValue("Tracer/1.0 DICOMweb", forHTTPHeaderField: "User-Agent")
        let token = configuration.connection.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        for instance in instances {
            body.append("--\(boundary)\r\n")
            body.append("Content-Type: application/dicom\r\n\r\n")
            body.append(instance)
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpError(status: http.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func searchStudiesSingle(query: VNAStudyQuery) async throws -> [VNAStudy] {
        let url = makeURL(path: ["studies"], queryItems: query.queryItems)
        let data = try await get(url: url, accept: "application/dicom+json")
        guard !data.isEmpty else { return [] }
        return try DICOMwebMetadataDecoder.decodeStudies(data: data, connection: configuration.connection)
            .sorted(by: studySort)
    }

    private func get(url: URL, accept: String) async throws -> Data {
        let (data, _) = try await send(url: url, accept: accept)
        return data
    }

    private func send(url: URL, accept: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: configuration.connection.timeoutSeconds)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Tracer/1.0 DICOMweb", forHTTPHeaderField: "User-Agent")
        let token = configuration.connection.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpError(status: http.statusCode,
                                        body: String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    private func makeURL(path: [String], queryItems: [URLQueryItem] = []) -> URL {
        var url = configuration.connection.baseURL!
        for component in path {
            url.appendPathComponent(component)
        }
        guard !queryItems.isEmpty else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.queryItems = queryItems
        return components.url ?? url
    }

    private func studySort(_ lhs: VNAStudy, _ rhs: VNAStudy) -> Bool {
        if lhs.studyDate != rhs.studyDate { return lhs.studyDate > rhs.studyDate }
        if lhs.studyTime != rhs.studyTime { return lhs.studyTime > rhs.studyTime }
        return lhs.patientName.localizedStandardCompare(rhs.patientName) == .orderedAscending
    }

    private static func expandedStudyQueries(from query: VNAStudyQuery) -> [VNAStudyQuery] {
        let hasExplicitFields = !query.patientID.trimmed.isEmpty ||
            !query.patientName.trimmed.isEmpty ||
            !query.accessionNumber.trimmed.isEmpty ||
            !query.studyDate.trimmed.isEmpty ||
            !query.modality.trimmed.isEmpty
        let free = query.searchText.trimmed
        guard !hasExplicitFields, !free.isEmpty else { return [query] }

        if free.count == 8, free.allSatisfy(\.isNumber) {
            var byDate = query
            byDate.studyDate = free
            byDate.searchText = ""
            return [byDate]
        }

        var byPatientID = query
        byPatientID.patientID = free
        byPatientID.searchText = ""

        var byAccession = query
        byAccession.accessionNumber = free
        byAccession.searchText = ""

        var byName = query
        byName.patientName = "*\(free.replacingOccurrences(of: " ", with: "*"))*"
        byName.searchText = ""

        return [byPatientID, byAccession, byName]
    }
}

private extension VNAStudyQuery {
    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "includefield", value: "all"),
            URLQueryItem(name: "limit", value: "\(max(1, limit))"),
            URLQueryItem(name: "offset", value: "\(max(0, offset))")
        ]
        if !patientID.trimmed.isEmpty {
            items.append(URLQueryItem(name: "00100020", value: patientID.trimmed))
        }
        if !patientName.trimmed.isEmpty {
            items.append(URLQueryItem(name: "00100010", value: patientName.trimmed))
            items.append(URLQueryItem(name: "fuzzymatching", value: "true"))
        }
        if !accessionNumber.trimmed.isEmpty {
            items.append(URLQueryItem(name: "00080050", value: accessionNumber.trimmed))
        }
        if !studyDate.trimmed.isEmpty {
            items.append(URLQueryItem(name: "00080020", value: studyDate.trimmed))
        }
        if !modality.trimmed.isEmpty {
            items.append(URLQueryItem(name: "00080061", value: modality.trimmed))
        }
        return items
    }
}

public enum DICOMwebMetadataDecoder {
    public static func decodeStudies(data: Data, connection: VNAConnection) throws -> [VNAStudy] {
        try objects(from: data).compactMap { object in
            let metadata = DICOMwebMetadata(object)
            let uid = metadata.string("0020000D")
            let id = "\(connection.id.uuidString):study:\(uid.isEmpty ? metadata.fallbackID : uid)"
            let modalities = metadata.strings("00080061")
                .map { Modality.normalize($0).displayName }
                .uniquedSorted()
            return VNAStudy(
                id: id,
                connectionID: connection.id,
                connectionName: connection.displayName,
                studyInstanceUID: uid,
                patientID: metadata.string("00100020"),
                patientName: metadata.personName("00100010"),
                accessionNumber: metadata.string("00080050"),
                studyDescription: metadata.string("00081030"),
                studyDate: metadata.string("00080020"),
                studyTime: metadata.string("00080030"),
                referringPhysicianName: metadata.personName("00080090"),
                modalities: modalities,
                seriesCount: metadata.int("00201206"),
                instanceCount: metadata.int("00201208"),
                retrieveURL: metadata.string("00081190")
            )
        }
    }

    public static func decodeSeries(data: Data,
                                    connection: VNAConnection,
                                    studyUID: String) throws -> [VNASeries] {
        try objects(from: data).compactMap { object in
            let metadata = DICOMwebMetadata(object)
            let seriesUID = metadata.string("0020000E")
            let studyUID = metadata.string("0020000D").nilIfEmpty ?? studyUID
            let id = "\(connection.id.uuidString):series:\(studyUID):\(seriesUID.isEmpty ? metadata.fallbackID : seriesUID)"
            return VNASeries(
                id: id,
                connectionID: connection.id,
                studyInstanceUID: studyUID,
                seriesInstanceUID: seriesUID,
                modality: Modality.normalize(metadata.string("00080060")).rawValue,
                seriesDescription: metadata.string("0008103E"),
                seriesNumber: metadata.int("00200011"),
                bodyPartExamined: metadata.string("00180015"),
                instanceCount: metadata.int("00201209"),
                retrieveURL: metadata.string("00081190")
            )
        }
        .sorted { lhs, rhs in
            if lhs.seriesNumber != rhs.seriesNumber { return lhs.seriesNumber < rhs.seriesNumber }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    public static func decodeInstances(data: Data,
                                       connection: VNAConnection,
                                       studyUID: String,
                                       seriesUID: String) throws -> [VNAInstance] {
        try objects(from: data).compactMap { object in
            let metadata = DICOMwebMetadata(object)
            let studyUID = metadata.string("0020000D").nilIfEmpty ?? studyUID
            let seriesUID = metadata.string("0020000E").nilIfEmpty ?? seriesUID
            let sopUID = metadata.string("00080018")
            let id = "\(connection.id.uuidString):instance:\(studyUID):\(seriesUID):\(sopUID.isEmpty ? metadata.fallbackID : sopUID)"
            return VNAInstance(
                id: id,
                connectionID: connection.id,
                studyInstanceUID: studyUID,
                seriesInstanceUID: seriesUID,
                sopInstanceUID: sopUID,
                instanceNumber: metadata.int("00200013"),
                retrieveURL: metadata.string("00081190")
            )
        }
        .sorted { lhs, rhs in
            if lhs.instanceNumber != rhs.instanceNumber { return lhs.instanceNumber < rhs.instanceNumber }
            return lhs.sopInstanceUID.localizedStandardCompare(rhs.sopInstanceUID) == .orderedAscending
        }
    }

    private static func objects(from data: Data) throws -> [[String: Any]] {
        let decoded = try JSONSerialization.jsonObject(with: data)
        guard let objects = decoded as? [[String: Any]] else {
            throw DICOMwebClient.ClientError.invalidDICOMJSON
        }
        return objects
    }
}

private struct DICOMwebMetadata {
    let object: [String: Any]

    init(_ object: [String: Any]) {
        self.object = object
    }

    var fallbackID: String {
        let pieces = ["0020000D", "0020000E", "00080018", "00100020", "00080020"]
            .map(string)
            .filter { !$0.isEmpty }
        if !pieces.isEmpty { return pieces.joined(separator: "|") }
        return UUID().uuidString
    }

    func string(_ tag: String) -> String {
        valueObjects(tag).compactMap(stringValue).first?.trimmed ?? ""
    }

    func strings(_ tag: String) -> [String] {
        valueObjects(tag).compactMap { stringValue($0)?.trimmed }.filter { !$0.isEmpty }
    }

    func personName(_ tag: String) -> String {
        valueObjects(tag).compactMap { value in
            if let dict = value as? [String: Any] {
                return (dict["Alphabetic"] as? String)?.trimmed
                    ?? (dict["Ideographic"] as? String)?.trimmed
                    ?? (dict["Phonetic"] as? String)?.trimmed
            }
            return stringValue(value)?.trimmed
        }
        .first ?? ""
    }

    func int(_ tag: String) -> Int {
        guard let first = valueObjects(tag).first else { return 0 }
        if let int = first as? Int { return int }
        if let number = first as? NSNumber { return number.intValue }
        if let string = first as? String { return Int(string.trimmed) ?? 0 }
        return 0
    }

    private func valueObjects(_ tag: String) -> [Any] {
        guard let element = object[tag] as? [String: Any],
              let values = element["Value"] as? [Any] else {
            return []
        }
        return values
    }

    private func stringValue(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let dict = value as? [String: Any] {
            return (dict["Alphabetic"] as? String)
                ?? (dict["Ideographic"] as? String)
                ?? (dict["Phonetic"] as? String)
        }
        return nil
    }
}

public enum DICOMwebMultipartParser {
    public static func extractParts(from data: Data, contentType: String?) -> [Data] {
        guard let contentType,
              contentType.range(of: "multipart/", options: .caseInsensitive) != nil,
              let boundary = boundary(from: contentType) else {
            return data.isEmpty ? [] : [data]
        }

        let marker = Data("--\(boundary)".utf8)
        let markerWithCRLF = Data("\r\n--\(boundary)".utf8)
        let markerWithLF = Data("\n--\(boundary)".utf8)
        let headerSeparatorCRLF = Data("\r\n\r\n".utf8)
        let headerSeparatorLF = Data("\n\n".utf8)
        var parts: [Data] = []
        var searchStart = 0

        while let markerRange = data.range(of: marker, options: [], in: searchStart..<data.count) {
            var cursor = markerRange.upperBound
            if data.hasBytes("--", at: cursor) {
                break
            }
            if data.hasBytes("\r\n", at: cursor) {
                cursor += 2
            } else if data.hasBytes("\n", at: cursor) {
                cursor += 1
            }

            let headerRange = data.range(of: headerSeparatorCRLF, options: [], in: cursor..<data.count)
                ?? data.range(of: headerSeparatorLF, options: [], in: cursor..<data.count)
            guard let headerRange else { break }
            let bodyStart = headerRange.upperBound

            let nextCRLF = data.range(of: markerWithCRLF, options: [], in: bodyStart..<data.count)
            let nextLF = data.range(of: markerWithLF, options: [], in: bodyStart..<data.count)
            let nextRange: Range<Data.Index>?
            switch (nextCRLF, nextLF) {
            case let (crlf?, lf?):
                nextRange = crlf.lowerBound <= lf.lowerBound ? crlf : lf
            case let (crlf?, nil):
                nextRange = crlf
            case let (nil, lf?):
                nextRange = lf
            default:
                nextRange = nil
            }

            guard let nextRange else { break }
            let body = data.subdata(in: bodyStart..<trimTrailingNewlines(in: data, before: nextRange.lowerBound))
            if !body.isEmpty {
                parts.append(body)
            }
            searchStart = max(nextRange.lowerBound, nextRange.upperBound - marker.count)
        }

        return parts
    }

    private static func boundary(from contentType: String) -> String? {
        for component in contentType.split(separator: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(trimmed.dropFirst("boundary=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func trimTrailingNewlines(in data: Data, before index: Int) -> Int {
        var end = index
        if end >= 2,
           data[end - 2] == 13,
           data[end - 1] == 10 {
            end -= 2
        } else if end >= 1,
                  data[end - 1] == 10 {
            end -= 1
        }
        return max(0, end)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }

    func hasBytes(_ string: String, at index: Int) -> Bool {
        let bytes = Array(string.utf8)
        guard index >= 0, index + bytes.count <= count else { return false }
        for (offset, byte) in bytes.enumerated() where self[index + offset] != byte {
            return false
        }
        return true
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array where Element == String {
    func uniquedSorted() -> [String] {
        Array(Set(self.filter { !$0.isEmpty })).sorted()
    }
}
