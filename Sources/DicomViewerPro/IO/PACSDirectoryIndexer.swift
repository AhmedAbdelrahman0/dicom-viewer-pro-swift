import Foundation

public enum PACSIndexPhase: String, Sendable {
    case scanning
    case finalizing
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
}

public enum PACSDirectoryIndexer {
    public static func scan(url: URL,
                            headerByteLimit: Int = 1_048_576,
                            progressStride: Int = 100,
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

            if scannedFiles % max(1, progressStride) == 0 {
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
    var studyUID: String
    var studyDescription: String
    var studyDate: String
    var filePaths: [String] = []
    var seenInstances: Set<String> = []

    init(firstFile: DICOMFile) {
        uid = firstFile.seriesInstanceUID
        modality = Modality.normalize(firstFile.modality).rawValue
        description = firstFile.seriesDescription
        patientID = firstFile.patientID
        patientName = firstFile.patientName
        studyUID = firstFile.studyInstanceUID
        studyDescription = firstFile.studyDescription
        studyDate = firstFile.studyDate
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
        if studyUID.isEmpty { studyUID = file.studyInstanceUID }
        if studyDescription.isEmpty { studyDescription = file.studyDescription }
        if studyDate.isEmpty { studyDate = file.studyDate }
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
            studyDescription: studyDescription,
            studyDate: studyDate,
            seriesDescription: description,
            sourcePath: sourcePath,
            filePaths: Array(Set(filePaths)).sorted(),
            instanceCount: seenInstances.count,
            indexedAt: indexedAt
        )
    }
}
