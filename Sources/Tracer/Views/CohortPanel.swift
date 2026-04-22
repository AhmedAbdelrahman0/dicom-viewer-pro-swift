import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The one pane that turns Tracer from a single-study viewer into a
/// cohort-processing tool. Drives `CohortBatchProcessor` via
/// `CohortResultsStore` — config form at the top, live progress in the
/// middle, sortable per-study results table at the bottom.
///
/// Opens as an inspector drawer from the AI Engines menu (⌘⇧B). Takes the
/// fully-indexed worklist from `ContentView`; the user filters it further
/// inside the panel (by modality, status, search text) before kicking off
/// a run.
public struct CohortPanel: View {
    @ObservedObject public var store: CohortResultsStore

    /// Everything indexed under "Study Browser". The cohort panel shows
    /// this as the "available studies" count and lets the user filter
    /// before running.
    public let availableStudies: [PACSWorklistStudy]

    @State private var jobName: String = "Cohort run"
    @State private var outputRoot: String = ""
    @State private var modalityFilter: String = "All"
    @State private var nnunetEntryID: String = NNUnetCatalog.all.first?.id ?? ""
    @State private var segmentationMode: SegmentationMode = .subprocess
    @State private var useFullEnsemble: Bool = false
    @State private var disableTTA: Bool = true
    @State private var classifierEntryID: String = ""
    @State private var maxConcurrent: Int = 2
    @State private var skipIfResultsExist: Bool = true
    @State private var sortColumn: SortColumn = .studyDate
    @State private var sortAscending: Bool = false

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
                availableStudies: [PACSWorklistStudy]) {
        self.store = store
        self.availableStudies = availableStudies
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            jobForm
            Divider()
            progressSection
            Divider()
            resultsTable
        }
        .padding(14)
        .frame(minWidth: 560)
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

    // MARK: - Form

    private var filteredStudies: [PACSWorklistStudy] {
        let lowered = modalityFilter
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

            TextField("Cohort name", text: $jobName)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Output folder (e.g. ~/tracer-cohort/autopet-2024)",
                          text: $outputRoot)
                    .textFieldStyle(.roundedBorder)
                #if canImport(AppKit)
                Button("Browse…") { pickOutputFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                #endif
            }

            HStack {
                Picker("Modality", selection: $modalityFilter) {
                    ForEach(allModalityOptions, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180)

                Stepper("Workers: \(maxConcurrent)",
                        value: $maxConcurrent, in: 1...16)
                    .controlSize(.small)

                Toggle("Skip if results exist", isOn: $skipIfResultsExist)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Picker("nnU-Net", selection: $nnunetEntryID) {
                ForEach(NNUnetCatalog.all, id: \.id) { Text($0.displayName).tag($0.id) }
            }
            .pickerStyle(.menu)

            HStack {
                Picker("Mode", selection: $segmentationMode) {
                    ForEach(SegmentationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("5-fold", isOn: $useFullEnsemble)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("No TTA", isOn: $disableTTA)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Picker("Classify with", selection: $classifierEntryID) {
                Text("— skip classification —").tag("")
                ForEach(LesionClassifierCatalog.all, id: \.id) {
                    Text($0.displayName).tag($0.id)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button {
                    startCohort()
                } label: {
                    Label("Run cohort", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isRunning || outputRoot.isEmpty || filteredStudies.isEmpty)

                Button {
                    store.markFailedForRetry()
                } label: {
                    Label("Retry failed", systemImage: "arrow.counterclockwise")
                }
                .disabled(store.checkpoint?.failedCount ?? 0 == 0)

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
        // Deterministic but varied colour per label. Hash into HSB space so
        // similar labels don't collide onto the same bar colour.
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
            case .pending:              return ("circle", .secondary)
            case .running:              return ("hourglass", .orange)
            case .done:                 return ("checkmark.circle.fill", .green)
            case .failedLoad:           return ("exclamationmark.octagon.fill", .red)
            case .failedSegmentation:   return ("exclamationmark.triangle.fill", .red)
            case .failedClassification: return ("exclamationmark.triangle.fill", .orange)
            case .cancelled:            return ("xmark.circle", .secondary)
            case .skipped:              return ("arrow.right.circle", .blue)
            }
        }()
        return Image(systemName: icon)
            .foregroundColor(color)
            .font(.system(size: 12))
    }

    // MARK: - Actions

    private func startCohort() {
        let expanded = (outputRoot as NSString).expandingTildeInPath
        let outputURL = URL(fileURLWithPath: expanded)
        var modalityAllow: [String] = []
        if modalityFilter != "All" { modalityAllow = [modalityFilter] }

        let job = CohortJob(
            name: jobName.isEmpty ? "Cohort run" : jobName,
            outputRoot: outputURL,
            nnunetEntryID: nnunetEntryID,
            segmentationMode: segmentationMode,
            useFullEnsemble: useFullEnsemble,
            disableTTA: disableTTA,
            classifierEntryID: classifierEntryID.isEmpty ? nil : classifierEntryID,
            maxConcurrent: maxConcurrent,
            skipIfResultsExist: skipIfResultsExist,
            modalityAllowList: modalityAllow
        )
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
            outputRoot = url.path
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(jobName.isEmpty ? "cohort" : jobName).csv"
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
    #else
    private func pickOutputFolder() { /* iPad stub */ }
    private func exportCSV() { /* iPad stub */ }
    #endif
}
