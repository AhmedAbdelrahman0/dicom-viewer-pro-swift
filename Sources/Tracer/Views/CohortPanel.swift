import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The one pane that turns Tracer from a single-study viewer into a
/// cohort-processing tool. Drives `CohortBatchProcessor` via
/// `CohortResultsStore`.
///
/// Architecture: this view is **presentational**. Form state lives on a
/// `CohortFormViewModel` owned by `ContentView`, which auto-persists a
/// draft to UserDefaults and supports named presets. The only `@State`
/// the panel keeps is for transient UI affordances (sort column, the
/// "save preset" sheet's text field) that don't belong in a saveable job
/// configuration.
///
/// Opens as an inspector drawer from the AI Engines menu (⌘⇧B). Takes the
/// fully-indexed worklist from `ContentView`; the user filters it further
/// inside the panel before kicking off a run.
public struct CohortPanel: View {
    @ObservedObject public var store: CohortResultsStore
    @ObservedObject public var classifier: ClassificationViewModel
    @ObservedObject public var form: CohortFormViewModel

    /// Everything indexed under "Study Browser". Display-only;
    /// `form.modalityFilter` decides which subset becomes a cohort.
    public let availableStudies: [PACSWorklistStudy]

    // MARK: - Transient UI state (not part of the saveable job config)

    @State private var sortColumn: SortColumn = .studyDate
    @State private var sortAscending: Bool = false
    @State private var showingSavePresetSheet: Bool = false
    @State private var pendingPresetName: String = ""
    @State private var showingRenameSheet: Bool = false
    @State private var pendingRenameValue: String = ""
    @State private var showingDeleteConfirm: Bool = false

    enum SortColumn: String, CaseIterable, Identifiable {
        case studyDate
        case patientName
        case status
        case lesionCount
        case tmtv

        var id: String { rawValue }
        var title: String {
            switch self {
            case .studyDate:   return "Date"
            case .patientName: return "Patient"
            case .status:      return "Status"
            case .lesionCount: return "Lesions"
            case .tmtv:        return "TMTV"
            }
        }
    }

    public init(store: CohortResultsStore,
                classifier: ClassificationViewModel,
                form: CohortFormViewModel,
                availableStudies: [PACSWorklistStudy]) {
        self.store = store
        self.classifier = classifier
        self.form = form
        self.availableStudies = availableStudies
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            presetBar
            Divider()
            jobForm
            Divider()
            progressSection
            Divider()
            resultsTable
        }
        .padding(14)
        .frame(minWidth: 560)
        .sheet(isPresented: $showingSavePresetSheet) { savePresetSheet }
        .sheet(isPresented: $showingRenameSheet) { renamePresetSheet }
        .alert("Delete preset?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteActivePreset() }
        } message: {
            Text("This removes \"\(form.activePresetName ?? "")\" from your saved presets. The current form contents stay as-is.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.3.layers.3d.down.right")
                .foregroundColor(.accentColor)
            Text("Cohort Batch")
                .font(.headline)
            Spacer()
            if store.isRunning {
                ProgressView().controlSize(.small)
                Button("Cancel") { store.cancel() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Preset bar

    /// Top-of-panel row that drives named-preset workflows. Picker for
    /// loading any saved preset; menu for save / save-as / rename / delete /
    /// duplicate. Shows a "•" next to the preset name when the form has
    /// drifted from the loaded preset (helps the user spot when they need
    /// to hit "Update preset").
    private var presetBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack")
                .foregroundColor(.secondary)
                .font(.system(size: 11))

            Menu {
                // Built-in presets (currently just "Defaults") at the top
                // so a user who opens a fresh window can immediately see
                // a clean starting point by name. These are read-only —
                // selecting "Defaults" doesn't unlock Update/Rename/Delete.
                ForEach(form.builtInPresets) { preset in
                    presetMenuButton(preset)
                }
                if !form.presets.isEmpty {
                    Divider()
                    ForEach(form.presets) { preset in
                        presetMenuButton(preset)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(activePresetDisplay)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(form.activePresetID == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if form.hasUnsavedPresetChanges {
                        Text("•")
                            .foregroundColor(.orange)
                            .help("Unsaved changes since this preset was loaded")
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.1)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Menu {
                Button {
                    pendingPresetName = form.activePresetIsBuiltIn
                        ? form.jobName        // don't pre-fill with "Defaults"
                        : (form.activePresetName ?? form.jobName)
                    showingSavePresetSheet = true
                } label: {
                    Label("Save as new preset…", systemImage: "square.and.arrow.down")
                }
                .disabled(!form.hasUserEdits)

                // Update only available for non-built-in active presets
                // with unsaved divergence.
                Button {
                    _ = form.updateActivePreset()
                } label: {
                    Label(form.hasUnsavedPresetChanges
                          ? "Update \"\(form.activePresetName ?? "")\""
                          : "Update active preset",
                          systemImage: "arrow.up.circle")
                }
                .disabled(form.activePresetID == nil
                          || form.activePresetIsBuiltIn
                          || !form.hasUnsavedPresetChanges)

                // Duplicate works for both built-ins and user presets —
                // built-in dup becomes a regular user preset the user
                // can then customise.
                if let active = form.preset(id: form.activePresetID ?? UUID()) {
                    Divider()
                    Button {
                        _ = form.duplicatePreset(active)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    if !active.isBuiltIn {
                        Button {
                            pendingRenameValue = active.name
                            showingRenameSheet = true
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                    }
                }

                // Sharing: export the active (single) preset, or every
                // user preset, as a .cohortpreset.json file.
                #if canImport(AppKit)
                Divider()
                if let active = form.preset(id: form.activePresetID ?? UUID()), !active.isBuiltIn {
                    Button {
                        exportPreset(active)
                    } label: {
                        Label("Export \"\(active.name)\"…", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    exportAllPresets()
                } label: {
                    Label("Export all presets…", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(form.presets.isEmpty)
                Button {
                    importPresetsFromFile()
                } label: {
                    Label("Import presets…", systemImage: "square.and.arrow.down.on.square")
                }
                #endif

                // Delete is its own block, always last + destructive.
                if let active = form.preset(id: form.activePresetID ?? UUID()),
                   !active.isBuiltIn {
                    Divider()
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Delete preset", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Preset management")
        }
    }

    private var activePresetDisplay: String {
        if let name = form.activePresetName { return name }
        if form.presets.isEmpty { return "Untitled (no presets yet)" }
        return "Untitled draft"
    }

    /// One menu row in the load picker. Shows the preset name (with the
    /// active checkmark or a category icon) and, when not a built-in,
    /// surfaces the relative-updated-at as a secondary line so users
    /// can spot "the one I tweaked yesterday" in a long preset list.
    /// Hover tooltip carries the full date breadcrumb.
    @ViewBuilder
    private func presetMenuButton(_ preset: CohortPreset) -> some View {
        Button {
            form.loadPreset(preset)
        } label: {
            // SwiftUI menus on macOS can render multi-line button content
            // — VStack-with-secondary-text shows up cleanly; the menu
            // resizes to fit the longest line.
            HStack(spacing: 6) {
                Image(systemName: leadingIconName(for: preset))
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                    if let relative = preset.relativeUpdatedAtDescription() {
                        Text(relative)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .help(preset.tooltipDescription())
    }

    private func leadingIconName(for preset: CohortPreset) -> String {
        if form.activePresetID == preset.id { return "checkmark.circle.fill" }
        return preset.isBuiltIn ? "doc.text" : "circle"
    }

    // MARK: - Form

    private var filteredStudies: [PACSWorklistStudy] {
        let lowered = form.modalityFilter
        return availableStudies.filter { study in
            if lowered == "All" { return true }
            return study.modalities.contains(lowered)
        }
    }

    private var allModalityOptions: [String] {
        var out: Set<String> = []
        for study in availableStudies {
            for m in study.modalities { out.insert(m) }
        }
        return ["All"] + out.sorted()
    }

    @ViewBuilder
    private var jobForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Job")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(filteredStudies.count) / \(availableStudies.count) studies match filters")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            TextField("Cohort name", text: $form.jobName)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Output folder (e.g. ~/tracer-cohort/autopet-2024)",
                          text: $form.outputRoot)
                    .textFieldStyle(.roundedBorder)
                #if canImport(AppKit)
                Button("Browse…") { pickOutputFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                #endif
            }

            HStack {
                Picker("Modality", selection: $form.modalityFilter) {
                    ForEach(allModalityOptions, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180)

                Stepper("Workers: \(form.maxConcurrent)",
                        value: $form.maxConcurrent, in: 1...16)
                    .controlSize(.small)

                Toggle("Skip if results exist", isOn: $form.skipIfResultsExist)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Picker("nnU-Net", selection: $form.nnunetEntryID) {
                ForEach(NNUnetCatalog.all, id: \.id) { Text($0.displayName).tag($0.id) }
            }
            .pickerStyle(.menu)

            HStack {
                Picker("Mode", selection: $form.segmentationMode) {
                    ForEach(SegmentationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("5-fold", isOn: $form.useFullEnsemble)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("No TTA", isOn: $form.disableTTA)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            petACSection

            Picker("Classify with", selection: $form.classifierEntryID) {
                Text("— skip classification —").tag("")
                ForEach(LesionClassifierCatalog.all, id: \.id) {
                    Text($0.displayName).tag($0.id)
                }
            }
            .pickerStyle(.menu)

            actionRow
        }
    }

    private var actionRow: some View {
        HStack {
            Button {
                startCohort()
            } label: {
                Label("Run cohort", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isRunning
                      || form.validationError(filteredStudyCount: filteredStudies.count) != nil)
            .help(form.validationError(filteredStudyCount: filteredStudies.count) ?? "Run the cohort")

            Button {
                store.markFailedForRetry()
            } label: {
                Label("Retry failed", systemImage: "arrow.counterclockwise")
            }
            .disabled((store.checkpoint?.failedCount ?? 0) == 0)

            Button {
                exportCSV()
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(store.checkpoint == nil)

            Spacer()
        }
        .controlSize(.small)
    }

    // MARK: - PET AC step (optional)

    @ViewBuilder
    private var petACSection: some View {
        Picker("AC step (NAC → AC PET)", selection: $form.petACEntryID) {
            Text("— skip AC —").tag("")
            ForEach(PETACCatalog.all, id: \.id) { entry in
                Text(entry.displayName).tag(entry.id)
            }
        }
        .pickerStyle(.menu)

        if !form.petACEntryID.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let entry = PETACCatalog.byID(form.petACEntryID) {
                    Text(entry.description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.requiresAnatomicalChannel {
                        Label("Needs a co-registered CT or MR per study",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }

                let entry = PETACCatalog.byID(form.petACEntryID)
                let isRemote = entry?.backend == .dgxRemote

                HStack {
                    TextField(isRemote
                              ? "~/scripts/deep_ac.py (on the DGX)"
                              : "path/to/deep_ac.py",
                              text: $form.petACScriptPath)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                if !isRemote {
                    TextField("Python interpreter (default /usr/bin/env)",
                              text: $form.petACPythonExecutable)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                Text(isRemote
                     ? "Environment / activation (first `activate=…` line runs before the script)"
                     : "Environment overrides (KEY=VALUE per line)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                TextEditor(text: $form.petACEnvironment)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3)))

                TextField("Extra script arguments (optional)", text: $form.petACExtraArgs)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)

                HStack {
                    Toggle("Use anatomical channel",
                           isOn: $form.petACUseAnatomicalChannel)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(entry?.requiresAnatomicalChannel == true)
                    Stepper("AC timeout: \(Int(form.petACTimeoutSeconds))s",
                            value: $form.petACTimeoutSeconds,
                            in: 30...3600,
                            step: 30)
                        .controlSize(.small)
                }

                Toggle("Fall back to NAC if AC fails (recommended)",
                       isOn: $form.petACFallbackToNACOnFailure)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("On: AC failure is logged, segmentation runs on the original NAC, study is flagged in the CSV. Off: AC failure marks the study failedAttenuationCorrection and skips segmentation/classification.")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.06)))
        }
    }

    // MARK: - Save / rename preset sheets

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save current cohort form as a preset")
                .font(.headline)
            TextField("Preset name", text: $pendingPresetName)
                .textFieldStyle(.roundedBorder)
            if presetNameCollision(pendingPresetName) {
                Label("A preset with that name already exists.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingSavePresetSheet = false }
                Button("Save") {
                    if form.saveAsPreset(named: pendingPresetName) != nil {
                        showingSavePresetSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingPresetName.trimmingCharacters(in: .whitespaces).isEmpty
                          || presetNameCollision(pendingPresetName))
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var renamePresetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename preset")
                .font(.headline)
            TextField("Preset name", text: $pendingRenameValue)
                .textFieldStyle(.roundedBorder)
            if renameCollision(pendingRenameValue) {
                Label("A different preset already uses that name.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingRenameSheet = false }
                Button("Rename") {
                    if form.renameActivePreset(to: pendingRenameValue) {
                        showingRenameSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingRenameValue.trimmingCharacters(in: .whitespaces).isEmpty
                          || renameCollision(pendingRenameValue))
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func presetNameCollision(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return form.presets.contains {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    private func renameCollision(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return form.presets.contains {
            $0.id != form.activePresetID
            && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    private func deleteActivePreset() {
        if let id = form.activePresetID,
           let preset = form.presets.first(where: { $0.id == id }) {
            form.deletePreset(preset)
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cp = store.checkpoint {
                HStack {
                    Text("\(cp.doneCount) / \(cp.total) done")
                        .font(.system(size: 11, weight: .medium))
                    if cp.failedCount > 0 {
                        Text("· \(cp.failedCount) failed").foregroundColor(.red)
                    }
                    if cp.skippedCount > 0 {
                        Text("· \(cp.skippedCount) skipped").foregroundColor(.secondary)
                    }
                    Spacer()
                    if let eta = store.etaString {
                        Text("ETA ≈ \(eta)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                ProgressView(value: store.progressFraction)
                    .progressViewStyle(.linear)

                if !cp.classificationHistogram.isEmpty {
                    histogramRow(cp.classificationHistogram)
                }
            } else {
                Text("No cohort loaded. Configure above, then Run.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func histogramRow(_ histogram: [(label: String, count: Int)]) -> some View {
        let total = max(1, histogram.reduce(0) { $0 + $1.count })
        HStack(spacing: 4) {
            Text("Classification:")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            ForEach(histogram.prefix(6), id: \.label) { row in
                let fraction = Double(row.count) / Double(total)
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: row.label))
                        .frame(width: CGFloat(fraction * 90), height: 8)
                    Text("\(row.label) (\(row.count))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func color(for label: String) -> Color {
        let hash = abs(label.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.65, brightness: 0.85)
    }

    // MARK: - Results table

    private var sortedResults: [CohortStudyResult] {
        guard let cp = store.checkpoint else { return [] }
        let all = Array(cp.results.values)
        let comparator: (CohortStudyResult, CohortStudyResult) -> Bool
        switch sortColumn {
        case .studyDate:
            comparator = { $0.studyDate < $1.studyDate }
        case .patientName:
            comparator = { $0.patientName.lowercased() < $1.patientName.lowercased() }
        case .status:
            comparator = { $0.status.rawValue < $1.status.rawValue }
        case .lesionCount:
            comparator = { ($0.lesionCount ?? -1) < ($1.lesionCount ?? -1) }
        case .tmtv:
            comparator = { ($0.totalMetabolicTumorVolumeML ?? -1) < ($1.totalMetabolicTumorVolumeML ?? -1) }
        }
        let sorted = all.sorted(by: comparator)
        return sortAscending ? sorted : sorted.reversed()
    }

    private var resultsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Results")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Picker("Sort", selection: $sortColumn) {
                    ForEach(SortColumn.allCases) { c in
                        Text(c.title).tag(c)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 140)
                Toggle("Ascending", isOn: $sortAscending)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if store.checkpoint == nil {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if sortedResults.isEmpty {
                Text("No studies queued.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                resultsList
            }
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sortedResults) { row in
                    resultsRow(row)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 260)
    }

    private func resultsRow(_ r: CohortStudyResult) -> some View {
        HStack(spacing: 6) {
            statusChip(r.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.patientName.isEmpty ? r.patientID : r.patientName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text("\(r.studyDate) · \(r.modalities.joined(separator: "/"))")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let n = r.lesionCount {
                    Text("\(n) lesions")
                        .font(.system(size: 10, design: .monospaced))
                }
                if let tmtv = r.totalMetabolicTumorVolumeML {
                    Text(String(format: "TMTV %.1f mL", tmtv))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            if let label = r.topClassification {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(color(for: label))
                        .lineLimit(1)
                    if let p = r.topClassificationConfidence {
                        Text(String(format: "%.0f%%", p * 100))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: 130)
            }
        }
        .padding(.vertical, 4)
        .help(r.errorMessage ?? r.patientName)
    }

    private func statusChip(_ status: CohortStudyResult.Status) -> some View {
        let (icon, color): (String, Color) = {
            switch status {
            case .pending:                       return ("circle", .secondary)
            case .running:                       return ("hourglass", .orange)
            case .done:                          return ("checkmark.circle.fill", .green)
            case .failedLoad:                    return ("exclamationmark.octagon.fill", .red)
            case .failedAttenuationCorrection:   return ("wand.and.rays", .red)
            case .failedSegmentation:            return ("exclamationmark.triangle.fill", .red)
            case .failedClassification:          return ("exclamationmark.triangle.fill", .orange)
            case .cancelled:                     return ("xmark.circle", .secondary)
            case .skipped:                       return ("arrow.right.circle", .blue)
            }
        }()
        return Image(systemName: icon)
            .foregroundColor(color)
            .font(.system(size: 12))
    }

    // MARK: - Actions

    private func startCohort() {
        var job = form.buildJob()
        if job.classifierEntryID != nil {
            classifier.applyCohortConfiguration(to: &job)
        }
        store.start(job: job, studies: filteredStudies)
    }

    #if canImport(AppKit)
    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Pick the output folder for cohort results"
        if panel.runModal() == .OK, let url = panel.url {
            form.outputRoot = url.path
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(form.jobName.isEmpty ? "cohort" : form.jobName).csv"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try store.exportCohortCSV(to: url)
                store.statusMessage = "Exported cohort CSV → \(url.lastPathComponent)"
            } catch {
                store.statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Export the active preset as a single-entry `.cohortpreset.json`.
    /// File name defaults to the sanitised preset name so multiple
    /// exports don't clobber each other in the user's Downloads folder.
    private func exportPreset(_ preset: CohortPreset) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sanitiseFilename(preset.name)).cohortpreset.json"
        panel.canCreateDirectories = true
        panel.message = "Export the \"\(preset.name)\" cohort preset as a sharable JSON file"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try form.exportPreset(preset)
                try data.write(to: url, options: [.atomic])
                store.statusMessage = "Exported preset → \(url.lastPathComponent)"
            } catch {
                store.statusMessage = "Preset export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Export EVERY user preset as one bundle file. Built-ins aren't
    /// included — they're code-defined on every Tracer install.
    private func exportAllPresets() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tracer-cohort-presets.cohortpreset.json"
        panel.canCreateDirectories = true
        panel.message = "Export every saved cohort preset as one sharable JSON file"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try form.exportAllUserPresets()
                try data.write(to: url, options: [.atomic])
                store.statusMessage = "Exported \(form.presets.count) preset(s) → \(url.lastPathComponent)"
            } catch {
                store.statusMessage = "Preset export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Read one or more `.cohortpreset.json` files and merge into the
    /// user's library. Default conflict policy is `.skip` — safe and
    /// reversible. Future enhancement: an "Import options…" sheet that
    /// lets the user pick `.rename` or `.overwrite` per import.
    private func importPresetsFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json]
        panel.message = "Import cohort presets from one or more .cohortpreset.json files"
        guard panel.runModal() == .OK else { return }

        var totals = CohortFormViewModel.ImportSummary()
        for url in panel.urls {
            do {
                let data = try Data(contentsOf: url)
                let summary = try form.importPresets(from: data, conflictPolicy: .skip)
                totals.imported += summary.imported
                totals.skipped += summary.skipped
                totals.renamed += summary.renamed
                totals.overwritten += summary.overwritten
                totals.built_inSkipped += summary.built_inSkipped
            } catch {
                store.statusMessage = "Import failed for \(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        }
        store.statusMessage = "Preset import: \(totals.statusMessage)"
    }

    /// Trim filesystem-hostile characters out of a preset name when
    /// using it as a default filename. Mirrors the same set we use in
    /// `CohortJob.outputDirectory`.
    private func sanitiseFilename(_ name: String) -> String {
        let disallowed: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = String(trimmed.map { disallowed.contains($0) ? "_" : $0 })
        return cleaned.isEmpty ? "preset" : cleaned
    }
    #else
    private func pickOutputFolder() { /* iPad stub */ }
    private func exportCSV() { /* iPad stub */ }
    #endif
}
