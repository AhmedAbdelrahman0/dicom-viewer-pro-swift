import Foundation

/// The engine that actually runs a cohort. Takes a `CohortJob` + a list of
/// `PACSWorklistStudy`, and processes each study end-to-end:
///
///   1. Load primary (and optional aux) volume from disk
///   2. Run nnU-Net segmentation (local, CoreML, or DGX remote)
///   3. Enumerate connected components via `PETQuantification.compute`
///   4. Optionally run the per-lesion classifier
///   5. Write `<outputRoot>/<studyID>/{labels.nii.gz, stats.json, classification.json}`
///   6. Update the checkpoint file atomically
///
/// Concurrency model: an `actor` owns the mutable checkpoint + progress
/// state. Studies run as child `Task`s with a bounded semaphore so the DGX
/// or CPU doesn't thrash. Cancellation propagates via `Task.isCancelled`;
/// in-flight studies are allowed to finish so we don't leave half-uploaded
/// NIfTIs on the remote host.
///
/// `CohortBatchProcessor` is deliberately decoupled from the single-study
/// `NNUnetViewModel` / `ClassificationViewModel` — those are `@MainActor`
/// and own UI-facing `@Published` state. Here we drive the lower-level
/// runners directly (`NNUnetRunner`, `RemoteNNUnetRunner`, a classifier
/// instance built by `CohortClassifierFactory`), which keeps cohort work
/// off the main thread and responsive.
public actor CohortBatchProcessor {

    public let jobID: String
    private var checkpoint: CohortCheckpoint
    private let checkpointURL: URL
    /// Full `PACSWorklistStudy` rows keyed by id. Needed to load volumes
    /// off disk — the `CohortStudyResult` only carries the metadata the
    /// cohort UI needs to render, not the series file paths.
    private var studiesByID: [String: PACSWorklistStudy]

    /// Called on the main actor every time a study transitions state. The
    /// cohort UI hooks this to update the progress row + results table
    /// without polling.
    private let onProgress: @Sendable (CohortCheckpoint) async -> Void

    public init(job: CohortJob,
                studies: [PACSWorklistStudy],
                onProgress: @escaping @Sendable (CohortCheckpoint) async -> Void = { _ in }) throws {

        self.jobID = job.id
        self.checkpointURL = job.checkpointURL
        self.onProgress = onProgress
        self.studiesByID = Dictionary(uniqueKeysWithValues: studies.map { ($0.id, $0) })

        // Create the output root + checkpoint skeleton. If a checkpoint
        // already exists for this job id, reuse it — that's how resume
        // works. Any new studies not yet in the checkpoint are appended
        // as .pending.
        try FileManager.default.createDirectory(at: job.outputRoot,
                                                withIntermediateDirectories: true)

        if let existing = try? CohortCheckpoint.load(from: job.checkpointURL) {
            var merged = existing
            merged.job = job   // refresh config; keeps results intact
            for study in studies where merged.results[study.id] == nil {
                merged.results[study.id] = CohortStudyResult(study: study)
            }
            self.checkpoint = merged
        } else {
            var cp = CohortCheckpoint(job: job)
            for study in studies {
                cp.results[study.id] = CohortStudyResult(study: study)
            }
            self.checkpoint = cp
        }
        try self.checkpoint.save(to: job.checkpointURL)
    }

    // MARK: - Public entry point

    /// Run to completion. Honours task cancellation between studies;
    /// in-flight studies are allowed to finish.
    public func run() async {
        let job = checkpoint.job
        let pendingIDs = checkpoint.results.values
            .filter { $0.status == .pending || ($0.status == .cancelled && !$0.status.isTerminal) }
            .map(\.id)

        guard !pendingIDs.isEmpty else {
            await onProgress(checkpoint)
            return
        }

        let workers = max(1, min(16, job.maxConcurrent))
        await withTaskGroup(of: Void.self) { group in
            // Seed the pool with `workers` tasks. Each task pulls the next
            // pending study id from a shared queue.
            let queue = AsyncSemaphoreQueue(pendingIDs)
            for _ in 0..<workers {
                group.addTask { [weak self] in
                    guard let self else { return }
                    while let studyID = await queue.next() {
                        if Task.isCancelled { break }
                        await self.processOneStudy(studyID: studyID)
                    }
                }
            }
            await group.waitForAll()
        }

        await onProgress(checkpoint)
    }

    // MARK: - Inspection

    public func currentCheckpoint() -> CohortCheckpoint { checkpoint }

    // MARK: - Core per-study pipeline

    private func processOneStudy(studyID: String) async {
        guard var result = checkpoint.results[studyID] else { return }

        // Skip if we already have a usable labels.nii.gz on disk and the
        // job asked us to.
        let studyDir = checkpoint.job.outputDirectory(for: studyID)
        let labelURL = studyDir.appendingPathComponent("labels.nii.gz")
        if checkpoint.job.skipIfResultsExist,
           FileManager.default.fileExists(atPath: labelURL.path),
           result.status != .failedLoad,
           result.status != .failedSegmentation {
            result.status = .skipped
            result.labelMapPath = labelURL.path
            await updateAndPersist(studyID: studyID, result: result)
            return
        }

        result.status = .running
        result.startedAt = Date()
        result.errorMessage = nil
        await updateAndPersist(studyID: studyID, result: result)

        // 1. Load
        let loaded: CohortStudyLoader.LoadedStudy
        do {
            guard let study = studiesByID[studyID] else {
                throw CohortError.worklistEntryMissing(id: studyID)
            }
            let t0 = Date()
            loaded = try await Task.detached(priority: .userInitiated) {
                try CohortStudyLoader.load(study)
            }.value
            result.loadSeconds = Date().timeIntervalSince(t0)
        } catch {
            result.status = .failedLoad
            result.errorMessage = error.localizedDescription
            result.finishedAt = Date()
            await updateAndPersist(studyID: studyID, result: result)
            return
        }

        // 2. Segment
        let labelMap: LabelMap
        do {
            try FileManager.default.createDirectory(at: studyDir, withIntermediateDirectories: true)
            let t0 = Date()
            labelMap = try await runSegmentation(job: checkpoint.job,
                                                 primary: loaded.primary,
                                                 auxiliary: loaded.auxiliary)
            result.segmentationSeconds = Date().timeIntervalSince(t0)
            try LabelIO.saveNIfTIGz(labelMap,
                                    to: labelURL,
                                    parentVolume: loaded.primary,
                                    writeLabelDescriptor: true)
            result.labelMapPath = labelURL.path
        } catch {
            result.status = .failedSegmentation
            result.errorMessage = error.localizedDescription
            result.finishedAt = Date()
            await updateAndPersist(studyID: studyID, result: result)
            return
        }

        // 3. Enumerate lesions + write stats.json
        do {
            let classesToEnumerate: [UInt16]? = checkpoint.job.classifyClassIDs.isEmpty
                ? nil
                : checkpoint.job.classifyClassIDs
            let report = try PETQuantification.compute(
                petVolume: loaded.primary,
                labelMap: labelMap,
                classes: classesToEnumerate,
                connectedComponents: true
            )
            result.lesionCount = report.lesionCount
            result.totalMetabolicTumorVolumeML = report.totalMetabolicTumorVolumeML
            result.maxSUV = report.maxSUV
            result.meanSUV = report.weightedMeanSUV
            let statsURL = studyDir.appendingPathComponent("stats.json")
            try writeStatsJSON(report, to: statsURL)
            result.statsPath = statsURL.path
        } catch {
            // Stats failure is not fatal — we still have a label map.
            // Log the error but don't flip the study into .failed.
            NSLog("Cohort stats failed for \(studyID): \(error.localizedDescription)")
        }

        // 4. Classify (optional)
        if let classifierID = checkpoint.job.classifierEntryID,
           let entry = LesionClassifierCatalog.byID(classifierID) {
            do {
                let t0 = Date()
                let report = try await runClassification(
                    job: checkpoint.job,
                    entry: entry,
                    volume: loaded.primary,
                    labelMap: labelMap
                )
                result.classificationSeconds = Date().timeIntervalSince(t0)

                let reportURL = studyDir.appendingPathComponent("classification.json")
                try writeClassificationReport(report, to: reportURL)
                result.classificationReportPath = reportURL.path

                if let (label, confidence) = argmaxClassification(report) {
                    result.topClassification = label
                    result.topClassificationConfidence = confidence
                }
            } catch {
                // Treat classification failure as non-fatal for the run as
                // a whole — segmentation is already persisted; we mark the
                // study so the user can filter / retry.
                result.status = .failedClassification
                result.errorMessage = "classification: \(error.localizedDescription)"
                result.finishedAt = Date()
                await updateAndPersist(studyID: studyID, result: result)
                return
            }
        }

        result.status = .done
        result.finishedAt = Date()
        await updateAndPersist(studyID: studyID, result: result)
    }

    // MARK: - Segmentation dispatch

    private func runSegmentation(job: CohortJob,
                                 primary: ImageVolume,
                                 auxiliary: [ImageVolume]) async throws -> LabelMap {
        guard let entryID = job.nnunetEntryID,
              let entry = NNUnetCatalog.byID(entryID) else {
            throw CohortError.noSegmenter
        }
        let channels = [primary] + auxiliary

        switch job.segmentationMode {
        case .subprocess:
            let runner = NNUnetRunner()
            let cfg = NNUnetRunner.Configuration(
                predictBinaryPath: nil,
                resultsDir: nil,
                configuration: entry.configuration,
                folds: job.useFullEnsemble ? ["0", "1", "2", "3", "4"] : entry.folds,
                disableTestTimeAugmentation: job.disableTTA
            )
            runner.update(configuration: cfg)
            let result = try await runner.runInference(
                channels: channels,
                referenceVolume: primary,
                datasetID: entry.datasetID
            )
            return result.labelMap

        case .coreML:
            // CoreML is single-channel — cohort CoreML jobs just use the primary.
            throw CohortError.coreMLNotYetSupported

        case .dgxRemote:
            let cfg = DGXSparkConfig.load()
            guard cfg.isConfigured, cfg.enabled else {
                throw CohortError.dgxUnavailable
            }
            let runnerCfg = RemoteNNUnetRunner.Configuration(
                dgx: cfg,
                datasetID: entry.datasetID,
                configuration: entry.configuration,
                folds: job.useFullEnsemble ? ["0", "1", "2", "3", "4"] : entry.folds,
                disableTestTimeAugmentation: job.disableTTA,
                quiet: true
            )
            let runner = RemoteNNUnetRunner(configuration: runnerCfg)
            let result = try await runner.runInference(channels: channels,
                                                       referenceVolume: primary)
            return result.labelMap
        }
    }

    // MARK: - Classification dispatch

    /// Per-study classification report, keyed by connected component id.
    struct StudyClassificationReport: Codable {
        struct LesionRow: Codable {
            var lesionID: Int
            var classID: Int
            var voxelCount: Int
            var volumeML: Double
            var suvMax: Double
            var suvMean: Double
            var tlg: Double
            var classifierID: String
            var classifierDisplayName: String
            var durationSeconds: Double
            var predictions: [Prediction]
            var rationale: String?
        }
        struct Prediction: Codable {
            var label: String
            var probability: Double
        }
        var studyID: String
        var classifierID: String
        var lesions: [LesionRow]
    }

    private func runClassification(job: CohortJob,
                                   entry: LesionClassifierCatalog.Entry,
                                   volume: ImageVolume,
                                   labelMap: LabelMap) async throws -> StudyClassificationReport {
        let classifier = try CohortClassifierFactory.make(job: job, entry: entry)

        let classesToEnumerate: [UInt16]? = job.classifyClassIDs.isEmpty ? nil : job.classifyClassIDs
        let petReport = try PETQuantification.compute(
            petVolume: volume,
            labelMap: labelMap,
            classes: classesToEnumerate,
            connectedComponents: true
        )

        // Snapshot — the cohort UI could be editing the active label map
        // (unlikely during batch run, but defensive).
        let snapshot = labelMap.snapshot(name: "\(labelMap.name) cohort snapshot")

        var rows: [StudyClassificationReport.LesionRow] = []
        rows.reserveCapacity(petReport.lesionCount)

        for (index, lesion) in petReport.lesions.enumerated() {
            let bounds = MONAITransforms.VoxelBounds(
                minZ: lesion.bounds.minZ, maxZ: lesion.bounds.maxZ,
                minY: lesion.bounds.minY, maxY: lesion.bounds.maxY,
                minX: lesion.bounds.minX, maxX: lesion.bounds.maxX
            )
            let classified = try await classifier.classify(
                volume: volume,
                mask: snapshot,
                classID: lesion.classID,
                bounds: bounds
            )
            rows.append(.init(
                lesionID: index + 1,
                classID: Int(lesion.classID),
                voxelCount: lesion.voxelCount,
                volumeML: lesion.volumeML,
                suvMax: lesion.suvMax,
                suvMean: lesion.suvMean,
                tlg: lesion.tlg,
                classifierID: classifier.id,
                classifierDisplayName: classifier.displayName,
                durationSeconds: classified.durationSeconds,
                predictions: classified.predictions.map {
                    .init(label: $0.label, probability: $0.probability)
                },
                rationale: classified.rationale
            ))
        }
        return StudyClassificationReport(
            studyID: checkpoint.results.values.first { $0.status == .running }?.id ?? "",
            classifierID: classifier.id,
            lesions: rows
        )
    }

    private func argmaxClassification(_ report: StudyClassificationReport) -> (label: String, confidence: Double)? {
        guard !report.lesions.isEmpty else { return nil }
        var totals: [String: Double] = [:]
        for lesion in report.lesions {
            for p in lesion.predictions {
                totals[p.label, default: 0] += p.probability
            }
        }
        guard let (label, total) = totals.max(by: { $0.value < $1.value }),
              total > 0 else {
            return nil
        }
        let normalised = total / Double(report.lesions.count)
        return (label, normalised.clamped(to: 0...1))
    }

    // MARK: - File I/O

    private func writeStatsJSON(_ report: PETQuantification.Report, to url: URL) throws {
        struct StatsDTO: Codable {
            struct Lesion: Codable {
                var id: Int
                var classID: Int
                var className: String
                var voxelCount: Int
                var volumeMM3: Double
                var volumeML: Double
                var suvMax: Double
                var suvMean: Double
                var suvPeak: Double
                var tlg: Double
            }
            var totalMetabolicTumorVolumeML: Double
            var totalLesionGlycolysis: Double
            var maxSUV: Double
            var weightedMeanSUV: Double
            var lesionCount: Int
            var lesions: [Lesion]
        }
        let dto = StatsDTO(
            totalMetabolicTumorVolumeML: report.totalMetabolicTumorVolumeML,
            totalLesionGlycolysis: report.totalLesionGlycolysis,
            maxSUV: report.maxSUV,
            weightedMeanSUV: report.weightedMeanSUV,
            lesionCount: report.lesionCount,
            lesions: report.lesions.map { l in
                StatsDTO.Lesion(id: Int(l.id),
                                classID: Int(l.classID),
                                className: l.className,
                                voxelCount: l.voxelCount,
                                volumeMM3: l.volumeMM3,
                                volumeML: l.volumeML,
                                suvMax: l.suvMax,
                                suvMean: l.suvMean,
                                suvPeak: l.suvPeak ?? l.suvMax,
                                tlg: l.tlg)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dto)
        try data.write(to: url, options: [.atomic])
    }

    private func writeClassificationReport(_ report: StudyClassificationReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Checkpoint persistence

    private func updateAndPersist(studyID: String, result: CohortStudyResult) async {
        checkpoint.results[studyID] = result
        checkpoint.updatedAt = Date()
        do {
            try checkpoint.save(to: checkpointURL)
        } catch {
            NSLog("Cohort: checkpoint save failed — \(error.localizedDescription)")
        }
        await onProgress(checkpoint)
    }

}

// MARK: - Async semaphore queue

/// Tiny FIFO that hands out the next study id to each worker task. Uses an
/// actor for serialisation instead of a lock + condition variable; the
/// cohort workers are long-running (minutes each) so the actor-hop cost is
/// utterly negligible.
actor AsyncSemaphoreQueue {
    private var items: [String]

    init(_ items: [String]) { self.items = items }

    func next() -> String? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }
}

// MARK: - Errors

public enum CohortError: Swift.Error, LocalizedError, Sendable {
    case noSegmenter
    case coreMLNotYetSupported
    case dgxUnavailable
    case worklistEntryMissing(id: String)

    public var errorDescription: String? {
        switch self {
        case .noSegmenter:
            return "Cohort job has no nnU-Net entry selected."
        case .coreMLNotYetSupported:
            return "CoreML mode is not yet supported in cohort jobs — use the subprocess or DGX runner."
        case .dgxUnavailable:
            return "DGX Spark is not enabled / configured. Settings → DGX Spark."
        case .worklistEntryMissing(let id):
            return "Study \(id) isn't in the cohort's worklist cache. Call `CohortBatchProcessor.register(studies:)` before running."
        }
    }
}

// MARK: - Helpers

fileprivate extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
