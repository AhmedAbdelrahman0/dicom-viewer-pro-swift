import Foundation
import SwiftData

public enum PACSIndexedSeriesKind: String, Codable, CaseIterable, Sendable {
    case dicom
    case nifti

    public var displayName: String {
        switch self {
        case .dicom: return "DICOM"
        case .nifti: return "NIfTI"
        }
    }
}

public struct PACSIndexedSeriesSnapshot: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: PACSIndexedSeriesKind
    public var seriesUID: String
    public var studyUID: String
    public var modality: String
    public var patientID: String
    public var patientName: String
    public var accessionNumber: String = ""
    public var studyDescription: String
    public var studyDate: String
    public var studyTime: String = ""
    public var referringPhysicianName: String = ""
    public var bodyPartExamined: String = ""
    public var seriesDescription: String
    public var sourcePath: String
    public var filePaths: [String]
    public var instanceCount: Int
    public var indexedAt: Date

    public var displayName: String {
        let description = seriesDescription.isEmpty ? "Series" : seriesDescription
        return "\(Modality.normalize(modality).displayName) - \(description)"
    }

    public var searchableText: String {
        PACSIndexedSeries.makeSearchableText(
            kind: kind,
            modality: modality,
            patientID: patientID,
            patientName: patientName,
            accessionNumber: accessionNumber,
            studyDescription: studyDescription,
            studyDate: studyDate,
            studyTime: studyTime,
            referringPhysicianName: referringPhysicianName,
            bodyPartExamined: bodyPartExamined,
            seriesDescription: seriesDescription,
            sourcePath: sourcePath
        )
    }
}

@Model
public final class PACSIndexedSeries {
    @Attribute(.unique) public var id: String
    public var kindRawValue: String
    public var seriesUID: String
    public var studyUID: String
    public var modality: String
    public var patientID: String
    public var patientName: String
    public var accessionNumber: String = ""
    public var studyDescription: String
    public var studyDate: String
    public var studyTime: String = ""
    public var referringPhysicianName: String = ""
    public var bodyPartExamined: String = ""
    public var seriesDescription: String
    public var sourcePath: String
    public var filePathsBlob: String
    public var instanceCount: Int
    public var indexedAt: Date
    public var searchableTextLower: String

    public init(id: String,
                kind: PACSIndexedSeriesKind,
                seriesUID: String,
                studyUID: String,
                modality: String,
                patientID: String,
                patientName: String,
                accessionNumber: String = "",
                studyDescription: String,
                studyDate: String,
                studyTime: String = "",
                referringPhysicianName: String = "",
                bodyPartExamined: String = "",
                seriesDescription: String,
                sourcePath: String,
                filePaths: [String],
                instanceCount: Int,
                indexedAt: Date = Date()) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.seriesUID = seriesUID
        self.studyUID = studyUID
        self.modality = modality
        self.patientID = patientID
        self.patientName = patientName
        self.accessionNumber = accessionNumber
        self.studyDescription = studyDescription
        self.studyDate = studyDate
        self.studyTime = studyTime
        self.referringPhysicianName = referringPhysicianName
        self.bodyPartExamined = bodyPartExamined
        self.seriesDescription = seriesDescription
        self.sourcePath = sourcePath
        self.filePathsBlob = filePaths.joined(separator: "\n")
        self.instanceCount = instanceCount
        self.indexedAt = indexedAt
        self.searchableTextLower = Self.makeSearchableText(
            kind: kind,
            modality: modality,
            patientID: patientID,
            patientName: patientName,
            accessionNumber: accessionNumber,
            studyDescription: studyDescription,
            studyDate: studyDate,
            studyTime: studyTime,
            referringPhysicianName: referringPhysicianName,
            bodyPartExamined: bodyPartExamined,
            seriesDescription: seriesDescription,
            sourcePath: sourcePath
        )
    }

    public convenience init(snapshot: PACSIndexedSeriesSnapshot) {
        self.init(
            id: snapshot.id,
            kind: snapshot.kind,
            seriesUID: snapshot.seriesUID,
            studyUID: snapshot.studyUID,
            modality: snapshot.modality,
            patientID: snapshot.patientID,
            patientName: snapshot.patientName,
            accessionNumber: snapshot.accessionNumber,
            studyDescription: snapshot.studyDescription,
            studyDate: snapshot.studyDate,
            studyTime: snapshot.studyTime,
            referringPhysicianName: snapshot.referringPhysicianName,
            bodyPartExamined: snapshot.bodyPartExamined,
            seriesDescription: snapshot.seriesDescription,
            sourcePath: snapshot.sourcePath,
            filePaths: snapshot.filePaths,
            instanceCount: snapshot.instanceCount,
            indexedAt: snapshot.indexedAt
        )
    }

    public var kind: PACSIndexedSeriesKind {
        PACSIndexedSeriesKind(rawValue: kindRawValue) ?? .dicom
    }

    public var filePaths: [String] {
        filePathsBlob
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public var displayName: String {
        let description = seriesDescription.isEmpty ? "Series" : seriesDescription
        return "\(Modality.normalize(modality).displayName) - \(description)"
    }

    public var searchableText: String {
        searchableTextLower
    }

    public var snapshot: PACSIndexedSeriesSnapshot {
        PACSIndexedSeriesSnapshot(
            id: id,
            kind: kind,
            seriesUID: seriesUID,
            studyUID: studyUID,
            modality: modality,
            patientID: patientID,
            patientName: patientName,
            accessionNumber: accessionNumber,
            studyDescription: studyDescription,
            studyDate: studyDate,
            studyTime: studyTime,
            referringPhysicianName: referringPhysicianName,
            bodyPartExamined: bodyPartExamined,
            seriesDescription: seriesDescription,
            sourcePath: sourcePath,
            filePaths: filePaths,
            instanceCount: instanceCount,
            indexedAt: indexedAt
        )
    }

    public func update(from other: PACSIndexedSeries) {
        kindRawValue = other.kindRawValue
        seriesUID = other.seriesUID
        studyUID = other.studyUID
        modality = other.modality
        patientID = other.patientID
        patientName = other.patientName
        accessionNumber = other.accessionNumber
        studyDescription = other.studyDescription
        studyDate = other.studyDate
        studyTime = other.studyTime
        referringPhysicianName = other.referringPhysicianName
        bodyPartExamined = other.bodyPartExamined
        seriesDescription = other.seriesDescription
        sourcePath = other.sourcePath
        filePathsBlob = other.filePathsBlob
        instanceCount = other.instanceCount
        indexedAt = other.indexedAt
        searchableTextLower = other.searchableTextLower
    }

    public func update(from snapshot: PACSIndexedSeriesSnapshot) {
        kindRawValue = snapshot.kind.rawValue
        seriesUID = snapshot.seriesUID
        studyUID = snapshot.studyUID
        modality = snapshot.modality
        patientID = snapshot.patientID
        patientName = snapshot.patientName
        accessionNumber = snapshot.accessionNumber
        studyDescription = snapshot.studyDescription
        studyDate = snapshot.studyDate
        studyTime = snapshot.studyTime
        referringPhysicianName = snapshot.referringPhysicianName
        bodyPartExamined = snapshot.bodyPartExamined
        seriesDescription = snapshot.seriesDescription
        sourcePath = snapshot.sourcePath
        filePathsBlob = snapshot.filePaths.joined(separator: "\n")
        instanceCount = snapshot.instanceCount
        indexedAt = snapshot.indexedAt
        searchableTextLower = snapshot.searchableText
    }

    public static func makeSearchableText(kind: PACSIndexedSeriesKind,
                                          modality: String,
                                          patientID: String,
                                          patientName: String,
                                          accessionNumber: String,
                                          studyDescription: String,
                                          studyDate: String,
                                          studyTime: String,
                                          referringPhysicianName: String,
                                          bodyPartExamined: String,
                                          seriesDescription: String,
                                          sourcePath: String) -> String {
        [
            kind.displayName,
            modality,
            patientID,
            patientName,
            accessionNumber,
            studyDescription,
            studyDate,
            studyTime,
            referringPhysicianName,
            bodyPartExamined,
            seriesDescription,
            sourcePath,
        ]
        .joined(separator: " ")
        .lowercased()
    }
}

public enum PACSIndexBuilder {
    public static func snapshot(for series: DICOMSeries,
                                sourcePath: String,
                                indexedAt: Date = Date()) -> PACSIndexedSeriesSnapshot {
        PACSIndexedSeriesSnapshot(
            id: "dicom:\(series.uid)",
            kind: .dicom,
            seriesUID: series.uid,
            studyUID: series.studyUID,
            modality: series.modality,
            patientID: series.patientID,
            patientName: series.patientName,
            accessionNumber: series.accessionNumber,
            studyDescription: series.studyDescription,
            studyDate: series.studyDate,
            studyTime: series.studyTime,
            referringPhysicianName: series.referringPhysicianName,
            bodyPartExamined: series.bodyPartExamined,
            seriesDescription: series.description,
            sourcePath: ImageVolume.canonicalPath(sourcePath),
            filePaths: Array(Set(series.files.map { ImageVolume.canonicalPath($0.filePath) })).sorted(),
            instanceCount: series.instanceCount,
            indexedAt: indexedAt
        )
    }

    public static func record(for series: DICOMSeries,
                              sourcePath: String,
                              indexedAt: Date = Date()) -> PACSIndexedSeries {
        PACSIndexedSeries(snapshot: snapshot(for: series, sourcePath: sourcePath, indexedAt: indexedAt))
    }

    public static func snapshotForNIfTI(url: URL,
                                        indexedAt: Date = Date()) -> PACSIndexedSeriesSnapshot {
        let modality = NIfTILoader.inferModality(
            filename: url.lastPathComponent,
            parentDir: url.deletingLastPathComponent().path,
            hint: ""
        )
        let sourcePath = NIfTILoader.canonicalSourcePath(for: url)
        let id = "nifti:\(sourcePath)"
        let bids = bidsMetadata(for: url)
        return PACSIndexedSeriesSnapshot(
            id: id,
            kind: .nifti,
            seriesUID: id,
            studyUID: bids?.studyUID ?? "NIFTI_STUDY",
            modality: modality,
            patientID: bids?.patientID ?? "NIFTI_Import",
            patientName: bids?.patientName ?? "NIfTI Import",
            accessionNumber: "",
            studyDescription: bids?.studyDescription ?? url.deletingLastPathComponent().lastPathComponent,
            studyDate: "",
            studyTime: "",
            referringPhysicianName: "",
            bodyPartExamined: "",
            seriesDescription: stripVolumeExtension(url.lastPathComponent),
            sourcePath: sourcePath,
            filePaths: [sourcePath],
            instanceCount: 1,
            indexedAt: indexedAt
        )
    }

    public static func recordForNIfTI(url: URL,
                                      indexedAt: Date = Date()) -> PACSIndexedSeries {
        PACSIndexedSeries(snapshot: snapshotForNIfTI(url: url, indexedAt: indexedAt))
    }

    private static func stripVolumeExtension(_ name: String) -> String {
        var n = name
        for ext in NIfTILoader.extensions.sorted(by: { $0.count > $1.count }) {
            let suffix = "." + ext
            if n.lowercased().hasSuffix(suffix) {
                n = String(n.dropLast(suffix.count))
                break
            }
        }
        return n
    }

    private static func bidsMetadata(for url: URL) -> (studyUID: String,
                                                       patientID: String,
                                                       patientName: String,
                                                       studyDescription: String)? {
        let components = url.standardizedFileURL.pathComponents
        guard let subjectIndex = components.firstIndex(where: { $0.hasPrefix("sub-") }) else {
            return nil
        }

        let subject = components[subjectIndex]
        let datasetName: String
        if subjectIndex > 1,
           components[subjectIndex - 1] == "derivatives" {
            datasetName = components[subjectIndex - 2]
        } else {
            datasetName = subjectIndex > 0 ? components[subjectIndex - 1] : "BIDS"
        }
        let session: String?
        if components.indices.contains(subjectIndex + 1),
           components[subjectIndex + 1].hasPrefix("ses-") {
            session = components[subjectIndex + 1]
        } else {
            session = nil
        }

        var studyKeyComponents = [datasetName, subject]
        if let session {
            studyKeyComponents.append(session)
        }
        let studyKey = studyKeyComponents.joined(separator: "/")
        let description = session.map { "\(datasetName) \($0)" } ?? datasetName
        return (
            studyUID: "bids:\(stableHash(for: studyKey))",
            patientID: subject,
            patientName: subject,
            studyDescription: description
        )
    }

    private static func stableHash(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash)
    }
}
