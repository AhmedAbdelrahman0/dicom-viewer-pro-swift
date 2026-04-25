import SwiftUI
import SwiftData
import Tracer

#if os(macOS)
import AppKit

private final class WorkstationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class TracerAppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: WorkstationWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        openMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func openMainWindow() {
        let screen = NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 960)
        let root = ContentView()
            .modelContainer(for: PACSIndexedSeries.self)
            .preferredColorScheme(.dark)

        let window = WorkstationWindow(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Tracer"
        window.minSize = NSSize(width: 1180, height: 760)
        window.contentView = NSHostingView(rootView: root)
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .canJoinAllSpaces]
        mainWindow = window

        enterWorkstationPresentationMode()
        fillDisplay()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.fillDisplay()
        }
    }

    private func fillDisplay() {
        guard let window = mainWindow else { return }
        let screen = window.screen ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        window.setFrame(frame, display: true, animate: false)
    }

    private func enterWorkstationPresentationMode() {
        var options = NSApp.presentationOptions
        options.insert(.autoHideDock)
        options.insert(.autoHideMenuBar)
        NSApp.presentationOptions = options
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "About Tracer",
                               action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        let settings = NSMenuItem(title: "Settings...",
                                  action: #selector(showSettings),
                                  keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Tracer",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openDICOM = NSMenuItem(title: "Open DICOM Directory...",
                                   action: #selector(openDICOMDirectory),
                                   keyEquivalent: "o")
        openDICOM.target = self
        openDICOM.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(openDICOM)
        let openNIfTI = NSMenuItem(title: "Open NIfTI File...",
                                   action: #selector(openNIfTIFile),
                                   keyEquivalent: "n")
        openNIfTI.target = self
        openNIfTI.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(openNIfTI)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openDICOMDirectory() {
        NotificationCenter.default.post(name: Notification.Name("openDICOMDirectory"), object: nil)
    }

    @objc private func openNIfTIFile() {
        NotificationCenter.default.post(name: Notification.Name("openNIfTIFile"), object: nil)
    }

    @objc private func showAbout() {
        NotificationCenter.default.post(name: Notification.Name("Tracer.showAboutWindow"), object: nil)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let root = TracerSettingsView()
                .preferredColorScheme(.dark)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Tracer Settings"
            window.contentView = NSHostingView(rootView: root)
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
private let delegate = TracerAppDelegate()
app.delegate = delegate
app.run()
#else
DicomViewerApp.main()
#endif
