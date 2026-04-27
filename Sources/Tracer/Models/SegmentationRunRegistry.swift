import Foundation
import CryptoKit

public struct SegmentationRunRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var studyKey: String
    public var studyUID: String
    public var patientID: String
    public var patientName: String
    public var studyDescription: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var name: String
    public var engine: String
    public var backend: String
    public var modelID: String
    public var sourceVolumeIdentities: [String]
    public var labelMap: StudySessionLabelMap?
    public var payloadFileName: String?
    public var classCount: Int
    public var nonzeroVoxelCount: Int
    public var dimensions: [Int]
    public var metadata: [String: String]

    public init(id: UUID = UUID(),
                studyKey: String,
                studyUID: String,
                patientID: String,
                patientName: String,
                studyDescription: String,
                createdAt: Date = Date(),
                modifiedAt: Date = Date(),
                name: String,
                engine: String,
                backend: String,
                modelID: String,
                sourceVolumeIdentities: [String],
                labelMap: StudySessionLabelMap,
                payloadFileName: String? = nil,
                metadata: [String: String] = [:]) {
        self.id = id
        self.studyKey = studyKey
        self.studyUID = studyUID
        self.patientID = patientID
        self.patientName = patientName
        self.studyDescription = studyDescription
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.name = name
        self.engine = engine
        self.backend = backend
        self.modelID = modelID
        self.sourceVolumeIdentities = sourceVolumeIdentities
        self.labelMap = labelMap
        self.payloadFileName = payloadFileName
        self.classCount = labelMap.classes.count
        self.nonzeroVoxelCount = labelMap.voxelsRLE.reduce(0) { total, entry in
            entry.value == 0 ? total : total + entry.count
        }
        self.dimensions = [labelMap.width, labelMap.height, labelMap.depth]
        self.metadata = metadata
    }

    public var summary: String {
        var parts: [String] = []
        if !engine.isEmpty { parts.append(engine) }
        if !backend.isEmpty { parts.append(backend) }
        if !modelID.isEmpty { parts.append(modelID) }
        parts.append("\(classCount) classes")
        parts.append("\(nonzeroVoxelCount) voxels")
        return parts.joined(separator: " · ")
    }

    public var indexedOnlyCopy: SegmentationRunRecord {
        var copy = self
        if copy.payloadFileName == nil {
            copy.payloadFileName = "\(id.uuidString).tracer-labelmap.json"
        }
        copy.labelMap = nil
        return copy
    }
}

public struct SegmentationRunRegistryBundle: Codable, Equatable, Sendable {
    public var version: Int
    public var generator: String
    public var studyKey: String
    public var studyUID: String
    public var patientID: String
    public var patientName: String
    public var studyDescription: String
    public var records: [SegmentationRunRecord]
    public var modifiedAt: Date

    public init(version: Int = 1,
                generator: String = "Tracer",
                studyKey: String,
                studyUID: String,
                patientID: String,
                patientName: String,
                studyDescription: String,
                records: [SegmentationRunRecord] = [],
                modifiedAt: Date = Date()) {
        self.version = version
        self.generator = generator
        self.studyKey = studyKey
        self.studyUID = studyUID
        self.patientID = patientID
        self.patientName = patientName
        self.studyDescription = studyDescription
        self.records = records
        self.modifiedAt = modifiedAt
    }
}

public enum SegmentationRunRegistryError: Error, LocalizedError {
    case invalidStudyKey

    public var errorDescription: String? {
        switch self {
        case .invalidStudyKey:
            return "Segmentation registry needs a valid study key."
        }
    }
}

public struct SegmentationRunRegistryStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL = SegmentationRunRegistryStore.defaultRootURL()) {
        self.rootURL = rootURL
    }

    public static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tracer", isDirectory: true)
            .appendingPathComponent("SegmentationRuns", isDirectory: true)
    }

    public func bundleURL(studyKey: String) -> URL {
        rootURL.appendingPathComponent("\(Self.safeComponent(studyKey)).tracer-segmentations.json")
    }

    public func payloadDirectoryURL(studyKey: String) -> URL {
        rootURL.appendingPathComponent(Self.safeComponent(studyKey), isDirectory: true)
    }

    public func payloadURL(for record: SegmentationRunRecord) -> URL {
        let fileName = record.payloadFileName ?? "\(record.id.uuidString).tracer-labelmap.json"
        return payloadDirectoryURL(studyKey: record.studyKey)
            .appendingPathComponent(fileName)
    }

    public func loadBundle(studyKey: String) throws -> SegmentationRunRegistryBundle? {
        let clean = studyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SegmentationRunRegistryError.invalidStudyKey }
        let url = bundleURL(studyKey: clean)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SegmentationRunRegistryBundle.self, from: data)
    }

    public func saveBundle(_ bundle: SegmentationRunRegistryBundle) throws {
        let clean = bundle.studyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SegmentationRunRegistryError.invalidStudyKey }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        try data.write(to: bundleURL(studyKey: clean), options: [.atomic])
    }

    public func loadRecords(studyKey: String) throws -> [SegmentationRunRecord] {
        try loadBundle(studyKey: studyKey)?.records ?? []
    }

    public func loadLabelMap(for record: SegmentationRunRecord) throws -> StudySessionLabelMap {
        if let labelMap = record.labelMap {
            return labelMap
        }
        let url = payloadURL(for: record)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StudySessionLabelMap.self, from: data)
    }

    public func saveRecords(_ records: [SegmentationRunRecord],
                            studyKey: String,
                            volumes: [ImageVolume]) throws {
        let anchor = volumes.first
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadDirectoryURL(studyKey: studyKey),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for record in sorted {
            guard let labelMap = record.labelMap else { continue }
            let payloadData = try encoder.encode(labelMap)
            try payloadData.write(to: payloadURL(for: record), options: [.atomic])
        }
        let bundle = SegmentationRunRegistryBundle(
            studyKey: studyKey,
            studyUID: anchor?.studyUID ?? sorted.first?.studyUID ?? "",
            patientID: anchor?.patientID ?? sorted.first?.patientID ?? "",
            patientName: anchor?.patientName ?? sorted.first?.patientName ?? "",
            studyDescription: anchor?.studyDescription ?? sorted.first?.studyDescription ?? "",
            records: sorted.map(\.indexedOnlyCopy),
            modifiedAt: Date()
        )
        try saveBundle(bundle)
    }

    public func deletePayload(for record: SegmentationRunRecord) {
        try? FileManager.default.removeItem(at: payloadURL(for: record))
    }

    private static func safeComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let value = String(scalars)
        return value.isEmpty ? sha256Hex(raw) : value
    }

    private static func sha256Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
