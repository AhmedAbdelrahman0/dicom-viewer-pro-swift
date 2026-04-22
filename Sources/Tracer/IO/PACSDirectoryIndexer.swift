import Foundation

public enum PACSIndexPhase: String, Sendable {
    case scanning
    case finalizing
    case cancelled
}

/// Thread-safe cancellation flag for long-running PACS scans.
///
/// The indexer runs on a detached task and checks this flag periodically.
/// The caller — typically a view model on `@MainActor` — sets the flag with
/// `cancel()`. The indexer short-circuits and returns a partial result whose
/// `cancelled` field is `true`.
public final class PACSScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { _cancelled }
    }

    public func cancel() {
        lock.withLock { _cancelled = true }
    }

    public func reset() {
        lock.withLock { _cancelled = false }
    }
}

public struct PACSIndexScanProgress: Equatable, Sendable {
    public let rootPath: String
    public let phase: PACSIndexPhase
    public let scannedFiles: Int
    public let dicomInstances: Int
    public let niftiVolumes: Int
    public let indexedSeries: Int
    public let skippedFiles: Int
    public let currentPath: String

    public var statusText: String {
        switch phase {
        case .scanning:
            return "Indexing \(scannedFiles) files | \(indexedSeries) series | \(dicomInstances) DICOM | \(niftiVolumes) NIfTI"
        case .finalizing:
            return "Finalizing \(indexedSeries) indexed series from \(scannedFiles) files"
        case .cancelled:
            return "Cancelled after \(scannedFiles) files | \(indexedSeries) partial series"
        }
    }
}

public struct PACSIndexScanResult: Equatable, Sendable {
    public let rootPath: String
    public let records: [PACSIndexedSeriesSnapshot]
    public let scannedFiles: Int
    public let dicomInstances: Int
    public let niftiVolumes: Int
    public let skippedFiles: Int
    public let cancelled: Bool

    public init(rootPath: String,
                records: [PACSIndexedSeriesSnapshot],
                scannedFiles: Int,
                dicomInstances: Int,
                niftiVolumes: Int,
                skippedFiles: Int,
                cancelled: Bool = false) {
        self.rootPath = rootPath
        self.records = records
        self.scannedFiles = scannedFiles
        self.dicomInstances = dicomInstances
        self.niftiVolumes = niftiVolumes
        self.skippedFiles = skippedFiles
        self.cancelled = cancelled
    }
}

public enum PACSDirectoryIndexer {
    /// Scan a directory tree and index DICOM and NIfTI volumes.
    ///
    /// - Parameters:
    ///   - isCancelled: Polled periodically (every `progressStride` files and
    ///                  once between phases). Return `true` to short-circuit
    ///                  the scan. The returned `PACSIndexScanResult` will have
    ///                  `cancelled == true` and contain only the series
    ///                  discovered before cancellation.
    public static func scan(url: URL,
                            headerByteLimit: Int = 1_048_576,
                            progressStride: Int = 100,
                            isCancelled: @escaping @Sendable () -> Bool = { false },
                            progress: @escaping @Sendable (PACSIndexScanProgress) -> Void = { _ in }) -> PACSIndexScanResult {
        let rootPath = ImageVolume.canonicalPath(url.path)
        let indexedAt = Date()
        var scannedFiles = 0
        var dicomInstances = 0
        var niftiVolumes = 0
        var skippedFiles = 0
        var dicomSeries: [String: DICOMSeriesIndexAccumulator] = [:]
        var niftiRecords: [PACSIndexedSeriesSnapshot] = []
        var seenNIfTIPaths = Set<String>()
        var cancelled = false

        progress(PACSIndexScanProgress(
            rootPath: rootPath,
            phase: .scanning,
            scannedFiles: 0,
            dicomInstances: 0,
            niftiVolumes: 0,
            indexedSeries: 0,
            skippedFiles: 0,
            currentPath: rootPath
        ))

        if isCancelled() {
            return cancelledResult(rootPath: rootPath,
                                   progress: progress,
                                   scannedFiles: 0,
                                   dicomInstances: 0,
                                   niftiVolumes: 0,
                                   skippedFiles: 0,
                                   records: [])
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return PACSIndexScanResult(
                rootPath: rootPath,
                records: [],
                scannedFiles: 0,
                dicomInstances: 0,
                niftiVolumes: 0,
                skippedFiles: 0
            )
        }

        let stride = max(1, progressStride)

        for case let fileURL as URL in enumerator {
            guard isRegularFile(fileURL) else { continue }
            scannedFiles += 1

            if NIfTILoader.isVolumeFile(fileURL) {
                let sourcePath = NIfTILoader.canonicalSourcePath(for: fileURL)
                if seenNIfTIPaths.insert(sourcePath).inserted {
                    niftiRecords.append(PACSIndexBuilder.snapshotForNIfTI(url: fileURL, indexedAt: indexedAt))
                    niftiVolumes += 1
                }
            } else if shouldAttemptDICOM(fileURL) {
                if let dcm = try? DICOMLoader.parseIndexHeader(at: fileURL, maxBytes: headerByteLimit),
                   !dcm.seriesInstanceUID.isEmpty {
                    let uid = dcm.seriesInstanceUID
                    if dicomSeries[uid] == nil {
                        dicomSeries[uid] = DICOMSeriesIndexAccumulator(firstFile: dcm)
                    } else {
                        dicomSeries[uid]?.add(dcm)
                    }
                    dicomInstances += 1
                } else {
                    skippedFiles += 1
                }
            } else {
                skippedFiles += 1
            }

            if scannedFiles % stride == 0 {
                progress(PACSIndexScanProgress(
                    rootPath: rootPath,
                    phase: .scanning,
                    scannedFiles: scannedFiles,
                    dicomInstances: dicomInstances,
                    niftiVolumes: niftiVolumes,
                    indexedSeries: dicomSeries.count + niftiRecords.count,
                    skippedFiles: skippedFiles,
                    currentPath: fileURL.path
                ))
                if isCancelled() {
                    cancelled = true
                    break
                }
            }
        }

        let dicomRecords = dicomSeries.values.map {
            $0.snapshot(sourcePath: rootPath, indexedAt: indexedAt)
        }
        let records = uniqueSnapshots(dicomRecords + niftiRecords)
            .sorted { lhs, rhs in
                if lhs.studyDate != rhs.studyDate { return lhs.studyDate > rhs.studyDate }
                if lhs.patientName != rhs.patientName { return lhs.patientName < rhs.patientName }
                return lhs.seriesDescription < rhs.seriesDescription
            }

        if cancelled {
            return cancelledResult(rootPath: rootPath,
                                   progress: progress,
                                   scannedFiles: scannedFiles,
                                   dicomInstances: dicomInstances,
                                   niftiVolumes: niftiVolumes,
                                   skippedFiles: skippedFiles,
                                   records: records)
        }

        progress(PACSIndexScanProgress(
            rootPath: rootPath,
            phase: .finalizing,
            scannedFiles: scannedFiles,
            dicomInstances: dicomInstances,
            niftiVolumes: niftiVolumes,
            indexedSeries: records.count,
            skippedFiles: skippedFiles,
            currentPath: rootPath
        ))

        return PACSIndexScanResult(
            rootPath: rootPath,
            records: records,
            scannedFiles: scannedFiles,
            dicomInstances: dicomInstances,
            niftiVolumes: niftiVolumes,
            skippedFiles: skippedFiles
        )
    }

    private static func cancelledResult(rootPath: String,
                                        progress: @escaping @Sendable (PACSIndexScanProgress) -> Void,
                                        scannedFiles: Int,
                                        dicomInstances: Int,
                                        niftiVolumes: Int,
                                        skippedFiles: Int,
                                        records: [PACSIndexedSeriesSnapshot]) -> PACSIndexScanResult {
        progress(PACSIndexScanProgress(
            rootPath: rootPath,
            phase: .cancelled,
            scannedFiles: scannedFiles,
            dicomInstances: dicomInstances,
            niftiVolumes: niftiVolumes,
            indexedSeries: records.count,
            skippedFiles: skippedFiles,
            currentPath: rootPath
        ))
        return PACSIndexScanResult(
            rootPath: rootPath,
            records: records,
            scannedFiles: scannedFiles,
            dicomInstances: dicomInstances,
            niftiVolumes: niftiVolumes,
            skippedFiles: skippedFiles,
            cancelled: true
        )
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }

    private static func shouldAttemptDICOM(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return true }
        let ignored: Set<String> = [
            "json", "txt", "csv", "tsv", "xml", "html", "htm",
            "jpg", "jpeg", "png", "gif", "tif", "tiff", "bmp",
            "pdf", "zip", "tar", "gz", "bz2", "xz", "DS_Store"
        ]
        return !ignored.contains(ext)
    }

    private static func uniqueSnapshots(_ records: [PACSIndexedSeriesSnapshot]) -> [PACSIndexedSeriesSnapshot] {
        var seen = Set<String>()
        var unique: [PACSIndexedSeriesSnapshot] = []
        for record in records where seen.insert(record.id).inserted {
            unique.append(record)
        }
        return unique
    }
}

private struct DICOMSeriesIndexAccumulator {
    let uid: String
    var modality: String
    var description: String
    var patientID: String
    var patientName: String
    var accessionNumber: String
    var studyUID: String
    var studyDescription: String
    var studyDate: String
    var studyTime: String
    var referringPhysicianName: String
    var bodyPartExamined: String
    var filePaths: [String] = []
    var seenInstances: Set<String> = []

    init(firstFile: DICOMFile) {
        uid = firstFile.seriesInstanceUID
        modality = Modality.normalize(firstFile.modality).rawValue
        description = firstFile.seriesDescription
        patientID = firstFile.patientID
        patientName = firstFile.patientName
        accessionNumber = firstFile.accessionNumber
        studyUID = firstFile.studyInstanceUID
        studyDescription = firstFile.studyDescription
        studyDate = firstFile.studyDate
        studyTime = firstFile.studyTime
        referringPhysicianName = firstFile.referringPhysicianName
        bodyPartExamined = firstFile.bodyPartExamined
        add(firstFile)
    }

    mutating func add(_ file: DICOMFile) {
        let key: String
        if !file.sopInstanceUID.isEmpty {
            key = "sop:\(file.sopInstanceUID)"
        } else {
            key = "path:\(ImageVolume.canonicalPath(file.filePath))"
        }
        guard seenInstances.insert(key).inserted else { return }

        filePaths.append(ImageVolume.canonicalPath(file.filePath))
        if modality.isEmpty { modality = Modality.normalize(file.modality).rawValue }
        if description.isEmpty { description = file.seriesDescription }
        if patientID.isEmpty { patientID = file.patientID }
        if patientName.isEmpty { patientName = file.patientName }
        if accessionNumber.isEmpty { accessionNumber = file.accessionNumber }
        if studyUID.isEmpty { studyUID = file.studyInstanceUID }
        if studyDescription.isEmpty { studyDescription = file.studyDescription }
        if studyDate.isEmpty { studyDate = file.studyDate }
        if studyTime.isEmpty { studyTime = file.studyTime }
        if referringPhysicianName.isEmpty { referringPhysicianName = file.referringPhysicianName }
        if bodyPartExamined.isEmpty { bodyPartExamined = file.bodyPartExamined }
    }

    func snapshot(sourcePath: String, indexedAt: Date) -> PACSIndexedSeriesSnapshot {
        PACSIndexedSeriesSnapshot(
            id: "dicom:\(uid)",
            kind: .dicom,
            seriesUID: uid,
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
            seriesDescription: description,
            sourcePath: sourcePath,
            filePaths: Array(Set(filePaths)).sorted(),
            instanceCount: seenInstances.count,
            indexedAt: indexedAt
        )
    }
}
