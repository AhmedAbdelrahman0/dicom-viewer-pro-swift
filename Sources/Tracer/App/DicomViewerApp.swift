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
            }
        #else
        return scene
        #endif
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
