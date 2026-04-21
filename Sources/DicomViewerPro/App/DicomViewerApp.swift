import SwiftUI

public struct DicomViewerApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
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
        #endif
    }
}

extension Notification.Name {
    static let openDICOMDirectory = Notification.Name("openDICOMDirectory")
    static let openNIfTIFile = Notification.Name("openNIfTIFile")
}
