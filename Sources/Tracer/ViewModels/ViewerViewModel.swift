import Foundation
import SwiftUI
import Combine
import SwiftData
import simd

public enum ViewerTool: String, CaseIterable, Identifiable {
    case wl, pan, zoom, distance, angle, area, suvSphere

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .wl: return "W/L"
        case .pan: return "Pan"
        case .zoom: return "Zoom"
        case .distance: return "Distance"
        case .angle: return "Angle"
        case .area: return "Area"
        case .suvSphere: return "SUV Sphere"
        }
    }
    public var systemImage: String {
        switch self {
        case .wl: return "slider.horizontal.3"
        case .pan: return "hand.draw"
        case .zoom: return "plus.magnifyingglass"
        case .distance: return "ruler"
        case .angle: return "angle"
        case .area: return "skew"
        case .suvSphere: return "flame.circle"
        }
    }

    /// Rich description shown as hover tooltip.
    public var helpText: String {
        switch self {
        case .wl:
            return "Window / Level\n"
                 + "Drag horizontally to adjust window width,\n"
                 + "vertically to adjust window level.\n"
                 + "Shortcut: W"
        case .pan:
            return "Pan\n"
                 + "Click and drag to move the image within the view.\n"
                 + "Works even when the image is zoomed in.\n"
                 + "Shortcut: P  (or middle-mouse drag at any time)"
        case .zoom:
            return "Zoom\n"
                 + "Drag up/down to zoom in/out.\n"
                 + "Scroll wheel + ⇧/⌘ also zooms.\n"
                 + "Double-click to fit to window.\n"
                 + "Shortcut: Z"
        case .distance:
            return "Distance Measurement\n"
                 + "Click two points to measure Euclidean distance in mm.\n"
                 + "Uses the volume's pixel spacing for calibration.\n"
                 + "Shortcut: D"
        case .angle:
            return "Angle Measurement\n"
                 + "Click three points (arm 1 → vertex → arm 2)\n"
                 + "to measure the angle between two arms in degrees.\n"
                 + "Shortcut: A"
        case .area:
            return "Area / ROI\n"
                 + "Click multiple points to outline a polygon.\n"
                 + "Shows the enclosed area in mm² / cm².\n"
                 + "Shortcut: R"
        case .suvSphere:
            return "Spherical SUV ROI\n"
                 + "Click PET or fused images to place a 3D spherical VOI.\n"
                 + "Reports SUVmax, SUVmean, and sampled volume.\n"
                 + "Shortcut: S"
        }
    }

    /// Keyboard shortcut character for toolbar binding.
    public var keyboardShortcut: Character? {
        switch self {
        case .wl: return "w"
        case .pan: return "p"
        case .zoom: return "z"
        case .distance: return "d"
        case .angle: return "a"
        case .area: return "r"
        case .suvSphere: return "s"
        }
    }
}

public struct VolumeOperationStatus: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let startedAt: Date
}

private struct PETMIPProjectionKey: Hashable, Sendable {
    let volumeIdentity: String
    let axis: Int
    let width: Int
    let height: Int
    let depth: Int

    init(volume: ImageVolume, axis: Int) {
        self.volumeIdentity = volume.sessionIdentity
        self.axis = axis
        self.width = volume.width
        self.height = volume.height
        self.depth = volume.depth
    }
}

private struct PETMIPProjection: Sendable {
    let pixels: [Float]
    let width: Int
    let height: Int

    static func compute(volume: ImageVolume, axis: Int) -> PETMIPProjection {
        let pixels = volume.pixels
        let width = volume.width
        let height = volume.height
        let depth = volume.depth

        switch axis {
        case 0:
            var out = [Float](repeating: 0, count: depth * height)
            for z in 0..<depth {
                let slabStart = z * height * width
                for y in 0..<height {
                    let rowStart = slabStart + y * width
                    var maxValue = -Float.greatestFiniteMagnitude
                    for x in 0..<width {
                        maxValue = Swift.max(maxValue, pixels[rowStart + x])
                    }
                    out[z * height + y] = maxValue
                }
            }
            return PETMIPProjection(pixels: out, width: height, height: depth)

        case 1:
            var out = [Float](repeating: 0, count: depth * width)
            for z in 0..<depth {
                let slabStart = z * height * width
                for x in 0..<width {
                    var maxValue = -Float.greatestFiniteMagnitude
                    for y in 0..<height {
                        maxValue = Swift.max(maxValue, pixels[slabStart + y * width + x])
                    }
                    out[z * width + x] = maxValue
                }
            }
            return PETMIPProjection(pixels: out, width: width, height: depth)

        default:
            var out = [Float](repeating: 0, count: height * width)
            for y in 0..<height {
                for x in 0..<width {
                    var maxValue = -Float.greatestFiniteMagnitude
                    for z in 0..<depth {
                        maxValue = Swift.max(maxValue, pixels[z * height * width + y * width + x])
                    }
                    out[y * width + x] = maxValue
                }
            }
            return PETMIPProjection(pixels: out, width: width, height: height)
        }
    }
}

private enum SliceRenderLayer: String, Hashable {
    case base
    case overlay
    case label
    case labelOutline
}

private struct SliceRenderCacheKey: Hashable {
    let layer: SliceRenderLayer
    let sourceVolumeID: UUID?
    let referenceVolumeID: UUID?
    let labelMapID: UUID?
    let labelRevision: Int
    let axis: Int
    let sliceIndex: Int
    let mode: String
    let width: Int
    let height: Int
    let depth: Int
    let window: Int
    let level: Int
    let invert: Bool
    let colormap: String
    let opacity: Int
    let flipHorizontal: Bool
    let flipVertical: Bool
    let suvSignature: String
}

@MainActor
public final class ViewerViewModel: ObservableObject {

    // Loaded volumes (cache)
    @Published public var loadedVolumes: [ImageVolume] = []

    // Current primary volume being displayed
    @Published public var currentVolume: ImageVolume?

    // Fusion (optional)
    @Published public var fusion: FusionPair?

    // Labeling (delegate to dedicated VM)
    @Published public var labeling = LabelingViewModel()

    // Window/Level
    @Published public var window: Double = 400
    @Published public var level: Double = 40

    // Slice indices [sagittal(0), coronal(1), axial(2)]
    @Published public var sliceIndices: [Int] = [0, 0, 0]

    // Active tool
    @Published public var activeTool: ViewerTool = .wl

    // Display transforms
    @Published public var invertColors: Bool = false
    @Published public var invertPETMIP: Bool = false
    @Published public var correctAnteriorPosteriorDisplay: Bool = true
    @Published public var correctRightLeftDisplay: Bool = false
    @Published public var linkZoomPanAcrossPanes: Bool = true
    @Published public var sharedViewportTransform: ViewportTransformState = .identity
    @Published public var paneViewportTransforms: [Int: ViewportTransformState] = [:]

    // Overlay display settings
    @Published public var overlayOpacity: Double = 0.5
    @Published public var overlayColormap: Colormap = .tracerPET
    @Published public var mipColormap: Colormap = .grayscale
    @Published public var overlayWindow: Double = 6
    @Published public var overlayLevel: Double = 3
    @Published public var petMRRegistrationMode: PETMRRegistrationMode = .rigidThenDeformable
    @Published public var petMRDeformableRegistration = PETMRDeformableRegistrationConfiguration()
    @Published public var hangingGrid: HangingGridLayout = .defaultPETCT
    @Published public var suvSettings = SUVCalculationSettings()
    @Published public var hangingPanes: [HangingPaneConfiguration] = HangingPaneConfiguration.defaultPETCT
    @Published public var lastVolumeMeasurementReport: VolumeMeasurementReport?
    @Published public var suvSphereRadiusMM: Double = 6.2
    @Published public var suvROIMeasurements: [SUVROIMeasurement] = []
    @Published public var lastSUVROIMeasurement: SUVROIMeasurement?
    @Published public var dynamicStudy: DynamicImageStudy?
    @Published public var selectedDynamicFrameIndex: Int = 0
    @Published public var dynamicPlaybackFPS: Double = 2.0
    @Published public private(set) var isDynamicPlaybackRunning: Bool = false
    @Published public private(set) var dynamicTimeActivityCurve: [DynamicTimeActivityPoint] = []
    @Published public private(set) var isDynamicTACComputing: Bool = false
    @Published public private(set) var volumeOperationStatus: VolumeOperationStatus?
    @Published public private(set) var petMIPCacheRevision: Int = 0
    @Published public private(set) var appUndoDepth: Int = 0
    @Published public private(set) var appRedoDepth: Int = 0

    // Annotations per view
    @Published public var annotations: [Annotation] = []

    // Status
    @Published public var statusMessage: String = "Ready. Open a DICOM or NIfTI file to begin."
    @Published public var isLoading: Bool = false
    @Published public var progress: Double = 0
    @Published public var indexProgress: PACSIndexScanProgress?
    @Published public var indexRevision: Int = 0
    @Published public private(set) var isIndexing: Bool = false

    /// Shared flag that lets the UI cancel a long-running PACS index scan.
    /// Read-only outside the VM; callers cancel via `cancelIndexing()`.
    public let indexCancellation = PACSScanCancellation()

    private struct AppHistoryRecord {
        let name: String
        let undo: () -> Void
        let redo: () -> Void
    }

    private struct EditableSnapshot {
        var window: Double
        var level: Double
        var invertColors: Bool
        var invertPETMIP: Bool
        var correctAnteriorPosteriorDisplay: Bool
        var correctRightLeftDisplay: Bool
        var linkZoomPanAcrossPanes: Bool
        var sharedViewportTransform: ViewportTransformState
        var paneViewportTransforms: [Int: ViewportTransformState]
        var overlayOpacity: Double
        var overlayColormap: Colormap
        var mipColormap: Colormap
        var overlayWindow: Double
        var overlayLevel: Double
        var petMRRegistrationMode: PETMRRegistrationMode
        var petMRDeformableRegistration: PETMRDeformableRegistrationConfiguration
        var hangingGrid: HangingGridLayout
        var hangingPanes: [HangingPaneConfiguration]
        var annotations: [Annotation]
        var suvSphereRadiusMM: Double
        var suvROIs: [SUVROIMeasurement]
        var lastSUVROI: SUVROIMeasurement?
        var labelVoxels: [UUID: [UInt16]]
    }

    private var appUndoStack: [AppHistoryRecord] = []
    private var appRedoStack: [AppHistoryRecord] = []
    private var isReplayingAppHistory = false
    private let maxAppHistoryRecords = 120
    private let maxBackgroundTrackedChangedVoxels = 5_000_000
    private var volumeOperationTask: Task<Void, Never>?
    private var autoWindowTask: Task<Void, Never>?
    private var dynamicPlaybackTask: Task<Void, Never>?
    private var dynamicTACTask: Task<Void, Never>?
    private let maxPETMIPProjectionCacheEntries = 12
    private var petMIPProjectionCache: [PETMIPProjectionKey: PETMIPProjection] = [:]
    private var petMIPProjectionCacheOrder: [PETMIPProjectionKey] = []
    private var petMIPProjectionTasks: [PETMIPProjectionKey: Task<Void, Never>] = [:]
    private let maxSliceRenderCacheEntries = 96
    private var sliceRenderCache: [SliceRenderCacheKey: CGImage] = [:]
    private var sliceRenderCacheOrder: [SliceRenderCacheKey] = []
    public private(set) var sliceRenderCacheHitCount: Int = 0
    public private(set) var sliceRenderCacheMissCount: Int = 0

    // DICOM study browser
    @Published public var loadedSeries: [DICOMSeries] = []

    /// Capped LRU list of the last `RecentVolumesStore.maximumEntries`
    /// volumes the user has opened. Persisted across launches. Displayed as
    /// a horizontal chip row at the top of the Study Browser.
    @Published public private(set) var recentVolumes: [RecentVolume] = []
    private let recentVolumesStore = RecentVolumesStore()

    public init() {
        self.recentVolumes = recentVolumesStore.load()
    }

    public var loadedCTVolumes: [ImageVolume] {
        loadedVolumes.filter { Modality.normalize($0.modality) == .CT }
    }

    public var loadedPETVolumes: [ImageVolume] {
        loadedVolumes.filter { Modality.normalize($0.modality) == .PT }
    }

    public var loadedMRVolumes: [ImageVolume] {
        loadedVolumes.filter { Modality.normalize($0.modality) == .MR }
    }

    public var loadedAnatomicalVolumes: [ImageVolume] {
        loadedVolumes.filter {
            let modality = Modality.normalize($0.modality)
            return modality == .CT || modality == .MR
        }
    }

    public var activePETQuantificationVolume: ImageVolume? {
        if let fusion {
            return fusion.displayedOverlay
        }
        if let currentVolume, Modality.normalize(currentVolume.modality) == .PT {
            return currentVolume
        }
        return loadedPETVolumes.first
    }

    public var activePETSourceVolume: ImageVolume? {
        fusion?.overlayVolume ?? activePETQuantificationVolume
    }

    public var petOverlayRangeMin: Double {
        overlayLevel - overlayWindow / 2
    }

    public var petOverlayRangeMax: Double {
        overlayLevel + overlayWindow / 2
    }

    public var canUndo: Bool {
        appUndoDepth > 0 || labeling.undoDepth > 0
    }

    public var canRedo: Bool {
        appRedoDepth > 0 || labeling.redoDepth > 0
    }

    public var isVolumeOperationRunning: Bool {
        volumeOperationStatus != nil
    }

    public func cancelVolumeOperation() {
        volumeOperationTask?.cancel()
        volumeOperationTask = nil
        if let operation = volumeOperationStatus {
            statusMessage = "Cancelled \(operation.title)"
        }
        volumeOperationStatus = nil
    }

    public func volumeForDisplayMode(_ mode: SliceDisplayMode) -> ImageVolume? {
        switch mode {
        case .primary:
            return currentVolume
        case .fused:
            return fusion?.baseVolume ?? currentVolume
        case .ctOnly:
            if let base = fusion?.baseVolume, Modality.normalize(base.modality) == .CT {
                return base
            }
            return loadedCTVolumes.first ?? currentVolume
        case .petOnly:
            return activePETQuantificationVolume ?? currentVolume
        case .mrT1:
            return preferredMRVolume(for: .t1) ?? currentVolume
        case .mrT2:
            return preferredMRVolume(for: .t2) ?? currentVolume
        case .mrFLAIR:
            return preferredMRVolume(for: .flair) ?? currentVolume
        case .mrDWI:
            return preferredMRVolume(for: .dwi) ?? currentVolume
        case .mrADC:
            return preferredMRVolume(for: .adc) ?? currentVolume
        case .mrPost:
            return preferredMRVolume(for: .postContrast) ?? currentVolume
        case .mrOther:
            return preferredMRVolume(for: .other) ?? currentVolume
        }
    }

    public func setFusionOverlayVisible(_ visible: Bool) {
        let before = fusion?.overlayVisible ?? false
        fusion?.overlayVisible = visible
        fusion?.objectWillChange.send()
        objectWillChange.send()
        recordValueChange(name: "Toggle PET overlay", before: before, after: visible) { vm, value in
            vm.fusion?.overlayVisible = value
            vm.fusion?.objectWillChange.send()
            vm.objectWillChange.send()
        }
    }

    public func setFusionOpacity(_ opacity: Double) {
        let before = overlayOpacity
        overlayOpacity = max(0, min(1, opacity))
        fusion?.opacity = overlayOpacity
        fusion?.objectWillChange.send()
        recordValueChange(name: "PET overlay opacity", before: before, after: overlayOpacity) { vm, value in
            vm.overlayOpacity = value
            vm.fusion?.opacity = value
            vm.fusion?.objectWillChange.send()
        }
    }

    public func setFusionColormap(_ colormap: Colormap) {
        let before = overlayColormap
        overlayColormap = colormap
        fusion?.colormap = colormap
        fusion?.objectWillChange.send()
        recordValueChange(name: "PET overlay color", before: before, after: colormap) { vm, value in
            vm.overlayColormap = value
            vm.fusion?.colormap = value
            vm.fusion?.objectWillChange.send()
        }
    }

    public func setPETMIPColormap(_ colormap: Colormap) {
        let before = mipColormap
        mipColormap = colormap
        recordValueChange(name: "PET MIP color", before: before, after: colormap) { vm, value in
            vm.mipColormap = value
        }
    }

    public func setInvertColors(_ enabled: Bool) {
        let before = invertColors
        invertColors = enabled
        recordValueChange(name: "Invert images", before: before, after: enabled) { vm, value in
            vm.invertColors = value
        }
    }

    public func setInvertPETMIP(_ enabled: Bool) {
        let before = invertPETMIP
        invertPETMIP = enabled
        recordValueChange(name: "Invert PET MIP", before: before, after: enabled) { vm, value in
            vm.invertPETMIP = value
        }
    }

    public func setCorrectAnteriorPosteriorDisplay(_ enabled: Bool) {
        let before = correctAnteriorPosteriorDisplay
        correctAnteriorPosteriorDisplay = enabled
        recordValueChange(name: "Flip A/P display axis", before: before, after: enabled) { vm, value in
            vm.correctAnteriorPosteriorDisplay = value
        }
    }

    public func setCorrectRightLeftDisplay(_ enabled: Bool) {
        let before = correctRightLeftDisplay
        correctRightLeftDisplay = enabled
        recordValueChange(name: "Flip R/L display axis", before: before, after: enabled) { vm, value in
            vm.correctRightLeftDisplay = value
        }
    }

    public func setDisplayOrientationCorrection(ap: Bool, rl: Bool, name: String = "Display positioning") {
        let before = (correctAnteriorPosteriorDisplay, correctRightLeftDisplay)
        let after = (ap, rl)
        correctAnteriorPosteriorDisplay = ap
        correctRightLeftDisplay = rl
        recordHistoryIfNeeded(
            name: name,
            changed: before.0 != after.0 || before.1 != after.1
        ) { [weak self] in
            self?.correctAnteriorPosteriorDisplay = before.0
            self?.correctRightLeftDisplay = before.1
        } redo: { [weak self] in
            self?.correctAnteriorPosteriorDisplay = after.0
            self?.correctRightLeftDisplay = after.1
        }
    }

    public func setLinkZoomPanAcrossPanes(_ enabled: Bool) {
        let before = linkZoomPanAcrossPanes
        linkZoomPanAcrossPanes = enabled
        recordValueChange(name: "Link zoom/pan", before: before, after: enabled) { vm, value in
            vm.linkZoomPanAcrossPanes = value
        }
    }

    public func setPETOverlayRange(min rawMin: Double, max rawMax: Double) {
        let before = (overlayWindow, overlayLevel)
        let lower = max(0, min(rawMin, rawMax - 0.1))
        let upper = max(lower + 0.1, rawMax)
        overlayWindow = upper - lower
        overlayLevel = (upper + lower) / 2
        fusion?.overlayWindow = overlayWindow
        fusion?.overlayLevel = overlayLevel
        fusion?.objectWillChange.send()
        let after = (overlayWindow, overlayLevel)
        recordHistoryIfNeeded(name: "PET SUV window", changed: abs(before.0 - after.0) > 0.0001 || abs(before.1 - after.1) > 0.0001) { [weak self] in
            self?.applyPETOverlayWindow(window: before.0, level: before.1)
        } redo: { [weak self] in
            self?.applyPETOverlayWindow(window: after.0, level: after.1)
        }
    }

    public func setPETMRRegistrationMode(_ mode: PETMRRegistrationMode) {
        let before = petMRRegistrationMode
        petMRRegistrationMode = mode
        recordValueChange(name: "PET/MR registration mode", before: before, after: mode) { vm, value in
            vm.petMRRegistrationMode = value
        }
    }

    public func setPETMRDeformableRegistration(_ configuration: PETMRDeformableRegistrationConfiguration) {
        let before = petMRDeformableRegistration
        petMRDeformableRegistration = configuration
        recordValueChange(name: "PET/MR deformable backend", before: before, after: configuration) { vm, value in
            vm.petMRDeformableRegistration = value
        }
    }

    public func setHangingPaneKind(index: Int, kind: HangingPaneKind) {
        guard hangingPanes.indices.contains(index) else { return }
        let before = hangingPanes
        hangingPanes[index].kind = kind
        let after = hangingPanes
        recordValueChange(name: "Hanging pane role", before: before, after: after) { vm, value in
            vm.hangingPanes = value
        }
    }

    public func setHangingPanePlane(index: Int, plane: SlicePlane) {
        guard hangingPanes.indices.contains(index) else { return }
        let before = hangingPanes
        hangingPanes[index].plane = plane
        let after = hangingPanes
        recordValueChange(name: "Hanging pane plane", before: before, after: after) { vm, value in
            vm.hangingPanes = value
        }
    }

    public func setHangingGrid(columns: Int, rows: Int) {
        let beforeGrid = hangingGrid
        let beforePanes = hangingPanes
        let nextGrid = HangingGridLayout(columns: columns, rows: rows)
        applyHangingProtocol(grid: nextGrid, panes: resizedHangingPanes(hangingPanes, count: nextGrid.paneCount))
        let afterGrid = hangingGrid
        let afterPanes = hangingPanes
        recordHistoryIfNeeded(
            name: "Hanging layout \(nextGrid.displayName)",
            changed: beforeGrid != afterGrid || beforePanes != afterPanes
        ) { [weak self] in
            self?.applyHangingProtocol(grid: beforeGrid, panes: beforePanes)
        } redo: { [weak self] in
            self?.applyHangingProtocol(grid: afterGrid, panes: afterPanes)
        }
    }

    public func setHangingGrid(_ layout: HangingGridLayout) {
        setHangingGrid(columns: layout.columns, rows: layout.rows)
    }

    public func resetPETHangingProtocol() {
        let beforeGrid = hangingGrid
        let beforePanes = hangingPanes
        applyHangingProtocol(grid: .defaultPETCT, panes: HangingPaneConfiguration.defaultPETCT)
        let afterGrid = hangingGrid
        let afterPanes = hangingPanes
        recordHistoryIfNeeded(
            name: "Reset hanging protocol",
            changed: beforeGrid != afterGrid || beforePanes != afterPanes
        ) { [weak self] in
            self?.applyHangingProtocol(grid: beforeGrid, panes: beforePanes)
        } redo: { [weak self] in
            self?.applyHangingProtocol(grid: afterGrid, panes: afterPanes)
        }
    }

    public func resetMRIHangingProtocol() {
        let beforeGrid = hangingGrid
        let beforePanes = hangingPanes
        applyHangingProtocol(grid: .threeByTwo, panes: HangingPaneConfiguration.defaultMRI)
        let afterGrid = hangingGrid
        let afterPanes = hangingPanes
        recordHistoryIfNeeded(
            name: "MRI hanging protocol",
            changed: beforeGrid != afterGrid || beforePanes != afterPanes
        ) { [weak self] in
            self?.applyHangingProtocol(grid: beforeGrid, panes: beforePanes)
        } redo: { [weak self] in
            self?.applyHangingProtocol(grid: afterGrid, panes: afterPanes)
        }
    }

    public func resetPETMRHangingProtocol() {
        let beforeGrid = hangingGrid
        let beforePanes = hangingPanes
        applyHangingProtocol(grid: .threeByTwo, panes: HangingPaneConfiguration.defaultPETMR)
        let afterGrid = hangingGrid
        let afterPanes = hangingPanes
        recordHistoryIfNeeded(
            name: "PET/MR hanging protocol",
            changed: beforeGrid != afterGrid || beforePanes != afterPanes
        ) { [weak self] in
            self?.applyHangingProtocol(grid: beforeGrid, panes: beforePanes)
        } redo: { [weak self] in
            self?.applyHangingProtocol(grid: afterGrid, panes: afterPanes)
        }
    }

    public func resetUnifiedHangingProtocol() {
        let beforeGrid = hangingGrid
        let beforePanes = hangingPanes
        applyHangingProtocol(grid: HangingGridLayout(columns: 4, rows: 2),
                             panes: HangingPaneConfiguration.defaultUnified)
        let afterGrid = hangingGrid
        let afterPanes = hangingPanes
        recordHistoryIfNeeded(
            name: "Unified hanging protocol",
            changed: beforeGrid != afterGrid || beforePanes != afterPanes
        ) { [weak self] in
            self?.applyHangingProtocol(grid: beforeGrid, panes: beforePanes)
        } redo: { [weak self] in
            self?.applyHangingProtocol(grid: afterGrid, panes: afterPanes)
        }
    }

    private func applyHangingProtocol(grid: HangingGridLayout,
                                      panes: [HangingPaneConfiguration]) {
        hangingGrid = grid
        hangingPanes = resizedHangingPanes(panes, count: grid.paneCount)
    }

    private func resizedHangingPanes(_ panes: [HangingPaneConfiguration],
                                     count: Int) -> [HangingPaneConfiguration] {
        let target = max(1, min(64, count))
        if panes.count == target {
            return panes
        }
        if panes.count > target {
            return Array(panes.prefix(target))
        }
        var resized = panes
        for index in panes.count..<target {
            resized.append(HangingPaneConfiguration.defaultPane(at: index))
        }
        return resized
    }

    public func viewportTransform(for paneKey: Int) -> ViewportTransformState {
        if linkZoomPanAcrossPanes {
            return sharedViewportTransform
        }
        return paneViewportTransforms[paneKey] ?? .identity
    }

    public func setViewportZoom(_ zoom: Double, for paneKey: Int) {
        let clamped = max(0.25, min(10.0, zoom))
        if linkZoomPanAcrossPanes {
            sharedViewportTransform.zoom = clamped
        } else {
            var state = paneViewportTransforms[paneKey] ?? .identity
            state.zoom = clamped
            paneViewportTransforms[paneKey] = state
        }
    }

    public func setViewportPan(x: Double, y: Double, for paneKey: Int) {
        if linkZoomPanAcrossPanes {
            sharedViewportTransform.panX = x
            sharedViewportTransform.panY = y
        } else {
            var state = paneViewportTransforms[paneKey] ?? .identity
            state.panX = x
            state.panY = y
            paneViewportTransforms[paneKey] = state
        }
    }

    public func resetViewportTransform(for paneKey: Int) {
        if linkZoomPanAcrossPanes {
            sharedViewportTransform = .identity
        } else {
            paneViewportTransforms[paneKey] = .identity
        }
    }

    public func resetAllViewportTransforms() {
        sharedViewportTransform = .identity
        paneViewportTransforms = [:]
    }

    public func undoLastEdit() {
        if let record = appUndoStack.popLast() {
            isReplayingAppHistory = true
            record.undo()
            isReplayingAppHistory = false
            appRedoStack.append(record)
            refreshAppHistoryDepths()
            statusMessage = "Undo: \(record.name)"
        } else if labeling.undoDepth > 0 {
            labeling.undo()
            startActiveVolumeMeasurement(method: .activeLabel, thresholdSummary: "Undo")
            statusMessage = "Undo label edit"
        } else {
            statusMessage = "Nothing to undo"
        }
    }

    public func redoLastEdit() {
        if let record = appRedoStack.popLast() {
            isReplayingAppHistory = true
            record.redo()
            isReplayingAppHistory = false
            appUndoStack.append(record)
            refreshAppHistoryDepths()
            statusMessage = "Redo: \(record.name)"
        } else if labeling.redoDepth > 0 {
            labeling.redo()
            startActiveVolumeMeasurement(method: .activeLabel, thresholdSummary: "Redo")
            statusMessage = "Redo label edit"
        } else {
            statusMessage = "Nothing to redo"
        }
    }

    public func resetEditableChanges() {
        let before = editableSnapshot()
        var resetVoxels = 0
        for map in labeling.labelMaps {
            resetVoxels += map.voxels.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
            map.voxels = [UInt16](repeating: 0, count: map.voxels.count)
            map.objectWillChange.send()
        }
        if resetVoxels > 0 {
            labeling.markDirty()
        }
        annotations.removeAll()
        suvROIMeasurements.removeAll()
        lastSUVROIMeasurement = nil
        lastVolumeMeasurementReport = nil
        resetAllViewportTransforms()
        invertColors = false
        invertPETMIP = false
        if let currentVolume {
            let (w, l) = autoWindowLevel(pixels: currentVolume.pixels)
            window = w
            level = l
        }
        let after = editableSnapshot()
        recordHistoryIfNeeded(name: "Reset edits", changed: true) { [weak self] in
            self?.applyEditableSnapshot(before)
        } redo: { [weak self] in
            self?.applyEditableSnapshot(after)
        }
        statusMessage = "Reset editable labels, measurements, zoom/pan, and display overrides (\(resetVoxels) voxels cleared)"
    }

    public func recordViewportChange(named name: String = "Zoom/pan",
                                     before: ViewportTransformState,
                                     after: ViewportTransformState,
                                     paneKey: Int) {
        let wasLinked = linkZoomPanAcrossPanes
        recordHistoryIfNeeded(name: name, changed: before != after) { [weak self] in
            self?.applyViewportTransform(before, for: paneKey, linked: wasLinked)
        } redo: { [weak self] in
            self?.applyViewportTransform(after, for: paneKey, linked: wasLinked)
        }
    }

    public func recordWindowLevelChange(before: (window: Double, level: Double),
                                        after: (window: Double, level: Double),
                                        name: String = "Window / level") {
        let changed = abs(before.window - after.window) > 0.0001 ||
            abs(before.level - after.level) > 0.0001
        recordHistoryIfNeeded(name: name, changed: changed) { [weak self] in
            self?.window = before.window
            self?.level = before.level
        } redo: { [weak self] in
            self?.window = after.window
            self?.level = after.level
        }
    }

    public func recordLabelEditIfChanged(named name: String, beforeUndoDepth: Int?) {
        guard let beforeUndoDepth, labeling.undoDepth > beforeUndoDepth else { return }
        recordHistoryIfNeeded(name: name, changed: true) { [weak self] in
            self?.labeling.undo()
            self?.startActiveVolumeMeasurement(method: .activeLabel, thresholdSummary: "Undo")
        } redo: { [weak self] in
            self?.labeling.redo()
            self?.startActiveVolumeMeasurement(method: .activeLabel, thresholdSummary: "Redo")
        }
    }

    public func addAnnotation(_ annotation: Annotation) {
        annotations.append(annotation)
        let id = annotation.id
        recordHistoryIfNeeded(name: "Measurement", changed: true) { [weak self] in
            self?.annotations.removeAll { $0.id == id }
        } redo: { [weak self] in
            guard let self, !self.annotations.contains(where: { $0.id == id }) else { return }
            self.annotations.append(annotation)
        }
    }

    @discardableResult
    public func addSphericalSUVROI(at worldPoint: SIMD3<Double>,
                                   radiusMM: Double? = nil) -> SUVROIMeasurement? {
        guard let pet = activePETQuantificationVolume else {
            statusMessage = "No PET volume is available for SUV measurement"
            return nil
        }
        let radius = max(0.5, radiusMM ?? suvSphereRadiusMM)
        let voxel = pet.voxelIndex(from: worldPoint)
        let center = VoxelCoordinate(z: voxel.z, y: voxel.y, x: voxel.x)
        guard let measurement = SUVROICalculator.spherical(
            volume: pet,
            center: center,
            radiusMM: radius,
            suvTransform: { [settings = suvSettings, pet] raw in
                settings.suv(forStoredValue: raw, volume: pet)
            }
        ) else {
            statusMessage = "Could not measure spherical SUV ROI at that point"
            return nil
        }

        suvROIMeasurements.append(measurement)
        lastSUVROIMeasurement = measurement
        let id = measurement.id
        recordHistoryIfNeeded(name: "SUV sphere ROI", changed: true) { [weak self] in
            guard let self else { return }
            self.suvROIMeasurements.removeAll { $0.id == id }
            self.lastSUVROIMeasurement = self.suvROIMeasurements.last
        } redo: { [weak self] in
            guard let self, !self.suvROIMeasurements.contains(where: { $0.id == id }) else { return }
            self.suvROIMeasurements.append(measurement)
            self.lastSUVROIMeasurement = measurement
        }
        statusMessage = "SUV sphere ROI: \(measurement.compactSummary)"
        return measurement
    }

    public func clearSUVROIMeasurements() {
        let before = suvROIMeasurements
        let beforeLast = lastSUVROIMeasurement
        guard !before.isEmpty else {
            statusMessage = "No SUV ROI measurements to clear"
            return
        }
        suvROIMeasurements.removeAll()
        lastSUVROIMeasurement = nil
        recordHistoryIfNeeded(name: "Clear SUV ROIs", changed: true) { [weak self] in
            self?.suvROIMeasurements = before
            self?.lastSUVROIMeasurement = beforeLast
        } redo: { [weak self] in
            self?.suvROIMeasurements.removeAll()
            self?.lastSUVROIMeasurement = nil
        }
        statusMessage = "Cleared \(before.count) SUV ROI measurements"
    }

    public var dynamicCandidateVolumes: [ImageVolume] {
        DynamicStudyBuilder.dynamicCandidates(from: loadedVolumes)
    }

    @discardableResult
    public func buildDynamicStudyFromLoadedVolumes(frameDurationSeconds: Double = 1.0) -> Bool {
        guard let study = DynamicStudyBuilder.makeStudy(
            from: loadedVolumes,
            preferredReference: currentVolume,
            frameDurationSeconds: frameDurationSeconds
        ) else {
            statusMessage = "Dynamic workflow needs at least two PET/NM frames on the same grid"
            return false
        }

        stopDynamicPlayback()
        dynamicStudy = study
        selectedDynamicFrameIndex = 0
        dynamicTimeActivityCurve = []
        if let first = study.frame(at: 0) {
            showDynamicFrame(first, resetDisplay: true)
        }
        statusMessage = "Dynamic study ready: \(study.frameCount) frames over \(study.durationLabel)"
        return true
    }

    public func clearDynamicStudy() {
        stopDynamicPlayback()
        dynamicTACTask?.cancel()
        dynamicTACTask = nil
        dynamicStudy = nil
        selectedDynamicFrameIndex = 0
        dynamicTimeActivityCurve = []
        isDynamicTACComputing = false
        statusMessage = "Closed dynamic workflow"
    }

    public func setDynamicFrame(index: Int) {
        guard let study = dynamicStudy,
              let frame = study.frame(at: index) else { return }
        selectedDynamicFrameIndex = max(0, min(study.frameCount - 1, index))
        showDynamicFrame(frame, resetDisplay: false)
        statusMessage = "Dynamic frame \(selectedDynamicFrameIndex + 1)/\(study.frameCount) at \(DynamicFrame.formatTime(frame.midSeconds))"
    }

    public func stepDynamicFrame(delta: Int) {
        guard let study = dynamicStudy, study.frameCount > 0 else { return }
        let next = max(0, min(study.frameCount - 1, selectedDynamicFrameIndex + delta))
        setDynamicFrame(index: next)
    }

    public func toggleDynamicPlayback() {
        isDynamicPlaybackRunning ? stopDynamicPlayback() : startDynamicPlayback()
    }

    public func startDynamicPlayback() {
        guard let study = dynamicStudy, study.frameCount > 1 else {
            statusMessage = "Build a dynamic study before playback"
            return
        }
        stopDynamicPlayback()
        isDynamicPlaybackRunning = true
        dynamicPlaybackTask = Task { [weak self] in
            while !Task.isCancelled {
                let fps = await MainActor.run { self?.dynamicPlaybackFPS ?? 2.0 }
                let interval = UInt64(1_000_000_000 / max(0.25, min(30.0, fps)))
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          let study = self.dynamicStudy,
                          study.frameCount > 1 else {
                        return
                    }
                    let next = (self.selectedDynamicFrameIndex + 1) % study.frameCount
                    self.setDynamicFrame(index: next)
                }
            }
        }
    }

    public func stopDynamicPlayback() {
        dynamicPlaybackTask?.cancel()
        dynamicPlaybackTask = nil
        isDynamicPlaybackRunning = false
    }

    public func computeDynamicTimeActivityCurveForActiveLabel() {
        guard let study = dynamicStudy else {
            statusMessage = "Build a dynamic study before calculating a time-activity curve"
            return
        }
        guard let map = labeling.activeLabelMap else {
            statusMessage = "Create or load a label/ROI before calculating a time-activity curve"
            return
        }

        dynamicTACTask?.cancel()
        isDynamicTACComputing = true
        statusMessage = "Computing dynamic time-activity curve..."
        let labelVoxels = map.voxels
        let dimensions = (depth: map.depth, height: map.height, width: map.width)
        let classID = labeling.activeClassID
        let settings = suvSettings

        dynamicTACTask = Task { [weak self, study, labelVoxels, dimensions, classID, settings] in
            let points = await Task.detached(priority: .userInitiated) {
                DynamicTimeActivityCalculator.compute(
                    study: study,
                    labelVoxels: labelVoxels,
                    labelDimensions: dimensions,
                    classID: classID,
                    suvSettings: settings
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            self.dynamicTimeActivityCurve = points
            self.isDynamicTACComputing = false
            self.dynamicTACTask = nil
            self.statusMessage = points.isEmpty
                ? "No dynamic TAC points found for the active label"
                : "Dynamic TAC ready: \(points.count) frames"
        }
    }

    public func ensureActiveLabelMapForCurrentContext(defaultName: String = "Measurement Labels",
                                                      className: String = "Lesion",
                                                      category: LabelCategory = .lesion,
                                                      color: Color = .orange) {
        if labeling.activeLabelMap == nil {
            let source = fusion?.baseVolume ?? currentVolume ?? activePETQuantificationVolume
            if let source {
                let map = labeling.createLabelMap(for: source, name: defaultName)
                map.addClass(LabelClass(labelID: 1, name: className, category: category, color: color))
                labeling.activeClassID = 1
                map.objectWillChange.send()
            }
        } else if let map = labeling.activeLabelMap,
                  map.classInfo(id: labeling.activeClassID) == nil {
            map.addClass(LabelClass(labelID: labeling.activeClassID, name: className, category: category, color: color))
            map.objectWillChange.send()
        }
    }

    private func recordValueChange<T: Equatable>(
        name: String,
        before: T,
        after: T,
        apply: @escaping (ViewerViewModel, T) -> Void
    ) {
        recordHistoryIfNeeded(name: name, changed: before != after) { [weak self] in
            guard let self else { return }
            apply(self, before)
        } redo: { [weak self] in
            guard let self else { return }
            apply(self, after)
        }
    }

    private func recordHistoryIfNeeded(name: String,
                                       changed: Bool,
                                       undo: @escaping () -> Void,
                                       redo: @escaping () -> Void) {
        guard changed, !isReplayingAppHistory else { return }
        appUndoStack.append(AppHistoryRecord(name: name, undo: undo, redo: redo))
        if appUndoStack.count > maxAppHistoryRecords {
            appUndoStack.removeFirst(appUndoStack.count - maxAppHistoryRecords)
        }
        appRedoStack.removeAll()
        refreshAppHistoryDepths()
    }

    private func refreshAppHistoryDepths() {
        appUndoDepth = appUndoStack.count
        appRedoDepth = appRedoStack.count
    }

    private func applyPETOverlayWindow(window: Double, level: Double) {
        overlayWindow = window
        overlayLevel = level
        fusion?.overlayWindow = window
        fusion?.overlayLevel = level
        fusion?.objectWillChange.send()
    }

    private func applyViewportTransform(_ transform: ViewportTransformState, for paneKey: Int, linked: Bool) {
        if linked {
            sharedViewportTransform = transform
        } else {
            paneViewportTransforms[paneKey] = transform
        }
    }

    private func editableSnapshot() -> EditableSnapshot {
        EditableSnapshot(
            window: window,
            level: level,
            invertColors: invertColors,
            invertPETMIP: invertPETMIP,
            correctAnteriorPosteriorDisplay: correctAnteriorPosteriorDisplay,
            correctRightLeftDisplay: correctRightLeftDisplay,
            linkZoomPanAcrossPanes: linkZoomPanAcrossPanes,
            sharedViewportTransform: sharedViewportTransform,
            paneViewportTransforms: paneViewportTransforms,
            overlayOpacity: overlayOpacity,
            overlayColormap: overlayColormap,
            mipColormap: mipColormap,
            overlayWindow: overlayWindow,
            overlayLevel: overlayLevel,
            petMRRegistrationMode: petMRRegistrationMode,
            petMRDeformableRegistration: petMRDeformableRegistration,
            hangingGrid: hangingGrid,
            hangingPanes: hangingPanes,
            annotations: annotations,
            suvSphereRadiusMM: suvSphereRadiusMM,
            suvROIs: suvROIMeasurements,
            lastSUVROI: lastSUVROIMeasurement,
            labelVoxels: labeling.labelMaps.reduce(into: [:]) { voxelsByMapID, map in
                voxelsByMapID[map.id] = map.voxels
            }
        )
    }

    private func applyEditableSnapshot(_ snapshot: EditableSnapshot) {
        window = snapshot.window
        level = snapshot.level
        invertColors = snapshot.invertColors
        invertPETMIP = snapshot.invertPETMIP
        correctAnteriorPosteriorDisplay = snapshot.correctAnteriorPosteriorDisplay
        correctRightLeftDisplay = snapshot.correctRightLeftDisplay
        linkZoomPanAcrossPanes = snapshot.linkZoomPanAcrossPanes
        sharedViewportTransform = snapshot.sharedViewportTransform
        paneViewportTransforms = snapshot.paneViewportTransforms
        overlayOpacity = snapshot.overlayOpacity
        overlayColormap = snapshot.overlayColormap
        mipColormap = snapshot.mipColormap
        petMRRegistrationMode = snapshot.petMRRegistrationMode
        petMRDeformableRegistration = snapshot.petMRDeformableRegistration
        applyPETOverlayWindow(window: snapshot.overlayWindow, level: snapshot.overlayLevel)
        fusion?.opacity = snapshot.overlayOpacity
        fusion?.colormap = snapshot.overlayColormap
        fusion?.objectWillChange.send()
        applyHangingProtocol(grid: snapshot.hangingGrid, panes: snapshot.hangingPanes)
        annotations = snapshot.annotations
        suvSphereRadiusMM = snapshot.suvSphereRadiusMM
        suvROIMeasurements = snapshot.suvROIs
        lastSUVROIMeasurement = snapshot.lastSUVROI
        for map in labeling.labelMaps {
            if let voxels = snapshot.labelVoxels[map.id], voxels.count == map.voxels.count {
                map.voxels = voxels
                map.objectWillChange.send()
            }
        }
        labeling.markDirty()
    }

    // MARK: - Loading

    public func loadNIfTI(url: URL, autoFuse: Bool = true) async {
        let sourcePath = NIfTILoader.canonicalSourcePath(for: url)
        if let existing = loadedVolume(sourcePath: sourcePath) {
            displayVolume(existing)
            statusMessage = "Already loaded: \(existing.seriesDescription)"
            return
        }

        isLoading = true
        statusMessage = "Loading \(url.lastPathComponent)..."
        defer { isLoading = false }

        do {
            let volume = try await Task.detached(priority: .userInitiated) {
                try NIfTILoader.load(url)
            }.value

            let result = addLoadedVolumeIfNeeded(volume)
            displayVolume(result.volume)
            statusMessage = result.inserted
                ? "Loaded: \(volume.seriesDescription) | \(Modality.normalize(volume.modality).displayName) | \(volume.width)×\(volume.height)×\(volume.depth)"
                : "Already loaded: \(result.volume.seriesDescription)"
            if autoFuse, result.inserted, shouldAutoFusePETCT(afterLoading: result.volume) {
                await autoFusePETCT()
            } else if autoFuse, result.inserted, shouldAutoFusePETMR(afterLoading: result.volume) {
                await autoFusePETMR()
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    public func loadDICOMDirectory(url: URL) async {
        isLoading = true
        statusMessage = "Scanning \(url.lastPathComponent)..."
        defer { isLoading = false }

        let series = await Task.detached(priority: .userInitiated) {
            DICOMLoader.scanDirectory(url) { done, total in
                Task { @MainActor in
                    // Progress updates via main actor (omitted for brevity)
                }
            }
        }.value

        let merge = mergeScannedSeries(series)
        statusMessage = "Found \(series.count) series | added \(merge.added.count), updated \(merge.updated), skipped \(merge.skipped) duplicates"

        if let pair = bestPETCTSeriesPair(in: series) {
            await openSeries(pair.ct, autoFuse: false)
            await openSeries(pair.pet, autoFuse: false)
            let mrSeries = preferredMRDisplaySeries(in: series)
            for mr in mrSeries.prefix(6) {
                await openSeries(mr, autoFuse: false)
            }
            await autoFusePETCT()
            if mrSeries.isEmpty {
                applyHangingProtocol(grid: .defaultPETCT, panes: HangingPaneConfiguration.defaultPETCT)
            } else {
                applyHangingProtocol(grid: HangingGridLayout(columns: 4, rows: 2),
                                     panes: HangingPaneConfiguration.defaultUnified)
            }
            statusMessage = mrSeries.isEmpty
                ? "Opened PET/CT study: \(pair.ct.displayName) + \(pair.pet.displayName)"
                : "Opened unified CT/MR/PET study: \(pair.ct.displayName) + \(pair.pet.displayName) + \(min(6, mrSeries.count)) MR"
            return
        }

        if let pair = bestPETMRSeriesPair(in: series) {
            let mrSeries = preferredMRDisplaySeries(in: series)
            for mr in mrSeries.prefix(6) {
                await openSeries(mr, autoFuse: false)
            }
            await openSeries(pair.pet, autoFuse: false)
            await autoFusePETMR()
            statusMessage = "Opened PET/MR study: \(pair.mr.displayName) + \(pair.pet.displayName)"
            return
        }

        let mrDisplaySeries = preferredMRDisplaySeries(in: series)
        if mrDisplaySeries.count >= 2 {
            for mr in mrDisplaySeries.prefix(6) {
                await openSeries(mr, autoFuse: false)
            }
            if let primary = loadedMRVolumes.sorted(by: mrDisplaySort).first {
                displayVolume(primary)
            }
            resetMRIHangingProtocol()
            statusMessage = "Opened MRI study with \(min(6, mrDisplaySeries.count)) linked sequences"
            return
        }

        // Open the first new series automatically; if everything was already
        // known, select the existing match instead of loading a duplicate.
        if let first = merge.added.first ?? series.first.flatMap({ loadedSeriesMatch(for: $0) }) {
            await openSeries(first)
        }
    }

    public func openSeries(_ series: DICOMSeries, autoFuse: Bool = true) async {
        if let existing = loadedVolume(seriesUID: series.uid) {
            displayVolume(existing)
            statusMessage = "Already loaded: \(series.displayName)"
            return
        }

        isLoading = true
        statusMessage = "Loading \(series.displayName)..."
        defer { isLoading = false }

        do {
            let volume = try await Task.detached(priority: .userInitiated) {
                try DICOMLoader.loadSeries(series.files)
            }.value

            let result = addLoadedVolumeIfNeeded(volume)
            displayVolume(result.volume)
            statusMessage = result.inserted
                ? "Loaded: \(volume.seriesDescription) | \(Modality.normalize(volume.modality).displayName) | \(volume.width)×\(volume.height)×\(volume.depth)"
                : "Already loaded: \(series.displayName)"

            if autoFuse, result.inserted, shouldAutoFusePETCT(afterLoading: result.volume) {
                await autoFusePETCT()
                applyHangingProtocol(grid: .defaultPETCT, panes: HangingPaneConfiguration.defaultPETCT)
                statusMessage = "Loaded and fused PET/CT: \(result.volume.seriesDescription.isEmpty ? series.displayName : result.volume.seriesDescription)"
            } else if autoFuse, result.inserted, shouldAutoFusePETMR(afterLoading: result.volume) {
                await autoFusePETMR()
                statusMessage = "Loaded and fused PET/MR: \(result.volume.seriesDescription.isEmpty ? series.displayName : result.volume.seriesDescription)"
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    public func indexDirectory(url: URL, modelContext: ModelContext) async {
        indexCancellation.reset()
        isLoading = true
        isIndexing = true
        progress = 0
        indexProgress = nil
        statusMessage = "Indexing \(url.lastPathComponent)..."
        defer {
            isLoading = false
            isIndexing = false
            progress = 0
            indexProgress = nil
        }

        let progressHandler: @Sendable (PACSIndexScanProgress) -> Void = { [weak self] update in
            Task { @MainActor in
                self?.indexProgress = update
                self?.statusMessage = update.statusText
            }
        }

        let cancellation = indexCancellation
        let isCancelled: @Sendable () -> Bool = { cancellation.isCancelled }

        let scanResult = await Task.detached(priority: .userInitiated) {
            PACSDirectoryIndexer.scan(url: url,
                                      progressStride: 5_000,
                                      isCancelled: isCancelled,
                                      progress: progressHandler)
        }.value

        if scanResult.cancelled {
            statusMessage = "Indexing cancelled after \(scanResult.scannedFiles) files (\(scanResult.records.count) partial series discarded)"
            return
        }

        let records = uniqueIndexSnapshots(scanResult.records)

        do {
            var inserted = 0
            var updated = 0
            var offset = 0
            let batchSize = 250

            while offset < records.count {
                if indexCancellation.isCancelled {
                    try? modelContext.save()
                    statusMessage = "Indexing cancelled at \(offset)/\(records.count) series (inserted \(inserted), updated \(updated))"
                    return
                }
                let end = min(records.count, offset + batchSize)
                for snapshot in records[offset..<end] {
                    switch try upsertIndexedSeries(snapshot, in: modelContext) {
                    case .inserted: inserted += 1
                    case .updated: updated += 1
                    }
                }
                try modelContext.save()
                offset = end
                statusMessage = "Indexed \(offset)/\(records.count) series | inserted \(inserted), updated \(updated)"
                await Task.yield()
            }
            indexRevision += 1
            statusMessage = "Indexed \(records.count) series from \(scanResult.scannedFiles) files | inserted \(inserted), updated \(updated), skipped \(scanResult.skippedFiles)"
        } catch {
            statusMessage = "Index error: \(error.localizedDescription)"
        }
    }

    /// Request cancellation of the in-flight `indexDirectory(...)` scan.
    /// Safe to call from any thread. No-op when no scan is running.
    public func cancelIndexing() {
        indexCancellation.cancel()
    }

    public func openIndexedSeries(_ entry: PACSIndexedSeriesSnapshot, autoFuse: Bool = true) async {
        switch entry.kind {
        case .dicom:
            await openIndexedDICOMSeries(entry, autoFuse: autoFuse)
        case .nifti:
            let path = entry.filePaths.first ?? entry.sourcePath
            await loadNIfTI(url: URL(fileURLWithPath: path), autoFuse: autoFuse)
        }
    }

    public func openWorklistStudy(_ study: PACSWorklistStudy) async {
        let anatomical = study.preferredAnatomicalSeriesForPETCT
        let pet = study.preferredPETSeriesForPETCT

        if let anatomical, let pet {
            let anatomicalModality = Modality.normalize(anatomical.modality)
            if anatomicalModality == .MR {
                for mr in preferredMRDisplaySeries(in: study.series).prefix(6) {
                    await openIndexedSeries(mr, autoFuse: false)
                }
            } else {
                await openIndexedSeries(anatomical, autoFuse: false)
                for mr in preferredMRDisplaySeries(in: study.series).prefix(6) {
                    await openIndexedSeries(mr, autoFuse: false)
                }
            }
            await openIndexedSeries(pet, autoFuse: false)
            if anatomicalModality == .MR {
                await autoFusePETMR()
            } else {
                await autoFusePETCT()
                if !preferredMRDisplaySeries(in: study.series).isEmpty {
                    applyHangingProtocol(grid: HangingGridLayout(columns: 4, rows: 2),
                                         panes: HangingPaneConfiguration.defaultUnified)
                }
            }
            let hasMRSeries = !preferredMRDisplaySeries(in: study.series).isEmpty
            let label = anatomicalModality == .MR
                ? "PET/MR"
                : (hasMRSeries ? "unified CT/MR/PET" : "PET/CT")
            statusMessage = "Opened \(label) study: \(study.patientName.isEmpty ? study.patientID : study.patientName)"
            return
        }

        let mrDisplaySeries = preferredMRDisplaySeries(in: study.series)
        if mrDisplaySeries.count >= 2 {
            for mr in mrDisplaySeries.prefix(6) {
                await openIndexedSeries(mr, autoFuse: false)
            }
            if let primary = loadedMRVolumes.sorted(by: mrDisplaySort).first {
                displayVolume(primary)
            }
            resetMRIHangingProtocol()
            statusMessage = "Opened MRI study: \(study.patientName.isEmpty ? study.patientID : study.patientName)"
            return
        }

        guard let first = study.series.first else {
            statusMessage = "Worklist study has no series"
            return
        }
        await openIndexedSeries(first)
        statusMessage = "Opened study: \(study.patientName.isEmpty ? study.patientID : study.patientName)"
    }

    public func loadOverlay(url: URL) async {
        let sourcePath = NIfTILoader.canonicalSourcePath(for: url)
        if let fusion,
           fusion.overlayVolume.sourceFiles.contains(sourcePath) {
            statusMessage = "Overlay already loaded: \(fusion.overlayVolume.seriesDescription)"
            return
        }

        isLoading = true
        statusMessage = "Loading overlay..."
        defer { isLoading = false }

        do {
            let overlay = try await Task.detached(priority: .userInitiated) {
                try NIfTILoader.load(url)
            }.value

            guard let base = currentVolume else {
                statusMessage = "Load a base volume first"
                return
            }

            let resampled = try await resampledOverlayIfNeeded(base: base, overlay: overlay)
            let pair = configureFusion(base: base, overlay: overlay, resampledOverlay: resampled)
            statusMessage = "Fusion loaded: \(pair.fusionTypeLabel)"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    public func autoFusePETCT() async {
        guard let pair = bestPETCTPair() else {
            statusMessage = "Load at least one CT and one PET volume first"
            return
        }
        await fusePETCT(base: pair.ct, overlay: pair.pet)
    }

    public func autoFusePETMR() async {
        guard let pair = bestPETMRPair() else {
            statusMessage = "Load at least one MR and one PET volume first"
            return
        }
        await fusePETMR(base: pair.mr, overlay: pair.pet)
    }

    public func fusePETCT(base: ImageVolume, overlay: ImageVolume) async {
        isLoading = true
        statusMessage = "Fusing PET/CT..."
        defer { isLoading = false }

        let ct = Modality.normalize(base.modality) == .CT ? base : overlay
        let pet = Modality.normalize(base.modality) == .PT ? base : overlay

        guard Modality.normalize(ct.modality) == .CT,
              Modality.normalize(pet.modality) == .PT else {
            statusMessage = "PET/CT fusion needs one CT volume and one PET volume"
            return
        }

        do {
            let resampled = try await resampledOverlayIfNeeded(base: ct, overlay: pet)
            configureFusion(base: ct, overlay: pet, resampledOverlay: resampled)
            statusMessage = "PET/CT fused: PET resampled into CT grid"
        } catch {
            statusMessage = "PET/CT fusion error: \(error.localizedDescription)"
        }
    }

    public func fusePETMR(base: ImageVolume, overlay: ImageVolume) async {
        isLoading = true
        statusMessage = "Fusing PET/MR..."
        defer { isLoading = false }

        let mr = Modality.normalize(base.modality) == .MR ? base : overlay
        let pet = Modality.normalize(base.modality) == .PT ? base : overlay

        guard Modality.normalize(mr.modality) == .MR,
              Modality.normalize(pet.modality) == .PT else {
            statusMessage = "PET/MR fusion needs one MR volume and one PET volume"
            return
        }

        let mode = petMRRegistrationMode
        let alreadyAligned = hasMatchingGrid(mr, pet)
        let registrationModeForInitializer: PETMRRegistrationMode = mode == .geometry ? .geometry : .rigidAnatomical
        let registration = PETMRRegistrationEngine.estimatePETToMR(
            pet: pet,
            mr: mr,
            mode: alreadyAligned ? .geometry : registrationModeForInitializer
        )

        var resampled: ImageVolume?
        var registrationNote = registration.note
        var qualityBefore: RegistrationQualitySnapshot?
        var deformationQuality: DeformationFieldQuality?
        if alreadyAligned {
            resampled = nil
            qualityBefore = RegistrationQualityAssurance.evaluate(
                fixed: mr,
                movingOnFixedGrid: pet,
                label: "Scanner geometry"
            )
        } else if mode == .rigidThenDeformable,
                  petMRDeformableRegistration.isExternalConfigured {
            let prealigned = await Task.detached(priority: .userInitiated) {
                VolumeResampler.resample(source: pet,
                                         target: mr,
                                         transform: registration.fixedToMoving,
                                         mode: .linear)
            }.value
            qualityBefore = RegistrationQualityAssurance.evaluate(
                fixed: mr,
                movingOnFixedGrid: prealigned,
                label: "Rigid prealignment"
            )
            do {
                statusMessage = "Running \(petMRDeformableRegistration.backend.displayName) PET/MR deformable registration..."
                let deformable = try await PETMRDeformableRegistrationRunner.register(
                    fixed: mr,
                    movingPrealigned: prealigned,
                    configuration: petMRDeformableRegistration
                )
                resampled = deformable.warpedMoving
                deformationQuality = deformable.deformationQuality
                registrationNote = "\(registration.note). \(deformable.note)"
            } catch {
                resampled = prealigned
                registrationNote = "\(registration.note). External deformable registration failed; using rigid prealignment. \(error.localizedDescription)"
            }
        } else if mode == .rigidThenDeformable {
            let prealigned = await Task.detached(priority: .userInitiated) {
                VolumeResampler.resample(source: pet,
                                         target: mr,
                                         transform: registration.fixedToMoving,
                                         mode: .linear)
            }.value
            qualityBefore = RegistrationQualityAssurance.evaluate(
                fixed: mr,
                movingOnFixedGrid: prealigned,
                label: "Rigid prealignment"
            )
            let deformable = PETMRRegistrationEngine.estimatePETToMR(
                pet: pet,
                mr: mr,
                mode: .rigidThenDeformable
            )
            resampled = await Task.detached(priority: .userInitiated) {
                VolumeResampler.resample(source: pet,
                                         target: mr,
                                         transform: deformable.fixedToMoving,
                                         mode: .linear)
            }.value
            registrationNote = "\(deformable.note). Configure ANTs/SynthMorph/VoxelMorph for dense deformable refinement."
        } else {
            resampled = await Task.detached(priority: .userInitiated) {
                VolumeResampler.resample(source: pet,
                                         target: mr,
                                         transform: registration.fixedToMoving,
                                         mode: .linear)
            }.value
            if let resampled {
                qualityBefore = RegistrationQualityAssurance.evaluate(
                    fixed: mr,
                    movingOnFixedGrid: resampled,
                    label: registrationModeForInitializer.displayName
                )
            }
        }

        let pair = configureFusion(base: mr, overlay: pet, resampledOverlay: resampled)
        pair.registrationNote = registrationNote
        let qaMoving = resampled ?? pet
        let qualityAfter = RegistrationQualityAssurance.evaluate(
            fixed: mr,
            movingOnFixedGrid: qaMoving,
            label: "Fusion result"
        )
        pair.registrationQuality = RegistrationQualityAssurance.compare(
            before: qualityBefore ?? qualityAfter,
            after: qualityAfter,
            deformation: deformationQuality
        )
        pair.objectWillChange.send()
        applyHangingProtocol(grid: .threeByTwo, panes: HangingPaneConfiguration.defaultPETMR)
        let qaLabel = pair.registrationQuality?.grade.displayName ?? RegistrationQualityGrade.unknown.displayName
        statusMessage = "PET/MR fused: \(registrationNote). QA \(qaLabel)"
    }

    private func openIndexedDICOMSeries(_ entry: PACSIndexedSeriesSnapshot,
                                        autoFuse: Bool = true) async {
        isLoading = true
        statusMessage = "Loading \(entry.displayName)..."
        defer { isLoading = false }

        do {
            let series = try await Task.detached(priority: .userInitiated) {
                let files = try entry.filePaths.map {
                    try DICOMLoader.parseHeader(at: URL(fileURLWithPath: $0))
                }
                guard !files.isEmpty else {
                    throw DICOMError.invalidFile("Indexed series has no files")
                }
                return DICOMSeries(
                    uid: entry.seriesUID,
                    modality: entry.modality,
                    description: entry.seriesDescription,
                    patientID: entry.patientID,
                    patientName: entry.patientName,
                    studyUID: entry.studyUID,
                    studyDescription: entry.studyDescription,
                    studyDate: entry.studyDate,
                    files: files
                )
            }.value

            await openSeries(series, autoFuse: autoFuse)
        } catch {
            statusMessage = "Mini-PACS load error: \(error.localizedDescription)"
        }
    }

    private enum IndexUpsertResult {
        case inserted
        case updated
    }

    private func upsertIndexedSeries(_ snapshot: PACSIndexedSeriesSnapshot,
                                     in modelContext: ModelContext) throws -> IndexUpsertResult {
        let id = snapshot.id
        var descriptor = FetchDescriptor<PACSIndexedSeries>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: snapshot)
            return .updated
        } else {
            modelContext.insert(PACSIndexedSeries(snapshot: snapshot))
            return .inserted
        }
    }

    public func removeOverlay() {
        fusion = nil
        statusMessage = "Overlay removed"
    }

    @discardableResult
    public func mergeScannedSeries(_ series: [DICOMSeries]) -> (added: [DICOMSeries], updated: Int, skipped: Int) {
        var added: [DICOMSeries] = []
        var updated = 0
        var skipped = 0

        for incoming in series {
            guard !incoming.uid.isEmpty else {
                skipped += 1
                continue
            }

            if let existingIndex = loadedSeries.firstIndex(where: { $0.uid == incoming.uid }) {
                let existingKeys = Set(loadedSeries[existingIndex].files.map(dicomFileIdentity))
                let newFiles = incoming.files.filter {
                    !existingKeys.contains(dicomFileIdentity($0))
                }
                if newFiles.isEmpty {
                    skipped += 1
                } else {
                    loadedSeries[existingIndex].files.append(contentsOf: newFiles)
                    updated += 1
                }
            } else {
                loadedSeries.append(incoming)
                added.append(incoming)
            }
        }

        return (added, updated, skipped)
    }

    @discardableResult
    public func addLoadedVolumeIfNeeded(_ volume: ImageVolume) -> (volume: ImageVolume, inserted: Bool) {
        if let existing = loadedVolume(matching: volume) {
            // Even re-openings bump the recent-list timestamp so the chip
            // stays at the head of the strip.
            recordRecent(volume: existing)
            return (existing, false)
        }
        loadedVolumes.append(volume)
        recordRecent(volume: volume)
        return (volume, true)
    }

    /// Install an attenuation-corrected PET produced by `PETACViewModel` —
    /// adds it to the loaded-volumes list (so it shows up in the volume
    /// switcher), makes it the current displayed volume if the NAC was
    /// active, and re-fuses with the existing CT base if there was a
    /// NAC/CT fusion in flight. The original NAC stays loaded so the user
    /// can flip back for comparison.
    public func installCorrectedPET(_ acVolume: ImageVolume,
                                    replacingNAC nacVolume: ImageVolume) {
        let result = addLoadedVolumeIfNeeded(acVolume)
        let installed = result.volume
        // If the NAC was the active overlay of a fusion pair, swap in the
        // AC volume on the same base so the user keeps their layout. The
        // base CT (or whatever the anatomical base was) is preserved.
        if let pair = fusion,
           pair.overlayVolume.id == nacVolume.id {
            Task { await fusePETCT(base: pair.baseVolume, overlay: installed) }
        }
        // If the NAC was the primary displayed volume, swap to AC.
        if currentVolume?.id == nacVolume.id {
            displayVolume(installed)
        }
        statusMessage = "AC PET installed: \(installed.seriesDescription)"
    }

    // MARK: - Recent volumes

    private func recordRecent(volume: ImageVolume) {
        guard !volume.sourceFiles.isEmpty else { return }
        recentVolumes = recentVolumesStore.recordOpen(RecentVolume(from: volume))
    }

    /// Refresh the published strip from persistence. Settings and other
    /// windows can mutate the shared store outside this view model.
    public func reloadRecentVolumes() {
        recentVolumes = recentVolumesStore.load()
    }

    /// Drop a recent entry (e.g. after the user clicks the × chip).
    public func removeRecent(id: String) {
        recentVolumes = recentVolumesStore.remove(id: id)
    }

    /// Re-open a volume from its `RecentVolume` bookmark. Picks the right
    /// loader based on `kind` and the file extensions, and if the session
    /// already holds that volume just re-displays it without re-loading.
    public func reopenRecent(_ recent: RecentVolume) async {
        // Already loaded in this session?
        if let already = loadedVolumes.first(where: { $0.sessionIdentity == recent.id }) {
            displayVolume(already)
            statusMessage = "Already loaded: \(recent.seriesDescription)"
            recordRecent(volume: already)
            return
        }
        guard let firstPath = recent.sourceFiles.first else {
            statusMessage = "Recent entry has no source files."
            return
        }
        switch recent.kind {
        case .nifti:
            await loadNIfTI(url: URL(fileURLWithPath: firstPath))
        case .dicom:
            // Use the parent directory to trigger a fresh DICOM scan —
            // cheapest way to rebuild the volume without caching pixel data
            // between sessions.
            let parent = (firstPath as NSString).deletingLastPathComponent
            await loadDICOMDirectory(url: URL(fileURLWithPath: parent))
        }
    }

    private func loadedVolume(matching volume: ImageVolume) -> ImageVolume? {
        loadedVolumes.first { candidate in
            if !volume.seriesUID.isEmpty, candidate.seriesUID == volume.seriesUID {
                return true
            }
            if !volume.sourceFiles.isEmpty,
               !Set(candidate.sourceFiles).isDisjoint(with: volume.sourceFiles) {
                return true
            }
            return candidate.sessionIdentity == volume.sessionIdentity
        }
    }

    private func loadedVolume(seriesUID: String) -> ImageVolume? {
        guard !seriesUID.isEmpty else { return nil }
        return loadedVolumes.first { $0.seriesUID == seriesUID }
    }

    private func loadedVolume(sourcePath: String) -> ImageVolume? {
        let canonical = ImageVolume.canonicalPath(sourcePath)
        return loadedVolumes.first { volume in
            volume.sourceFiles.contains(canonical) ||
            volume.seriesUID == "nifti:\(canonical)"
        }
    }

    private func loadedSeriesMatch(for series: DICOMSeries) -> DICOMSeries? {
        loadedSeries.first { $0.uid == series.uid }
    }

    private func bestPETCTSeriesPair(in series: [DICOMSeries]) -> (ct: DICOMSeries, pet: DICOMSeries)? {
        let ctSeries = series
            .filter { Modality.normalize($0.modality) == .CT }
            .sorted { $0.instanceCount > $1.instanceCount }
        let petSeries = series
            .filter { Modality.normalize($0.modality) == .PT }
            .sorted { $0.instanceCount > $1.instanceCount }
        guard !ctSeries.isEmpty, !petSeries.isEmpty else { return nil }

        var best: (ct: DICOMSeries, pet: DICOMSeries, score: Int)?
        for ct in ctSeries {
            for pet in petSeries {
                var score = min(ct.instanceCount, pet.instanceCount)
                if !ct.studyUID.isEmpty, ct.studyUID == pet.studyUID { score += 10_000 }
                if !ct.patientID.isEmpty, ct.patientID == pet.patientID { score += 1_000 }
                if !ct.patientName.isEmpty, ct.patientName == pet.patientName { score += 250 }
                if !ct.accessionNumber.isEmpty, ct.accessionNumber == pet.accessionNumber { score += 250 }
                if best == nil || score > best!.score {
                    best = (ct, pet, score)
                }
            }
        }
        return best.map { ($0.ct, $0.pet) }
    }

    private func bestPETMRSeriesPair(in series: [DICOMSeries]) -> (mr: DICOMSeries, pet: DICOMSeries)? {
        let mrSeries = preferredMRDisplaySeries(in: series)
        let petSeries = series
            .filter { Modality.normalize($0.modality) == .PT }
            .sorted { $0.instanceCount > $1.instanceCount }
        guard !mrSeries.isEmpty, !petSeries.isEmpty else { return nil }

        var best: (mr: DICOMSeries, pet: DICOMSeries, score: Int)?
        for mr in mrSeries {
            for pet in petSeries {
                var score = min(mr.instanceCount, pet.instanceCount)
                if !mr.studyUID.isEmpty, mr.studyUID == pet.studyUID { score += 10_000 }
                if !mr.patientID.isEmpty, mr.patientID == pet.patientID { score += 1_000 }
                if !mr.patientName.isEmpty, mr.patientName == pet.patientName { score += 250 }
                if !mr.accessionNumber.isEmpty, mr.accessionNumber == pet.accessionNumber { score += 250 }
                score += mrSequencePreferenceScore(description: mr.description, modality: mr.modality)
                if best == nil || score > best!.score {
                    best = (mr, pet, score)
                }
            }
        }
        return best.map { ($0.mr, $0.pet) }
    }

    private func preferredMRDisplaySeries(in series: [DICOMSeries]) -> [DICOMSeries] {
        series
            .filter { Modality.normalize($0.modality) == .MR }
            .sorted { lhs, rhs in
                let lhsScore = mrSequencePreferenceScore(description: lhs.description, modality: lhs.modality)
                let rhsScore = mrSequencePreferenceScore(description: rhs.description, modality: rhs.modality)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if lhs.instanceCount != rhs.instanceCount { return lhs.instanceCount > rhs.instanceCount }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func preferredMRDisplaySeries(in series: [PACSIndexedSeriesSnapshot]) -> [PACSIndexedSeriesSnapshot] {
        series
            .filter { Modality.normalize($0.modality) == .MR }
            .sorted { lhs, rhs in
                let lhsScore = mrSequencePreferenceScore(description: lhs.seriesDescription, modality: lhs.modality)
                let rhsScore = mrSequencePreferenceScore(description: rhs.seriesDescription, modality: rhs.modality)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if lhs.instanceCount != rhs.instanceCount { return lhs.instanceCount > rhs.instanceCount }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func mrSequencePreferenceScore(description: String, modality: String) -> Int {
        let roles: [MRSequenceRole] = [.t1, .t2, .flair, .dwi, .adc, .postContrast, .other]
        guard let role = roles.max(by: {
            $0.score(seriesDescription: description, modality: modality) <
                $1.score(seriesDescription: description, modality: modality)
        }) else { return 0 }
        let roleScore = role.score(seriesDescription: description, modality: modality)
        return roleScore + (100 - mrRoleSortRank(role))
    }

    private func shouldAutoFusePETCT(afterLoading volume: ImageVolume) -> Bool {
        let modality = Modality.normalize(volume.modality)
        guard modality == .CT || modality == .PT else { return false }
        guard !loadedCTVolumes.isEmpty, !loadedPETVolumes.isEmpty else { return false }
        if let fusion {
            return fusion.baseVolume.id != volume.id && fusion.overlayVolume.id != volume.id
        }
        return true
    }

    private func shouldAutoFusePETMR(afterLoading volume: ImageVolume) -> Bool {
        let modality = Modality.normalize(volume.modality)
        guard modality == .MR || modality == .PT else { return false }
        guard loadedCTVolumes.isEmpty else { return false }
        guard !loadedMRVolumes.isEmpty, !loadedPETVolumes.isEmpty else { return false }
        if let fusion {
            return fusion.baseVolume.id != volume.id && fusion.overlayVolume.id != volume.id
        }
        return true
    }

    private func uniqueIndexSnapshots(_ records: [PACSIndexedSeriesSnapshot]) -> [PACSIndexedSeriesSnapshot] {
        var seen = Set<String>()
        var unique: [PACSIndexedSeriesSnapshot] = []
        for record in records where seen.insert(record.id).inserted {
            unique.append(record)
        }
        return unique
    }

    private func dicomFileIdentity(_ file: DICOMFile) -> String {
        if !file.sopInstanceUID.isEmpty {
            return "sop:\(file.sopInstanceUID)"
        }
        return "path:\(ImageVolume.canonicalPath(file.filePath))"
    }

    @discardableResult
    private func configureFusion(base: ImageVolume,
                                 overlay: ImageVolume,
                                 resampledOverlay: ImageVolume?) -> FusionPair {
        displayVolume(base)
        if Modality.normalize(base.modality) == .CT,
           let softTissue = WLPresets.CT.first(where: { $0.name == "Soft Tissue" }) {
            window = softTissue.window
            level = softTissue.level
        }

        let pair = FusionPair(base: base, overlay: overlay)
        pair.resampledOverlay = resampledOverlay
        pair.isGeometryResampled = resampledOverlay != nil
        pair.registrationNote = resampledOverlay == nil
            ? "Overlay already matches base grid"
            : "Overlay resampled into base world geometry"
        applyFusionDisplayDefaults(for: overlay, pair: pair)
        fusion = pair
        return pair
    }

    private func applyFusionDisplayDefaults(for overlay: ImageVolume, pair: FusionPair) {
        if Modality.normalize(overlay.modality) == .PT {
            overlayOpacity = 0.55
            overlayColormap = .tracerPET
            if overlay.suvScaleFactor != nil {
                suvSettings.mode = .manualScale
                suvSettings.manualScaleFactor = overlay.suvScaleFactor ?? 1
            }

            let range = petSUVDisplayRange(for: pair.displayedOverlay)
            let maxValue = range.max
            if maxValue.isFinite, maxValue > 0, maxValue <= 25 {
                let upper = min(15, max(10, maxValue))
                applyPETOverlayWindow(window: upper, level: upper / 2)
            } else if maxValue.isFinite, maxValue > 0 {
                let upper = max(1, maxValue * 0.85)
                applyPETOverlayWindow(window: upper, level: upper / 2)
            } else {
                applyPETOverlayWindow(window: 10, level: 5)
            }
        }

        pair.opacity = overlayOpacity
        pair.colormap = overlayColormap
        pair.overlayWindow = overlayWindow
        pair.overlayLevel = overlayLevel
    }

    private func resampledOverlayIfNeeded(base: ImageVolume,
                                          overlay: ImageVolume) async throws -> ImageVolume? {
        guard !hasMatchingGrid(base, overlay) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            VolumeResampler.resample(overlay: overlay, toMatch: base, mode: .linear)
        }.value
    }

    private func hasMatchingGrid(_ base: ImageVolume, _ overlay: ImageVolume) -> Bool {
        ImageVolumeGeometry.gridsMatch(base, overlay)
    }

    private func bestPETCTPair() -> (ct: ImageVolume, pet: ImageVolume)? {
        let cts = loadedCTVolumes
        let pets = loadedPETVolumes
        guard !cts.isEmpty, !pets.isEmpty else { return nil }

        if let current = currentVolume {
            let currentModality = Modality.normalize(current.modality)
            if currentModality == .CT,
               let pet = pets.max(by: { fusionScore(ct: current, pet: $0) < fusionScore(ct: current, pet: $1) }) {
                return (current, pet)
            }
            if currentModality == .PT,
               let ct = cts.max(by: { fusionScore(ct: $0, pet: current) < fusionScore(ct: $1, pet: current) }) {
                return (ct, current)
            }
        }

        var best: (ct: ImageVolume, pet: ImageVolume, score: Int)?
        for ct in cts {
            for pet in pets {
                let score = fusionScore(ct: ct, pet: pet)
                if best == nil || score > best!.score {
                    best = (ct, pet, score)
                }
            }
        }
        guard let best else { return nil }
        return (best.ct, best.pet)
    }

    private func bestPETMRPair() -> (mr: ImageVolume, pet: ImageVolume)? {
        let mrs = loadedMRVolumes.sorted(by: mrDisplaySort)
        let pets = loadedPETVolumes
        guard !mrs.isEmpty, !pets.isEmpty else { return nil }

        if let current = currentVolume {
            let currentModality = Modality.normalize(current.modality)
            if currentModality == .MR,
               let pet = pets.max(by: { fusionScore(mr: current, pet: $0) < fusionScore(mr: current, pet: $1) }) {
                return (current, pet)
            }
            if currentModality == .PT,
               let mr = mrs.max(by: { fusionScore(mr: $0, pet: current) < fusionScore(mr: $1, pet: current) }) {
                return (mr, current)
            }
        }

        var best: (mr: ImageVolume, pet: ImageVolume, score: Int)?
        for mr in mrs {
            for pet in pets {
                let score = fusionScore(mr: mr, pet: pet)
                if best == nil || score > best!.score {
                    best = (mr, pet, score)
                }
            }
        }
        guard let best else { return nil }
        return (best.mr, best.pet)
    }

    public func preferredMRVolume(for role: MRSequenceRole) -> ImageVolume? {
        let mrs = loadedMRVolumes
        guard !mrs.isEmpty else { return nil }

        if role == .other {
            return mrs.first { MRSequenceRole.role(for: $0) == .other } ?? mrs.first
        }

        if let exact = mrs.max(by: { role.score(volume: $0) < role.score(volume: $1) }),
           role.score(volume: exact) > 0 {
            return exact
        }

        // MR protocols should stay populated even when series names are
        // vendor-specific or sparse. Fall back to a deterministic sequence
        // rank rather than leaving panes blank.
        let ordered = mrs.sorted(by: mrDisplaySort)
        let index: Int
        switch role {
        case .t1: index = 0
        case .t2: index = min(1, ordered.count - 1)
        case .flair: index = min(2, ordered.count - 1)
        case .dwi: index = min(3, ordered.count - 1)
        case .adc: index = min(4, ordered.count - 1)
        case .postContrast: index = min(5, ordered.count - 1)
        case .other: index = 0
        }
        return ordered[index]
    }

    private func mrDisplaySort(_ lhs: ImageVolume, _ rhs: ImageVolume) -> Bool {
        let lhsRole = MRSequenceRole.role(for: lhs)
        let rhsRole = MRSequenceRole.role(for: rhs)
        let lhsRank = mrRoleSortRank(lhsRole)
        let rhsRank = mrRoleSortRank(rhsRole)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.seriesDescription.localizedStandardCompare(rhs.seriesDescription) == .orderedAscending
    }

    private func mrRoleSortRank(_ role: MRSequenceRole) -> Int {
        switch role {
        case .t1: return 0
        case .t2: return 1
        case .flair: return 2
        case .dwi: return 3
        case .adc: return 4
        case .postContrast: return 5
        case .other: return 10
        }
    }

    private func fusionScore(ct: ImageVolume, pet: ImageVolume) -> Int {
        var score = 0
        if !ct.studyUID.isEmpty, ct.studyUID == pet.studyUID { score += 8 }
        if !ct.patientID.isEmpty, ct.patientID == pet.patientID { score += 4 }
        if !ct.patientName.isEmpty, ct.patientName == pet.patientName { score += 2 }
        if abs(ct.origin.x - pet.origin.x) < 50,
           abs(ct.origin.y - pet.origin.y) < 50,
           abs(ct.origin.z - pet.origin.z) < 50 {
            score += 1
        }
        return score
    }

    private func fusionScore(mr: ImageVolume, pet: ImageVolume) -> Int {
        var score = 0
        if !mr.studyUID.isEmpty, mr.studyUID == pet.studyUID { score += 8 }
        if !mr.patientID.isEmpty, mr.patientID == pet.patientID { score += 4 }
        if !mr.patientName.isEmpty, mr.patientName == pet.patientName { score += 2 }
        let role = MRSequenceRole.role(for: mr)
        switch role {
        case .t1: score += 4
        case .t2, .flair: score += 3
        case .postContrast: score += 2
        default: score += 1
        }
        if abs(mr.origin.x - pet.origin.x) < 75,
           abs(mr.origin.y - pet.origin.y) < 75,
           abs(mr.origin.z - pet.origin.z) < 75 {
            score += 1
        }
        return score
    }

    // MARK: - Volume display

    public func displayVolume(_ volume: ImageVolume) {
        autoWindowTask?.cancel()
        autoWindowTask = nil
        currentVolume = volume
        sliceIndices = [volume.width / 2, volume.height / 2, volume.depth / 2]
        let center = volume.worldPoint(voxel: SIMD3<Double>(
            Double(sliceIndices[0]),
            Double(sliceIndices[1]),
            Double(sliceIndices[2])
        ))
        labeling.crosshair.world = WorldPoint(x: center.x, y: center.y, z: center.z)

        // Auto window/level
        let (w, l) = autoWindowLevel(pixels: volume.pixels)
        window = w
        level = l
    }

    private func showDynamicFrame(_ frame: DynamicFrame, resetDisplay: Bool) {
        if resetDisplay || currentVolume == nil {
            displayVolume(frame.volume)
        } else {
            currentVolume = frame.volume
            clampSliceIndices(to: frame.volume)
        }
    }

    private func clampSliceIndices(to volume: ImageVolume) {
        guard sliceIndices.count >= 3 else {
            sliceIndices = [volume.width / 2, volume.height / 2, volume.depth / 2]
            return
        }
        sliceIndices[0] = max(0, min(volume.width - 1, sliceIndices[0]))
        sliceIndices[1] = max(0, min(volume.height - 1, sliceIndices[1]))
        sliceIndices[2] = max(0, min(volume.depth - 1, sliceIndices[2]))
    }

    // MARK: - Slice navigation

    public func scroll(axis: Int, delta: Int) {
        guard let v = currentVolume, delta != 0 else { return }
        let max: Int
        switch axis {
        case 0: max = v.width - 1
        case 1: max = v.height - 1
        default: max = v.depth - 1
        }
        sliceIndices[axis] = Swift.max(0, Swift.min(max, sliceIndices[axis] + delta))
        syncCrosshairToCurrentSliceIndices()
    }

    public func scroll(axis: Int, delta: Int, mode: SliceDisplayMode) {
        guard delta != 0,
              let v = volumeForDisplayMode(mode) ?? currentVolume else { return }
        let max: Int
        switch axis {
        case 0: max = v.width - 1
        case 1: max = v.height - 1
        default: max = v.depth - 1
        }
        let current = displayedSliceIndex(axis: axis, volume: v)
        setSlice(axis: axis, index: Swift.max(0, Swift.min(max, current + delta)), mode: mode)
    }

    public func scrollAllSlices(delta: Int) {
        guard let v = currentVolume, delta != 0 else { return }
        let maxima = [v.width - 1, v.height - 1, v.depth - 1]
        for axis in 0..<3 {
            sliceIndices[axis] = Swift.max(0, Swift.min(maxima[axis], sliceIndices[axis] + delta))
        }
    }

    public func setSlice(axis: Int, index: Int) {
        guard let v = currentVolume else { return }
        let max: Int
        switch axis {
        case 0: max = v.width - 1
        case 1: max = v.height - 1
        default: max = v.depth - 1
        }
        sliceIndices[axis] = Swift.max(0, Swift.min(max, index))
        syncCrosshairToCurrentSliceIndices()
    }

    public func setSlice(axis: Int, index: Int, mode: SliceDisplayMode) {
        guard let v = volumeForDisplayMode(mode) ?? currentVolume else { return }
        let max: Int
        switch axis {
        case 0: max = v.width - 1
        case 1: max = v.height - 1
        default: max = v.depth - 1
        }
        let clampedIndex = Swift.max(0, Swift.min(max, index))
        let currentWorld = SIMD3<Double>(
            labeling.crosshair.world.x,
            labeling.crosshair.world.y,
            labeling.crosshair.world.z
        )
        var voxel = v.voxelCoordinates(from: currentWorld)
        switch axis {
        case 0: voxel.x = Double(clampedIndex)
        case 1: voxel.y = Double(clampedIndex)
        default: voxel.z = Double(clampedIndex)
        }
        let world = v.worldPoint(voxel: voxel)
        labeling.crosshair.world = WorldPoint(x: world.x, y: world.y, z: world.z)

        if let currentVolume {
            let currentVoxel = currentVolume.voxelIndex(from: world)
            sliceIndices = [currentVoxel.x, currentVoxel.y, currentVoxel.z]
        } else {
            switch axis {
            case 0: sliceIndices[0] = clampedIndex
            case 1: sliceIndices[1] = clampedIndex
            default: sliceIndices[2] = clampedIndex
            }
        }
    }

    public func displayedSliceIndex(axis: Int, mode: SliceDisplayMode) -> Int {
        guard let volume = volumeForDisplayMode(mode) ?? currentVolume else {
            return sliceIndices.indices.contains(axis) ? sliceIndices[axis] : 0
        }
        return displayedSliceIndex(axis: axis, volume: volume)
    }

    public func displayedSliceIndices(for volume: ImageVolume) -> (sag: Int, cor: Int, ax: Int) {
        if labeling.crosshair.enabled {
            return labeling.crosshair.sliceIndices(for: labeling.crosshair.world, in: volume)
        }
        return (
            sag: Swift.max(0, Swift.min(volume.width - 1, sliceIndices[0])),
            cor: Swift.max(0, Swift.min(volume.height - 1, sliceIndices[1])),
            ax: Swift.max(0, Swift.min(volume.depth - 1, sliceIndices[2]))
        )
    }

    public func centerSlices(on world: SIMD3<Double>) {
        labeling.crosshair.world = WorldPoint(x: world.x, y: world.y, z: world.z)
        if let currentVolume {
            let voxel = currentVolume.voxelIndex(from: world)
            sliceIndices = [voxel.x, voxel.y, voxel.z]
        }
    }

    private func syncCrosshairToCurrentSliceIndices() {
        guard let currentVolume, sliceIndices.count >= 3 else { return }
        let world = currentVolume.worldPoint(voxel: SIMD3<Double>(
            Double(sliceIndices[0]),
            Double(sliceIndices[1]),
            Double(sliceIndices[2])
        ))
        labeling.crosshair.world = WorldPoint(x: world.x, y: world.y, z: world.z)
    }

    private func displayedSliceIndex(axis: Int, volume: ImageVolume) -> Int {
        let indices = displayedSliceIndices(for: volume)
        switch axis {
        case 0: return indices.sag
        case 1: return indices.cor
        default: return indices.ax
        }
    }

    public func displayTransform(for axis: Int, volume: ImageVolume? = nil) -> SliceDisplayTransform {
        guard let volume = volume ?? currentVolume else { return .identity }
        var transform = SliceDisplayTransform.canonical(axis: axis, volume: volume)
        if correctAnteriorPosteriorDisplay {
            transform = patientAxisCorrected(transform, axis: axis, volume: volume, letters: ["A", "P"])
        }
        if correctRightLeftDisplay {
            transform = patientAxisCorrected(transform, axis: axis, volume: volume, letters: ["R", "L"])
        }
        return transform
    }

    public func displayAxes(for axis: Int, volume: ImageVolume? = nil) -> (right: SIMD3<Double>, down: SIMD3<Double>)? {
        guard let volume = volume ?? currentVolume else { return nil }
        return SliceDisplayTransform.displayAxes(
            axis: axis,
            volume: volume,
            transform: displayTransform(for: axis, volume: volume)
        )
    }

    private func patientAxisCorrected(
        _ transform: SliceDisplayTransform,
        axis: Int,
        volume: ImageVolume,
        letters: Set<String>
    ) -> SliceDisplayTransform {
        let axes = SliceDisplayTransform.displayAxes(axis: axis, volume: volume, transform: transform)
        var adjusted = transform
        if isPatientAxis(axes.right, letters: letters) {
            adjusted = SliceDisplayTransform(
                flipHorizontal: !adjusted.flipHorizontal,
                flipVertical: adjusted.flipVertical
            )
        }
        if isPatientAxis(axes.down, letters: letters) {
            adjusted = SliceDisplayTransform(
                flipHorizontal: adjusted.flipHorizontal,
                flipVertical: !adjusted.flipVertical
            )
        }
        return adjusted
    }

    private func isPatientAxis(_ vector: SIMD3<Double>, letters: Set<String>) -> Bool {
        let letter = SliceDisplayTransform.patientLetter(for: vector)
        return letters.contains(letter)
    }

    // MARK: - W/L manipulation

    public func adjustWindowLevel(dw: Double, dl: Double) {
        window = max(1, window + dw)
        level += dl
    }

    public func applyPreset(_ preset: WindowLevel) {
        let before = (window, level)
        window = preset.window
        level = preset.level
        recordWindowLevelChange(before: before, after: (window, level), name: "\(preset.name) W/L")
    }

    public func setWindow(_ value: Double) {
        let before = (window, level)
        window = max(1, value)
        recordWindowLevelChange(before: before, after: (window, level), name: "Window")
    }

    public func setLevel(_ value: Double) {
        let before = (window, level)
        level = value
        recordWindowLevelChange(before: before, after: (window, level), name: "Level")
    }

    /// Look up a preset by name across the current modality's list first,
    /// falling back to the union of CT + MR + PT presets. Useful for global
    /// keyboard shortcuts that should "just work" regardless of the loaded
    /// modality. Returns a status message describing what happened.
    ///
    /// Normalizes the input so callers don't have to: whitespace is trimmed
    /// and matches are case-insensitive (`"  lung  "` == `"Lung"`). An empty
    /// or whitespace-only name is rejected with a clear status message
    /// rather than silently matching the first preset.
    @discardableResult
    public func applyPresetNamed(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "W/L preset name was empty."
            return statusMessage
        }

        let modality = currentVolume.map { Modality.normalize($0.modality) } ?? .CT
        let modalityPresets = WLPresets.presets(for: modality)
        if let match = modalityPresets.first(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            applyPreset(match)
            statusMessage = "Applied \(match.name) W/L (\(modality.displayName))"
            return statusMessage
        }
        let union = WLPresets.CT + WLPresets.MR + WLPresets.PT
        if let match = union.first(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            applyPreset(match)
            statusMessage = "Applied \(match.name) W/L"
            return statusMessage
        }
        statusMessage = "No \(trimmed) preset available for this modality."
        return statusMessage
    }

    public func autoWL() {
        autoWLHistogram(preset: .balanced)
    }

    /// Histogram-driven W/L picker, inspired by ITK-SNAP's auto-contrast.
    /// `preset` maps to a percentile clip range (see `HistogramAutoWindow.Preset`).
    public func autoWLHistogram(preset: HistogramAutoWindow.Preset = .balanced) {
        guard let v = currentVolume else { return }
        autoWindowTask?.cancel()
        let before = (window, level)
        let volumeID = v.id
        let ignoreZeros = Modality.normalize(v.modality) == .PT
        statusMessage = "Computing auto W/L… viewer remains responsive"

        autoWindowTask = Task { [weak self, v, before, volumeID, preset, ignoreZeros] in
            let result = await Task.detached(priority: .userInitiated) {
                HistogramAutoWindow.compute(
                    v,
                    preset: preset,
                    ignoreZeros: ignoreZeros
                )
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.currentVolume?.id == volumeID else { return }
            self.window = result.window
            self.level = result.level
            self.recordWindowLevelChange(before: before,
                                         after: (self.window, self.level),
                                         name: "Auto W/L")
            self.statusMessage = String(format: "Auto W/L: W=%.0f L=%.0f (%.0f–%.0f)",
                                        result.window, result.level,
                                        result.lowerValue, result.upperValue)
            self.autoWindowTask = nil
        }
    }

    /// Synchronous variant kept for tests and command paths that explicitly
    /// need a blocking result. UI surfaces should call `autoWLHistogram`.
    public func computeAutoWLHistogramNow(preset: HistogramAutoWindow.Preset = .balanced) {
        guard let v = currentVolume else { return }
        let before = (window, level)
        let ignoreZeros = Modality.normalize(v.modality) == .PT
        let result = HistogramAutoWindow.compute(v,
                                                  preset: preset,
                                                  ignoreZeros: ignoreZeros)
        window = result.window
        level = result.level
        recordWindowLevelChange(before: before, after: (window, level), name: "Auto W/L")
        statusMessage = String(format: "Auto W/L: W=%.0f L=%.0f (%.0f–%.0f)",
                               result.window, result.level,
                               result.lowerValue, result.upperValue)
    }

    public func suvValue(rawStoredValue: Double) -> Double {
        if let vol = activePETQuantificationVolume {
            return suvSettings.suv(forStoredValue: rawStoredValue, volume: vol)
        }
        return suvSettings.suv(forStoredValue: rawStoredValue)
    }

    /// Volume-aware SUV lookup. Callers that already have a specific PET
    /// volume in hand (e.g. the PET Engine staging an auxiliary channel for
    /// nnU-Net inference) should use this — it honours the per-volume DICOM
    /// SUV scale factor when the user has `.storedSUV` selected, which the
    /// plain `suvValue(rawStoredValue:)` can't do for any volume other than
    /// the currently-active one.
    public func suvValue(rawStoredValue: Double, volume: ImageVolume) -> Double {
        suvSettings.suv(forStoredValue: rawStoredValue, volume: volume)
    }

    public func activePETProbe() -> SUVProbe? {
        guard let pet = activePETQuantificationVolume else { return nil }
        let z = min(max(sliceIndices[2], 0), pet.depth - 1)
        let y = min(max(sliceIndices[1], 0), pet.height - 1)
        let x = min(max(sliceIndices[0], 0), pet.width - 1)
        return suvProbe(z: z, y: y, x: x, in: pet)
    }

    public func suvProbe(z: Int, y: Int, x: Int, in volume: ImageVolume? = nil) -> SUVProbe? {
        let pet = volume ?? activePETQuantificationVolume
        guard let pet else { return nil }
        guard z >= 0, z < pet.depth, y >= 0, y < pet.height, x >= 0, x < pet.width else {
            return nil
        }
        let raw = Double(pet.intensity(z: z, y: y, x: x))
        return SUVProbe(
            voxel: (z: z, y: y, x: x),
            rawValue: raw,
            suv: suvValue(rawStoredValue: raw, volume: pet)
        )
    }

    public func activePETRegionStats(for labelMap: LabelMap,
                                     classID: UInt16) -> RegionStats? {
        guard let pet = activePETVolumeMatching(labelMap) else {
            return nil
        }
        return RegionStats.compute(
            pet,
            labelMap,
            classID: classID,
            suvTransform: suvTransform(for: pet)
        )
    }

    public func startThresholdActiveLabel(atOrAbove threshold: Double) {
        labeling.thresholdValue = threshold
        runBackgroundLabelOperation(
            .petThreshold(threshold: threshold),
            defaultName: "PET/CT Volumes",
            className: "Lesion",
            category: .lesion,
            color: .orange
        )
    }

    public func startPercentOfMaxActiveLabelWholeVolume(percent: Double) {
        labeling.percentOfMax = percent
        runBackgroundLabelOperation(
            .petPercentOfMax(percent: percent),
            defaultName: "PET/CT Volumes",
            className: "Lesion",
            category: .lesion,
            color: .orange
        )
    }

    public func startPercentOfMaxActiveLabelAroundSeed(seed: (z: Int, y: Int, x: Int),
                                                       boxRadius: Int = 30,
                                                       percent: Double) {
        labeling.percentOfMax = percent
        runBackgroundLabelOperation(
            .petSeededPercentOfMax(seed: seed, boxRadius: boxRadius, percent: percent),
            defaultName: "PET/CT Volumes",
            className: "Lesion",
            category: .lesion,
            color: .orange
        )
    }

    public func startGradientActiveLabelAroundSeed(seed: (z: Int, y: Int, x: Int),
                                                   minimumValue: Double,
                                                   gradientCutoffFraction: Double,
                                                   searchRadius: Int) {
        labeling.thresholdValue = minimumValue
        labeling.gradientCutoffFraction = gradientCutoffFraction
        labeling.gradientSearchRadius = searchRadius
        runBackgroundLabelOperation(
            .petGradient(seed: seed,
                         minimumValue: minimumValue,
                         gradientCutoffFraction: gradientCutoffFraction,
                         searchRadius: searchRadius),
            defaultName: "PET/CT Volumes",
            className: "Lesion",
            category: .lesion,
            color: .orange
        )
    }

    public func startRegionGrowActiveLabelAroundSeed(seed: (z: Int, y: Int, x: Int),
                                                     tolerance: Double,
                                                     preferredVolume: ImageVolume? = nil) {
        runBackgroundLabelOperation(
            .regionGrow(seed: seed, tolerance: tolerance),
            defaultName: "PET/CT Volumes",
            className: "Region",
            category: .lesion,
            color: .yellow,
            preferredVolume: preferredVolume
        )
    }

    public func startThresholdActiveCTLabel(lowerHU: Double, upperHU: Double) {
        runBackgroundLabelOperation(
            .ctRange(lower: lowerHU, upper: upperHU),
            defaultName: "CT Volumes",
            className: "CT Volume",
            category: .organ,
            color: .cyan,
            forceCT: true
        )
    }

    public func startActiveVolumeMeasurement(method: VolumeMeasurementMethod = .activeLabel,
                                             thresholdSummary: String = "Active label",
                                             preferPET: Bool = true) {
        guard !isVolumeOperationRunning else {
            statusMessage = "Volume operation already running. Cancel it before starting another label-volume job."
            return
        }
        guard let map = labeling.activeLabelMap else {
            lastVolumeMeasurementReport = nil
            statusMessage = "No active label map to measure"
            return
        }
        guard let source = activeMeasurementSource(matching: map, preferPET: preferPET) else {
            lastVolumeMeasurementReport = nil
            statusMessage = "No matching volume grid for the active label map"
            return
        }

        let operationID = UUID()
        let title = source.source == .petSUV ? "Measure SUV metrics" : "Measure volume"
        volumeOperationStatus = VolumeOperationStatus(
            id: operationID,
            title: title,
            detail: thresholdSummary,
            startedAt: Date()
        )
        statusMessage = "Running \(title)… viewer remains responsive"

        let input = VolumeMeasurementInput(
            mapID: map.id,
            mapName: map.name,
            classes: map.classes,
            voxels: map.voxels,
            volume: source.volume,
            classID: labeling.activeClassID,
            source: source.source,
            method: method,
            thresholdSummary: thresholdSummary,
            suvSettings: suvSettings
        )

        volumeOperationTask = Task { [weak self, input, operationID] in
            let report = await Task.detached(priority: .userInitiated) {
                VolumeOperationWorker.measure(input)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.volumeOperationStatus?.id == operationID else { return }
            self.lastVolumeMeasurementReport = report
            self.statusMessage = self.measurementStatus(report)
            self.volumeOperationStatus = nil
            self.volumeOperationTask = nil
        }
    }

    public func thresholdActiveLabel(atOrAbove threshold: Double) {
        ensureActiveLabelMapForCurrentContext(defaultName: "PET/CT Volumes", className: "Lesion", category: .lesion, color: .orange)
        guard let map = labeling.activeLabelMap else { return }
        guard let source = activeSegmentationSource(matching: map) else {
            statusMessage = "No current image or PET overlay matches the active label map grid"
            return
        }

        labeling.thresholdValue = threshold
        let transform: ((Double) -> Double)? = source.usesSUV ? suvTransform(for: source.volume) : nil
        let beforeUndoDepth = labeling.undoDepth
        var count = 0
        labeling.recordVoxelEdit(named: "SUV threshold") {
            count = PETSegmentation.thresholdAbove(
                volume: source.volume,
                label: map,
                threshold: threshold,
                classID: labeling.activeClassID,
                valueTransform: transform
            )
        }
        map.objectWillChange.send()

        let unit = source.usesSUV ? "SUV" : "intensity"
        statusMessage = "Segmented \(count) voxels at \(unit) >= \(String(format: "%.2f", threshold))"
        recordLabelEditIfChanged(named: "Fixed \(unit) threshold", beforeUndoDepth: beforeUndoDepth)
        refreshActiveVolumeMeasurement(
            method: .fixedThreshold,
            thresholdSummary: "\(unit) >= \(String(format: "%.2f", threshold))",
            preferPET: source.usesSUV
        )
    }

    public func percentOfMaxActiveLabelWholeVolume(percent: Double) {
        ensureActiveLabelMapForCurrentContext(defaultName: "PET/CT Volumes", className: "Lesion", category: .lesion, color: .orange)
        guard let map = labeling.activeLabelMap else { return }
        guard let source = activeSegmentationSource(matching: map) else {
            statusMessage = "No current image or PET overlay matches the active label map grid"
            return
        }

        labeling.percentOfMax = percent
        let transform: ((Double) -> Double)? = source.usesSUV ? suvTransform(for: source.volume) : nil
        let box = VoxelBox.all(in: source.volume)
        let beforeUndoDepth = labeling.undoDepth
        var count = 0
        labeling.recordVoxelEdit(named: "Percent of max") {
            count = PETSegmentation.percentOfMax(
                volume: source.volume,
                label: map,
                percent: percent,
                classID: labeling.activeClassID,
                boundingBox: box,
                valueTransform: transform
            )
        }
        map.objectWillChange.send()

        let unit = source.usesSUV ? "SUVmax" : "intensity max"
        statusMessage = "Segmented \(count) voxels at \(Int(percent * 100))% of \(unit)"
        recordLabelEditIfChanged(named: "Percent of max volume", beforeUndoDepth: beforeUndoDepth)
        refreshActiveVolumeMeasurement(
            method: .percentOfMax,
            thresholdSummary: "\(Int(percent * 100))% of \(unit)",
            preferPET: source.usesSUV
        )
    }

    public func percentOfMaxActiveLabelAroundSeed(seed: (z: Int, y: Int, x: Int),
                                                  boxRadius: Int = 30,
                                                  percent: Double) {
        ensureActiveLabelMapForCurrentContext(defaultName: "PET/CT Volumes", className: "Lesion", category: .lesion, color: .orange)
        guard let map = labeling.activeLabelMap else { return }
        guard let source = activeSegmentationSource(matching: map) else {
            statusMessage = "No current image or PET overlay matches the active label map grid"
            return
        }

        labeling.percentOfMax = percent
        let transform: ((Double) -> Double)? = source.usesSUV ? suvTransform(for: source.volume) : nil
        let box = VoxelBox.around(seed, radius: boxRadius, in: source.volume)
        let beforeUndoDepth = labeling.undoDepth
        var count = 0
        labeling.recordVoxelEdit(named: "SUV percent of max") {
            count = PETSegmentation.percentOfMax(
                volume: source.volume,
                label: map,
                percent: percent,
                classID: labeling.activeClassID,
                boundingBox: box,
                valueTransform: transform
            )
        }
        map.objectWillChange.send()

        let unit = source.usesSUV ? "SUVmax" : "intensity max"
        statusMessage = "Segmented \(count) voxels at \(Int(percent * 100))% of \(unit)"
        recordLabelEditIfChanged(named: "Seeded percent of max", beforeUndoDepth: beforeUndoDepth)
        refreshActiveVolumeMeasurement(
            method: .percentOfMax,
            thresholdSummary: "\(Int(percent * 100))% of local \(unit)",
            preferPET: source.usesSUV
        )
    }

    public func gradientActiveLabelAroundSeed(seed: (z: Int, y: Int, x: Int),
                                              minimumValue: Double,
                                              gradientCutoffFraction: Double,
                                              searchRadius: Int) {
        ensureActiveLabelMapForCurrentContext(defaultName: "PET/CT Volumes", className: "Lesion", category: .lesion, color: .orange)
        guard let map = labeling.activeLabelMap else { return }
        guard let source = activeSegmentationSource(matching: map) else {
            statusMessage = "No current image or PET overlay matches the active label map grid"
            return
        }

        labeling.thresholdValue = minimumValue
        labeling.gradientCutoffFraction = gradientCutoffFraction
        labeling.gradientSearchRadius = searchRadius
        let transform: ((Double) -> Double)? = source.usesSUV ? suvTransform(for: source.volume) : nil
        let beforeUndoDepth = labeling.undoDepth
        let result = labeling.gradientEdge(
            volume: source.volume,
            seed: seed,
            minimumValue: minimumValue,
            gradientCutoffFraction: gradientCutoffFraction,
            searchRadius: searchRadius,
            valueTransform: transform
        )

        let unit = source.usesSUV ? "SUV" : "intensity"
        statusMessage = "SUV gradient segmented \(result.voxelCount) voxels | floor \(unit) \(String(format: "%.2f", minimumValue)), peak \(String(format: "%.2f", result.maxValue)), edge \(String(format: "%.3f", result.gradientCutoff))/mm"
        recordLabelEditIfChanged(named: "SUV gradient edge", beforeUndoDepth: beforeUndoDepth)
        refreshActiveVolumeMeasurement(
            method: .gradientEdge,
            thresholdSummary: "Gradient edge, floor \(unit) \(String(format: "%.2f", minimumValue))",
            preferPET: source.usesSUV
        )
    }

    public func thresholdActiveCTLabel(lowerHU: Double, upperHU: Double) {
        ensureActiveLabelMapForCurrentContext(defaultName: "CT Volumes", className: "CT Volume", category: .organ, color: .cyan)
        guard let map = labeling.activeLabelMap else { return }
        guard let ct = activeCTVolumeMatching(map) else {
            statusMessage = "No CT volume matches the active label map grid"
            return
        }

        let lower = min(lowerHU, upperHU)
        let upper = max(lowerHU, upperHU)
        let beforeUndoDepth = labeling.undoDepth
        var count = 0
        labeling.recordVoxelEdit(named: "CT HU range") {
            count = PETSegmentation.thresholdRange(
                volume: ct,
                label: map,
                lower: lower,
                upper: upper,
                classID: labeling.activeClassID
            )
        }
        map.objectWillChange.send()
        statusMessage = "Segmented \(count) CT voxels from \(Int(lower)) to \(Int(upper)) HU"
        recordLabelEditIfChanged(named: "CT HU volume", beforeUndoDepth: beforeUndoDepth)
        refreshActiveVolumeMeasurement(
            method: .huRange,
            thresholdSummary: "\(Int(lower))...\(Int(upper)) HU",
            preferPET: false
        )
    }

    @discardableResult
    public func refreshActiveVolumeMeasurement(method: VolumeMeasurementMethod = .activeLabel,
                                               thresholdSummary: String = "Active label",
                                               preferPET: Bool = true) -> VolumeMeasurementReport? {
        guard let map = labeling.activeLabelMap else {
            lastVolumeMeasurementReport = nil
            return nil
        }
        guard let source = activeMeasurementSource(matching: map, preferPET: preferPET) else {
            lastVolumeMeasurementReport = nil
            return nil
        }
        let transform = source.source == .petSUV ? suvTransform(for: source.volume) : nil
        let report = VolumeMeasurementReport.compute(
            volume: source.volume,
            labelMap: map,
            classID: labeling.activeClassID,
            source: source.source,
            method: method,
            thresholdSummary: thresholdSummary,
            valueTransform: transform
        )
        lastVolumeMeasurementReport = report
        return report
    }

    private func runBackgroundLabelOperation(_ operation: VolumeLabelOperation,
                                             defaultName: String,
                                             className: String,
                                             category: LabelCategory,
                                             color: Color,
                                             forceCT: Bool = false,
                                             preferredVolume: ImageVolume? = nil) {
        guard !isVolumeOperationRunning else {
            statusMessage = "Volume operation already running. Cancel it before starting another label-volume job."
            return
        }

        ensureActiveLabelMapForCurrentContext(
            defaultName: defaultName,
            className: className,
            category: category,
            color: color
        )
        guard let map = labeling.activeLabelMap else { return }

        let source: (volume: ImageVolume, usesSUV: Bool)?
        if let preferredVolume, sameGrid(preferredVolume, map) {
            source = (preferredVolume, Modality.normalize(preferredVolume.modality) == .PT)
        } else if forceCT {
            source = activeCTVolumeMatching(map).map { ($0, false) }
        } else {
            source = activeSegmentationSource(matching: map)
        }
        guard let source else {
            statusMessage = forceCT
                ? "No CT volume matches the active label map grid"
                : "No current image or PET overlay matches the active label map grid"
            return
        }

        let operationID = UUID()
        volumeOperationStatus = VolumeOperationStatus(
            id: operationID,
            title: operation.title,
            detail: operation.thresholdSummary,
            startedAt: Date()
        )
        statusMessage = "Running \(operation.title)… viewer remains responsive"

        let input = VolumeLabelOperationInput(
            mapID: map.id,
            mapName: map.name,
            classes: map.classes,
            startingVoxels: map.voxels,
            volume: source.volume,
            classID: labeling.activeClassID,
            usesSUV: source.usesSUV,
            suvSettings: suvSettings,
            operation: operation,
            diffLimit: maxBackgroundTrackedChangedVoxels
        )

        volumeOperationTask = Task { [weak self, input, operationID] in
            let result = await Task.detached(priority: .userInitiated) {
                VolumeOperationWorker.runLabelOperation(input)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.volumeOperationStatus?.id == operationID else { return }
            self.finishBackgroundLabelOperation(result)
        }
    }

    private func finishBackgroundLabelOperation(_ result: VolumeLabelOperationOutput) {
        let changed = labeling.applyVoxelReplacement(
            mapID: result.mapID,
            voxels: result.voxels,
            diff: result.diff,
            name: result.operation.title
        )
        lastVolumeMeasurementReport = result.report

        if changed && !result.diff.overflowed {
            recordHistoryIfNeeded(name: result.operation.title, changed: true) { [weak self] in
                self?.labeling.undo()
                self?.startActiveVolumeMeasurement(
                    method: result.operation.method,
                    thresholdSummary: result.operation.thresholdSummary,
                    preferPET: result.report.source == .petSUV
                )
            } redo: { [weak self] in
                self?.labeling.redo()
                self?.startActiveVolumeMeasurement(
                    method: result.operation.method,
                    thresholdSummary: result.operation.thresholdSummary,
                    preferPET: result.report.source == .petSUV
                )
            }
        }

        var message: String
        switch result.operation {
        case .petThreshold:
            message = "Segmented \(result.voxelCount) voxels at \(result.operation.thresholdSummary)"
        case .petPercentOfMax, .petSeededPercentOfMax:
            message = "Segmented \(result.voxelCount) voxels at \(result.operation.thresholdSummary)"
        case .petGradient:
            if let gradient = result.gradient {
                message = "SUV gradient segmented \(gradient.voxelCount) voxels | peak \(String(format: "%.2f", gradient.maxValue)), edge \(String(format: "%.3f", gradient.gradientCutoff))/mm"
            } else {
                message = "SUV gradient finished"
            }
        case .regionGrow:
            message = "Region grow segmented \(result.voxelCount) voxels"
        case .ctRange:
            message = "Segmented \(result.voxelCount) CT voxels from \(result.operation.thresholdSummary)"
        }
        if result.diff.overflowed {
            message += " (undo history skipped: very large edit)"
        }
        if !changed && result.voxelCount == 0 {
            message = "No voxels matched \(result.operation.thresholdSummary)"
        }
        statusMessage = message
        volumeOperationStatus = nil
        volumeOperationTask = nil
    }

    private func measurementStatus(_ report: VolumeMeasurementReport) -> String {
        if report.source == .petSUV {
            let suvMax = report.suvMax.map { String(format: " SUVmax %.2f", $0) } ?? ""
            let suvMean = report.suvMean.map { String(format: " SUVmean %.2f", $0) } ?? ""
            return String(format: "Measured %@: %.2f mL%@%@",
                          report.className,
                          report.volumeML,
                          suvMax,
                          suvMean)
        }
        return String(format: "Measured %@: %.2f mL", report.className, report.volumeML)
    }

    private func suvTransform(for volume: ImageVolume) -> (Double) -> Double {
        { [suvSettings, volume] rawValue in
            suvSettings.suv(forStoredValue: rawValue, volume: volume)
        }
    }

    private func activePETVolumeMatching(_ labelMap: LabelMap) -> ImageVolume? {
        if let fusion, sameGrid(fusion.displayedOverlay, labelMap) {
            return fusion.displayedOverlay
        }
        if let currentVolume,
           Modality.normalize(currentVolume.modality) == .PT,
           sameGrid(currentVolume, labelMap) {
            return currentVolume
        }
        return nil
    }

    private func activeCTVolumeMatching(_ labelMap: LabelMap) -> ImageVolume? {
        if let fusion,
           Modality.normalize(fusion.baseVolume.modality) == .CT,
           sameGrid(fusion.baseVolume, labelMap) {
            return fusion.baseVolume
        }
        if let currentVolume,
           Modality.normalize(currentVolume.modality) == .CT,
           sameGrid(currentVolume, labelMap) {
            return currentVolume
        }
        return loadedCTVolumes.first { sameGrid($0, labelMap) }
    }

    private func activeMeasurementSource(
        matching labelMap: LabelMap,
        preferPET: Bool
    ) -> (volume: ImageVolume, source: VolumeMeasurementSource)? {
        if preferPET, let pet = activePETVolumeMatching(labelMap) {
            return (pet, .petSUV)
        }
        if let ct = activeCTVolumeMatching(labelMap) {
            return (ct, .ctHU)
        }
        if let pet = activePETVolumeMatching(labelMap) {
            return (pet, .petSUV)
        }
        if let currentVolume, sameGrid(currentVolume, labelMap) {
            let normalized = Modality.normalize(currentVolume.modality)
            if normalized == .PT { return (currentVolume, .petSUV) }
            if normalized == .CT { return (currentVolume, .ctHU) }
            return (currentVolume, .intensity)
        }
        return loadedVolumes.first(where: { sameGrid($0, labelMap) }).map { volume in
            let normalized = Modality.normalize(volume.modality)
            let source: VolumeMeasurementSource = normalized == .PT
                ? .petSUV
                : (normalized == .CT ? .ctHU : .intensity)
            return (volume, source)
        }
    }

    private func activeSegmentationSource(matching labelMap: LabelMap) -> (volume: ImageVolume, usesSUV: Bool)? {
        if let pet = activePETVolumeMatching(labelMap) {
            return (pet, true)
        }
        if let currentVolume, sameGrid(currentVolume, labelMap) {
            return (currentVolume, Modality.normalize(currentVolume.modality) == .PT)
        }
        return nil
    }

    private func sameGrid(_ volume: ImageVolume, _ labelMap: LabelMap) -> Bool {
        volume.width == labelMap.width &&
        volume.height == labelMap.height &&
        volume.depth == labelMap.depth
    }

    // MARK: - Slice images

    public func clearSliceRenderCache() {
        sliceRenderCache.removeAll(keepingCapacity: true)
        sliceRenderCacheOrder.removeAll(keepingCapacity: true)
        sliceRenderCacheHitCount = 0
        sliceRenderCacheMissCount = 0
    }

    public func makeImage(for axis: Int, mode: SliceDisplayMode = .fused) -> CGImage? {
        guard sliceIndices.indices.contains(axis) else { return nil }
        guard let v = volumeForDisplayMode(mode) else { return nil }
        let index = sliceIndex(axis: axis, volume: v)
        let dimensions = sliceDimensions(axis: axis, volume: v)
        let transform = displayTransform(for: axis, volume: v)
        let renderPETColor = mode == .petOnly && Modality.normalize(v.modality) == .PT
        let key = SliceRenderCacheKey(
            layer: .base,
            sourceVolumeID: v.id,
            referenceVolumeID: v.id,
            labelMapID: nil,
            labelRevision: 0,
            axis: axis,
            sliceIndex: index,
            mode: mode.rawValue,
            width: dimensions.width,
            height: dimensions.height,
            depth: v.depth,
            window: renderKey(renderPETColor ? overlayWindow : window),
            level: renderKey(renderPETColor ? overlayLevel : level),
            invert: renderPETColor ? false : invertColors,
            colormap: renderPETColor ? overlayColormap.rawValue : "gray",
            opacity: renderKey(1),
            flipHorizontal: transform.flipHorizontal,
            flipVertical: transform.flipVertical,
            suvSignature: renderPETColor ? suvRenderSignature(for: v) : "none"
        )

        return cachedSliceImage(for: key) {
            let slice = v.slice(axis: axis, index: index)
            var pixels = slice.pixels
            let w = slice.width, h = slice.height

            pixels = SliceTransform.apply(pixels, width: w, height: h,
                                          transform: transform)

            if renderPETColor {
                pixels = petDisplayPixels(pixels, volume: v)
                return PixelRenderer.makeColorImage(
                    pixels: pixels, width: w, height: h,
                    window: overlayWindow, level: overlayLevel,
                    colormap: overlayColormap,
                    baseAlpha: 1.0
                )
            }

            return PixelRenderer.makeGrayImage(
                pixels: pixels, width: w, height: h,
                window: window, level: level, invert: invertColors
            )
        }
    }

    public func makeLabelImage(for axis: Int,
                               mode: SliceDisplayMode = .fused,
                               outlineOnly: Bool = false) -> CGImage? {
        guard sliceIndices.indices.contains(axis) else { return nil }
        guard let map = labeling.activeLabelMap else { return nil }
        guard map.visible else { return nil }
        let displayVolume = volumeForDisplayMode(mode) ?? currentVolume
        let index = sliceIndex(axis: axis, labelMap: map)
        let dimensions = sliceDimensions(axis: axis, labelMap: map)
        let transform = displayTransform(for: axis, volume: displayVolume)
        let key = SliceRenderCacheKey(
            layer: outlineOnly ? .labelOutline : .label,
            sourceVolumeID: nil,
            referenceVolumeID: displayVolume?.id,
            labelMapID: map.id,
            labelRevision: map.renderRevision,
            axis: axis,
            sliceIndex: index,
            mode: mode.rawValue,
            width: dimensions.width,
            height: dimensions.height,
            depth: map.depth,
            window: 0,
            level: 0,
            invert: false,
            colormap: "labels",
            opacity: renderKey(map.opacity),
            flipHorizontal: transform.flipHorizontal,
            flipVertical: transform.flipVertical,
            suvSignature: "none"
        )

        return cachedSliceImage(for: key) {
            let slice = map.slice(axis: axis, index: index)
            var values = slice.values
            let w = slice.width, h = slice.height
            values = SliceTransform.apply(values, width: w, height: h,
                                          transform: transform)
            if outlineOnly {
                return LabelRenderer.makeOutlineImage(values: values, width: w, height: h,
                                                        classes: map.classes,
                                                        baseAlpha: map.opacity)
            }
            return LabelRenderer.makeImage(values: values, width: w, height: h,
                                             classes: map.classes,
                                             baseAlpha: map.opacity)
        }
    }

    public func makeOverlayImage(for axis: Int, mode: SliceDisplayMode = .fused) -> CGImage? {
        guard sliceIndices.indices.contains(axis) else { return nil }
        guard mode == .fused else { return nil }
        guard let pair = fusion else { return nil }
        guard pair.overlayVisible else { return nil }
        let ov = pair.displayedOverlay
        let index = sliceIndex(axis: axis, volume: ov)
        let dimensions = sliceDimensions(axis: axis, volume: ov)
        let transform = displayTransform(for: axis, volume: pair.baseVolume)
        let key = SliceRenderCacheKey(
            layer: .overlay,
            sourceVolumeID: ov.id,
            referenceVolumeID: pair.baseVolume.id,
            labelMapID: nil,
            labelRevision: 0,
            axis: axis,
            sliceIndex: index,
            mode: mode.rawValue,
            width: dimensions.width,
            height: dimensions.height,
            depth: ov.depth,
            window: renderKey(pair.overlayWindow),
            level: renderKey(pair.overlayLevel),
            invert: false,
            colormap: pair.colormap.rawValue,
            opacity: renderKey(pair.opacity),
            flipHorizontal: transform.flipHorizontal,
            flipVertical: transform.flipVertical,
            suvSignature: suvRenderSignature(for: ov)
        )

        return cachedSliceImage(for: key) {
            let slice = ov.slice(axis: axis, index: index)
            var pixels = petDisplayPixels(slice.pixels, volume: ov)
            let w = slice.width, h = slice.height
            pixels = SliceTransform.apply(pixels, width: w, height: h,
                                          transform: transform)
            return PixelRenderer.makeColorImage(
                pixels: pixels, width: w, height: h,
                window: pair.overlayWindow, level: pair.overlayLevel,
                colormap: pair.colormap,
                baseAlpha: pair.opacity
            )
        }
    }

    private func cachedSliceImage(for key: SliceRenderCacheKey,
                                  build: () -> CGImage?) -> CGImage? {
        if let image = sliceRenderCache[key] {
            sliceRenderCacheHitCount &+= 1
            sliceRenderCacheOrder.removeAll { $0 == key }
            sliceRenderCacheOrder.append(key)
            return image
        }

        guard let image = build() else { return nil }
        sliceRenderCacheMissCount &+= 1
        sliceRenderCache[key] = image
        sliceRenderCacheOrder.removeAll { $0 == key }
        sliceRenderCacheOrder.append(key)
        while sliceRenderCacheOrder.count > maxSliceRenderCacheEntries {
            let evicted = sliceRenderCacheOrder.removeFirst()
            sliceRenderCache.removeValue(forKey: evicted)
        }
        return image
    }

    private func sliceIndex(axis: Int, volume: ImageVolume) -> Int {
        displayedSliceIndex(axis: axis, volume: volume)
    }

    private func sliceIndex(axis: Int, labelMap: LabelMap) -> Int {
        let maxIndex: Int
        switch axis {
        case 0: maxIndex = labelMap.width - 1
        case 1: maxIndex = labelMap.height - 1
        default: maxIndex = labelMap.depth - 1
        }
        return Swift.max(0, Swift.min(maxIndex, sliceIndices[axis]))
    }

    private func sliceDimensions(axis: Int, volume: ImageVolume) -> (width: Int, height: Int) {
        switch axis {
        case 0: return (volume.height, volume.depth)
        case 1: return (volume.width, volume.depth)
        default: return (volume.width, volume.height)
        }
    }

    private func sliceDimensions(axis: Int, labelMap: LabelMap) -> (width: Int, height: Int) {
        switch axis {
        case 0: return (labelMap.height, labelMap.depth)
        case 1: return (labelMap.width, labelMap.depth)
        default: return (labelMap.width, labelMap.height)
        }
    }

    private func renderKey(_ value: Double, scale: Double = 1_000) -> Int {
        guard value.isFinite else { return 0 }
        let scaled = (value * scale).rounded()
        if scaled >= Double(Int.max) { return Int.max }
        if scaled <= Double(Int.min) { return Int.min }
        return Int(scaled)
    }

    private func optionalRenderKey(_ value: Double?) -> Int {
        guard let value else { return Int.min }
        return renderKey(value)
    }

    private func suvRenderSignature(for volume: ImageVolume?) -> String {
        guard let volume, Modality.normalize(volume.modality) == .PT else {
            return "none"
        }
        let settings = suvSettings
        return [
            settings.mode.rawValue,
            settings.activityUnit.rawValue,
            "\(renderKey(settings.customBqPerMLPerStoredUnit))",
            "\(renderKey(settings.manualScaleFactor))",
            "\(renderKey(settings.patientWeightKg))",
            "\(renderKey(settings.patientHeightCm))",
            "\(renderKey(settings.injectedDoseMBq))",
            "\(renderKey(settings.residualDoseMBq))",
            settings.sex.rawValue,
            "\(optionalRenderKey(volume.suvScaleFactor))"
        ].joined(separator: "|")
    }

    public func makePETMIPImage(for axis: Int) -> CGImage? {
        guard let pet = activePETQuantificationVolume else { return nil }
        let key = PETMIPProjectionKey(volume: pet, axis: axis)
        guard let mip = petMIPProjectionCache[key] else {
            startPETMIPProjectionIfNeeded(volume: pet, axis: axis, key: key)
            return nil
        }
        var pixels = SliceTransform.apply(
            mip.pixels,
            width: mip.width,
            height: mip.height,
            transform: displayTransform(for: axis, volume: pet)
        )
        pixels = petDisplayPixels(pixels, volume: pet)
        return PixelRenderer.makeColorImage(
            pixels: pixels,
            width: mip.width,
            height: mip.height,
            window: overlayWindow,
            level: overlayLevel,
            colormap: mipColormap,
            baseAlpha: 1.0,
            invert: invertPETMIP
        )
    }

    public func isPETMIPProjectionPending(for axis: Int) -> Bool {
        guard let pet = activePETQuantificationVolume else { return false }
        return petMIPProjectionTasks[PETMIPProjectionKey(volume: pet, axis: axis)] != nil
    }

    public func petSUVDisplayRange(for volume: ImageVolume) -> (min: Double, max: Double) {
        guard Modality.normalize(volume.modality) == .PT else {
            return (Double(volume.intensityRange.min), Double(volume.intensityRange.max))
        }
        var minValue = Double.greatestFiniteMagnitude
        var maxValue = -Double.greatestFiniteMagnitude
        for raw in volume.pixels {
            let value = suvValue(rawStoredValue: Double(raw), volume: volume)
            guard value.isFinite else { continue }
            minValue = Swift.min(minValue, value)
            maxValue = Swift.max(maxValue, value)
        }
        if minValue == Double.greatestFiniteMagnitude {
            return (0, 1)
        }
        return (minValue, maxValue)
    }

    private func petDisplayPixels(_ pixels: [Float], volume: ImageVolume) -> [Float] {
        guard Modality.normalize(volume.modality) == .PT else { return pixels }
        return pixels.map { Float(suvValue(rawStoredValue: Double($0), volume: volume)) }
    }

    private func startPETMIPProjectionIfNeeded(volume: ImageVolume,
                                               axis: Int,
                                               key: PETMIPProjectionKey) {
        guard petMIPProjectionTasks[key] == nil else { return }
        petMIPProjectionTasks[key] = Task { [weak self, volume, axis, key] in
            let projection = await Task.detached(priority: .userInitiated) {
                PETMIPProjection.compute(volume: volume, axis: axis)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.petMIPProjectionTasks[key] = nil
            self.petMIPProjectionCache[key] = projection
            self.petMIPProjectionCacheOrder.removeAll { $0 == key }
            self.petMIPProjectionCacheOrder.append(key)
            while self.petMIPProjectionCacheOrder.count > self.maxPETMIPProjectionCacheEntries {
                let evicted = self.petMIPProjectionCacheOrder.removeFirst()
                self.petMIPProjectionCache.removeValue(forKey: evicted)
            }
            self.petMIPCacheRevision += 1
        }
    }
}

private func findNIfTIFiles(in url: URL) -> [URL] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var files: [URL] = []
    for case let fileURL as URL in enumerator {
        let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        guard isFile, NIfTILoader.isVolumeFile(fileURL) else { continue }
        files.append(fileURL)
    }
    return files.sorted { $0.path < $1.path }
}
