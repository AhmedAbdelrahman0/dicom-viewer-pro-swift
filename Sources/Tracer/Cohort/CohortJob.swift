import Foundation

/// Configuration for one cohort run. A cohort is a batch over a
/// `PACSWorklist` (typically thousands of studies) that segments each study
/// with nnU-Net, optionally classifies lesions, and writes sidecar results
/// to `outputRoot/<studyID>/`.
///
/// `CohortJob` is pure data — no runners, no state. `CohortBatchProcessor`
/// consumes it to build the actual nnU-Net / classifier instances.
public struct CohortJob: Codable, Hashable, Sendable {

    /// Human-readable name for this run. Shown in the UI + used in the
    /// checkpoint filename so the user can keep a few cohorts side-by-side
    /// without clobbering each other.
    public var name: String

    /// Where per-study results go. We write `<outputRoot>/<studyID>/labels.nii.gz`,
    /// `classification.json`, `stats.json` plus the top-level checkpoint file
    /// `<outputRoot>/cohort-<jobID>.json`.
    public var outputRoot: URL

    /// Stable id for the job. Same across relaunches so the checkpoint file
    /// path is deterministic — lets us resume a run after the app crashes.
    public let id: String

    // MARK: - Segmentation

    /// nnU-Net catalog entry id to run. `nil` means "skip segmentation"
    /// (rare — probably only used for classification-only re-runs over
    /// studies that already have label maps on disk).
    public var nnunetEntryID: String?

    /// Mirrors `NNUnetViewModel.Mode`. String-typed so the job config can be
    /// round-tripped through JSON without dragging the full Mode enum into
    /// this module.
    public var segmentationMode: SegmentationMode

    /// Full 5-fold ensemble vs. the catalog entry's default folds. Matches
    /// the toggle in the panel.
    public var useFullEnsemble: Bool

    /// Disable test-time augmentation (~8× faster, tiny quality hit). True
    /// by default because cohort runs care about throughput.
    public var disableTTA: Bool

    // MARK: - Classification

    /// Lesion-classifier catalog entry id. `nil` means "segment only, skip
    /// classification" — still useful for producing TMTV + lesion-count
    /// reports.
    public var classifierEntryID: String?

    /// Paths supplied to the classifier. Mirrors
    /// `ClassificationViewModel.custom…Path`. Kept flat here because the
    /// cohort UI re-uses the single-study ClassificationViewModel to let
    /// the user pick paths once, then copies the values in.
    public var classifierModelPath: String
    public var classifierBinaryPath: String
    public var classifierProjectorPath: String
    public var classifierEnvironment: String
    public var zeroShotPrompts: String
    public var zeroShotLabels: String
    public var zeroShotTokenIDs: String
    public var candidateLabels: String
    public var runClassifierOnDGX: Bool

    /// Class IDs in the predicted label map to enumerate as lesions. Empty
    /// = "every non-zero class found in the output." That's the common case
    /// for multi-class models like AutoPET where every non-background voxel
    /// is a candidate lesion.
    public var classifyClassIDs: [UInt16]

    // MARK: - Runtime

    /// How many studies to process in parallel. DGX-heavy jobs want 1-2
    /// (the GPU is the bottleneck); CPU-only radiomics can push 4-8. Clamped
    /// to [1, 16] at runtime.
    public var maxConcurrent: Int

    /// If true, skip studies whose `<outputRoot>/<studyID>/labels.nii.gz`
    /// already exists. Lets the user re-run only the studies that failed in
    /// a previous batch without re-doing the expensive segmentations.
    public var skipIfResultsExist: Bool

    /// When set, only process studies whose indexed modalities include at
    /// least one of these values (e.g. `["PT"]` to only run on PET studies).
    /// Empty = accept every study in the worklist.
    public var modalityAllowList: [String]

    // MARK: - Optional PET attenuation correction step

    /// `PETACCatalog` entry id to apply to each NAC PET before
    /// segmentation/classification. `nil` = skip AC entirely (the
    /// majority case — most cohorts already have CT-AC PET).
    public var petACEntryID: String?
    /// Local path (or remote-DGX path) to the AC script. Mirrors
    /// `PETACViewModel.scriptPath`.
    public var petACScriptPath: String
    /// Python interpreter for subprocess AC. `/usr/bin/env` is the
    /// default — Tracer prepends `python3` automatically.
    public var petACPythonExecutable: String
    /// `KEY=VALUE` lines exported into the subprocess env (or, for the
    /// DGX backend, the first `activate=…` line is run before the script).
    public var petACEnvironment: String
    /// Extra script arguments appended after the script path, before
    /// `--input` / `--output`.
    public var petACExtraArgs: String
    /// Per-study AC timeout. Generous default — cold-start torch + load
    /// can take 30s; a single 192³ inference adds 5–60s.
    public var petACTimeoutSeconds: Double
    /// Whether to feed an anatomical (CT/MR) channel to the AC model.
    /// Forced on for entries whose `requiresAnatomicalChannel` is true.
    public var petACUseAnatomicalChannel: Bool
    /// **Critical UX toggle.** When `true`, an AC failure on a study is
    /// logged but the study still proceeds to segmentation/classification
    /// using the original NAC PET. When `false`, the study is marked
    /// `failedAttenuationCorrection` and skipped — no segmentation,
    /// no classification. Default: `true` (keep moving on cohorts).
    public var petACFallbackToNACOnFailure: Bool

    public init(id: String = UUID().uuidString,
                name: String = "Cohort run",
                outputRoot: URL,
                nnunetEntryID: String? = nil,
                segmentationMode: SegmentationMode = .subprocess,
                useFullEnsemble: Bool = false,
                disableTTA: Bool = true,
                classifierEntryID: String? = nil,
                classifierModelPath: String = "",
                classifierBinaryPath: String = "",
                classifierProjectorPath: String = "",
                classifierEnvironment: String = "",
                zeroShotPrompts: String = "",
                zeroShotLabels: String = "",
                zeroShotTokenIDs: String = "",
                candidateLabels: String = "",
                runClassifierOnDGX: Bool = false,
                classifyClassIDs: [UInt16] = [],
                maxConcurrent: Int = 2,
                skipIfResultsExist: Bool = true,
                modalityAllowList: [String] = [],
                petACEntryID: String? = nil,
                petACScriptPath: String = "",
                petACPythonExecutable: String = "/usr/bin/env",
                petACEnvironment: String = "",
                petACExtraArgs: String = "",
                petACTimeoutSeconds: Double = 600,
                petACUseAnatomicalChannel: Bool = false,
                petACFallbackToNACOnFailure: Bool = true) {
        self.id = id
        self.name = name
        self.outputRoot = outputRoot
        self.nnunetEntryID = nnunetEntryID
        self.segmentationMode = segmentationMode
        self.useFullEnsemble = useFullEnsemble
        self.disableTTA = disableTTA
        self.classifierEntryID = classifierEntryID
        self.classifierModelPath = classifierModelPath
        self.classifierBinaryPath = classifierBinaryPath
        self.classifierProjectorPath = classifierProjectorPath
        self.classifierEnvironment = classifierEnvironment
        self.zeroShotPrompts = zeroShotPrompts
        self.zeroShotLabels = zeroShotLabels
        self.zeroShotTokenIDs = zeroShotTokenIDs
        self.candidateLabels = candidateLabels
        self.runClassifierOnDGX = runClassifierOnDGX
        self.classifyClassIDs = classifyClassIDs
        self.maxConcurrent = maxConcurrent
        self.skipIfResultsExist = skipIfResultsExist
        self.modalityAllowList = modalityAllowList
        self.petACEntryID = petACEntryID
        self.petACScriptPath = petACScriptPath
        self.petACPythonExecutable = petACPythonExecutable
        self.petACEnvironment = petACEnvironment
        self.petACExtraArgs = petACExtraArgs
        self.petACTimeoutSeconds = petACTimeoutSeconds
        self.petACUseAnatomicalChannel = petACUseAnatomicalChannel
        self.petACFallbackToNACOnFailure = petACFallbackToNACOnFailure
    }

    // MARK: - Backward-compatible decoding

    private enum CodingKeys: String, CodingKey {
        case id, name, outputRoot
        case nnunetEntryID, segmentationMode, useFullEnsemble, disableTTA
        case classifierEntryID, classifierModelPath, classifierBinaryPath
        case classifierProjectorPath, classifierEnvironment
        case zeroShotPrompts, zeroShotLabels, zeroShotTokenIDs, candidateLabels
        case runClassifierOnDGX, classifyClassIDs
        case maxConcurrent, skipIfResultsExist, modalityAllowList
        case petACEntryID, petACScriptPath, petACPythonExecutable
        case petACEnvironment, petACExtraArgs, petACTimeoutSeconds
        case petACUseAnatomicalChannel, petACFallbackToNACOnFailure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Old (pre-AC) checkpoints don't have the `petAC…` keys; default
        // them so resuming a pre-AC cohort still works.
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.outputRoot = try c.decode(URL.self, forKey: .outputRoot)
        self.nnunetEntryID = try c.decodeIfPresent(String.self, forKey: .nnunetEntryID)
        self.segmentationMode = try c.decodeIfPresent(SegmentationMode.self, forKey: .segmentationMode) ?? .subprocess
        self.useFullEnsemble = try c.decodeIfPresent(Bool.self, forKey: .useFullEnsemble) ?? false
        self.disableTTA = try c.decodeIfPresent(Bool.self, forKey: .disableTTA) ?? true
        self.classifierEntryID = try c.decodeIfPresent(String.self, forKey: .classifierEntryID)
        self.classifierModelPath = try c.decodeIfPresent(String.self, forKey: .classifierModelPath) ?? ""
        self.classifierBinaryPath = try c.decodeIfPresent(String.self, forKey: .classifierBinaryPath) ?? ""
        self.classifierProjectorPath = try c.decodeIfPresent(String.self, forKey: .classifierProjectorPath) ?? ""
        self.classifierEnvironment = try c.decodeIfPresent(String.self, forKey: .classifierEnvironment) ?? ""
        self.zeroShotPrompts = try c.decodeIfPresent(String.self, forKey: .zeroShotPrompts) ?? ""
        self.zeroShotLabels = try c.decodeIfPresent(String.self, forKey: .zeroShotLabels) ?? ""
        self.zeroShotTokenIDs = try c.decodeIfPresent(String.self, forKey: .zeroShotTokenIDs) ?? ""
        self.candidateLabels = try c.decodeIfPresent(String.self, forKey: .candidateLabels) ?? ""
        self.runClassifierOnDGX = try c.decodeIfPresent(Bool.self, forKey: .runClassifierOnDGX) ?? false
        self.classifyClassIDs = try c.decodeIfPresent([UInt16].self, forKey: .classifyClassIDs) ?? []
        self.maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 2
        self.skipIfResultsExist = try c.decodeIfPresent(Bool.self, forKey: .skipIfResultsExist) ?? true
        self.modalityAllowList = try c.decodeIfPresent([String].self, forKey: .modalityAllowList) ?? []
        self.petACEntryID = try c.decodeIfPresent(String.self, forKey: .petACEntryID)
        self.petACScriptPath = try c.decodeIfPresent(String.self, forKey: .petACScriptPath) ?? ""
        self.petACPythonExecutable = try c.decodeIfPresent(String.self, forKey: .petACPythonExecutable) ?? "/usr/bin/env"
        self.petACEnvironment = try c.decodeIfPresent(String.self, forKey: .petACEnvironment) ?? ""
        self.petACExtraArgs = try c.decodeIfPresent(String.self, forKey: .petACExtraArgs) ?? ""
        self.petACTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .petACTimeoutSeconds) ?? 600
        self.petACUseAnatomicalChannel = try c.decodeIfPresent(Bool.self, forKey: .petACUseAnatomicalChannel) ?? false
        self.petACFallbackToNACOnFailure = try c.decodeIfPresent(Bool.self, forKey: .petACFallbackToNACOnFailure) ?? true
    }

    /// Stable path for the checkpoint file. Co-located with the results so
    /// they travel together if the user moves the output folder.
    public var checkpointURL: URL {
        outputRoot.appendingPathComponent("cohort-\(id).json")
    }

    public func outputDirectory(for studyID: String) -> URL {
        outputRoot.appendingPathComponent(Self.sanitize(studyID), isDirectory: true)
    }

    /// Strip characters filesystems (especially network shares) choke on
    /// when a study id is used as a directory name. DICOM study UIDs are
    /// dotted numeric strings which are already safe; this is belt-and-
    /// braces in case a synthetic id has a `/` in it.
    private static func sanitize(_ id: String) -> String {
        let disallowed: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        return String(id.map { disallowed.contains($0) ? "_" : $0 })
    }
}

/// String-typed mirror of `NNUnetViewModel.Mode`. Lives in the cohort module
/// because `CohortJob` round-trips through JSON and we don't want the Mode
/// enum (which only exists in an @MainActor file) leaking into Codable land.
public enum SegmentationMode: String, Codable, CaseIterable, Sendable {
    case subprocess
    case coreML
    case dgxRemote

    public var displayName: String {
        switch self {
        case .subprocess: return "Python (local)"
        case .coreML:     return "CoreML on-device"
        case .dgxRemote:  return "DGX Spark (remote)"
        }
    }
}
