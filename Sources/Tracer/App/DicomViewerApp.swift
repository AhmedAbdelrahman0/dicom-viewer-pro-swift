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
            }
        #else
        return scene
        #endif
    }
}

extension Notification.Name {
    static let openDICOMDirectory = Notification.Name("openDICOMDirectory")
    static let openNIfTIFile = Notification.Name("openNIfTIFile")
}
