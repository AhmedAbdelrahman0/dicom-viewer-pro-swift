import Foundation
import SwiftUI

/// MainActor-side wrapper around a `CohortCheckpoint` — the piece of state
/// that SwiftUI binds to. The `CohortBatchProcessor` publishes updates via
/// its `onProgress` closure; this store takes those updates and re-publishes
/// as `@Published` so views can observe them.
///
/// Also provides aggregate accessors (done/failed counts, ETA, histogram)
/// so the cohort panel doesn't have to re-derive them on every redraw.
@MainActor
public final class CohortResultsStore: ObservableObject {

    @Published public private(set) var checkpoint: CohortCheckpoint?
    @Published public private(set) var isRunning: Bool = false
    @Published public var statusMessage: String = ""

    /// Kept strong so the Task that runs `processor.run()` doesn't get
    /// dropped mid-flight when the UI goes elsewhere. Nilled on completion
    /// or cancellation.
    private var activeTask: Task<Void, Never>?
    private var activeProcessor: CohortBatchProcessor?

    public init() {}

    // MARK: - Progress derivations

    public var progressFraction: Double {
        guard let cp = checkpoint, cp.total > 0 else { return 0 }
        let finished = cp.doneCount + cp.failedCount + cp.skippedCount
        return Double(finished) / Double(cp.total)
    }

    public var etaSeconds: Double? {
        guard let cp = checkpoint,
              let mean = cp.meanStudyDuration,
              cp.pendingCount > 0 else {
            return nil
        }
        // Divide by max-concurrent because workers run in parallel. Round
        // up so we don't tell the user "done in 0 minutes".
        let workers = max(1, Double(cp.job.maxConcurrent))
        return (mean * Double(cp.pendingCount)) / workers
    }

    public var etaString: String? {
        guard let seconds = etaSeconds else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds)
    }

    // MARK: - Lifecycle

    /// Start a fresh cohort run. Destroys any in-flight run first.
    public func start(job: CohortJob,
                      studies: [PACSWorklistStudy]) {
        cancel()
        statusMessage = "Preparing cohort \(job.name)…"
        do {
            let processor = try CohortBatchProcessor(
                job: job,
                studies: studies,
                onProgress: { [weak self] updated in
                    Task { @MainActor in
                        self?.checkpoint = updated
                        self?.statusMessage = Self.formatStatus(updated)
                    }
                }
            )
            self.activeProcessor = processor
            // Seed the checkpoint immediately so the UI shows "0/2000 queued"
            // before the first study finishes. We capture processor (a
            // Sendable actor reference) instead of `self` so the Task body
            // stays Sendable; we MainActor-hop back to write @Published
            // state.
            Task { [weak self] in
                let seeded = await processor.currentCheckpoint()
                await MainActor.run {
                    self?.checkpoint = seeded
                }
            }
            isRunning = true
            activeTask = Task.detached(priority: .userInitiated) { [weak self] in
                await processor.run()
                await self?.markRunFinished()
            }
        } catch {
            statusMessage = "Failed to start cohort: \(error.localizedDescription)"
        }
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isRunning = false
        statusMessage = "Cohort cancelled."
    }

    /// Called on the MainActor when the detached run Task returns.
    /// Having this as a named method (rather than an inline closure) keeps
    /// Swift 6 concurrency checking happy — the compiler knows a class
    /// method hop is actor-safe, whereas capturing `self?.isRunning` inside
    /// a `MainActor.run { }` closure triggers a "var self captured" warning.
    private func markRunFinished() {
        isRunning = false
        activeTask = nil
    }

    /// Re-queue failed studies in-place. Flips them back to .pending so
    /// the next `start()` picks them up; works with `skipIfResultsExist=true`
    /// to cheaply retry only the broken studies in a 2000-case run.
    public func markFailedForRetry() {
        guard var cp = checkpoint else { return }
        for (id, result) in cp.results where result.status.isFailure {
            var updated = result
            updated.status = .pending
            updated.errorMessage = nil
            updated.finishedAt = nil
            cp.results[id] = updated
        }
        checkpoint = cp
        if let url = checkpoint?.job.checkpointURL {
            try? checkpoint?.save(to: url)
        }
    }

    /// Load a previously-saved checkpoint from disk without starting a run.
    /// Used by "Resume cohort from folder" flows and by the cohort panel
    /// when the user returns to an old run.
    public func load(checkpointURL: URL) {
        do {
            checkpoint = try CohortCheckpoint.load(from: checkpointURL)
            statusMessage = "Loaded checkpoint (\(checkpoint?.total ?? 0) studies)"
        } catch {
            statusMessage = "Checkpoint load failed: \(error.localizedDescription)"
            checkpoint = nil
        }
    }

    // MARK: - Export

    /// Write a single CSV combining every study's top-line classification +
    /// quantification. Columns match what you'd want for a spreadsheet
    /// cohort analysis. Returns the written URL on success.
    public func exportCohortCSV(to url: URL) throws {
        guard let cp = checkpoint else {
            throw CohortExportError.noCheckpoint
        }
        var csv = [
            "study_id",
            "patient_id",
            "patient_name",
            "study_date",
            "study_description",
            "modalities",
            "status",
            "lesion_count",
            "tmtv_ml",
            "suv_max",
            "suv_mean",
            "top_classification",
            "top_classification_confidence",
            "load_sec",
            "ac_sec",
            "ac_fallback_to_nac",
            "ac_path",
            "segmentation_sec",
            "classification_sec",
            "error",
            "labels_path",
            "classification_report_path"
        ].joined(separator: ",") + "\n"

        let sorted = cp.results.values.sorted { $0.studyDate < $1.studyDate }
        for r in sorted {
            csv.append(Self.csvRow(for: r))
            csv.append("\n")
        }

        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Internals

    private static func formatStatus(_ cp: CohortCheckpoint) -> String {
        let done = cp.doneCount
        let failed = cp.failedCount
        let skipped = cp.skippedCount
        let total = cp.total
        if cp.pendingCount == 0 && cp.runningCount == 0 {
            return "Cohort complete — \(done)/\(total) done, \(failed) failed, \(skipped) skipped"
        }
        return "Cohort: \(done)/\(total) done, \(cp.runningCount) running, \(failed) failed"
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return s
    }

    /// Builds one CSV line for a study result. Split out of the main
    /// export loop because the concatenation expression was complex enough
    /// that the Swift compiler hit the "unable to type-check in reasonable
    /// time" bailout; keeping each column on its own line + `.joined` is
    /// trivial for the solver.
    private static func csvRow(for r: CohortStudyResult) -> String {
        var columns: [String] = []
        columns.reserveCapacity(22)
        columns.append(csvEscape(r.id))
        columns.append(csvEscape(r.patientID))
        columns.append(csvEscape(r.patientName))
        columns.append(csvEscape(r.studyDate))
        columns.append(csvEscape(r.studyDescription))
        columns.append(csvEscape(r.modalities.joined(separator: "/")))
        columns.append(csvEscape(r.status.rawValue))
        columns.append(r.lesionCount.map(String.init) ?? "")
        columns.append(r.totalMetabolicTumorVolumeML.map { String(format: "%.3f", $0) } ?? "")
        columns.append(r.maxSUV.map { String(format: "%.3f", $0) } ?? "")
        columns.append(r.meanSUV.map { String(format: "%.3f", $0) } ?? "")
        columns.append(csvEscape(r.topClassification ?? ""))
        columns.append(r.topClassificationConfidence.map { String(format: "%.4f", $0) } ?? "")
        columns.append(r.loadSeconds.map { String(format: "%.2f", $0) } ?? "")
        // PET AC step (3 columns inserted between load and segmentation so
        // the column order matches the pipeline order in the processor).
        // ac_fallback_to_nac is "true" / "false" / "" — empty when the
        // job didn't include AC at all.
        columns.append(r.attenuationCorrectionSeconds.map { String(format: "%.2f", $0) } ?? "")
        columns.append(r.attenuationCorrectionFallbackToNAC.map { $0 ? "true" : "false" } ?? "")
        columns.append(csvEscape(r.attenuationCorrectionPath ?? ""))
        columns.append(r.segmentationSeconds.map { String(format: "%.2f", $0) } ?? "")
        columns.append(r.classificationSeconds.map { String(format: "%.2f", $0) } ?? "")
        columns.append(csvEscape(r.errorMessage ?? ""))
        columns.append(csvEscape(r.labelMapPath ?? ""))
        columns.append(csvEscape(r.classificationReportPath ?? ""))
        return columns.joined(separator: ",")
    }
}

public enum CohortExportError: Swift.Error, LocalizedError, Sendable {
    case noCheckpoint

    public var errorDescription: String? {
        switch self {
        case .noCheckpoint: return "No cohort loaded yet."
        }
    }
}
