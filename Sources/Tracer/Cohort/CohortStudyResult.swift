import Foundation

/// Per-study outcome from a cohort run. Codable so it sits in the checkpoint
/// file; Equatable so the UI can diff for table updates.
public struct CohortStudyResult: Codable, Hashable, Sendable, Identifiable {
    public let id: String                    // = PACSWorklistStudy.id (study key)
    public var patientID: String
    public var patientName: String
    public var studyDescription: String
    public var studyDate: String
    public var modalities: [String]
    public var sourcePath: String

    public var status: Status
    public var errorMessage: String?
    public var startedAt: Date?
    public var finishedAt: Date?

    /// Recorded timings — all in seconds, fractional. nil if the stage
    /// didn't run (e.g. classification skipped because job had no
    /// classifier entry).
    public var loadSeconds: Double?
    public var segmentationSeconds: Double?
    public var classificationSeconds: Double?

    // Segmentation-level stats, pulled from PETQuantification's report.
    public var lesionCount: Int?
    public var totalMetabolicTumorVolumeML: Double?
    public var maxSUV: Double?
    public var meanSUV: Double?

    /// Paths on disk, written under
    /// `<outputRoot>/<studyID>/`. Relative would be nicer but the cohort
    /// UI needs absolute URLs to open a file externally, so we store the
    /// absolute path and the caller-side code can rewrite them if the
    /// output root moves.
    public var labelMapPath: String?
    public var statsPath: String?
    public var classificationReportPath: String?

    /// Top classified label across all lesions (argmax of the sum of
    /// per-lesion probabilities). Useful for cohort-level histograms /
    /// sortable columns.
    public var topClassification: String?
    public var topClassificationConfidence: Double?

    // MARK: - Optional PET attenuation correction step

    /// Wall-clock seconds the AC step took. nil if AC wasn't part of
    /// the job, or if the AC step failed before producing a result.
    public var attenuationCorrectionSeconds: Double?
    /// Path to the AC PET sidecar written under `<studyDir>/ac.nii.gz`.
    /// nil when AC didn't run or fell back to NAC.
    public var attenuationCorrectionPath: String?
    /// Set when the job had AC enabled, AC failed for this study, AND
    /// `petACFallbackToNACOnFailure` is on. The downstream segmentation
    /// + classification ran on NAC; a column in the cohort CSV flags it
    /// so the user can quarantine those rows in their analysis.
    public var attenuationCorrectionFallbackToNAC: Bool?
    /// Last-line stderr / model log from the AC step. nil = no signal
    /// either way; empty string = AC ran cleanly.
    public var attenuationCorrectionLog: String?

    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case running
        case done
        case failedLoad
        case failedAttenuationCorrection   // AC failed AND fallback was disabled
        case failedSegmentation
        case failedClassification
        case cancelled
        case skipped            // for `skipIfResultsExist` where the study was already done on a previous run

        public var displayName: String {
            switch self {
            case .pending:                       return "Pending"
            case .running:                       return "Running"
            case .done:                          return "Done"
            case .failedLoad:                    return "Load failed"
            case .failedAttenuationCorrection:   return "AC failed"
            case .failedSegmentation:            return "Segmentation failed"
            case .failedClassification:          return "Classification failed"
            case .cancelled:                     return "Cancelled"
            case .skipped:                       return "Skipped"
            }
        }

        public var isTerminal: Bool {
            switch self {
            case .done, .failedLoad, .failedAttenuationCorrection,
                 .failedSegmentation, .failedClassification, .skipped:
                return true
            case .pending, .running, .cancelled:
                return false
            }
        }

        public var isFailure: Bool {
            switch self {
            case .failedLoad, .failedAttenuationCorrection,
                 .failedSegmentation, .failedClassification:
                return true
            default:
                return false
            }
        }
    }

    public init(study: PACSWorklistStudy,
                status: Status = .pending) {
        self.id = study.id
        self.patientID = study.patientID
        self.patientName = study.patientName
        self.studyDescription = study.studyDescription
        self.studyDate = study.studyDate
        self.modalities = study.modalities
        self.sourcePath = study.sourcePath
        self.status = status
    }

    /// Minimal initializer for tests / hand-crafted rows.
    public init(id: String,
                patientID: String = "",
                patientName: String = "",
                studyDescription: String = "",
                studyDate: String = "",
                modalities: [String] = [],
                sourcePath: String = "",
                status: Status = .pending) {
        self.id = id
        self.patientID = patientID
        self.patientName = patientName
        self.studyDescription = studyDescription
        self.studyDate = studyDate
        self.modalities = modalities
        self.sourcePath = sourcePath
        self.status = status
    }
}

/// Top-level cohort checkpoint. One per job; persists the whole
/// `[studyID → CohortStudyResult]` map plus the job config that produced it.
public struct CohortCheckpoint: Codable, Sendable {
    public var job: CohortJob
    public var results: [String: CohortStudyResult]
    public var createdAt: Date
    public var updatedAt: Date

    public init(job: CohortJob,
                results: [String: CohortStudyResult] = [:],
                createdAt: Date = Date()) {
        self.job = job
        self.results = results
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    // MARK: - I/O

    public static func load(from url: URL) throws -> CohortCheckpoint {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CohortCheckpoint.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        // Atomic write so a SIGKILL mid-flush never leaves the user with
        // a half-written checkpoint (which decoding would refuse to load).
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Aggregates

    public var total: Int { results.count }

    public var doneCount: Int {
        results.values.reduce(0) { $0 + ($1.status == .done ? 1 : 0) }
    }

    public var failedCount: Int {
        results.values.reduce(0) { $0 + ($1.status.isFailure ? 1 : 0) }
    }

    public var skippedCount: Int {
        results.values.reduce(0) { $0 + ($1.status == .skipped ? 1 : 0) }
    }

    public var pendingCount: Int {
        results.values.reduce(0) { $0 + ($1.status == .pending ? 1 : 0) }
    }

    public var runningCount: Int {
        results.values.reduce(0) { $0 + ($1.status == .running ? 1 : 0) }
    }

    /// Mean wall-clock per completed study. Useful for computing an ETA.
    public var meanStudyDuration: Double? {
        let completions = results.values.compactMap { r -> Double? in
            guard r.status == .done,
                  let s = r.startedAt, let f = r.finishedAt else { return nil }
            return f.timeIntervalSince(s)
        }
        guard !completions.isEmpty else { return nil }
        return completions.reduce(0, +) / Double(completions.count)
    }

    /// Histogram of `topClassification` across done studies. Empty when
    /// the job didn't run classification.
    public var classificationHistogram: [(label: String, count: Int)] {
        let labels = results.values.compactMap { $0.topClassification }
        let counts = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count)
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}
