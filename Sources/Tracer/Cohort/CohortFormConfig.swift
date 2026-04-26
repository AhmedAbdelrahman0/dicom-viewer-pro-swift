import Foundation

/// Pure-data snapshot of every cohort form field. Codable so it can be:
///   • Persisted as a draft to `UserDefaults["Tracer.Cohort.Draft"]`
///     (auto-saved on every change so the user doesn't lose a 12-field
///     configuration when the inspector closes)
///   • Saved as a named preset under `UserDefaults["Tracer.Cohort.Presets"]`
///     for cohorts that the user runs repeatedly (e.g. "AutoPET DGX run",
///     "Local lung CT cohort")
///   • Round-tripped into a `CohortJob` for the batch processor
///
/// Keep this struct pure-data. View state (sort column, whether the panel
/// is showing the results table) lives on the View itself; cohort run state
/// (progress, checkpoint) lives on `CohortResultsStore`. The line is:
/// **if it goes into the JSON config the user might save and reload, it
/// belongs here**.
public struct CohortFormConfig: Codable, Hashable, Sendable {

    // MARK: - Job basics

    public var jobName: String
    public var outputRoot: String
    public var modalityFilter: String
    public var maxConcurrent: Int
    public var skipIfResultsExist: Bool

    // MARK: - Segmentation

    public var nnunetEntryID: String
    public var segmentationMode: SegmentationMode
    public var useFullEnsemble: Bool
    public var disableTTA: Bool

    // MARK: - Classification (the entry id; the paths come from the
    // separately-persisted ClassificationViewModel config so users
    // configure them once and reuse across cohorts).

    public var classifierEntryID: String

    // MARK: - PET attenuation correction (optional pre-segmentation step)

    public var petACEntryID: String
    public var petACScriptPath: String
    public var petACPythonExecutable: String
    public var petACEnvironment: String
    public var petACExtraArgs: String
    public var petACTimeoutSeconds: Double
    public var petACUseAnatomicalChannel: Bool
    public var petACFallbackToNACOnFailure: Bool

    public init(jobName: String = "Cohort run",
                outputRoot: String = "",
                modalityFilter: String = "All",
                maxConcurrent: Int = 2,
                skipIfResultsExist: Bool = true,
                nnunetEntryID: String = NNUnetCatalog.all.first?.id ?? "",
                segmentationMode: SegmentationMode = .subprocess,
                useFullEnsemble: Bool = false,
                disableTTA: Bool = true,
                classifierEntryID: String = "",
                petACEntryID: String = "",
                petACScriptPath: String = "",
                petACPythonExecutable: String = "/usr/bin/env",
                petACEnvironment: String = "",
                petACExtraArgs: String = "",
                petACTimeoutSeconds: Double = 600,
                petACUseAnatomicalChannel: Bool = false,
                petACFallbackToNACOnFailure: Bool = true) {
        self.jobName = jobName
        self.outputRoot = outputRoot
        self.modalityFilter = modalityFilter
        self.maxConcurrent = maxConcurrent
        self.skipIfResultsExist = skipIfResultsExist
        self.nnunetEntryID = nnunetEntryID
        self.segmentationMode = segmentationMode
        self.useFullEnsemble = useFullEnsemble
        self.disableTTA = disableTTA
        self.classifierEntryID = classifierEntryID
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

    /// Older drafts / presets won't have every key (we add fields over
    /// time). `decodeIfPresent` with explicit defaults means a v1 draft
    /// loads into v2 cleanly — same pattern we use for `CohortJob` itself.
    private enum CodingKeys: String, CodingKey {
        case jobName, outputRoot, modalityFilter, maxConcurrent, skipIfResultsExist
        case nnunetEntryID, segmentationMode, useFullEnsemble, disableTTA
        case classifierEntryID
        case petACEntryID, petACScriptPath, petACPythonExecutable
        case petACEnvironment, petACExtraArgs, petACTimeoutSeconds
        case petACUseAnatomicalChannel, petACFallbackToNACOnFailure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jobName = try c.decodeIfPresent(String.self, forKey: .jobName) ?? "Cohort run"
        self.outputRoot = try c.decodeIfPresent(String.self, forKey: .outputRoot) ?? ""
        self.modalityFilter = try c.decodeIfPresent(String.self, forKey: .modalityFilter) ?? "All"
        self.maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 2
        self.skipIfResultsExist = try c.decodeIfPresent(Bool.self, forKey: .skipIfResultsExist) ?? true
        self.nnunetEntryID = try c.decodeIfPresent(String.self, forKey: .nnunetEntryID)
            ?? (NNUnetCatalog.all.first?.id ?? "")
        self.segmentationMode = try c.decodeIfPresent(SegmentationMode.self, forKey: .segmentationMode) ?? .subprocess
        self.useFullEnsemble = try c.decodeIfPresent(Bool.self, forKey: .useFullEnsemble) ?? false
        self.disableTTA = try c.decodeIfPresent(Bool.self, forKey: .disableTTA) ?? true
        self.classifierEntryID = try c.decodeIfPresent(String.self, forKey: .classifierEntryID) ?? ""
        self.petACEntryID = try c.decodeIfPresent(String.self, forKey: .petACEntryID) ?? ""
        self.petACScriptPath = try c.decodeIfPresent(String.self, forKey: .petACScriptPath) ?? ""
        self.petACPythonExecutable = try c.decodeIfPresent(String.self, forKey: .petACPythonExecutable) ?? "/usr/bin/env"
        self.petACEnvironment = try c.decodeIfPresent(String.self, forKey: .petACEnvironment) ?? ""
        self.petACExtraArgs = try c.decodeIfPresent(String.self, forKey: .petACExtraArgs) ?? ""
        self.petACTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .petACTimeoutSeconds) ?? 600
        self.petACUseAnatomicalChannel = try c.decodeIfPresent(Bool.self, forKey: .petACUseAnatomicalChannel) ?? false
        self.petACFallbackToNACOnFailure = try c.decodeIfPresent(Bool.self, forKey: .petACFallbackToNACOnFailure) ?? true
    }

    // MARK: - Build

    /// Translate the form snapshot into a `CohortJob` ready for the batch
    /// processor. Trims whitespace from text fields and resolves the
    /// modality filter to either an empty allow-list (`"All"`) or a
    /// single-element allow-list. Output folder tilde is expanded.
    ///
    /// Pure function — no UserDefaults reads, no view-model state. That
    /// makes `buildJob` fully testable: feed it a config, assert on the
    /// resulting `CohortJob` fields.
    public func buildJob() -> CohortJob {
        let expandedOutput = (outputRoot as NSString).expandingTildeInPath
        let outputURL = URL(fileURLWithPath: expandedOutput)
        let allowList: [String] = (modalityFilter == "All" || modalityFilter.isEmpty)
            ? []
            : [modalityFilter]
        let trimmedName = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        return CohortJob(
            name: trimmedName.isEmpty ? "Cohort run" : trimmedName,
            outputRoot: outputURL,
            nnunetEntryID: nnunetEntryID.isEmpty ? nil : nnunetEntryID,
            segmentationMode: segmentationMode,
            useFullEnsemble: useFullEnsemble,
            disableTTA: disableTTA,
            classifierEntryID: classifierEntryID.isEmpty ? nil : classifierEntryID,
            maxConcurrent: maxConcurrent,
            skipIfResultsExist: skipIfResultsExist,
            modalityAllowList: allowList,
            petACEntryID: petACEntryID.isEmpty ? nil : petACEntryID,
            petACScriptPath: petACScriptPath,
            petACPythonExecutable: petACPythonExecutable,
            petACEnvironment: petACEnvironment,
            petACExtraArgs: petACExtraArgs,
            petACTimeoutSeconds: petACTimeoutSeconds,
            petACUseAnatomicalChannel: petACUseAnatomicalChannel,
            petACFallbackToNACOnFailure: petACFallbackToNACOnFailure
        )
    }

    // MARK: - Validation

    /// Returns the first user-facing problem with this config, if any.
    /// `nil` means the form is ready to run. Used by the panel to disable
    /// the Run button + tooltip the reason.
    public func validationError(filteredStudyCount: Int) -> String? {
        if outputRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Pick an output folder for cohort results."
        }
        if filteredStudyCount == 0 {
            return "No studies match the current filters."
        }
        if nnunetEntryID.isEmpty {
            return "Pick an nnU-Net dataset to segment with."
        }
        if !petACEntryID.isEmpty,
           petACScriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "AC step is on but no script path is set."
        }
        return nil
    }
}

/// A user-named cohort configuration — wraps a `CohortFormConfig` with an
/// id, display name, and timestamps. Persisted as a `[CohortPreset]` array
/// under `UserDefaults["Tracer.Cohort.Presets"]`.
///
/// Tracer also defines a small set of **built-in presets** (currently just
/// `Defaults`) that are loadable but can't be renamed, updated, deleted,
/// or persisted — they're computed in code so they can't be lost or
/// shadowed by a user-created preset with the same name. Use `isBuiltIn`
/// to gate the UI's mutate-actions.
public struct CohortPreset: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    public var config: CohortFormConfig

    public init(id: UUID = UUID(),
                name: String,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                config: CohortFormConfig) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.config = config
    }

    // MARK: - Built-ins

    /// Stable id for the "Defaults" sentinel preset. Hard-coded UUID so
    /// it survives across launches without needing persistence and so we
    /// can recognize it in `isBuiltIn`. Never collides with `UUID()` —
    /// uniformly random UUIDs land here with probability ~1e-38.
    public static let defaultsPresetID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Read-only "Defaults" preset surfaced at the top of the picker so
    /// users can reset to a clean form by name (rather than digging into
    /// a "New" menu item that mutates state in place). Doesn't get
    /// persisted; rebuilt in code on every VM init.
    public static let builtInDefaults = CohortPreset(
        id: defaultsPresetID,
        name: "Defaults",
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        config: CohortFormConfig()
    )

    /// Every built-in preset Tracer ships. Currently one. Surfaced as a
    /// computed list (not a `let` constant) so views can show / hide them
    /// per-feature-flag in the future.
    public static var allBuiltIns: [CohortPreset] {
        [builtInDefaults]
    }

    /// True for any preset whose id is known to be a built-in. Drives
    /// the UI's "hide Update / Rename / Delete" gate and the VM's
    /// "reject mutation" guards.
    public var isBuiltIn: Bool {
        Self.allBuiltIns.contains { $0.id == self.id }
    }
}
