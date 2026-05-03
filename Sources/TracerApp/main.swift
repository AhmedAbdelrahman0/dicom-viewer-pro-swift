import SwiftUI
import SwiftData
import Tracer

#if os(macOS)
import AppKit

@MainActor
private final class TracerAppDelegate: NSObject, NSApplicationDelegate {
    private enum StudyWindowLayout: String {
        case split
        case unified
    }

    private var studyWindowLayout: StudyWindowLayout = .unified
    private var unifiedWindow: NSWindow?
    private var navigatorWindow: NSWindow?
    private var viewerWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let sharedViewer = ViewerViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenu()
        ContainerRuntimeBootstrapper.shared.startOnAppLaunch()
        openPreferredStudyWindows()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPreferredStudyWindows()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func openPreferredStudyWindows() {
        switch studyWindowLayout {
        case .split:
            openSplitStudyWindows()
        case .unified:
            openUnifiedStudyWindow()
        }
    }

    private func openSplitStudyWindows() {
        studyWindowLayout = .split
        openStudyNavigator(activate: false)
        openStudyViewer(activate: true)
        unifiedWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    private func openUnifiedStudyWindow(activate: Bool = true) -> NSWindow {
        studyWindowLayout = .unified
        if let unifiedWindow {
            if activate {
                unifiedWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                unifiedWindow.orderFront(nil)
            }
            navigatorWindow?.orderOut(nil)
            viewerWindow?.orderOut(nil)
            return unifiedWindow
        }

        let frame = defaultUnifiedStudyWindowFrame()
        let root = ContentView(vm: sharedViewer, role: .unified)
            .modelContainer(for: PACSIndexedSeries.self)
            .frame(minWidth: 1100, minHeight: 680)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(.dark)
        let window = makeStudyWindow(
            title: "Tracer",
            frame: frame,
            minSize: NSSize(width: 1100, height: 680),
            root: root
        )
        unifiedWindow = window
        navigatorWindow?.orderOut(nil)
        viewerWindow?.orderOut(nil)
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
        return window
    }

    @discardableResult
    private func openStudyNavigator(activate: Bool = true) -> NSWindow {
        if let navigatorWindow {
            if activate {
                navigatorWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                navigatorWindow.orderFront(nil)
            }
            return navigatorWindow
        }

        let frames = defaultStudyWindowFrames()
        let root = ContentView(vm: sharedViewer, role: .navigator)
            .modelContainer(for: PACSIndexedSeries.self)
            .frame(minWidth: 420, minHeight: 600)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(.dark)
        let window = makeStudyWindow(
            title: "Tracer Study Navigator",
            frame: frames.navigator,
            minSize: NSSize(width: 420, height: 600),
            root: root
        )
        navigatorWindow = window
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
        return window
    }

    @discardableResult
    private func openStudyViewer(activate: Bool = true) -> NSWindow {
        if let viewerWindow {
            if activate {
                viewerWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                viewerWindow.orderFront(nil)
            }
            return viewerWindow
        }

        let frames = defaultStudyWindowFrames()
        let root = ContentView(vm: sharedViewer, role: .viewer)
            .modelContainer(for: PACSIndexedSeries.self)
            .frame(minWidth: 900, minHeight: 600)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(.dark)
        let window = makeStudyWindow(
            title: "Tracer Study Viewer",
            frame: frames.viewer,
            minSize: NSSize(width: 900, height: 600),
            root: root
        )
        viewerWindow = window
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
        return window
    }

    private func makeStudyWindow<Root: View>(title: String,
                                             frame: NSRect,
                                             minSize: NSSize,
                                             root: Root) -> NSWindow {
        let hostingView = NSHostingView(rootView: root)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(origin: .zero, size: frame.size)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
            screen: NSScreen.main
        )
        window.title = title
        window.minSize = minSize
        window.contentView = hostingView
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.setFrame(frame, display: true, animate: false)
        window.orderFrontRegardless()
        return window
    }

    private func defaultStudyWindowFrames() -> (navigator: NSRect, viewer: NSRect) {
        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 960)
        let margin: CGFloat = 18
        let gap: CGFloat = 12
        let height = min(max(720, visible.height * 0.88), visible.height - margin * 2)
        let y = visible.midY - height / 2
        let contentWidth = max(900, visible.width - margin * 2)
        let availableSideBySideWidth = max(900, contentWidth - gap)
        let navigatorWidth = min(max(420, availableSideBySideWidth * 0.28), 560)
        let viewerWidth = max(900, availableSideBySideWidth - navigatorWidth)

        if navigatorWidth + gap + viewerWidth <= contentWidth {
            let navigatorFrame = NSRect(x: visible.minX + margin,
                                        y: y,
                                        width: navigatorWidth,
                                        height: height)
            let viewerFrame = NSRect(x: navigatorFrame.maxX + gap,
                                     y: y,
                                     width: viewerWidth,
                                     height: height)
            return (navigatorFrame, viewerFrame)
        }

        let viewerFrame = NSRect(x: visible.midX - min(max(1080, visible.width * 0.78), visible.width - margin * 2) / 2,
                                 y: y,
                                 width: min(max(1080, visible.width * 0.78), visible.width - margin * 2),
                                 height: height)
        let navigatorFrame = NSRect(x: visible.minX + margin,
                                    y: y + 28,
                                    width: navigatorWidth,
                                    height: max(620, height - 56))
        return (navigatorFrame, viewerFrame)
    }

    private func defaultUnifiedStudyWindowFrame() -> NSRect {
        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 960)
        let margin: CGFloat = 18
        let width = min(max(1280, visible.width * 0.86), visible.width - margin * 2)
        let height = min(max(780, visible.height * 0.88), visible.height - margin * 2)
        return NSRect(x: visible.midX - width / 2,
                      y: visible.midY - height / 2,
                      width: width,
                      height: height)
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(makeMenuItem(title: "About Tracer", action: #selector(showAbout), modifiers: []))
        appMenu.addItem(makeMenuItem(title: "Settings...", action: #selector(showSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Tracer",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(makeMenuItem(title: "Open DICOM Directory...",
                                      action: #selector(openDICOMDirectory),
                                      key: "o"))
        fileMenu.addItem(makeMenuItem(title: "Open NIfTI File...",
                                      action: #selector(openNIfTIFile),
                                      key: "n"))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(makeMenuItem(title: "Undo", action: #selector(undoLastEdit), key: "z"))
        editMenu.addItem(makeMenuItem(title: "Redo", action: #selector(redoLastEdit), key: "Z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(makeMenuItem(title: "Reset Editable Changes",
                                      action: #selector(resetEditableChanges),
                                      key: "0",
                                      modifiers: [.command, .option]))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

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
        toolsMenu.addItem(makeMenuItem(title: "Focus Mode", action: #selector(toggleFocusMode), key: "e"))
        toolsMenuItem.submenu = toolsMenu
        mainMenu.addItem(toolsMenuItem)

        let labelsMenuItem = NSMenuItem()
        let labelsMenu = NSMenu(title: "Labels")
        labelsMenu.addItem(makeMenuItem(title: "Create / Select Label Map",
                                        action: #selector(createLabelMap),
                                        key: "l",
                                        modifiers: [.command, .shift]))
        labelsMenu.addItem(.separator())
        labelsMenu.addItem(makeLabelingToolItem("Brush", tool: "brush", key: "b"))
        labelsMenu.addItem(makeLabelingToolItem("Eraser", tool: "eraser", key: "x"))
        labelsMenu.addItem(makeLabelingToolItem("Freehand ROI", tool: "freehand", key: "f"))
        labelsMenu.addItem(makeLabelingToolItem("Threshold Seed", tool: "threshold", key: "t"))
        labelsMenu.addItem(makeLabelingToolItem("SUV Gradient Seed", tool: "suvGradient", key: "g"))
        labelsMenu.addItem(makeLabelingToolItem("Region Grow", tool: "regionGrow", key: "y"))
        labelsMenu.addItem(makeLabelingToolItem("Active Contour Snake", tool: "activeContour", key: "n"))
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
        measurementsMenu.addItem(makeMenuItem(title: "Clear Measurements",
                                             action: #selector(clearMeasurements),
                                             key: "\u{8}"))
        measurementsMenu.addItem(.separator())
        measurementsMenu.addItem(makeMenuItem(title: "Save Study Session", action: #selector(saveStudySession), key: "s"))
        measurementsMenu.addItem(makeMenuItem(title: "New Measurement Session",
                                             action: #selector(newStudySession),
                                             key: "n",
                                             modifiers: [.command, .option]))
        measurementsMenuItem.submenu = measurementsMenu
        mainMenu.addItem(measurementsMenuItem)

        let aiMenuItem = NSMenuItem()
        let aiMenu = NSMenu(title: "AI Engines")
        aiMenu.addItem(makeEnginePanelItem("MONAI Label", panel: "monai", key: "m"))
        aiMenu.addItem(makeEnginePanelItem("nnU-Net", panel: "nnunet", key: "n"))
        aiMenu.addItem(makeEnginePanelItem("PET Engine", panel: "pet", key: "p"))
        aiMenu.addItem(makeEnginePanelItem("AutoPET V Experiments", panel: "autoPET", key: "e"))
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
        windowMenu.addItem(makeMenuItem(title: "Merge Into Single Study Window",
                                        action: #selector(mergeStudyWindows),
                                        key: "m",
                                        modifiers: [.command, .option]))
        windowMenu.addItem(makeMenuItem(title: "Split Into Navigator + Viewer",
                                        action: #selector(splitStudyWindows),
                                        key: "3",
                                        modifiers: [.command, .option]))
        windowMenu.addItem(.separator())
        windowMenu.addItem(makeMenuItem(title: "Show Study Navigator",
                                        action: #selector(showStudyNavigator),
                                        key: "1",
                                        modifiers: [.command, .option]))
        windowMenu.addItem(makeMenuItem(title: "Show Study Viewer",
                                        action: #selector(showStudyViewer),
                                        key: "2",
                                        modifiers: [.command, .option]))
        windowMenu.addItem(.separator())
        windowMenu.addItem(makeMenuItem(title: "Fit Active Window to Display",
                                        action: #selector(fitActiveWindowToDisplay),
                                        key: "f",
                                        modifiers: [.command, .option]))
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
        postToStudyNavigator(.openDICOMDirectory)
    }

    @objc private func openNIfTIFile() {
        postToStudyNavigator(.openNIfTIFile)
    }

    @objc private func undoLastEdit() { postToStudyViewer(.undoLastEdit) }
    @objc private func redoLastEdit() { postToStudyViewer(.redoLastEdit) }
    @objc private func resetEditableChanges() { postToStudyViewer(.resetEditableChanges) }
    @objc private func createLabelMap() { postToStudyViewer(.createLabelMap) }
    @objc private func clearMeasurements() { postToStudyViewer(.clearMeasurements) }
    @objc private func saveStudySession() { postToStudyViewer(.saveStudySession) }
    @objc private func newStudySession() { postToStudyViewer(.newStudySession) }
    @objc private func toggleLinkedZoomPan() { postToStudyViewer(.toggleLinkedZoomPan) }
    @objc private func toggleFocusMode() { postToStudyViewer(.toggleFocusMode) }

    @objc private func selectViewerTool(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? String else { return }
        postToStudyViewer(.selectViewerTool, userInfo: ["tool": tool])
    }

    @objc private func selectLabelingTool(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? String else { return }
        postToStudyViewer(.selectLabelingTool, userInfo: ["tool": tool])
    }

    @objc private func showEngineInspector(_ sender: NSMenuItem) {
        guard let panel = sender.representedObject as? String else { return }
        postToStudyViewer(.showEngineInspector, userInfo: ["panel": panel])
    }

    @objc private func mergeStudyWindows() {
        openUnifiedStudyWindow()
    }

    @objc private func splitStudyWindows() {
        openSplitStudyWindows()
    }

    @objc private func showStudyNavigator() {
        studyWindowLayout = .split
        unifiedWindow?.orderOut(nil)
        openStudyNavigator()
    }

    @objc private func showStudyViewer() {
        studyWindowLayout = .split
        unifiedWindow?.orderOut(nil)
        openStudyViewer()
    }

    @objc private func fitActiveWindowToDisplay() {
        guard let window = NSApp.keyWindow ?? unifiedWindow ?? viewerWindow ?? navigatorWindow,
              let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: true, animate: true)
    }

    @objc private func showAbout() {
        postToStudyNavigator(.showAboutWindow)
    }

    private func postToStudyNavigator(_ name: Notification.Name,
                                      userInfo: [AnyHashable: Any]? = nil) {
        if studyWindowLayout == .unified {
            openUnifiedStudyWindow()
        } else {
            openStudyNavigator()
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        }
    }

    private func postToStudyViewer(_ name: Notification.Name,
                                   userInfo: [AnyHashable: Any]? = nil) {
        if studyWindowLayout == .unified {
            openUnifiedStudyWindow()
        } else {
            openStudyViewer()
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let root = TracerSettingsView()
                .preferredColorScheme(.dark)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Tracer Settings"
            window.contentView = NSHostingView(rootView: root)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }
}

let app = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = TracerAppDelegate()
    app.delegate = delegate
    app.run()
    _ = delegate
}
#else
DicomViewerApp.main()
#endif
