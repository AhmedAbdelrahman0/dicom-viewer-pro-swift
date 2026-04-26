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
    @StateObject private var lesionDetector = LesionDetectorViewModel()
    @StateObject private var cohortForm = CohortFormViewModel()
    @StateObject private var petAC = PETACViewModel()
    @StateObject private var reconstruction = NuclearReconstructionViewModel()
    @StateObject private var syntheticCT = SyntheticCTViewModel()
    @StateObject private var dosimetry = Lu177DosimetryViewModel()
    @StateObject private var activity = ActivityLogStore.shared
    @StateObject private var jobs = JobCenterStore.shared
    /// Dictation session — survives panel open/close so an in-progress
    /// transcript isn't lost when the user toggles the inspector. Engine
    /// (Apple Speech today, WhisperKit later) is hot-swappable via
    /// `dictation.setEngine(_:)`.
    @StateObject private var dictation = DictationSession()
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
    @State private var showLesionDetectorPanel = false
    @State private var showPETACPanel = false
    @State private var showNuclearToolsPanel = false
    @State private var showDictationPanel = false
    @State private var cohortStudies: [PACSWorklistStudy] = []
    @State private var showAboutWindow = false
    @State private var showOnboarding = false
    @State private var showJobCenter = false
    @State private var showActivityLog = false
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

            activityFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(TracerTheme.accent)
        .environmentObject(vm)
        .environmentObject(monai)
        .environmentObject(nnunet)
        .environmentObject(activity)
        .environmentObject(jobs)
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
                        form: cohortForm,
                        availableStudies: cohortStudies)
                .overlay(alignment: .topTrailing) {
                    closeInspectorButton { showCohortPanel = false }
                }
        }
        .engineInspector(
            isCompact: useCompactEnginePresentation,
            isPresented: $showLesionDetectorPanel,
            inspectorWidth: (min: 480, ideal: 540, max: 700)
        ) {
            LesionDetectorPanel(viewer: vm, detector: lesionDetector)
                .overlay(alignment: .topTrailing) {
                    closeInspectorButton { showLesionDetectorPanel = false }
                }
        }
        .engineInspector(
            isCompact: useCompactEnginePresentation,
            isPresented: $showPETACPanel,
            inspectorWidth: (min: 480, ideal: 540, max: 660)
        ) {
            PETACPanel(viewer: vm, ac: petAC)
                .overlay(alignment: .topTrailing) {
                    closeInspectorButton { showPETACPanel = false }
                }
        }
        .engineInspector(
            isCompact: useCompactEnginePresentation,
            isPresented: $showNuclearToolsPanel,
            inspectorWidth: (min: 540, ideal: 620, max: 780)
        ) {
            NuclearToolsPanel(viewer: vm,
                              reconstruction: reconstruction,
                              syntheticCT: syntheticCT,
                              dosimetry: dosimetry)
                .overlay(alignment: .topTrailing) {
                    closeInspectorButton { showNuclearToolsPanel = false }
                }
        }
        .modifier(DictationInspectorModifier(
            isCompact: useCompactEnginePresentation,
            isPresented: $showDictationPanel,
            session: dictation,
            close: { showDictationPanel = false }
        ))
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
        .modifier(TracerMenuCommandHandler(vm: vm,
                                           toggleFocusMode: toggleFocusMode,
                                           showEngineInspector: showEngineInspector(named:)))
        .onReceive(NotificationCenter.default.publisher(for: .recentVolumesDidChange)) { _ in
            vm.reloadRecentVolumes()
        }
        .modifier(ActivityLogHooks(vm: vm,
                                   monai: monai,
                                   nnunet: nnunet,
                                   pet: pet,
                                   classification: classification,
                                   modelManager: modelManager,
                                   cohort: cohort,
                                   lesionDetector: lesionDetector,
                                   petAC: petAC,
                                   reconstruction: reconstruction,
                                   syntheticCT: syntheticCT,
                                   dosimetry: dosimetry,
                                   activity: activity))
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
        .onReceive(NotificationCenter.default.publisher(for: .assistantDidRequestLesionDetection)) { _ in
            handleAssistantLesionDetection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantDidRequestLesionDetectorPanel)) { _ in
            showInspector(.lesionDetector)
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantDidRequestPETAttenuationCorrection)) { _ in
            handleAssistantPETACRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantDidRequestPETACPanel)) { _ in
            showInspector(.petAC)
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
            activity.log("Tracer ready.", source: "System", level: .success, countAsUnread: false)
        }
        .tooltipHost()  // must wrap the whole window so tooltips escape any clipping
        .background(TracerTheme.windowBackground)
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
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 400)
        } content: {
            workstationScaffold
                .navigationSplitViewColumnWidth(min: 360, ideal: 960)
        } detail: {
            ControlsPanel()
                .environmentObject(vm)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
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
        .background(TracerTheme.viewportBackground)
    }

    // MARK: - Custom toolbar (in-content so hover + tooltips work reliably)

    private var customToolbar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    toolbarControls
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
            .lineLimit(1)
            .padding(.trailing, 8)
        }
        .background(TracerTheme.toolbarBackground)
        .overlay(Rectangle().fill(TracerTheme.hairline).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private var toolbarControls: some View {
        toolbarBrand

        Divider()
            .frame(height: 20)
            .padding(.trailing, 4)

        ForEach(ViewerTool.allCases) { tool in
            ToolButton(
                tool: tool,
                isActive: vm.activeTool == tool,
                action: { vm.setActiveViewerTool(tool) }
            )
        }

        Divider()
            .frame(height: 20)
            .padding(.horizontal, 4)

        HoverIconButton(
            systemImage: "arrow.uturn.backward",
            tooltip: "Undo (⌘Z)\nReverts the last app action: labels, measurements, windowing, fusion, layout, zoom/pan, or display changes."
        ) {
            vm.undoLastEdit()
        }
        .disabled(!vm.canUndo)
        .keyboardShortcut("z", modifiers: [.command])

        HoverIconButton(
            systemImage: "arrow.uturn.forward",
            tooltip: "Redo (⌘⇧Z)\nReapplies the last undone app action."
        ) {
            vm.redoLastEdit()
        }
        .disabled(!vm.canRedo)
        .keyboardShortcut("z", modifiers: [.command, .shift])

        HoverIconButton(
            systemImage: "arrow.counterclockwise.circle",
            tooltip: "Reset editable changes\nClears label voxels, measurements, zoom/pan, and display overrides while keeping loaded studies."
        ) {
            vm.resetEditableChanges()
        }
        .disabled(vm.isVolumeOperationRunning)

        HoverIconButton(
            systemImage: vm.linkZoomPanAcrossPanes ? "link" : "link.badge.plus",
            tooltip: vm.linkZoomPanAcrossPanes
                ? "Linked Zoom/Pan: All Panes\nPan or zoom in one pane and all four windows move together."
                : "Linked Zoom/Pan: Single Pane\nClick to link all four windows.",
            isActive: vm.linkZoomPanAcrossPanes
        ) {
            vm.setLinkZoomPanAcrossPanes(!vm.linkZoomPanAcrossPanes)
        }

        orientationMenu

        hangingLayoutMenu

        petDisplayMenu

        HoverIconButton(
            systemImage: "flame",
            tooltip: "Measure PET SUV / MTV / TLG\nCalculates SUVmax, SUVmean, metabolic tumor volume, and TLG for the active label without blocking the viewer.",
            isActive: vm.volumeOperationStatus?.title.contains("SUV") == true
        ) {
            vm.startActiveVolumeMeasurement(
                method: .activeLabel,
                thresholdSummary: "Active PET label",
                preferPET: true
            )
        }
        .disabled(vm.labeling.activeLabelMap == nil || vm.isVolumeOperationRunning)

        volumetryMenu

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

            Button {
                showInspector(.lesionDetector)
            } label: {
                Label("Lesion Detection — boxes + classes in one pass",
                      systemImage: "viewfinder.circle")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button {
                showInspector(.petAC)
            } label: {
                Label("PET Attenuation Correction — produce AC PET from NAC PET",
                      systemImage: "wand.and.rays")
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Button {
                showInspector(.nuclearTools)
            } label: {
                Label("Nuclear Tools — reconstruction, synthetic CT, Lu-177",
                      systemImage: "atom")
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])

            Divider()

            Button {
                showInspector(.dictation)
            } label: {
                Label("Dictation — push-to-talk reporting + AI",
                      systemImage: "waveform.and.mic")
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        } label: {
            Label("AI Engines", systemImage: "cpu")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("AI Engines\n• MONAI Label (⌘⇧M)\n• nnU-Net (⌘⇧N)\n• PET Engine (⌘⇧P)\n• Classify (⌘⇧C)\n• Model Manager (⌘⇧W)\n• Cohort Batch (⌘⇧B)\n• Lesion Detection (⌘⇧D)\n• PET AC (⌘⇧K)\n• Nuclear Tools (⌘⇧U)\n• Dictation (⌘⇧V)\nPanels open as side inspectors — ⌘. to close.")
    }

    private var orientationMenu: some View {
        Menu {
            Toggle("Flip A/P Display Axis", isOn: Binding(
                get: { vm.correctAnteriorPosteriorDisplay },
                set: { vm.setCorrectAnteriorPosteriorDisplay($0) }
            ))
            Toggle("Flip R/L Display Axis", isOn: Binding(
                get: { vm.correctRightLeftDisplay },
                set: { vm.setCorrectRightLeftDisplay($0) }
            ))
            Divider()
            Button {
                vm.setDisplayOrientationCorrection(ap: false, rl: false, name: "Native geometry")
            } label: {
                Label("Native Geometry", systemImage: "arrow.counterclockwise")
            }
            Button {
                vm.setDisplayOrientationCorrection(ap: true, rl: false, name: "Radiology default")
            } label: {
                Label("Radiology Default", systemImage: "viewfinder")
            }
        } label: {
            Label("Position", systemImage: "arrow.left.and.right")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Image Positioning\nControls anterior/posterior and right/left display flips from the toolbar.")
    }

    private var petDisplayMenu: some View {
        Menu {
            Picker("Fusion PET Color", selection: Binding(
                get: { vm.overlayColormap },
                set: { vm.setFusionColormap($0) }
            )) {
                ForEach(Colormap.allCases) { color in
                    Text(color.displayName).tag(color)
                }
            }
            Picker("MIP PET Color", selection: Binding(
                get: { vm.mipColormap },
                set: { vm.setPETMIPColormap($0) }
            )) {
                ForEach(Colormap.allCases) { color in
                    Text(color.displayName).tag(color)
                }
            }
            Toggle("Invert MIP", isOn: Binding(
                get: { vm.invertPETMIP },
                set: { vm.setInvertPETMIP($0) }
            ))
            Divider()
            Button("SUV 0–5") { vm.setPETOverlayRange(min: 0, max: 5) }
            Button("SUV 0–10") { vm.setPETOverlayRange(min: 0, max: 10) }
            Button("SUV 0–15") { vm.setPETOverlayRange(min: 0, max: 15) }
            Button("SUV 2.5–15") { vm.setPETOverlayRange(min: 2.5, max: 15) }
            Button {
                if let pet = vm.activePETQuantificationVolume {
                    let range = vm.petSUVDisplayRange(for: pet)
                    vm.setPETOverlayRange(min: max(0, range.min), max: max(1, range.max))
                }
            } label: {
                Label("Auto SUV Range", systemImage: "wand.and.stars")
            }
        } label: {
            Label("PET Color", systemImage: "paintpalette")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("PET Coloring\nFusion and PET-only panes can use heat maps while MIP uses a separate black/white or custom map.")
    }

    private var hangingLayoutMenu: some View {
        Menu {
            ForEach(HangingGridLayout.presets, id: \.displayName) { layout in
                Button {
                    vm.setHangingGrid(layout)
                } label: {
                    Label(layout.displayName, systemImage: layout == vm.hangingGrid ? "checkmark.rectangle" : "rectangle.grid.2x2")
                }
            }
            Divider()
            Button {
                vm.resetPETHangingProtocol()
            } label: {
                Label("PET/CT Default", systemImage: "square.2.layers.3d")
            }
            Button {
                vm.resetMRIHangingProtocol()
            } label: {
                Label("MRI Multi-Series", systemImage: "brain.head.profile")
            }
            Button {
                vm.resetPETMRHangingProtocol()
            } label: {
                Label("PET/MR Fusion", systemImage: "brain")
            }
            Button {
                vm.resetUnifiedHangingProtocol()
            } label: {
                Label("Unified CT/MR/PET", systemImage: "rectangle.grid.3x2")
            }
        } label: {
            Label(vm.hangingGrid.displayName, systemImage: "rectangle.grid.2x2")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Viewport Layout\nChoose 1, 2x1, 2x2, 4x4, 8x8, or use the Controls panel for custom rows and columns.")
    }

    private var volumetryMenu: some View {
        Menu {
            Button {
                vm.ensureActiveLabelMapForCurrentContext()
                vm.statusMessage = "Active label map ready for PET/CT volume measurements"
            } label: {
                Label("Create / Select Volume Label", systemImage: "plus.square.on.square")
            }
            Divider()
            Button {
                vm.startThresholdActiveLabel(atOrAbove: vm.labeling.thresholdValue)
            } label: {
                Label(String(format: "PET Fixed SUV ≥ %.1f", vm.labeling.thresholdValue),
                      systemImage: "greaterthan.circle")
            }
            Button {
                vm.startPercentOfMaxActiveLabelWholeVolume(percent: vm.labeling.percentOfMax)
            } label: {
                Label(String(format: "PET %.0f%% SUVmax", vm.labeling.percentOfMax * 100),
                      systemImage: "percent")
            }
            Button {
                vm.setActiveLabelingTool(.suvGradient)
            } label: {
                Label("PET Gradient Seed Tool", systemImage: "waveform.path.ecg")
            }
            Divider()
            ForEach(HUThresholdPreset.presets) { preset in
                Button {
                    vm.startThresholdActiveCTLabel(lowerHU: preset.lower, upperHU: preset.upper)
                } label: {
                    Label("\(preset.name) \(Int(preset.lower))...\(Int(preset.upper)) HU",
                          systemImage: "cube")
                }
            }
            Divider()
            Button {
                vm.startActiveVolumeMeasurement(
                    method: .activeLabel,
                    thresholdSummary: "Active PET label",
                    preferPET: true
                )
            } label: {
                Label("Measure PET SUV / Volume", systemImage: "flame")
            }
            Button {
                vm.startActiveVolumeMeasurement(
                    method: .activeLabel,
                    thresholdSummary: "Active CT label",
                    preferPET: false
                )
            } label: {
                Label("Measure CT HU / Volume", systemImage: "cube")
            }
            if let report = vm.lastVolumeMeasurementReport {
                Divider()
                Text(report.className)
                Text(String(format: "Volume %.2f mL", report.volumeML))
                if let suvMax = report.suvMax {
                    Text(String(format: "SUVmax %.2f", suvMax))
                }
                if let suvMean = report.suvMean {
                    Text(String(format: "SUVmean %.2f", suvMean))
                }
                if let tlg = report.tlg {
                    Text(String(format: "TLG %.1f", tlg))
                }
            }
        } label: {
            Label("SUV/Volumes", systemImage: "chart.bar.doc.horizontal")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("PET/CT Volume Tools\nVisible toolbar access to SUV metrics, MTV/TLG, HU volume masks, and active-label measurement.")
    }

    private var toolbarBrand: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tracerMark
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tracer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("oncology AI workstation")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(TracerTheme.mutedText)
                }
            }
            .frame(width: 164, alignment: .leading)

            HStack(spacing: 6) {
                tracerMark
                Text("Tracer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .frame(width: 84, alignment: .leading)
        }
    }

    private var tracerMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(TracerTheme.activeGradient)
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black.opacity(0.72))
        }
        .frame(width: 24, height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(0.20), lineWidth: 1)
        )
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
        .background(TracerTheme.headerBackground)
        .overlay(Rectangle().fill(TracerTheme.hairline).frame(height: 1), alignment: .bottom)
    }

    private var workstationStateBadges: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                WorkstationBadge("Mini-PACS", systemImage: "server.rack", color: TracerTheme.accent)
                WorkstationBadge(vm.fusion == nil ? "Fusion idle" : "Fusion active",
                                 systemImage: "square.2.stack.3d",
                                 color: vm.fusion == nil ? .secondary : TracerTheme.pet)
                WorkstationBadge(vm.labeling.activeLabelMap == nil ? "Labels idle" : "Labels active",
                                 systemImage: "list.bullet.rectangle",
                                 color: vm.labeling.activeLabelMap == nil ? .secondary : TracerTheme.label)
                WorkstationBadge("AI control", systemImage: "sparkles", color: TracerTheme.accentBright)
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
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Activity bar

    private var activityFooter: some View {
        VStack(spacing: 0) {
            if showJobCenter {
                JobCenterPanel(jobs: jobs) { job in
                    cancel(job)
                }
                .frame(height: 230)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showActivityLog {
                ActivityLogPanel(activity: activity)
                    .frame(height: 170)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            activityBar
        }
        .background(TracerTheme.panelBackground)
        .overlay(Rectangle().fill(TracerTheme.hairline).frame(height: 1), alignment: .top)
        .onAppear {
            syncJobCenter()
        }
        .onChange(of: activeOperationsDigest) { _, _ in
            syncJobCenter()
        }
    }

    private var activityBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showJobCenter.toggle()
                    if showJobCenter {
                        showActivityLog = false
                        jobs.markRead()
                    }
                }
            } label: {
                Label(showJobCenter ? "Hide jobs" : "Jobs",
                      systemImage: showJobCenter ? "chevron.down.circle" : "list.bullet.clipboard")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Show Job Center")

            if jobs.unreadIssueCount > 0 && !showJobCenter {
                Text("\(jobs.unreadIssueCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange))
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showActivityLog.toggle()
                    if showActivityLog {
                        showJobCenter = false
                        activity.markRead()
                    }
                }
            } label: {
                Label(showActivityLog ? "Hide logs" : "Logs",
                      systemImage: showActivityLog ? "chevron.down.circle" : "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Show operation logs")

            if activity.unreadCount > 0 && !showActivityLog {
                Text("\(activity.unreadCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(TracerTheme.accent))
            }

            Divider()
                .frame(height: 18)

            let operations = activeOperations
            if operations.isEmpty {
                Image(systemName: vm.isLoading ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .foregroundColor(vm.isLoading ? TracerTheme.accentBright : .secondary)
                Text(vm.statusMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 8) {
                        ForEach(operations) { operation in
                            ActivityOperationChip(operation: operation) {
                                cancel(operation)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 8)

            Text(Date.now, style: .time)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))

            Button {
                activity.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Clear logs")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 32)
    }

    private var activeOperations: [ActivityOperationSnapshot] {
        var operations: [ActivityOperationSnapshot] = []

        if vm.isIndexing {
            operations.append(ActivityOperationSnapshot(
                id: "pacs-index",
                title: "PACS indexing",
                stage: vm.indexProgress?.phase.rawValue.capitalized ?? "Scanning",
                detail: vm.indexProgress?.statusText ?? vm.statusMessage,
                progress: nil,
                systemImage: "externaldrive.badge.magnifyingglass",
                cancelTarget: .indexing
            ))
        } else if vm.isLoading {
            operations.append(ActivityOperationSnapshot(
                id: "viewer-loading",
                title: "Loading study",
                stage: "Import",
                detail: vm.statusMessage,
                progress: vm.progress > 0 ? vm.progress : nil,
                systemImage: "square.and.arrow.down",
                cancelTarget: nil
            ))
        }

        if let operation = vm.volumeOperationStatus {
            operations.append(ActivityOperationSnapshot(
                id: operation.id.uuidString,
                title: operation.title,
                stage: operation.detail,
                detail: "Running since \(operation.startedAt.formatted(date: .omitted, time: .shortened))",
                progress: nil,
                systemImage: "point.3.connected.trianglepath.dotted",
                cancelTarget: .volumeOperation
            ))
        }

        if monai.isBusy {
            operations.append(ActivityOperationSnapshot(id: "monai",
                                                        title: "MONAI Label",
                                                        stage: monai.isConnected ? "Inference / server" : "Connect",
                                                        detail: monai.statusMessage,
                                                        progress: nil,
                                                        systemImage: "network",
                                                        cancelTarget: nil))
        }
        if nnunet.isRunning {
            operations.append(ActivityOperationSnapshot(id: "nnunet",
                                                        title: "nnU-Net",
                                                        stage: nnunet.mode.displayName,
                                                        detail: nnunet.statusMessage,
                                                        progress: nil,
                                                        systemImage: "brain.head.profile",
                                                        cancelTarget: .nnunet))
        }
        if pet.isRunning {
            operations.append(ActivityOperationSnapshot(id: "pet-engine",
                                                        title: "PET Engine",
                                                        stage: "Segmentation / quantification",
                                                        detail: pet.statusMessage,
                                                        progress: nil,
                                                        systemImage: "flame",
                                                        cancelTarget: nil))
        }
        if classification.isRunning {
            operations.append(ActivityOperationSnapshot(id: "classification",
                                                        title: "Classification",
                                                        stage: "Lesion model",
                                                        detail: classification.statusMessage,
                                                        progress: nil,
                                                        systemImage: "chart.bar.doc.horizontal",
                                                        cancelTarget: nil))
        }
        if cohort.isRunning {
            operations.append(ActivityOperationSnapshot(id: "cohort",
                                                        title: "Cohort",
                                                        stage: cohortStatusStage,
                                                        detail: cohort.statusMessage,
                                                        progress: cohort.progressFraction,
                                                        systemImage: "rectangle.stack.badge.play",
                                                        cancelTarget: .cohort))
        }
        if lesionDetector.isRunning {
            operations.append(ActivityOperationSnapshot(id: "detector",
                                                        title: "Lesion detector",
                                                        stage: "Inference",
                                                        detail: lesionDetector.statusMessage,
                                                        progress: nil,
                                                        systemImage: "scope",
                                                        cancelTarget: nil))
        }
        if petAC.isRunning {
            operations.append(ActivityOperationSnapshot(id: "pet-ac",
                                                        title: "PET AC",
                                                        stage: "Correction",
                                                        detail: petAC.statusMessage,
                                                        progress: nil,
                                                        systemImage: "wand.and.stars",
                                                        cancelTarget: nil))
        }
        if reconstruction.isRunning {
            operations.append(ActivityOperationSnapshot(id: "reconstruction",
                                                        title: "Reconstruction",
                                                        stage: reconstruction.algorithm.displayName,
                                                        detail: reconstruction.statusMessage,
                                                        progress: nil,
                                                        systemImage: "waveform.path.ecg.rectangle",
                                                        cancelTarget: .reconstruction))
        }
        if syntheticCT.isRunning {
            operations.append(ActivityOperationSnapshot(id: "synthetic-ct",
                                                        title: "Synthetic CT",
                                                        stage: syntheticCT.method.displayName,
                                                        detail: syntheticCT.statusMessage,
                                                        progress: nil,
                                                        systemImage: "sparkles.rectangle.stack",
                                                        cancelTarget: .syntheticCT))
        }
        if dosimetry.isRunning {
            operations.append(ActivityOperationSnapshot(id: "dosimetry",
                                                        title: "Lu-177 dosimetry",
                                                        stage: "Dose map",
                                                        detail: dosimetry.statusMessage,
                                                        progress: nil,
                                                        systemImage: "atom",
                                                        cancelTarget: .dosimetry))
        }

        for (modelID, status) in modelManager.downloader.statusByModelID.sorted(by: { $0.key < $1.key }) {
            if let operation = downloadOperation(modelID: modelID, status: status) {
                operations.append(operation)
            }
        }

        return operations
    }

    private var activeOperationsDigest: String {
        activeOperations
            .map { operation in
                [
                    operation.id,
                    operation.title,
                    operation.stage,
                    operation.detail,
                    operation.progress.map { String(format: "%.4f", $0) } ?? "nil",
                    operation.cancelTarget == nil ? "fixed" : "cancel"
                ].joined(separator: "\u{1f}")
            }
            .joined(separator: "\u{1e}")
    }

    private func syncJobCenter() {
        completeTerminalDownloadJobs()
        jobs.sync(active: activeOperations.map(\.jobUpdate))
    }

    private func completeTerminalDownloadJobs() {
        for (modelID, status) in modelManager.downloader.statusByModelID {
            let displayName = modelManager.store.models.first(where: { $0.id == modelID })?.displayName ?? modelID
            switch status {
            case .failed(let message):
                jobs.complete(operationID: "download-\(modelID)",
                              state: .failed,
                              detail: "\(displayName) download failed: \(message)")
                jobs.complete(operationID: "verify-\(modelID)",
                              state: .failed,
                              detail: "\(displayName) verification failed: \(message)")
            case .cancelled:
                jobs.complete(operationID: "download-\(modelID)",
                              state: .cancelled,
                              detail: "\(displayName) download cancelled")
                jobs.complete(operationID: "verify-\(modelID)",
                              state: .cancelled,
                              detail: "\(displayName) verification cancelled")
            case .idle, .downloading, .verifying, .completed:
                break
            }
        }
    }

    private var cohortStatusStage: String {
        guard let cp = cohort.checkpoint else { return "Queued" }
        return "\(cp.doneCount + cp.failedCount + cp.skippedCount)/\(cp.total) studies"
    }

    private func downloadOperation(modelID: String,
                                   status: ModelDownloadManager.DownloadStatus) -> ActivityOperationSnapshot? {
        let displayName = modelManager.store.models.first(where: { $0.id == modelID })?.displayName ?? modelID
        switch status {
        case .idle, .completed, .failed, .cancelled:
            return nil
        case .downloading(let bytesReceived, let totalBytes):
            let progress = totalBytes > 0 ? Double(bytesReceived) / Double(totalBytes) : nil
            return ActivityOperationSnapshot(id: "download-\(modelID)",
                                             title: "Model download",
                                             stage: displayName,
                                             detail: byteProgress(bytesReceived, totalBytes),
                                             progress: progress,
                                             systemImage: "arrow.down.circle",
                                             cancelTarget: .modelDownload(modelID))
        case .verifying:
            return ActivityOperationSnapshot(id: "verify-\(modelID)",
                                             title: "Model verify",
                                             stage: displayName,
                                             detail: "Checking SHA-256",
                                             progress: nil,
                                             systemImage: "checkmark.shield",
                                             cancelTarget: nil)
        }
    }

    private func cancel(_ operation: ActivityOperationSnapshot) {
        guard let target = operation.cancelTarget else { return }
        switch target {
        case .volumeOperation:
            vm.cancelVolumeOperation()
            activity.log("Cancelled \(operation.title).", source: "Viewer", level: .warning)
        case .indexing:
            vm.cancelIndexing()
            activity.log("Cancelled PACS indexing.", source: "PACS", level: .warning)
        case .nnunet:
            nnunet.cancel()
            activity.log("Cancelled nnU-Net.", source: "nnU-Net", level: .warning)
        case .cohort:
            cohort.cancel()
            activity.log("Cancelled cohort run.", source: "Cohort", level: .warning)
        case .reconstruction:
            reconstruction.cancel()
            activity.log("Cancelled reconstruction.", source: "Reconstruction", level: .warning)
        case .syntheticCT:
            syntheticCT.cancel()
            activity.log("Cancelled synthetic CT.", source: "Synthetic CT", level: .warning)
        case .dosimetry:
            dosimetry.cancel()
            activity.log("Cancelled dosimetry.", source: "Dosimetry", level: .warning)
        case .modelDownload(let id):
            modelManager.downloader.cancel(modelID: id)
            activity.log("Cancelled model download.", source: "Models", level: .warning)
        }
    }

    private func cancel(_ job: JobRecord) {
        guard let operation = activeOperations.first(where: { $0.id == job.operationID }) else {
            jobs.markCancellationRequested(recordID: job.id)
            activity.log("Cancellation requested for \(job.title), but the operation is no longer active.",
                         source: "Job Center",
                         level: .warning)
            return
        }
        jobs.markCancellationRequested(recordID: job.id)
        cancel(operation)
    }

    private func byteProgress(_ received: Int64, _ total: Int64) -> String {
        guard total > 0 else { return "\(byteString(received)) received" }
        return "\(byteString(received)) / \(byteString(total))"
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
        showLesionDetectorPanel = false
        showPETACPanel = false
        showNuclearToolsPanel = false
        showDictationPanel = false
        // Open the requested one next tick so the close animations settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            switch which {
            case .monai: showMONAIPanel = true
            case .nnunet: showNNUnetPanel = true
            case .pet: showPETEnginePanel = true
            case .classification: showClassificationPanel = true
            case .modelManager: showModelManagerPanel = true
            case .cohort: showCohortPanel = true
            case .lesionDetector: showLesionDetectorPanel = true
            case .petAC: showPETACPanel = true
            case .nuclearTools: showNuclearToolsPanel = true
            case .dictation: showDictationPanel = true
            }
        }
    }

    private enum EngineInspector { case monai, nnunet, pet, classification, modelManager, cohort, lesionDetector, petAC, nuclearTools, dictation }

    private func showEngineInspector(named raw: String) {
        switch raw {
        case "monai": showInspector(.monai)
        case "nnunet": showInspector(.nnunet)
        case "pet": showInspector(.pet)
        case "classification": showInspector(.classification)
        case "modelManager": showInspector(.modelManager)
        case "cohort":
            refreshCohortStudies()
            showInspector(.cohort)
        case "lesionDetector": showInspector(.lesionDetector)
        case "petAC": showInspector(.petAC)
        case "nuclearTools": showInspector(.nuclearTools)
        case "dictation": showInspector(.dictation)
        default:
            vm.statusMessage = "Unknown panel: \(raw)"
        }
    }

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

    /// Chatbot → lesion detector. Picks the active volume + an
    /// auxiliary anatomical channel (when configured) and runs the
    /// LesionDetectorViewModel. Detection results land in the panel,
    /// which the user can open separately to see + jump to.
    private func handleAssistantLesionDetection() {
        guard let volume = vm.currentVolume else {
            vm.statusMessage = "Detection: load a volume first."
            return
        }
        let anatomical: ImageVolume? = {
            guard lesionDetector.useAnatomicalChannel
                  || (lesionDetector.selectedEntry?.requiresAnatomicalChannel ?? false) else {
                return nil
            }
            if let pair = vm.fusion, pair.baseVolume.id != volume.id {
                return pair.baseVolume
            }
            return vm.loadedVolumes.first {
                $0.id != volume.id
                && (Modality.normalize($0.modality) == .CT
                    || Modality.normalize($0.modality) == .MR)
            }
        }()
        Task {
            _ = await lesionDetector.run(volume: volume, anatomical: anatomical)
        }
    }

    /// Chatbot → PET attenuation correction. Picks the active PET (the
    /// fusion overlay if there's a fusion, else any loaded PET volume,
    /// else the current volume if it's PET) and runs the configured AC
    /// model. The AC volume installs as a new series; the panel doesn't
    /// have to be open for this to work.
    private func handleAssistantPETACRequest() {
        let petVolume: ImageVolume? = {
            if let pair = vm.fusion,
               Modality.normalize(pair.overlayVolume.modality) == .PT {
                return pair.overlayVolume
            }
            if let pet = vm.loadedVolumes.first(where: {
                Modality.normalize($0.modality) == .PT
            }) {
                return pet
            }
            if let cur = vm.currentVolume,
               Modality.normalize(cur.modality) == .PT {
                return cur
            }
            return nil
        }()
        guard let petVolume else {
            vm.statusMessage = "AC: load a PET volume first."
            return
        }
        let anatomical: ImageVolume? = {
            guard petAC.useAnatomicalChannel
                  || (petAC.selectedEntry?.requiresAnatomicalChannel ?? false) else {
                return nil
            }
            if let pair = vm.fusion,
               Modality.normalize(pair.baseVolume.modality) != .PT {
                return pair.baseVolume
            }
            return vm.loadedVolumes.first {
                let m = Modality.normalize($0.modality)
                return m == .CT || m == .MR
            }
        }()
        Task {
            _ = await petAC.run(nacPET: petVolume,
                                anatomical: anatomical,
                                viewer: vm)
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

private struct WorkstationBadge: View {
    let title: String
    let systemImage: String
    let color: Color

    init(_ title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(color, TracerTheme.mutedText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(color.opacity(0.22), lineWidth: 1)
            )
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
                .foregroundColor(isActive ? .black.opacity(0.82) : (isHovering ? .primary : .secondary))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isActive ? AnyShapeStyle(TracerTheme.activeGradient) :
                              AnyShapeStyle(isHovering ? TracerTheme.accent.opacity(0.16) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isActive ? TracerTheme.accentBright.opacity(0.65) : Color.clear,
                                lineWidth: 1)
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

private struct TracerMenuCommandHandler: ViewModifier {
    @ObservedObject var vm: ViewerViewModel
    let toggleFocusMode: () -> Void
    let showEngineInspector: (String) -> Void

    func body(content: Content) -> some View {
        content
            .modifier(TracerToolMenuCommandHandler(vm: vm))
            .modifier(TracerEditMenuCommandHandler(vm: vm, toggleFocusMode: toggleFocusMode))
            .modifier(TracerEngineMenuCommandHandler(showEngineInspector: showEngineInspector))
    }
}

private struct TracerToolMenuCommandHandler: ViewModifier {
    @ObservedObject var vm: ViewerViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .selectViewerTool)) { note in
                guard let raw = note.userInfo?["tool"] as? String,
                      let tool = ViewerTool(rawValue: raw) else { return }
                vm.setActiveViewerTool(tool)
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectLabelingTool)) { note in
                guard let raw = note.userInfo?["tool"] as? String,
                      let tool = LabelingTool(rawValue: raw) else { return }
                vm.setActiveLabelingTool(tool)
            }
            .onReceive(NotificationCenter.default.publisher(for: .createLabelMap)) { _ in
                vm.ensureActiveLabelMapForCurrentContext()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clearMeasurements)) { _ in
                vm.clearAllMeasurements()
            }
            .onReceive(NotificationCenter.default.publisher(for: .saveStudySession)) { _ in
                vm.saveCurrentStudySession()
            }
            .onReceive(NotificationCenter.default.publisher(for: .newStudySession)) { _ in
                vm.newStudyMeasurementSession()
            }
    }
}

private struct TracerEditMenuCommandHandler: ViewModifier {
    @ObservedObject var vm: ViewerViewModel
    let toggleFocusMode: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .undoLastEdit)) { _ in
                vm.undoLastEdit()
            }
            .onReceive(NotificationCenter.default.publisher(for: .redoLastEdit)) { _ in
                vm.redoLastEdit()
            }
            .onReceive(NotificationCenter.default.publisher(for: .resetEditableChanges)) { _ in
                vm.resetEditableChanges()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleLinkedZoomPan)) { _ in
                vm.setLinkZoomPanAcrossPanes(!vm.linkZoomPanAcrossPanes)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
                toggleFocusMode()
            }
    }
}

private struct TracerEngineMenuCommandHandler: ViewModifier {
    let showEngineInspector: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showEngineInspector)) { note in
                guard let raw = note.userInfo?["panel"] as? String else { return }
                showEngineInspector(raw)
            }
    }
}

/// Wraps the dictation panel's `engineInspector` modifier so the main
/// `body` doesn't grow the modifier chain past Swift's type-inference
/// budget. (SwiftUI `body` builders type-check each `.modifier(...)` link;
/// past ~10 panels in one chain the inference times out.)
private struct DictationInspectorModifier: ViewModifier {
    let isCompact: Bool
    @Binding var isPresented: Bool
    @ObservedObject var session: DictationSession
    let close: () -> Void

    func body(content: Content) -> some View {
        content.engineInspector(
            isCompact: isCompact,
            isPresented: $isPresented,
            inspectorWidth: (min: 460, ideal: 520, max: 680)
        ) {
            DictationPanel(session: session)
                .overlay(alignment: .topTrailing) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                            .padding(8)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(".", modifiers: [.command])
                    .help("Close inspector (⌘.)")
                }
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
                .foregroundColor(isActive ? .black.opacity(0.82) : (isHovering ? .primary : .secondary))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isActive ? AnyShapeStyle(TracerTheme.activeGradient) :
                              AnyShapeStyle(isHovering ? TracerTheme.accent.opacity(0.18) : Color.clear))
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
                let layout = vm.hangingGrid
                let w = max(0, (geo.size.width - gap * CGFloat(layout.columns - 1)) / CGFloat(layout.columns))
                let h = max(0, (geo.size.height - gap * CGFloat(layout.rows - 1)) / CGFloat(layout.rows))
                VStack(spacing: gap) {
                    ForEach(0..<layout.rows, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<layout.columns, id: \.self) { column in
                                HangingPaneView(index: row * layout.columns + column)
                                    .frame(width: w, height: h)
                            }
                        }
                    }
                }
            }
            .background(TracerTheme.viewportBackground)
        }
    }
}

private struct HangingPaneView: View {
    @EnvironmentObject var vm: ViewerViewModel
    let index: Int

    var body: some View {
        let config = paneConfig
        if config.kind == .petMIP {
            PETMIPPane(index: index, plane: config.plane)
        } else {
            SliceView(
                axis: config.plane.axis,
                title: "\(config.kind.shortName) \(config.plane.shortName)",
                displayMode: config.kind.sliceDisplayMode ?? .fused,
                paneIndex: index
            )
        }
    }

    private var paneConfig: HangingPaneConfiguration {
        if vm.hangingPanes.indices.contains(index) {
            return vm.hangingPanes[index]
        }
        return HangingPaneConfiguration.defaultPane(at: index)
    }
}

private struct PETMIPPane: View {
    @EnvironmentObject var vm: ViewerViewModel
    let index: Int
    let plane: SlicePlane
    @State private var dragStartPan: CGSize?
    @State private var gestureStartZoom: CGFloat?
    @State private var viewportBeforeInteraction: ViewportTransformState?

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                ZStack {
                    TracerTheme.viewportBackground
                    if let cg = vm.makePETMIPImage(for: plane.axis) {
                        let imgW = CGFloat(cg.width)
                        let imgH = CGFloat(cg.height)
                        let fit = min(geo.size.width / imgW, geo.size.height / imgH) * zoom
                        Image(decorative: cg, scale: 1.0)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: imgW * fit, height: imgH * fit)
                            .offset(pan)

                        orientationMarkers
                            .padding(12)

                        VStack {
                            Spacer()
                            HStack {
                                mipBadge
                                Spacer()
                            }
                        }
                        .padding(8)
                    } else if vm.activePETQuantificationVolume != nil {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(vm.isPETMIPProjectionPending(for: plane.axis)
                                 ? "Preparing PET MIP"
                                 : "PET MIP readying")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "flame")
                                .font(.system(size: 30))
                                .foregroundColor(.secondary)
                            Text("Load or fuse PET to show MIP")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(magnificationGesture())
                .gesture(dragGesture())
                .onTapGesture(count: 2) {
                    vm.resetViewportTransform(for: index)
                }
            }
            .background(TracerTheme.viewportBackground)
            .overlay(Rectangle().stroke(TracerTheme.hairline, lineWidth: 1))
        }
        .background(TracerTheme.panelBackground)
    }

    private var zoom: CGFloat {
        CGFloat(vm.viewportTransform(for: index).zoom)
    }

    private var pan: CGSize {
        let state = vm.viewportTransform(for: index)
        return CGSize(width: state.panX, height: state.panY)
    }

    private func setZoom(_ value: CGFloat) {
        vm.setViewportZoom(Double(value), for: index)
    }

    private func setPan(_ value: CGSize) {
        vm.setViewportPan(x: Double(value.width), y: Double(value.height), for: index)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("MIP \(plane.shortName)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(TracerTheme.pet)

            if vm.hangingGrid.paneCount > 16 {
                compactPaneMenu
            } else {
                rolePicker
                    .frame(width: 88)
                planePicker
                    .frame(width: 58)
            }

            Spacer()

            if vm.hangingGrid.paneCount <= 16 {
                mipColorPicker

                HoverIconButton(
                    systemImage: "circle.righthalf.filled",
                    tooltip: "Invert PET MIP\nReverses only the MIP color window.",
                    isActive: vm.invertPETMIP
                ) {
                    vm.setInvertPETMIP(!vm.invertPETMIP)
                }

                HoverIconButton(
                    systemImage: "rectangle.on.rectangle.angled",
                    tooltip: "Reset MIP zoom/pan"
                ) {
                    vm.resetViewportTransform(for: index)
                }

                Text(String(format: "SUV %.1f–%.1f", vm.petOverlayRangeMin, vm.petOverlayRangeMax))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(TracerTheme.headerBackground)
    }

    private var rolePicker: some View {
        Picker("", selection: Binding(
            get: { vm.hangingPanes.indices.contains(index) ? vm.hangingPanes[index].kind : .petMIP },
            set: { vm.setHangingPaneKind(index: index, kind: $0) }
        )) {
            ForEach(HangingPaneKind.allCases) { kind in
                Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.mini)
    }

    private var planePicker: some View {
        Picker("", selection: Binding(
            get: { vm.hangingPanes.indices.contains(index) ? vm.hangingPanes[index].plane : .coronal },
            set: { vm.setHangingPanePlane(index: index, plane: $0) }
        )) {
            ForEach(SlicePlane.allCases) { plane in
                Text(plane.shortName).tag(plane)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.mini)
    }

    private var compactPaneMenu: some View {
        let pane = vm.hangingPanes.indices.contains(index)
            ? vm.hangingPanes[index]
            : HangingPaneConfiguration.defaultPane(at: index)
        return Menu {
            rolePicker
            planePicker
        } label: {
            Text("\(pane.kind.shortName) \(pane.plane.shortName)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.mini)
    }

    private var mipColorPicker: some View {
        Picker("", selection: Binding(
            get: { vm.mipColormap },
            set: { vm.setPETMIPColormap($0) }
        )) {
            ForEach(Colormap.allCases) { color in
                Text(color.displayName).tag(color)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 92)
        .controlSize(.mini)
        .help("PET MIP colormap. This is independent from fused PET coloring.")
    }

    private var mipBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "cube.transparent")
                .foregroundColor(TracerTheme.pet)
            Text("PET MIP")
                .foregroundColor(.white)
            Text(vm.mipColormap.displayName)
                .foregroundColor(.secondary)
            if vm.invertPETMIP {
                Text("inverted")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .background(Color.black.opacity(0.58))
        .cornerRadius(5)
    }

    private var orientationMarkers: some View {
        let letters = orientationLetters
        return ZStack {
            VStack {
                Text(letters.top).opacity(0.6)
                Spacer()
                Text(letters.bottom).opacity(0.6)
            }
            HStack {
                Text(letters.left).opacity(0.6)
                Spacer()
                Text(letters.right).opacity(0.6)
            }
        }
        .font(.system(size: 12, weight: .bold, design: .monospaced))
        .foregroundColor(.yellow)
    }

    private var orientationLetters: (top: String, bottom: String, left: String, right: String) {
        guard let volume = vm.activePETQuantificationVolume,
              let axes = vm.displayAxes(for: plane.axis, volume: volume) else {
            switch plane {
            case .sagittal: return ("H", "F", "A", "P")
            case .coronal: return ("H", "F", "R", "L")
            case .axial: return ("A", "P", "R", "L")
            }
        }
        return (
            top: SliceDisplayTransform.patientLetter(for: -axes.down),
            bottom: SliceDisplayTransform.patientLetter(for: axes.down),
            left: SliceDisplayTransform.patientLetter(for: -axes.right),
            right: SliceDisplayTransform.patientLetter(for: axes.right)
        )
    }

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if gestureStartZoom == nil {
                    gestureStartZoom = zoom
                    viewportBeforeInteraction = vm.viewportTransform(for: index)
                }
                let start = gestureStartZoom ?? 1
                setZoom(max(0.25, min(10, start * scale)))
            }
            .onEnded { _ in
                if let before = viewportBeforeInteraction {
                    vm.recordViewportChange(before: before,
                                            after: vm.viewportTransform(for: index),
                                            paneKey: index)
                }
                viewportBeforeInteraction = nil
                gestureStartZoom = nil
            }
    }

    private func dragGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch vm.activeTool {
                case .pan:
                    if dragStartPan == nil {
                        dragStartPan = pan
                        viewportBeforeInteraction = vm.viewportTransform(for: index)
                    }
                    let start = dragStartPan ?? .zero
                    setPan(CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    ))
                case .zoom:
                    if gestureStartZoom == nil {
                        gestureStartZoom = zoom
                        viewportBeforeInteraction = vm.viewportTransform(for: index)
                    }
                    let start = gestureStartZoom ?? 1
                    let factor = 1.0 + Double(-value.translation.height) * 0.005
                    setZoom(CGFloat(max(0.25, min(10.0, Double(start) * factor))))
                default:
                    break
                }
            }
            .onEnded { _ in
                if let before = viewportBeforeInteraction {
                    vm.recordViewportChange(before: before,
                                            after: vm.viewportTransform(for: index),
                                            paneKey: index)
                }
                viewportBeforeInteraction = nil
                dragStartPan = nil
                gestureStartZoom = nil
            }
    }
}

private struct EmptyWorkstationView: View {
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TracerTheme.panelRaised.opacity(0.85))
                    .frame(width: 76, height: 76)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(TracerTheme.hairline, lineWidth: 1)
                    )
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(TracerTheme.accentBright, TracerTheme.mutedText)
            }

            VStack(spacing: 4) {
                Text("No study loaded")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Open a DICOM folder or NIfTI volume to begin.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                emptyWorkstationButtons(axis: .horizontal)
                emptyWorkstationButtons(axis: .vertical)
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                TracerTheme.viewportBackground
                LinearGradient(colors: [
                    TracerTheme.accent.opacity(0.12),
                    Color.clear,
                    TracerTheme.pet.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            }
        )
    }

    @ViewBuilder
    private func emptyWorkstationButtons(axis: Axis) -> some View {
        let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 8))
        stack {
            Button {
                NotificationCenter.default.post(name: .openDICOMDirectory, object: nil)
            } label: {
                Label("DICOM Folder", systemImage: "folder")
                    .frame(minWidth: 132)
            }
            .buttonStyle(.borderedProminent)

            Button {
                NotificationCenter.default.post(name: .openNIfTIFile, object: nil)
            } label: {
                Label("NIfTI File", systemImage: "doc")
                    .frame(minWidth: 112)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Activity footer

private enum ActivityCancelTarget: Equatable {
    case volumeOperation
    case indexing
    case nnunet
    case cohort
    case reconstruction
    case syntheticCT
    case dosimetry
    case modelDownload(String)
}

private struct ActivityOperationSnapshot: Identifiable, Equatable {
    let id: String
    let title: String
    let stage: String
    let detail: String
    let progress: Double?
    let systemImage: String
    let cancelTarget: ActivityCancelTarget?
}

private extension ActivityOperationSnapshot {
    var jobUpdate: JobUpdate {
        JobUpdate(operationID: id,
                  kind: inferredJobKind,
                  title: title,
                  stage: stage,
                  detail: detail,
                  progress: progress,
                  systemImage: systemImage,
                  canCancel: cancelTarget != nil)
    }

    var inferredJobKind: JobKind {
        if id == "pacs-index" { return .pacsIndexing }
        if id == "viewer-loading" { return .studyLoading }
        if id == "monai" { return .monai }
        if id == "nnunet" { return .nnunet }
        if id == "pet-engine" { return .petEngine }
        if id == "classification" { return .classification }
        if id == "cohort" { return .cohort }
        if id == "detector" { return .lesionDetection }
        if id == "pet-ac" { return .petAC }
        if id == "reconstruction" { return .reconstruction }
        if id == "synthetic-ct" { return .syntheticCT }
        if id == "dosimetry" { return .dosimetry }
        if id.hasPrefix("download-") { return .modelDownload }
        if id.hasPrefix("verify-") { return .modelVerification }
        return title.lowercased().contains("volume") ? .volumeOperation : .unknown
    }
}

private struct ActivityOperationChip: View {
    let operation: ActivityOperationSnapshot
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: operation.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(TracerTheme.accentBright)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(operation.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(operation.stage)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text(operation.detail.isEmpty ? "Running" : operation.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let progress = operation.progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 180, alignment: .leading)
                }
            }

            if operation.cancelTarget != nil {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundColor(.secondary)
                .help("Cancel")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(TracerTheme.viewportBackground.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(TracerTheme.hairline, lineWidth: 1)
        )
    }
}

private struct ActivityLogPanel: View {
    @ObservedObject var activity: ActivityLogStore

    private var visibleEntries: [ActivityLogEntry] {
        Array(activity.entries.suffix(160))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Operation Logs", systemImage: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(activity.entries.count) events")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(TracerTheme.headerBackground)
            .overlay(Rectangle().fill(TracerTheme.hairline).frame(height: 1), alignment: .bottom)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if visibleEntries.isEmpty {
                            Text("No activity yet.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(10)
                        } else {
                            ForEach(visibleEntries) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text(entry.timestamp, style: .time)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 64, alignment: .leading)
                                    Image(systemName: icon(for: entry.level))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(color(for: entry.level))
                                        .frame(width: 14)
                                    Text(entry.source)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(color(for: entry.level))
                                        .frame(width: 92, alignment: .leading)
                                    Text(entry.message)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.primary.opacity(0.9))
                                        .textSelection(.enabled)
                                }
                                .id(entry.id)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 1)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: activity.entries.count) { _, _ in
                    if let last = visibleEntries.last {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let last = visibleEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(TracerTheme.panelBackground)
    }

    private func icon(for level: ActivityLogLevel) -> String {
        switch level {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(for level: ActivityLogLevel) -> Color {
        switch level {
        case .info: return TracerTheme.accentBright
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct ActivityLogHooks: ViewModifier {
    @ObservedObject var vm: ViewerViewModel
    @ObservedObject var monai: MONAILabelViewModel
    @ObservedObject var nnunet: NNUnetViewModel
    @ObservedObject var pet: PETEngineViewModel
    @ObservedObject var classification: ClassificationViewModel
    @ObservedObject var modelManager: ModelManagerViewModel
    @ObservedObject var cohort: CohortResultsStore
    @ObservedObject var lesionDetector: LesionDetectorViewModel
    @ObservedObject var petAC: PETACViewModel
    @ObservedObject var reconstruction: NuclearReconstructionViewModel
    @ObservedObject var syntheticCT: SyntheticCTViewModel
    @ObservedObject var dosimetry: Lu177DosimetryViewModel
    @ObservedObject var activity: ActivityLogStore

    func body(content: Content) -> some View {
        content
            .modifier(ViewerActivityLogHooks(vm: vm,
                                             monai: monai,
                                             activity: activity))
            .modifier(InferenceActivityLogHooks(nnunet: nnunet,
                                                pet: pet,
                                                classification: classification,
                                                activity: activity))
            .modifier(WorkflowActivityLogHooks(modelManager: modelManager,
                                               cohort: cohort,
                                               lesionDetector: lesionDetector,
                                               petAC: petAC,
                                               activity: activity))
            .modifier(NuclearActivityLogHooks(reconstruction: reconstruction,
                                              syntheticCT: syntheticCT,
                                              dosimetry: dosimetry,
                                              activity: activity))
    }
}

private struct ViewerActivityLogHooks: ViewModifier {
    @ObservedObject var vm: ViewerViewModel
    @ObservedObject var monai: MONAILabelViewModel
    @ObservedObject var activity: ActivityLogStore

    func body(content: Content) -> some View {
        content
            .onChange(of: vm.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "Viewer")
            }
            .onChange(of: monai.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "MONAI")
            }
    }
}

private struct InferenceActivityLogHooks: ViewModifier {
    @ObservedObject var nnunet: NNUnetViewModel
    @ObservedObject var pet: PETEngineViewModel
    @ObservedObject var classification: ClassificationViewModel
    @ObservedObject var activity: ActivityLogStore

    func body(content: Content) -> some View {
        content
            .onChange(of: nnunet.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "nnU-Net")
            }
            .onChange(of: nnunet.log) { _, newValue in
                ActivityLogHelpers.logLatestLine(newValue, source: "nnU-Net", activity: activity)
            }
            .onChange(of: pet.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "PET Engine")
            }
            .onChange(of: classification.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "Classifier")
            }
    }
}

private struct WorkflowActivityLogHooks: ViewModifier {
    @ObservedObject var modelManager: ModelManagerViewModel
    @ObservedObject var cohort: CohortResultsStore
    @ObservedObject var lesionDetector: LesionDetectorViewModel
    @ObservedObject var petAC: PETACViewModel
    @ObservedObject var activity: ActivityLogStore

    func body(content: Content) -> some View {
        content
            .onChange(of: modelManager.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "Models")
            }
            .onChange(of: modelManager.downloader.statusByModelID) { _, newValue in
                ActivityLogHelpers.logDownloadStatuses(newValue,
                                                       modelManager: modelManager,
                                                       activity: activity)
            }
            .onChange(of: cohort.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "Cohort")
            }
            .onChange(of: lesionDetector.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "Detector")
            }
            .onChange(of: lesionDetector.log) { _, newValue in
                ActivityLogHelpers.logLatestLine(newValue, source: "Detector", activity: activity)
            }
            .onChange(of: petAC.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "PET AC")
            }
            .onChange(of: petAC.log) { _, newValue in
                ActivityLogHelpers.logLatestLine(newValue, source: "PET AC", activity: activity)
            }
    }
}

private struct NuclearActivityLogHooks: ViewModifier {
    @ObservedObject var reconstruction: NuclearReconstructionViewModel
    @ObservedObject var syntheticCT: SyntheticCTViewModel
    @ObservedObject var dosimetry: Lu177DosimetryViewModel
    @ObservedObject var activity: ActivityLogStore

    func body(content: Content) -> some View {
        content
            .onChange(of: reconstruction.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "Reconstruction")
            }
            .onChange(of: syntheticCT.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "Synthetic CT")
            }
            .onChange(of: dosimetry.statusMessage) { _, newValue in
                activity.logStatus(newValue, source: "Dosimetry")
            }
    }
}

private enum ActivityLogHelpers {
    @MainActor
    static func logLatestLine(_ text: String, source: String, activity: ActivityLogStore) {
        let line = text
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let line, !line.isEmpty {
            activity.log(line, source: source)
        }
    }

    @MainActor
    static func logDownloadStatuses(_ statuses: [String: ModelDownloadManager.DownloadStatus],
                                    modelManager: ModelManagerViewModel,
                                    activity: ActivityLogStore) {
        for (modelID, status) in statuses {
            let displayName = modelManager.store.models.first(where: { $0.id == modelID })?.displayName ?? modelID
            switch status {
            case .idle:
                break
            case .downloading(let bytesReceived, let totalBytes):
                activity.log("Downloading \(displayName): \(byteProgress(bytesReceived, totalBytes))",
                             source: "Models")
            case .verifying:
                activity.log("Verifying \(displayName).", source: "Models")
            case .completed(let sizeBytes):
                activity.log("Downloaded \(displayName) (\(byteString(Int64(sizeBytes))).",
                             source: "Models",
                             level: .success)
            case .failed(let message):
                activity.log("\(displayName) download failed: \(message)",
                             source: "Models",
                             level: .error)
            case .cancelled:
                activity.log("\(displayName) download cancelled.",
                             source: "Models",
                             level: .warning)
            }
        }
    }

    static func byteProgress(_ received: Int64, _ total: Int64) -> String {
        guard total > 0 else { return "\(byteString(received)) received" }
        return "\(byteString(received)) / \(byteString(total))"
    }

    static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Engine presentation

private extension View {
    /// Presents engine panels as sheets. A stack of hidden macOS inspectors
    /// can trigger AppKit key-view traversal during launch before the
    /// workstation is interactive.
    @ViewBuilder
    func engineInspector<Body: View>(
        isCompact: Bool,
        isPresented: Binding<Bool>,
        inspectorWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat),
        @ViewBuilder content: @escaping () -> Body
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            content()
                .frame(minWidth: inspectorWidth.min,
                       idealWidth: inspectorWidth.ideal,
                       maxWidth: inspectorWidth.max,
                       minHeight: 560)
        }
    }
}
