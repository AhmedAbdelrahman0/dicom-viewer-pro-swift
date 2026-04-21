import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct ContentView: View {
    @StateObject private var vm = ViewerViewModel()
    @State private var showingFileImporter = false
    @State private var showingDirectoryPicker = false
    @State private var fileImporterMode: FileImporterMode = .volume

    enum FileImporterMode { case volume, overlay }

    public init() {}

    public var body: some View {
        NavigationSplitView {
            StudyBrowserView(vm: vm,
                             onImportFolder: { showingDirectoryPicker = true },
                             onImportVolume: {
                                 fileImporterMode = .volume
                                 showingFileImporter = true
                             },
                             onImportOverlay: {
                                 fileImporterMode = .overlay
                                 showingFileImporter = true
                             })
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } content: {
            MPRLayoutView()
                .environmentObject(vm)
                .navigationSplitViewColumnWidth(min: 400, ideal: 900)
        } detail: {
            ControlsPanel()
                .environmentObject(vm)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        }
        .toolbar { mainToolbar }
        .overlay(alignment: .bottom) {
            if vm.isLoading {
                loadingIndicator
            } else {
                statusBar
            }
        }
        .environmentObject(vm)
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
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ForEach(ViewerTool.allCases) { tool in
                ToolButton(
                    tool: tool,
                    isActive: vm.activeTool == tool,
                    action: { vm.activeTool = tool }
                )
            }
            Divider()
            Button {
                vm.autoWL()
            } label: {
                Label("Auto W/L", systemImage: "wand.and.stars")
            }
            .help("Automatically compute window/level from the 1–99 percentile of the current volume.\nShortcut: ⌘R")
            .keyboardShortcut("r", modifiers: [.command])
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            Text(vm.statusMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            Spacer()
        }
        .background(.regularMaterial)
    }

    private var loadingIndicator: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(vm.statusMessage)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .cornerRadius(6)
        .padding(.bottom, 16)
    }

    // MARK: - File handlers

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
        .help(tool.helpText)
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
        .help(tooltip)
    }
}

// MARK: - MPR Layout

struct MPRLayoutView: View {
    @EnvironmentObject var vm: ViewerViewModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / 2
            let h = geo.size.height / 2
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    SliceView(axis: 2, title: "Axial")
                        .frame(width: w, height: h)
                    SliceView(axis: 0, title: "Sagittal")
                        .frame(width: w, height: h)
                }
                HStack(spacing: 2) {
                    SliceView(axis: 1, title: "Coronal")
                        .frame(width: w, height: h)
                    ThreeDPlaceholderView()
                        .frame(width: w, height: h)
                }
            }
        }
        .background(Color.black)
    }
}

struct ThreeDPlaceholderView: View {
    @EnvironmentObject var vm: ViewerViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("3D MIP")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.blue)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.displayP3, white: 0.1))

            ZStack {
                Color.black
                if let img = makeMIP() {
                    Image(decorative: img, scale: 1.0)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("3D view (MIP)")
                        .foregroundColor(.gray)
                }
            }
        }
        .background(Color(.displayP3, white: 0.08))
    }

    private func makeMIP() -> CGImage? {
        guard let v = vm.currentVolume else { return nil }
        // Coronal MIP: max along axis 1 (height)
        let w = v.width, h = v.height, d = v.depth
        var mip = [Float](repeating: -.infinity, count: d * w)
        for z in 0..<d {
            for y in 0..<h {
                let rowStart = z * h * w + y * w
                for x in 0..<w {
                    let idx = z * w + x
                    let p = v.pixels[rowStart + x]
                    if p > mip[idx] { mip[idx] = p }
                }
            }
        }
        // Flip vertically to put head on top
        let flipped = SliceTransform.flipVertical(mip, width: w, height: d)
        return PixelRenderer.makeGrayImage(
            pixels: flipped, width: w, height: d,
            window: vm.window, level: vm.level, invert: false
        )
    }
}
