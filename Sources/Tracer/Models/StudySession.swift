import Foundation
import CryptoKit
import SwiftUI

public struct StudySessionBundle: Codable, Equatable, Sendable {
    public var version: Int
    public var generator: String
    public var studyKey: String
    public var studyUID: String
    public var patientID: String
    public var patientName: String
    public var studyDescription: String
    public var volumeIdentities: [String]
    public var sessions: [StudyMeasurementSession]
    public var activeSessionID: UUID?
    public var modifiedAt: Date

    public init(version: Int = 1,
                generator: String = "Tracer",
                studyKey: String,
                studyUID: String,
                patientID: String,
                patientName: String,
                studyDescription: String,
                volumeIdentities: [String],
                sessions: [StudyMeasurementSession] = [],
                activeSessionID: UUID? = nil,
                modifiedAt: Date = Date()) {
        self.version = version
        self.generator = generator
        self.studyKey = studyKey
        self.studyUID = studyUID
        self.patientID = patientID
        self.patientName = patientName
        self.studyDescription = studyDescription
        self.volumeIdentities = volumeIdentities
        self.sessions = sessions
        self.activeSessionID = activeSessionID
        self.modifiedAt = modifiedAt
    }
}

public struct StudyMeasurementSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var visible: Bool
    public var annotations: [Annotation]
    public var suvROIs: [SUVROIMeasurement]
    public var intensityROIs: [IntensityROIMeasurement]
    public var volumeReports: [VolumeMeasurementReport]
    public var labelMaps: [StudySessionLabelMap]
    public var metadata: [String: String]

    public init(id: UUID = UUID(),
                name: String,
                createdAt: Date = Date(),
                modifiedAt: Date = Date(),
                visible: Bool = true,
                annotations: [Annotation] = [],
                suvROIs: [SUVROIMeasurement] = [],
                intensityROIs: [IntensityROIMeasurement] = [],
                volumeReports: [VolumeMeasurementReport] = [],
                labelMaps: [StudySessionLabelMap] = [],
                metadata: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.visible = visible
        self.annotations = annotations
        self.suvROIs = suvROIs
        self.intensityROIs = intensityROIs
        self.volumeReports = volumeReports
        self.labelMaps = labelMaps
        self.metadata = metadata
    }

    public var measurementCount: Int {
        annotations.count + suvROIs.count + intensityROIs.count + volumeReports.count
    }

    public var labelMapCount: Int { labelMaps.count }

    public var isEmpty: Bool {
        measurementCount == 0 && labelMaps.isEmpty && metadata.isEmpty
    }

    public var summary: String {
        var parts: [String] = []
        if !annotations.isEmpty { parts.append("\(annotations.count) calipers") }
        if !suvROIs.isEmpty { parts.append("\(suvROIs.count) SUV ROI") }
        if !intensityROIs.isEmpty { parts.append("\(intensityROIs.count) HU/intensity ROI") }
        if !volumeReports.isEmpty { parts.append("\(volumeReports.count) volumes") }
        if !labelMaps.isEmpty { parts.append("\(labelMaps.count) labels") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}

public struct StudySessionLabelMap: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var parentSeriesUID: String
    public var name: String
    public var depth: Int
    public var height: Int
    public var width: Int
    public var opacity: Double
    public var visible: Bool
    public var classes: [StudySessionLabelClass]
    public var voxelsRLE: [StudySessionRLEEntry]

    public init(id: UUID = UUID(),
                parentSeriesUID: String,
                name: String,
                depth: Int,
                height: Int,
                width: Int,
                opacity: Double,
                visible: Bool,
                classes: [StudySessionLabelClass],
                voxelsRLE: [StudySessionRLEEntry]) {
        self.id = id
        self.parentSeriesUID = parentSeriesUID
        self.name = name
        self.depth = depth
        self.height = height
        self.width = width
        self.opacity = opacity
        self.visible = visible
        self.classes = classes
        self.voxelsRLE = voxelsRLE
    }

    public init(_ map: LabelMap) {
        self.id = map.id
        self.parentSeriesUID = map.parentSeriesUID
        self.name = map.name
        self.depth = map.depth
        self.height = map.height
        self.width = map.width
        self.opacity = map.opacity
        self.visible = map.visible
        self.classes = map.classes.map(StudySessionLabelClass.init)
        self.voxelsRLE = StudySessionRLEEntry.encode(map.voxels)
    }

    public func makeLabelMap() throws -> LabelMap {
        let expectedCount = depth * height * width
        let voxels = try StudySessionRLEEntry.decode(voxelsRLE, expectedCount: expectedCount)
        let map = LabelMap(
            parentSeriesUID: parentSeriesUID,
            depth: depth,
            height: height,
            width: width,
            name: name,
            classes: classes.map(\.labelClass)
        )
        map.voxels = voxels
        map.opacity = opacity
        map.visible = visible
        return map
    }
}

public struct StudySessionLabelClass: Codable, Equatable, Sendable {
    public var labelID: UInt16
    public var name: String
    public var category: String
    public var color: StudySessionRGB
    public var dicomCode: String?
    public var fmaID: String?
    public var notes: String
    public var opacity: Double
    public var visible: Bool

    public init(_ labelClass: LabelClass) {
        let (r, g, b) = labelClass.color.rgbBytes()
        self.labelID = labelClass.labelID
        self.name = labelClass.name
        self.category = labelClass.category.rawValue
        self.color = StudySessionRGB(r: r, g: g, b: b)
        self.dicomCode = labelClass.dicomCode
        self.fmaID = labelClass.fmaID
        self.notes = labelClass.notes
        self.opacity = labelClass.opacity
        self.visible = labelClass.visible
    }

    public var labelClass: LabelClass {
        LabelClass(
            labelID: labelID,
            name: name,
            category: LabelCategory(rawValue: category) ?? .custom,
            color: Color(r: Int(color.r), g: Int(color.g), b: Int(color.b)),
            dicomCode: dicomCode,
            fmaID: fmaID,
            notes: notes,
            opacity: opacity,
            visible: visible
        )
    }
}

public struct StudySessionRGB: Codable, Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
}

public struct StudySessionRLEEntry: Codable, Equatable, Sendable {
    public var value: UInt16
    public var count: Int

    public static func encode(_ voxels: [UInt16]) -> [StudySessionRLEEntry] {
        guard let first = voxels.first else { return [] }
        var entries: [StudySessionRLEEntry] = []
        var current = first
        var count = 0
        for value in voxels {
            if value == current {
                count += 1
            } else {
                entries.append(StudySessionRLEEntry(value: current, count: count))
                current = value
                count = 1
            }
        }
        entries.append(StudySessionRLEEntry(value: current, count: count))
        return entries
    }

    public static func decode(_ entries: [StudySessionRLEEntry], expectedCount: Int) throws -> [UInt16] {
        guard expectedCount >= 0 else {
            throw StudySessionStoreError.invalidBundle("negative voxel count")
        }
        var voxels: [UInt16] = []
        voxels.reserveCapacity(expectedCount)
        for entry in entries {
            guard entry.count >= 0 else {
                throw StudySessionStoreError.invalidBundle("negative RLE count")
            }
            guard voxels.count + entry.count <= expectedCount else {
                throw StudySessionStoreError.invalidBundle("RLE payload exceeds expected voxel count")
            }
            voxels.append(contentsOf: repeatElement(entry.value, count: entry.count))
        }
        guard voxels.count == expectedCount else {
            throw StudySessionStoreError.invalidBundle("RLE payload decoded \(voxels.count) voxels, expected \(expectedCount)")
        }
        return voxels
    }
}

public enum StudySessionStoreError: Error, LocalizedError {
    case invalidBundle(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBundle(let message): return "Invalid study session bundle: \(message)"
        }
    }
}

public struct StudySessionStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL = StudySessionStore.defaultRootURL()) {
        self.rootURL = rootURL
    }

    public static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tracer", isDirectory: true)
            .appendingPathComponent("StudySessions", isDirectory: true)
    }

    public func bundleURL(studyKey: String) -> URL {
        rootURL.appendingPathComponent("\(studyKey).tracer-study.json")
    }

    public func loadBundle(studyKey: String) throws -> StudySessionBundle? {
        let url = bundleURL(studyKey: studyKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StudySessionBundle.self, from: data)
    }

    public func saveBundle(_ bundle: StudySessionBundle) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        try data.write(to: bundleURL(studyKey: bundle.studyKey), options: [.atomic])
    }

    public static func studyKey(for volumes: [ImageVolume]) -> String {
        let sorted = volumes.sorted {
            $0.sessionIdentity.localizedStandardCompare($1.sessionIdentity) == .orderedAscending
        }
        if let uid = sorted.map(\.studyUID).first(where: { uid in
            let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != "NIFTI_STUDY"
        }) {
            return "study-\(safeComponent(uid))"
        }
        let identities = sorted.map(\.sessionIdentity).joined(separator: "\n")
        return "derived-\(sha256Hex(identities))"
    }

    public static func makeBundleMetadata(studyKey: String,
                                          volumes: [ImageVolume],
                                          sessions: [StudyMeasurementSession],
                                          activeSessionID: UUID?) -> StudySessionBundle {
        let anchor = volumes.first
        return StudySessionBundle(
            studyKey: studyKey,
            studyUID: anchor?.studyUID ?? "",
            patientID: anchor?.patientID ?? "",
            patientName: anchor?.patientName ?? "",
            studyDescription: anchor?.studyDescription ?? "",
            volumeIdentities: volumes.map(\.sessionIdentity).sorted(),
            sessions: sessions,
            activeSessionID: activeSessionID,
            modifiedAt: Date()
        )
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
