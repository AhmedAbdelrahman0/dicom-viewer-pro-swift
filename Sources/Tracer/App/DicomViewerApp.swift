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
            .windowResizability(.contentSize)
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
    static let openDICOMDirectory = Notification.Name("openDICOMDirectory")
    static let openNIfTIFile = Notification.Name("openNIfTIFile")
    static let showAboutWindow = Notification.Name("Tracer.showAboutWindow")
    static let showOnboarding = Notification.Name("Tracer.showOnboarding")
}
