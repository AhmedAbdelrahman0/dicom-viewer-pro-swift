import Foundation

/// The engine that actually runs a cohort. Takes a `CohortJob` + a list of
/// `PACSWorklistStudy`, and processes each study end-to-end:
///
///   1. Load primary (and optional aux) volume from disk
///   2. Run nnU-Net segmentation (local, CoreML, or remote workstation)
///   3. Enumerate connected components via `PETQuantification.compute`
///   4. Optionally run the per-lesion classifier
///   5. Write `<outputRoot>/<studyID>/{labels.nii.gz, stats.json, classification.json}`
///   6. Update the checkpoint file atomically
///
/// Concurrency model: an `actor` owns the mutable checkpoint + progress
/// state. Studies run as child `Task`s with a bounded semaphore so remote
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

        let requestedWorkers = max(1, min(16, job.maxConcurrent))
        let policy = ResourcePolicy.load()
        let cohortBound = policy.boundedCohortWorkers(requested: requestedWorkers)
        let mayUseLocalGPU = job.nnunetEntryID != nil && job.segmentationMode != .dgxRemote
        let workers = mayUseLocalGPU ? min(cohortBound, policy.gpuWorkerLimit) : cohortBound
        if workers != checkpoint.job.maxConcurrent {
            checkpoint.job.maxConcurrent = workers
            try? checkpoint.save(to: checkpointURL)
            await onProgress(checkpoint)
        }
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
        var loaded: CohortStudyLoader.LoadedStudy
        do {
            guard let study = studiesByID[studyID] else {
                throw CohortError.worklistEntryMissing(id: studyID)
            }
            let t0 = Date()
            loaded = try await Task.detached(priority: ResourcePolicy.load().backgroundTaskPriority) {
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

        // 1b. Optional: PET attenuation correction. When the job has an AC
        // entry configured, run it on the NAC PET in `loaded` and swap the
        // AC PET back into the load set so segmentation + quantification +
        // classification all see the corrected values. Failure handling
        // depends on `petACFallbackToNACOnFailure` — see the toggle's docs.
        if let acID = checkpoint.job.petACEntryID,
           let acEntry = PETACCatalog.byID(acID) {
            let acOutcome = await runAttenuationCorrection(
                job: checkpoint.job,
                entry: acEntry,
                loaded: loaded,
                studyDir: studyDir
            )
            switch acOutcome {
            case .success(let acRun):
                loaded = loaded.replacingPET(with: acRun.acPET)
                result.attenuationCorrectionSeconds = acRun.durationSeconds
                result.attenuationCorrectionPath = acRun.persistedPath
                result.attenuationCorrectionFallbackToNAC = false
                result.attenuationCorrectionLog = acRun.logSnippet
            case .failedFallback(let message):
                result.attenuationCorrectionSeconds = nil
                result.attenuationCorrectionPath = nil
                result.attenuationCorrectionFallbackToNAC = true
                result.attenuationCorrectionLog = message
                NSLog("Cohort AC failed for \(studyID), continuing on NAC: \(message)")
            case .failedAbort(let message):
                result.status = .failedAttenuationCorrection
                result.attenuationCorrectionFallbackToNAC = false
                result.attenuationCorrectionLog = message
                result.errorMessage = message
                result.finishedAt = Date()
                await updateAndPersist(studyID: studyID, result: result)
                return
            }
        }

        // 2. Segment
        let labelMap: LabelMap
        do {
            try FileManager.default.createDirectory(at: studyDir, withIntermediateDirectories: true)
            let t0 = Date()
            labelMap = try await runSegmentation(job: checkpoint.job, loaded: loaded)
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
                petVolume: loaded.quantificationVolume,
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
                guard let classificationVolume = loaded.classificationVolume(for: entry.modality) else {
                    throw CohortError.classificationVolumeMissing(expected: entry.modality?.displayName ?? "selected")
                }
                let t0 = Date()
                let report = try await runClassification(
                    studyID: studyID,
                    job: checkpoint.job,
                    entry: entry,
                    volume: classificationVolume,
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

    // MARK: - Attenuation correction dispatch

    /// Outcome of the per-study AC step. Three terminal shapes; the caller
    /// decides what to do with each.
    enum ACStepOutcome {
        /// AC ran cleanly. The new PET is in `acPET`, persisted at
        /// `persistedPath`, and timing/log are surfaced into the result row.
        case success(ACSuccess)
        /// AC failed AND `petACFallbackToNACOnFailure` is true. Caller
        /// continues the pipeline on the original NAC; the row is flagged.
        case failedFallback(message: String)
        /// AC failed AND fallback is disabled. Caller marks the study
        /// `failedAttenuationCorrection` and skips segmentation/classification.
        case failedAbort(message: String)
    }

    struct ACSuccess: Sendable {
        let acPET: ImageVolume
        let persistedPath: String?
        let durationSeconds: Double
        let logSnippet: String?
    }

    /// Locate the PET channel, run the configured AC corrector, persist
    /// the result as `<studyDir>/ac.nii.gz`, and return an outcome that
    /// honours the job's NAC-fallback policy.
    private func runAttenuationCorrection(job: CohortJob,
                                          entry: PETACCatalog.Entry,
                                          loaded: CohortStudyLoader.LoadedStudy,
                                          studyDir: URL) async -> ACStepOutcome {
        // Find the PET volume in the load set. PET-only → primary;
        // PET/CT → first auxiliary PET. Other configurations have no
        // PET to correct, so AC is a no-op (we just return success
        // with the original PET so timing fields stay nil and the row
        // doesn't claim it ran AC when it didn't).
        let petVolume: ImageVolume? = {
            if Modality.normalize(loaded.primary.modality) == .PT { return loaded.primary }
            return loaded.auxiliary.first { Modality.normalize($0.modality) == .PT }
        }()
        guard let petVolume else {
            // No PET to correct — silently skip without claiming AC ran.
            return .failedFallback(message: "No PET channel found in the study; AC skipped.")
        }

        // Pick an anatomical channel if the entry needs one (or the
        // toggle is on). Same priority as the per-study panel.
        let anatomical: ImageVolume? = {
            guard entry.requiresAnatomicalChannel || job.petACUseAnatomicalChannel else {
                return nil
            }
            // Prefer CT/MR primary in PET/CT loads.
            if Modality.normalize(loaded.primary.modality) != .PT { return loaded.primary }
            return loaded.auxiliary.first {
                let m = Modality.normalize($0.modality)
                return m == .CT || m == .MR
            }
        }()

        // Build the corrector + run.
        let corrector: PETAttenuationCorrector
        do {
            corrector = try CohortPETACFactory.make(job: job, entry: entry)
        } catch {
            let message = "AC corrector init failed: \(error.localizedDescription)"
            return job.petACFallbackToNACOnFailure
                ? .failedFallback(message: message)
                : .failedAbort(message: message)
        }

        do {
            // Progress sink swallowed at cohort level — the per-study
            // panel surfaces it for interactive runs; cohort runs would
            // overwhelm the UI, so we keep just the final logSnippet.
            let acResult = try await corrector.attenuationCorrect(
                nacPET: petVolume,
                anatomical: anatomical,
                progress: { _ in }
            )
            // Persist next to the segmentation. Same atomic-write pattern.
            try FileManager.default.createDirectory(at: studyDir,
                                                    withIntermediateDirectories: true)
            let acURL = studyDir.appendingPathComponent("ac.nii.gz")
            do {
                let raw = try acVolumeToNIfTI(acResult.acPET)
                try raw.write(to: acURL, options: [.atomic])
                return .success(ACSuccess(
                    acPET: acResult.acPET,
                    persistedPath: acURL.path,
                    durationSeconds: acResult.durationSeconds,
                    logSnippet: acResult.logSnippet
                ))
            } catch {
                // AC produced a volume but we couldn't persist it — still
                // a success because the in-memory PET is good and the
                // pipeline can continue. Caller sees `persistedPath = nil`.
                NSLog("Cohort AC: persist failed for \(acURL.path) — \(error.localizedDescription)")
                return .success(ACSuccess(
                    acPET: acResult.acPET,
                    persistedPath: nil,
                    durationSeconds: acResult.durationSeconds,
                    logSnippet: acResult.logSnippet
                ))
            }
        } catch {
            let message = "AC inference failed: \(error.localizedDescription)"
            return job.petACFallbackToNACOnFailure
                ? .failedFallback(message: message)
                : .failedAbort(message: message)
        }
    }

    /// Encode an `ImageVolume` as gzip-compressed NIfTI bytes. Tracer's
    /// `NIfTIWriter` writes uncompressed `.nii`; for cohort sidecars we
    /// gzip via `LabelIO.gzip(_:)` so the output is `.nii.gz` like every
    /// other piece of label/segmentation data the cohort emits.
    private func acVolumeToNIfTI(_ volume: ImageVolume) throws -> Data {
        // Write uncompressed to a temp file (`NIfTIWriter` only supports
        // file output today), read back, gzip. One alloc per study.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-ac-encode-\(UUID().uuidString).nii")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try NIfTIWriter.write(volume, to: tmp)
        let raw = try Data(contentsOf: tmp)
        return try LabelIO.gzip(raw)
    }

    // MARK: - Segmentation dispatch

    private func runSegmentation(job: CohortJob,
                                 loaded: CohortStudyLoader.LoadedStudy) async throws -> LabelMap {
        guard let entryID = job.nnunetEntryID,
              let entry = NNUnetCatalog.byID(entryID) else {
            throw CohortError.noSegmenter
        }
        let channels = loaded.segmentationChannels(for: entry)

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
                referenceVolume: loaded.primary,
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
                                                       referenceVolume: loaded.primary)
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

    private func runClassification(studyID: String,
                                   job: CohortJob,
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
            studyID: studyID,
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
    case classificationVolumeMissing(expected: String)

    public var errorDescription: String? {
        switch self {
        case .noSegmenter:
            return "Cohort job has no nnU-Net entry selected."
        case .coreMLNotYetSupported:
            return "CoreML mode is not yet supported in cohort jobs — use the subprocess or remote runner."
        case .dgxUnavailable:
            return "Remote workstation is not enabled / configured. Settings -> Remote Workstation."
        case .worklistEntryMissing(let id):
            return "Study \(id) isn't in the cohort's worklist cache. Call `CohortBatchProcessor.register(studies:)` before running."
        case .classificationVolumeMissing(let expected):
            return "Classifier expected a \(expected) volume for this study, but it isn't available in the cohort load set."
        }
    }
}

// MARK: - Helpers

fileprivate extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
