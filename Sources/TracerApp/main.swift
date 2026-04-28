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
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let screen = NSScreen.main
        let frame = defaultWindowFrame(on: screen)
        let root = ContentView()
            .modelContainer(for: PACSIndexedSeries.self)
            .preferredColorScheme(.dark)

        let window = WorkstationWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Tracer"
        window.minSize = NSSize(width: 920, height: 640)
        window.contentView = NSHostingView(rootView: root)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.setFrameAutosaveName("Tracer.MainWindow")
        mainWindow = window

        constrainMainWindowToCurrentScreen()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.constrainMainWindowToCurrentScreen()
        }
    }

    private func defaultWindowFrame(on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 960)
        let width = min(max(1180, visible.width * 0.82), visible.width)
        let height = min(max(760, visible.height * 0.84), visible.height)
        return NSRect(x: visible.midX - width / 2,
                      y: visible.midY - height / 2,
                      width: width,
                      height: height)
    }

    private func constrainMainWindowToCurrentScreen() {
        guard let window = mainWindow else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let constrained = window.constrainFrameRect(window.frame, to: screen)
        window.setFrame(constrained, display: true, animate: false)
    }

    @objc private func fitMainWindowToDisplay() {
        guard let window = mainWindow,
              let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: true, animate: true)
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

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(makeMenuItem(title: "Undo", action: #selector(undoLastEdit), key: "z", modifiers: [.command]))
        editMenu.addItem(makeMenuItem(title: "Redo", action: #selector(redoLastEdit), key: "Z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(makeMenuItem(title: "Reset Editable Changes", action: #selector(resetEditableChanges), key: "0", modifiers: [.command, .option]))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

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

        let toolsMenuItem = NSMenuItem()
        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.addItem(makeViewerToolItem("Window / Level", tool: "wl", key: "w"))
        toolsMenu.addItem(makeViewerToolItem("Pan", tool: "pan", key: "p"))
        toolsMenu.addItem(makeViewerToolItem("Zoom", tool: "zoom", key: "z"))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(makeViewerToolItem("Distance Measurement", tool: "distance", key: "d"))
        toolsMenu.addItem(makeViewerToolItem("Angle Measurement", tool: "angle", key: "a"))
        toolsMenu.addItem(makeViewerToolItem("Area Measurement", tool: "area", key: "r"))
        toolsMenu.addItem(makeViewerToolItem("Spherical SUV / HU ROI", tool: "suvSphere", key: "s"))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(makeMenuItem(title: "Link Zoom + Pan", action: #selector(toggleLinkedZoomPan), key: "l", modifiers: []))
        toolsMenu.addItem(makeMenuItem(title: "Focus Mode", action: #selector(toggleFocusMode), key: "e", modifiers: [.command]))
        toolsMenuItem.submenu = toolsMenu
        mainMenu.addItem(toolsMenuItem)

        let labelsMenuItem = NSMenuItem()
        let labelsMenu = NSMenu(title: "Labels")
        labelsMenu.addItem(makeMenuItem(title: "Create / Select Label Map", action: #selector(createLabelMap), key: "l", modifiers: [.command, .shift]))
        labelsMenu.addItem(.separator())
        labelsMenu.addItem(makeLabelingToolItem("Brush", tool: "brush", key: "b"))
        labelsMenu.addItem(makeLabelingToolItem("Eraser", tool: "eraser", key: "x"))
        labelsMenu.addItem(makeLabelingToolItem("Freehand ROI", tool: "freehand", key: "f"))
        labelsMenu.addItem(makeLabelingToolItem("Threshold Seed", tool: "threshold", key: "t"))
        labelsMenu.addItem(makeLabelingToolItem("SUV Gradient Seed", tool: "suvGradient", key: "g"))
        labelsMenu.addItem(makeLabelingToolItem("Region Grow", tool: "regionGrow", key: "y"))
        labelsMenu.addItem(makeLabelingToolItem("Quick Lesion Sphere", tool: "lesionSphere", key: "q"))
        labelsMenu.addItem(makeLabelingToolItem("Landmark", tool: "landmark", key: "k"))
        labelsMenu.addItem(.separator())
        labelsMenu.addItem(makeLabelingToolItem("Viewer Mode", tool: "none", key: "\u{1b}"))
        labelsMenuItem.submenu = labelsMenu
        mainMenu.addItem(labelsMenuItem)

        let measurementsMenuItem = NSMenuItem()
        let measurementsMenu = NSMenu(title: "Measurements")
        measurementsMenu.addItem(makeViewerToolItem("Distance", tool: "distance", key: ""))
        measurementsMenu.addItem(makeViewerToolItem("Angle", tool: "angle", key: ""))
        measurementsMenu.addItem(makeViewerToolItem("Area / Polygon ROI", tool: "area", key: ""))
        measurementsMenu.addItem(makeViewerToolItem("Spherical SUV / HU ROI", tool: "suvSphere", key: ""))
        measurementsMenu.addItem(.separator())
        measurementsMenu.addItem(makeMenuItem(title: "Clear Measurements", action: #selector(clearMeasurements), key: "\u{8}", modifiers: [.command]))
        measurementsMenu.addItem(.separator())
        measurementsMenu.addItem(makeMenuItem(title: "Save Study Session", action: #selector(saveStudySession), key: "s", modifiers: [.command]))
        measurementsMenu.addItem(makeMenuItem(title: "New Measurement Session", action: #selector(newStudySession), key: "n", modifiers: [.command, .option]))
        measurementsMenuItem.submenu = measurementsMenu
        mainMenu.addItem(measurementsMenuItem)

        let aiMenuItem = NSMenuItem()
        let aiMenu = NSMenu(title: "AI Engines")
        aiMenu.addItem(makeEnginePanelItem("MONAI Label", panel: "monai", key: "m"))
        aiMenu.addItem(makeEnginePanelItem("nnU-Net", panel: "nnunet", key: "n"))
        aiMenu.addItem(makeEnginePanelItem("PET Engine", panel: "pet", key: "p"))
        aiMenu.addItem(makeEnginePanelItem("Classify Lesions", panel: "classification", key: "c"))
        aiMenu.addItem(makeEnginePanelItem("Model Manager", panel: "modelManager", key: "w"))
        aiMenu.addItem(makeEnginePanelItem("Cohort Batch", panel: "cohort", key: "b"))
        aiMenu.addItem(makeEnginePanelItem("Lesion Detection", panel: "lesionDetector", key: "d"))
        aiMenu.addItem(makeEnginePanelItem("PET Attenuation Correction", panel: "petAC", key: "k"))
        aiMenu.addItem(makeEnginePanelItem("Nuclear Tools", panel: "nuclearTools", key: "u"))
        aiMenu.addItem(.separator())
        aiMenu.addItem(makeEnginePanelItem("Dictation", panel: "dictation", key: "v"))
        aiMenuItem.submenu = aiMenu
        mainMenu.addItem(aiMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let fitDisplay = NSMenuItem(title: "Fit Window to Display",
                                    action: #selector(fitMainWindowToDisplay),
                                    keyEquivalent: "f")
        fitDisplay.target = self
        fitDisplay.keyEquivalentModifierMask = [.command, .option]
        windowMenu.addItem(fitDisplay)
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Minimize",
                                      action: #selector(NSWindow.performMiniaturize(_:)),
                                      keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom",
                                      action: #selector(NSWindow.performZoom(_:)),
                                      keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func makeMenuItem(title: String,
                              action: Selector,
                              key: String = "",
                              modifiers: NSEvent.ModifierFlags = [.command],
                              representedObject: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = representedObject
        return item
    }

    private func makeViewerToolItem(_ title: String, tool: String, key: String) -> NSMenuItem {
        makeMenuItem(title: title, action: #selector(selectViewerTool(_:)), key: key, modifiers: [], representedObject: tool)
    }

    private func makeLabelingToolItem(_ title: String, tool: String, key: String) -> NSMenuItem {
        makeMenuItem(title: title, action: #selector(selectLabelingTool(_:)), key: key, modifiers: [], representedObject: tool)
    }

    private func makeEnginePanelItem(_ title: String, panel: String, key: String) -> NSMenuItem {
        makeMenuItem(title: title, action: #selector(showEngineInspector(_:)), key: key, modifiers: [.command, .shift], representedObject: panel)
    }

    @objc private func openDICOMDirectory() {
        NotificationCenter.default.post(name: Notification.Name("openDICOMDirectory"), object: nil)
    }

    @objc private func openNIfTIFile() {
        NotificationCenter.default.post(name: Notification.Name("openNIfTIFile"), object: nil)
    }

    @objc private func undoLastEdit() { NotificationCenter.default.post(name: .undoLastEdit, object: nil) }
    @objc private func redoLastEdit() { NotificationCenter.default.post(name: .redoLastEdit, object: nil) }
    @objc private func resetEditableChanges() { NotificationCenter.default.post(name: .resetEditableChanges, object: nil) }
    @objc private func createLabelMap() { NotificationCenter.default.post(name: .createLabelMap, object: nil) }
    @objc private func clearMeasurements() { NotificationCenter.default.post(name: .clearMeasurements, object: nil) }
    @objc private func saveStudySession() { NotificationCenter.default.post(name: .saveStudySession, object: nil) }
    @objc private func newStudySession() { NotificationCenter.default.post(name: .newStudySession, object: nil) }
    @objc private func toggleLinkedZoomPan() { NotificationCenter.default.post(name: .toggleLinkedZoomPan, object: nil) }
    @objc private func toggleFocusMode() { NotificationCenter.default.post(name: .toggleFocusMode, object: nil) }

    @objc private func selectViewerTool(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? String else { return }
        NotificationCenter.default.post(name: .selectViewerTool, object: nil, userInfo: ["tool": tool])
    }

    @objc private func selectLabelingTool(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? String else { return }
        NotificationCenter.default.post(name: .selectLabelingTool, object: nil, userInfo: ["tool": tool])
    }

    @objc private func showEngineInspector(_ sender: NSMenuItem) {
        guard let panel = sender.representedObject as? String else { return }
        NotificationCenter.default.post(name: .showEngineInspector, object: nil, userInfo: ["panel": panel])
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
