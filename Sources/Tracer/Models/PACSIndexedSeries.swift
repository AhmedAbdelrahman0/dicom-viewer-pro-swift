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
    private struct NIfTIIndexMetadata {
        var studyUID: String
        var patientID: String
        var patientName: String
        var accessionNumber: String
        var studyDescription: String
        var studyDate: String
        var bodyPartExamined: String
    }

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

    public static func loadMetadataForNIfTI(url: URL) -> NIfTILoadMetadata {
        let metadata = metadataForNIfTI(url: url)
        return NIfTILoadMetadata(
            studyUID: metadata.studyUID,
            patientID: metadata.patientID,
            patientName: metadata.patientName,
            accessionNumber: metadata.accessionNumber,
            studyDate: metadata.studyDate,
            bodyPartExamined: metadata.bodyPartExamined,
            seriesDescription: stripVolumeExtension(url.lastPathComponent),
            studyDescription: metadata.studyDescription
        )
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
        let metadata = metadataForNIfTI(url: url)
        let imageCount = (try? NIfTILoader.headerSummary(url).imageCount) ?? 1
        return PACSIndexedSeriesSnapshot(
            id: id,
            kind: .nifti,
            seriesUID: id,
            studyUID: metadata.studyUID,
            modality: modality,
            patientID: metadata.patientID,
            patientName: metadata.patientName,
            accessionNumber: metadata.accessionNumber,
            studyDescription: metadata.studyDescription,
            studyDate: metadata.studyDate,
            studyTime: "",
            referringPhysicianName: "",
            bodyPartExamined: metadata.bodyPartExamined,
            seriesDescription: stripVolumeExtension(url.lastPathComponent),
            sourcePath: sourcePath,
            filePaths: [sourcePath],
            instanceCount: imageCount,
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

    private static func metadataForNIfTI(url: URL) -> NIfTIIndexMetadata {
        if let bids = bidsMetadata(for: url) {
            return bids
        }
        return folderMetadata(for: url)
    }

    private static func folderMetadata(for url: URL) -> NIfTIIndexMetadata {
        let studyURL = url.deletingLastPathComponent()
        let studyPath = ImageVolume.canonicalPath(studyURL.path)
        let studyFolder = meaningfulFolderTitle(studyURL.lastPathComponent)
        let patientFolder = meaningfulFolderTitle(studyURL.deletingLastPathComponent().lastPathComponent)
        let patientID = isLikelyPatientFolder(patientFolder, studyFolder: studyFolder) ? patientFolder : ""
        let studyDescription = studyFolder.isEmpty ? stripVolumeExtension(url.lastPathComponent) : studyFolder
        let hash = stableHash(for: studyPath)
        return NIfTIIndexMetadata(
            studyUID: "nifti-study:\(hash)",
            patientID: patientID,
            patientName: patientID,
            accessionNumber: "NIFTI-\(String(hash.prefix(12)))",
            studyDescription: studyDescription,
            studyDate: dicomDate(from: studyDescription),
            bodyPartExamined: inferredBodyPart(from: studyDescription)
        )
    }

    private static func bidsMetadata(for url: URL) -> NIfTIIndexMetadata? {
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
        return NIfTIIndexMetadata(
            studyUID: "bids:\(stableHash(for: studyKey))",
            patientID: subject,
            patientName: subject,
            accessionNumber: "",
            studyDescription: description,
            studyDate: "",
            bodyPartExamined: ""
        )
    }

    private static func meaningfulFolderTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let normalized = trimmed
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let generic = [
            "tmp",
            "temp",
            "users",
            "desktop",
            "downloads",
            "documents",
            "datasets",
            "dataset",
            "data",
            "archive",
            "archives",
            "images",
            "nifti",
            "nii",
            "fdg pet ct lesions",
        ]
        return generic.contains(normalized) ? "" : trimmed
    }

    private static func isLikelyPatientFolder(_ candidate: String, studyFolder: String) -> Bool {
        guard !candidate.isEmpty, candidate != studyFolder else { return false }
        let lower = candidate.lowercased()
        if lower.hasPrefix("petct") ||
            lower.hasPrefix("patient") ||
            lower.hasPrefix("subject") ||
            lower.hasPrefix("sub-") ||
            lower.hasPrefix("case") ||
            lower.hasPrefix("pt") ||
            lower.hasPrefix("anon") {
            return true
        }
        if !dicomDate(from: studyFolder).isEmpty {
            return true
        }
        return candidate.rangeOfCharacter(from: .decimalDigits) != nil &&
            dicomDate(from: candidate).isEmpty
    }

    private static func dicomDate(from value: String) -> String {
        if let ymd = firstDateMatch(in: value,
                                    pattern: #"(?<!\d)(\d{4})[-_]?(\d{2})[-_]?(\d{2})(?!\d)"#,
                                    order: (0, 1, 2)) {
            return ymd
        }
        return firstDateMatch(in: value,
                              pattern: #"(?<!\d)(\d{2})[-_](\d{2})[-_](\d{4})(?!\d)"#,
                              order: (2, 0, 1)) ?? ""
    }

    private static func firstDateMatch(in value: String,
                                       pattern: String,
                                       order: (year: Int, month: Int, day: Int)) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              match.numberOfRanges >= 4 else {
            return nil
        }
        let captures = (1..<match.numberOfRanges).compactMap { index -> Int? in
            guard let swiftRange = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[swiftRange])
        }
        guard captures.count >= 3 else { return nil }
        return validDICOMDate(year: captures[order.year],
                              month: captures[order.month],
                              day: captures[order.day])
    }

    private static func validDICOMDate(year: Int, month: Int, day: Int) -> String? {
        guard (1900...2200).contains(year),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        return String(format: "%04d%02d%02d", year, month, day)
    }

    private static func inferredBodyPart(from value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("brain") { return "BRAIN" }
        if lower.contains("head") { return "HEAD" }
        if lower.contains("chest") { return "CHEST" }
        if lower.contains("abd") { return "ABDOMEN" }
        if lower.contains("pelvis") { return "PELVIS" }
        if lower.contains("whole") || lower.contains(" wb") || lower.contains("body") {
            return "WHOLEBODY"
        }
        return ""
    }

    private static func stableHash(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash)
    }
}
