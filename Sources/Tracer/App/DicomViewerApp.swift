import SwiftUI
import SwiftData

public struct DicomViewerApp: App {
    public init() {}

    public var body: some Scene {
        // Split into two scenes: the main window + (on macOS) a Settings
        // scene that opens via the standard ⌘, shortcut. The Settings
        // window reads the same `@AppStorage` keys used elsewhere in the
        // app so changes propagate without additional glue.
        mainScene
        #if os(macOS)
        Settings {
            TracerSettingsView()
        }
        #endif
    }

    private var mainScene: some Scene {
        let scene = WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: PACSIndexedSeries.self)
        #if os(macOS)
        return scene
            .defaultSize(width: 1440, height: 960)
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Open DICOM Directory…") {
                        NotificationCenter.default.post(name: .openDICOMDirectory, object: nil)
                    }
                    .keyboardShortcut("O", modifiers: [.command])

                    Button("Open NIfTI File…") {
                        NotificationCenter.default.post(name: .openNIfTIFile, object: nil)
                    }
                    .keyboardShortcut("N", modifiers: [.command])
                }

                // Replace the default "About App" menu item with our own —
                // the standard panel can't carry a changelog or brand hero.
                CommandGroup(replacing: .appInfo) {
                    Button("About Tracer") {
                        NotificationCenter.default.post(name: .showAboutWindow, object: nil)
                    }
                }

                // Help menu shortcut to the onboarding walkthrough — handy
                // for users who dismissed it once and want to revisit.
                CommandGroup(after: .help) {
                    Button("Show Welcome Walkthrough") {
                        NotificationCenter.default.post(name: .showOnboarding, object: nil)
                    }
                }

                CommandMenu("Tools") {
                    viewerToolButton("Window / Level", tool: "wl", key: "w")
                    viewerToolButton("Pan", tool: "pan", key: "p")
                    viewerToolButton("Zoom", tool: "zoom", key: "z")

                    Divider()

                    viewerToolButton("Distance Measurement", tool: "distance", key: "d")
                    viewerToolButton("Angle Measurement", tool: "angle", key: "a")
                    viewerToolButton("Area Measurement", tool: "area", key: "r")
                    viewerToolButton("Spherical SUV / HU ROI", tool: "suvSphere", key: "s")

                    Divider()

                    Button("Link Zoom + Pan") {
                        NotificationCenter.default.post(name: .toggleLinkedZoomPan, object: nil)
                    }
                    .keyboardShortcut("l")

                    Button("Focus Mode") {
                        NotificationCenter.default.post(name: .toggleFocusMode, object: nil)
                    }
                    .keyboardShortcut("e", modifiers: [.command])
                }

                CommandMenu("Labels") {
                    Button("Create / Select Label Map") {
                        NotificationCenter.default.post(name: .createLabelMap, object: nil)
                    }
                    .keyboardShortcut("L", modifiers: [.command, .shift])

                    Divider()

                    labelingToolButton("Brush", tool: "brush", key: "b")
                    labelingToolButton("Eraser", tool: "eraser", key: "x")
                    labelingToolButton("Freehand ROI", tool: "freehand", key: "f")
                    labelingToolButton("Threshold Seed", tool: "threshold", key: "t")
                    labelingToolButton("SUV Gradient Seed", tool: "suvGradient", key: "g")
                    labelingToolButton("Region Grow", tool: "regionGrow", key: "y")
                    labelingToolButton("Quick Lesion Sphere", tool: "lesionSphere", key: "q")
                    labelingToolButton("Landmark", tool: "landmark", key: "k")

                    Divider()

                    labelingToolButton("Viewer Mode", tool: "none", key: .escape)
                }

                CommandMenu("Measurements") {
                    viewerToolButton("Distance", tool: "distance")
                    viewerToolButton("Angle", tool: "angle")
                    viewerToolButton("Area / Polygon ROI", tool: "area")
                    viewerToolButton("Spherical SUV / HU ROI", tool: "suvSphere")

                    Divider()

                    Button("Clear Measurements") {
                        NotificationCenter.default.post(name: .clearMeasurements, object: nil)
                    }
                    .keyboardShortcut(.delete, modifiers: [.command])

                    Divider()

                    Button("Save Study Session") {
                        NotificationCenter.default.post(name: .saveStudySession, object: nil)
                    }
                    .keyboardShortcut("s", modifiers: [.command])

                    Button("New Measurement Session") {
                        NotificationCenter.default.post(name: .newStudySession, object: nil)
                    }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                }

                CommandMenu("AI Engines") {
                    enginePanelButton("MONAI Label", panel: "monai", key: "m")
                    enginePanelButton("nnU-Net", panel: "nnunet", key: "n")
                    enginePanelButton("PET Engine", panel: "pet", key: "p")
                    enginePanelButton("Classify Lesions", panel: "classification", key: "c")
                    enginePanelButton("Model Manager", panel: "modelManager", key: "w")
                    enginePanelButton("Cohort Batch", panel: "cohort", key: "b")
                    enginePanelButton("Lesion Detection", panel: "lesionDetector", key: "d")
                    enginePanelButton("PET Attenuation Correction", panel: "petAC", key: "k")
                    enginePanelButton("Nuclear Tools", panel: "nuclearTools", key: "u")

                    Divider()

                    enginePanelButton("Dictation", panel: "dictation", key: "v")
                }

                CommandMenu("Tracer Edit") {
                    Button("Undo") {
                        NotificationCenter.default.post(name: .undoLastEdit, object: nil)
                    }
                    .keyboardShortcut("z", modifiers: [.command])

                    Button("Redo") {
                        NotificationCenter.default.post(name: .redoLastEdit, object: nil)
                    }
                    .keyboardShortcut("Z", modifiers: [.command, .shift])

                    Button("Reset Editable Changes") {
                        NotificationCenter.default.post(name: .resetEditableChanges, object: nil)
                    }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                }
            }
        #else
        return scene
        #endif
    }

    @ViewBuilder
    private func viewerToolButton(_ title: String,
                                  tool: String) -> some View {
        Button(title) {
            NotificationCenter.default.post(name: .selectViewerTool, object: nil, userInfo: ["tool": tool])
        }
    }

    @ViewBuilder
    private func viewerToolButton(_ title: String,
                                  tool: String,
                                  key: KeyEquivalent) -> some View {
        Button(title) {
            NotificationCenter.default.post(name: .selectViewerTool, object: nil, userInfo: ["tool": tool])
        }
        .keyboardShortcut(key, modifiers: [])
    }

    @ViewBuilder
    private func labelingToolButton(_ title: String,
                                    tool: String,
                                    key: KeyEquivalent) -> some View {
        Button(title) {
            NotificationCenter.default.post(name: .selectLabelingTool, object: nil, userInfo: ["tool": tool])
        }
        .keyboardShortcut(key, modifiers: [])
    }

    @ViewBuilder
    private func enginePanelButton(_ title: String,
                                   panel: String,
                                   key: KeyEquivalent) -> some View {
        Button(title) {
            NotificationCenter.default.post(name: .showEngineInspector, object: nil, userInfo: ["panel": panel])
        }
        .keyboardShortcut(key, modifiers: [.command, .shift])
    }
}

extension Notification.Name {
    public static let openDICOMDirectory = Notification.Name("openDICOMDirectory")
    public static let openNIfTIFile = Notification.Name("openNIfTIFile")
    public static let showAboutWindow = Notification.Name("Tracer.showAboutWindow")
    public static let showOnboarding = Notification.Name("Tracer.showOnboarding")
    public static let selectViewerTool = Notification.Name("Tracer.selectViewerTool")
    public static let selectLabelingTool = Notification.Name("Tracer.selectLabelingTool")
    public static let createLabelMap = Notification.Name("Tracer.createLabelMap")
    public static let clearMeasurements = Notification.Name("Tracer.clearMeasurements")
    public static let saveStudySession = Notification.Name("Tracer.saveStudySession")
    public static let newStudySession = Notification.Name("Tracer.newStudySession")
    public static let undoLastEdit = Notification.Name("Tracer.undoLastEdit")
    public static let redoLastEdit = Notification.Name("Tracer.redoLastEdit")
    public static let resetEditableChanges = Notification.Name("Tracer.resetEditableChanges")
    public static let toggleLinkedZoomPan = Notification.Name("Tracer.toggleLinkedZoomPan")
    public static let toggleFocusMode = Notification.Name("Tracer.toggleFocusMode")
    public static let showEngineInspector = Notification.Name("Tracer.showEngineInspector")
}
