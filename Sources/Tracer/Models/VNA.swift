import Foundation

public struct VNAConnection: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURLString: String
    public var bearerToken: String
    public var isEnabled: Bool
    public var timeoutSeconds: TimeInterval
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(),
                name: String,
                baseURLString: String,
                bearerToken: String = "",
                isEnabled: Bool = true,
                timeoutSeconds: TimeInterval = 60,
                lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.bearerToken = bearerToken
        self.isEnabled = isEnabled
        self.timeoutSeconds = timeoutSeconds
        self.lastUsedAt = lastUsedAt
    }

    public var baseURL: URL? {
        URL(string: normalizedBaseURLString)
    }

    public var normalizedBaseURLString: String {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.contains("://") {
            return trimmed
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("localhost") || lower.hasPrefix("127.") || lower.hasPrefix("[::1]") {
            return "http://\(trimmed)"
        }
        return "https://\(trimmed)"
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return baseURL?.host ?? "VNA"
    }

    public var endpointSummary: String {
        guard let url = baseURL else { return baseURLString }
        var pieces: [String] = []
        if let host = url.host { pieces.append(host) }
        if !url.path.isEmpty && url.path != "/" { pieces.append(url.path) }
        return pieces.isEmpty ? normalizedBaseURLString : pieces.joined(separator: " ")
    }
}

public struct VNAConnectionStore {
    public static let defaultKey = "Tracer.VNAConnections.v1"

    private let defaults: UserDefaults
    private let key: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(defaults: UserDefaults = .standard, key: String = VNAConnectionStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [VNAConnection] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode([VNAConnection].self, from: data) else {
            return []
        }
        return sorted(uniqued(decoded))
    }

    @discardableResult
    public func upsert(_ connection: VNAConnection, usedAt: Date? = nil) -> [VNAConnection] {
        var connections = load()
        var next = connection
        if let usedAt {
            next.lastUsedAt = usedAt
        }
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = next
        } else if let index = connections.firstIndex(where: {
            $0.normalizedBaseURLString.caseInsensitiveCompare(connection.normalizedBaseURLString) == .orderedSame
        }) {
            next.id = connections[index].id
            connections[index] = next
        } else {
            connections.append(next)
        }
        save(connections)
        return load()
    }

    @discardableResult
    public func markUsed(id: UUID, at date: Date = Date()) -> [VNAConnection] {
        var connections = load()
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return connections }
        connections[index].lastUsedAt = date
        save(connections)
        return load()
    }

    @discardableResult
    public func remove(id: UUID) -> [VNAConnection] {
        let remaining = load().filter { $0.id != id }
        save(remaining)
        return remaining
    }

    @discardableResult
    public func clear() -> [VNAConnection] {
        defaults.removeObject(forKey: key)
        return []
    }

    private func save(_ connections: [VNAConnection]) {
        if let data = try? encoder.encode(sorted(uniqued(connections))) {
            defaults.set(data, forKey: key)
        }
    }

    private func uniqued(_ connections: [VNAConnection]) -> [VNAConnection] {
        var seenIDs = Set<UUID>()
        var seenURLs = Set<String>()
        var output: [VNAConnection] = []
        for connection in connections {
            let urlKey = connection.normalizedBaseURLString.lowercased()
            guard !seenIDs.contains(connection.id), !seenURLs.contains(urlKey) else { continue }
            seenIDs.insert(connection.id)
            seenURLs.insert(urlKey)
            output.append(connection)
        }
        return output
    }

    private func sorted(_ connections: [VNAConnection]) -> [VNAConnection] {
        connections.sorted { lhs, rhs in
            let lhsDate = lhs.lastUsedAt ?? .distantPast
            let rhsDate = rhs.lastUsedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

public struct VNAStudyQuery: Equatable, Sendable {
    public var searchText: String
    public var patientID: String
    public var patientName: String
    public var accessionNumber: String
    public var studyDate: String
    public var modality: String
    public var limit: Int
    public var offset: Int

    public init(searchText: String = "",
                patientID: String = "",
                patientName: String = "",
                accessionNumber: String = "",
                studyDate: String = "",
                modality: String = "",
                limit: Int = 50,
                offset: Int = 0) {
        self.searchText = searchText
        self.patientID = patientID
        self.patientName = patientName
        self.accessionNumber = accessionNumber
        self.studyDate = studyDate
        self.modality = modality
        self.limit = limit
        self.offset = offset
    }
}

public struct VNAStudy: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var connectionID: UUID
    public var connectionName: String
    public var studyInstanceUID: String
    public var patientID: String
    public var patientName: String
    public var accessionNumber: String
    public var studyDescription: String
    public var studyDate: String
    public var studyTime: String
    public var referringPhysicianName: String
    public var modalities: [String]
    public var seriesCount: Int
    public var instanceCount: Int
    public var retrieveURL: String

    public init(id: String,
                connectionID: UUID,
                connectionName: String,
                studyInstanceUID: String,
                patientID: String,
                patientName: String,
                accessionNumber: String,
                studyDescription: String,
                studyDate: String,
                studyTime: String,
                referringPhysicianName: String,
                modalities: [String],
                seriesCount: Int,
                instanceCount: Int,
                retrieveURL: String = "") {
        self.id = id
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.studyInstanceUID = studyInstanceUID
        self.patientID = patientID
        self.patientName = patientName
        self.accessionNumber = accessionNumber
        self.studyDescription = studyDescription
        self.studyDate = studyDate
        self.studyTime = studyTime
        self.referringPhysicianName = referringPhysicianName
        self.modalities = modalities
        self.seriesCount = seriesCount
        self.instanceCount = instanceCount
        self.retrieveURL = retrieveURL
    }

    public var modalitySummary: String {
        modalities.isEmpty ? "Other" : modalities.joined(separator: "/")
    }
}

public struct VNASeries: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var connectionID: UUID
    public var studyInstanceUID: String
    public var seriesInstanceUID: String
    public var modality: String
    public var seriesDescription: String
    public var seriesNumber: Int
    public var bodyPartExamined: String
    public var instanceCount: Int
    public var retrieveURL: String

    public init(id: String,
                connectionID: UUID,
                studyInstanceUID: String,
                seriesInstanceUID: String,
                modality: String,
                seriesDescription: String,
                seriesNumber: Int = 0,
                bodyPartExamined: String = "",
                instanceCount: Int = 0,
                retrieveURL: String = "") {
        self.id = id
        self.connectionID = connectionID
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.modality = modality
        self.seriesDescription = seriesDescription
        self.seriesNumber = seriesNumber
        self.bodyPartExamined = bodyPartExamined
        self.instanceCount = instanceCount
        self.retrieveURL = retrieveURL
    }

    public var displayName: String {
        let description = seriesDescription.isEmpty ? "Series" : seriesDescription
        return "\(Modality.normalize(modality).displayName) - \(description)"
    }
}

public struct VNAInstance: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var connectionID: UUID
    public var studyInstanceUID: String
    public var seriesInstanceUID: String
    public var sopInstanceUID: String
    public var instanceNumber: Int
    public var retrieveURL: String

    public init(id: String,
                connectionID: UUID,
                studyInstanceUID: String,
                seriesInstanceUID: String,
                sopInstanceUID: String,
                instanceNumber: Int = 0,
                retrieveURL: String = "") {
        self.id = id
        self.connectionID = connectionID
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.sopInstanceUID = sopInstanceUID
        self.instanceNumber = instanceNumber
        self.retrieveURL = retrieveURL
    }
}

public struct VNACacheStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootURL = base
                .appendingPathComponent("Tracer", isDirectory: true)
                .appendingPathComponent("VNACache", isDirectory: true)
        }
    }

    public func cachedInstanceURL(connectionID: UUID,
                                  studyUID: String,
                                  seriesUID: String,
                                  sopInstanceUID: String) -> URL {
        seriesDirectory(connectionID: connectionID, studyUID: studyUID, seriesUID: seriesUID)
            .appendingPathComponent(Self.safePathComponent(sopInstanceUID))
            .appendingPathExtension("dcm")
    }

    public func writeInstance(_ data: Data,
                              connectionID: UUID,
                              studyUID: String,
                              seriesUID: String,
                              sopInstanceUID: String) throws -> URL {
        let directory = seriesDirectory(connectionID: connectionID, studyUID: studyUID, seriesUID: seriesUID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = cachedInstanceURL(connectionID: connectionID,
                                    studyUID: studyUID,
                                    seriesUID: seriesUID,
                                    sopInstanceUID: sopInstanceUID)
        try data.write(to: url, options: [.atomic])
        return url
    }

    public func cachedSeriesFilePaths(connectionID: UUID,
                                      studyUID: String,
                                      seriesUID: String,
                                      instances: [VNAInstance]) -> [String] {
        instances
            .map {
                cachedInstanceURL(connectionID: connectionID,
                                  studyUID: studyUID,
                                  seriesUID: seriesUID,
                                  sopInstanceUID: $0.sopInstanceUID)
            }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
    }

    private func seriesDirectory(connectionID: UUID, studyUID: String, seriesUID: String) -> URL {
        rootURL
            .appendingPathComponent(connectionID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(studyUID), isDirectory: true)
            .appendingPathComponent(Self.safePathComponent(seriesUID), isDirectory: true)
    }

    public static func safePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return value.isEmpty ? "unknown" : value
    }
}
