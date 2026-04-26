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
                            headerByteLimit: Int = 16_384,
                            progressStride: Int = 100,
                            seriesDirectoryFastPath: Bool = true,
                            fastPathMinimumDICOMFilesPerDirectory: Int = 8,
                            fastPathSampleCount: Int = 2,
                            maxWorkerCount: Int? = nil,
                            pathDerivedFastPathSeriesThreshold: Int = 1_024,
                            pathDerivedFastPathFileThreshold: Int = 100_000,
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
        var fastIndexedDICOMDirectories = Set<String>()
        var fastPathRejectedDICOMDirectories = Set<String>()
        var fastPathDirectoryJobs: [[URL]] = []
        var lastProgressFiles = 0

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
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
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
        let prefersPathDerivedFastPath = shouldPreferPathDerivedFastPath(root: url)
        let fastPathMinimum = prefersPathDerivedFastPath
            ? 1
            : max(2, fastPathMinimumDICOMFilesPerDirectory)
        let fastPathSamples = max(1, fastPathSampleCount)

        func mergeDICOMAccumulator(_ accumulator: DICOMSeriesIndexAccumulator) {
            let uid = accumulator.uid
            if dicomSeries[uid] == nil {
                dicomSeries[uid] = accumulator
            } else {
                dicomSeries[uid]?.merge(accumulator)
            }
        }

        func emitProgressIfNeeded(currentPath: String, force: Bool = false) {
            guard force || scannedFiles - lastProgressFiles >= stride else { return }
            lastProgressFiles = scannedFiles
            progress(PACSIndexScanProgress(
                rootPath: rootPath,
                phase: .scanning,
                scannedFiles: scannedFiles,
                dicomInstances: dicomInstances,
                niftiVolumes: niftiVolumes,
                indexedSeries: dicomSeries.count + niftiRecords.count,
                skippedFiles: skippedFiles,
                currentPath: currentPath
            ))
            if isCancelled() {
                cancelled = true
            }
        }

        for case let fileURL as URL in enumerator {
            if isDirectory(fileURL) {
                let directoryPath = fileURL.path
                if seriesDirectoryFastPath,
                   !fastIndexedDICOMDirectories.contains(directoryPath),
                   !fastPathRejectedDICOMDirectories.contains(directoryPath) {
                    let candidates = dicomCandidateFiles(
                        in: fileURL,
                        requireKnownDICOMExtension: prefersPathDerivedFastPath
                    )
                    if candidates.count >= fastPathMinimum {
                        fastPathDirectoryJobs.append(candidates)
                        scannedFiles += candidates.count
                        fastIndexedDICOMDirectories.insert(directoryPath)
                        enumerator.skipDescendants()
                        emitProgressIfNeeded(currentPath: fileURL.path)
                        if cancelled { break }
                    } else if !candidates.isEmpty {
                        fastPathRejectedDICOMDirectories.insert(directoryPath)
                    }
                }
                continue
            }

            let parentPath = fileURL.deletingLastPathComponent().path
            if shouldAttemptDICOM(fileURL),
               fastIndexedDICOMDirectories.contains(parentPath) {
                continue
            }
            guard isRegularFile(fileURL) else { continue }

            if NIfTILoader.isVolumeFile(fileURL) {
                scannedFiles += 1
                let sourcePath = NIfTILoader.canonicalSourcePath(for: fileURL)
                if seenNIfTIPaths.insert(sourcePath).inserted {
                    niftiRecords.append(PACSIndexBuilder.snapshotForNIfTI(url: fileURL, indexedAt: indexedAt))
                    niftiVolumes += 1
                }
                emitProgressIfNeeded(currentPath: fileURL.path)
            } else if shouldAttemptDICOM(fileURL) {
                if seriesDirectoryFastPath,
                   !fastPathRejectedDICOMDirectories.contains(parentPath) {
                    let candidates = dicomCandidateFiles(
                        in: fileURL.deletingLastPathComponent(),
                        requireKnownDICOMExtension: prefersPathDerivedFastPath
                    )
                    if candidates.count >= fastPathMinimum,
                       let fast = fastPathAccumulator(
                        files: candidates,
                        headerByteLimit: headerByteLimit,
                        sampleCount: fastPathSamples
                       ) {
                        mergeDICOMAccumulator(fast.accumulator)
                        scannedFiles += fast.scannedFiles
                        dicomInstances += fast.scannedFiles
                        fastIndexedDICOMDirectories.insert(parentPath)
                        emitProgressIfNeeded(currentPath: fileURL.path)
                        if cancelled { break }
                        continue
                    } else {
                        fastPathRejectedDICOMDirectories.insert(parentPath)
                    }
                }

                scannedFiles += 1
                if let dcm = try? DICOMLoader.parseIndexHeader(at: fileURL, maxBytes: headerByteLimit),
                   !dcm.seriesInstanceUID.isEmpty {
                    mergeDICOMAccumulator(DICOMSeriesIndexAccumulator(firstFile: dcm))
                    dicomInstances += 1
                } else {
                    skippedFiles += 1
                }
                emitProgressIfNeeded(currentPath: fileURL.path)
            } else {
                scannedFiles += 1
                skippedFiles += 1
                emitProgressIfNeeded(currentPath: fileURL.path)
            }

            if cancelled { break }
        }

        if !cancelled, !fastPathDirectoryJobs.isEmpty {
            progress(PACSIndexScanProgress(
                rootPath: rootPath,
                phase: .finalizing,
                scannedFiles: scannedFiles,
                dicomInstances: dicomInstances,
                niftiVolumes: niftiVolumes,
                indexedSeries: dicomSeries.count + niftiRecords.count,
                skippedFiles: skippedFiles,
                currentPath: rootPath
            ))
            let shouldUsePathDerivedFastPath =
                prefersPathDerivedFastPath ||
                fastPathDirectoryJobs.count > pathDerivedFastPathSeriesThreshold ||
                scannedFiles > pathDerivedFastPathFileThreshold

            if shouldUsePathDerivedFastPath {
                for files in fastPathDirectoryJobs {
                    if isCancelled() {
                        cancelled = true
                        break
                    }
                    guard let result = pathDerivedFastPathAccumulator(files: files, root: url) else {
                        skippedFiles += files.count
                        continue
                    }
                    mergeDICOMAccumulator(result.accumulator)
                    dicomInstances += result.scannedFiles
                }
            } else {
                let fastResults = fastPathAccumulators(
                    jobs: fastPathDirectoryJobs,
                    headerByteLimit: headerByteLimit,
                    sampleCount: fastPathSamples,
                    maxWorkerCount: maxWorkerCount,
                    isCancelled: isCancelled
                )
                for result in fastResults.indexed {
                    mergeDICOMAccumulator(result.accumulator)
                    dicomInstances += result.scannedFiles
                }
                skippedFiles += fastResults.failedFiles
                if fastResults.cancelled {
                    cancelled = true
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

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
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

    private static func dicomCandidateFiles(in directory: URL,
                                            requireKnownDICOMExtension: Bool = false) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        return children
            .filter { isDICOMCandidateChild($0, requireKnownDICOMExtension: requireKnownDICOMExtension) }
            .sorted { $0.path < $1.path }
    }

    private static func isDICOMCandidateChild(_ url: URL,
                                              requireKnownDICOMExtension: Bool = false) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "dcm" || ext == "ima" || ext == "dicom" {
            return true
        }
        if requireKnownDICOMExtension {
            return false
        }
        guard shouldAttemptDICOM(url) else { return false }
        return isRegularFile(url)
    }

    private static func shouldPreferPathDerivedFastPath(root: URL) -> Bool {
        root.pathComponents.contains { $0.hasPrefix("manifest-") }
    }

    private static func fastPathAccumulator(files: [URL],
                                            headerByteLimit: Int,
                                            sampleCount: Int) -> (accumulator: DICOMSeriesIndexAccumulator, scannedFiles: Int)? {
        guard files.count >= 2 else { return nil }
        let samples = sampledFiles(files, sampleCount: sampleCount)
        var parsed: [DICOMFile] = []
        parsed.reserveCapacity(samples.count)

        for url in samples {
            guard let dcm = try? DICOMLoader.parseIndexHeader(at: url, maxBytes: headerByteLimit),
                  !dcm.seriesInstanceUID.isEmpty else {
                return nil
            }
            parsed.append(dcm)
        }

        guard let first = parsed.first else { return nil }
        let uid = first.seriesInstanceUID
        guard parsed.allSatisfy({ $0.seriesInstanceUID == uid }) else {
            return nil
        }

        return (
            DICOMSeriesIndexAccumulator(
                representativeFile: first,
                filePaths: files.map { $0.standardizedFileURL.path }
            ),
            files.count
        )
    }

    private static func pathDerivedFastPathAccumulator(files: [URL],
                                                       root: URL) -> (accumulator: DICOMSeriesIndexAccumulator, scannedFiles: Int)? {
        guard let first = files.first else { return nil }
        let directory = first.deletingLastPathComponent()
        let metadata = PathDerivedDICOMSeriesMetadata(directory: directory, root: root)
        return (
            DICOMSeriesIndexAccumulator(
                pathDerived: metadata,
                filePaths: files.map { $0.standardizedFileURL.path }
            ),
            files.count
        )
    }

    private static func fastPathAccumulators(jobs: [[URL]],
                                             headerByteLimit: Int,
                                             sampleCount: Int,
                                             maxWorkerCount: Int?,
                                             isCancelled: @escaping @Sendable () -> Bool)
        -> (indexed: [(accumulator: DICOMSeriesIndexAccumulator, scannedFiles: Int)], failedFiles: Int, cancelled: Bool) {
        guard !jobs.isEmpty else { return ([], 0, false) }

        let lock = NSLock()
        var nextIndex = 0
        var indexed: [(accumulator: DICOMSeriesIndexAccumulator, scannedFiles: Int)] = []
        var failedFiles = 0
        var cancelled = false

        let workerCount = min(
            jobs.count,
            ResourcePolicy.load().boundedIndexingWorkers(
                requested: maxWorkerCount ?? min(8, ProcessInfo.processInfo.activeProcessorCount)
            )
        )

        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            while true {
                let index: Int? = lock.withLock {
                    if cancelled || isCancelled() {
                        cancelled = true
                        return nil
                    }
                    guard nextIndex < jobs.count else { return nil }
                    defer { nextIndex += 1 }
                    return nextIndex
                }

                guard let index else { break }

                let files = jobs[index]
                if let result = fastPathAccumulator(
                    files: files,
                    headerByteLimit: headerByteLimit,
                    sampleCount: sampleCount
                ) {
                    lock.withLock {
                        indexed.append(result)
                    }
                } else {
                    lock.withLock {
                        failedFiles += files.count
                    }
                }
            }
        }

        return (indexed, failedFiles, cancelled)
    }

    private static func sampledFiles(_ files: [URL], sampleCount: Int) -> [URL] {
        guard files.count > sampleCount else { return files }
        let requested = max(1, sampleCount)
        guard requested > 1 else { return [files[0]] }

        let last = files.count - 1
        var indexes = Set<Int>()
        let slots = max(1, requested - 1)
        for i in 0..<requested {
            indexes.insert(min(last, (i * last) / slots))
        }

        return indexes.sorted().map { files[$0] }
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

private struct PathDerivedDICOMSeriesMetadata {
    let seriesUID: String
    let studyUID: String
    let modality: String
    let description: String
    let patientID: String
    let patientName: String
    let studyDescription: String
    let studyDate: String

    init(directory: URL, root: URL) {
        let directoryPath = directory.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let relativePath: String
        if directoryPath.hasPrefix(rootPath + "/") {
            relativePath = String(directoryPath.dropFirst(rootPath.count + 1))
        } else {
            relativePath = directory.lastPathComponent
        }

        let components = relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        let seriesFolder = components.last ?? directory.lastPathComponent
        let hierarchy = Self.hierarchyComponents(components)

        seriesUID = Self.stableUID(for: directoryPath)
        let studyKey = hierarchy.studyPath.map { rootPath + "/" + $0 }
            ?? directory.deletingLastPathComponent().standardizedFileURL.path
        studyUID = Self.stableUID(for: studyKey)
        description = Self.cleanedSeriesDescription(seriesFolder)
        modality = Self.inferredModality(from: description)
        patientID = hierarchy.patientID
        patientName = hierarchy.patientID
        studyDescription = hierarchy.studyDescription
        studyDate = Self.dicomDate(from: hierarchy.studyDescription)
    }

    private static func hierarchyComponents(_ components: [String])
        -> (patientID: String, studyDescription: String, studyPath: String?) {
        guard !components.isEmpty else {
            return ("Unknown Patient", "Unknown Study", nil)
        }

        let seriesIndex = components.count - 1
        let manifestIndex = components.firstIndex { $0.hasPrefix("manifest-") }
        if let manifestIndex,
           components.indices.contains(manifestIndex + 3),
           seriesIndex >= manifestIndex + 3 {
            let patient = components[manifestIndex + 2]
            let study = components[manifestIndex + 3]
            let studyPath = components[...(manifestIndex + 3)].joined(separator: "/")
            return (patient, study, studyPath)
        }

        if components.count >= 3 {
            let patient = components[components.count - 3]
            let study = components[components.count - 2]
            let studyPath = components.dropLast().joined(separator: "/")
            return (patient, study, studyPath)
        }

        if components.count == 2 {
            return (components[0], components[0], components[0])
        }

        return (components[0], components[0], components[0])
    }

    private static func cleanedSeriesDescription(_ folder: String) -> String {
        var value = folder
        if let dash = value.firstIndex(of: "-") {
            let prefix = value[..<dash]
            if prefix.allSatisfy({ $0.isNumber || $0 == "." }) {
                value = String(value[value.index(after: dash)...])
            }
        }

        let pieces = value.split(separator: "-").map(String.init)
        if pieces.count > 1, pieces.last?.allSatisfy(\.isNumber) == true {
            value = pieces.dropLast().joined(separator: "-")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inferredModality(from description: String) -> String {
        let upper = description.uppercased()
        if upper.contains("PET") || upper.contains("PT") || upper.contains("SUV") {
            return "PT"
        }
        if upper.contains("SPECT") || upper.contains("NM") {
            return "NM"
        }
        if upper.contains("CT") {
            return "CT"
        }
        if upper.contains("MR") || upper.contains("MRI")
            || upper.contains("DWI") || upper.contains("ADC")
            || upper.contains("T1") || upper.contains("T2")
            || upper.contains("LAVA") || upper.contains("PROP") {
            return "MR"
        }
        if upper.contains("SEG") {
            return "SEG"
        }
        return "OT"
    }

    private static func dicomDate(from text: String) -> String {
        let parts = text.split(separator: "-")
        guard parts.count >= 3,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              let year = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day),
              year > 1800 else {
            return ""
        }
        return String(format: "%04d%02d%02d", year, month, day)
    }

    private static func stableUID(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return "2.25.\(hash)"
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

    init(representativeFile: DICOMFile, filePaths: [String]) {
        uid = representativeFile.seriesInstanceUID
        modality = Modality.normalize(representativeFile.modality).rawValue
        description = representativeFile.seriesDescription
        patientID = representativeFile.patientID
        patientName = representativeFile.patientName
        accessionNumber = representativeFile.accessionNumber
        studyUID = representativeFile.studyInstanceUID
        studyDescription = representativeFile.studyDescription
        studyDate = representativeFile.studyDate
        studyTime = representativeFile.studyTime
        referringPhysicianName = representativeFile.referringPhysicianName
        bodyPartExamined = representativeFile.bodyPartExamined

        let uniquePaths = Array(Set(filePaths)).sorted()
        self.filePaths = uniquePaths
        self.seenInstances = Set(uniquePaths.map { "path:\($0)" })
    }

    init(pathDerived metadata: PathDerivedDICOMSeriesMetadata, filePaths: [String]) {
        uid = metadata.seriesUID
        modality = metadata.modality
        description = metadata.description
        patientID = metadata.patientID
        patientName = metadata.patientName
        accessionNumber = ""
        studyUID = metadata.studyUID
        studyDescription = metadata.studyDescription
        studyDate = metadata.studyDate
        studyTime = ""
        referringPhysicianName = ""
        bodyPartExamined = ""

        let uniquePaths = Array(Set(filePaths)).sorted()
        self.filePaths = uniquePaths
        self.seenInstances = Set(uniquePaths.map { "path:\($0)" })
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

    mutating func merge(_ other: DICOMSeriesIndexAccumulator) {
        for key in other.seenInstances where seenInstances.insert(key).inserted {}
        let existingPaths = Set(filePaths)
        filePaths.append(contentsOf: other.filePaths.filter { !existingPaths.contains($0) })
        if modality.isEmpty { modality = other.modality }
        if description.isEmpty { description = other.description }
        if patientID.isEmpty { patientID = other.patientID }
        if patientName.isEmpty { patientName = other.patientName }
        if accessionNumber.isEmpty { accessionNumber = other.accessionNumber }
        if studyUID.isEmpty { studyUID = other.studyUID }
        if studyDescription.isEmpty { studyDescription = other.studyDescription }
        if studyDate.isEmpty { studyDate = other.studyDate }
        if studyTime.isEmpty { studyTime = other.studyTime }
        if referringPhysicianName.isEmpty { referringPhysicianName = other.referringPhysicianName }
        if bodyPartExamined.isEmpty { bodyPartExamined = other.bodyPartExamined }
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
