import Foundation
import SwiftUI
import Combine

/// MainActor view model that owns the cohort form's editable state.
///
/// Replaces the 20-some `@State` properties that used to live directly on
/// `CohortPanel` so the form is:
///   • **Persistent across panel close/open** — the VM is owned by
///     `ContentView` as a `@StateObject`, so closing the inspector doesn't
///     reset state.
///   • **Persistent across app launches** — every change auto-saves a
///     debounced JSON draft to `UserDefaults["Tracer.Cohort.Draft"]`.
///   • **Named-preset-able** — users can save the current form as a
///     named preset and switch between several configurations.
///   • **Testable** — `buildJob` is a pure function on `CohortFormConfig`
///     and the VM exposes its config as a `@Published` snapshot.
///   • **Addressable from chat** — a future "set cohort workers to 4"
///     command can write to `vm.maxConcurrent` directly.
@MainActor
public final class CohortFormViewModel: ObservableObject {

    // MARK: - Persistence keys

    /// Auto-saved snapshot of the current form, written on every change
    /// (debounced). Survives app relaunch.
    static let draftDefaultsKey = "Tracer.Cohort.Draft"
    /// Array of named presets the user has explicitly saved.
    static let presetsDefaultsKey = "Tracer.Cohort.Presets"

    // MARK: - Form fields (mirror of CohortFormConfig)

    @Published public var jobName: String
    @Published public var outputRoot: String
    @Published public var modalityFilter: String
    @Published public var maxConcurrent: Int
    @Published public var skipIfResultsExist: Bool
    @Published public var nnunetEntryID: String
    @Published public var segmentationMode: SegmentationMode
    @Published public var useFullEnsemble: Bool
    @Published public var disableTTA: Bool
    @Published public var classifierEntryID: String
    @Published public var petACEntryID: String
    @Published public var petACScriptPath: String
    @Published public var petACPythonExecutable: String
    @Published public var petACEnvironment: String
    @Published public var petACExtraArgs: String
    @Published public var petACTimeoutSeconds: Double
    @Published public var petACUseAnatomicalChannel: Bool
    @Published public var petACFallbackToNACOnFailure: Bool

    // MARK: - Preset state

    @Published public private(set) var presets: [CohortPreset] = []
    /// The preset id the user currently has loaded. `nil` means "untitled
    /// draft — not associated with any saved preset". For built-in
    /// presets (e.g. "Defaults") this carries the built-in's stable id;
    /// the UI gates mutate-actions on `activePresetIsBuiltIn`.
    @Published public private(set) var activePresetID: UUID?
    @Published public private(set) var activePresetName: String?

    /// Tracer's built-in presets (currently just "Defaults"). Always
    /// rendered above user presets in the picker; can't be renamed,
    /// updated, deleted, or exported.
    public let builtInPresets: [CohortPreset] = CohortPreset.allBuiltIns

    /// Convenience for the panel's "hide mutate menu items" gate.
    public var activePresetIsBuiltIn: Bool {
        guard let id = activePresetID else { return false }
        return builtInPresets.contains { $0.id == id }
    }

    /// Lookup that searches BOTH built-ins and user presets — the picker
    /// loads via id, and we don't want it to silently miss a built-in.
    public func preset(id: UUID) -> CohortPreset? {
        if let built = builtInPresets.first(where: { $0.id == id }) { return built }
        return presets.first { $0.id == id }
    }

    // MARK: - Internals

    /// Backing store + clock — injectable for tests.
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    /// Combine pipeline for debounced auto-save. Cancelled on deinit.
    private var draftSaveSink: AnyCancellable?

    public init(defaults: UserDefaults = .standard,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now

        // Hydrate from persisted draft if present, else seed with sensible
        // defaults from CohortFormConfig().
        let initial = Self.loadDraft(from: defaults) ?? CohortFormConfig()
        self.jobName = initial.jobName
        self.outputRoot = initial.outputRoot
        self.modalityFilter = initial.modalityFilter
        self.maxConcurrent = initial.maxConcurrent
        self.skipIfResultsExist = initial.skipIfResultsExist
        self.nnunetEntryID = initial.nnunetEntryID
        self.segmentationMode = initial.segmentationMode
        self.useFullEnsemble = initial.useFullEnsemble
        self.disableTTA = initial.disableTTA
        self.classifierEntryID = initial.classifierEntryID
        self.petACEntryID = initial.petACEntryID
        self.petACScriptPath = initial.petACScriptPath
        self.petACPythonExecutable = initial.petACPythonExecutable
        self.petACEnvironment = initial.petACEnvironment
        self.petACExtraArgs = initial.petACExtraArgs
        self.petACTimeoutSeconds = initial.petACTimeoutSeconds
        self.petACUseAnatomicalChannel = initial.petACUseAnatomicalChannel
        self.petACFallbackToNACOnFailure = initial.petACFallbackToNACOnFailure

        self.presets = Self.loadPresets(from: defaults)

        // Debounced auto-save. Subscribe to objectWillChange after we've
        // hydrated all the fields above so the init-time assignments
        // don't trigger a save. Debounce window: 500 ms, which is below
        // human "I expect this to be saved" perception but high enough
        // to coalesce typing bursts (TextField fires per keystroke).
        //
        // SwiftUI re-evaluates `hasUnsavedPresetChanges` automatically
        // on each @Published mutation; we deliberately do NOT call
        // objectWillChange.send() from inside this sink — doing so would
        // create a feedback loop with the debounce subscription and
        // re-fire the save every 500 ms forever.
        draftSaveSink = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveDraft()
            }
    }

    // MARK: - Snapshot

    /// Pure-data snapshot of the current form. Used by `buildJob`,
    /// preset save, draft persist, and tests.
    public var config: CohortFormConfig {
        CohortFormConfig(
            jobName: jobName,
            outputRoot: outputRoot,
            modalityFilter: modalityFilter,
            maxConcurrent: maxConcurrent,
            skipIfResultsExist: skipIfResultsExist,
            nnunetEntryID: nnunetEntryID,
            segmentationMode: segmentationMode,
            useFullEnsemble: useFullEnsemble,
            disableTTA: disableTTA,
            classifierEntryID: classifierEntryID,
            petACEntryID: petACEntryID,
            petACScriptPath: petACScriptPath,
            petACPythonExecutable: petACPythonExecutable,
            petACEnvironment: petACEnvironment,
            petACExtraArgs: petACExtraArgs,
            petACTimeoutSeconds: petACTimeoutSeconds,
            petACUseAnatomicalChannel: petACUseAnatomicalChannel,
            petACFallbackToNACOnFailure: petACFallbackToNACOnFailure
        )
    }

    /// True when the user has typed at least one custom value — used by the
    /// panel to enable the "Save as preset" button. Specifically: the
    /// current config differs from a freshly-defaulted CohortFormConfig.
    public var hasUserEdits: Bool {
        config != CohortFormConfig()
    }

    /// True when we have a loaded preset AND the form has diverged from
    /// it. Drives the "modified" dot next to the preset name. For
    /// built-in presets, "diverged" still flips to `true` (the user is
    /// editing the form on top of the built-in baseline) but the panel
    /// won't offer "Update preset" for built-ins — they're read-only.
    public var hasUnsavedPresetChanges: Bool {
        guard let id = activePresetID, let preset = preset(id: id) else {
            return false
        }
        return preset.config != config
    }

    // MARK: - Build

    /// Translate the form into a `CohortJob`. Pure delegation — the
    /// translation logic lives on `CohortFormConfig.buildJob` so the Codable
    /// snapshot can be tested in isolation, without spinning a VM.
    public func buildJob() -> CohortJob {
        config.buildJob()
    }

    public func validationError(filteredStudyCount: Int) -> String? {
        config.validationError(filteredStudyCount: filteredStudyCount)
    }

    // MARK: - Apply external config

    /// Replace every field with `config`. Each assignment fires
    /// `objectWillChange`; the debounce coalesces them into one trailing
    /// save 500 ms later. We also call `saveDraft()` immediately so a
    /// preset load is durable even if the user closes the app within the
    /// debounce window.
    public func apply(_ config: CohortFormConfig) {
        jobName = config.jobName
        outputRoot = config.outputRoot
        modalityFilter = config.modalityFilter
        maxConcurrent = config.maxConcurrent
        skipIfResultsExist = config.skipIfResultsExist
        nnunetEntryID = config.nnunetEntryID
        segmentationMode = config.segmentationMode
        useFullEnsemble = config.useFullEnsemble
        disableTTA = config.disableTTA
        classifierEntryID = config.classifierEntryID
        petACEntryID = config.petACEntryID
        petACScriptPath = config.petACScriptPath
        petACPythonExecutable = config.petACPythonExecutable
        petACEnvironment = config.petACEnvironment
        petACExtraArgs = config.petACExtraArgs
        petACTimeoutSeconds = config.petACTimeoutSeconds
        petACUseAnatomicalChannel = config.petACUseAnatomicalChannel
        petACFallbackToNACOnFailure = config.petACFallbackToNACOnFailure
        saveDraft()
    }

    /// Reset the form to the defaults from `CohortFormConfig.init()`.
    /// Clears the active preset binding so the next save creates a new
    /// preset rather than overwriting one. Users who want to LOAD the
    /// "Defaults" built-in preset (so the picker shows its name) should
    /// call `loadPreset(CohortPreset.builtInDefaults)` instead.
    public func reset() {
        apply(CohortFormConfig())
        activePresetID = nil
        activePresetName = nil
    }

    // MARK: - Preset CRUD

    /// Save the current form as a new preset under `name`. `name` is
    /// trimmed; empty names + collisions with built-in or user preset
    /// names are rejected. Returns the saved preset on success so
    /// callers can highlight it.
    @discardableResult
    public func saveAsPreset(named rawName: String) -> CohortPreset? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // Reject collisions with both user presets AND built-ins so
        // users can't shadow the "Defaults" preset by saving one called
        // "Defaults".
        if anyPresetMatches(name: name, excluding: nil) { return nil }
        let preset = CohortPreset(
            name: name,
            createdAt: now(),
            updatedAt: now(),
            config: config
        )
        presets.append(preset)
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        savePresets()
        activePresetID = preset.id
        activePresetName = preset.name
        return preset
    }

    /// Overwrite the active preset with the current form. No-op if no
    /// preset is loaded OR if the active preset is a built-in
    /// (built-ins are read-only by design). Caller should disable the
    /// menu item via `activePresetIsBuiltIn`.
    @discardableResult
    public func updateActivePreset() -> CohortPreset? {
        guard let id = activePresetID,
              !activePresetIsBuiltIn,
              let idx = presets.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        presets[idx].config = config
        presets[idx].updatedAt = now()
        savePresets()
        return presets[idx]
    }

    public func loadPreset(_ preset: CohortPreset) {
        apply(preset.config)
        activePresetID = preset.id
        activePresetName = preset.name
    }

    /// Delete a user preset. No-op for built-in presets — they aren't
    /// in the `presets` array anyway, but the `activePresetID` could
    /// still point at one, so we guard against clearing the binding for
    /// a built-in delete attempt.
    public func deletePreset(_ preset: CohortPreset) {
        if preset.isBuiltIn { return }
        presets.removeAll { $0.id == preset.id }
        savePresets()
        if activePresetID == preset.id {
            activePresetID = nil
            activePresetName = nil
        }
    }

    /// Make a copy of `preset` with `(copy)` appended to the name. Works
    /// on built-in presets too — the resulting copy is a regular user
    /// preset (mutable, persistent).
    @discardableResult
    public func duplicatePreset(_ preset: CohortPreset) -> CohortPreset {
        let baseName = preset.name + " (copy)"
        var name = baseName
        var counter = 2
        while anyPresetMatches(name: name, excluding: nil) {
            name = "\(baseName) \(counter)"
            counter += 1
        }
        let dup = CohortPreset(
            name: name,
            createdAt: now(),
            updatedAt: now(),
            config: preset.config
        )
        presets.append(dup)
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        savePresets()
        return dup
    }

    /// Rename the active preset. Returns false on empty / duplicate
    /// names OR if the active preset is a built-in (built-ins are
    /// read-only by design — the UI should hide the rename action).
    @discardableResult
    public func renameActivePreset(to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !activePresetIsBuiltIn,
              let id = activePresetID,
              let idx = presets.firstIndex(where: { $0.id == id }) else {
            return false
        }
        // Reject if some OTHER preset (user or built-in) owns this name.
        if anyPresetMatches(name: name, excluding: id) {
            return false
        }
        presets[idx].name = name
        presets[idx].updatedAt = now()
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        savePresets()
        activePresetName = name
        return true
    }

    /// Helper: case-insensitive name collision against BOTH built-in
    /// and user presets. `excluding` skips a specific preset id (used
    /// during rename to allow no-op renames like "beta" → "Beta").
    private func anyPresetMatches(name: String, excluding skipID: UUID?) -> Bool {
        let combined = builtInPresets + presets
        return combined.contains { preset in
            preset.id != skipID
                && preset.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    // MARK: - Persistence — draft

    private func saveDraft() {
        let snapshot = config
        do {
            let data = try JSONEncoder().encode(snapshot)
            defaults.set(data, forKey: Self.draftDefaultsKey)
        } catch {
            NSLog("CohortFormViewModel: draft encode failed — \(error.localizedDescription)")
        }
    }

    private static func loadDraft(from defaults: UserDefaults) -> CohortFormConfig? {
        guard let data = defaults.data(forKey: draftDefaultsKey) else { return nil }
        do {
            return try JSONDecoder().decode(CohortFormConfig.self, from: data)
        } catch {
            // Corrupt draft — wipe it so we don't keep failing on every
            // launch. Better to lose one session's draft than to hang on
            // an unloadable JSON forever.
            NSLog("CohortFormViewModel: corrupt draft, discarding — \(error.localizedDescription)")
            defaults.removeObject(forKey: draftDefaultsKey)
            return nil
        }
    }

    // MARK: - Persistence — presets

    private func savePresets() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // stable across runs for diff-friendliness
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(presets)
            defaults.set(data, forKey: Self.presetsDefaultsKey)
        } catch {
            NSLog("CohortFormViewModel: preset encode failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Export / import (sharing across machines)

    /// Versioned envelope that wraps an exported preset list. Versioning
    /// matters because the file format leaves the local app — a user
    /// might mail a preset file to someone running an older Tracer
    /// build, and we want a clean refusal rather than a partial decode.
    public struct Bundle: Codable, Sendable {
        /// File-format version. Bump when the schema changes in a
        /// non-backward-compatible way.
        public let version: Int
        public let exportedAt: Date
        public let presets: [CohortPreset]

        public static let currentVersion = 1

        public init(presets: [CohortPreset],
                    exportedAt: Date = Date(),
                    version: Int = currentVersion) {
            self.version = version
            self.exportedAt = exportedAt
            self.presets = presets
        }
    }

    public enum ImportConflictPolicy: String, Sendable {
        /// Drop incoming presets whose name already exists. Safest default.
        case skip
        /// Append "(imported)" / "(imported) 2" / … to the incoming
        /// preset's name until it's unique. Always succeeds.
        case rename
        /// Replace the existing preset's config with the imported one.
        /// Preserves the existing preset's id (so any UI / chat state
        /// that referenced the old id keeps working).
        case overwrite
    }

    public struct ImportSummary: Equatable, Sendable {
        public var imported: Int
        public var skipped: Int
        public var renamed: Int
        public var overwritten: Int
        public var built_inSkipped: Int

        public init(imported: Int = 0,
                    skipped: Int = 0,
                    renamed: Int = 0,
                    overwritten: Int = 0,
                    built_inSkipped: Int = 0) {
            self.imported = imported
            self.skipped = skipped
            self.renamed = renamed
            self.overwritten = overwritten
            self.built_inSkipped = built_inSkipped
        }

        public var totalApplied: Int {
            imported + renamed + overwritten
        }

        /// Compact summary for the panel's status bar.
        public var statusMessage: String {
            var parts: [String] = []
            if imported > 0 { parts.append("\(imported) added") }
            if renamed > 0 { parts.append("\(renamed) renamed") }
            if overwritten > 0 { parts.append("\(overwritten) updated") }
            if skipped > 0 { parts.append("\(skipped) skipped (already exist)") }
            if built_inSkipped > 0 { parts.append("\(built_inSkipped) skipped (built-in)") }
            return parts.isEmpty ? "Nothing imported." : parts.joined(separator: ", ")
        }
    }

    public enum ImportError: Swift.Error, LocalizedError, Sendable {
        case decodeFailed(String)
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .decodeFailed(let m):
                return "Could not parse preset file: \(m)"
            case .unsupportedVersion(let v):
                return "Preset file version \(v) is newer than this Tracer build supports. Update Tracer or ask the sender for a v\(Bundle.currentVersion) export."
            }
        }
    }

    /// Encode the supplied presets as a versioned JSON bundle ready to
    /// write to a `.cohortpreset.json` file. Built-ins are accepted but
    /// re-export with their stable id so the recipient sees them as
    /// the same built-in (not a user-mutable duplicate).
    public static func encodeExport(_ presets: [CohortPreset],
                                    exportedAt: Date = Date()) throws -> Data {
        let bundle = Bundle(presets: presets, exportedAt: exportedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    /// Convenience: encode every user preset in this VM. (Built-ins are
    /// not exported — they live in code on every machine.)
    public func exportAllUserPresets(exportedAt: Date? = nil) throws -> Data {
        try Self.encodeExport(presets, exportedAt: exportedAt ?? now())
    }

    /// Convenience: encode a single preset.
    public func exportPreset(_ preset: CohortPreset,
                             exportedAt: Date? = nil) throws -> Data {
        try Self.encodeExport([preset], exportedAt: exportedAt ?? now())
    }

    /// Import from a previously-exported bundle. Returns a summary the
    /// panel surfaces in its status line. Atomic: the import is built
    /// up in a local copy and only assigned to `presets` once decoding
    /// succeeded for every entry.
    @discardableResult
    public func importPresets(from data: Data,
                              conflictPolicy: ImportConflictPolicy = .skip) throws -> ImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle: Bundle
        do {
            bundle = try decoder.decode(Bundle.self, from: data)
        } catch {
            throw ImportError.decodeFailed(error.localizedDescription)
        }
        if bundle.version > Bundle.currentVersion {
            throw ImportError.unsupportedVersion(bundle.version)
        }

        var working = presets
        var summary = ImportSummary()

        for incoming in bundle.presets {
            // Skip built-in re-imports — they're code-defined on every
            // machine, importing one is a no-op (and we don't want to
            // accidentally let a built-in name become a user preset).
            if incoming.isBuiltIn {
                summary.built_inSkipped += 1
                continue
            }

            // Collision check covers built-ins so users can't sneak a
            // preset called "Defaults" in via import either.
            let allNames = builtInPresets.map(\.name) + working.map(\.name)
            let nameExists = allNames.contains {
                $0.caseInsensitiveCompare(incoming.name) == .orderedSame
            }

            if !nameExists {
                // Stamp updatedAt so cross-machine sort-by-recency works.
                let saved = CohortPreset(
                    id: incoming.id,
                    name: incoming.name,
                    createdAt: incoming.createdAt,
                    updatedAt: now(),
                    config: incoming.config
                )
                working.append(saved)
                summary.imported += 1
                continue
            }

            switch conflictPolicy {
            case .skip:
                summary.skipped += 1

            case .rename:
                let baseName = incoming.name + " (imported)"
                var newName = baseName
                var counter = 2
                let hasCollision: (String) -> Bool = { candidate in
                    let combined = self.builtInPresets.map(\.name) + working.map(\.name)
                    return combined.contains {
                        $0.caseInsensitiveCompare(candidate) == .orderedSame
                    }
                }
                while hasCollision(newName) {
                    newName = "\(baseName) \(counter)"
                    counter += 1
                }
                // Fresh id for renamed import so we don't risk colliding
                // with an existing preset that happens to share the
                // incoming id (rare but possible if the user re-imports
                // a file they already imported before).
                let renamed = CohortPreset(
                    id: UUID(),
                    name: newName,
                    createdAt: incoming.createdAt,
                    updatedAt: now(),
                    config: incoming.config
                )
                working.append(renamed)
                summary.renamed += 1

            case .overwrite:
                // Find the existing user preset by name (case-insensitive).
                // Built-in name collisions can't be overwritten — they're
                // not in `working`, so the search misses and we skip
                // those rather than appending a new one.
                if let idx = working.firstIndex(where: {
                    $0.name.caseInsensitiveCompare(incoming.name) == .orderedSame
                }) {
                    let existing = working[idx]
                    // Rebuild via init since id + createdAt are `let`.
                    // Preserves the existing id (so any in-flight UI /
                    // chat state that referenced the old id keeps
                    // working) and the original createdAt timestamp.
                    let replacement = CohortPreset(
                        id: existing.id,
                        name: existing.name,
                        createdAt: existing.createdAt,
                        updatedAt: now(),
                        config: incoming.config
                    )
                    working[idx] = replacement
                    summary.overwritten += 1
                } else {
                    // Built-in name collision — skip, can't overwrite a built-in.
                    summary.built_inSkipped += 1
                }
            }
        }

        working.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        presets = working
        savePresets()
        return summary
    }

    private static func loadPresets(from defaults: UserDefaults) -> [CohortPreset] {
        guard let data = defaults.data(forKey: presetsDefaultsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let presets = try decoder.decode([CohortPreset].self, from: data)
            return presets.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            // Same conservative recovery as for the draft. Presets are the
            // user's intentional saves so we keep the corrupt blob in a
            // sidecar key for them to recover manually if it matters.
            NSLog("CohortFormViewModel: corrupt presets, archiving — \(error.localizedDescription)")
            defaults.set(data, forKey: presetsDefaultsKey + ".corrupt-\(Int(Date().timeIntervalSince1970))")
            defaults.removeObject(forKey: presetsDefaultsKey)
            return []
        }
    }

    // MARK: - Divergence

    // `hasUnsavedPresetChanges` is computed from `presets[id].config != config`
    // at View render time. Both `presets` and the form fields are
    // @Published, so any user edit triggers SwiftUI to re-render the
    // panel, which automatically recomputes the flag and shows / hides
    // the "•" indicator. No explicit divergence-detection callback is
    // needed (and trying to add one via objectWillChange.send() would
    // form a feedback loop with the debounce subscription).
}
