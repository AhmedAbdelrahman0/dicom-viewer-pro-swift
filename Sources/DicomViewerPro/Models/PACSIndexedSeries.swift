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
    public var studyDescription: String
    public var studyDate: String
    public var seriesDescription: String
    public var sourcePath: String
    public var filePaths: [String]
    public var instanceCount: Int
    public var indexedAt: Date

    public var displayName: String {
        let description = seriesDescription.isEmpty ? "Series" : seriesDescription
        return "\(Modality.normalize(modality).displayName) - \(description)"
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
    public var studyDescription: String
    public var studyDate: String
    public var seriesDescription: String
    public var sourcePath: String
    public var filePathsBlob: String
    public var instanceCount: Int
    public var indexedAt: Date

    public init(id: String,
                kind: PACSIndexedSeriesKind,
                seriesUID: String,
                studyUID: String,
                modality: String,
                patientID: String,
                patientName: String,
                studyDescription: String,
                studyDate: String,
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
        self.studyDescription = studyDescription
        self.studyDate = studyDate
        self.seriesDescription = seriesDescription
        self.sourcePath = sourcePath
        self.filePathsBlob = filePaths.joined(separator: "\n")
        self.instanceCount = instanceCount
        self.indexedAt = indexedAt
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
        [
            kind.displayName,
            modality,
            patientID,
            patientName,
            studyDescription,
            studyDate,
            seriesDescription,
            sourcePath,
        ]
        .joined(separator: " ")
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
            studyDescription: studyDescription,
            studyDate: studyDate,
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
        studyDescription = other.studyDescription
        studyDate = other.studyDate
        seriesDescription = other.seriesDescription
        sourcePath = other.sourcePath
        filePathsBlob = other.filePathsBlob
        instanceCount = other.instanceCount
        indexedAt = other.indexedAt
    }
}

public enum PACSIndexBuilder {
    public static func record(for series: DICOMSeries,
                              sourcePath: String,
                              indexedAt: Date = Date()) -> PACSIndexedSeries {
        let id = "dicom:\(series.uid)"
        return PACSIndexedSeries(
            id: id,
            kind: .dicom,
            seriesUID: series.uid,
            studyUID: series.studyUID,
            modality: series.modality,
            patientID: series.patientID,
            patientName: series.patientName,
            studyDescription: series.studyDescription,
            studyDate: series.studyDate,
            seriesDescription: series.description,
            sourcePath: sourcePath,
            filePaths: series.files.map(\.filePath).sorted(),
            instanceCount: series.instanceCount,
            indexedAt: indexedAt
        )
    }

    public static func recordForNIfTI(url: URL,
                                      indexedAt: Date = Date()) -> PACSIndexedSeries {
        let modality = NIfTILoader.inferModality(
            filename: url.lastPathComponent,
            parentDir: url.deletingLastPathComponent().path,
            hint: ""
        )
        let id = "nifti:\(url.path)"
        return PACSIndexedSeries(
            id: id,
            kind: .nifti,
            seriesUID: id,
            studyUID: "NIFTI_STUDY",
            modality: modality,
            patientID: "NIFTI_Import",
            patientName: "NIfTI Import",
            studyDescription: url.deletingLastPathComponent().lastPathComponent,
            studyDate: "",
            seriesDescription: stripVolumeExtension(url.lastPathComponent),
            sourcePath: url.path,
            filePaths: [url.path],
            instanceCount: 1,
            indexedAt: indexedAt
        )
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
}
