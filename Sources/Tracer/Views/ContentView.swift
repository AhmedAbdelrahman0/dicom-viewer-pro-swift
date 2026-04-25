import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif
    @StateObject private var vm = ViewerViewModel()
    @StateObject private var monai = MONAILabelViewModel()
    @StateObject private var nnunet = NNUnetViewModel()
    @StateObject private var pet = PETEngineViewModel()
    @StateObject private var classification = ClassificationViewModel()
    @StateObject private var modelManager = ModelManagerViewModel()
    @StateObject private var cohort = CohortResultsStore()
    @State private var showingFileImporter = false
    @State private var showingDirectoryPicker = false
    @State private var fileImporterMode: FileImporterMode = .volume
    @State private var directoryImporterMode: DirectoryImporterMode = .open
    @State private var showMONAIPanel = false
    @State private var showNNUnetPanel = false
    @State private var showPETEnginePanel = false
    @State private var showClassificationPanel = false
    @State private var showModelManagerPanel = false
    @State private var showCohortPanel = false
    @State private var cohortStudies: [PACSWorklistStudy] = []
    @State private var showAboutWindow = false
    @State private var showOnboarding = false
    /// First-launch onboarding gate — once dismissed the welcome card
    /// sheet stays closed across relaunches. Users can re-open it from
    /// Help → Show Welcome Walkthrough.
    @AppStorage("Tracer.HasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    /// Focus mode — hides the study browser and controls panel so the MPR
    /// viewport fills the window. Toggled via ⌘E or the toolbar button.
    /// Persists across launches via `@AppStorage`.
    @AppStorage("focusModeEnabled") private var focusModeEnabled = false
    @State private var browserVisibility: NavigationSplitViewVisibility = .all

    // User-rebindable W/L preset names for ⌘1 / ⌘2 / ⌘3. Defaults are set
    // to match most radiologists' muscle memory (Lung / Bone / Brain)
    // but every value is pickable from the Settings window.
    #if os(macOS)
    @AppStorage(TracerSettings.Keys.wlShortcut1) private var wlShortcut1: String = "Lung"
    @AppStorage(TracerSettings.Keys.wlShortcut2) private var wlShortcut2: String = "Bone"
    @AppStorage(TracerSettings.Keys.wlShortcut3) private var wlShortcut3: String = "Brain"
    #else
    private let wlShortcut1 = "Lung"
    private let wlShortcut2 = "Bone"
    private let wlShortcut3 = "Brain"
    #endif

    enum FileImporterMode { case volume, overlay }
    enum DirectoryImporterMode { case open, index }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            rootLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if vm.isLoading {
                loadingIndicator
                    .transition(.opacity)
            } else {
                statusBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(vm)
        .environmentObject(monai)
        .environmentObject(nnunet)
        // Engine panels open as right-side inspector drawers on regular-
        // width windows (macOS / iPad in landscape). In `.compact` widths
        // (iPad portrait, narrow windows) we fall back to `.sheet` since
        // an inspector drawer eats too much of the viewport. Only one is
        // ever visible at a time — the AI Engines menu calls
        // `showInspector(_:)` which closes the others first.
        .engineInspector(
            isCompact: useCompactEnginePresentation,
            isPresented: $showMONAIPanel,
            inspectorWidth: (min: 360, ideal: 440, max: 560)
        ) {
            MONAILabelPanel(viewer: vm, monai: monai, labeling: vm.labeling)
                .overlay(alignment: .topTrailing) {
                    closeInspectorButton { showMONAIPanel = false }
                }
        }
        .engineInspector(
            isCompact: useCompactEnginePresentation,
            isPresented: $showNNUnetPanel,
            inspectorWidth: (min: 400, ideal: 480, max: 640)
        ) {
            NNUnetPanel(viewer: vm, nnunet: nnunet, labeling: vm.labeling)
                .overlay(alignment: .topTrailing) {
                    closeInspectorButton { showNNUnetPanel = false }
                }
        }
        .engineInspector(
            isCompact: useCompactEnginePresentation,
            isPresented: $showPETEnginePanel,
            inspectorWidth: (min: 440, ideal: 500, max: 640)
        ) {
            PETEnginePanel(viewer: vm, nnunet: nnunet, pet: pet, labeling: vm.labeling)
                .overlay(alignment: .topTrailing) {
                    closeInspectorButton { showPETEnginePanel = false }
                }
        }
        .engineInspector(
            isCompact: useCompactEnginePresentation,
            isPresented: $showClassificationPanel,
            inspectorWidth: (min: 480, ideal: 520, max: 640)
        ) {
            ClassificationPanel(viewer: vm,
                                classifier: classification,
                                labeling: vm.labeling)
                .overlay(alignment: .topTrailing) {
                    closeInspectorButton { showClassificationPanel = false }
                }
        }
        .engineInspector(
            isCompact: useCompactEnginePresentation,
            isPresented: $showModelManagerPanel,
            inspectorWidth: (min: 540, ideal: 600, max: 760)
        ) {
            ModelManagerPanel(vm: modelManager)
                .overlay(alignment: .topTrailing) {
                    closeInspectorButton { showModelManagerPanel = false }
                }
        }
        .engineInspector(
            isCompact: useCompactEnginePresentation,
            isPresented: $showCohortPanel,
            inspectorWidth: (min: 600, ideal: 680, max: 820)
        ) {
            CohortPanel(store: cohort,
                        classifier: classification,
                        availableStudies: cohortStudies)
                .overlay(alignment: .topTrailing) {
                    closeInspectorButton { showCohortPanel = false }
                }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result)
        }
        .fileImporter(
            isPresented: $showingDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleDirectoryImport(result: result)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDICOMDirectory)) { _ in
            directoryImporterMode = .open
            showingDirectoryPicker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNIfTIFile)) { _ in
            fileImporterMode = .volume
            showingFileImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAboutWindow)) { _ in
            showAboutWindow = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            showOnboarding = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .recentVolumesDidChange)) { _ in
            vm.reloadRecentVolumes()
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantDidRequestClassification)) { _ in
            handleAssistantClassificationRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantDidRequestClassificationExport)) { note in
            let formatRaw = (note.userInfo?["format"] as? String) ?? "csv"
            handleAssistantClassificationExport(format: formatRaw)
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantDidRequestCohortPanel)) { _ in
            refreshCohortStudies()
            showInspector(.cohort)
        }
        .onChange(of: focusModeEnabled) { _, enabled in
            if !enabled {
                browserVisibility = .all
            }
        }
        #if os(macOS)
        .sheet(isPresented: $showAboutWindow) {
            TracerAboutView()
        }
        .sheet(isPresented: $showOnboarding) {
            TracerOnboardingView(isPresented: $showOnboarding) {
                hasSeenOnboarding = true
            }
        }
        #endif
        .onAppear {
            // Focus mode renders a different root layout, so keep the split
            // view in a predictable state for the next time panels are shown.
            browserVisibility = .all
            // Show the onboarding card set once per install, before the
            // user loads any data.
            if !hasSeenOnboarding {
                // Defer by a runloop so the view hierarchy finishes mounting.
                DispatchQueue.main.async { showOnboarding = true }
            }
        }
        .tooltipHost()  // must wrap the whole window so tooltips escape any clipping
    }

    @ViewBuilder
    private var rootLayout: some View {
        if focusModeEnabled {
            workstationScaffold
        } else {
            splitWorkstation
        }
    }

    private var splitWorkstation: some View {
        NavigationSplitView(columnVisibility: $browserVisibility) {
            StudyBrowserView(vm: vm,
                             onImportFolder: {
                                 directoryImporterMode = .open
                                 showingDirectoryPicker = true
                             },
                             onIndexFolder: {
                                 directoryImporterMode = .index
                                 showingDirectoryPicker = true
                             },
                             onImportVolume: {
                                 fileImporterMode = .volume
                                 showingFileImporter = true
                             },
                             onImportOverlay: {
                                 fileImporterMode = .overlay
                                 showingFileImporter = true
                             })
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        } content: {
            workstationScaffold
                .navigationSplitViewColumnWidth(min: 560, ideal: 1100)
        } detail: {
            ControlsPanel()
                .environmentObject(vm)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 360)
        }
    }

    private var workstationScaffold: some View {
        VStack(spacing: 0) {
            customToolbar
            workstationHeader
            MPRLayoutView()
                .environmentObject(vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Custom toolbar (in-content so hover + tooltips work reliably)

    private var customToolbar: some View {
        HStack(spacing: 6) {
            toolbarBrand

            Divider()
                .frame(height: 20)
                .padding(.trailing, 4)

            ForEach(ViewerTool.allCases) { tool in
                ToolButton(
                    tool: tool,
                    isActive: vm.activeTool == tool,
                    action: { vm.activeTool = tool }
                )
            }

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            HoverIconButton(
                systemImage: "wand.and.stars",
                tooltip: "Auto Window / Level  (⌘R or ⌘4)\n"
                       + "Automatically compute window/level from the\n"
                       + "1–99 percentile of the current volume."
            ) {
                vm.autoWLHistogram(preset: .balanced)
            }
            .keyboardShortcut("r", modifiers: [.command])

            // Invisible buttons that own the global W/L shortcuts. Kept off-
            // screen so they participate in the shortcut graph without
            // crowding the visible toolbar. The preset names are read from
            // Settings (`@AppStorage`) so users can rebind ⌘1 / ⌘2 / ⌘3.
            Group {
                Button("W/L Slot 1 (\(wlShortcut1))") {
                    vm.applyPresetNamed(wlShortcut1)
                }
                .keyboardShortcut("1", modifiers: [.command])
                Button("W/L Slot 2 (\(wlShortcut2))") {
                    vm.applyPresetNamed(wlShortcut2)
                }
                .keyboardShortcut("2", modifiers: [.command])
                Button("W/L Slot 3 (\(wlShortcut3))") {
                    vm.applyPresetNamed(wlShortcut3)
                }
                .keyboardShortcut("3", modifiers: [.command])
                Button("Auto W/L") { vm.autoWLHistogram(preset: .balanced) }
                    .keyboardShortcut("4", modifiers: [.command])
            }
            .frame(width: 0, height: 0)
            .hidden()
            .accessibilityHidden(true)

            HoverIconButton(
                systemImage: focusModeEnabled
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                tooltip: focusModeEnabled
                    ? "Exit Focus Mode (⌘E)\nShow the study browser and controls panel."
                    : "Focus Mode (⌘E)\nHide the side panels so the MPR viewport fills the window.\nGreat for contouring detailed lesions at full resolution."
            ) {
                toggleFocusMode()
            }
            .keyboardShortcut("e", modifiers: [.command])

            HoverIconButton(
                systemImage: "bubble.left.and.bubble.right",
                tooltip: "Assistant Chat  (⌘⇧A)\n"
                       + "Open the AI assistant panel on the right.\n"
                       + "Type natural-language commands like\n"
                       + "“Show lungs”, “threshold SUV 2.5”, or\n"
                       + "“create label map TotalSegmentator”."
            ) {
                NotificationCenter.default.post(name: .focusAssistantTab, object: nil)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            // One menu for every AI engine — replaces three separate toolbar
            // buttons that were crowding the top bar. Each entry opens its
            // own sheet / drawer and carries a keyboard shortcut so power
            // users never have to touch the menu.
            Menu {
                Button {
                    showInspector(.monai)
                } label: {
                    Label("MONAI Label — interactive server models",
                          systemImage: "brain.head.profile")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button {
                    showInspector(.nnunet)
                } label: {
                    Label("nnU-Net — catalog of 15 pretrained datasets",
                          systemImage: "square.stack.3d.up.fill")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button {
                    showInspector(.pet)
                } label: {
                    Label("PET Engine — AutoPET + MedSAM2 + TMTV",
                          systemImage: "flame.fill")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                Button {
                    showInspector(.classification)
                } label: {
                    Label("Classify lesions — radiomics / CoreML / MedGemma",
                          systemImage: "square.stack.3d.forward.dottedline")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Divider()

                Button {
                    showInspector(.modelManager)
                } label: {
                    Label("Model Manager — weights + DGX Spark",
                          systemImage: "externaldrive.fill.badge.icloud")
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button {
                    refreshCohortStudies()
                    showInspector(.cohort)
                } label: {
                    Label("Cohort Batch — run segmentation/classification on every study",
                          systemImage: "square.3.layers.3d.down.right")
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            } label: {
                Label("AI Engines", systemImage: "cpu")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("AI Engines\n• MONAI Label (⌘⇧M)\n• nnU-Net (⌘⇧N)\n• PET Engine (⌘⇧P)\n• Classify (⌘⇧C)\n• Model Manager (⌘⇧W)\n• Cohort Batch (⌘⇧B)\nPanels open as side inspectors — ⌘. to close.")

            Spacer()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Label("MPR + VR", systemImage: "rectangle.grid.2x2")
                    Label(vm.activeTool.displayName, systemImage: vm.activeTool.systemImage)
                }
                Label(vm.activeTool.displayName, systemImage: vm.activeTool.systemImage)
                EmptyView()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.displayP3, white: 0.115))
        .overlay(Divider(), alignment: .bottom)
    }

    private var toolbarBrand: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Tracer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Text("diagnostic workstation")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(width: 132, alignment: .leading)

            Text("Tracer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 54, alignment: .leading)
        }
    }

    private var workstationHeader: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if let volume = vm.currentVolume {
                        StudyMetric(label: "Patient", value: volume.patientName.isEmpty ? "Unknown" : volume.patientName)
                        StudyMetric(label: "Study", value: volume.studyDescription.isEmpty ? "Untitled" : volume.studyDescription)
                        StudyMetric(label: "Series", value: volume.seriesDescription.isEmpty ? "Untitled" : volume.seriesDescription)
                        StudyMetric(label: "Modality", value: Modality.normalize(volume.modality).displayName)
                        StudyMetric(label: "W/L", value: "\(Int(vm.window)) / \(Int(vm.level))")
                        StudyMetric(label: "Slices", value: "\(vm.sliceIndices[0]) · \(vm.sliceIndices[1]) · \(vm.sliceIndices[2])")
                    } else {
                        Label("No study loaded", systemImage: "tray")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            workstationStateBadges
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.displayP3, white: 0.075))
        .overlay(Divider(), alignment: .bottom)
    }

    private var workstationStateBadges: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Label("Mini-PACS", systemImage: "server.rack")
                Label(vm.fusion == nil ? "Fusion idle" : "Fusion active", systemImage: "square.2.stack.3d")
                Label(vm.labeling.activeLabelMap == nil ? "Labels idle" : "Labels active", systemImage: "list.bullet.rectangle")
                Label("AI control", systemImage: "sparkles")
            }

            HStack(spacing: 7) {
                Image(systemName: "server.rack")
                Image(systemName: vm.fusion == nil ? "square.2.stack.3d" : "square.2.stack.3d.top.filled")
                Image(systemName: vm.labeling.activeLabelMap == nil ? "list.bullet.rectangle" : "list.bullet.rectangle.fill")
                Image(systemName: "sparkles")
            }

            EmptyView()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            Text(vm.statusMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            Spacer()
        }
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .top)
    }

    private var loadingIndicator: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(vm.statusMessage)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - File handlers

    /// Should engine panels render as `.sheet` (compact) or `.inspector`
    /// (regular)? On macOS we always have the room for an inspector; on
    /// iPad we fall back to a sheet when the horizontal size class is
    /// compact (portrait or split view) so the viewport isn't crushed.
    private var useCompactEnginePresentation: Bool {
        #if canImport(UIKit)
        return hSizeClass == .compact
        #else
        return false
        #endif
    }

    /// Toggle focus mode. In focus mode both the browser and the controls
    /// panel slide out of the way; the center viewport gets the full window.
    private func toggleFocusMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            focusModeEnabled.toggle()
            if !focusModeEnabled {
                browserVisibility = .all
            }
        }
    }

    /// Common "close" chip rendered inside each inspector panel. `.inspector`
    /// doesn't provide its own toolbar, so we overlay a small button top-
    /// right of whichever panel is showing.
    @ViewBuilder
    private func closeInspectorButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .padding(8)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(".", modifiers: [.command])
        .help("Close inspector (⌘.)")
    }

    /// Open one of the engine inspectors; closes any already-open inspector
    /// so only one drawer is visible at a time. Called by the AI Engines
    /// menu items.
    private func showInspector(_ which: EngineInspector) {
        // Close everything first.
        showMONAIPanel = false
        showNNUnetPanel = false
        showPETEnginePanel = false
        showClassificationPanel = false
        showModelManagerPanel = false
        showCohortPanel = false
        // Open the requested one next tick so the close animations settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            switch which {
            case .monai: showMONAIPanel = true
            case .nnunet: showNNUnetPanel = true
            case .pet: showPETEnginePanel = true
            case .classification: showClassificationPanel = true
            case .modelManager: showModelManagerPanel = true
            case .cohort: showCohortPanel = true
            }
        }
    }

    private enum EngineInspector { case monai, nnunet, pet, classification, modelManager, cohort }

    /// Pull the full worklist (every indexed study in the SwiftData store)
    /// into the cohort panel. Called when the user opens the panel so the
    /// cohort always sees the latest worklist without needing an
    /// `@Environment(\.modelContext)` round-trip.
    private func refreshCohortStudies() {
        let descriptor = FetchDescriptor<PACSIndexedSeries>()
        do {
            let seriesSnapshots = try modelContext.fetch(descriptor).map(\.snapshot)
            cohortStudies = PACSWorklistStudy.grouped(from: seriesSnapshots)
        } catch {
            vm.statusMessage = "Cohort: worklist fetch failed — \(error.localizedDescription)"
            cohortStudies = []
        }
    }

    /// Chatbot → classifier. Called when the assistant parses
    /// "classify lesions". Reads the currently-active label map + volume
    /// and hands them to `ClassificationViewModel.classifyAll`.
    /// ClassificationPanel stays closed — the user can open it to see
    /// results, or ask the chat to export directly.
    private func handleAssistantClassificationRequest() {
        guard let volume = vm.currentVolume else {
            vm.statusMessage = "Classify: load a volume first."
            return
        }
        guard let map = vm.labeling.activeLabelMap else {
            vm.statusMessage = "Classify: segment lesions first."
            return
        }
        let classID = vm.labeling.activeClassID
        Task {
            _ = await classification.classifyAll(
                volume: volume,
                labelMap: map,
                classID: classID
            )
        }
    }

    private func handleAssistantClassificationExport(format: String) {
        guard !classification.lastResults.isEmpty else {
            vm.statusMessage = "Nothing to export — classify first."
            return
        }
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format == "json"
            ? "classification.json"
            : "classification.csv"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data: Data
                if format == "json" {
                    data = try ClassificationReport.jsonData(for: classification.lastResults)
                } else {
                    data = ClassificationReport.csvData(for: classification.lastResults)
                }
                try data.write(to: url, options: .atomic)
                vm.statusMessage = "Exported → \(url.lastPathComponent)"
            } catch {
                vm.statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        #else
        vm.statusMessage = "Chat-driven export is macOS-only for now."
        #endif
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        // macOS / iOS sandboxed access
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        Task {
            if fileImporterMode == .overlay {
                await vm.loadOverlay(url: url)
            } else {
                if NIfTILoader.isVolumeFile(url) {
                    await vm.loadNIfTI(url: url)
                } else {
                    // Assume DICOM single file — pick its folder
                    await vm.loadDICOMDirectory(url: url.deletingLastPathComponent())
                }
            }
        }
    }

    private func handleDirectoryImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        Task {
            if directoryImporterMode == .index {
                await vm.indexDirectory(url: url, modelContext: modelContext)
                return
            }

            // Inspect contents: if NIfTI files present, scan as volumes;
            // otherwise as DICOM directory.
            let fm = FileManager.default
            let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            let niftiFiles = contents.filter { NIfTILoader.isVolumeFile($0) }

            if !niftiFiles.isEmpty {
                for f in niftiFiles {
                    await vm.loadNIfTI(url: f)
                }
            } else {
                await vm.loadDICOMDirectory(url: url)
            }
        }
    }
}

private struct StudyMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minWidth: 54, maxWidth: 150, alignment: .leading)
    }
}

// MARK: - Toolbar button with hover tooltip + keyboard shortcut

private struct ToolButton: View {
    let tool: ViewerTool
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            Label(tool.displayName, systemImage: tool.systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 14))
                .foregroundColor(isActive ? .white : (isHovering ? .primary : .secondary))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isActive ? Color.accentColor :
                              (isHovering ? Color.secondary.opacity(0.15) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovering = hovering }
            #if os(macOS)
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            #endif
        }
        .tooltip(tool.helpText)
        .modifier(KeyboardShortcutIfAvailable(character: tool.keyboardShortcut))
    }
}

private struct KeyboardShortcutIfAvailable: ViewModifier {
    let character: Character?
    func body(content: Content) -> some View {
        if let c = character {
            content.keyboardShortcut(KeyEquivalent(c), modifiers: [])
        } else {
            content
        }
    }
}

/// Reusable small icon button with hover feedback + rich tooltip.
public struct HoverIconButton: View {
    let systemImage: String
    let tooltip: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering: Bool = false

    public init(systemImage: String, tooltip: String,
                isActive: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.tooltip = tooltip
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundColor(isActive ? .white : (isHovering ? .primary : .secondary))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isActive ? Color.accentColor :
                              (isHovering ? Color.secondary.opacity(0.25) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovering = hovering }
            #if os(macOS)
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            #endif
        }
        .tooltip(tooltip)
    }
}

// MARK: - MPR Layout

struct MPRLayoutView: View {
    @EnvironmentObject var vm: ViewerViewModel

    var body: some View {
        if vm.currentVolume == nil {
            EmptyWorkstationView()
        } else {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let w = max(0, (geo.size.width - gap) / 2)
                let h = max(0, (geo.size.height - gap) / 2)
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        SliceView(axis: 2, title: "Axial")
                            .frame(width: w, height: h)
                        SliceView(axis: 0, title: "Sagittal")
                            .frame(width: w, height: h)
                    }
                    HStack(spacing: gap) {
                        SliceView(axis: 1, title: "Coronal")
                            .frame(width: w, height: h)
                        VolumeRenderingPane()
                            .frame(width: w, height: h)
                    }
                }
            }
            .background(Color.black)
        }
    }
}

private struct EmptyWorkstationView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.grid.2x2")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)

            VStack(spacing: 4) {
                Text("No study loaded")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Open a DICOM folder or NIfTI volume to begin.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    NotificationCenter.default.post(name: .openDICOMDirectory, object: nil)
                } label: {
                    Label("DICOM Folder", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    NotificationCenter.default.post(name: .openNIfTIFile, object: nil)
                } label: {
                    Label("NIfTI File", systemImage: "doc")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

// MARK: - Compact-aware engine presentation

private extension View {
    /// Routes an engine panel to `.inspector` on regular-width devices and
    /// to `.sheet` on compact widths (iPad portrait / narrow splits). One
    /// call site per engine keeps ContentView's body small while still
    /// giving each engine its own presentation flag.
    @ViewBuilder
    func engineInspector<Body: View>(
        isCompact: Bool,
        isPresented: Binding<Bool>,
        inspectorWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat),
        @ViewBuilder content: @escaping () -> Body
    ) -> some View {
        if isCompact {
            self.sheet(isPresented: isPresented) {
                content()
                    .frame(minWidth: inspectorWidth.min,
                           minHeight: 560)
            }
        } else {
            self.inspector(isPresented: isPresented) {
                content()
                    .inspectorColumnWidth(
                        min: inspectorWidth.min,
                        ideal: inspectorWidth.ideal,
                        max: inspectorWidth.max
                    )
            }
        }
    }
}
