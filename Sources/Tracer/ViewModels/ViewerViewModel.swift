import Foundation
import SwiftUI
import Combine
import SwiftData
import simd

public enum ViewerTool: String, CaseIterable, Identifiable {
    case wl, pan, zoom, distance, angle, area, suvSphere, fusionAlign

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .wl: return "W/L"
        case .pan: return "Pan"
        case .zoom: return "Zoom"
        case .distance: return "Distance"
        case .angle: return "Angle"
        case .area: return "Area"
        case .suvSphere: return "Sphere ROI"
        case .fusionAlign: return "Fusion Align"
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
        case .fusionAlign: return "arrow.up.left.and.arrow.down.right"
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
            return "Spherical SUV / HU ROI\n"
                 + "Click PET or fused images for SUVmax/SUVmean.\n"
                 + "Click CT/MR panes for HU or raw intensity stats.\n"
                 + "Shortcut: S"
        case .fusionAlign:
            return "Manual Fusion Alignment\n"
                 + "Drag a fused viewport to nudge the PET overlay in patient space.\n"
                 + "Release the mouse to resample and apply the correction.\n"
                 + "Use after choosing the MR/CT and PET series in Fusion."
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
        case .fusionAlign: return "f"
        }
    }
}

public struct VolumeOperationStatus: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let startedAt: Date
    public let mapID: UUID?
    public let isMutating: Bool

    public init(id: UUID,
                title: String,
                detail: String,
                startedAt: Date,
                mapID: UUID? = nil,
                isMutating: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
        self.mapID = mapID
        self.isMutating = isMutating
    }
}

public enum DisplayWindowLevelTarget: String, Equatable, Sendable {
    case base
    case petOnly
    case petOverlay
}

public struct DisplayWindowLevelSnapshot: Equatable, Sendable {
    public let target: DisplayWindowLevelTarget
    public let window: Double
    public let level: Double
}

private enum PETMIPRotationConstants {
    static let fullCircleTenths = 3_600
    static let stepDegrees = 5.0
    static let stepTenths = 50
    static let fullCircleFrameCount = fullCircleTenths / stepTenths
    static let minimumCachedProjectionFrames = fullCircleFrameCount * 2 + 1
}

private struct PETMIPProjectionKey: Hashable, Sendable {
    let volumeIdentity: String
    let axis: Int
    let width: Int
    let height: Int
    let depth: Int
    let rotationTenths: Int

    init(volume: ImageVolume, axis: Int, rotationDegrees: Double) {
        self.init(volume: volume,
                  axis: axis,
                  rotationTenths: PETMIPProjectionKey.quantizedRotationTenths(rotationDegrees))
    }

    init(volume: ImageVolume, axis: Int, rotationTenths: Int) {
        self.volumeIdentity = volume.sessionIdentity
        self.axis = axis
        self.width = volume.width
        self.height = volume.height
        self.depth = volume.depth
        self.rotationTenths = axis == 2 ? 0 : PETMIPProjectionKey.normalizedRotationTenths(rotationTenths)
    }

    fileprivate static func quantizedRotationTenths(_ degrees: Double) -> Int {
        guard degrees.isFinite else { return 0 }
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        let tenths = Int((normalized * 10).rounded())
        let step = PETMIPRotationConstants.stepTenths
        let snapped = Int((Double(tenths) / Double(step)).rounded()) * step
        return normalizedRotationTenths(snapped)
    }

    private static func normalizedRotationTenths(_ tenths: Int) -> Int {
        let value = tenths % PETMIPRotationConstants.fullCircleTenths
        return value < 0 ? value + PETMIPRotationConstants.fullCircleTenths : value
    }

    var needsRotatedProjection: Bool {
        axis != 2 && rotationTenths != 0
    }

    func sameVolumeAndAxis(as other: PETMIPProjectionKey) -> Bool {
        volumeIdentity == other.volumeIdentity
            && axis == other.axis
            && width == other.width
            && height == other.height
            && depth == other.depth
    }

    func rotationDistanceTenths(to other: PETMIPProjectionKey) -> Int {
        let raw = abs(rotationTenths - other.rotationTenths)
        return min(raw, max(0, 3_600 - raw))
    }
}

private struct PETMIPCineWarmupKey: Hashable, Sendable {
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

private struct PETMIPRenderedImageKey: Hashable {
    let projectionKey: PETMIPProjectionKey
    let projectionWidth: Int
    let projectionHeight: Int
    let window: Int
    let level: Int
    let invert: Bool
    let colormap: String
    let flipHorizontal: Bool
    let flipVertical: Bool
    let suvSignature: String
}

private struct PETMIPRenderedLabelKey: Hashable {
    let projectionKey: PETMIPProjectionKey
    let projectionWidth: Int
    let projectionHeight: Int
    let labelMapID: UUID
    let labelRevision: Int
    let flipHorizontal: Bool
    let flipVertical: Bool
}

private struct PETMIPProjectionSelection {
    let key: PETMIPProjectionKey
    let projection: PETMIPProjection
}

private struct PETMIPProjection: Sendable {
    let pixels: [Float]
    let argmaxX: [Int]
    let argmaxY: [Int]
    let argmaxZ: [Int]
    let width: Int
    let height: Int

    static func compute(volume: ImageVolume,
                        axis: Int,
                        horizontalRotationDegrees: Double,
                        interactivePreview: Bool = false) -> PETMIPProjection {
        let pixels = volume.pixels
        let width = volume.width
        let height = volume.height
        let depth = volume.depth

        if axis != 2 {
            let sampleStride = interactivePreview
                ? interactiveSampleStride(width: width, height: height)
                : 1
            return computeRotatedAxialProjection(
                pixels: pixels,
                volumeWidth: width,
                volumeHeight: height,
                volumeDepth: depth,
                axis: axis,
                horizontalRotationDegrees: horizontalRotationDegrees,
                sampleStride: sampleStride
            )
        }

        switch axis {
        case 0:
            var out = [Float](repeating: 0, count: depth * height)
            var argX = [Int](repeating: 0, count: out.count)
            var argY = [Int](repeating: 0, count: out.count)
            var argZ = [Int](repeating: 0, count: out.count)
            for z in 0..<depth {
                if Task.isCancelled { return PETMIPProjection.empty(width: height, height: depth) }
                let slabStart = z * height * width
                for y in 0..<height {
                    let rowStart = slabStart + y * width
                    var maxValue = -Float.greatestFiniteMagnitude
                    var maxX = 0
                    for x in 0..<width {
                        let value = pixels[rowStart + x]
                        if value > maxValue {
                            maxValue = value
                            maxX = x
                        }
                    }
                    let outIndex = z * height + y
                    out[outIndex] = maxValue
                    argX[outIndex] = maxX
                    argY[outIndex] = y
                    argZ[outIndex] = z
                }
            }
            return PETMIPProjection(pixels: out, argmaxX: argX, argmaxY: argY, argmaxZ: argZ, width: height, height: depth)

        case 1:
            var out = [Float](repeating: 0, count: depth * width)
            var argX = [Int](repeating: 0, count: out.count)
            var argY = [Int](repeating: 0, count: out.count)
            var argZ = [Int](repeating: 0, count: out.count)
            for z in 0..<depth {
                if Task.isCancelled { return PETMIPProjection.empty(width: width, height: depth) }
                let slabStart = z * height * width
                for x in 0..<width {
                    var maxValue = -Float.greatestFiniteMagnitude
                    var maxY = 0
                    for y in 0..<height {
                        let value = pixels[slabStart + y * width + x]
                        if value > maxValue {
                            maxValue = value
                            maxY = y
                        }
                    }
                    let outIndex = z * width + x
                    out[outIndex] = maxValue
                    argX[outIndex] = x
                    argY[outIndex] = maxY
                    argZ[outIndex] = z
                }
            }
            return PETMIPProjection(pixels: out, argmaxX: argX, argmaxY: argY, argmaxZ: argZ, width: width, height: depth)

        default:
            var out = [Float](repeating: 0, count: height * width)
            var argX = [Int](repeating: 0, count: out.count)
            var argY = [Int](repeating: 0, count: out.count)
            var argZ = [Int](repeating: 0, count: out.count)
            for y in 0..<height {
                if Task.isCancelled { return PETMIPProjection.empty(width: width, height: height) }
                for x in 0..<width {
                    var maxValue = -Float.greatestFiniteMagnitude
                    var maxZ = 0
                    for z in 0..<depth {
                        let value = pixels[z * height * width + y * width + x]
                        if value > maxValue {
                            maxValue = value
                            maxZ = z
                        }
                    }
                    let outIndex = y * width + x
                    out[outIndex] = maxValue
                    argX[outIndex] = x
                    argY[outIndex] = y
                    argZ[outIndex] = maxZ
                }
            }
            return PETMIPProjection(pixels: out, argmaxX: argX, argmaxY: argY, argmaxZ: argZ, width: width, height: height)
        }
    }

    private static func empty(width: Int, height: Int) -> PETMIPProjection {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        let count = safeWidth * safeHeight
        return PETMIPProjection(pixels: [Float](repeating: 0, count: count),
                                argmaxX: [Int](repeating: -1, count: count),
                                argmaxY: [Int](repeating: -1, count: count),
                                argmaxZ: [Int](repeating: -1, count: count),
                                width: safeWidth,
                                height: safeHeight)
    }

    private static func interactiveSampleStride(width: Int, height: Int) -> Int {
        let inPlaneVoxels = width * height
        if inPlaneVoxels >= 512 * 512 { return 8 }
        if inPlaneVoxels >= 384 * 384 { return 6 }
        if inPlaneVoxels >= 256 * 256 { return 4 }
        if inPlaneVoxels >= 128 * 128 { return 3 }
        return 2
    }

    private static func computeRotatedAxialProjection(pixels: [Float],
                                                      volumeWidth: Int,
                                                      volumeHeight: Int,
                                                      volumeDepth: Int,
                                                      axis: Int,
                                                      horizontalRotationDegrees: Double,
                                                      sampleStride requestedSampleStride: Int) -> PETMIPProjection {
        let sampleStride = max(1, requestedSampleStride)
        let cx = (Double(volumeWidth) - 1) / 2
        let cy = (Double(volumeHeight) - 1) / 2
        let baseAngle = axis == 0 ? Double.pi / 2 : 0
        let angle = baseAngle + horizontalRotationDegrees * Double.pi / 180
        let cosA = cos(angle)
        let sinA = sin(angle)
        let diagonal = hypot(Double(max(0, volumeWidth - 1)), Double(max(0, volumeHeight - 1)))
        let outWidth = max(1, Int((diagonal / Double(sampleStride)).rounded(.up)) + 1)
        let minU = -Double(outWidth - 1) * Double(sampleStride) / 2
        let outHeight = max(1, (volumeDepth + sampleStride - 1) / sampleStride)
        let count = outWidth * outHeight
        var out = [Float](repeating: -Float.greatestFiniteMagnitude, count: count)
        var argX = [Int](repeating: -1, count: count)
        var argY = [Int](repeating: -1, count: count)
        var argZ = [Int](repeating: -1, count: count)

        for z in Swift.stride(from: 0, to: volumeDepth, by: sampleStride) {
            if Task.isCancelled { return PETMIPProjection.empty(width: outWidth, height: outHeight) }
            let outZ = z / sampleStride
            let slabStart = z * volumeHeight * volumeWidth
            for y in Swift.stride(from: 0, to: volumeHeight, by: sampleStride) {
                let rowStart = slabStart + y * volumeWidth
                let dy = Double(y) - cy
                for x in Swift.stride(from: 0, to: volumeWidth, by: sampleStride) {
                    let dx = Double(x) - cx
                    let u = dx * cosA + dy * sinA
                    let outX = Int(((u - minU) / Double(sampleStride)).rounded())
                    guard outX >= 0, outX < outWidth else { continue }
                    let outIndex = outZ * outWidth + outX
                    let value = pixels[rowStart + x]
                    if value > out[outIndex] {
                        out[outIndex] = value
                        argX[outIndex] = x
                        argY[outIndex] = y
                        argZ[outIndex] = z
                    }
                }
            }
        }

        for index in out.indices where out[index] == -Float.greatestFiniteMagnitude {
            out[index] = 0
        }
        return PETMIPProjection(pixels: out, argmaxX: argX, argmaxY: argY, argmaxZ: argZ, width: outWidth, height: outHeight)
    }
}

private enum SliceRenderLayer: String, Hashable {
    case base
    case fused
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
    let secondaryWindow: Int
    let secondaryLevel: Int
    let secondaryInvert: Bool
    let invert: Bool
    let colormap: String
    let opacity: Int
    let flipHorizontal: Bool
    let flipVertical: Bool
    let suvSignature: String
}

private struct ViewerPatientSeed {
    let patientID: String
    let patientName: String
    let suggestedName: String?
}

@MainActor
public final class ViewerViewModel: ObservableObject {
    public static let petMIPRotationStepDegrees = PETMIPRotationConstants.stepDegrees

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
    @Published public var invertPETImages: Bool = false
    @Published public var invertPETOnlyImages: Bool = false
    @Published public var invertCTImages: Bool = false
    @Published public var invertPETMIP: Bool = false
    @Published public var correctAnteriorPosteriorDisplay: Bool = false
    @Published public var correctRightLeftDisplay: Bool = false
    @Published public var linkZoomPanAcrossPanes: Bool = true
    @Published public var sharedViewportTransform: ViewportTransformState = .identity
    @Published public var paneViewportTransforms: [Int: ViewportTransformState] = [:]

    // Overlay display settings
    @Published public var overlayOpacity: Double = 0.5
    @Published public var overlayColormap: Colormap = .tracerPET
    @Published public var petOnlyColormap: Colormap = .petHotIron
    @Published public var mipColormap: Colormap = .grayscale
    @Published public var petMIPRotationDegrees: Double = 0
    @Published public var overlayWindow: Double = 6
    @Published public var overlayLevel: Double = 3
    @Published public var petOnlyWindow: Double = 6
    @Published public var petOnlyLevel: Double = 3
    @Published public var petMIPWindow: Double = 6
    @Published public var petMIPLevel: Double = 3
    @Published public var petMRRegistrationMode: PETMRRegistrationMode = .automaticBestFit
    @Published public var petMRDeformableRegistration = PETMRDeformableRegistrationConfiguration()
    @Published public var hangingGrid: HangingGridLayout = .defaultPETCT
    @Published public var suvSettings = SUVCalculationSettings()
    @Published public var hangingPanes: [HangingPaneConfiguration] = HangingPaneConfiguration.defaultPETCT
    @Published public var lastVolumeMeasurementReport: VolumeMeasurementReport?
    @Published public private(set) var lastRadiomicsFeatureReport: RadiomicsFeatureReport?
    @Published public var suvSphereRadiusMM: Double = 6.2
    @Published public var suvROIMeasurements: [SUVROIMeasurement] = []
    @Published public var lastSUVROIMeasurement: SUVROIMeasurement?
    @Published public var intensityROIMeasurements: [IntensityROIMeasurement] = []
    @Published public var lastIntensityROIMeasurement: IntensityROIMeasurement?
    @Published public private(set) var viewerSessions: [ViewerSessionRecord] = []
    @Published public private(set) var activeViewerSessionID: UUID?
    @Published public private(set) var studySessions: [StudyMeasurementSession] = []
    @Published public private(set) var activeStudySessionID: UUID?
    @Published public private(set) var activeStudySessionKey: String?
    @Published public private(set) var segmentationRuns: [SegmentationRunRecord] = []
    @Published public private(set) var activePETOncologyReview: PETOncologyReview?
    @Published public private(set) var activeSegmentationQualityReport: SegmentationQualityReport?
    @Published public private(set) var autoContourSession: AutoContourSession?
    @Published public private(set) var autoContourQAReport: AutoContourQAReport?
    @Published public private(set) var brainPETReport: BrainPETReport?
    @Published public private(set) var brainPETAnatomyAwareReport: BrainPETAnatomyAwareReport?
    @Published public private(set) var brainPETNormalDatabase: BrainPETNormalDatabase?
    @Published public private(set) var neuroQuantWorkbenchResult: NeuroQuantWorkbenchResult?
    @Published public var dynamicStudy: DynamicImageStudy?
    @Published public var selectedDynamicFrameIndex: Int = 0
    @Published public var dynamicPlaybackFPS: Double = 2.0
    @Published public private(set) var isDynamicPlaybackRunning: Bool = false
    @Published public private(set) var dynamicTimeActivityCurve: [DynamicTimeActivityPoint] = []
    @Published public private(set) var isDynamicTACComputing: Bool = false
    @Published public private(set) var volumeOperationStatus: VolumeOperationStatus?
    @Published public private(set) var volumeOperationStatuses: [VolumeOperationStatus] = []
    @Published public private(set) var petMIPCacheRevision: Int = 0
    @Published public private(set) var petMIPCineProgressByAxis: [Int: Double] = [:]
    @Published public private(set) var sliceRenderWarmupStatus: String = "Slice cache idle"
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
        var invertPETImages: Bool
        var invertPETOnlyImages: Bool
        var invertCTImages: Bool
        var invertPETMIP: Bool
        var correctAnteriorPosteriorDisplay: Bool
        var correctRightLeftDisplay: Bool
        var linkZoomPanAcrossPanes: Bool
        var sharedViewportTransform: ViewportTransformState
        var paneViewportTransforms: [Int: ViewportTransformState]
        var overlayOpacity: Double
        var overlayColormap: Colormap
        var petOnlyColormap: Colormap
        var mipColormap: Colormap
        var petMIPRotationDegrees: Double
        var overlayWindow: Double
        var overlayLevel: Double
        var petOnlyWindow: Double
        var petOnlyLevel: Double
        var petMIPWindow: Double
        var petMIPLevel: Double
        var petMRRegistrationMode: PETMRRegistrationMode
        var petMRDeformableRegistration: PETMRDeformableRegistrationConfiguration
        var hangingGrid: HangingGridLayout
        var hangingPanes: [HangingPaneConfiguration]
        var annotations: [Annotation]
        var suvSphereRadiusMM: Double
        var suvROIs: [SUVROIMeasurement]
        var lastSUVROI: SUVROIMeasurement?
        var intensityROIs: [IntensityROIMeasurement]
        var lastIntensityROI: IntensityROIMeasurement?
        var lastRadiomicsReport: RadiomicsFeatureReport?
        var labelVoxels: [UUID: [UInt16]]
    }

    private var appUndoStack: [AppHistoryRecord] = []
    private var appRedoStack: [AppHistoryRecord] = []
    private var isReplayingAppHistory = false
    private let maxAppHistoryRecords = 120
    private let maxBackgroundTrackedChangedVoxels = 5_000_000
    private var volumeOperationTasks: [UUID: Task<Void, Never>] = [:]
    private var autoWindowTask: Task<Void, Never>?
    private var sliceRenderWarmupTask: Task<Void, Never>?
    private var fusionAdjustmentTask: Task<Void, Never>?
    private var dynamicPlaybackTask: Task<Void, Never>?
    private var dynamicTACTask: Task<Void, Never>?
    private var petMIPProjectionCache: [PETMIPProjectionKey: PETMIPProjection] = [:]
    private var petMIPProjectionCacheOrder: [PETMIPProjectionKey] = []
    private var petMIPProjectionTasks: [PETMIPProjectionKey: Task<Void, Never>] = [:]
    private var petMIPPreviewProjectionCache: [PETMIPProjectionKey: PETMIPProjection] = [:]
    private var petMIPPreviewProjectionCacheOrder: [PETMIPProjectionKey] = []
    private var petMIPPreviewProjectionTasks: [PETMIPProjectionKey: Task<Void, Never>] = [:]
    private var petMIPCineWarmupTasks: [PETMIPCineWarmupKey: Task<Void, Never>] = [:]
    private var petMIPCineWarmupTokens: [PETMIPCineWarmupKey: UUID] = [:]
    private var petMIPCineReadyKeys: Set<PETMIPCineWarmupKey> = []
    private var petMIPCineProgressKeys: [PETMIPCineWarmupKey: Double] = [:]
    private var petMIPCineProgressVolumeIdentity: String?
    private var petMIPCineWarmupDebounceTask: Task<Void, Never>?
    private var petMIPFullQualityDebounceTask: Task<Void, Never>?
    private let petMIPFullQualitySettleDelayNanoseconds: UInt64 = 700_000_000
    private let petMIPCineWarmupSettleDelayNanoseconds: UInt64 = 1_500_000_000
    private let petMIPCineStepTenths = PETMIPRotationConstants.stepTenths
    private var petMIPRenderedImageCache: [PETMIPRenderedImageKey: CGImage] = [:]
    private var petMIPRenderedImageCacheOrder: [PETMIPRenderedImageKey] = []
    private var petMIPRenderedLabelCache: [PETMIPRenderedLabelKey: CGImage] = [:]
    private var petMIPRenderedLabelCacheOrder: [PETMIPRenderedLabelKey] = []
    private var sliceRenderCache: [SliceRenderCacheKey: CGImage] = [:]
    private var sliceRenderCacheOrder: [SliceRenderCacheKey] = []
    public private(set) var sliceRenderCacheHitCount: Int = 0
    public private(set) var sliceRenderCacheMissCount: Int = 0

    // DICOM study browser
    @Published public var loadedSeries: [DICOMSeries] = []
    @Published public private(set) var vnaConnections: [VNAConnection] = []
    @Published public private(set) var activeVNAConnectionID: UUID?
    @Published public private(set) var vnaStudies: [VNAStudy] = []
    @Published public private(set) var vnaSeriesByStudyID: [String: [VNASeries]] = [:]
    @Published public private(set) var isVNASearching: Bool = false
    @Published public private(set) var isVNARetrieving: Bool = false
    @Published public private(set) var vnaLastError: String?

    /// Capped LRU list of the last `RecentVolumesStore.maximumEntries`
    /// volumes the user has opened. Persisted across launches. Displayed as
    /// a horizontal chip row at the top of the Study Browser.
    @Published public private(set) var recentVolumes: [RecentVolume] = []
    @Published public private(set) var savedArchiveRoots: [PACSArchiveRoot] = []
    private let recentVolumesStore = RecentVolumesStore()
    private let studySessionStore: StudySessionStore
    private let viewerSessionStore: ViewerSessionStore
    private let segmentationRunStore: SegmentationRunRegistryStore
    private let archiveRootStore: PACSArchiveRootStore
    private let vnaConnectionStore: VNAConnectionStore
    private let vnaCacheStore: VNACacheStore
    private var viewerPatientSeedBySeriesUID: [String: ViewerPatientSeed] = [:]
    private var viewerPatientSeedByVolumeIdentity: [String: ViewerPatientSeed] = [:]

    public init(studySessionStore: StudySessionStore = StudySessionStore(),
                viewerSessionStore: ViewerSessionStore = ViewerSessionStore(),
                segmentationRunStore: SegmentationRunRegistryStore = SegmentationRunRegistryStore(),
                archiveRootStore: PACSArchiveRootStore = PACSArchiveRootStore(),
                vnaConnectionStore: VNAConnectionStore = VNAConnectionStore(),
                vnaCacheStore: VNACacheStore = VNACacheStore()) {
        self.studySessionStore = studySessionStore
        self.viewerSessionStore = viewerSessionStore
        self.segmentationRunStore = segmentationRunStore
        self.archiveRootStore = archiveRootStore
        self.vnaConnectionStore = vnaConnectionStore
        self.vnaCacheStore = vnaCacheStore
        self.recentVolumes = recentVolumesStore.load()
        self.savedArchiveRoots = archiveRootStore.load()
        self.vnaConnections = vnaConnectionStore.load()
        self.activeVNAConnectionID = vnaConnections.first(where: \.isEnabled)?.id ?? vnaConnections.first?.id
        loadViewerSessions()
    }

    public var activeViewerSession: ViewerSessionRecord? {
        guard let activeViewerSessionID else { return nil }
        return viewerSessions.first { $0.id == activeViewerSessionID }
    }

    public var activeVNAConnection: VNAConnection? {
        guard let activeVNAConnectionID else { return nil }
        return vnaConnections.first { $0.id == activeVNAConnectionID }
    }

    public var openStudies: [ViewerSessionStudyReference] {
        if let activeViewerSession {
            return activeViewerSession.studies
        }
        return makeStudyReferences(from: loadedVolumes)
    }

    public var activeSessionVolumes: [ImageVolume] {
        guard let activeViewerSession else { return loadedVolumes }
        let identities = Set(activeViewerSession.volumes.map(\.volumeIdentity))
        guard !identities.isEmpty else { return [] }
        return loadedVolumes.filter { identities.contains($0.sessionIdentity) }
    }

    public var activeOpenStudy: ViewerSessionStudyReference? {
        guard let currentVolume else { return nil }
        let key = viewerStudyKey(for: currentVolume)
        return openStudies.first { $0.studyKey == key }
    }

    public var activeStudySession: StudyMeasurementSession? {
        guard let activeStudySessionID else { return nil }
        return studySessions.first { $0.id == activeStudySessionID }
    }

    public var visibleAnnotations: [Annotation] {
        guard !studySessions.isEmpty else { return annotations }
        return studySessions.filter(\.visible).flatMap { session in
            session.id == activeStudySessionID ? annotations : session.annotations
        }
    }

    public var visibleSUVROIMeasurements: [SUVROIMeasurement] {
        guard !studySessions.isEmpty else { return suvROIMeasurements }
        return studySessions.filter(\.visible).flatMap { session in
            session.id == activeStudySessionID ? suvROIMeasurements : session.suvROIs
        }
    }

    public var visibleIntensityROIMeasurements: [IntensityROIMeasurement] {
        guard !studySessions.isEmpty else { return intensityROIMeasurements }
        return studySessions.filter(\.visible).flatMap { session in
            session.id == activeStudySessionID ? intensityROIMeasurements : session.intensityROIs
        }
    }

    public var visibleVolumeMeasurementReports: [VolumeMeasurementReport] {
        guard !studySessions.isEmpty else {
            return lastVolumeMeasurementReport.map { [$0] } ?? []
        }
        return studySessions.filter(\.visible).flatMap { session in
            if session.id == activeStudySessionID {
                return lastVolumeMeasurementReport.map { [$0] } ?? []
            }
            return session.volumeReports
        }
    }

    public var visibleRadiomicsFeatureReports: [RadiomicsFeatureReport] {
        guard !studySessions.isEmpty else {
            return lastRadiomicsFeatureReport.map { [$0] } ?? []
        }
        return studySessions.filter(\.visible).flatMap { session in
            if session.id == activeStudySessionID {
                return lastRadiomicsFeatureReport.map { [$0] } ?? []
            }
            return session.radiomicsReports
        }
    }

    public var loadedCTVolumes: [ImageVolume] {
        activeSessionVolumes.filter { Modality.normalize($0.modality) == .CT }
    }

    public var loadedPETVolumes: [ImageVolume] {
        activeSessionVolumes.filter { Modality.normalize($0.modality) == .PT }
    }

    public var loadedMRVolumes: [ImageVolume] {
        activeSessionVolumes.filter { Modality.normalize($0.modality) == .MR }
    }

    public var currentStudyVolumes: [ImageVolume] {
        guard let currentVolume else { return [] }
        return studyVolumes(anchoredAt: currentVolume)
    }

    public var currentStudyReportKey: String? {
        let volumes = currentStudyVolumes
        guard !volumes.isEmpty else { return nil }
        return StudySessionStore.studyKey(for: volumes)
    }

    public var loadedAnatomicalVolumes: [ImageVolume] {
        activeSessionVolumes.filter {
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

    public func activeBrainPETAnatomyVolume(for mode: BrainPETAnatomyMode,
                                            pet: ImageVolume? = nil) -> ImageVolume? {
        let pet = pet ?? activePETQuantificationVolume
        let candidates: [ImageVolume]
        if let pet {
            let studyCandidates = studyVolumes(anchoredAt: pet).filter {
                let modality = Modality.normalize($0.modality)
                return modality == .MR || modality == .CT
            }
            candidates = studyCandidates.isEmpty ? loadedAnatomicalVolumes : studyCandidates
        } else {
            candidates = loadedAnatomicalVolumes
        }

        func best(_ modality: Modality) -> ImageVolume? {
            if let currentVolume,
               Modality.normalize(currentVolume.modality) == modality,
               candidates.contains(where: { $0.sessionIdentity == currentVolume.sessionIdentity }) {
                return currentVolume
            }
            return candidates.first { Modality.normalize($0.modality) == modality }
        }

        switch mode {
        case .automatic:
            return best(.MR) ?? best(.CT)
        case .mriAssisted:
            return best(.MR)
        case .ctAssisted:
            return best(.CT)
        case .petOnly:
            return nil
        }
    }

    public func preparePETMIPCine(for axis: Int) {
        guard let pet = activePETQuantificationVolume else { return }
        let key = PETMIPProjectionKey(volume: pet, axis: axis, rotationDegrees: petMIPRotationDegrees)
        guard axis != SlicePlane.axial.axis else {
            startPETMIPProjectionIfNeeded(volume: pet, axis: axis, key: key)
            return
        }
        startPETMIPCineWarmupIfNeeded(volume: pet, axis: axis, around: key.rotationTenths)
    }

    public func preparePETMIPFrame(for axis: Int, rotationDegrees: Double) {
        guard let pet = activePETQuantificationVolume else { return }
        let key = PETMIPProjectionKey(volume: pet, axis: axis, rotationDegrees: rotationDegrees)
        if axis != SlicePlane.axial.axis {
            let warmupKey = PETMIPCineWarmupKey(volume: pet, axis: axis)
            if petMIPCineReadyKeys.contains(warmupKey),
               !hasRenderedPETMIPFrame(volume: pet, axis: axis, key: key) {
                petMIPCineReadyKeys.remove(warmupKey)
                petMIPCineProgressKeys[warmupKey] = 0
                petMIPCineProgressByAxis[axis] = 0
            }
        }
        startPETMIPProjectionIfNeeded(volume: pet, axis: axis, key: key)
    }

    public func isPETMIPCineReady(for axis: Int) -> Bool {
        guard let pet = activePETQuantificationVolume else { return false }
        if axis == SlicePlane.axial.axis {
            return isPETMIPCurrentFrameReady(for: axis)
        }
        return petMIPCineReadyKeys.contains(PETMIPCineWarmupKey(volume: pet, axis: axis))
    }

    public func petMIPCineProgress(for axis: Int) -> Double {
        guard activePETQuantificationVolume != nil else { return 0 }
        if axis == SlicePlane.axial.axis {
            return isPETMIPCurrentFrameReady(for: axis) ? 1 : 0
        }
        return max(0, min(1, petMIPCineProgressByAxis[axis] ?? 0))
    }

    public func setActiveViewerTool(_ tool: ViewerTool) {
        activeTool = tool
        labeling.labelingTool = .none
        switch tool {
        case .suvSphere:
            statusMessage = "Spherical ROI armed: click PET/fusion for SUV or CT/MR for intensity stats"
        case .fusionAlign:
            statusMessage = "Fusion align armed: drag a fused viewport, release to apply PET overlay offset"
        case .distance, .angle, .area:
            statusMessage = "\(tool.displayName) armed"
        default:
            statusMessage = "\(tool.displayName) tool active"
        }
    }

    public func setActiveLabelingTool(_ tool: LabelingTool) {
        if tool != .none {
            ensureActiveLabelMapForCurrentContext()
            activeTool = .wl
        }
        labeling.labelingTool = tool
        switch tool {
        case .none:
            statusMessage = "Viewer tools active"
        case .freehand:
            statusMessage = "Freehand ROI armed: drag a closed contour and release to fill"
        case .brush, .eraser:
            statusMessage = "\(tool.displayName) armed: drag on a slice"
        case .threshold, .suvGradient, .regionGrow, .activeContour:
            statusMessage = "\(tool.displayName) armed: click a seed voxel"
        case .landmark:
            statusMessage = "Landmark capture armed"
        case .lesionSphere:
            statusMessage = "Quick lesion sphere armed: click a lesion"
        }
    }

    public var petOverlayRangeMin: Double {
        overlayLevel - overlayWindow / 2
    }

    public var petOverlayRangeMax: Double {
        overlayLevel + overlayWindow / 2
    }

    public var petOnlyRangeMin: Double {
        petOnlyLevel - petOnlyWindow / 2
    }

    public var petOnlyRangeMax: Double {
        petOnlyLevel + petOnlyWindow / 2
    }

    public var petMIPRangeMin: Double {
        petMIPLevel - petMIPWindow / 2
    }

    public var petMIPRangeMax: Double {
        petMIPLevel + petMIPWindow / 2
    }

    public var canUndo: Bool {
        appUndoDepth > 0 || labeling.undoDepth > 0
    }

    public var canRedo: Bool {
        appRedoDepth > 0 || labeling.redoDepth > 0
    }

    public var isVolumeOperationRunning: Bool {
        volumeOperationStatuses.contains { $0.isMutating }
    }

    public func cancelVolumeOperation(id: UUID? = nil) {
        let operationIDs: [UUID]
        if let id {
            operationIDs = [id]
        } else {
            operationIDs = Array(Set(volumeOperationTasks.keys).union(volumeOperationStatuses.map(\.id)))
        }

        for operationID in operationIDs {
            volumeOperationTasks[operationID]?.cancel()
            volumeOperationTasks.removeValue(forKey: operationID)
            guard let operation = volumeOperationStatuses.first(where: { $0.id == operationID }) else { continue }
            statusMessage = "Cancelled \(operation.title)"
            JobManager.shared.cancel(operationID: operation.id.uuidString,
                                     detail: "Cancelled \(operation.title)")
            removeVolumeOperationStatus(id: operationID)
        }
    }

    private func addVolumeOperationStatus(_ status: VolumeOperationStatus) {
        volumeOperationStatuses.removeAll { $0.id == status.id }
        volumeOperationStatuses.append(status)
        volumeOperationStatus = status
    }

    private func removeVolumeOperationStatus(id: UUID) {
        volumeOperationStatuses.removeAll { $0.id == id }
        volumeOperationStatus = volumeOperationStatuses.last
    }

    private func hasMutatingVolumeOperation(for mapID: UUID) -> Bool {
        volumeOperationStatuses.contains { $0.isMutating && $0.mapID == mapID }
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
        scheduleVisibleSliceCacheWarmup(reason: "fusion visibility")
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
        scheduleVisibleSliceCacheWarmup(reason: "PET/CT blend")
        recordValueChange(name: "PET/CT blend", before: before, after: overlayOpacity) { vm, value in
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
        scheduleVisibleSliceCacheWarmup(reason: "PET overlay color")
        recordValueChange(name: "PET overlay color", before: before, after: colormap) { vm, value in
            vm.overlayColormap = value
            vm.fusion?.colormap = value
            vm.fusion?.objectWillChange.send()
        }
    }

    public func setPETOnlyColormap(_ colormap: Colormap) {
        let before = petOnlyColormap
        petOnlyColormap = colormap
        scheduleVisibleSliceCacheWarmup(reason: "PET-only color")
        recordValueChange(name: "PET-only color", before: before, after: colormap) { vm, value in
            vm.petOnlyColormap = value
        }
    }

    public func setPETMIPColormap(_ colormap: Colormap) {
        let before = mipColormap
        mipColormap = colormap
        clearPETMIPRenderedImageCache()
        activePETQuantificationVolume.map(startPETMIPCineWarmupForVolume)
        recordValueChange(name: "PET MIP color", before: before, after: colormap) { vm, value in
            vm.mipColormap = value
            vm.clearPETMIPRenderedImageCache()
        }
    }

    public func setPETMIPRotationDegrees(_ degrees: Double,
                                         priorityAxis: Int? = nil,
                                         scheduleFullQuality: Bool = true) {
        let before = petMIPRotationDegrees
        let after = normalizedPETMIPRotation(degrees)
        applyPETMIPRotation(after)
        if scheduleFullQuality {
            schedulePETMIPFullQualityProjection(priorityAxis: priorityAxis, delayNanoseconds: 0)
        } else {
            cancelPETMIPFullQualityProjectionWork(priorityAxis: priorityAxis)
        }
        recordHistoryIfNeeded(name: "PET MIP rotation", changed: before != after) { [weak self] in
            self?.applyPETMIPRotation(before)
        } redo: { [weak self] in
            self?.applyPETMIPRotation(after)
        }
        statusMessage = String(format: "PET MIP horizontal rotation %.0f°", after)
    }

    public func previewPETMIPRotationDegrees(_ degrees: Double,
                                             priorityAxis: Int? = nil,
                                             scheduleFullQuality: Bool = false) {
        let after = normalizedPETMIPRotation(degrees)
        applyPETMIPRotation(after)
        if scheduleFullQuality {
            schedulePETMIPFullQualityProjection(priorityAxis: priorityAxis,
                                                delayNanoseconds: petMIPFullQualitySettleDelayNanoseconds)
        } else {
            cancelPETMIPFullQualityProjectionWork(priorityAxis: priorityAxis)
        }
        statusMessage = String(format: "PET MIP horizontal rotation %.0f°", after)
    }

    public func setSUVSphereRadiusMM(_ radiusMM: Double) {
        let before = suvSphereRadiusMM
        let after = max(0.5, min(100, radiusMM.isFinite ? radiusMM : before))
        suvSphereRadiusMM = after
        recordValueChange(name: "Sphere ROI radius", before: before, after: after) { vm, value in
            vm.suvSphereRadiusMM = value
        }
        statusMessage = String(format: "Sphere ROI radius %.1f mm", after)
    }

    public func setInvertColors(_ enabled: Bool) {
        let before = invertColors
        invertColors = enabled
        scheduleVisibleSliceCacheWarmup(reason: "image inversion")
        recordValueChange(name: "Invert images", before: before, after: enabled) { vm, value in
            vm.invertColors = value
        }
    }

    public func setInvertPETImages(_ enabled: Bool) {
        let before = invertPETImages
        invertPETImages = enabled
        scheduleVisibleSliceCacheWarmup(reason: "fused PET inversion")
        recordValueChange(name: "Invert fused PET", before: before, after: enabled) { vm, value in
            vm.invertPETImages = value
        }
    }

    public func setInvertPETOnlyImages(_ enabled: Bool) {
        let before = invertPETOnlyImages
        invertPETOnlyImages = enabled
        scheduleVisibleSliceCacheWarmup(reason: "PET-only inversion")
        recordValueChange(name: "Invert PET-only image", before: before, after: enabled) { vm, value in
            vm.invertPETOnlyImages = value
        }
    }

    public func setInvertCTImages(_ enabled: Bool) {
        let before = invertCTImages
        invertCTImages = enabled
        scheduleVisibleSliceCacheWarmup(reason: "CT inversion")
        recordValueChange(name: "Invert CT images", before: before, after: enabled) { vm, value in
            vm.invertCTImages = value
        }
    }

    public func setInvertPETMIP(_ enabled: Bool) {
        let before = invertPETMIP
        invertPETMIP = enabled
        clearPETMIPRenderedImageCache()
        activePETQuantificationVolume.map(startPETMIPCineWarmupForVolume)
        recordValueChange(name: "Invert PET MIP", before: before, after: enabled) { vm, value in
            vm.invertPETMIP = value
            vm.clearPETMIPRenderedImageCache()
        }
    }

    public func setCorrectAnteriorPosteriorDisplay(_ enabled: Bool) {
        let before = correctAnteriorPosteriorDisplay
        correctAnteriorPosteriorDisplay = enabled
        clearPETMIPRenderedImageCache()
        activePETQuantificationVolume.map(startPETMIPCineWarmupForVolume)
        scheduleVisibleSliceCacheWarmup(reason: "display orientation")
        recordValueChange(name: "Flip A/P display axis", before: before, after: enabled) { vm, value in
            vm.correctAnteriorPosteriorDisplay = value
            vm.clearPETMIPRenderedImageCache()
        }
    }

    public func setCorrectRightLeftDisplay(_ enabled: Bool) {
        let before = correctRightLeftDisplay
        correctRightLeftDisplay = enabled
        clearPETMIPRenderedImageCache()
        activePETQuantificationVolume.map(startPETMIPCineWarmupForVolume)
        scheduleVisibleSliceCacheWarmup(reason: "display orientation")
        recordValueChange(name: "Flip R/L display axis", before: before, after: enabled) { vm, value in
            vm.correctRightLeftDisplay = value
            vm.clearPETMIPRenderedImageCache()
        }
    }

    public func setDisplayOrientationCorrection(ap: Bool, rl: Bool, name: String = "Display positioning") {
        let before = (correctAnteriorPosteriorDisplay, correctRightLeftDisplay)
        let after = (ap, rl)
        correctAnteriorPosteriorDisplay = ap
        correctRightLeftDisplay = rl
        clearPETMIPRenderedImageCache()
        activePETQuantificationVolume.map(startPETMIPCineWarmupForVolume)
        scheduleVisibleSliceCacheWarmup(reason: "display orientation")
        recordHistoryIfNeeded(
            name: name,
            changed: before.0 != after.0 || before.1 != after.1
        ) { [weak self] in
            self?.correctAnteriorPosteriorDisplay = before.0
            self?.correctRightLeftDisplay = before.1
            self?.clearPETMIPRenderedImageCache()
        } redo: { [weak self] in
            self?.correctAnteriorPosteriorDisplay = after.0
            self?.correctRightLeftDisplay = after.1
            self?.clearPETMIPRenderedImageCache()
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
        scheduleVisibleSliceCacheWarmup(reason: "PET overlay window")
        let after = (overlayWindow, overlayLevel)
        recordHistoryIfNeeded(name: "PET SUV window", changed: abs(before.0 - after.0) > 0.0001 || abs(before.1 - after.1) > 0.0001) { [weak self] in
            self?.applyPETOverlayWindow(window: before.0, level: before.1)
        } redo: { [weak self] in
            self?.applyPETOverlayWindow(window: after.0, level: after.1)
        }
    }

    public func setPETOnlyRange(min rawMin: Double, max rawMax: Double) {
        let before = (petOnlyWindow, petOnlyLevel)
        let lower = max(0, min(rawMin, rawMax - 0.1))
        let upper = max(lower + 0.1, rawMax)
        petOnlyWindow = upper - lower
        petOnlyLevel = (upper + lower) / 2
        scheduleVisibleSliceCacheWarmup(reason: "PET-only window")
        let after = (petOnlyWindow, petOnlyLevel)
        recordHistoryIfNeeded(name: "PET-only SUV window", changed: abs(before.0 - after.0) > 0.0001 || abs(before.1 - after.1) > 0.0001) { [weak self] in
            self?.applyPETOnlyWindow(window: before.0, level: before.1)
        } redo: { [weak self] in
            self?.applyPETOnlyWindow(window: after.0, level: after.1)
        }
    }

    public func setPETMIPRange(min rawMin: Double, max rawMax: Double, name: String = "PET MIP SUV window") {
        let before = (petMIPWindow, petMIPLevel)
        let lower = max(0, min(rawMin, rawMax - 0.1))
        let upper = max(lower + 0.1, rawMax)
        applyPETMIPWindow(window: upper - lower, level: (upper + lower) / 2)
        let after = (petMIPWindow, petMIPLevel)
        recordHistoryIfNeeded(name: name, changed: abs(before.0 - after.0) > 0.0001 || abs(before.1 - after.1) > 0.0001) { [weak self] in
            self?.applyPETMIPWindow(window: before.0, level: before.1)
        } redo: { [weak self] in
            self?.applyPETMIPWindow(window: after.0, level: after.1)
        }
        statusMessage = String(format: "PET MIP SUV window %.1f-%.1f", petMIPRangeMin, petMIPRangeMax)
    }

    public func adjustPETMIPIntensity(brighter: Bool) {
        let lower = max(0, petMIPRangeMin)
        let upper = max(lower + 0.1, petMIPRangeMax)
        let span = max(0.1, upper - lower)
        let factor = brighter ? 0.80 : 1.25
        let newUpper = lower + max(0.1, span * factor)
        setPETMIPRange(min: lower,
                       max: newUpper,
                       name: brighter ? "Increase PET MIP intensity" : "Decrease PET MIP intensity")
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
        scheduleVisibleSliceCacheWarmup(reason: "hanging protocol")
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
        intensityROIMeasurements.removeAll()
        lastIntensityROIMeasurement = nil
        lastVolumeMeasurementReport = nil
        lastRadiomicsFeatureReport = nil
        resetAllViewportTransforms()
        invertColors = false
        invertPETImages = false
        invertPETOnlyImages = false
        invertCTImages = false
        invertPETMIP = false
        petMIPRotationDegrees = 0
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
        saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: true)
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
        autosaveActiveStudySession()
    }

    @discardableResult
    public func updateAnnotation(_ annotation: Annotation) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else {
            statusMessage = "Measurement was not found in the active session"
            return false
        }
        let previous = annotations[index]
        guard previous != annotation else { return true }
        annotations[index] = annotation
        recordHistoryIfNeeded(name: "Edit measurement", changed: true) { [weak self] in
            guard let self,
                  let currentIndex = self.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
            self.annotations[currentIndex] = previous
        } redo: { [weak self] in
            guard let self,
                  let currentIndex = self.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
            self.annotations[currentIndex] = annotation
        }
        statusMessage = "Updated \(annotation.displayText.isEmpty ? annotation.type.rawValue : annotation.displayText)"
        autosaveActiveStudySession()
        return true
    }

    @discardableResult
    public func deleteAnnotation(id: UUID) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else {
            statusMessage = "Measurement was not found in the active session"
            return false
        }
        let removed = annotations.remove(at: index)
        recordHistoryIfNeeded(name: "Delete measurement", changed: true) { [weak self] in
            guard let self, !self.annotations.contains(where: { $0.id == removed.id }) else { return }
            self.annotations.insert(removed, at: min(index, self.annotations.count))
        } redo: { [weak self] in
            self?.annotations.removeAll { $0.id == removed.id }
        }
        statusMessage = "Deleted \(removed.displayText.isEmpty ? removed.type.rawValue : removed.displayText)"
        autosaveActiveStudySession()
        return true
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
        autosaveActiveStudySession()
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
        autosaveActiveStudySession()
    }

    @discardableResult
    public func deleteSphericalSUVROI(id: UUID) -> Bool {
        guard let index = suvROIMeasurements.firstIndex(where: { $0.id == id }) else {
            statusMessage = "SUV ROI was not found in the active session"
            return false
        }
        let removed = suvROIMeasurements.remove(at: index)
        lastSUVROIMeasurement = suvROIMeasurements.last
        let lastAfterDelete = lastSUVROIMeasurement
        recordHistoryIfNeeded(name: "Delete SUV ROI", changed: true) { [weak self] in
            guard let self, !self.suvROIMeasurements.contains(where: { $0.id == removed.id }) else { return }
            self.suvROIMeasurements.insert(removed, at: min(index, self.suvROIMeasurements.count))
            self.lastSUVROIMeasurement = removed
        } redo: { [weak self] in
            guard let self else { return }
            self.suvROIMeasurements.removeAll { $0.id == removed.id }
            self.lastSUVROIMeasurement = lastAfterDelete
        }
        statusMessage = "Deleted SUV ROI: \(removed.compactSummary)"
        autosaveActiveStudySession()
        return true
    }

    @discardableResult
    public func addSphericalIntensityROI(at worldPoint: SIMD3<Double>,
                                         in volume: ImageVolume,
                                         radiusMM: Double? = nil) -> IntensityROIMeasurement? {
        let radius = max(0.5, radiusMM ?? suvSphereRadiusMM)
        let voxel = volume.voxelIndex(from: worldPoint)
        let center = VoxelCoordinate(z: voxel.z, y: voxel.y, x: voxel.x)
        guard let measurement = IntensityROICalculator.spherical(
            volume: volume,
            center: center,
            radiusMM: radius
        ) else {
            statusMessage = "Could not measure spherical ROI at that point"
            return nil
        }

        intensityROIMeasurements.append(measurement)
        lastIntensityROIMeasurement = measurement
        let id = measurement.id
        recordHistoryIfNeeded(name: "Intensity sphere ROI", changed: true) { [weak self] in
            guard let self else { return }
            self.intensityROIMeasurements.removeAll { $0.id == id }
            self.lastIntensityROIMeasurement = self.intensityROIMeasurements.last
        } redo: { [weak self] in
            guard let self,
                  !self.intensityROIMeasurements.contains(where: { $0.id == id }) else { return }
            self.intensityROIMeasurements.append(measurement)
            self.lastIntensityROIMeasurement = measurement
        }
        let modality = Modality.normalize(volume.modality)
        let label = modality == .CT ? "HU sphere ROI" : "\(modality.displayName) sphere ROI"
        statusMessage = "\(label): \(measurement.compactSummary)"
        autosaveActiveStudySession()
        return measurement
    }

    public func clearIntensityROIMeasurements() {
        let before = intensityROIMeasurements
        let beforeLast = lastIntensityROIMeasurement
        guard !before.isEmpty else {
            statusMessage = "No intensity ROI measurements to clear"
            return
        }
        intensityROIMeasurements.removeAll()
        lastIntensityROIMeasurement = nil
        recordHistoryIfNeeded(name: "Clear intensity ROIs", changed: true) { [weak self] in
            self?.intensityROIMeasurements = before
            self?.lastIntensityROIMeasurement = beforeLast
        } redo: { [weak self] in
            self?.intensityROIMeasurements.removeAll()
            self?.lastIntensityROIMeasurement = nil
        }
        statusMessage = "Cleared \(before.count) intensity ROI measurements"
        autosaveActiveStudySession()
    }

    @discardableResult
    public func deleteSphericalIntensityROI(id: UUID) -> Bool {
        guard let index = intensityROIMeasurements.firstIndex(where: { $0.id == id }) else {
            statusMessage = "Intensity ROI was not found in the active session"
            return false
        }
        let removed = intensityROIMeasurements.remove(at: index)
        lastIntensityROIMeasurement = intensityROIMeasurements.last
        let lastAfterDelete = lastIntensityROIMeasurement
        recordHistoryIfNeeded(name: "Delete intensity ROI", changed: true) { [weak self] in
            guard let self,
                  !self.intensityROIMeasurements.contains(where: { $0.id == removed.id }) else { return }
            self.intensityROIMeasurements.insert(removed, at: min(index, self.intensityROIMeasurements.count))
            self.lastIntensityROIMeasurement = removed
        } redo: { [weak self] in
            guard let self else { return }
            self.intensityROIMeasurements.removeAll { $0.id == removed.id }
            self.lastIntensityROIMeasurement = lastAfterDelete
        }
        statusMessage = "Deleted intensity ROI: \(removed.compactSummary)"
        autosaveActiveStudySession()
        return true
    }

    public func clearAllMeasurements() {
        let beforeAnnotations = annotations
        let beforeSUV = suvROIMeasurements
        let beforeLastSUV = lastSUVROIMeasurement
        let beforeIntensity = intensityROIMeasurements
        let beforeLastIntensity = lastIntensityROIMeasurement
        guard !beforeAnnotations.isEmpty || !beforeSUV.isEmpty || !beforeIntensity.isEmpty else {
            statusMessage = "No measurements to clear"
            return
        }

        annotations.removeAll()
        suvROIMeasurements.removeAll()
        lastSUVROIMeasurement = nil
        intensityROIMeasurements.removeAll()
        lastIntensityROIMeasurement = nil
        recordHistoryIfNeeded(name: "Clear measurements", changed: true) { [weak self] in
            guard let self else { return }
            self.annotations = beforeAnnotations
            self.suvROIMeasurements = beforeSUV
            self.lastSUVROIMeasurement = beforeLastSUV
            self.intensityROIMeasurements = beforeIntensity
            self.lastIntensityROIMeasurement = beforeLastIntensity
        } redo: { [weak self] in
            guard let self else { return }
            self.annotations.removeAll()
            self.suvROIMeasurements.removeAll()
            self.lastSUVROIMeasurement = nil
            self.intensityROIMeasurements.removeAll()
            self.lastIntensityROIMeasurement = nil
        }
        statusMessage = "Cleared measurements"
        autosaveActiveStudySession()
    }

    public func saveCurrentViewerSession(named name: String? = nil) {
        if hasGeneratedStudySessionContent {
            saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: true)
        }
        let id = ensureActiveViewerSession()
        guard let index = viewerSessions.firstIndex(where: { $0.id == id }) else { return }
        let existing = viewerSessions[index]
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = (trimmedName?.isEmpty == false ? trimmedName : nil)
            ?? existing.name
        let activeVolume = currentVolume
        let updated = makeCurrentViewerSessionRecord(
            id: existing.id,
            name: sessionName,
            createdAt: existing.createdAt,
            fallback: existing,
            activeVolume: activeVolume
        )
        viewerSessions[index] = updated
        activeViewerSessionID = updated.id
        persistViewerSessions()
        statusMessage = "Saved viewer session: \(updated.name) (\(updated.summary))"
    }

    public func newViewerSession(named name: String? = nil) {
        if !activeSessionVolumes.isEmpty || hasGeneratedStudySessionContent {
            saveCurrentViewerSession()
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = (trimmedName?.isEmpty == false ? trimmedName : nil)
            ?? "Session \(viewerSessions.count + 1)"
        let session = ViewerSessionRecord(name: sessionName)
        viewerSessions.append(session)
        activeViewerSessionID = session.id
        currentVolume = nil
        fusion = nil
        activeStudySessionKey = nil
        activeStudySessionID = nil
        studySessions = []
        segmentationRuns = []
        clearCurrentStudySessionState()
        clearSliceRenderCache()
        clearPETMIPRenderedImageCache()
        persistViewerSessions()
        statusMessage = "Started viewer session: \(session.name)"
    }

    public func openViewerSession(id: UUID) async {
        guard let session = viewerSessions.first(where: { $0.id == id }) else {
            statusMessage = "Viewer session is no longer available"
            return
        }
        if hasGeneratedStudySessionContent {
            saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: true)
        }
        activeViewerSessionID = session.id
        isLoading = true
        statusMessage = "Opening viewer session: \(session.name)..."
        var restored = 0
        var failed = 0
        for reference in session.volumes {
            if await loadViewerSessionVolume(reference) != nil {
                restored += 1
            } else {
                failed += 1
            }
        }
        isLoading = false

        let sessionVolumes = activeSessionVolumes
        let sessionIdentities = Set(sessionVolumes.map(\.sessionIdentity))
        if let pair = fusion,
           !sessionIdentities.contains(pair.baseVolume.sessionIdentity) ||
           !sessionIdentities.contains(pair.overlayVolume.sessionIdentity) {
            fusion = nil
            fusionAdjustmentTask?.cancel()
            fusionAdjustmentTask = nil
        }
        let preferred = session.activeVolumeIdentity.flatMap { identity in
            sessionVolumes.first { $0.sessionIdentity == identity }
        } ?? sessionVolumes.first
        if let preferred {
            displayVolume(preferred)
        } else {
            currentVolume = nil
            activeStudySessionKey = nil
            activeStudySessionID = nil
            studySessions = []
            segmentationRuns = []
            clearCurrentStudySessionState()
        }
        persistViewerSessions()
        let failureSuffix = failed == 0 ? "" : " · \(failed) missing"
        statusMessage = "Opened viewer session: \(session.name) (\(session.studyCount) studies, \(restored) series\(failureSuffix))"
    }

    public func deleteViewerSession(id: UUID) {
        guard let index = viewerSessions.firstIndex(where: { $0.id == id }) else { return }
        let removed = viewerSessions.remove(at: index)
        if activeViewerSessionID == id {
            activeViewerSessionID = viewerSessions.first?.id
            currentVolume = activeViewerSession?.activeVolumeIdentity.flatMap { identity in
                activeSessionVolumes.first { $0.sessionIdentity == identity }
            } ?? activeSessionVolumes.first
            if let currentVolume {
                displayVolume(currentVolume)
            } else {
                fusion = nil
                activeStudySessionKey = nil
                activeStudySessionID = nil
                studySessions = []
                segmentationRuns = []
                clearCurrentStudySessionState()
            }
        }
        persistViewerSessions()
        statusMessage = "Deleted viewer session: \(removed.name)"
    }

    @discardableResult
    public func prepareViewerSessionForPatient(patientID: String,
                                               patientName: String,
                                               suggestedName: String? = nil,
                                               seriesUID: String? = nil,
                                               volumeIdentity: String? = nil) -> UUID {
        let seed = ViewerPatientSeed(patientID: patientID,
                                     patientName: patientName,
                                     suggestedName: suggestedName)
        if let seriesUID,
           !seriesUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewerPatientSeedBySeriesUID[seriesUID] = seed
        }
        if let volumeIdentity,
           !volumeIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewerPatientSeedByVolumeIdentity[volumeIdentity] = seed
        }
        return ensureActiveViewerSession(patientID: patientID,
                                         patientName: patientName,
                                         suggestedName: suggestedName)
    }

    public func displayOpenStudy(id studyKey: String) {
        let candidates = activeSessionVolumes.filter { viewerStudyKey(for: $0) == studyKey }
        guard let volume = preferredDisplayVolume(in: candidates) else {
            statusMessage = "Study is not loaded in the active session"
            return
        }
        displayVolume(volume)
        statusMessage = "Showing study: \(volume.patientName.isEmpty ? volume.patientID : volume.patientName)"
    }

    public func closeOpenStudy(id studyKey: String) {
        let volumes = activeSessionVolumes.filter { viewerStudyKey(for: $0) == studyKey }
        guard !volumes.isEmpty else { return }
        if hasGeneratedStudySessionContent {
            saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: true)
        }
        let identities = Set(volumes.map(\.sessionIdentity))
        loadedVolumes.removeAll { identities.contains($0.sessionIdentity) }
        if let pair = fusion,
           identities.contains(pair.baseVolume.sessionIdentity) ||
           identities.contains(pair.overlayVolume.sessionIdentity) ||
           identities.contains(pair.displayedOverlay.sessionIdentity) {
            fusion = nil
            fusionAdjustmentTask?.cancel()
            fusionAdjustmentTask = nil
        }
        removeVolumeIdentitiesFromActiveViewerSession(identities)
        if currentVolume.map({ identities.contains($0.sessionIdentity) }) == true {
            if let replacement = activeSessionVolumes.first {
                displayVolume(replacement)
            } else {
                currentVolume = nil
                activeStudySessionKey = nil
                activeStudySessionID = nil
                studySessions = []
                segmentationRuns = []
                clearCurrentStudySessionState()
            }
        }
        clearSliceRenderCache()
        clearPETMIPRenderedImageCache()
        statusMessage = "Closed study with \(volumes.count) loaded series"
    }

    public func saveCurrentStudySession(named name: String? = nil) {
        saveOrUpdateCurrentStudySession(named: name, announce: true, includeLabelMaps: true)
    }

    private func saveOrUpdateCurrentStudySession(named name: String? = nil,
                                                 announce: Bool,
                                                 includeLabelMaps: Bool) {
        guard let currentVolume else {
            if announce { statusMessage = "Open a study before saving a measurement session" }
            return
        }
        let volumes = studyVolumes(anchoredAt: currentVolume)
        let key = StudySessionStore.studyKey(for: volumes)
        if activeStudySessionKey != key {
            activeStudySessionKey = key
            studySessions = []
            activeStudySessionID = nil
        }

        let existing = activeStudySession
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = (trimmedName?.isEmpty == false ? trimmedName : nil)
            ?? existing?.name
            ?? "Session \(studySessions.count + 1)"
        let session = makeCurrentStudySession(
            id: existing?.id ?? activeStudySessionID ?? UUID(),
            name: sessionName,
            createdAt: existing?.createdAt ?? Date(),
            visible: existing?.visible ?? true,
            includeLabelMaps: includeLabelMaps
        )
        upsertStudySession(session)
        activeStudySessionID = session.id
        persistStudySessions()
        if announce { statusMessage = "Saved study session: \(session.name)" }
    }

    public func newStudyMeasurementSession() {
        if hasGeneratedStudySessionContent {
            saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: true)
        }
        let session = StudyMeasurementSession(name: "Session \(studySessions.count + 1)")
        studySessions.append(session)
        activeStudySessionID = session.id
        clearCurrentStudySessionState()
        persistStudySessions()
        statusMessage = "Started \(session.name)"
    }

    public func openStudySession(id: UUID) {
        guard let session = studySessions.first(where: { $0.id == id }) else {
            statusMessage = "Study session is no longer available"
            return
        }
        if hasGeneratedStudySessionContent {
            saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: true)
        }
        applyStudySession(session)
        activeStudySessionID = session.id
        persistStudySessions()
        statusMessage = "Opened study session: \(session.name)"
    }

    public func setStudySessionVisibility(id: UUID, visible: Bool) {
        guard let index = studySessions.firstIndex(where: { $0.id == id }) else { return }
        studySessions[index].visible = visible
        studySessions[index].modifiedAt = Date()
        if id == activeStudySessionID {
            for map in labeling.labelMaps {
                map.visible = visible
            }
        }
        persistStudySessions()
        statusMessage = visible ? "Showing \(studySessions[index].name)" : "Hiding \(studySessions[index].name)"
    }

    public func deleteStudySession(id: UUID) {
        guard let index = studySessions.firstIndex(where: { $0.id == id }) else { return }
        let removed = studySessions.remove(at: index)
        if activeStudySessionID == id {
            activeStudySessionID = studySessions.first?.id
            if let next = studySessions.first {
                applyStudySession(next)
            } else {
                clearCurrentStudySessionState()
            }
        }
        persistStudySessions()
        statusMessage = "Deleted study session: \(removed.name)"
    }

    private var hasGeneratedStudySessionContent: Bool {
        !annotations.isEmpty ||
        !suvROIMeasurements.isEmpty ||
        !intensityROIMeasurements.isEmpty ||
        lastVolumeMeasurementReport != nil ||
        lastRadiomicsFeatureReport != nil ||
        !labeling.labelMaps.isEmpty
    }

    private func autosaveActiveStudySession() {
        guard activeStudySessionID != nil || hasGeneratedStudySessionContent else { return }
        saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: false)
    }

    private func makeCurrentStudySession(id: UUID,
                                         name: String,
                                         createdAt: Date,
                                         visible: Bool,
                                         includeLabelMaps: Bool = true) -> StudyMeasurementSession {
        var reports = activeStudySession?.volumeReports ?? []
        if let report = lastVolumeMeasurementReport,
           !reports.contains(where: { $0.id == report.id }) {
            reports.append(report)
        }
        var radiomicsReports = activeStudySession?.radiomicsReports ?? []
        if let report = lastRadiomicsFeatureReport,
           !radiomicsReports.contains(where: { $0.id == report.id }) {
            radiomicsReports.append(report)
        }
        let labelMaps = includeLabelMaps
            ? labeling.labelMaps.map(StudySessionLabelMap.init)
            : (activeStudySession?.labelMaps ?? [])
        return StudyMeasurementSession(
            id: id,
            name: name,
            createdAt: createdAt,
            modifiedAt: Date(),
            visible: visible,
            annotations: annotations,
            suvROIs: suvROIMeasurements,
            intensityROIs: intensityROIMeasurements,
            volumeReports: reports,
            radiomicsReports: radiomicsReports,
            labelMaps: labelMaps,
            metadata: currentGeneratedMetadata()
        )
    }

    private func upsertStudySession(_ session: StudyMeasurementSession) {
        if let index = studySessions.firstIndex(where: { $0.id == session.id }) {
            studySessions[index] = session
        } else {
            studySessions.append(session)
        }
    }

    private func applyStudySession(_ session: StudyMeasurementSession) {
        annotations = session.annotations
        suvROIMeasurements = session.suvROIs
        lastSUVROIMeasurement = session.suvROIs.last
        intensityROIMeasurements = session.intensityROIs
        lastIntensityROIMeasurement = session.intensityROIs.last
        lastVolumeMeasurementReport = session.volumeReports.last
        lastRadiomicsFeatureReport = session.radiomicsReports.last
        let maps = session.labelMaps.compactMap { try? $0.makeLabelMap() }
        labeling.replaceLabelMapsForStudySession(maps)
    }

    private func clearCurrentStudySessionState() {
        annotations.removeAll()
        suvROIMeasurements.removeAll()
        lastSUVROIMeasurement = nil
        intensityROIMeasurements.removeAll()
        lastIntensityROIMeasurement = nil
        lastVolumeMeasurementReport = nil
        lastRadiomicsFeatureReport = nil
        labeling.replaceLabelMapsForStudySession([])
    }

    private func persistStudySessions() {
        guard let currentVolume else { return }
        let volumes = studyVolumes(anchoredAt: currentVolume)
        let key = activeStudySessionKey ?? StudySessionStore.studyKey(for: volumes)
        activeStudySessionKey = key
        let bundle = StudySessionStore.makeBundleMetadata(
            studyKey: key,
            volumes: volumes,
            sessions: studySessions,
            activeSessionID: activeStudySessionID
        )
        do {
            try studySessionStore.saveBundle(bundle)
        } catch {
            statusMessage = "Study session save failed: \(error.localizedDescription)"
        }
    }

    private func loadStudySessionsIfNeeded(anchor volume: ImageVolume,
                                           force: Bool = false,
                                           persistCurrent: Bool = true) {
        let volumes = studyVolumes(anchoredAt: volume)
        let key = StudySessionStore.studyKey(for: volumes)
        guard force || activeStudySessionKey != key else { return }
        if persistCurrent && hasGeneratedStudySessionContent {
            persistStudySessions()
        }
        activeStudySessionKey = key
        do {
            if let bundle = try studySessionStore.loadBundle(studyKey: key) {
                studySessions = bundle.sessions
                activeStudySessionID = bundle.activeSessionID ?? bundle.sessions.first?.id
                if let activeStudySessionID,
                   let session = bundle.sessions.first(where: { $0.id == activeStudySessionID }) {
                    applyStudySession(session)
                    statusMessage = "Restored \(bundle.sessions.count) study session(s); active: \(session.name)"
                } else {
                    clearCurrentStudySessionState()
                    statusMessage = "Restored \(bundle.sessions.count) study session(s)"
                }
            } else {
                studySessions = []
                activeStudySessionID = nil
                clearCurrentStudySessionState()
            }
            loadSegmentationRuns(studyKey: key)
        } catch {
            studySessions = []
            activeStudySessionID = nil
            segmentationRuns = []
            statusMessage = "Study session load failed: \(error.localizedDescription)"
        }
    }

    public func refreshSegmentationRuns() {
        guard let key = activeStudySessionKey ?? currentStudyReportKey else {
            segmentationRuns = []
            statusMessage = "Load a study before refreshing segmentation runs"
            return
        }
        loadSegmentationRuns(studyKey: key)
        statusMessage = "Loaded \(segmentationRuns.count) segmentation run(s)"
    }

    @discardableResult
    public func refreshActiveSegmentationQuality() -> SegmentationQualityReport? {
        guard let map = labeling.activeLabelMap else {
            activeSegmentationQualityReport = nil
            statusMessage = "No active segmentation for QA"
            return nil
        }
        let report = segmentationQualityReport(for: map)
        activeSegmentationQualityReport = report
        statusMessage = "Segmentation QA: \(report.compactSummary)"
        return report
    }

    @discardableResult
    public func planAutoContour(templateID: String,
                                availableMONAIModels: [String] = []) -> AutoContourSession? {
        guard let template = AutoContourWorkflow.template(id: templateID) else {
            statusMessage = "Auto-contour protocol was not found"
            return nil
        }
        guard let volume = autoContourPrimaryVolume(for: template) ?? currentVolume else {
            statusMessage = "Load a CT, MR, or PET/CT study before planning auto-contours"
            return nil
        }

        let session = AutoContourWorkflow.plan(template: template,
                                               volume: volume,
                                               availableMONAIModels: availableMONAIModels)
        autoContourSession = session
        autoContourQAReport = nil
        let routeLabel = session.preferredNNUnetEntry?.displayName
            ?? session.primaryRoute?.modelName
            ?? "review checklist"
        statusMessage = "Auto-contour plan ready: \(template.shortName) via \(routeLabel)"
        return session
    }

    @discardableResult
    public func prepareAutoContourStructureSet(templateID: String? = nil) -> LabelMap? {
        let template: AutoContourProtocolTemplate?
        if let templateID {
            template = AutoContourWorkflow.template(id: templateID)
        } else {
            template = autoContourSession?.protocolTemplate
        }
        guard let template else {
            statusMessage = "Pick an auto-contour protocol first"
            return nil
        }
        guard let volume = autoContourPrimaryVolume(for: template) ?? currentVolume else {
            statusMessage = "Load a review volume before preparing auto-contours"
            return nil
        }

        let map: LabelMap
        if let active = labeling.activeLabelMap, sameGrid(volume, active) {
            map = active
        } else if let existing = labeling.labelMaps.first(where: { sameGrid(volume, $0) }) {
            labeling.activeLabelMap = existing
            map = existing
        } else {
            map = labeling.createLabelMap(for: volume,
                                          name: "\(template.shortName) AutoContour",
                                          presetSet: AutoContourWorkflow.labelPreset(for: template))
        }

        let added = AutoContourWorkflow.installMissingStructures(from: template, into: map)
        if let first = map.classes.first {
            labeling.activeClassID = first.labelID
        }
        autoContourQAReport = AutoContourWorkflow.qaReport(labelMap: map,
                                                           template: template,
                                                           referenceVolume: volume)
        if var session = autoContourSession, session.protocolTemplate.id == template.id {
            session.status = .draft
            session.qaReport = autoContourQAReport
            autoContourSession = session
        }
        statusMessage = added > 0
            ? "Prepared \(template.shortName) structure set (+\(added) class(es))"
            : "Prepared \(template.shortName) structure set"
        return map
    }

    @discardableResult
    public func refreshAutoContourQA(templateID: String? = nil) -> AutoContourQAReport? {
        guard let map = labeling.activeLabelMap else {
            autoContourQAReport = nil
            statusMessage = "No active label map for auto-contour QA"
            return nil
        }
        let template: AutoContourProtocolTemplate?
        if let templateID {
            template = AutoContourWorkflow.template(id: templateID)
        } else {
            template = autoContourSession?.protocolTemplate
        }
        guard let template else {
            statusMessage = "Pick an auto-contour protocol before running QA"
            return nil
        }
        let referenceVolume = autoContourPrimaryVolume(for: template) ?? currentVolume
        let report = AutoContourWorkflow.qaReport(labelMap: map,
                                                  template: template,
                                                  referenceVolume: referenceVolume)
        autoContourQAReport = report
        if var session = autoContourSession, session.protocolTemplate.id == template.id {
            session.qaReport = report
            session.status = report.hasBlockingFindings ? .blocked : .needsReview
            autoContourSession = session
        }
        statusMessage = "Auto-contour QA: \(report.compactSummary)"
        return report
    }

    @discardableResult
    public func completeAutoContourInference(labelMap: LabelMap,
                                             templateID: String,
                                             engine: String,
                                             backend: String,
                                             modelID: String,
                                             metadata: [String: String] = [:]) -> AutoContourQAReport? {
        guard let template = AutoContourWorkflow.template(id: templateID) else {
            statusMessage = "Auto-contour protocol was not found"
            return nil
        }
        if !labeling.labelMaps.contains(where: { $0.id == labelMap.id }) {
            labeling.labelMaps.append(labelMap)
        }
        labeling.activeLabelMap = labelMap
        AutoContourWorkflow.installMissingStructures(from: template, into: labelMap)
        labelMap.name = "\(template.shortName) AutoContour Draft"

        let referenceVolume = autoContourPrimaryVolume(for: template) ?? currentVolume
        let report = AutoContourWorkflow.qaReport(labelMap: labelMap,
                                                  template: template,
                                                  referenceVolume: referenceVolume)
        autoContourQAReport = report

        var session = autoContourSession
        if session?.protocolTemplate.id != template.id,
           let volume = referenceVolume {
            session = AutoContourWorkflow.plan(template: template, volume: volume)
        }
        if var updated = session {
            updated.status = report.hasBlockingFindings ? .blocked : .needsReview
            updated.qaReport = report
            let workflowMetadata = AutoContourWorkflow.metadata(for: updated, report: report)
            let record = recordSegmentationRun(
                labelMap: labelMap,
                name: "\(template.shortName) AutoContour Draft",
                engine: engine,
                backend: backend,
                modelID: modelID,
                metadata: metadata.merging(workflowMetadata) { explicit, _ in explicit }
            )
            updated.generatedRunID = record?.id
            autoContourSession = updated
        }
        statusMessage = "Auto-contour draft ready: \(report.compactSummary)"
        return report
    }

    @discardableResult
    public func approveAutoContourSession() -> SegmentationRunRecord? {
        guard var session = autoContourSession else {
            statusMessage = "No auto-contour session to approve"
            return nil
        }
        guard labeling.activeLabelMap != nil else {
            statusMessage = "No active auto-contour label map to approve"
            return nil
        }
        let report = autoContourQAReport ?? refreshAutoContourQA(templateID: session.protocolTemplate.id)
        guard let report else { return nil }
        guard !report.hasBlockingFindings else {
            session.status = .blocked
            session.qaReport = report
            autoContourSession = session
            statusMessage = "Auto-contour approval blocked: \(report.compactSummary)"
            return nil
        }

        session.status = .approved
        session.approvedAt = Date()
        session.qaReport = report
        let modelID = session.preferredNNUnetEntry?.datasetID
            ?? session.primaryRoute?.nnunetDatasetID
            ?? session.primaryRoute?.matchedMONAIModel
            ?? "workflow"
        let record = captureActiveSegmentationRun(
            name: "\(session.protocolTemplate.shortName) AutoContour Approved",
            engine: "Tracer AutoContour",
            backend: session.primaryRoute?.preferredEngine.displayName ?? "Protocol QA",
            modelID: modelID,
            metadata: AutoContourWorkflow.metadata(for: session, report: report)
        )
        session.generatedRunID = record?.id
        autoContourSession = session
        statusMessage = record == nil
            ? "Auto-contour approved"
            : "Auto-contour approved and saved: \(session.protocolTemplate.shortName)"
        return record
    }

    public func autoContourPrimaryVolume(for template: AutoContourProtocolTemplate) -> ImageVolume? {
        let candidates = autoContourVolumeCandidates(near: currentVolume)
        if let currentVolume,
           template.modalities.contains(Modality.normalize(currentVolume.modality)) {
            return currentVolume
        }
        for modality in template.modalities {
            if let match = candidates.first(where: { Modality.normalize($0.modality) == modality }) {
                return match
            }
        }
        return currentVolume ?? candidates.first
    }

    public func autoContourPrimaryVolume(for entry: NNUnetCatalog.Entry,
                                         template: AutoContourProtocolTemplate? = nil) -> ImageVolume? {
        let candidates = autoContourVolumeCandidates(near: currentVolume)
        if entry.multiChannel,
           let firstDescription = entry.channelDescriptions.first,
           let match = autoContourVolume(matching: firstDescription,
                                         in: candidates,
                                         excluding: []) {
            return match
        }
        if let currentVolume, Modality.normalize(currentVolume.modality) == entry.modality {
            return currentVolume
        }
        if let match = candidates.first(where: { Modality.normalize($0.modality) == entry.modality }) {
            return match
        }
        if let template {
            return autoContourPrimaryVolume(for: template)
        }
        return currentVolume ?? candidates.first
    }

    public func autoContourAuxiliaryChannels(for entry: NNUnetCatalog.Entry,
                                             primary: ImageVolume) -> [ImageVolume] {
        guard entry.requiredChannels > 1 else { return [] }
        let candidates = autoContourVolumeCandidates(near: primary)
        var selectedIdentities = Set([primary.sessionIdentity])
        var channels: [ImageVolume] = []

        for index in 1..<entry.requiredChannels {
            let description = entry.channelDescriptions.indices.contains(index)
                ? entry.channelDescriptions[index]
                : ""
            guard let match = autoContourVolume(matching: description,
                                                in: candidates,
                                                excluding: selectedIdentities) else {
                break
            }
            channels.append(match)
            selectedIdentities.insert(match.sessionIdentity)
        }
        return channels
    }

    @discardableResult
    public func refreshActivePETOncologyReview() -> PETOncologyReview? {
        guard let map = labeling.activeLabelMap else {
            activePETOncologyReview = nil
            statusMessage = "No active segmentation for PET oncology review"
            return nil
        }
        do {
            guard let review = try petOncologyReview(for: map) else {
                activePETOncologyReview = nil
                statusMessage = "No matching PET volume for oncology review"
                return nil
            }
            activePETOncologyReview = review
            statusMessage = "PET oncology review: \(review.summary)"
            return review
        } catch {
            activePETOncologyReview = nil
            statusMessage = "PET oncology review failed: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    public func runActiveBrainPETAnalysis(tracer: BrainPETTracer,
                                          tauSUVRThreshold: Double = 1.34,
                                          normalDatabase: BrainPETNormalDatabase? = nil,
                                          anatomyMode: BrainPETAnatomyMode = .petOnly) -> BrainPETReport? {
        let fallbackPET = currentVolume.flatMap {
            Modality.normalize($0.modality) == .PT ? $0 : nil
        }
        guard let pet = activePETQuantificationVolume ?? fallbackPET else {
            brainPETReport = nil
            brainPETAnatomyAwareReport = nil
            statusMessage = "Load a brain PET volume before running brain analysis"
            return nil
        }
        let atlas = activeBrainPETAtlas(for: pet) ?? createQuickBrainPETAtlas(for: pet, announce: false)
        guard let atlas else {
            brainPETReport = nil
            brainPETAnatomyAwareReport = nil
            statusMessage = "Brain PET analysis needs a PET-aligned atlas. Quick atlas creation could not find enough brain uptake."
            return nil
        }
        let configuration = BrainPETAnalysisConfiguration(
            tracer: tracer,
            tauSUVRThreshold: tauSUVRThreshold,
            normalDatabase: normalDatabase ?? matchingBrainPETNormalDatabase(for: tracer)
        )
        do {
            let anatomyReport = try BrainPETAnalysis.analyzeAnatomyAware(
                volume: pet,
                atlas: atlas,
                anatomyVolume: activeBrainPETAnatomyVolume(for: anatomyMode, pet: pet),
                requestedMode: anatomyMode,
                configuration: configuration
            )
            let report = anatomyReport.anatomyAwareReport
            brainPETReport = report
            brainPETAnatomyAwareReport = anatomyReport
            statusMessage = anatomyReport.summary
            return report
        } catch {
            brainPETReport = nil
            brainPETAnatomyAwareReport = nil
            statusMessage = "Brain PET analysis failed: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    public func runActiveNeuroQuantification(workflow: NeuroQuantWorkflowProtocol,
                                             anatomyMode: BrainPETAnatomyMode = .automatic,
                                             tauSUVRThreshold: Double? = nil,
                                             localValidation: NeuroQuantClinicalValidationResult? = nil,
                                             referenceManifest: NeuroQuantReferencePackManifest? = nil,
                                             clinicalIntake: NeuroAUCIntake? = nil,
                                             mriContext: NeuroMRIContextInput? = nil,
                                             antiAmyloidContext: NeuroAntiAmyloidTherapyContext? = nil,
                                             visualRead: NeuroVisualReadInput? = nil,
                                             movementDisorderContext: NeuroMovementDisorderContext? = nil,
                                             timelineEvents: [NeuroTimelineEvent] = [],
                                             signoff: NeuroClinicalSignoff? = nil) -> NeuroQuantWorkbenchResult? {
        let fallbackNuclear = currentVolume.flatMap { volume -> ImageVolume? in
            let modality = Modality.normalize(volume.modality)
            return modality == .PT || modality == .NM ? volume : nil
        }
        guard let nuclear = activePETQuantificationVolume ?? fallbackNuclear else {
            neuroQuantWorkbenchResult = nil
            brainPETReport = nil
            brainPETAnatomyAwareReport = nil
            statusMessage = "Load a brain PET/SPECT volume before running neuroquantification"
            return nil
        }
        let atlas = activeBrainPETAtlas(for: nuclear) ?? createQuickBrainPETAtlas(for: nuclear, announce: false)
        guard let atlas else {
            neuroQuantWorkbenchResult = nil
            brainPETReport = nil
            brainPETAnatomyAwareReport = nil
            statusMessage = "\(workflow.displayName) needs a PET/SPECT-aligned atlas. Quick atlas creation could not find enough brain uptake."
            return nil
        }
        do {
            let result = try NeuroQuantWorkbench.run(
                volume: nuclear,
                atlas: atlas,
                normalDatabase: matchingBrainPETNormalDatabase(for: workflow.tracer),
                workflow: workflow,
                anatomyVolume: activeBrainPETAnatomyVolume(for: anatomyMode, pet: nuclear),
                anatomyMode: anatomyMode,
                tauSUVRThreshold: tauSUVRThreshold,
                localValidation: localValidation,
                referenceManifest: referenceManifest,
                clinicalIntake: clinicalIntake,
                mriContext: mriContext,
                acquisitionSignature: NeuroAcquisitionSignature(
                    tracer: workflow.tracer,
                    reconstructionDescription: nuclear.seriesDescription.isEmpty ? nuclear.modality : nuclear.seriesDescription,
                    patientAge: clinicalIntake?.age ?? movementDisorderContext?.age
                ),
                antiAmyloidContext: antiAmyloidContext,
                visualRead: visualRead,
                movementDisorderContext: movementDisorderContext,
                timelineEvents: timelineEvents,
                signoff: signoff
            )
            neuroQuantWorkbenchResult = result
            brainPETReport = result.report
            brainPETAnatomyAwareReport = result.anatomyAwareReport
            statusMessage = result.structuredReport.impression
            return result
        } catch {
            neuroQuantWorkbenchResult = nil
            brainPETReport = nil
            brainPETAnatomyAwareReport = nil
            statusMessage = "Neuroquantification failed: \(error.localizedDescription)"
            return nil
        }
    }

    public func createQuickBrainPETAtlasForActivePET() -> LabelMap? {
        guard let pet = activePETQuantificationVolume else {
            statusMessage = "Load a brain PET volume before creating a quick atlas"
            return nil
        }
        return createQuickBrainPETAtlas(for: pet, announce: true)
    }

    private func activeBrainPETAtlas(for pet: ImageVolume) -> LabelMap? {
        if let active = labeling.activeLabelMap,
           active.width == pet.width,
           active.height == pet.height,
           active.depth == pet.depth {
            return active
        }
        return labeling.labelMaps.first {
            $0.width == pet.width &&
            $0.height == pet.height &&
            $0.depth == pet.depth &&
            ($0.name.localizedCaseInsensitiveContains("brain") ||
             $0.classes.contains { $0.category == .brain })
        }
    }

    private struct QuickBrainAtlasBounds {
        let minZ: Int
        let maxZ: Int
        let minY: Int
        let maxY: Int
        let minX: Int
        let maxX: Int
    }

    private func createQuickBrainPETAtlas(for pet: ImageVolume, announce: Bool) -> LabelMap? {
        let finiteMax = pet.pixels.lazy.filter(\.isFinite).max() ?? 0
        guard finiteMax > 0 else {
            if announce { statusMessage = "Quick brain atlas needs positive finite PET uptake" }
            return nil
        }
        let threshold = max(finiteMax * 0.05, 0.000001)
        guard let bounds = quickBrainBounds(in: pet, threshold: threshold) else {
            if announce { statusMessage = "Quick brain atlas could not find a brain uptake envelope" }
            return nil
        }

        let atlas = LabelMap(
            parentSeriesUID: pet.seriesUID,
            depth: pet.depth,
            height: pet.height,
            width: pet.width,
            name: "Quick Brain PET Atlas",
            classes: [
                LabelClass(labelID: 1, name: "Left temporal cortex gray", category: .brain, color: .orange, opacity: 0.35),
                LabelClass(labelID: 2, name: "Right temporal cortex gray", category: .brain, color: .blue, opacity: 0.35),
                LabelClass(labelID: 3, name: "Frontal cortex gray", category: .brain, color: .purple, opacity: 0.35),
                LabelClass(labelID: 4, name: "Parietal precuneus cortex gray", category: .brain, color: .pink, opacity: 0.35),
                LabelClass(labelID: 10, name: "Cerebellar gray", category: .brain, color: .green, opacity: 0.35),
                LabelClass(labelID: 20, name: "White matter", category: .brain, color: .gray, opacity: 0.25)
            ]
        )
        atlas.opacity = 0.28

        var voxels = atlas.voxels
        var counts: [UInt16: Int] = [:]
        fillQuickBrainRegion(labelID: 1, pet: pet, threshold: threshold, bounds: bounds,
                             x: 0.16..<0.43, y: 0.25..<0.72, z: 0.34..<0.72,
                             voxels: &voxels, counts: &counts)
        fillQuickBrainRegion(labelID: 2, pet: pet, threshold: threshold, bounds: bounds,
                             x: 0.57..<0.84, y: 0.25..<0.72, z: 0.34..<0.72,
                             voxels: &voxels, counts: &counts)
        fillQuickBrainRegion(labelID: 3, pet: pet, threshold: threshold, bounds: bounds,
                             x: 0.28..<0.72, y: 0.56..<0.90, z: 0.38..<0.78,
                             voxels: &voxels, counts: &counts)
        fillQuickBrainRegion(labelID: 4, pet: pet, threshold: threshold, bounds: bounds,
                             x: 0.30..<0.70, y: 0.34..<0.62, z: 0.58..<0.92,
                             voxels: &voxels, counts: &counts)
        fillQuickBrainRegion(labelID: 10, pet: pet, threshold: threshold, bounds: bounds,
                             x: 0.34..<0.66, y: 0.10..<0.45, z: 0.05..<0.32,
                             voxels: &voxels, counts: &counts)
        fillQuickBrainRegion(labelID: 20, pet: pet, threshold: threshold, bounds: bounds,
                             x: 0.42..<0.58, y: 0.38..<0.64, z: 0.38..<0.66,
                             voxels: &voxels, counts: &counts)

        for labelID in [UInt16(1), 2, 3, 4, 10, 20] where counts[labelID, default: 0] == 0 {
            backfillQuickBrainRegion(labelID: labelID,
                                     pet: pet,
                                     threshold: threshold,
                                     bounds: bounds,
                                     voxels: &voxels,
                                     counts: &counts)
        }

        atlas.voxels = voxels
        labeling.labelMaps.append(atlas)
        labeling.activeLabelMap = atlas
        labeling.markDirty()
        saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: true)
        statusMessage = "Created quick PET-derived brain atlas. Use a registered anatomical atlas for clinical-grade regional analysis."
        if announce {
            objectWillChange.send()
        }
        return atlas
    }

    private func quickBrainBounds(in pet: ImageVolume, threshold: Float) -> QuickBrainAtlasBounds? {
        var minZ = pet.depth, maxZ = -1
        var minY = pet.height, maxY = -1
        var minX = pet.width, maxX = -1
        for z in 0..<pet.depth {
            for y in 0..<pet.height {
                let row = z * pet.height * pet.width + y * pet.width
                for x in 0..<pet.width {
                    let value = pet.pixels[row + x]
                    guard value.isFinite, value >= threshold else { continue }
                    minZ = min(minZ, z)
                    maxZ = max(maxZ, z)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        guard maxZ >= minZ, maxY >= minY, maxX >= minX else { return nil }
        return QuickBrainAtlasBounds(minZ: minZ, maxZ: maxZ, minY: minY, maxY: maxY, minX: minX, maxX: maxX)
    }

    private func fillQuickBrainRegion(labelID: UInt16,
                                      pet: ImageVolume,
                                      threshold: Float,
                                      bounds: QuickBrainAtlasBounds,
                                      x xRange: Range<Double>,
                                      y yRange: Range<Double>,
                                      z zRange: Range<Double>,
                                      voxels: inout [UInt16],
                                      counts: inout [UInt16: Int]) {
        let spanX = max(1, bounds.maxX - bounds.minX)
        let spanY = max(1, bounds.maxY - bounds.minY)
        let spanZ = max(1, bounds.maxZ - bounds.minZ)
        for z in bounds.minZ...bounds.maxZ {
            let fz = Double(z - bounds.minZ) / Double(spanZ)
            guard zRange.contains(fz) else { continue }
            for y in bounds.minY...bounds.maxY {
                let fy = Double(y - bounds.minY) / Double(spanY)
                guard yRange.contains(fy) else { continue }
                let row = z * pet.height * pet.width + y * pet.width
                for x in bounds.minX...bounds.maxX {
                    let fx = Double(x - bounds.minX) / Double(spanX)
                    guard xRange.contains(fx) else { continue }
                    let index = row + x
                    let value = pet.pixels[index]
                    guard value.isFinite, value >= threshold else { continue }
                    voxels[index] = labelID
                    counts[labelID, default: 0] += 1
                }
            }
        }
    }

    private func backfillQuickBrainRegion(labelID: UInt16,
                                          pet: ImageVolume,
                                          threshold: Float,
                                          bounds: QuickBrainAtlasBounds,
                                          voxels: inout [UInt16],
                                          counts: inout [UInt16: Int]) {
        let centerX = (bounds.minX + bounds.maxX) / 2
        let centerY = (bounds.minY + bounds.maxY) / 2
        let centerZ = (bounds.minZ + bounds.maxZ) / 2
        let radiusX = max(1, (bounds.maxX - bounds.minX) / 12)
        let radiusY = max(1, (bounds.maxY - bounds.minY) / 12)
        let radiusZ = max(1, (bounds.maxZ - bounds.minZ) / 12)
        for z in max(bounds.minZ, centerZ - radiusZ)...min(bounds.maxZ, centerZ + radiusZ) {
            for y in max(bounds.minY, centerY - radiusY)...min(bounds.maxY, centerY + radiusY) {
                let row = z * pet.height * pet.width + y * pet.width
                for x in max(bounds.minX, centerX - radiusX)...min(bounds.maxX, centerX + radiusX) {
                    let index = row + x
                    let value = pet.pixels[index]
                    guard value.isFinite, value >= threshold * 0.5 else { continue }
                    voxels[index] = labelID
                    counts[labelID, default: 0] += 1
                }
            }
        }
    }

    public func importBrainPETNormalDatabase(from url: URL,
                                             tracer: BrainPETTracer) {
        let shouldStopAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            brainPETNormalDatabase = try BrainPETNormalDatabaseIO.loadCSV(
                from: url,
                tracer: tracer
            )
            statusMessage = "Loaded brain PET normal database: \(brainPETNormalDatabase?.name ?? "")"
        } catch {
            statusMessage = "Brain PET normal database import failed: \(error.localizedDescription)"
        }
    }

    public func clearBrainPETNormalDatabase() {
        brainPETNormalDatabase = nil
        statusMessage = "Cleared brain PET normal database"
    }

    @discardableResult
    public func captureActiveSegmentationRun(name: String? = nil,
                                             engine: String = "Manual",
                                             backend: String = "Tracer",
                                             modelID: String = "",
                                             metadata: [String: String] = [:]) -> SegmentationRunRecord? {
        guard let map = labeling.activeLabelMap else {
            statusMessage = "No active segmentation to save"
            return nil
        }
        return recordSegmentationRun(labelMap: map,
                                     name: name ?? map.name,
                                     engine: engine,
                                     backend: backend,
                                     modelID: modelID,
                                     metadata: metadata)
    }

    @discardableResult
    public func recordSegmentationRun(labelMap: LabelMap,
                                      name: String,
                                      engine: String,
                                      backend: String,
                                      modelID: String,
                                      metadata: [String: String] = [:]) -> SegmentationRunRecord? {
        let volumes = currentVolume.map { studyVolumes(anchoredAt: $0) } ?? activeSessionVolumes
        guard !volumes.isEmpty else {
            statusMessage = "Load a study before saving a segmentation run"
            return nil
        }
        let key = activeStudySessionKey ?? StudySessionStore.studyKey(for: volumes)
        activeStudySessionKey = key
        let anchor = volumes.first
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let qa = segmentationQualityReport(for: labelMap, volumes: volumes)
        activeSegmentationQualityReport = qa
        var enrichedMetadata = metadata.merging(qa.metadata()) { explicit, _ in explicit }
        if let review = try? petOncologyReview(for: labelMap) {
            activePETOncologyReview = review
            enrichedMetadata["oncology.summary"] = review.summary
            enrichedMetadata["oncology.tmtvML"] = String(format: "%.4f", review.totalMetabolicTumorVolumeML)
            enrichedMetadata["oncology.tlg"] = String(format: "%.4f", review.totalLesionGlycolysis)
            enrichedMetadata["oncology.suvMax"] = String(format: "%.4f", review.maxSUV)
            enrichedMetadata["oncology.lesionCount"] = "\(review.lesionCount)"
        }
        let record = SegmentationRunRecord(
            studyKey: key,
            studyUID: anchor?.studyUID ?? "",
            patientID: anchor?.patientID ?? "",
            patientName: anchor?.patientName ?? "",
            studyDescription: anchor?.studyDescription ?? "",
            name: cleanName.isEmpty ? labelMap.name : cleanName,
            engine: engine,
            backend: backend,
            modelID: modelID,
            sourceVolumeIdentities: volumes.map(\.sessionIdentity).sorted(),
            labelMap: StudySessionLabelMap(labelMap),
            metadata: enrichedMetadata.merging(currentGeneratedMetadata()) { explicit, _ in explicit }
        )
        segmentationRuns.removeAll { $0.id == record.id }
        segmentationRuns.insert(record, at: 0)
        persistSegmentationRuns(studyKey: key, volumes: volumes)
        statusMessage = "Saved segmentation run: \(record.name)"
        return record
    }

    @discardableResult
    public func loadSegmentationRun(id: UUID) -> Bool {
        guard let record = segmentationRuns.first(where: { $0.id == id }) else {
            statusMessage = "Segmentation run was not found"
            return false
        }
        do {
            let storedLabelMap = try segmentationRunStore.loadLabelMap(for: record)
            let map = try storedLabelMap.makeLabelMap()
            map.name = record.name
            if let existing = labeling.labelMaps.firstIndex(where: {
                $0.name == map.name &&
                $0.parentSeriesUID == map.parentSeriesUID &&
                $0.width == map.width &&
                $0.height == map.height &&
                $0.depth == map.depth
            }) {
                labeling.labelMaps[existing] = map
            } else {
                labeling.labelMaps.append(map)
            }
            labeling.activeLabelMap = map
            if let first = map.classes.first {
                labeling.activeClassID = first.labelID
            }
            saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: true)
            statusMessage = "Loaded segmentation run: \(record.name)"
            return true
        } catch {
            statusMessage = "Segmentation run load failed: \(error.localizedDescription)"
            return false
        }
    }

    public func deleteSegmentationRun(id: UUID) {
        guard let index = segmentationRuns.firstIndex(where: { $0.id == id }) else { return }
        let removed = segmentationRuns.remove(at: index)
        let volumes = currentVolume.map { studyVolumes(anchoredAt: $0) } ?? activeSessionVolumes
        let key = activeStudySessionKey ?? removed.studyKey
        segmentationRunStore.deletePayload(for: removed)
        persistSegmentationRuns(studyKey: key, volumes: volumes)
        statusMessage = "Deleted segmentation run: \(removed.name)"
    }

    private func loadSegmentationRuns(studyKey: String) {
        do {
            segmentationRuns = try segmentationRunStore.loadRecords(studyKey: studyKey)
        } catch {
            segmentationRuns = []
            statusMessage = "Segmentation registry load failed: \(error.localizedDescription)"
        }
    }

    private func persistSegmentationRuns(studyKey: String, volumes: [ImageVolume]) {
        do {
            try segmentationRunStore.saveRecords(segmentationRuns,
                                                 studyKey: studyKey,
                                                 volumes: volumes)
        } catch {
            statusMessage = "Segmentation registry save failed: \(error.localizedDescription)"
        }
    }

    private func loadViewerSessions() {
        do {
            let bundle = try viewerSessionStore.loadBundle()
            let splitSessions = splitMixedPatientViewerSessions(bundle.sessions)
            viewerSessions = splitSessions
            activeViewerSessionID = bundle.activeSessionID.flatMap { activeID in
                splitSessions.first(where: { $0.id == activeID })?.id
            } ?? splitSessions.first?.id
            if splitSessions != bundle.sessions {
                persistViewerSessions()
            }
        } catch {
            viewerSessions = []
            activeViewerSessionID = nil
            statusMessage = "Viewer session registry load failed: \(error.localizedDescription)"
        }
    }

    private func splitMixedPatientViewerSessions(_ sessions: [ViewerSessionRecord]) -> [ViewerSessionRecord] {
        sessions.flatMap { session -> [ViewerSessionRecord] in
            let patientKeys = Set(
                session.studies.compactMap { patientSessionKey(patientID: $0.patientID, patientName: $0.patientName) } +
                session.volumes.compactMap { patientSessionKey(patientID: $0.patientID, patientName: $0.patientName) }
            )
            guard patientKeys.count > 1 else { return [session] }

            var split: [ViewerSessionRecord] = []
            for (offset, key) in patientKeys.sorted().enumerated() {
                let studies = session.studies.filter {
                    patientSessionKey(patientID: $0.patientID, patientName: $0.patientName) == key
                }
                let volumes = session.volumes.filter {
                    patientSessionKey(patientID: $0.patientID, patientName: $0.patientName) == key
                }
                guard !studies.isEmpty || !volumes.isEmpty else { continue }
                let displayName = studies.first?.displayTitle
                    ?? volumes.first?.patientName
                    ?? session.name
                split.append(ViewerSessionRecord(
                    id: offset == 0 ? session.id : UUID(),
                    name: displayName.isEmpty ? "\(session.name) \(offset + 1)" : displayName,
                    createdAt: session.createdAt,
                    modifiedAt: Date(),
                    activeStudyKey: studies.first?.studyKey,
                    activeVolumeIdentity: volumes.first?.volumeIdentity,
                    studies: studies,
                    volumes: volumes,
                    metadata: session.metadata
                ))
            }
            return split.isEmpty ? [session] : split
        }
    }

    private func persistViewerSessions() {
        let bundle = ViewerSessionBundle(
            sessions: viewerSessions,
            activeSessionID: activeViewerSessionID,
            modifiedAt: Date()
        )
        do {
            try viewerSessionStore.saveBundle(bundle)
        } catch {
            statusMessage = "Viewer session save failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func ensureActiveViewerSession(for volume: ImageVolume? = nil) -> UUID {
        guard let volume else {
            if let activeViewerSessionID,
               viewerSessions.contains(where: { $0.id == activeViewerSessionID }) {
                return activeViewerSessionID
            }
            let session = ViewerSessionRecord(name: "Session \(viewerSessions.count + 1)")
            viewerSessions.append(session)
            activeViewerSessionID = session.id
            persistViewerSessions()
            return session.id
        }
        let seed = patientSeed(for: volume)
        return ensureActiveViewerSession(
            patientID: seed.patientID,
            patientName: seed.patientName,
            suggestedName: seed.suggestedName ?? defaultViewerSessionName(for: volume)
        )
    }

    @discardableResult
    private func ensureActiveViewerSession(patientID: String,
                                           patientName: String,
                                           suggestedName: String?) -> UUID {
        let incomingKey = patientSessionKey(patientID: patientID, patientName: patientName)
        if let activeViewerSessionID,
           let session = viewerSessions.first(where: { $0.id == activeViewerSessionID }) {
            let activeHasContent = !session.volumes.isEmpty || !session.studies.isEmpty
            if !activeHasContent {
                return activeViewerSessionID
            }
            if let incomingKey,
               patientSessionKey(for: session) == incomingKey {
                return activeViewerSessionID
            }
            if incomingKey == nil {
                return activeViewerSessionID
            }
        }

        if let incomingKey,
           let matching = viewerSessions.first(where: { patientSessionKey(for: $0) == incomingKey }) {
            activeViewerSessionID = matching.id
            persistViewerSessions()
            return matching.id
        }

        let session = ViewerSessionRecord(name: suggestedName ?? defaultViewerSessionName(patientID: patientID, patientName: patientName))
        viewerSessions.append(session)
        activeViewerSessionID = session.id
        persistViewerSessions()
        return session.id
    }

    private func makeCurrentViewerSessionRecord(id: UUID,
                                                name: String,
                                                createdAt: Date,
                                                fallback: ViewerSessionRecord?,
                                                activeVolume: ImageVolume?) -> ViewerSessionRecord {
        let fallbackVolumeRefs = fallback?.volumes ?? []
        let loadedRefs = activeSessionVolumes.map {
            viewerVolumeReference(for: $0)
        }
        var referencesByID = Dictionary(uniqueKeysWithValues: fallbackVolumeRefs.map { ($0.volumeIdentity, $0) })
        for reference in loadedRefs {
            referencesByID[reference.volumeIdentity] = reference
        }
        let volumeReferences = referencesByID.values.sorted {
            $0.seriesDescription.localizedStandardCompare($1.seriesDescription) == .orderedAscending
        }
        let loadedStudyReferences = makeStudyReferences(from: activeSessionVolumes)
        let studies = loadedStudyReferences.isEmpty ? (fallback?.studies ?? []) : loadedStudyReferences
        let activeStudyKey = activeVolume.map { viewerStudyKey(for: $0) } ?? fallback?.activeStudyKey
        return ViewerSessionRecord(
            id: id,
            name: name,
            createdAt: createdAt,
            modifiedAt: Date(),
            activeStudyKey: activeStudyKey,
            activeVolumeIdentity: activeVolume?.sessionIdentity ?? fallback?.activeVolumeIdentity,
            studies: studies,
            volumes: volumeReferences,
            metadata: currentGeneratedMetadata()
        )
    }

    private func addVolumeToActiveViewerSession(_ volume: ImageVolume) {
        addVolumesToActiveViewerSession([volume], activeVolume: volume)
    }

    private func addRelatedLoadedVolumesToActiveViewerSession(activating volume: ImageVolume) {
        addVolumesToActiveViewerSession(
            loadedVolumesMatchingViewerSession(of: volume),
            activeVolume: volume
        )
    }

    private func loadedVolumesMatchingViewerSession(of volume: ImageVolume) -> [ImageVolume] {
        let targetPatientKey = patientSessionKey(for: volume)
        var seen = Set<String>()
        let candidates = (loadedVolumes + [volume]).filter { candidate in
            seen.insert(candidate.sessionIdentity).inserted
        }
        return candidates
            .filter { candidate in
                if candidate.sessionIdentity == volume.sessionIdentity {
                    return true
                }
                if let targetPatientKey {
                    return patientSessionKey(for: candidate) == targetPatientKey
                }
                return patientSessionKey(for: candidate) == nil
            }
            .sorted(by: viewerVolumeSort)
    }

    private func addVolumesToActiveViewerSession(_ volumes: [ImageVolume],
                                                 activeVolume: ImageVolume) {
        let id = ensureActiveViewerSession(for: activeVolume)
        guard let index = viewerSessions.firstIndex(where: { $0.id == id }) else { return }
        var seen = Set<String>()
        let orderedVolumes = (volumes + [activeVolume]).filter { candidate in
            seen.insert(candidate.sessionIdentity).inserted
        }

        for volume in orderedVolumes {
            let seed = patientSeed(for: volume)
            viewerPatientSeedByVolumeIdentity[volume.sessionIdentity] = seed
            let reference = viewerVolumeReference(for: volume)
            if let volumeIndex = viewerSessions[index].volumes.firstIndex(where: { $0.volumeIdentity == reference.volumeIdentity }) {
                viewerSessions[index].volumes[volumeIndex] = reference
            } else {
                viewerSessions[index].volumes.append(reference)
            }
        }

        let sessionVolumes = activeSessionVolumes + orderedVolumes
        viewerSessions[index].studies = makeStudyReferences(from: sessionVolumes)
        viewerSessions[index].activeStudyKey = viewerStudyKey(for: activeVolume)
        viewerSessions[index].activeVolumeIdentity = activeVolume.sessionIdentity
        viewerSessions[index].modifiedAt = Date()
        persistViewerSessions()
    }

    private func defaultViewerSessionName(for volume: ImageVolume) -> String {
        defaultViewerSessionName(patientID: volume.patientID, patientName: volume.patientName)
    }

    private func defaultViewerSessionName(patientID: String, patientName: String) -> String {
        let patient = patientName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !patient.isEmpty { return patient }
        let patientID = patientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !patientID.isEmpty { return "Patient \(patientID)" }
        return "Session \(viewerSessions.count + 1)"
    }

    private func patientSeed(for volume: ImageVolume) -> ViewerPatientSeed {
        if let seed = viewerPatientSeedByVolumeIdentity[volume.sessionIdentity] {
            return seed
        }
        if let seed = viewerPatientSeedBySeriesUID[volume.seriesUID] {
            return seed
        }
        return ViewerPatientSeed(
            patientID: volume.patientID,
            patientName: volume.patientName,
            suggestedName: defaultViewerSessionName(for: volume)
        )
    }

    private func patientSessionKey(patientID: String, patientName: String) -> String? {
        let patientID = patientID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !patientID.isEmpty { return "id:\(patientID)" }
        let patientName = patientName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !patientName.isEmpty { return "name:\(patientName)" }
        return nil
    }

    private func patientSessionKey(for volume: ImageVolume) -> String? {
        let seed = patientSeed(for: volume)
        return patientSessionKey(patientID: seed.patientID, patientName: seed.patientName)
    }

    private func patientSessionKey(for session: ViewerSessionRecord) -> String? {
        if let study = session.studies.first {
            let patientID = study.patientID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !patientID.isEmpty { return "id:\(patientID)" }
            let patientName = study.patientName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !patientName.isEmpty { return "name:\(patientName)" }
        }
        if let volume = session.volumes.first {
            let patientID = volume.patientID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !patientID.isEmpty { return "id:\(patientID)" }
            let patientName = volume.patientName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !patientName.isEmpty { return "name:\(patientName)" }
        }
        return nil
    }

    private func updateActiveViewerSessionSelection(volume: ImageVolume) {
        guard let activeViewerSessionID,
              let index = viewerSessions.firstIndex(where: { $0.id == activeViewerSessionID }) else { return }
        viewerSessions[index].activeStudyKey = viewerStudyKey(for: volume)
        viewerSessions[index].activeVolumeIdentity = volume.sessionIdentity
        viewerSessions[index].modifiedAt = Date()
        persistViewerSessions()
    }

    private func removeVolumeIdentitiesFromActiveViewerSession(_ identities: Set<String>) {
        guard let activeViewerSessionID,
              let index = viewerSessions.firstIndex(where: { $0.id == activeViewerSessionID }) else { return }
        viewerSessions[index].volumes.removeAll { identities.contains($0.volumeIdentity) }
        viewerSessions[index].studies = makeStudyReferences(from: activeSessionVolumes)
        if let active = viewerSessions[index].activeVolumeIdentity,
           identities.contains(active) {
            viewerSessions[index].activeVolumeIdentity = activeSessionVolumes.first?.sessionIdentity
            viewerSessions[index].activeStudyKey = activeSessionVolumes.first.map { viewerStudyKey(for: $0) }
        }
        viewerSessions[index].modifiedAt = Date()
        persistViewerSessions()
    }

    private func loadViewerSessionVolume(_ reference: ViewerSessionVolumeReference) async -> ImageVolume? {
        if let existing = loadedVolumes.first(where: { $0.sessionIdentity == reference.volumeIdentity }) {
            addRelatedLoadedVolumesToActiveViewerSession(activating: existing)
            return existing
        }
        guard !reference.sourceFiles.isEmpty else { return nil }
        do {
            let volume: ImageVolume
            switch reference.kind {
            case .nifti:
                guard let path = reference.sourceFiles.first else { return nil }
                let metadata = NIfTILoadMetadata(
                    studyUID: studyUID(from: reference.studyKey),
                    patientID: reference.patientID,
                    patientName: reference.patientName,
                    seriesDescription: reference.seriesDescription,
                    studyDescription: reference.studyDescription
                )
                volume = try await Task.detached(priority: .userInitiated) {
                    try MedicalVolumeFileIO.load(URL(fileURLWithPath: path),
                                                 modalityHint: reference.modality,
                                                 metadata: metadata)
                }.value
            case .dicom:
                let paths = reference.sourceFiles
                volume = try await Task.detached(priority: .userInitiated) {
                    let files = try paths.map { try DICOMLoader.parseHeader(at: URL(fileURLWithPath: $0)) }
                    return try DICOMLoader.loadSeries(files)
                }.value
            }
            let result = addLoadedVolumeIfNeeded(volume)
            return result.volume
        } catch {
            return nil
        }
    }

    private func viewerStudyKey(for volume: ImageVolume) -> String {
        let studyUID = volume.studyUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !studyUID.isEmpty && studyUID != "NIFTI_STUDY" {
            return "study:\(studyUID)"
        }
        if let folder = volume.sourceFiles.first.map({ ($0 as NSString).deletingLastPathComponent }),
           !folder.isEmpty {
            return "folder:\(folder)"
        }
        return "volume:\(volume.sessionIdentity)"
    }

    private func studyUID(from studyKey: String) -> String {
        let prefix = "study:"
        guard studyKey.hasPrefix(prefix) else { return "" }
        return String(studyKey.dropFirst(prefix.count))
    }

    private func viewerVolumeReference(for volume: ImageVolume) -> ViewerSessionVolumeReference {
        let seed = patientSeed(for: volume)
        let isNIfTI = volume.sourceFiles.first?.hasSuffix(".nii") == true ||
            volume.sourceFiles.first?.hasSuffix(".nii.gz") == true
        return ViewerSessionVolumeReference(
            volumeIdentity: volume.sessionIdentity,
            studyKey: viewerStudyKey(for: volume),
            kind: isNIfTI ? .nifti : .dicom,
            modality: volume.modality,
            seriesDescription: volume.seriesDescription,
            studyDescription: volume.studyDescription,
            patientID: seed.patientID.isEmpty ? volume.patientID : seed.patientID,
            patientName: seed.patientName.isEmpty ? volume.patientName : seed.patientName,
            sourceFiles: volume.sourceFiles
        )
    }

    private func makeStudyReferences(from volumes: [ImageVolume]) -> [ViewerSessionStudyReference] {
        let uniqueVolumes = Dictionary(grouping: volumes, by: \.sessionIdentity)
            .compactMap { $0.value.first }
        let grouped = Dictionary(grouping: uniqueVolumes, by: viewerStudyKey(for:))
        return grouped.compactMap { key, values in
            guard let first = values.sorted(by: viewerVolumeSort).first else { return nil }
            let seed = patientSeed(for: first)
            let modalities = Array(Set(values.map { Modality.normalize($0.modality).displayName })).sorted()
            let identities = values.map(\.sessionIdentity).sorted()
            return ViewerSessionStudyReference(
                studyKey: key,
                studyUID: first.studyUID,
                patientID: seed.patientID.isEmpty ? first.patientID : seed.patientID,
                patientName: seed.patientName.isEmpty ? first.patientName : seed.patientName,
                studyDescription: first.studyDescription,
                modalities: modalities,
                volumeIdentities: identities
            )
        }
        .sorted { lhs, rhs in
            if lhs.displayTitle != rhs.displayTitle {
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
            return lhs.displaySubtitle.localizedStandardCompare(rhs.displaySubtitle) == .orderedAscending
        }
    }

    private func viewerVolumeSort(_ lhs: ImageVolume, _ rhs: ImageVolume) -> Bool {
        let lhsModality = Modality.normalize(lhs.modality).displayName
        let rhsModality = Modality.normalize(rhs.modality).displayName
        if lhsModality != rhsModality {
            return lhsModality.localizedStandardCompare(rhsModality) == .orderedAscending
        }
        return lhs.seriesDescription.localizedStandardCompare(rhs.seriesDescription) == .orderedAscending
    }

    private func preferredDisplayVolume(in volumes: [ImageVolume]) -> ImageVolume? {
        if let currentVolume,
           volumes.contains(where: { $0.sessionIdentity == currentVolume.sessionIdentity }) {
            return currentVolume
        }
        return volumes.first { Modality.normalize($0.modality) == .CT }
            ?? volumes.first { Modality.normalize($0.modality) == .MR }
            ?? volumes.first { Modality.normalize($0.modality) == .PT }
            ?? volumes.first
    }

    private func studyVolumes(anchoredAt anchor: ImageVolume) -> [ImageVolume] {
        let studyUID = anchor.studyUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !studyUID.isEmpty && studyUID != "NIFTI_STUDY" {
            let matching = activeSessionVolumes.filter { $0.studyUID == anchor.studyUID }
            return matching.isEmpty ? [anchor] : matching
        }
        if let anchorFolder = anchor.sourceFiles.first.map({ ($0 as NSString).deletingLastPathComponent }) {
            let matching = activeSessionVolumes.filter { volume in
                volume.sourceFiles.first.map { ($0 as NSString).deletingLastPathComponent } == anchorFolder
            }
            if !matching.isEmpty { return matching }
        }
        return [anchor]
    }

    private func currentGeneratedMetadata() -> [String: String] {
        var metadata: [String: String] = [:]
        if let currentVolume {
            metadata["currentSeriesUID"] = currentVolume.seriesUID
            metadata["currentModality"] = currentVolume.modality
            metadata["currentSeriesDescription"] = currentVolume.seriesDescription
        }
        metadata["suvMode"] = suvSettings.mode.rawValue
        metadata["suvScale"] = suvSettings.scaleDescription
        metadata["suvSphereRadiusMM"] = String(format: "%.3f", suvSphereRadiusMM)
        metadata["hangingGrid"] = "\(hangingGrid.columns)x\(hangingGrid.rows)"
        metadata["savedAt"] = ISO8601DateFormatter().string(from: Date())
        return metadata
    }

    public var dynamicCandidateVolumes: [ImageVolume] {
        DynamicStudyBuilder.dynamicCandidates(from: activeSessionVolumes)
    }

    @discardableResult
    public func buildDynamicStudyFromLoadedVolumes(frameDurationSeconds: Double = 1.0) -> Bool {
        guard let study = DynamicStudyBuilder.makeStudy(
            from: activeSessionVolumes,
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
        let source = fusion?.baseVolume ?? currentVolume ?? activePETQuantificationVolume
        guard let source else { return }
        ensureActiveLabelMap(for: source,
                             defaultName: defaultName,
                             className: className,
                             category: category,
                             color: color)
    }

    public func ensureActiveLabelMap(for volume: ImageVolume,
                                     defaultName: String = "Measurement Labels",
                                     className: String = "Lesion",
                                     category: LabelCategory = .lesion,
                                     color: Color = .orange) {
        let activeMatchesVolume = labeling.activeLabelMap.map {
            $0.parentSeriesUID == volume.seriesUID &&
            $0.depth == volume.depth &&
            $0.height == volume.height &&
            $0.width == volume.width
        } ?? false

        if !activeMatchesVolume {
            if let existing = labeling.labelMaps.first(where: {
                $0.parentSeriesUID == volume.seriesUID &&
                $0.depth == volume.depth &&
                $0.height == volume.height &&
                $0.width == volume.width
            }) {
                labeling.activeLabelMap = existing
            } else {
                labeling.activeLabelMap = labeling.createLabelMap(for: volume, name: defaultName)
            }
        }

        guard let map = labeling.activeLabelMap else { return }
        if map.classInfo(id: labeling.activeClassID) == nil {
            let requestedID = labeling.activeClassID == 0 ? UInt16(1) : labeling.activeClassID
            map.addClass(LabelClass(labelID: requestedID,
                                    name: className,
                                    category: category,
                                    color: color))
            labeling.activeClassID = requestedID
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

    private func applyPETOnlyWindow(window: Double, level: Double) {
        petOnlyWindow = window
        petOnlyLevel = level
    }

    private func applyPETMIPWindow(window: Double, level: Double) {
        petMIPWindow = max(0.1, window)
        petMIPLevel = max(0, level)
        clearPETMIPRenderedImageCache()
        activePETQuantificationVolume.map(startPETMIPCineWarmupForVolume)
    }

    private func normalizedPETMIPRotation(_ degrees: Double) -> Double {
        Double(PETMIPProjectionKey.quantizedRotationTenths(degrees)) / 10
    }

    private func applyPETMIPRotation(_ degrees: Double) {
        petMIPRotationDegrees = normalizedPETMIPRotation(degrees)
        petMIPCacheRevision += 1
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
            invertPETImages: invertPETImages,
            invertPETOnlyImages: invertPETOnlyImages,
            invertCTImages: invertCTImages,
            invertPETMIP: invertPETMIP,
            correctAnteriorPosteriorDisplay: correctAnteriorPosteriorDisplay,
            correctRightLeftDisplay: correctRightLeftDisplay,
            linkZoomPanAcrossPanes: linkZoomPanAcrossPanes,
            sharedViewportTransform: sharedViewportTransform,
            paneViewportTransforms: paneViewportTransforms,
            overlayOpacity: overlayOpacity,
            overlayColormap: overlayColormap,
            petOnlyColormap: petOnlyColormap,
            mipColormap: mipColormap,
            petMIPRotationDegrees: petMIPRotationDegrees,
            overlayWindow: overlayWindow,
            overlayLevel: overlayLevel,
            petOnlyWindow: petOnlyWindow,
            petOnlyLevel: petOnlyLevel,
            petMIPWindow: petMIPWindow,
            petMIPLevel: petMIPLevel,
            petMRRegistrationMode: petMRRegistrationMode,
            petMRDeformableRegistration: petMRDeformableRegistration,
            hangingGrid: hangingGrid,
            hangingPanes: hangingPanes,
            annotations: annotations,
            suvSphereRadiusMM: suvSphereRadiusMM,
            suvROIs: suvROIMeasurements,
            lastSUVROI: lastSUVROIMeasurement,
            intensityROIs: intensityROIMeasurements,
            lastIntensityROI: lastIntensityROIMeasurement,
            lastRadiomicsReport: lastRadiomicsFeatureReport,
            labelVoxels: labeling.labelMaps.reduce(into: [:]) { voxelsByMapID, map in
                voxelsByMapID[map.id] = map.voxels
            }
        )
    }

    private func applyEditableSnapshot(_ snapshot: EditableSnapshot) {
        window = snapshot.window
        level = snapshot.level
        invertColors = snapshot.invertColors
        invertPETImages = snapshot.invertPETImages
        invertPETOnlyImages = snapshot.invertPETOnlyImages
        invertCTImages = snapshot.invertCTImages
        invertPETMIP = snapshot.invertPETMIP
        correctAnteriorPosteriorDisplay = snapshot.correctAnteriorPosteriorDisplay
        correctRightLeftDisplay = snapshot.correctRightLeftDisplay
        linkZoomPanAcrossPanes = snapshot.linkZoomPanAcrossPanes
        sharedViewportTransform = snapshot.sharedViewportTransform
        paneViewportTransforms = snapshot.paneViewportTransforms
        overlayOpacity = snapshot.overlayOpacity
        overlayColormap = snapshot.overlayColormap
        petOnlyColormap = snapshot.petOnlyColormap
        mipColormap = snapshot.mipColormap
        petMIPRotationDegrees = snapshot.petMIPRotationDegrees
        petMRRegistrationMode = snapshot.petMRRegistrationMode
        petMRDeformableRegistration = snapshot.petMRDeformableRegistration
        applyPETOverlayWindow(window: snapshot.overlayWindow, level: snapshot.overlayLevel)
        applyPETOnlyWindow(window: snapshot.petOnlyWindow, level: snapshot.petOnlyLevel)
        applyPETMIPWindow(window: snapshot.petMIPWindow, level: snapshot.petMIPLevel)
        fusion?.opacity = snapshot.overlayOpacity
        fusion?.colormap = snapshot.overlayColormap
        fusion?.objectWillChange.send()
        applyHangingProtocol(grid: snapshot.hangingGrid, panes: snapshot.hangingPanes)
        annotations = snapshot.annotations
        suvSphereRadiusMM = snapshot.suvSphereRadiusMM
        suvROIMeasurements = snapshot.suvROIs
        lastSUVROIMeasurement = snapshot.lastSUVROI
        intensityROIMeasurements = snapshot.intensityROIs
        lastIntensityROIMeasurement = snapshot.lastIntensityROI
        lastRadiomicsFeatureReport = snapshot.lastRadiomicsReport
        for map in labeling.labelMaps {
            if let voxels = snapshot.labelVoxels[map.id], voxels.count == map.voxels.count {
                map.voxels = voxels
                map.objectWillChange.send()
            }
        }
        labeling.markDirty()
    }

    // MARK: - Loading

    public func loadNIfTI(url: URL,
                          autoFuse: Bool = false,
                          modalityHint: String = "",
                          metadata: NIfTILoadMetadata = NIfTILoadMetadata()) async {
        let sourcePath = MedicalVolumeFileIO.canonicalSourcePath(for: url)
        if let existing = loadedVolume(sourcePath: sourcePath) {
            displayVolume(existing)
            statusMessage = "Already loaded: \(existing.seriesDescription)"
            return
        }

        isLoading = true
        statusMessage = "Loading \(url.lastPathComponent)..."
        defer { isLoading = false }

        do {
            let effectiveMetadata = metadata.isEmpty
                ? PACSIndexBuilder.loadMetadataForNIfTI(url: url)
                : metadata
            let volume = try await Task.detached(priority: .userInitiated) {
                try MedicalVolumeFileIO.load(url, modalityHint: modalityHint, metadata: effectiveMetadata)
            }.value

            let result = addLoadedVolumeIfNeeded(volume)
            displayVolume(result.volume)
            loadStudySessionsIfNeeded(anchor: result.volume)
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
        rememberArchiveDirectory(url: url)
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
            if mrSeries.isEmpty {
                applyHangingProtocol(grid: .defaultPETCT, panes: HangingPaneConfiguration.defaultPETCT)
            } else {
                applyHangingProtocol(grid: HangingGridLayout(columns: 4, rows: 2),
                                     panes: HangingPaneConfiguration.defaultUnified)
            }
            statusMessage = mrSeries.isEmpty
                ? "Opened PET/CT study. Choose CT + PET in Fusion to fuse."
                : "Opened unified CT/MR/PET study. Choose the anatomical and PET series in Fusion to fuse."
            return
        }

        if let pair = bestPETMRSeriesPair(in: series) {
            let mrSeries = preferredMRDisplaySeries(in: series)
            for mr in mrSeries.prefix(6) {
                await openSeries(mr, autoFuse: false)
            }
            await openSeries(pair.pet, autoFuse: false)
            resetPETMRHangingProtocol()
            statusMessage = "Opened PET/MR study. Choose the MR sequence and PET series in Fusion to fuse."
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
            await openSeries(first, autoFuse: false)
        }
    }

    public func openSeries(_ series: DICOMSeries, autoFuse: Bool = false) async {
        let seriesPatientID = series.patientID.isEmpty ? (series.files.first?.patientID ?? "") : series.patientID
        let seriesPatientName = series.patientName.isEmpty ? (series.files.first?.patientName ?? "") : series.patientName
        prepareViewerSessionForPatient(patientID: seriesPatientID,
                                       patientName: seriesPatientName,
                                       suggestedName: seriesPatientName.isEmpty ? seriesPatientID : seriesPatientName,
                                       seriesUID: series.uid)
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
            loadStudySessionsIfNeeded(anchor: result.volume)
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
        let jobID = "pacs-index"
        indexCancellation.reset()
        isLoading = true
        isIndexing = true
        progress = 0
        indexProgress = nil
        statusMessage = "Indexing \(url.lastPathComponent)..."
        JobManager.shared.start(JobUpdate(operationID: jobID,
                                          kind: .pacsIndexing,
                                          title: "PACS indexing",
                                          stage: "Scanning",
                                          detail: statusMessage,
                                          progress: nil,
                                          systemImage: "externaldrive.badge.magnifyingglass",
                                          canCancel: true))
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
                JobManager.shared.heartbeat(operationID: jobID,
                                            detail: update.statusText)
                JobManager.shared.update(operationID: jobID,
                                         stage: update.phase.rawValue.capitalized,
                                         detail: update.statusText)
            }
        }

        let cancellation = indexCancellation
        let isCancelled: @Sendable () -> Bool = { cancellation.isCancelled }

        let indexWorkerLimit = ResourcePolicy.load().indexingWorkerLimit
        let scanResult = await Task.detached(priority: ResourcePolicy.load().backgroundTaskPriority) {
            PACSDirectoryIndexer.scan(url: url,
                                      progressStride: 5_000,
                                      maxWorkerCount: indexWorkerLimit,
                                      isCancelled: isCancelled,
                                      progress: progressHandler)
        }.value

        if scanResult.cancelled {
            statusMessage = "Indexing cancelled after \(scanResult.scannedFiles) files (\(scanResult.records.count) partial series discarded)"
            JobManager.shared.cancel(operationID: jobID, detail: statusMessage)
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
                    JobManager.shared.cancel(operationID: jobID, detail: statusMessage)
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
                JobManager.shared.heartbeat(operationID: jobID,
                                            detail: statusMessage,
                                            progress: records.isEmpty ? nil : Double(offset) / Double(records.count))
                await Task.yield()
            }
            indexRevision += 1
            savedArchiveRoots = archiveRootStore.rememberIndexedDirectory(url: url, records: records)
            statusMessage = "Indexed \(records.count) series from \(scanResult.scannedFiles) files | inserted \(inserted), updated \(updated), skipped \(scanResult.skippedFiles)"
            JobManager.shared.succeed(operationID: jobID, detail: statusMessage)
        } catch {
            statusMessage = "Index error: \(error.localizedDescription)"
            JobManager.shared.fail(operationID: jobID,
                                   error: JobErrorInfo(error,
                                                       code: "pacs_index_error",
                                                       recoverySuggestion: "Check directory permissions and retry indexing.",
                                                       isRetryable: true),
                                   detail: statusMessage)
        }
    }

    /// Request cancellation of the in-flight `indexDirectory(...)` scan.
    /// Safe to call from any thread. No-op when no scan is running.
    public func cancelIndexing() {
        indexCancellation.cancel()
        JobManager.shared.markCancellationRequested(operationID: "pacs-index")
    }

    // MARK: - VNA / DICOMweb

    public func reloadVNAConnections() {
        vnaConnections = vnaConnectionStore.load()
        if let activeVNAConnectionID,
           vnaConnections.contains(where: { $0.id == activeVNAConnectionID }) {
            return
        }
        activeVNAConnectionID = vnaConnections.first(where: \.isEnabled)?.id ?? vnaConnections.first?.id
    }

    @discardableResult
    public func upsertVNAConnection(id: UUID? = nil,
                                    name: String,
                                    baseURLString: String,
                                    bearerToken: String = "") -> VNAConnection? {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            statusMessage = "VNA URL is required"
            return nil
        }
        var connection = VNAConnection(
            id: id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURLString: trimmedURL,
            bearerToken: bearerToken.trimmingCharacters(in: .whitespacesAndNewlines),
            isEnabled: true
        )
        guard connection.baseURL != nil else {
            statusMessage = "Invalid VNA URL: \(baseURLString)"
            return nil
        }
        if connection.name.isEmpty {
            connection.name = connection.baseURL?.host ?? "VNA"
        }
        vnaConnections = vnaConnectionStore.upsert(connection)
        let stored = vnaConnections.first {
            $0.normalizedBaseURLString.caseInsensitiveCompare(connection.normalizedBaseURLString) == .orderedSame
        } ?? connection
        activeVNAConnectionID = stored.id
        statusMessage = "Saved VNA connection: \(stored.displayName)"
        return stored
    }

    public func selectVNAConnection(id: UUID) {
        guard vnaConnections.contains(where: { $0.id == id }) else { return }
        activeVNAConnectionID = id
        vnaStudies = []
        vnaSeriesByStudyID = [:]
        vnaLastError = nil
        if let connection = activeVNAConnection {
            statusMessage = "Selected VNA: \(connection.displayName)"
        }
    }

    public func deleteVNAConnection(id: UUID) {
        let removed = vnaConnections.first { $0.id == id }
        vnaConnections = vnaConnectionStore.remove(id: id)
        if activeVNAConnectionID == id {
            activeVNAConnectionID = vnaConnections.first(where: \.isEnabled)?.id ?? vnaConnections.first?.id
            vnaStudies = []
            vnaSeriesByStudyID = [:]
        }
        if let removed {
            statusMessage = "Removed VNA connection: \(removed.displayName)"
        }
    }

    public func searchVNAStudies(searchText: String, limit: Int = 50) async {
        guard let connection = activeVNAConnection else {
            vnaLastError = "Add a VNA connection first."
            statusMessage = "Add a VNA connection first."
            return
        }
        do {
            isVNASearching = true
            vnaLastError = nil
            statusMessage = "Searching VNA \(connection.displayName)..."
            let client = try makeDICOMwebClient(connection: connection)
            let studies = try await client.searchStudies(
                query: VNAStudyQuery(searchText: searchText, limit: limit)
            )
            vnaStudies = studies
            vnaSeriesByStudyID = [:]
            vnaConnections = vnaConnectionStore.markUsed(id: connection.id)
            activeVNAConnectionID = connection.id
            statusMessage = "VNA search found \(studies.count) studies"
        } catch {
            vnaLastError = error.localizedDescription
            statusMessage = "VNA search error: \(error.localizedDescription)"
        }
        isVNASearching = false
    }

    public func vnaSeries(for study: VNAStudy) -> [VNASeries] {
        vnaSeriesByStudyID[study.id] ?? []
    }

    public func loadVNASeries(for study: VNAStudy) async {
        guard let connection = vnaConnections.first(where: { $0.id == study.connectionID }) else {
            statusMessage = "VNA connection is no longer available"
            return
        }
        do {
            isVNASearching = true
            vnaLastError = nil
            statusMessage = "Loading VNA series for \(study.patientName.isEmpty ? study.patientID : study.patientName)..."
            let client = try makeDICOMwebClient(connection: connection)
            let series = try await client.searchSeries(study: study)
            vnaSeriesByStudyID[study.id] = series
            statusMessage = "Loaded \(series.count) remote series"
        } catch {
            vnaLastError = error.localizedDescription
            statusMessage = "VNA series error: \(error.localizedDescription)"
        }
        isVNASearching = false
    }

    public func openVNAStudy(_ study: VNAStudy) async {
        prepareViewerSessionForPatient(patientID: study.patientID,
                                       patientName: study.patientName,
                                       suggestedName: study.patientName.isEmpty ? study.patientID : study.patientName)
        if vnaSeries(for: study).isEmpty {
            await loadVNASeries(for: study)
        }
        let selectedSeries = preferredVNASeriesForStudy(study)
        guard !selectedSeries.isEmpty else {
            statusMessage = "No retrievable VNA series found for study"
            return
        }
        for series in selectedSeries {
            await openVNASeries(series, study: study, autoFuse: false)
        }
        statusMessage = "Opened VNA study: \(study.patientName.isEmpty ? study.patientID : study.patientName)"
    }

    public func openVNASeries(_ series: VNASeries,
                              study: VNAStudy,
                              autoFuse: Bool = false) async {
        guard let connection = vnaConnections.first(where: { $0.id == series.connectionID }) else {
            statusMessage = "VNA connection is no longer available"
            return
        }
        prepareViewerSessionForPatient(patientID: study.patientID,
                                       patientName: study.patientName,
                                       suggestedName: study.patientName.isEmpty ? study.patientID : study.patientName,
                                       seriesUID: series.seriesInstanceUID)
        isVNARetrieving = true
        isLoading = true
        vnaLastError = nil
        statusMessage = "Retrieving \(series.displayName) from \(connection.displayName)..."
        defer {
            isVNARetrieving = false
            isLoading = false
        }

        do {
            let client = try makeDICOMwebClient(connection: connection)
            let instances = try await client.searchInstances(studyUID: series.studyInstanceUID,
                                                             seriesUID: series.seriesInstanceUID)
            guard !instances.isEmpty else {
                throw DICOMwebClient.ClientError.emptyRetrieveResponse
            }
            let filePaths = try await retrieveVNAInstances(instances,
                                                           series: series,
                                                           connection: connection,
                                                           client: client)
            let dicomSeries = try await Task.detached(priority: .userInitiated) {
                let files = try filePaths.map { try DICOMLoader.parseHeader(at: URL(fileURLWithPath: $0)) }
                guard !files.isEmpty else {
                    throw DICOMError.invalidFile("VNA series has no readable DICOM instances")
                }
                return DICOMSeries(
                    uid: series.seriesInstanceUID,
                    modality: series.modality,
                    description: series.seriesDescription,
                    patientID: study.patientID,
                    patientName: study.patientName,
                    accessionNumber: study.accessionNumber,
                    studyUID: study.studyInstanceUID,
                    studyDescription: study.studyDescription,
                    studyDate: study.studyDate,
                    studyTime: study.studyTime,
                    referringPhysicianName: study.referringPhysicianName,
                    bodyPartExamined: series.bodyPartExamined,
                    files: files
                )
            }.value
            _ = mergeScannedSeries([dicomSeries])
            await openSeries(dicomSeries, autoFuse: autoFuse)
            statusMessage = "Opened VNA series: \(series.displayName)"
        } catch {
            vnaLastError = error.localizedDescription
            statusMessage = "VNA retrieve error: \(error.localizedDescription)"
        }
    }

    private func makeDICOMwebClient(connection: VNAConnection) throws -> DICOMwebClient {
        try DICOMwebClient(configuration: DICOMwebClient.Configuration(connection: connection))
    }

    private func retrieveVNAInstances(_ instances: [VNAInstance],
                                      series: VNASeries,
                                      connection: VNAConnection,
                                      client: DICOMwebClient) async throws -> [String] {
        var paths: [String] = []
        for (offset, instance) in instances.enumerated() {
            let cachedURL = vnaCacheStore.cachedInstanceURL(
                connectionID: connection.id,
                studyUID: series.studyInstanceUID,
                seriesUID: series.seriesInstanceUID,
                sopInstanceUID: instance.sopInstanceUID
            )
            if !FileManager.default.fileExists(atPath: cachedURL.path) {
                statusMessage = "Retrieving VNA image \(offset + 1)/\(instances.count)..."
                let data = try await client.retrieveInstance(studyUID: series.studyInstanceUID,
                                                             seriesUID: series.seriesInstanceUID,
                                                             sopInstanceUID: instance.sopInstanceUID)
                _ = try vnaCacheStore.writeInstance(data,
                                                    connectionID: connection.id,
                                                    studyUID: series.studyInstanceUID,
                                                    seriesUID: series.seriesInstanceUID,
                                                    sopInstanceUID: instance.sopInstanceUID)
            }
            paths.append(cachedURL.path)
        }
        return paths
    }

    private func preferredVNASeriesForStudy(_ study: VNAStudy) -> [VNASeries] {
        let series = vnaSeries(for: study).filter { !$0.seriesInstanceUID.isEmpty }
        let anatomical = series.filter {
            let modality = Modality.normalize($0.modality)
            return modality == .CT || modality == .MR
        }
        .max { preferredVNAAnatomicalScore($0) < preferredVNAAnatomicalScore($1) }
        let pet = series.filter { Modality.normalize($0.modality) == .PT }
            .max { preferredVNAPETScore($0) < preferredVNAPETScore($1) }

        if let anatomical, let pet {
            return anatomical.seriesInstanceUID == pet.seriesInstanceUID ? [anatomical] : [anatomical, pet]
        }
        if let primary = series.filter({ Modality.normalize($0.modality) != .SEG }).first ?? series.first {
            return [primary]
        }
        return []
    }

    private func preferredVNAAnatomicalScore(_ series: VNASeries) -> Int {
        let desc = series.seriesDescription.lowercased()
        var score = Modality.normalize(series.modality) == .CT ? 100 : 80
        if desc.contains("resampled") || desc.contains("registered") || desc.contains("ctres") {
            score += 60
        }
        if desc.contains("attenuation") || desc.contains("ac ") || desc.contains("low dose") {
            score += 20
        }
        score += min(series.instanceCount, 1_000) / 20
        return score
    }

    private func preferredVNAPETScore(_ series: VNASeries) -> Int {
        let desc = series.seriesDescription.lowercased()
        var score = 100 + min(series.instanceCount, 1_000) / 20
        if desc.contains("nac") || desc.contains("non attenuation") {
            score -= 20
        }
        if desc.contains("wb") || desc.contains("whole") {
            score += 10
        }
        return score
    }

    public func openIndexedSeries(_ entry: PACSIndexedSeriesSnapshot, autoFuse: Bool = false) async {
        prepareViewerSessionForPatient(patientID: entry.patientID,
                                       patientName: entry.patientName,
                                       suggestedName: entry.patientName.isEmpty ? entry.patientID : entry.patientName,
                                       seriesUID: entry.seriesUID)
        switch entry.kind {
        case .dicom:
            await openIndexedDICOMSeries(entry, autoFuse: autoFuse)
        case .nifti:
            let path = entry.filePaths.first ?? entry.sourcePath
            let metadata = NIfTILoadMetadata(
                studyUID: entry.studyUID,
                patientID: entry.patientID,
                patientName: entry.patientName,
                accessionNumber: entry.accessionNumber,
                studyDate: entry.studyDate,
                studyTime: entry.studyTime,
                bodyPartExamined: entry.bodyPartExamined,
                seriesDescription: entry.seriesDescription,
                studyDescription: entry.studyDescription
            )
            await loadNIfTI(url: URL(fileURLWithPath: path),
                            autoFuse: autoFuse,
                            modalityHint: entry.modality,
                            metadata: metadata)
        }
    }

    public func openWorklistStudy(_ study: PACSWorklistStudy) async {
        prepareViewerSessionForPatient(patientID: study.patientID,
                                       patientName: study.patientName,
                                       suggestedName: study.patientName.isEmpty ? study.patientID : study.patientName)
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
                resetPETMRHangingProtocol()
            } else if !preferredMRDisplaySeries(in: study.series).isEmpty {
                applyHangingProtocol(grid: HangingGridLayout(columns: 4, rows: 2),
                                     panes: HangingPaneConfiguration.defaultUnified)
            } else {
                applyHangingProtocol(grid: .defaultPETCT, panes: HangingPaneConfiguration.defaultPETCT)
            }
            let hasMRSeries = !preferredMRDisplaySeries(in: study.series).isEmpty
            let label = anatomicalModality == .MR
                ? "PET/MR"
                : (hasMRSeries ? "unified CT/MR/PET" : "PET/CT")
            statusMessage = "Opened \(label) study. Choose the series to fuse in Fusion."
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
        await openIndexedSeries(first, autoFuse: false)
        statusMessage = "Opened study: \(study.patientName.isEmpty ? study.patientID : study.patientName)"
    }

    public func loadOverlay(url: URL) async {
        let sourcePath = MedicalVolumeFileIO.canonicalSourcePath(for: url)
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
                try MedicalVolumeFileIO.load(url)
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

    public func reregisterActivePETMRFusion() async {
        guard let pair = fusion, pair.isPETMR else {
            statusMessage = "No active PET/MR fusion to re-register"
            return
        }
        await fusePETMR(base: pair.baseVolume, overlay: pair.overlayVolume)
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

    private struct PETMRFusionCandidate {
        let volume: ImageVolume
        let note: String
        let deformationQuality: DeformationFieldQuality?
        let quality: RegistrationQualitySnapshot
        let allowBrainFitInside: Bool
        let label: String
    }

    private struct PETMRFusionCandidateInput {
        let volume: ImageVolume
        let note: String
        let deformationQuality: DeformationFieldQuality?
        let label: String
        let allowBrainFitInside: Bool
    }

    private func petMRFusionCandidateScore(_ quality: RegistrationQualitySnapshot) -> Double {
        let nmi = quality.normalizedMutualInformation ?? 0
        let nmiScore = max(0, min(1, (nmi - 0.90) / 0.40))
        let overlapScore = max(0, min(1, quality.maskDice ?? 0))
        let centroid = quality.centroidResidualMM ?? 120
        let centroidScore = max(0, min(1, 1 - centroid / 70))
        let edgeScore = max(0, min(1, (quality.edgeAlignment ?? 0) / 0.35))
        var score = 0.40 * overlapScore + 0.25 * nmiScore + 0.20 * centroidScore + 0.15 * edgeScore
        switch quality.grade {
        case .pass:
            break
        case .unknown:
            score -= 0.04
        case .caution:
            score -= 0.08
        case .fail:
            score -= 0.25
        }
        score -= min(0.18, Double(quality.warnings.count) * 0.04)
        return score
    }

    private func isScannerGeometryPETMRCandidate(_ candidate: PETMRFusionCandidate) -> Bool {
        candidate.label.caseInsensitiveCompare("Scanner geometry") == .orderedSame
    }

    private func isLikelyBrainPETMRFixedVolume(_ volume: ImageVolume) -> Bool {
        guard Modality.normalize(volume.modality) == .MR else { return false }
        let extent = SIMD3<Double>(
            Double(max(1, volume.width - 1)) * volume.spacing.x,
            Double(max(1, volume.height - 1)) * volume.spacing.y,
            Double(max(1, volume.depth - 1)) * volume.spacing.z
        )
        let largest = max(extent.x, max(extent.y, extent.z))
        let smallest = min(extent.x, min(extent.y, extent.z))
        return largest <= 320 && smallest >= 80
    }

    private func isBodyWarpPETMRCandidate(_ candidate: PETMRFusionCandidate) -> Bool {
        let label = candidate.label.lowercased()
        let note = candidate.note.lowercased()
        return label.contains("body warp") ||
            label.contains("body-envelope") ||
            note.contains("body warp") ||
            note.contains("body-envelope")
    }

    private func isBrainStagedPETMRCandidate(_ candidate: PETMRFusionCandidate) -> Bool {
        let label = candidate.label.lowercased()
        let note = candidate.note.lowercased()
        return label.contains("direction-volume-anatomy") ||
            note.contains("direction → volume → anatomy") ||
            note.contains("direction-volume-anatomy")
    }

    private func isBrainSafePETMRCandidate(_ candidate: PETMRFusionCandidate) -> Bool {
        if isBodyWarpPETMRCandidate(candidate) {
            return false
        }
        let label = candidate.label.lowercased()
        let note = candidate.note.lowercased()
        return isScannerGeometryPETMRCandidate(candidate) ||
            label.contains("scanner geometry") ||
            label.contains("rigid rotation") ||
            label.contains("python mi refinement on scanner") ||
            label.contains("brainsfit on scanner") ||
            label.contains("greedy on scanner") ||
            note.contains("scanner/world geometry") ||
            note.contains("rigid rotation")
    }

    private func isExternalBrainPETMRRefinement(_ candidate: PETMRFusionCandidate) -> Bool {
        candidate.label.localizedCaseInsensitiveContains("Greedy") ||
            candidate.note.localizedCaseInsensitiveContains("Greedy") ||
            candidate.label.localizedCaseInsensitiveContains("BRAINSFit") ||
            candidate.note.localizedCaseInsensitiveContains("BRAINSFit")
    }

    private func hasStrongExternalBrainPETMRRefinement(in candidates: [PETMRFusionCandidate]) -> Bool {
        guard let geometry = candidates.first(where: isScannerGeometryPETMRCandidate) else {
            return false
        }
        return candidates.contains { candidate in
            !isScannerGeometryPETMRCandidate(candidate) &&
                isExternalBrainPETMRRefinement(candidate) &&
                petMRAutomaticMateriallyImproves(candidate, over: geometry)
        }
    }

    private func brainPETMRExternalSeeds(from candidates: [PETMRFusionCandidate]) -> [PETMRFusionCandidate] {
        var safeSeeds = candidates
            .filter(isBrainSafePETMRCandidate)
            .filter { !$0.label.localizedCaseInsensitiveContains("Python MI") }
            .filter { !$0.label.localizedCaseInsensitiveContains("BRAINSFit") }
            .filter { !$0.label.localizedCaseInsensitiveContains("Greedy") }
        var pinned: [PETMRFusionCandidate] = []
        if let geometry = safeSeeds.first(where: isScannerGeometryPETMRCandidate) {
            pinned.append(geometry)
            safeSeeds.removeAll { $0.label == geometry.label }
        }
        let ranked = safeSeeds.sorted {
            let lhsScore = petMRFusionCandidateScore($0.quality)
            let rhsScore = petMRFusionCandidateScore($1.quality)
            if abs(lhsScore - rhsScore) > 0.01 { return lhsScore > rhsScore }
            return ($0.quality.centroidResidualMM ?? .greatestFiniteMagnitude) <
                ($1.quality.centroidResidualMM ?? .greatestFiniteMagnitude)
        }
        pinned.append(contentsOf: ranked.prefix(1))
        return pinned
    }

    private func brainPETMROrientationSeeds(from candidates: [PETMRFusionCandidate]) -> [PETMRFusionCandidate] {
        var seeds: [PETMRFusionCandidate] = []
        if let geometry = candidates.first(where: isScannerGeometryPETMRCandidate) {
            seeds.append(geometry)
        }
        if let rigid = candidates.first(where: {
            $0.label.localizedCaseInsensitiveContains("Rigid rotation") &&
                !$0.label.localizedCaseInsensitiveContains("brain landmark")
        }) {
            seeds.append(rigid)
        }
        if seeds.isEmpty {
            seeds = topPETMRFusionCandidates(candidates, limit: 1)
        }

        var seen = Set<String>()
        return seeds.filter { candidate in
            let key = candidate.label
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private func petMRAutomaticComplexityPenalty(_ candidate: PETMRFusionCandidate) -> Double {
        let label = candidate.label.lowercased()
        let note = candidate.note.lowercased()
        var penalty = 0.0
        if !isScannerGeometryPETMRCandidate(candidate) {
            penalty += 0.03
        }
        if label.contains("similarity") || note.contains("similarity pixel fit") {
            penalty += 0.03
        }
        if label.contains("body warp") || note.contains("body-envelope") {
            penalty += 0.05
        }
        if label.contains("visual fit") || note.contains("brain uptake fit") {
            penalty += 0.05
        }
        if label.contains("segmentation polish") || note.contains("segmentation polish") {
            penalty += 0.03
        }
        if label.contains("brain landmark") || note.contains("brain landmark") {
            penalty += 0.03
        }
        if isBodyWarpPETMRCandidate(candidate) {
            penalty += 0.06
        }
        if isBrainStagedPETMRCandidate(candidate) {
            penalty -= 0.025
        }
        if label.contains("python mi") || note.contains("python mi") {
            penalty += 0.03
        }
        if candidate.deformationQuality != nil {
            penalty += 0.04
        }
        if candidate.quality.grade == .fail {
            penalty += 0.30
        }
        return max(0, min(0.22, penalty))
    }

    private func petMRAutomaticCandidateScore(_ candidate: PETMRFusionCandidate) -> Double {
        petMRFusionCandidateScore(candidate.quality) - petMRAutomaticComplexityPenalty(candidate)
    }

    private func bestPETMRFusionCandidate(_ candidates: [PETMRFusionCandidate]) -> PETMRFusionCandidate? {
        candidates.max { lhs, rhs in
            let lhsScore = petMRFusionCandidateScore(lhs.quality)
            let rhsScore = petMRFusionCandidateScore(rhs.quality)
            if abs(lhsScore - rhsScore) > 0.01 {
                return lhsScore < rhsScore
            }
            let lhsCentroid = lhs.quality.centroidResidualMM ?? .greatestFiniteMagnitude
            let rhsCentroid = rhs.quality.centroidResidualMM ?? .greatestFiniteMagnitude
            if abs(lhsCentroid - rhsCentroid) > 1 {
                return lhsCentroid > rhsCentroid
            }
            if (lhs.deformationQuality == nil) != (rhs.deformationQuality == nil) {
                return lhs.deformationQuality == nil
            }
            return (lhs.quality.maskDice ?? 0) < (rhs.quality.maskDice ?? 0)
        }
    }

    private func petMRAutomaticMateriallyImproves(_ candidate: PETMRFusionCandidate,
                                                  over geometry: PETMRFusionCandidate) -> Bool {
        let geometryScore = petMRFusionCandidateScore(geometry.quality)
        let candidateScore = petMRFusionCandidateScore(candidate.quality)
        let nmiGain = (candidate.quality.normalizedMutualInformation ?? -.infinity) -
            (geometry.quality.normalizedMutualInformation ?? .infinity)
        let diceGain = (candidate.quality.maskDice ?? -.infinity) -
            (geometry.quality.maskDice ?? .infinity)
        let centroidGain = (geometry.quality.centroidResidualMM ?? .infinity) -
            (candidate.quality.centroidResidualMM ?? .infinity)
        let edgeGain: Double?
        if let candidateEdge = candidate.quality.edgeAlignment,
           let geometryEdge = geometry.quality.edgeAlignment {
            edgeGain = candidateEdge - geometryEdge
        } else {
            edgeGain = nil
        }

        if candidate.quality.grade == .fail {
            return false
        }

        if geometry.quality.grade == .pass,
           (geometry.quality.centroidResidualMM ?? .infinity) <= 25,
           (geometry.quality.maskDice ?? 0) >= 0.45 {
            let precisionEdgeGain = edgeGain ?? 0
            let isMicroNudge = candidate.label.localizedCaseInsensitiveContains("QA nudge") ||
                candidate.note.localizedCaseInsensitiveContains("precision QA nudge")
            if isMicroNudge,
               candidateScore >= geometryScore - 0.025,
               nmiGain >= 0.0005,
               diceGain >= -0.006,
               centroidGain >= 0.40,
               precisionEdgeGain >= -0.002 {
                return true
            }
            if isExternalBrainPETMRRefinement(candidate),
               (candidate.quality.centroidResidualMM ?? .infinity) <= 30,
               candidateScore >= geometryScore + 0.025,
               nmiGain >= 0.025,
               diceGain >= 0.035,
               precisionEdgeGain >= 0.035 {
                return true
            }
            let isPrecisionRefinement =
                candidate.label.localizedCaseInsensitiveContains("Python MI") ||
                candidate.note.localizedCaseInsensitiveContains("Python MI") ||
                candidate.label.localizedCaseInsensitiveContains("segmentation polish") ||
                candidate.note.localizedCaseInsensitiveContains("segmentation polish") ||
                candidate.label.localizedCaseInsensitiveContains("brain landmark") ||
                candidate.note.localizedCaseInsensitiveContains("brain landmark")
            if isPrecisionRefinement,
               candidateScore >= geometryScore + 0.025,
               nmiGain >= -0.01,
               diceGain >= -0.04,
               centroidGain >= -2,
               (precisionEdgeGain >= 0.035 || centroidGain >= 2.0) {
                return true
            }
            return candidateScore >= geometryScore + 0.10 &&
                nmiGain >= 0.04 &&
                centroidGain >= 6 &&
                (edgeGain ?? 0) >= -0.03 &&
                diceGain >= -0.04
        }

        return candidateScore >= geometryScore + 0.08 ||
            (nmiGain >= 0.05 && centroidGain >= 10)
    }

    private func bestPETMRAutomaticCandidate(_ candidates: [PETMRFusionCandidate],
                                             preferBrainSafe: Bool = false)
        -> (candidate: PETMRFusionCandidate, selectionNote: String?)? {
        guard !candidates.isEmpty else { return nil }

        func rawCandidateOrdering(_ lhs: PETMRFusionCandidate, _ rhs: PETMRFusionCandidate) -> Bool {
            let lhsScore = petMRFusionCandidateScore(lhs.quality)
            let rhsScore = petMRFusionCandidateScore(rhs.quality)
            if abs(lhsScore - rhsScore) > 0.01 {
                return lhsScore < rhsScore
            }
            let lhsCentroid = lhs.quality.centroidResidualMM ?? .greatestFiniteMagnitude
            let rhsCentroid = rhs.quality.centroidResidualMM ?? .greatestFiniteMagnitude
            if abs(lhsCentroid - rhsCentroid) > 1 {
                return lhsCentroid > rhsCentroid
            }
            return petMRAutomaticComplexityPenalty(lhs) > petMRAutomaticComplexityPenalty(rhs)
        }

        guard let geometry = candidates.first(where: isScannerGeometryPETMRCandidate) else {
            guard let best = candidates.max(by: rawCandidateOrdering) else { return nil }
            return (best, nil)
        }

        func conservativeBrainCandidate() -> PETMRFusionCandidate? {
            guard preferBrainSafe else { return nil }
            let safeCandidates = candidates
                .filter(isBrainSafePETMRCandidate)
                .filter { $0.quality.grade != .fail }
            guard !safeCandidates.isEmpty else { return nil }
            return safeCandidates.max {
                let lhsScore = petMRAutomaticCandidateScore($0)
                let rhsScore = petMRAutomaticCandidateScore($1)
                if isBrainStagedPETMRCandidate($0) != isBrainStagedPETMRCandidate($1),
                   abs(lhsScore - rhsScore) <= 0.04 {
                    return !isBrainStagedPETMRCandidate($0)
                }
                if abs(lhsScore - rhsScore) > 0.01 {
                    return lhsScore < rhsScore
                }
                let lhsCentroid = $0.quality.centroidResidualMM ?? .greatestFiniteMagnitude
                let rhsCentroid = $1.quality.centroidResidualMM ?? .greatestFiniteMagnitude
                if abs(lhsCentroid - rhsCentroid) > 1 {
                    return lhsCentroid > rhsCentroid
                }
                return rawCandidateOrdering($0, $1)
            }
        }

        let materiallyBetter = candidates
            .filter { !isScannerGeometryPETMRCandidate($0) }
            .filter { petMRAutomaticMateriallyImproves($0, over: geometry) }
            .max(by: rawCandidateOrdering)
        if let materiallyBetter {
            if preferBrainSafe,
               isBodyWarpPETMRCandidate(materiallyBetter),
               let conservative = conservativeBrainCandidate(),
               conservative.quality.grade == .pass,
               (conservative.quality.normalizedMutualInformation ?? 0) >= 1.02,
               (conservative.quality.maskDice ?? 0) >= 0.45 {
                return (
                    conservative,
                    "Brain PET/MR retained the best scanner/rigid-space fit because body-envelope deformable candidates can overfit compact brain uptake despite stronger global overlap metrics."
                )
            }
            return (
                materiallyBetter,
                "Selected higher-complexity PET/MR fit because it materially improved masked MI, envelope overlap, centroid residual, or edge QA over scanner geometry."
            )
        }

        let adjustedBest = candidates.max {
            let lhsScore = petMRAutomaticCandidateScore($0)
            let rhsScore = petMRAutomaticCandidateScore($1)
            if abs(lhsScore - rhsScore) > 0.01 {
                return lhsScore < rhsScore
            }
            return rawCandidateOrdering($0, $1)
        }
        if let adjustedBest, !isScannerGeometryPETMRCandidate(adjustedBest) {
            if preferBrainSafe,
               isBodyWarpPETMRCandidate(adjustedBest),
               let conservative = conservativeBrainCandidate() {
                return (
                    conservative,
                    "Brain PET/MR retained the best scanner/rigid-space fit after conservative visual-safety scoring rejected body-envelope overfit."
                )
            }
            return (
                adjustedBest,
                "Selected the best complexity-adjusted PET/MR fit; no candidate met the stricter material-improvement threshold."
            )
        }
        return (
            geometry,
            "Scanner/world geometry retained because higher-complexity candidates did not materially improve masked MI and PET/MR centroid QA."
        )
    }

    private func evaluatePETMRFusionCandidateInputs(_ inputs: [PETMRFusionCandidateInput],
                                                    fixed mr: ImageVolume,
                                                    includeLocalPolish: Bool = true) async -> [PETMRFusionCandidate] {
        var candidates: [PETMRFusionCandidate] = []
        candidates.reserveCapacity(inputs.count * 2)
        for input in inputs {
            func appendBrainLandmarkCandidate(from volume: ImageVolume,
                                              note: String,
                                              deformationQuality: DeformationFieldQuality?,
                                              label: String,
                                              allowBrainFitInside: Bool) async {
                guard let landmark = PETMRRegistrationEngine.postResampleBrainLandmarkFit(
                    movingOnFixedGrid: volume,
                    fixed: mr
                ) else {
                    return
                }
                let landmarked = await Task.detached(priority: .userInitiated) {
                    VolumeResampler.resample(source: volume,
                                             target: mr,
                                             transform: landmark.sourceToDisplay.inverse,
                                             mode: .linear)
                }.value
                let landmarkLabel = "\(label) + brain landmark direction-volume-anatomy fit"
                let landmarkQuality = RegistrationQualityAssurance.evaluate(
                    fixed: mr,
                    movingOnFixedGrid: landmarked,
                    label: landmarkLabel
                )
                candidates.append(PETMRFusionCandidate(
                    volume: landmarked,
                    note: "\(note). Direction → volume → anatomy staged brain PET/MR fit. \(landmark.note)",
                    deformationQuality: deformationQuality,
                    quality: landmarkQuality,
                    allowBrainFitInside: allowBrainFitInside,
                    label: landmarkLabel
                ))
            }

            let quality = RegistrationQualityAssurance.evaluate(
                fixed: mr,
                movingOnFixedGrid: input.volume,
                label: input.label
            )
            candidates.append(PETMRFusionCandidate(
                volume: input.volume,
                note: input.note,
                deformationQuality: input.deformationQuality,
                quality: quality,
                allowBrainFitInside: input.allowBrainFitInside,
                label: input.label
            ))
            await appendBrainLandmarkCandidate(from: input.volume,
                                               note: input.note,
                                               deformationQuality: input.deformationQuality,
                                               label: input.label,
                                               allowBrainFitInside: true)

            guard includeLocalPolish else {
                continue
            }

            if let polish = PETMRRegistrationEngine.postResampleSegmentationPolish(movingOnFixedGrid: input.volume,
                                                                                   fixed: mr) {
                let polished = await Task.detached(priority: .userInitiated) {
                    VolumeResampler.resample(source: input.volume,
                                             target: mr,
                                             transform: polish.sourceToDisplay.inverse,
                                             mode: .linear)
                }.value
                let polishedLabel = "\(input.label) + segmentation polish"
                let polishedQuality = RegistrationQualityAssurance.evaluate(
                    fixed: mr,
                    movingOnFixedGrid: polished,
                    label: polishedLabel
                )
                candidates.append(PETMRFusionCandidate(
                    volume: polished,
                    note: "\(input.note). \(polish.note)",
                    deformationQuality: input.deformationQuality,
                    quality: polishedQuality,
                    allowBrainFitInside: true,
                    label: polishedLabel
                ))
                await appendBrainLandmarkCandidate(from: polished,
                                                   note: "\(input.note). \(polish.note)",
                                                   deformationQuality: input.deformationQuality,
                                                   label: polishedLabel,
                                                   allowBrainFitInside: true)
            }

            if let correction = PETMRRegistrationEngine.postResampleVisualFit(movingOnFixedGrid: input.volume,
                                                                              fixed: mr) {
                let corrected = await Task.detached(priority: .userInitiated) {
                    VolumeResampler.resample(source: input.volume,
                                             target: mr,
                                             transform: correction.sourceToDisplay.inverse,
                                             mode: .linear)
                }.value
                let correctedLabel = "\(input.label) + visual fit"
                let correctedQuality = RegistrationQualityAssurance.evaluate(
                    fixed: mr,
                    movingOnFixedGrid: corrected,
                    label: correctedLabel
                )
                candidates.append(PETMRFusionCandidate(
                    volume: corrected,
                    note: "\(input.note). \(correction.note)",
                    deformationQuality: input.deformationQuality,
                    quality: correctedQuality,
                    allowBrainFitInside: true,
                    label: correctedLabel
                ))

                if let polish = PETMRRegistrationEngine.postResampleSegmentationPolish(movingOnFixedGrid: corrected,
                                                                                       fixed: mr) {
                    let polished = await Task.detached(priority: .userInitiated) {
                        VolumeResampler.resample(source: corrected,
                                                 target: mr,
                                                 transform: polish.sourceToDisplay.inverse,
                                                 mode: .linear)
                    }.value
                    let polishedLabel = "\(correctedLabel) + segmentation polish"
                    let polishedQuality = RegistrationQualityAssurance.evaluate(
                        fixed: mr,
                        movingOnFixedGrid: polished,
                        label: polishedLabel
                    )
                    candidates.append(PETMRFusionCandidate(
                        volume: polished,
                        note: "\(input.note). \(correction.note). \(polish.note)",
                        deformationQuality: input.deformationQuality,
                        quality: polishedQuality,
                        allowBrainFitInside: true,
                        label: polishedLabel
                    ))
                }
            }
        }
        return candidates
    }

    private func evaluatePETMRPrecisionNudges(from candidates: [PETMRFusionCandidate],
                                              fixed mr: ImageVolume,
                                              limit: Int) async -> [PETMRFusionCandidate] {
        let seeds = topPETMRFusionCandidates(candidates, limit: limit)
            .filter { !$0.label.localizedCaseInsensitiveContains("QA nudge") }
        var nudged: [PETMRFusionCandidate] = []
        nudged.reserveCapacity(seeds.count)
        for seed in seeds {
            if let candidate = await petMRPrecisionNudgeCandidate(from: seed, fixed: mr) {
                nudged.append(candidate)
            }
        }
        return nudged
    }

    private func petMRPrecisionNudgeCandidate(from seed: PETMRFusionCandidate,
                                              fixed mr: ImageVolume) async -> PETMRFusionCandidate? {
        let baseScore = petMRFusionCandidateScore(seed.quality)
        var bestQuality = seed.quality
        var bestVolume = seed.volume
        var bestTranslation = SIMD3<Double>(0, 0, 0)
        var bestRotation = SIMD3<Double>(0, 0, 0)
        var bestScale = SIMD3<Double>(repeating: 1)

        let center = mr.worldPoint(voxel: SIMD3<Double>(
            Double(max(0, mr.width - 1)) / 2,
            Double(max(0, mr.height - 1)) / 2,
            Double(max(0, mr.depth - 1)) / 2
        ))

        func fixedAxisOffset(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> {
            mr.direction * SIMD3<Double>(x, y, z)
        }

        func correctionTransform(translation: SIMD3<Double>,
                                 rotation: SIMD3<Double>,
                                 scale: SIMD3<Double>) -> Transform3D {
            Transform3D.translation(translation.x, translation.y, translation.z)
                .concatenate(Transform3D.translation(center.x, center.y, center.z))
                .concatenate(Transform3D.rotationZ(rotation.z))
                .concatenate(Transform3D.rotationY(rotation.y))
                .concatenate(Transform3D.rotationX(rotation.x))
                .concatenate(Transform3D.scale(scale))
                .concatenate(Transform3D.translation(-center.x, -center.y, -center.z))
        }

        func shouldAdopt(_ quality: RegistrationQualitySnapshot) -> Bool {
            let scoreGain = petMRFusionCandidateScore(quality) - petMRFusionCandidateScore(bestQuality)
            let centroidGain = (bestQuality.centroidResidualMM ?? .infinity) - (quality.centroidResidualMM ?? .infinity)
            let edgeGain = (quality.edgeAlignment ?? -.infinity) - (bestQuality.edgeAlignment ?? -.infinity)
            let nmiGain = (quality.normalizedMutualInformation ?? -.infinity) - (bestQuality.normalizedMutualInformation ?? -.infinity)
            let diceGain = (quality.maskDice ?? -.infinity) - (bestQuality.maskDice ?? -.infinity)
            if quality.grade == .fail { return false }
            if scoreGain >= 0.004 { return true }
            if nmiGain >= 0.0005, centroidGain >= 0.20, edgeGain >= -0.006, diceGain >= -0.008 { return true }
            if centroidGain >= 0.75, edgeGain >= -0.015, nmiGain >= -0.010 { return true }
            if edgeGain >= 0.025, centroidGain >= -0.75, nmiGain >= -0.010 { return true }
            return false
        }

        func evaluate(translation: SIMD3<Double>,
                      rotation: SIMD3<Double>,
                      scale: SIMD3<Double>,
                      label: String) async {
            let transform = correctionTransform(translation: translation,
                                                rotation: rotation,
                                                scale: scale)
            let nudgedVolume = await Task.detached(priority: .userInitiated) {
                VolumeResampler.resample(source: seed.volume,
                                         target: mr,
                                         transform: transform.inverse,
                                         mode: .linear)
            }.value
            let quality = RegistrationQualityAssurance.evaluate(
                fixed: mr,
                movingOnFixedGrid: nudgedVolume,
                label: label
            )
            if shouldAdopt(quality) {
                bestQuality = quality
                bestVolume = nudgedVolume
                bestTranslation = translation
                bestRotation = rotation
                bestScale = scale
            }
        }

        for step in [1.5, 0.75] {
            let anchor = bestTranslation
            let offsets = [
                fixedAxisOffset(step, 0, 0),
                fixedAxisOffset(-step, 0, 0),
                fixedAxisOffset(0, step, 0),
                fixedAxisOffset(0, -step, 0),
                fixedAxisOffset(0, 0, step),
                fixedAxisOffset(0, 0, -step)
            ]
            for offset in offsets {
                await evaluate(translation: anchor + offset,
                               rotation: bestRotation,
                               scale: bestScale,
                               label: "\(seed.label) + QA nudge")
            }
        }

        if isScannerGeometryPETMRCandidate(seed) {
            let anchor = bestTranslation
            let targetedDiagonalOffsets: [SIMD3<Double>] = [
                SIMD3<Double>(-1.5, 1.5, -1.0),
                SIMD3<Double>(-1.5, 1.5, -0.5),
                SIMD3<Double>(-1.5, 1.5, 0),
                SIMD3<Double>(-1.5, 1.0, -1.0),
                SIMD3<Double>(-1.0, 1.5, -1.0),
                SIMD3<Double>(-2.0, 1.5, -1.0),
                SIMD3<Double>(-1.5, 2.0, -1.0),
                SIMD3<Double>(1.5, -1.5, 1.0),
                SIMD3<Double>(1.5, -1.5, 0.5),
                SIMD3<Double>(1.5, -1.5, 0),
                SIMD3<Double>(1.5, -1.0, 1.0),
                SIMD3<Double>(1.0, -1.5, 1.0),
                SIMD3<Double>(2.0, -1.5, 1.0),
                SIMD3<Double>(1.5, -2.0, 1.0),
                SIMD3<Double>(-0.75, 0.75, -0.5),
                SIMD3<Double>(0.75, -0.75, 0.5)
            ]
            for offset in targetedDiagonalOffsets {
                await evaluate(translation: anchor + fixedAxisOffset(offset.x, offset.y, offset.z),
                               rotation: bestRotation,
                               scale: bestScale,
                               label: "\(seed.label) + QA nudge")
            }
        }

        let finalScoreGain = petMRFusionCandidateScore(bestQuality) - baseScore
        let finalCentroidGain = (seed.quality.centroidResidualMM ?? .infinity) -
            (bestQuality.centroidResidualMM ?? .infinity)
        let finalEdgeGain = (bestQuality.edgeAlignment ?? -.infinity) -
            (seed.quality.edgeAlignment ?? -.infinity)
        let finalNMIGain = (bestQuality.normalizedMutualInformation ?? -.infinity) -
            (seed.quality.normalizedMutualInformation ?? -.infinity)
        let finalDiceGain = (bestQuality.maskDice ?? -.infinity) -
            (seed.quality.maskDice ?? -.infinity)
        guard finalScoreGain >= 0.004 ||
              (finalCentroidGain >= 0.75 && finalEdgeGain >= -0.015) ||
              (finalNMIGain >= 0.0005 && finalCentroidGain >= 0.20 && finalEdgeGain >= -0.006 && finalDiceGain >= -0.008) ||
              finalEdgeGain >= 0.025 else {
            return nil
        }

        let rotationDegrees = SIMD3<Double>(
            bestRotation.x * 180 / Double.pi,
            bestRotation.y * 180 / Double.pi,
            bestRotation.z * 180 / Double.pi
        )
        let note = String(
            format: "%@. PET/MR precision QA nudge improved local fit: shift X %.2f / Y %.2f / Z %.2f mm, rotate X %.2f° / Y %.2f° / Z %.2f°, scale %.3fx, score +%.3f.",
            seed.note,
            bestTranslation.x,
            bestTranslation.y,
            bestTranslation.z,
            rotationDegrees.x,
            rotationDegrees.y,
            rotationDegrees.z,
            (bestScale.x + bestScale.y + bestScale.z) / 3,
            finalScoreGain
        )
        return PETMRFusionCandidate(
            volume: bestVolume,
            note: note,
            deformationQuality: seed.deformationQuality,
            quality: bestQuality,
            allowBrainFitInside: seed.allowBrainFitInside,
            label: "\(seed.label) + QA nudge"
        )
    }

    private func evaluatePETMRAxialQuarterTurnCandidates(from candidates: [PETMRFusionCandidate],
                                                         fixed mr: ImageVolume,
                                                         limit: Int) async -> [PETMRFusionCandidate] {
        let seeds = topPETMRFusionCandidates(candidates, limit: limit)
            .filter { !$0.label.localizedCaseInsensitiveContains("90°") }
        var quarterTurns: [PETMRFusionCandidate] = []
        quarterTurns.reserveCapacity(seeds.count * 4)
        for seed in seeds {
            let direct = await petMRAxialQuarterTurnCandidates(from: seed, fixed: mr)
            quarterTurns += direct
            for candidate in direct {
                if let landmark = await petMRBrainLandmarkCandidate(from: candidate, fixed: mr) {
                    quarterTurns.append(landmark)
                }
            }
        }
        return quarterTurns
    }

    private func petMRAxialQuarterTurnCandidates(from seed: PETMRFusionCandidate,
                                                 fixed mr: ImageVolume) async -> [PETMRFusionCandidate] {
        let center = mr.worldPoint(voxel: SIMD3<Double>(
            Double(max(0, mr.width - 1)) / 2,
            Double(max(0, mr.height - 1)) / 2,
            Double(max(0, mr.depth - 1)) / 2
        ))
        let rotations: [(label: String, angle: Double)] = [
            ("PET 90° anti-clockwise", Double.pi / 2),
            ("PET 90° clockwise", -Double.pi / 2)
        ]
        var results: [PETMRFusionCandidate] = []
        for rotation in rotations {
            let sourceToDisplay = Transform3D.translation(center.x, center.y, center.z)
                .concatenate(Transform3D.rotationZ(rotation.angle))
                .concatenate(Transform3D.translation(-center.x, -center.y, -center.z))
            let rotated = await Task.detached(priority: .userInitiated) {
                VolumeResampler.resample(source: seed.volume,
                                         target: mr,
                                         transform: sourceToDisplay.inverse,
                                         mode: .linear)
            }.value
            let label = "\(seed.label) + \(rotation.label)"
            let quality = RegistrationQualityAssurance.evaluate(
                fixed: mr,
                movingOnFixedGrid: rotated,
                label: label
            )
            results.append(PETMRFusionCandidate(
                volume: rotated,
                note: "\(seed.note). Applied \(rotation.label) axial reorientation around the MR brain center before QA.",
                deformationQuality: seed.deformationQuality,
                quality: quality,
                allowBrainFitInside: true,
                label: label
            ))
        }
        return results.sorted {
            let lhs = petMRFusionCandidateScore($0.quality)
            let rhs = petMRFusionCandidateScore($1.quality)
            if abs(lhs - rhs) > 0.001 { return lhs > rhs }
            let lhsAntiClockwise = $0.label.localizedCaseInsensitiveContains("anti-clockwise")
            let rhsAntiClockwise = $1.label.localizedCaseInsensitiveContains("anti-clockwise")
            if lhsAntiClockwise != rhsAntiClockwise {
                return lhsAntiClockwise
            }
            return ($0.quality.centroidResidualMM ?? .greatestFiniteMagnitude) <
                ($1.quality.centroidResidualMM ?? .greatestFiniteMagnitude)
        }
    }

    private func petMRBrainLandmarkCandidate(from seed: PETMRFusionCandidate,
                                             fixed mr: ImageVolume) async -> PETMRFusionCandidate? {
        guard let landmark = PETMRRegistrationEngine.postResampleBrainLandmarkFit(
            movingOnFixedGrid: seed.volume,
            fixed: mr
        ) else {
            return nil
        }
        let landmarked = await Task.detached(priority: .userInitiated) {
            VolumeResampler.resample(source: seed.volume,
                                     target: mr,
                                     transform: landmark.sourceToDisplay.inverse,
                                     mode: .linear)
        }.value
        let label = "\(seed.label) + brain landmark direction-volume-anatomy fit"
        let quality = RegistrationQualityAssurance.evaluate(
            fixed: mr,
            movingOnFixedGrid: landmarked,
            label: label
        )
        return PETMRFusionCandidate(
            volume: landmarked,
            note: "\(seed.note). Direction → volume → anatomy staged brain PET/MR fit. \(landmark.note)",
            deformationQuality: seed.deformationQuality,
            quality: quality,
            allowBrainFitInside: true,
            label: label
        )
    }

    private func petMRGranularBrainAnatomyCandidate(from seed: PETMRFusionCandidate,
                                                    fixed mr: ImageVolume) async -> PETMRFusionCandidate? {
        guard !seed.label.localizedCaseInsensitiveContains("granular anatomy"),
              let landmark = PETMRRegistrationEngine.postResampleBrainLandmarkFit(
                movingOnFixedGrid: seed.volume,
                fixed: mr,
                minimumAnatomyGain: 0.0015
              ) else {
            return nil
        }

        let refined = await Task.detached(priority: .userInitiated) {
            VolumeResampler.resample(source: seed.volume,
                                     target: mr,
                                     transform: landmark.sourceToDisplay.inverse,
                                     mode: .linear)
        }.value
        let label = "\(seed.label) + granular anatomy match"
        let quality = RegistrationQualityAssurance.evaluate(
            fixed: mr,
            movingOnFixedGrid: refined,
            label: label
        )

        let scoreGain = petMRFusionCandidateScore(quality) - petMRFusionCandidateScore(seed.quality)
        let edgeGain = (quality.edgeAlignment ?? -.infinity) - (seed.quality.edgeAlignment ?? -.infinity)
        let nmiGain = (quality.normalizedMutualInformation ?? -.infinity) - (seed.quality.normalizedMutualInformation ?? -.infinity)
        let diceGain = (quality.maskDice ?? -.infinity) - (seed.quality.maskDice ?? -.infinity)
        let centroidGain = (seed.quality.centroidResidualMM ?? .infinity) - (quality.centroidResidualMM ?? .infinity)

        guard quality.grade != .fail,
              nmiGain >= -0.008,
              diceGain >= -0.018,
              centroidGain >= -0.75,
              scoreGain >= 0.0015 || edgeGain >= 0.012 || centroidGain >= 0.35 else {
            return nil
        }

        let note = String(
            format: "%@. Granular PET/MR anatomy match accepted after global direction/volume fit: score +%.3f, edge %+0.3f, centroid %+0.2f mm. %@",
            seed.note,
            scoreGain,
            edgeGain,
            centroidGain,
            landmark.note
        )
        return PETMRFusionCandidate(
            volume: refined,
            note: note,
            deformationQuality: seed.deformationQuality,
            quality: quality,
            allowBrainFitInside: true,
            label: label
        )
    }

    private func automaticPETMRExternalConfigurations() -> [PETMRDeformableRegistrationConfiguration] {
        var configs: [PETMRDeformableRegistrationConfiguration] = []
        let selectedPythonMI = petMRDeformableRegistration.backend == .pythonMI
        let selectedBRAINSFit = petMRDeformableRegistration.backend == .brainsFit
        let selectedGreedy = petMRDeformableRegistration.backend == .greedy
        let selectedExtraArguments = petMRDeformableRegistration.extraArguments
            .trimmingCharacters(in: .whitespacesAndNewlines)

        func appendIfReady(_ config: PETMRDeformableRegistrationConfiguration) {
            guard config.isExternalConfigured else { return }
            let executable = config.resolvedExecutable
            if executable.contains("/"),
               !FileManager.default.isExecutableFile(atPath: executable) {
                return
            }
            guard !configs.contains(where: {
                $0.backend == config.backend &&
                $0.resolvedExecutable == config.resolvedExecutable &&
                $0.extraArguments == config.extraArguments
            }) else {
                return
            }
            configs.append(config)
        }

        var pythonMI = PETMRDeformableRegistrationConfiguration(
            backend: .pythonMI,
            executablePath: selectedPythonMI ? petMRDeformableRegistration.executablePath : "",
            timeoutSeconds: min(max(petMRDeformableRegistration.timeoutSeconds, 120), 300),
            metricPreset: selectedPythonMI ? petMRDeformableRegistration.metricPreset : .multimodalMI
        )
        pythonMI.extraArguments = selectedPythonMI && !selectedExtraArguments.isEmpty
            ? selectedExtraArguments
            : "--sampling 0.05 --iterations 120 --bins 64"
        appendIfReady(pythonMI)

        if selectedBRAINSFit {
            var brainsFit = PETMRDeformableRegistrationConfiguration(
                backend: .brainsFit,
                executablePath: petMRDeformableRegistration.executablePath,
                timeoutSeconds: min(max(petMRDeformableRegistration.timeoutSeconds, 120), 300),
                metricPreset: petMRDeformableRegistration.metricPreset
            )
            brainsFit.extraArguments = selectedExtraArguments
            appendIfReady(brainsFit)
        } else {
            appendIfReady(PETMRDeformableRegistrationConfiguration(
                backend: .brainsFit,
                executablePath: PETMRDeformableBackend.brainsFit.defaultExecutableName,
                timeoutSeconds: 300,
                metricPreset: .multimodalMI
            ))
        }

        if selectedGreedy {
            var greedy = PETMRDeformableRegistrationConfiguration(
                backend: .greedy,
                executablePath: petMRDeformableRegistration.executablePath,
                timeoutSeconds: min(max(petMRDeformableRegistration.timeoutSeconds, 180), 420),
                metricPreset: petMRDeformableRegistration.metricPreset
            )
            greedy.extraArguments = selectedExtraArguments
            appendIfReady(greedy)
        } else {
            appendIfReady(PETMRDeformableRegistrationConfiguration(
                backend: .greedy,
                executablePath: PETMRDeformableBackend.greedy.defaultExecutableName,
                timeoutSeconds: 420,
                metricPreset: .multimodalMI
            ))
        }

        if petMRDeformableRegistration.isExternalConfigured,
           petMRDeformableRegistration.backend != .pythonMI,
           petMRDeformableRegistration.backend != .brainsFit,
           petMRDeformableRegistration.backend != .greedy {
            appendIfReady(petMRDeformableRegistration)
        }
        return configs
    }

    private func topPETMRFusionCandidates(_ candidates: [PETMRFusionCandidate],
                                          limit: Int) -> [PETMRFusionCandidate] {
        Array(candidates.sorted {
            let lhs = petMRFusionCandidateScore($0.quality)
            let rhs = petMRFusionCandidateScore($1.quality)
            if abs(lhs - rhs) > 0.01 { return lhs > rhs }
            return ($0.quality.centroidResidualMM ?? .greatestFiniteMagnitude) <
                ($1.quality.centroidResidualMM ?? .greatestFiniteMagnitude)
        }.prefix(limit))
    }

    private func concisePETMRAutoNote(best: PETMRFusionCandidate,
                                      candidateCount: Int,
                                      failedEngines: [String],
                                      selectionNote: String?) -> String {
        var note = String(format: "Auto PET/MR selected %@ from %d candidates (score %.2f).",
                          best.label,
                          candidateCount,
                          petMRFusionCandidateScore(best.quality))
        if let selectionNote {
            note += " \(selectionNote)"
        }
        if !failedEngines.isEmpty {
            note += " Skipped/failed: \(failedEngines.joined(separator: "; "))."
        }
        if best.note.localizedCaseInsensitiveContains("Python MI") {
            note += " Python MI refinement contributed to the selected fit."
        } else if best.note.localizedCaseInsensitiveContains("precision QA nudge") {
            note += " Precision QA nudge contributed to the selected fit."
        } else if best.note.localizedCaseInsensitiveContains("brain landmark") {
            note += " Brain cortex/cerebellum landmark fit contributed to the selected fit."
        } else if best.note.localizedCaseInsensitiveContains("segmentation polish") {
            note += " Local segmentation polish contributed to the selected fit."
        } else if best.note.localizedCaseInsensitiveContains("brain uptake fit") {
            note += " Brain uptake visual fit contributed to the selected fit."
        }
        if let optimizerNote = petMROptimizerSummary(from: best.deformationQuality?.notes ?? []) {
            note += " \(optimizerNote)."
        }
        return note
    }

    private func petMROptimizerSummary(from notes: [String]) -> String? {
        func value(prefix: String) -> String? {
            notes.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        guard let iterations = value(prefix: "optimizerIterations=") else { return nil }
        let attempt = value(prefix: "maskAttempt=").map { ", mask \($0)" } ?? ""
        return "Optimizer iterations \(iterations)\(attempt)"
    }

    private func petMRAutomaticDiagnostics(candidates: [PETMRFusionCandidate],
                                           selected: PETMRFusionCandidate,
                                           failedEngines: [String]) -> [String] {
        var lines = candidates
            .sorted {
                let lhsScore = petMRFusionCandidateScore($0.quality)
                let rhsScore = petMRFusionCandidateScore($1.quality)
                if abs(lhsScore - rhsScore) > 0.001 { return lhsScore > rhsScore }
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            .map { candidate -> String in
                let marker = candidate.label == selected.label ? "SELECTED" : "rejected"
                var metrics = [
                    String(format: "score %.2f", petMRFusionCandidateScore(candidate.quality)),
                    "QA \(candidate.quality.grade.displayName)"
                ]
                if let nmi = candidate.quality.normalizedMutualInformation {
                    metrics.append(String(format: "NMI %.3f", nmi))
                }
                if let dice = candidate.quality.maskDice {
                    metrics.append(String(format: "Dice %.2f", dice))
                }
                if let centroid = candidate.quality.centroidResidualMM {
                    metrics.append(String(format: "centroid %.1f mm", centroid))
                }
                if let edge = candidate.quality.edgeAlignment {
                    metrics.append(String(format: "edge %.2f", edge))
                }
                if let optimizer = petMROptimizerSummary(from: candidate.deformationQuality?.notes ?? []) {
                    metrics.append(optimizer)
                }
                if !candidate.quality.warnings.isEmpty {
                    metrics.append("warnings \(candidate.quality.warnings.joined(separator: ", "))")
                }
                return "\(marker): \(candidate.label) · \(metrics.joined(separator: " · "))"
            }
        lines += failedEngines.map { "failed: \($0)" }
        return lines
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
        if mode == .automaticBestFit {
            await fusePETMRAutomatic(mr: mr, pet: pet)
            return
        }
        if mode == .brainMRIDriven {
            await fusePETMRBrainMRIDriven(mr: mr, pet: pet)
            return
        }
        let alreadyAligned = hasMatchingGrid(mr, pet)
        let useGeometryOnly = alreadyAligned && mode == .geometry
        let externalDeformableConfigured = mode == .rigidThenDeformable && petMRDeformableRegistration.isExternalConfigured
        let registrationModeForInitializer: PETMRRegistrationMode
        if useGeometryOnly {
            registrationModeForInitializer = .geometry
        } else if mode == .rigidThenDeformable && !externalDeformableConfigured {
            registrationModeForInitializer = .rigidThenDeformable
        } else {
            registrationModeForInitializer = .rigidAnatomical
        }
        if !useGeometryOnly {
            statusMessage = "Pixel-matching PET to MRI..."
        }
        let registration = await Task.detached(priority: .userInitiated) {
            PETMRRegistrationEngine.estimatePETToMR(
                pet: pet,
                mr: mr,
                mode: registrationModeForInitializer
            )
        }.value

        var resampled: ImageVolume?
        var registrationNote = registration.note
        var qualityBefore: RegistrationQualitySnapshot?
        var deformationQuality: DeformationFieldQuality?
        var selectedQuality: RegistrationQualitySnapshot?
        var candidateInputs: [PETMRFusionCandidateInput] = []
        if useGeometryOnly {
            resampled = nil
            qualityBefore = RegistrationQualityAssurance.evaluate(
                fixed: mr,
                movingOnFixedGrid: pet,
                label: "Scanner geometry"
            )
        } else if externalDeformableConfigured {
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
                candidateInputs.append(PETMRFusionCandidateInput(
                    volume: deformable.warpedMoving,
                    note: registrationNote,
                    deformationQuality: deformable.deformationQuality,
                    label: "\(petMRDeformableRegistration.backend.displayName) result",
                    allowBrainFitInside: false
                ))
            } catch {
                resampled = prealigned
                registrationNote = "\(registration.note). External deformable registration failed; using rigid prealignment. \(error.localizedDescription)"
            }
        } else if mode == .rigidThenDeformable {
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
                    label: "Pixel-matched body warp"
                )
            }
            registrationNote = "\(registration.note). Configure ANTs/SynthMorph/VoxelMorph for dense deformable refinement."
            if let resampled {
                candidateInputs.append(PETMRFusionCandidateInput(
                    volume: resampled,
                    note: registrationNote,
                    deformationQuality: nil,
                    label: "Pixel-matched body warp",
                    allowBrainFitInside: false
                ))
            }
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
            if let resampled {
                candidateInputs.append(PETMRFusionCandidateInput(
                    volume: resampled,
                    note: registrationNote,
                    deformationQuality: nil,
                    label: registrationModeForInitializer.displayName,
                    allowBrainFitInside: false
                ))
            }
        }

        if candidateInputs.isEmpty, let resampled {
            candidateInputs.append(PETMRFusionCandidateInput(
                volume: resampled,
                note: registrationNote,
                deformationQuality: deformationQuality,
                label: "Fusion result",
                allowBrainFitInside: false
            ))
        }

        if !candidateInputs.isEmpty {
            var candidates = await evaluatePETMRFusionCandidateInputs(candidateInputs, fixed: mr)
            candidates += await evaluatePETMRAxialQuarterTurnCandidates(from: candidates, fixed: mr, limit: 1)
            candidates += await evaluatePETMRPrecisionNudges(from: candidates, fixed: mr, limit: 1)

            if let best = bestPETMRFusionCandidate(candidates) {
                resampled = best.volume
                registrationNote = best.note
                deformationQuality = best.deformationQuality
                selectedQuality = best.quality
                if candidates.count > 1 {
                    registrationNote += String(format: ". QA selected %@ (score %.2f)",
                                               best.label,
                                               petMRFusionCandidateScore(best.quality))
                }
            }
        }

        let pair = configureFusion(base: mr, overlay: pet, resampledOverlay: resampled)
        pair.registrationNote = registrationNote
        let qaMoving = resampled ?? pet
        let qualityAfter = selectedQuality ?? RegistrationQualityAssurance.evaluate(
            fixed: mr,
            movingOnFixedGrid: qaMoving,
            label: "Fusion result"
        )
        pair.registrationQuality = RegistrationQualityAssurance.compare(
            before: qualityBefore ?? qualityAfter,
            after: qualityAfter,
            deformation: deformationQuality,
            allowBrainPETMRFitInside: registrationNote.localizedCaseInsensitiveContains("brain uptake fit")
        )
        if !candidateInputs.isEmpty {
            pair.registrationDiagnostics = ["Manual PET/MR mode tested \(candidateInputs.count) candidate input(s). Selected: \(qualityAfter.label)"]
        }
        pair.objectWillChange.send()
        applyHangingProtocol(grid: .threeByTwo, panes: HangingPaneConfiguration.defaultPETMR)
        let qaLabel = pair.registrationQuality?.grade.displayName ?? RegistrationQualityGrade.unknown.displayName
        statusMessage = "PET/MR fused: \(registrationNote). QA \(qaLabel)"
    }

    private func fusePETMRAutomatic(mr: ImageVolume, pet: ImageVolume) async {
        let preferBrainSafe = isLikelyBrainPETMRFixedVolume(mr)
        if preferBrainSafe {
            await fusePETMRBrainMRIDriven(mr: mr,
                                          pet: pet,
                                          statusPrefix: "Auto-registering brain PET/MR")
            return
        }

        statusMessage = "Auto-registering PET/MR: testing geometry, rigid, body-fit, visual-fit, and segmentation-polish candidates..."
        var inputs: [PETMRFusionCandidateInput] = []

        let geometryVolume = hasMatchingGrid(mr, pet)
            ? pet
            : await Task.detached(priority: .userInitiated) {
                VolumeResampler.resample(overlay: pet, toMatch: mr, mode: .linear)
            }.value
        let geometryQuality = RegistrationQualityAssurance.evaluate(
            fixed: mr,
            movingOnFixedGrid: geometryVolume,
            label: "Scanner geometry"
        )
        inputs.append(PETMRFusionCandidateInput(
            volume: geometryVolume,
            note: "Scanner/world geometry PET/MR candidate.",
            deformationQuality: nil,
            label: "Scanner geometry",
            allowBrainFitInside: false
        ))

        if hasMatchingGrid(mr, pet) {
            let pair = configureFusion(base: mr, overlay: pet, resampledOverlay: nil)
            pair.registrationNote = "Auto PET/MR retained scanner/world geometry because PET and MRI grids already match."
            pair.registrationDiagnostics = [
                "PET/MR automatic registration skipped higher-complexity candidates for an already matching PET/MR grid."
            ]
            pair.registrationQuality = RegistrationQualityAssurance.compare(
                before: geometryQuality,
                after: geometryQuality,
                deformation: nil,
                allowBrainPETMRFitInside: false
            )
            pair.objectWillChange.send()
            applyHangingProtocol(grid: .threeByTwo, panes: HangingPaneConfiguration.defaultPETMR)
            let qaLabel = pair.registrationQuality?.grade.displayName ?? RegistrationQualityGrade.unknown.displayName
            statusMessage = "PET/MR auto registration retained scanner geometry. QA \(qaLabel)"
            return
        }

        for candidateMode in [PETMRRegistrationMode.rigidAnatomical, .rigidThenDeformable] {
            statusMessage = "Auto-registering PET/MR: testing \(candidateMode.displayName)..."
            let registration = await Task.detached(priority: .userInitiated) {
                PETMRRegistrationEngine.estimatePETToMR(
                    pet: pet,
                    mr: mr,
                    mode: candidateMode
                )
            }.value
            let resampled = await Task.detached(priority: .userInitiated) {
                VolumeResampler.resample(source: pet,
                                         target: mr,
                                         transform: registration.fixedToMoving,
                                         mode: .linear)
            }.value
            inputs.append(PETMRFusionCandidateInput(
                volume: resampled,
                note: registration.note,
                deformationQuality: nil,
                label: candidateMode.displayName,
                allowBrainFitInside: false
            ))
        }

        var candidates = await evaluatePETMRFusionCandidateInputs(inputs,
                                                                  fixed: mr,
                                                                  includeLocalPolish: false)
        if preferBrainSafe {
            for seed in brainPETMROrientationSeeds(from: candidates) {
                let direct = await petMRAxialQuarterTurnCandidates(from: seed, fixed: mr)
                candidates += direct
                for candidate in direct {
                    if let landmark = await petMRBrainLandmarkCandidate(from: candidate, fixed: mr) {
                        candidates.append(landmark)
                    }
                }
            }
        } else {
            candidates += await evaluatePETMRAxialQuarterTurnCandidates(from: candidates, fixed: mr, limit: 1)
        }
        var failedEngines: [String] = []
        let externalConfigs = automaticPETMRExternalConfigurations()
        if !externalConfigs.isEmpty {
            let brainSeeds = preferBrainSafe ? brainPETMRExternalSeeds(from: candidates) : []
            let seeds = brainSeeds.isEmpty ? topPETMRFusionCandidates(candidates, limit: 1) : brainSeeds
            for config in externalConfigs {
                for seed in seeds {
                    statusMessage = "Auto-registering PET/MR: refining \(seed.label) with \(config.backend.displayName)..."
                    do {
                        let deformable = try await PETMRDeformableRegistrationRunner.register(
                            fixed: mr,
                            movingPrealigned: seed.volume,
                            configuration: config
                        )
                        let externalInputs = [PETMRFusionCandidateInput(
                            volume: deformable.warpedMoving,
                            note: "\(seed.note). \(config.backend.displayName) refined \(seed.label). \(deformable.note)",
                            deformationQuality: deformable.deformationQuality,
                            label: "\(config.backend.displayName) on \(seed.label)",
                            allowBrainFitInside: seed.allowBrainFitInside
                        )]
                        candidates += await evaluatePETMRFusionCandidateInputs(externalInputs,
                                                                               fixed: mr,
                                                                               includeLocalPolish: false)
                    } catch {
                        failedEngines.append("\(config.backend.displayName) on \(seed.label): \(error.localizedDescription)")
                    }
                }
            }
        }
        if preferBrainSafe && !hasStrongExternalBrainPETMRRefinement(in: candidates) {
            for seed in brainPETMRExternalSeeds(from: candidates) {
                if let nudged = await petMRPrecisionNudgeCandidate(from: seed, fixed: mr) {
                    candidates.append(nudged)
                }
            }
        } else {
            candidates += await evaluatePETMRPrecisionNudges(from: candidates, fixed: mr, limit: 1)
        }

        guard let selection = bestPETMRAutomaticCandidate(candidates,
                                                          preferBrainSafe: preferBrainSafe) else {
            configureFusion(base: mr, overlay: pet, resampledOverlay: nil)
            statusMessage = "PET/MR auto registration failed: no candidate could be scored"
            return
        }
        let best = selection.candidate

        let pair = configureFusion(base: mr, overlay: pet, resampledOverlay: best.volume)
        pair.registrationNote = concisePETMRAutoNote(best: best,
                                                     candidateCount: candidates.count,
                                                     failedEngines: failedEngines,
                                                     selectionNote: selection.selectionNote)
        pair.registrationDiagnostics = petMRAutomaticDiagnostics(candidates: candidates,
                                                                 selected: best,
                                                                 failedEngines: failedEngines)
        pair.registrationQuality = RegistrationQualityAssurance.compare(
            before: geometryQuality,
            after: best.quality,
            deformation: best.deformationQuality,
            allowBrainPETMRFitInside: best.allowBrainFitInside
        )
        pair.objectWillChange.send()
        applyHangingProtocol(grid: .threeByTwo, panes: HangingPaneConfiguration.defaultPETMR)
        let qaLabel = pair.registrationQuality?.grade.displayName ?? RegistrationQualityGrade.unknown.displayName
        statusMessage = "PET/MR auto registration selected \(best.label). QA \(qaLabel)"
    }

    private func fusePETMRBrainMRIDriven(mr: ImageVolume,
                                         pet: ImageVolume,
                                         statusPrefix: String = "Brain MRI-driven PET/MR registration") async {
        statusMessage = "\(statusPrefix): testing scanner geometry, rigid MRI-space alignment, orientation, and precision refinements..."
        var inputs: [PETMRFusionCandidateInput] = []

        let geometryVolume = hasMatchingGrid(mr, pet)
            ? pet
            : await Task.detached(priority: .userInitiated) {
                VolumeResampler.resample(overlay: pet, toMatch: mr, mode: .linear)
            }.value
        let geometryQuality = RegistrationQualityAssurance.evaluate(
            fixed: mr,
            movingOnFixedGrid: geometryVolume,
            label: "Scanner geometry"
        )
        inputs.append(PETMRFusionCandidateInput(
            volume: geometryVolume,
            note: "Scanner/world geometry brain PET/MR candidate. MRI anatomy is the registration authority.",
            deformationQuality: nil,
            label: "Scanner geometry",
            allowBrainFitInside: false
        ))

        statusMessage = "\(statusPrefix): testing rigid MRI-anatomy candidate..."
        let rigidRegistration = await Task.detached(priority: .userInitiated) {
            PETMRRegistrationEngine.estimatePETToMR(
                pet: pet,
                mr: mr,
                mode: .rigidAnatomical
            )
        }.value
        let rigidVolume = await Task.detached(priority: .userInitiated) {
            VolumeResampler.resample(source: pet,
                                     target: mr,
                                     transform: rigidRegistration.fixedToMoving,
                                     mode: .linear)
        }.value
        inputs.append(PETMRFusionCandidateInput(
            volume: rigidVolume,
            note: rigidRegistration.note,
            deformationQuality: nil,
            label: PETMRRegistrationMode.rigidAnatomical.displayName,
            allowBrainFitInside: false
        ))

        var candidates = await evaluatePETMRFusionCandidateInputs(inputs,
                                                                  fixed: mr,
                                                                  includeLocalPolish: false)
        for seed in brainPETMROrientationSeeds(from: candidates) {
            let direct = await petMRAxialQuarterTurnCandidates(from: seed, fixed: mr)
            candidates += direct
            for candidate in direct {
                if let landmark = await petMRBrainLandmarkCandidate(from: candidate, fixed: mr) {
                    candidates.append(landmark)
                }
            }
        }

        var failedEngines: [String] = []
        let externalConfigs = automaticPETMRExternalConfigurations()
        if !externalConfigs.isEmpty {
            let seeds = brainPETMRExternalSeeds(from: candidates)
            for config in externalConfigs {
                for seed in seeds {
                    statusMessage = "\(statusPrefix): refining \(seed.label) with \(config.backend.displayName)..."
                    do {
                        let deformable = try await PETMRDeformableRegistrationRunner.register(
                            fixed: mr,
                            movingPrealigned: seed.volume,
                            configuration: config
                        )
                        let externalInputs = [PETMRFusionCandidateInput(
                            volume: deformable.warpedMoving,
                            note: "\(seed.note). \(config.backend.displayName) refined \(seed.label). \(deformable.note)",
                            deformationQuality: deformable.deformationQuality,
                            label: "\(config.backend.displayName) on \(seed.label)",
                            allowBrainFitInside: seed.allowBrainFitInside
                        )]
                        candidates += await evaluatePETMRFusionCandidateInputs(externalInputs,
                                                                               fixed: mr,
                                                                               includeLocalPolish: false)
                    } catch {
                        failedEngines.append("\(config.backend.displayName) on \(seed.label): \(error.localizedDescription)")
                    }
                }
            }
        }

        if !hasStrongExternalBrainPETMRRefinement(in: candidates) {
            for seed in brainPETMRExternalSeeds(from: candidates) {
                if let nudged = await petMRPrecisionNudgeCandidate(from: seed, fixed: mr) {
                    candidates.append(nudged)
                }
            }
        }

        guard let selection = bestPETMRAutomaticCandidate(candidates,
                                                          preferBrainSafe: true) else {
            configureFusion(base: mr, overlay: pet, resampledOverlay: geometryVolume)
            statusMessage = "Brain PET/MR registration failed: no MRI-safe candidate could be scored"
            return
        }
        var best = selection.candidate
        var selectionNote = selection.selectionNote ??
            "Brain MRI-driven registration excluded body-envelope warp and selected among scanner/rigid-space candidates."

        if let granular = await petMRGranularBrainAnatomyCandidate(from: best, fixed: mr) {
            candidates.append(granular)
            best = granular
            selectionNote += " Final granular anatomy matching refined cortex/cerebellum alignment after direction and volume correction."
        }

        let pair = configureFusion(base: mr, overlay: pet, resampledOverlay: best.volume)
        pair.registrationNote = concisePETMRAutoNote(best: best,
                                                     candidateCount: candidates.count,
                                                     failedEngines: failedEngines,
                                                     selectionNote: selectionNote)
        pair.registrationDiagnostics = petMRAutomaticDiagnostics(candidates: candidates,
                                                                 selected: best,
                                                                 failedEngines: failedEngines)
        pair.registrationQuality = RegistrationQualityAssurance.compare(
            before: geometryQuality,
            after: best.quality,
            deformation: best.deformationQuality,
            allowBrainPETMRFitInside: best.allowBrainFitInside
        )
        pair.objectWillChange.send()
        applyHangingProtocol(grid: .threeByTwo, panes: HangingPaneConfiguration.defaultPETMR)
        let qaLabel = pair.registrationQuality?.grade.displayName ?? RegistrationQualityGrade.unknown.displayName
        statusMessage = "Brain PET/MR registration selected \(best.label). QA \(qaLabel)"
    }

    private func openIndexedDICOMSeries(_ entry: PACSIndexedSeriesSnapshot,
                                        autoFuse: Bool = false) async {
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

    public func closeVolume(_ volume: ImageVolume) {
        guard loadedVolumes.contains(where: { $0.id == volume.id }) else { return }
        if hasGeneratedStudySessionContent {
            saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: true)
        }

        let wasCurrent = currentVolume?.id == volume.id
        let closedStudyUID = volume.studyUID
        let closedIdentity = volume.sessionIdentity
        loadedVolumes.removeAll { $0.id == volume.id }
        removeVolumeIdentitiesFromActiveViewerSession([closedIdentity])

        if let pair = fusion,
           pair.baseVolume.id == volume.id ||
           pair.overlayVolume.id == volume.id ||
           pair.displayedOverlay.id == volume.id {
            fusion = nil
            fusionAdjustmentTask?.cancel()
            fusionAdjustmentTask = nil
        }

        clearSliceRenderCache()
        clearPETMIPRenderedImageCache()

        if activeSessionVolumes.isEmpty {
            currentVolume = nil
            activeStudySessionKey = nil
            activeStudySessionID = nil
            studySessions = []
            clearCurrentStudySessionState()
        } else if wasCurrent {
            let replacement = activeSessionVolumes.first {
                !closedStudyUID.isEmpty && $0.studyUID == closedStudyUID
            } ?? activeSessionVolumes.first
            if let replacement {
                displayVolume(replacement)
            }
        }

        statusMessage = "Closed series: \(volume.seriesDescription.isEmpty ? Modality.normalize(volume.modality).displayName : volume.seriesDescription)"
    }

    public func closeAllVolumes() {
        let volumesToClose = activeViewerSession == nil ? loadedVolumes : activeSessionVolumes
        guard !volumesToClose.isEmpty else { return }
        if hasGeneratedStudySessionContent {
            saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: true)
        }
        let count = volumesToClose.count
        let identities = Set(volumesToClose.map(\.sessionIdentity))
        loadedVolumes.removeAll { identities.contains($0.sessionIdentity) }
        removeVolumeIdentitiesFromActiveViewerSession(identities)
        fusion = nil
        fusionAdjustmentTask?.cancel()
        fusionAdjustmentTask = nil
        currentVolume = nil
        activeStudySessionKey = nil
        activeStudySessionID = nil
        studySessions = []
        clearCurrentStudySessionState()
        clearSliceRenderCache()
        clearPETMIPRenderedImageCache()
        statusMessage = "Closed \(count) loaded series"
    }

    public func setFusionManualTranslation(x: Double, y: Double, z: Double) {
        let rotation = fusion?.manualRotationDegrees ?? SIMD3<Double>(0, 0, 0)
        let scale = fusion?.manualScale ?? 1
        setFusionManualTransform(translation: SIMD3<Double>(x, y, z),
                                 rotationDegrees: rotation,
                                 scale: scale)
    }

    public func setFusionManualRotation(x: Double, y: Double, z: Double) {
        let translation = fusion?.manualTranslationMM ?? SIMD3<Double>(0, 0, 0)
        let scale = fusion?.manualScale ?? 1
        setFusionManualTransform(translation: translation,
                                 rotationDegrees: SIMD3<Double>(x, y, z),
                                 scale: scale)
    }

    public func setFusionManualScale(_ scale: Double) {
        let translation = fusion?.manualTranslationMM ?? SIMD3<Double>(0, 0, 0)
        let rotation = fusion?.manualRotationDegrees ?? SIMD3<Double>(0, 0, 0)
        setFusionManualTransform(translation: translation,
                                 rotationDegrees: rotation,
                                 scale: scale)
    }

    public func setFusionManualTransform(translation: SIMD3<Double>,
                                         rotationDegrees: SIMD3<Double>,
                                         scale: Double) {
        let next = SIMD3<Double>(
            max(-120, min(120, translation.x)),
            max(-120, min(120, translation.y)),
            max(-120, min(120, translation.z))
        )
        let nextRotation = SIMD3<Double>(
            max(-45, min(45, rotationDegrees.x)),
            max(-45, min(45, rotationDegrees.y)),
            max(-180, min(180, rotationDegrees.z))
        )
        let nextScale = max(0.50, min(1.85, scale))
        fusion?.manualTranslationMM = next
        fusion?.manualRotationDegrees = nextRotation
        fusion?.manualScale = nextScale
        fusion?.objectWillChange.send()
        objectWillChange.send()
        fusionAdjustmentTask?.cancel()
        fusionAdjustmentTask = Task { [weak self] in
            await self?.applyFusionManualTransform(translation: next,
                                                   rotationDegrees: nextRotation,
                                                   scale: nextScale)
        }
    }

    public func previewFusionManualTranslation(_ offset: SIMD3<Double>) {
        let next = SIMD3<Double>(
            max(-120, min(120, offset.x)),
            max(-120, min(120, offset.y)),
            max(-120, min(120, offset.z))
        )
        fusion?.manualTranslationMM = next
        fusion?.objectWillChange.send()
        objectWillChange.send()
        statusMessage = String(format: "Fusion align preview: X %.1f / Y %.1f / Z %.1f mm. Release to apply.",
                               next.x,
                               next.y,
                               next.z)
    }

    public func nudgeFusionManualTranslation(dx: Double, dy: Double, dz: Double) {
        let current = fusion?.manualTranslationMM ?? SIMD3<Double>(0, 0, 0)
        setFusionManualTranslation(x: current.x + dx,
                                   y: current.y + dy,
                                   z: current.z + dz)
    }

    public func nudgeFusionManualRotation(dx: Double, dy: Double, dz: Double) {
        let current = fusion?.manualRotationDegrees ?? SIMD3<Double>(0, 0, 0)
        setFusionManualRotation(x: current.x + dx,
                                y: current.y + dy,
                                z: current.z + dz)
    }

    public func nudgeFusionManualScale(_ delta: Double) {
        let current = fusion?.manualScale ?? 1
        setFusionManualScale(current + delta)
    }

    public func resetFusionManualTranslation() {
        setFusionManualTranslation(x: 0, y: 0, z: 0)
    }

    public func resetFusionManualTransform() {
        setFusionManualTransform(translation: SIMD3<Double>(0, 0, 0),
                                 rotationDegrees: SIMD3<Double>(0, 0, 0),
                                 scale: 1)
    }

    public func applyFusionManualTranslation(_ offset: SIMD3<Double>) async {
        let rotation = fusion?.manualRotationDegrees ?? SIMD3<Double>(0, 0, 0)
        let scale = fusion?.manualScale ?? 1
        await applyFusionManualTransform(translation: offset,
                                         rotationDegrees: rotation,
                                         scale: scale)
    }

    public func applyFusionManualTransform(translation offset: SIMD3<Double>,
                                           rotationDegrees: SIMD3<Double>,
                                           scale: Double) async {
        guard let pair = fusion else { return }
        let base = pair.baseVolume
        let overlay = pair.registrationResampledOverlay ?? pair.overlayVolume
        let normalizedRotation = SIMD3<Double>(
            max(-45, min(45, rotationDegrees.x)),
            max(-45, min(45, rotationDegrees.y)),
            max(-180, min(180, rotationDegrees.z))
        )
        let normalizedScale = max(0.50, min(1.85, scale))
        let hasTransform = simd_length(offset) > 0.001 ||
            simd_length(normalizedRotation) > 0.001 ||
            abs(normalizedScale - 1) > 0.001
        guard hasTransform else {
            pair.resampledOverlay = pair.registrationResampledOverlay
            pair.isGeometryResampled = pair.resampledOverlay != nil
            pair.manualTranslationMM = SIMD3<Double>(0, 0, 0)
            pair.manualRotationDegrees = SIMD3<Double>(0, 0, 0)
            pair.manualScale = 1
            pair.objectWillChange.send()
            objectWillChange.send()
            clearSliceRenderCache()
            scheduleVisibleSliceCacheWarmup(reason: "fusion manual reset")
            statusMessage = "Fusion manual transform reset"
            return
        }

        let shifted = await Task.detached(priority: .userInitiated) {
            let center = base.worldPoint(voxel: SIMD3<Double>(
                Double(base.width - 1) / 2,
                Double(base.height - 1) / 2,
                Double(base.depth - 1) / 2
            ))
            let radians = SIMD3<Double>(
                normalizedRotation.x * .pi / 180.0,
                normalizedRotation.y * .pi / 180.0,
                normalizedRotation.z * .pi / 180.0
            )
            let sourceToDisplay = Transform3D.translation(center.x + offset.x,
                                                          center.y + offset.y,
                                                          center.z + offset.z)
                .concatenate(Transform3D.rotationZ(radians.z))
                .concatenate(Transform3D.rotationY(radians.y))
                .concatenate(Transform3D.rotationX(radians.x))
                .concatenate(Transform3D.scale(normalizedScale))
                .concatenate(Transform3D.translation(-center.x, -center.y, -center.z))
            return VolumeResampler.resample(
                source: overlay,
                target: base,
                transform: sourceToDisplay.inverse,
                mode: .linear
            )
        }.value

        guard !Task.isCancelled, let activePair = fusion, activePair === pair else { return }
        pair.resampledOverlay = shifted
        pair.isGeometryResampled = true
        pair.manualTranslationMM = offset
        pair.manualRotationDegrees = normalizedRotation
        pair.manualScale = normalizedScale
        pair.objectWillChange.send()
        objectWillChange.send()
        clearSliceRenderCache()
        if Modality.normalize(pair.displayedOverlay.modality) == .PT {
            clearPETMIPRenderedImageCache()
            startPETMIPCineWarmupForVolume(pair.displayedOverlay)
        }
        scheduleVisibleSliceCacheWarmup(reason: "fusion manual transform")
        statusMessage = "Fusion manual transform: \(pair.manualTranslationLabel), \(pair.manualRotationLabel), scale \(pair.manualScaleLabel)"
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
            addVolumeToActiveViewerSession(existing)
            return (existing, false)
        }
        loadedVolumes.append(volume)
        recordRecent(volume: volume)
        addRelatedLoadedVolumesToActiveViewerSession(activating: volume)
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

    // MARK: - Saved archive roots

    public func reloadSavedArchiveRoots() {
        savedArchiveRoots = archiveRootStore.load()
    }

    public func rememberArchiveDirectory(url: URL) {
        savedArchiveRoots = archiveRootStore.rememberDirectory(url: url)
    }

    public func forgetArchiveDirectory(id: String) {
        savedArchiveRoots = archiveRootStore.remove(id: id)
        statusMessage = "Forgot saved archive directory"
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
        pair.registrationResampledOverlay = resampledOverlay
        pair.isGeometryResampled = resampledOverlay != nil
        pair.registrationNote = resampledOverlay == nil
            ? "Overlay already matches base grid"
            : "Overlay resampled into base world geometry"
        applyFusionDisplayDefaults(for: overlay, pair: pair)
        fusion = pair
        if Modality.normalize(pair.displayedOverlay.modality) == .PT {
            startPETMIPCineWarmupForVolume(pair.displayedOverlay)
        }
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
                applyPETMIPWindow(window: upper, level: upper / 2)
            } else if maxValue.isFinite, maxValue > 0 {
                let upper = max(1, maxValue * 0.85)
                applyPETOverlayWindow(window: upper, level: upper / 2)
                applyPETMIPWindow(window: upper, level: upper / 2)
            } else {
                applyPETOverlayWindow(window: 10, level: 5)
                applyPETMIPWindow(window: 10, level: 5)
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
        let targetVolumes = studyVolumes(anchoredAt: volume)
        let targetKey = StudySessionStore.studyKey(for: targetVolumes)
        if activeStudySessionKey != nil,
           activeStudySessionKey != targetKey,
           hasGeneratedStudySessionContent {
            persistStudySessions()
        }
        addRelatedLoadedVolumesToActiveViewerSession(activating: volume)
        currentVolume = volume
        updateActiveViewerSessionSelection(volume: volume)
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
        loadStudySessionsIfNeeded(anchor: volume, persistCurrent: false)
        if Modality.normalize(volume.modality) == .PT {
            startPETMIPCineWarmupForVolume(volume)
        }
        scheduleVisibleSliceCacheWarmup(reason: "loaded volume")
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
        scheduleVisibleSliceCacheWarmup(reason: "slice navigation")
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
        syncCrosshairToCurrentSliceIndices()
        scheduleVisibleSliceCacheWarmup(reason: "slice navigation")
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
        scheduleVisibleSliceCacheWarmup(reason: "slice navigation")
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
        scheduleVisibleSliceCacheWarmup(reason: "slice navigation")
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
        scheduleVisibleSliceCacheWarmup(reason: "window level")
    }

    public func windowLevelSnapshot(for mode: SliceDisplayMode,
                                    volume: ImageVolume?) -> DisplayWindowLevelSnapshot {
        let target = windowLevelTarget(for: mode, volume: volume)
        let pair = currentWindowLevel(for: target)
        return DisplayWindowLevelSnapshot(target: target,
                                          window: pair.window,
                                          level: pair.level)
    }

    public func adjustWindowLevel(dw: Double,
                                  dl: Double,
                                  mode: SliceDisplayMode,
                                  volume: ImageVolume?) {
        let target = windowLevelTarget(for: mode, volume: volume)
        switch target {
        case .base:
            adjustWindowLevel(dw: dw, dl: dl)
        case .petOnly:
            petOnlyWindow = max(0.1, petOnlyWindow + dw * 0.025)
            petOnlyLevel = max(0, petOnlyLevel + dl * 0.025)
            scheduleVisibleSliceCacheWarmup(reason: "PET-only window")
        case .petOverlay:
            applyPETOverlayWindow(window: max(0.1, overlayWindow + dw * 0.025),
                                  level: max(0, overlayLevel + dl * 0.025))
            scheduleVisibleSliceCacheWarmup(reason: "PET overlay window")
        }
    }

    public func recordWindowLevelChange(before: DisplayWindowLevelSnapshot,
                                        after: DisplayWindowLevelSnapshot,
                                        name: String = "Window / level") {
        guard before.target == after.target else { return }
        let changed = abs(before.window - after.window) > 0.0001 ||
            abs(before.level - after.level) > 0.0001
        recordHistoryIfNeeded(name: name, changed: changed) { [weak self] in
            self?.applyWindowLevel(target: before.target,
                                   window: before.window,
                                   level: before.level)
        } redo: { [weak self] in
            self?.applyWindowLevel(target: after.target,
                                   window: after.window,
                                   level: after.level)
        }
    }

    private func windowLevelTarget(for mode: SliceDisplayMode,
                                   volume: ImageVolume?) -> DisplayWindowLevelTarget {
        if mode == .petOnly {
            return .petOnly
        }
        if mode == .primary,
           let volume,
           Modality.normalize(volume.modality) == .PT {
            return .petOnly
        }
        return .base
    }

    private func currentWindowLevel(for target: DisplayWindowLevelTarget) -> (window: Double, level: Double) {
        switch target {
        case .base:
            return (window, level)
        case .petOnly:
            return (petOnlyWindow, petOnlyLevel)
        case .petOverlay:
            return (overlayWindow, overlayLevel)
        }
    }

    private func applyWindowLevel(target: DisplayWindowLevelTarget,
                                  window: Double,
                                  level: Double) {
        switch target {
        case .base:
            self.window = max(1, window)
            self.level = level
        case .petOnly:
            applyPETOnlyWindow(window: window, level: level)
        case .petOverlay:
            applyPETOverlayWindow(window: window, level: level)
        }
        scheduleVisibleSliceCacheWarmup(reason: "window level")
    }

    public func applyPreset(_ preset: WindowLevel) {
        let before = (window, level)
        window = preset.window
        level = preset.level
        scheduleVisibleSliceCacheWarmup(reason: "\(preset.name) window")
        recordWindowLevelChange(before: before, after: (window, level), name: "\(preset.name) W/L")
    }

    public func setWindow(_ value: Double) {
        let before = (window, level)
        window = max(1, value)
        scheduleVisibleSliceCacheWarmup(reason: "window level")
        recordWindowLevelChange(before: before, after: (window, level), name: "Window")
    }

    public func setLevel(_ value: Double) {
        let before = (window, level)
        level = value
        scheduleVisibleSliceCacheWarmup(reason: "window level")
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

    /// Histogram-driven W/L picker using percentile clipping.
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

    public func segmentationQualityReport(for labelMap: LabelMap,
                                          volumes: [ImageVolume]? = nil) -> SegmentationQualityReport {
        let reference = referenceVolumeMatching(labelMap, volumes: volumes)
        return SegmentationQuality.analyze(labelMap: labelMap, referenceVolume: reference)
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

    public func startActiveContourAroundSeed(seed: (z: Int, y: Int, x: Int),
                                             preferredVolume: ImageVolume? = nil) {
        let speed: LevelSetSegmentation.SpeedMode
        switch labeling.activeContourMode {
        case .regionCompetition:
            speed = .regionCompetition(
                midpoint: Float(labeling.activeContourMidpoint),
                halfWidth: Float(max(0.001, labeling.activeContourHalfWidth))
            )
        case .edgeStopping:
            speed = .edgeStopping(kappa: Float(max(0.001, labeling.activeContourKappa)))
        }
        let parameters = LevelSetSegmentation.Parameters(
            propagation: Float(labeling.activeContourPropagation),
            curvature: Float(labeling.activeContourCurvature),
            advection: Float(labeling.activeContourAdvection),
            iterations: max(1, labeling.activeContourIterations)
        )
        runBackgroundLabelOperation(
            .activeContour(
                seed: seed,
                radius: max(1, labeling.activeContourSeedRadius),
                speed: speed,
                parameters: parameters
            ),
            defaultName: "Active Contours",
            className: "Snake",
            category: .organ,
            color: .green,
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
        addVolumeOperationStatus(VolumeOperationStatus(
            id: operationID,
            title: title,
            detail: thresholdSummary,
            startedAt: Date(),
            mapID: map.id,
            isMutating: false
        ))
        statusMessage = "Running \(title)… viewer remains responsive"
        JobManager.shared.start(JobUpdate(operationID: operationID.uuidString,
                                          kind: .volumeOperation,
                                          title: title,
                                          stage: thresholdSummary,
                                          detail: statusMessage,
                                          progress: nil,
                                          systemImage: "chart.bar.xaxis",
                                          canCancel: true))

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

        let task = Task { [weak self, input, operationID] in
            await MainActor.run {
                JobManager.shared.heartbeat(operationID: operationID.uuidString,
                                            detail: "Computing volume metrics")
            }
            let report = await Task.detached(priority: ResourcePolicy.load().backgroundTaskPriority) {
                VolumeOperationWorker.measure(input)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.volumeOperationStatuses.contains(where: { $0.id == operationID }) else { return }
            self.lastVolumeMeasurementReport = report
            self.statusMessage = self.measurementStatus(report)
            self.removeVolumeOperationStatus(id: operationID)
            self.volumeOperationTasks.removeValue(forKey: operationID)
            self.autosaveActiveStudySession()
            JobManager.shared.succeed(operationID: operationID.uuidString,
                                      detail: self.statusMessage)
        }
        volumeOperationTasks[operationID] = task
    }

    @discardableResult
    public func extractActiveRadiomics(preferPET: Bool = true) -> RadiomicsFeatureReport? {
        guard let map = labeling.activeLabelMap else {
            lastRadiomicsFeatureReport = nil
            statusMessage = "No active label map for radiomics"
            return nil
        }
        guard let source = activeMeasurementSource(matching: map, preferPET: preferPET) else {
            lastRadiomicsFeatureReport = nil
            statusMessage = "No matching volume grid for active-label radiomics"
            return nil
        }
        if preferPET, source.source != .petSUV {
            lastRadiomicsFeatureReport = nil
            statusMessage = "No PET volume matches the active label map"
            return nil
        }
        if !preferPET, source.source == .petSUV {
            lastRadiomicsFeatureReport = nil
            statusMessage = "No CT/anatomic volume matches the active label map"
            return nil
        }
        let classID = labeling.activeClassID
        let className = map.classInfo(id: classID)?.name ?? "class_\(classID)"
        guard let bounds = radiomicsBounds(for: map, classID: classID) else {
            lastRadiomicsFeatureReport = nil
            statusMessage = "Active class has no voxels for radiomics"
            return nil
        }

        do {
            let transform: ((Double) -> Double)? = source.source == .petSUV ? suvTransform(for: source.volume) : nil
            let features = try RadiomicsExtractor.extract(
                volume: source.volume,
                mask: map,
                classID: classID,
                bounds: bounds,
                valueTransform: transform
            )
            let description = source.volume.seriesDescription.isEmpty
                ? Modality.normalize(source.volume.modality).displayName
                : source.volume.seriesDescription
            let report = RadiomicsFeatureReport(
                source: source.source,
                sourceVolumeIdentity: source.volume.sessionIdentity,
                sourceDescription: description,
                classID: classID,
                className: className,
                bounds: bounds,
                features: features
            )
            lastRadiomicsFeatureReport = report
            statusMessage = "Extracted \(report.compactSummary)"
            autosaveActiveStudySession()
            return report
        } catch {
            lastRadiomicsFeatureReport = nil
            statusMessage = "Radiomics extraction failed: \(error.localizedDescription)"
            return nil
        }
    }

    public func activeLabelDataExportReport() -> LabelDataExportReport? {
        guard let map = labeling.activeLabelMap else {
            statusMessage = "No active label map to export"
            return nil
        }
        guard let source = referenceVolumeMatching(map) else {
            statusMessage = "No matching volume grid for label data export"
            return nil
        }
        return LabelDataExportReport(
            labelMap: map,
            parentVolume: source,
            activeVolumeReport: lastVolumeMeasurementReport,
            activeRadiomicsReport: lastRadiomicsFeatureReport,
            annotations: annotations
        )
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
        autosaveActiveStudySession()
        return report
    }

    private func runBackgroundLabelOperation(_ operation: VolumeLabelOperation,
                                             defaultName: String,
                                             className: String,
                                             category: LabelCategory,
                                             color: Color,
                                             forceCT: Bool = false,
                                             preferredVolume: ImageVolume? = nil) {
        ensureActiveLabelMapForCurrentContext(
            defaultName: defaultName,
            className: className,
            category: category,
            color: color
        )
        guard let map = labeling.activeLabelMap else { return }
        guard !hasMutatingVolumeOperation(for: map.id) else {
            statusMessage = "A label-writing job is already running for this label map. Other studies and read-only measurements can continue."
            return
        }

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
        addVolumeOperationStatus(VolumeOperationStatus(
            id: operationID,
            title: operation.title,
            detail: operation.thresholdSummary,
            startedAt: Date(),
            mapID: map.id,
            isMutating: true
        ))
        statusMessage = "Running \(operation.title)… viewer remains responsive"
        JobManager.shared.start(JobUpdate(operationID: operationID.uuidString,
                                          kind: .volumeOperation,
                                          title: operation.title,
                                          stage: operation.thresholdSummary,
                                          detail: statusMessage,
                                          progress: nil,
                                          systemImage: operation.systemImage,
                                          canCancel: true))

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

        let task = Task { [weak self, input, operationID] in
            await MainActor.run {
                JobManager.shared.heartbeat(operationID: operationID.uuidString,
                                            detail: "Running \(input.operation.title)")
            }
            let result = await Task.detached(priority: ResourcePolicy.load().backgroundTaskPriority) {
                VolumeOperationWorker.runLabelOperation(input)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.volumeOperationStatuses.contains(where: { $0.id == operationID }) else { return }
            self.finishBackgroundLabelOperation(result, operationID: operationID)
        }
        volumeOperationTasks[operationID] = task
    }

    private func finishBackgroundLabelOperation(_ result: VolumeLabelOperationOutput, operationID: UUID) {
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
        case .activeContour:
            if let levelSet = result.levelSet {
                message = "Snake segmented \(levelSet.insideVoxels) voxels in \(levelSet.iterations) iterations"
                if levelSet.converged {
                    message += " (converged)"
                }
            } else {
                message = "Snake segmentation finished"
            }
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
        removeVolumeOperationStatus(id: operationID)
        volumeOperationTasks.removeValue(forKey: operationID)
        saveOrUpdateCurrentStudySession(announce: false, includeLabelMaps: true)
        JobManager.shared.succeed(operationID: operationID.uuidString,
                                  detail: message)
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

    private func petOncologyReview(for labelMap: LabelMap) throws -> PETOncologyReview? {
        guard let pet = activePETVolumeMatching(labelMap) else { return nil }
        let report = try PETQuantification.compute(
            petVolume: pet,
            labelMap: labelMap,
            suvTransform: suvTransform(for: pet),
            connectedComponents: true
        )
        return PETOncologyReview.build(from: report, petVolume: pet)
    }

    private func matchingBrainPETNormalDatabase(for tracer: BrainPETTracer) -> BrainPETNormalDatabase? {
        guard let database = brainPETNormalDatabase else { return nil }
        return database.tracer == tracer || database.tracer.family == tracer.family ? database : nil
    }

    private func referenceVolumeMatching(_ labelMap: LabelMap,
                                         volumes: [ImageVolume]? = nil) -> ImageVolume? {
        if let source = activeMeasurementSource(matching: labelMap, preferPET: true)?.volume {
            return source
        }
        if let volumes,
           let match = volumes.first(where: { sameGrid($0, labelMap) }) {
            return match
        }
        if let currentVolume, sameGrid(currentVolume, labelMap) {
            return currentVolume
        }
        return activeSessionVolumes.first { sameGrid($0, labelMap) }
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
        return activeSessionVolumes.first(where: { sameGrid($0, labelMap) }).map { volume in
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

    private func autoContourVolumeCandidates(near volume: ImageVolume?) -> [ImageVolume] {
        if let volume {
            let study = studyVolumes(anchoredAt: volume)
            if !study.isEmpty { return study }
        }
        if !activeSessionVolumes.isEmpty { return activeSessionVolumes }
        return loadedVolumes
    }

    private func autoContourVolume(matching description: String,
                                   in candidates: [ImageVolume],
                                   excluding excludedIdentities: Set<String>) -> ImageVolume? {
        let text = description.lowercased()
        let requestedModality: Modality?
        if text.contains("pet") || text.contains("suv") || text.contains("psma") || text.contains("fdg") {
            requestedModality = .PT
        } else if text.contains("ct") || text.contains("hu") {
            requestedModality = .CT
        } else if text.contains("mr") ||
                    text.contains("mri") ||
                    text.contains("t1") ||
                    text.contains("t2") ||
                    text.contains("flair") ||
                    text.contains("adc") {
            requestedModality = .MR
        } else {
            requestedModality = nil
        }

        guard let requestedModality else { return nil }
        return candidates.first {
            !excludedIdentities.contains($0.sessionIdentity) &&
            Modality.normalize($0.modality) == requestedModality
        }
    }

    private func radiomicsBounds(for labelMap: LabelMap,
                                 classID: UInt16) -> MONAITransforms.VoxelBounds? {
        var minZ = labelMap.depth
        var maxZ = -1
        var minY = labelMap.height
        var maxY = -1
        var minX = labelMap.width
        var maxX = -1
        for z in 0..<labelMap.depth {
            for y in 0..<labelMap.height {
                let rowStart = z * labelMap.height * labelMap.width + y * labelMap.width
                for x in 0..<labelMap.width where labelMap.voxels[rowStart + x] == classID {
                    minZ = min(minZ, z)
                    maxZ = max(maxZ, z)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        guard maxZ >= minZ, maxY >= minY, maxX >= minX else { return nil }
        return MONAITransforms.VoxelBounds(
            minZ: minZ, maxZ: maxZ,
            minY: minY, maxY: maxY,
            minX: minX, maxX: maxX
        )
    }

    // MARK: - Slice images

    public func clearSliceRenderCache() {
        sliceRenderWarmupTask?.cancel()
        sliceRenderWarmupTask = nil
        sliceRenderCache.removeAll(keepingCapacity: true)
        sliceRenderCacheOrder.removeAll(keepingCapacity: true)
        sliceRenderCacheHitCount = 0
        sliceRenderCacheMissCount = 0
        sliceRenderWarmupStatus = "Slice cache cleared"
    }

    public func scheduleVisibleSliceCacheWarmup(reason: String = "visible panes") {
        sliceRenderWarmupTask?.cancel()
        let quiet = reason == "slice navigation"
        let delayNanoseconds: UInt64 = quiet ? 280_000_000 : 120_000_000
        sliceRenderWarmupTask = Task { [weak self, delayNanoseconds, quiet] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.runVisibleSliceCacheWarmup(reason: reason, quiet: quiet)
        }
    }

    @discardableResult
    public func warmVisibleSliceCacheNow(limit: Int = 12,
                                         updateStatus: Bool = true) -> Int {
        guard !hangingPanes.isEmpty else {
            if updateStatus { sliceRenderWarmupStatus = "Slice cache idle" }
            return 0
        }
        let visibleCount = min(max(0, limit), hangingGrid.paneCount, hangingPanes.count)
        guard visibleCount > 0 else {
            if updateStatus { sliceRenderWarmupStatus = "Slice cache idle" }
            return 0
        }

        let hitsBefore = sliceRenderCacheHitCount
        let missesBefore = sliceRenderCacheMissCount
        var warmed = 0

        for pane in hangingPanes.prefix(visibleCount) {
            guard let mode = pane.kind.sliceDisplayMode else { continue }
            let axis = pane.plane.axis
            if makeImage(for: axis, mode: mode) != nil {
                warmed += 1
            }
            if makeLabelImage(for: axis, mode: mode) != nil {
                warmed += 1
            }
        }

        let newHits = sliceRenderCacheHitCount - hitsBefore
        let newMisses = sliceRenderCacheMissCount - missesBefore
        if updateStatus {
            if warmed > 0 {
                sliceRenderWarmupStatus = "Slice cache warm: \(warmed) image(s), \(newHits) hit(s), \(newMisses) miss(es)"
            } else {
                sliceRenderWarmupStatus = "Slice cache idle"
            }
        }
        return warmed
    }

    private func runVisibleSliceCacheWarmup(reason: String, quiet: Bool = false) {
        let warmed = warmVisibleSliceCacheNow(updateStatus: !quiet)
        if warmed > 0 && !quiet {
            statusMessage = "Prepared \(warmed) visible slice image(s) for \(reason)"
        }
    }

    public func makeImage(for axis: Int, mode: SliceDisplayMode = .fused) -> CGImage? {
        guard sliceIndices.indices.contains(axis) else { return nil }
        guard let v = volumeForDisplayMode(mode) else { return nil }
        let index = sliceIndex(axis: axis, volume: v)
        let dimensions = sliceDimensions(axis: axis, volume: v)
        let transform = displayTransform(for: axis, volume: v)
        let modality = Modality.normalize(v.modality)
        let renderPETColor = mode == .petOnly && modality == .PT
        let renderWindow = renderPETColor ? petOnlyWindow : window
        let renderLevel = renderPETColor ? petOnlyLevel : level
        let renderInvert = invertForDisplay(volume: v, mode: mode)

        if mode == .fused,
           let pair = fusion,
           pair.overlayVisible,
           pair.baseVolume.id == v.id {
            let ov = pair.displayedOverlay
            let overlayIndex = sliceIndex(axis: axis, volume: ov)
            let overlayDimensions = sliceDimensions(axis: axis, volume: ov)
            guard overlayDimensions.width == dimensions.width,
                  overlayDimensions.height == dimensions.height else { return nil }
            let overlayInvert = invertForFusionOverlay(volume: ov)
            let key = SliceRenderCacheKey(
                layer: .fused,
                sourceVolumeID: v.id,
                referenceVolumeID: ov.id,
                labelMapID: nil,
                labelRevision: 0,
                axis: axis,
                sliceIndex: index,
                mode: mode.rawValue,
                width: dimensions.width,
                height: dimensions.height,
                depth: v.depth,
                window: renderKey(window),
                level: renderKey(level),
                secondaryWindow: renderKey(pair.overlayWindow),
                secondaryLevel: renderKey(pair.overlayLevel),
                secondaryInvert: overlayInvert,
                invert: renderInvert,
                colormap: pair.colormap.rawValue,
                opacity: renderKey(pair.opacity),
                flipHorizontal: transform.flipHorizontal,
                flipVertical: transform.flipVertical,
                suvSignature: suvRenderSignature(for: ov)
            )

            return cachedSliceImage(for: key) {
                let baseSlice = v.slice(axis: axis, index: index)
                let overlaySlice = ov.slice(axis: axis, index: overlayIndex)
                guard baseSlice.width == overlaySlice.width,
                      baseSlice.height == overlaySlice.height else { return nil }
                var basePixels = baseSlice.pixels
                var overlayPixels = petDisplayPixels(overlaySlice.pixels, volume: ov)
                let w = baseSlice.width, h = baseSlice.height
                basePixels = SliceTransform.apply(basePixels, width: w, height: h,
                                                  transform: transform)
                overlayPixels = SliceTransform.apply(overlayPixels, width: w, height: h,
                                                     transform: transform)
                return PixelRenderer.makeFusedImage(
                    basePixels: basePixels,
                    overlayPixels: overlayPixels,
                    width: w,
                    height: h,
                    baseWindow: window,
                    baseLevel: level,
                    overlayWindow: pair.overlayWindow,
                    overlayLevel: pair.overlayLevel,
                    colormap: pair.colormap,
                    opacity: pair.opacity,
                    invertBase: renderInvert,
                    invertOverlay: overlayInvert
                )
            }
        }

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
            window: renderKey(renderWindow),
            level: renderKey(renderLevel),
            secondaryWindow: 0,
            secondaryLevel: 0,
            secondaryInvert: false,
            invert: renderInvert,
            colormap: renderPETColor ? petOnlyColormap.rawValue : "gray",
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
                    window: petOnlyWindow, level: petOnlyLevel,
                    colormap: petOnlyColormap,
                    baseAlpha: 1.0,
                    invert: renderInvert
                )
            }

            return PixelRenderer.makeGrayImage(
                pixels: pixels, width: w, height: h,
                window: window, level: level, invert: renderInvert
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
            secondaryWindow: 0,
            secondaryLevel: 0,
            secondaryInvert: false,
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
        // Fused panes now render PET/CT as a single true cross-fade in
        // `makeImage(for:mode:)`, so there is no separate top overlay layer.
        return nil
    }

    private func invertForDisplay(volume: ImageVolume, mode: SliceDisplayMode) -> Bool {
        switch Modality.normalize(volume.modality) {
        case .PT:
            if mode == .petOnly { return invertColors || invertPETOnlyImages }
            return invertColors || invertPETImages
        case .CT:
            return invertColors || invertCTImages
        default:
            return invertColors
        }
    }

    private func invertForFusionOverlay(volume: ImageVolume) -> Bool {
        if Modality.normalize(volume.modality) == .PT {
            return invertColors || invertPETImages
        }
        return invertColors
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
        while sliceRenderCacheOrder.count > ResourcePolicy.load().sliceCacheEntries {
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
        let key = PETMIPProjectionKey(volume: pet, axis: axis, rotationDegrees: petMIPRotationDegrees)
        guard let selection = petMIPProjectionForDisplay(volume: pet, axis: axis, key: key) else { return nil }
        return renderedPETMIPImage(for: selection.projection, key: selection.key, volume: pet, axis: axis)
    }

    public func cachedPETMIPImage(for axis: Int) -> CGImage? {
        guard let pet = activePETQuantificationVolume else { return nil }
        let key = PETMIPProjectionKey(volume: pet, axis: axis, rotationDegrees: petMIPRotationDegrees)
        return cachedPETMIPImageForDisplay(volume: pet, axis: axis, key: key)
    }

    public func makePETMIPLabelImage(for axis: Int) -> CGImage? {
        guard let pet = activePETQuantificationVolume,
              let map = labeling.activeLabelMap,
              map.visible,
              sameGrid(pet, map) else {
            return nil
        }
        let key = PETMIPProjectionKey(volume: pet, axis: axis, rotationDegrees: petMIPRotationDegrees)
        guard let selection = petMIPProjectionForDisplay(volume: pet, axis: axis, key: key) else { return nil }
        return renderedPETMIPLabelImage(for: selection.projection,
                                        key: selection.key,
                                        volume: pet,
                                        axis: axis,
                                        map: map)
    }

    public func cachedPETMIPLabelImage(for axis: Int) -> CGImage? {
        guard let pet = activePETQuantificationVolume,
              let map = labeling.activeLabelMap,
              map.visible,
              sameGrid(pet, map) else {
            return nil
        }
        let key = PETMIPProjectionKey(volume: pet, axis: axis, rotationDegrees: petMIPRotationDegrees)
        for selection in cachedFullPETMIPProjectionSelections(for: key) {
            if let image = cachedRenderedPETMIPLabelImage(for: selection.projection,
                                                          key: selection.key,
                                                          volume: pet,
                                                          axis: axis,
                                                          map: map) {
                return image
            }
        }
        return nil
    }

    public func isPETMIPCurrentFrameReady(for axis: Int) -> Bool {
        isPETMIPRenderedFrameReady(for: axis, rotationDegrees: petMIPRotationDegrees)
    }

    public func isPETMIPRenderedFrameReady(for axis: Int, rotationDegrees: Double) -> Bool {
        guard let pet = activePETQuantificationVolume else { return false }
        let key = PETMIPProjectionKey(volume: pet, axis: axis, rotationDegrees: rotationDegrees)
        return hasRenderedPETMIPFrame(volume: pet, axis: axis, key: key)
    }

    private func hasRenderedPETMIPFrame(volume: ImageVolume,
                                        axis: Int,
                                        key: PETMIPProjectionKey) -> Bool {
        guard let selection = exactFullCachedPETMIPProjection(for: key) else { return false }
        return hasRenderedPETMIPImage(for: selection.projection,
                                      key: selection.key,
                                      volume: volume,
                                      axis: axis)
    }

    public func isPETMIPProjectionPending(for axis: Int) -> Bool {
        guard let pet = activePETQuantificationVolume else { return false }
        let key = PETMIPProjectionKey(volume: pet, axis: axis, rotationDegrees: petMIPRotationDegrees)
        return petMIPProjectionTasks[key] != nil || petMIPPreviewProjectionTasks[key] != nil
    }

    @discardableResult
    public func navigateUsingPETMIP(axis: Int, displayPixelX: Int, displayPixelY: Int) -> Bool {
        guard let pet = activePETQuantificationVolume else {
            statusMessage = "No PET MIP is available for navigation"
            return false
        }
        let key = PETMIPProjectionKey(volume: pet, axis: axis, rotationDegrees: petMIPRotationDegrees)
        guard let selection = petMIPProjectionForDisplay(volume: pet, axis: axis, key: key) else {
            statusMessage = "PET MIP is still preparing"
            return false
        }
        let mip = selection.projection
        guard mip.width > 0, mip.height > 0 else { return false }
        var x = max(0, min(mip.width - 1, displayPixelX))
        var y = max(0, min(mip.height - 1, displayPixelY))
        let transform = displayTransform(for: axis, volume: pet)
        if transform.flipHorizontal {
            x = mip.width - 1 - x
        }
        y = mip.height - 1 - y
        if transform.flipVertical {
            y = mip.height - 1 - y
        }
        let index = y * mip.width + x
        guard mip.argmaxX.indices.contains(index),
              mip.argmaxY.indices.contains(index),
              mip.argmaxZ.indices.contains(index) else { return false }

        let voxelX = mip.argmaxX[index]
        let voxelY = mip.argmaxY[index]
        let voxelZ = mip.argmaxZ[index]
        guard voxelX >= 0, voxelY >= 0, voxelZ >= 0 else {
            statusMessage = "No PET uptake was projected at that MIP point"
            return false
        }
        let world = pet.worldPoint(z: voxelZ, y: voxelY, x: voxelX)
        centerSlices(on: world)
        let raw = pet.intensity(z: voxelZ, y: voxelY, x: voxelX)
        let suv = suvValue(rawStoredValue: Double(raw), volume: pet)
        statusMessage = String(format: "MIP navigation → PET voxel (%d, %d, %d), SUV %.2f",
                               voxelX, voxelY, voxelZ, suv)
        return true
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

    private func clearPETMIPRenderedImageCache() {
        petMIPCineWarmupDebounceTask?.cancel()
        petMIPCineWarmupDebounceTask = nil
        for task in petMIPCineWarmupTasks.values {
            task.cancel()
        }
        petMIPCineWarmupTasks.removeAll(keepingCapacity: true)
        petMIPCineWarmupTokens.removeAll(keepingCapacity: true)
        petMIPRenderedImageCache.removeAll(keepingCapacity: true)
        petMIPRenderedImageCacheOrder.removeAll(keepingCapacity: true)
        petMIPCineReadyKeys.removeAll(keepingCapacity: true)
        petMIPCineProgressKeys.removeAll(keepingCapacity: true)
        petMIPCineProgressByAxis = [:]
    }

    private func cachedPETMIPImageForDisplay(volume: ImageVolume,
                                             axis: Int,
                                             key: PETMIPProjectionKey) -> CGImage? {
        for selection in cachedFullPETMIPProjectionSelections(for: key) {
            if let image = cachedRenderedPETMIPImage(for: selection.projection,
                                                     key: selection.key,
                                                     volume: volume,
                                                     axis: axis) {
                return image
            }
        }
        return nil
    }

    private func renderedPETMIPImageKey(for projectionKey: PETMIPProjectionKey,
                                        projection: PETMIPProjection,
                                        volume: ImageVolume,
                                        axis: Int) -> PETMIPRenderedImageKey {
        let transform = displayTransform(for: axis, volume: volume)
        return PETMIPRenderedImageKey(
            projectionKey: projectionKey,
            projectionWidth: projection.width,
            projectionHeight: projection.height,
            window: renderKey(petMIPWindow),
            level: renderKey(petMIPLevel),
            invert: invertPETMIP,
            colormap: mipColormap.rawValue,
            flipHorizontal: transform.flipHorizontal,
            flipVertical: transform.flipVertical,
            suvSignature: suvRenderSignature(for: volume)
        )
    }

    @discardableResult
    private func renderedPETMIPImage(for projection: PETMIPProjection,
                                     key: PETMIPProjectionKey,
                                     volume: ImageVolume,
                                     axis: Int) -> CGImage? {
        if let cached = cachedRenderedPETMIPImage(for: projection, key: key, volume: volume, axis: axis) {
            return cached
        }

        var pixels = SliceTransform.apply(
            projection.pixels,
            width: projection.width,
            height: projection.height,
            transform: displayTransform(for: axis, volume: volume)
        )
        pixels = petDisplayPixels(pixels, volume: volume)
        guard let image = PixelRenderer.makeColorImage(
            pixels: pixels,
            width: projection.width,
            height: projection.height,
            window: petMIPWindow,
            level: petMIPLevel,
            colormap: mipColormap,
            baseAlpha: 1.0,
            invert: invertPETMIP
        ) else {
            return nil
        }

        let imageKey = renderedPETMIPImageKey(for: key,
                                              projection: projection,
                                              volume: volume,
                                              axis: axis)
        petMIPRenderedImageCache[imageKey] = image
        petMIPRenderedImageCacheOrder.removeAll { $0 == imageKey }
        petMIPRenderedImageCacheOrder.append(imageKey)
        while petMIPRenderedImageCacheOrder.count > 512 {
            let evicted = petMIPRenderedImageCacheOrder.removeFirst()
            petMIPRenderedImageCache.removeValue(forKey: evicted)
        }
        return image
    }

    private func cachedRenderedPETMIPImage(for projection: PETMIPProjection,
                                           key: PETMIPProjectionKey,
                                           volume: ImageVolume,
                                           axis: Int) -> CGImage? {
        let imageKey = renderedPETMIPImageKey(for: key, projection: projection, volume: volume, axis: axis)
        guard let cached = petMIPRenderedImageCache[imageKey] else { return nil }
        petMIPRenderedImageCacheOrder.removeAll { $0 == imageKey }
        petMIPRenderedImageCacheOrder.append(imageKey)
        return cached
    }

    private func hasRenderedPETMIPImage(for projection: PETMIPProjection,
                                        key: PETMIPProjectionKey,
                                        volume: ImageVolume,
                                        axis: Int) -> Bool {
        let imageKey = renderedPETMIPImageKey(for: key, projection: projection, volume: volume, axis: axis)
        return petMIPRenderedImageCache[imageKey] != nil
    }

    private func renderedPETMIPLabelImageKey(for projectionKey: PETMIPProjectionKey,
                                             projection: PETMIPProjection,
                                             volume: ImageVolume,
                                             axis: Int,
                                             map: LabelMap) -> PETMIPRenderedLabelKey {
        let transform = displayTransform(for: axis, volume: volume)
        return PETMIPRenderedLabelKey(
            projectionKey: projectionKey,
            projectionWidth: projection.width,
            projectionHeight: projection.height,
            labelMapID: map.id,
            labelRevision: map.renderRevision,
            flipHorizontal: transform.flipHorizontal,
            flipVertical: transform.flipVertical
        )
    }

    @discardableResult
    private func renderedPETMIPLabelImage(for projection: PETMIPProjection,
                                          key: PETMIPProjectionKey,
                                          volume: ImageVolume,
                                          axis: Int,
                                          map: LabelMap? = nil) -> CGImage? {
        guard let map = map ?? labeling.activeLabelMap,
              map.visible,
              sameGrid(volume, map),
              projection.width > 0,
              projection.height > 0 else {
            return nil
        }
        if let cached = cachedRenderedPETMIPLabelImage(for: projection,
                                                       key: key,
                                                       volume: volume,
                                                       axis: axis,
                                                       map: map) {
            return cached
        }

        var values = [UInt16](repeating: 0, count: projection.width * projection.height)
        for index in values.indices {
            guard projection.argmaxX.indices.contains(index),
                  projection.argmaxY.indices.contains(index),
                  projection.argmaxZ.indices.contains(index) else {
                continue
            }
            let x = projection.argmaxX[index]
            let y = projection.argmaxY[index]
            let z = projection.argmaxZ[index]
            guard x >= 0, x < map.width,
                  y >= 0, y < map.height,
                  z >= 0, z < map.depth else {
                continue
            }
            values[index] = map.value(z: z, y: y, x: x)
        }

        values = SliceTransform.apply(values,
                                      width: projection.width,
                                      height: projection.height,
                                      transform: displayTransform(for: axis, volume: volume))
        guard let image = LabelRenderer.makeImage(values: values,
                                                  width: projection.width,
                                                  height: projection.height,
                                                  classes: map.classes,
                                                  baseAlpha: map.opacity) else {
            return nil
        }
        let labelKey = renderedPETMIPLabelImageKey(for: key,
                                                   projection: projection,
                                                   volume: volume,
                                                   axis: axis,
                                                   map: map)
        petMIPRenderedLabelCache[labelKey] = image
        petMIPRenderedLabelCacheOrder.removeAll { $0 == labelKey }
        petMIPRenderedLabelCacheOrder.append(labelKey)
        while petMIPRenderedLabelCacheOrder.count > 256 {
            let evicted = petMIPRenderedLabelCacheOrder.removeFirst()
            petMIPRenderedLabelCache.removeValue(forKey: evicted)
        }
        return image
    }

    private func cachedRenderedPETMIPLabelImage(for projection: PETMIPProjection,
                                                key: PETMIPProjectionKey,
                                                volume: ImageVolume,
                                                axis: Int,
                                                map: LabelMap) -> CGImage? {
        let labelKey = renderedPETMIPLabelImageKey(for: key,
                                                   projection: projection,
                                                   volume: volume,
                                                   axis: axis,
                                                   map: map)
        guard let cached = petMIPRenderedLabelCache[labelKey] else { return nil }
        petMIPRenderedLabelCacheOrder.removeAll { $0 == labelKey }
        petMIPRenderedLabelCacheOrder.append(labelKey)
        return cached
    }

    private func schedulePETMIPFullQualityProjection(priorityAxis: Int?,
                                                     delayNanoseconds: UInt64) {
        petMIPFullQualityDebounceTask?.cancel()
        petMIPFullQualityDebounceTask = Task { [weak self, delayNanoseconds, priorityAxis] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            self?.startPETMIPFullQualityProjectionForCurrentRotation(priorityAxis: priorityAxis)
        }
    }

    private func cancelPETMIPFullQualityProjectionWork(priorityAxis: Int?) {
        petMIPFullQualityDebounceTask?.cancel()
        petMIPFullQualityDebounceTask = nil
        guard let pet = activePETQuantificationVolume else { return }
        let staleKeys = petMIPProjectionTasks.keys.filter { key in
            key.volumeIdentity == pet.sessionIdentity && (priorityAxis == nil || key.axis == priorityAxis)
        }
        for key in staleKeys {
            petMIPProjectionTasks[key]?.cancel()
            petMIPProjectionTasks.removeValue(forKey: key)
        }
    }

    private func startPETMIPFullQualityProjectionForCurrentRotation(priorityAxis: Int?) {
        guard let pet = activePETQuantificationVolume else { return }
        for axis in preferredPETMIPProjectionAxes(priorityAxis: priorityAxis) {
            let key = PETMIPProjectionKey(volume: pet, axis: axis, rotationDegrees: petMIPRotationDegrees)
            startPETMIPProjectionIfNeeded(volume: pet, axis: axis, key: key)
        }
    }

    private func preferredPETMIPProjectionAxes(priorityAxis: Int?) -> [Int] {
        var axes: [Int] = []
        if let priorityAxis {
            axes.append(priorityAxis)
        }
        for pane in hangingPanes where pane.kind == .petMIP && !axes.contains(pane.plane.axis) {
            axes.append(pane.plane.axis)
        }
        if axes.isEmpty {
            axes = [SlicePlane.coronal.axis, SlicePlane.sagittal.axis]
        }
        return axes
    }

    private func petMIPProjectionForDisplay(volume: ImageVolume,
                                            axis: Int,
                                            key: PETMIPProjectionKey) -> PETMIPProjectionSelection? {
        if let selection = exactCachedPETMIPProjection(for: key) {
            return selection
        }

        if key.needsRotatedProjection {
            startPETMIPPreviewProjectionIfNeeded(volume: volume, axis: axis, key: key)
            if let selection = exactCachedPETMIPProjection(for: key) {
                return selection
            }
            return nearestCachedPETMIPProjection(for: key)
        }

        startPETMIPProjectionIfNeeded(volume: volume, axis: axis, key: key)
        return nearestCachedPETMIPProjection(for: key)
    }

    private func petMIPCineRotationSequence(around centerTenths: Int) -> [Int] {
        let step = max(10, petMIPCineStepTenths)
        let center = ((centerTenths + step / 2) / step * step) % 3_600
        var sequence: [Int] = [center]
        let maxOffset = 3_600 / step
        for offset in 1...maxOffset {
            let forward = (center + offset * step) % 3_600
            if !sequence.contains(forward) {
                sequence.append(forward)
            }
            let backward = (center - offset * step + 3_600 * 2) % 3_600
            if !sequence.contains(backward) {
                sequence.append(backward)
            }
            if sequence.count >= maxOffset { break }
        }
        return sequence
    }

    private func startPETMIPCineWarmupIfNeeded(volume: ImageVolume,
                                               axis: Int,
                                               around centerTenths: Int) {
        guard axis != SlicePlane.axial.axis else { return }
        let warmupKey = PETMIPCineWarmupKey(volume: volume, axis: axis)
        guard !petMIPCineReadyKeys.contains(warmupKey),
              petMIPCineWarmupTasks[warmupKey] == nil else { return }
        let sequence = petMIPCineRotationSequence(around: centerTenths)
        let policy = ResourcePolicy.load()
        let token = UUID()
        petMIPCineWarmupTokens[warmupKey] = token
        petMIPCineWarmupTasks[warmupKey] = Task { [weak self, volume, axis, warmupKey, sequence, policy, token] in
            var completed = 0
            for tenths in sequence {
                guard !Task.isCancelled else { break }
                guard self?.petMIPCineWarmupTokens[warmupKey] == token else { break }
                let key = PETMIPProjectionKey(volume: volume, axis: axis, rotationTenths: tenths)

                if let cached = self?.petMIPProjectionCache[key] {
                    self?.renderedPETMIPImage(for: cached, key: key, volume: volume, axis: axis)
                    self?.renderedPETMIPLabelImage(for: cached, key: key, volume: volume, axis: axis)
                    completed += 1
                    self?.updatePETMIPCineProgress(warmupKey,
                                                   axis: axis,
                                                   completed: completed,
                                                   total: sequence.count,
                                                   volumeIdentity: volume.sessionIdentity)
                    await Task.yield()
                    continue
                }

                if self?.petMIPProjectionTasks[key] != nil {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    if let cached = self?.petMIPProjectionCache[key] {
                        self?.renderedPETMIPImage(for: cached, key: key, volume: volume, axis: axis)
                        self?.renderedPETMIPLabelImage(for: cached, key: key, volume: volume, axis: axis)
                        completed += 1
                        self?.updatePETMIPCineProgress(warmupKey,
                                                       axis: axis,
                                                       completed: completed,
                                                       total: sequence.count,
                                                       volumeIdentity: volume.sessionIdentity)
                    }
                    await Task.yield()
                    continue
                }

                let rotation = Double(key.rotationTenths) / 10
                let computeTask = Task.detached(priority: .utility) {
                    PETMIPProjection.compute(volume: volume,
                                             axis: axis,
                                             horizontalRotationDegrees: rotation,
                                             interactivePreview: false)
                }
                let projection = await withTaskCancellationHandler {
                    await computeTask.value
                } onCancel: {
                    computeTask.cancel()
                }
                guard let self else { break }
                guard !Task.isCancelled else { break }
                guard self.petMIPCineWarmupTokens[warmupKey] == token else { break }
                self.storePETMIPProjection(projection, for: key, policy: policy)
                self.renderedPETMIPImage(for: projection, key: key, volume: volume, axis: axis)
                self.renderedPETMIPLabelImage(for: projection, key: key, volume: volume, axis: axis)
                completed += 1
                self.updatePETMIPCineProgress(warmupKey,
                                              axis: axis,
                                              completed: completed,
                                              total: sequence.count,
                                              volumeIdentity: volume.sessionIdentity)
                await Task.yield()
            }
            guard self?.petMIPCineWarmupTokens[warmupKey] == token else { return }
            if completed >= sequence.count {
                self?.petMIPCineReadyKeys.insert(warmupKey)
                self?.petMIPCineProgressKeys[warmupKey] = 1
                if self?.petMIPCineProgressVolumeIdentity == volume.sessionIdentity {
                    self?.petMIPCineProgressByAxis[axis] = 1
                }
            }
            self?.petMIPCineWarmupTasks[warmupKey] = nil
            self?.petMIPCineWarmupTokens.removeValue(forKey: warmupKey)
        }
    }

    private func updatePETMIPCineProgress(_ key: PETMIPCineWarmupKey,
                                          axis: Int,
                                          completed: Int,
                                          total: Int,
                                          volumeIdentity: String) {
        let progress = total == 0 ? 1 : Double(completed) / Double(total)
        let previous = petMIPCineProgressKeys[key] ?? 0
        guard progress >= 1 || progress - previous >= 0.03 else { return }
        petMIPCineProgressKeys[key] = progress
        if petMIPCineProgressVolumeIdentity == volumeIdentity {
            petMIPCineProgressByAxis[axis] = progress
        }
    }

    private func startPETMIPCineWarmupForVolume(_ volume: ImageVolume) {
        guard Modality.normalize(volume.modality) == .PT else { return }
        if petMIPCineProgressVolumeIdentity != volume.sessionIdentity {
            petMIPCineProgressVolumeIdentity = volume.sessionIdentity
            petMIPCineProgressByAxis = [:]
        }
        cancelPETMIPWorkForOtherVolumes(keeping: volume.sessionIdentity)

        for axis in preferredPETMIPProjectionAxes(priorityAxis: nil) {
            let key = PETMIPProjectionKey(volume: volume, axis: axis, rotationDegrees: petMIPRotationDegrees)
            startPETMIPProjectionIfNeeded(volume: volume, axis: axis, key: key)
        }

        schedulePETMIPCineWarmupForVolume(volume)
    }

    private func schedulePETMIPCineWarmupForVolume(_ volume: ImageVolume) {
        let axes = preferredPETMIPProjectionAxes(priorityAxis: nil).filter { $0 != SlicePlane.axial.axis }
        guard !axes.isEmpty else { return }
        petMIPCineWarmupDebounceTask?.cancel()
        let delay = petMIPCineWarmupSettleDelayNanoseconds
        let centerTenths = Int((petMIPRotationDegrees * 10).rounded())
        petMIPCineWarmupDebounceTask = Task { @MainActor [weak self, volume, axes, delay, centerTenths] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard let self, !Task.isCancelled else { return }
            guard self.activePETQuantificationVolume?.sessionIdentity == volume.sessionIdentity else { return }
            for axis in axes {
                self.startPETMIPCineWarmupIfNeeded(volume: volume, axis: axis, around: centerTenths)
            }
        }
    }

    private func cancelPETMIPWorkForOtherVolumes(keeping volumeIdentity: String) {
        petMIPCineWarmupDebounceTask?.cancel()
        petMIPCineWarmupDebounceTask = nil
        let staleWarmups = petMIPCineWarmupTasks.keys.filter { $0.volumeIdentity != volumeIdentity }
        for key in staleWarmups {
            petMIPCineWarmupTasks[key]?.cancel()
            petMIPCineWarmupTasks.removeValue(forKey: key)
            petMIPCineWarmupTokens.removeValue(forKey: key)
        }

        let staleFull = petMIPProjectionTasks.keys.filter { $0.volumeIdentity != volumeIdentity }
        for key in staleFull {
            petMIPProjectionTasks[key]?.cancel()
            petMIPProjectionTasks.removeValue(forKey: key)
        }

        let stalePreview = petMIPPreviewProjectionTasks.keys.filter { $0.volumeIdentity != volumeIdentity }
        for key in stalePreview {
            petMIPPreviewProjectionTasks[key]?.cancel()
            petMIPPreviewProjectionTasks.removeValue(forKey: key)
        }
    }

    private func hasPETMIPProjectionRunning(for key: PETMIPProjectionKey) -> Bool {
        petMIPProjectionTasks[key] != nil
            || petMIPPreviewProjectionTasks[key] != nil
    }

    private func exactCachedPETMIPProjection(for key: PETMIPProjectionKey) -> PETMIPProjectionSelection? {
        if let projection = petMIPProjectionCache[key] {
            return PETMIPProjectionSelection(key: key, projection: projection)
        }
        if let projection = petMIPPreviewProjectionCache[key] {
            return PETMIPProjectionSelection(key: key, projection: projection)
        }
        return nil
    }

    private func exactFullCachedPETMIPProjection(for key: PETMIPProjectionKey) -> PETMIPProjectionSelection? {
        guard let projection = petMIPProjectionCache[key] else { return nil }
        return PETMIPProjectionSelection(key: key, projection: projection)
    }

    private func nearestCachedPETMIPProjection(for key: PETMIPProjectionKey) -> PETMIPProjectionSelection? {
        cachedPETMIPProjectionSelections(for: key).first
    }

    private func cachedFullPETMIPProjectionSelections(for key: PETMIPProjectionKey) -> [PETMIPProjectionSelection] {
        cachedPETMIPProjectionSelections(for: key, includePreview: false)
    }

    private func cachedPETMIPProjectionSelections(for key: PETMIPProjectionKey) -> [PETMIPProjectionSelection] {
        cachedPETMIPProjectionSelections(for: key, includePreview: true)
    }

    private func cachedPETMIPProjectionSelections(for key: PETMIPProjectionKey,
                                                  includePreview: Bool) -> [PETMIPProjectionSelection] {
        var candidates: [(distance: Int, qualityRank: Int, selection: PETMIPProjectionSelection)] = []

        func consider(_ candidateKey: PETMIPProjectionKey,
                      _ projection: PETMIPProjection,
                      qualityRank: Int) {
            guard candidateKey.sameVolumeAndAxis(as: key) else { return }
            let selection = PETMIPProjectionSelection(key: candidateKey, projection: projection)
            candidates.append((candidateKey.rotationDistanceTenths(to: key), qualityRank, selection))
        }

        for (candidateKey, projection) in petMIPProjectionCache {
            consider(candidateKey, projection, qualityRank: 0)
        }
        if includePreview {
            for (candidateKey, projection) in petMIPPreviewProjectionCache {
                consider(candidateKey, projection, qualityRank: 1)
            }
        }
        candidates.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.qualityRank < $1.qualityRank
        }
        return candidates.map(\.selection)
    }

    private func cancelStalePETMIPProjectionTasks(for key: PETMIPProjectionKey,
                                                  includeFull: Bool,
                                                  includePreview: Bool) {
        if includeFull {
            let staleKeys = petMIPProjectionTasks.keys.filter {
                $0 != key && $0.sameVolumeAndAxis(as: key)
            }
            for candidateKey in staleKeys {
                petMIPProjectionTasks[candidateKey]?.cancel()
                petMIPProjectionTasks.removeValue(forKey: candidateKey)
            }
        }
        if includePreview {
            let staleKeys = petMIPPreviewProjectionTasks.keys.filter {
                $0 != key && $0.sameVolumeAndAxis(as: key)
            }
            for candidateKey in staleKeys {
                petMIPPreviewProjectionTasks[candidateKey]?.cancel()
                petMIPPreviewProjectionTasks.removeValue(forKey: candidateKey)
            }
        }
    }

    private func storePETMIPProjection(_ projection: PETMIPProjection,
                                       for key: PETMIPProjectionKey,
                                       policy: ResourcePolicy = ResourcePolicy.load()) {
        petMIPProjectionCache[key] = projection
        petMIPProjectionCacheOrder.removeAll { $0 == key }
        petMIPProjectionCacheOrder.append(key)
        petMIPPreviewProjectionCache.removeValue(forKey: key)
        petMIPPreviewProjectionCacheOrder.removeAll { $0 == key }
        while petMIPProjectionCacheOrder.count > petMIPProjectionCacheLimit(policy: policy) {
            let evicted = petMIPProjectionCacheOrder.removeFirst()
            petMIPProjectionCache.removeValue(forKey: evicted)
        }
    }

    private func storePETMIPPreviewProjection(_ projection: PETMIPProjection,
                                              for key: PETMIPProjectionKey,
                                              policy: ResourcePolicy = ResourcePolicy.load(),
                                              notifyIfCurrent: Bool = false) {
        petMIPPreviewProjectionCache[key] = projection
        petMIPPreviewProjectionCacheOrder.removeAll { $0 == key }
        petMIPPreviewProjectionCacheOrder.append(key)
        while petMIPPreviewProjectionCacheOrder.count > petMIPProjectionCacheLimit(policy: policy) {
            let evicted = petMIPPreviewProjectionCacheOrder.removeFirst()
            petMIPPreviewProjectionCache.removeValue(forKey: evicted)
        }
        if notifyIfCurrent, let pet = activePETQuantificationVolume {
            let currentKey = PETMIPProjectionKey(volume: pet, axis: key.axis, rotationDegrees: petMIPRotationDegrees)
            if currentKey == key {
                petMIPCacheRevision += 1
            }
        }
    }

    private func petMIPProjectionCacheLimit(policy: ResourcePolicy) -> Int {
        max(PETMIPRotationConstants.minimumCachedProjectionFrames,
            policy.petMIPCacheEntries * 8)
    }

    private func startPETMIPPreviewProjectionIfNeeded(volume: ImageVolume,
                                                     axis: Int,
                                                     key: PETMIPProjectionKey) {
        guard key.needsRotatedProjection,
              petMIPPreviewProjectionCache[key] == nil,
              petMIPPreviewProjectionTasks[key] == nil,
              petMIPProjectionCache[key] == nil else { return }
        cancelStalePETMIPProjectionTasks(for: key, includeFull: true, includePreview: false)
        let policy = ResourcePolicy.load()
        guard petMIPPreviewProjectionTasks.count < max(1, policy.mipWorkerLimit) else { return }
        petMIPPreviewProjectionTasks[key] = Task { [weak self, volume, axis, key, policy] in
            let rotation = Double(key.rotationTenths) / 10
            let computeTask = Task.detached(priority: .userInitiated) {
                PETMIPProjection.compute(volume: volume,
                                         axis: axis,
                                         horizontalRotationDegrees: rotation,
                                         interactivePreview: true)
            }
            let projection = await withTaskCancellationHandler {
                await computeTask.value
            } onCancel: {
                computeTask.cancel()
            }
            guard let self else { return }
            self.petMIPPreviewProjectionTasks[key] = nil
            guard !Task.isCancelled else { return }
            self.storePETMIPPreviewProjection(projection, for: key, policy: policy)
            self.renderedPETMIPImage(for: projection, key: key, volume: volume, axis: axis)
            self.renderedPETMIPLabelImage(for: projection, key: key, volume: volume, axis: axis)
            self.petMIPCacheRevision += 1
        }
    }

    private func startPETMIPProjectionIfNeeded(volume: ImageVolume,
                                               axis: Int,
                                               key: PETMIPProjectionKey) {
        guard petMIPProjectionCache[key] == nil,
              petMIPProjectionTasks[key] == nil else { return }
        cancelStalePETMIPProjectionTasks(for: key, includeFull: true, includePreview: true)
        let policy = ResourcePolicy.load()
        guard petMIPProjectionTasks.count < policy.mipWorkerLimit else { return }
        petMIPProjectionTasks[key] = Task { [weak self, volume, axis, key, policy] in
            let rotation = key.axis == 2 ? 0 : Double(key.rotationTenths) / 10
            let computeTask = Task.detached(priority: policy.backgroundTaskPriority) {
                PETMIPProjection.compute(volume: volume,
                                         axis: axis,
                                         horizontalRotationDegrees: rotation,
                                         interactivePreview: false)
            }
            let projection = await withTaskCancellationHandler {
                await computeTask.value
            } onCancel: {
                computeTask.cancel()
            }
            guard let self else { return }
            self.petMIPProjectionTasks[key] = nil
            guard !Task.isCancelled else { return }
            self.storePETMIPProjection(projection, for: key, policy: policy)
            self.renderedPETMIPImage(for: projection, key: key, volume: volume, axis: axis)
            self.renderedPETMIPLabelImage(for: projection, key: key, volume: volume, axis: axis)
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
        guard isFile, MedicalVolumeFileIO.isVolumeFile(fileURL) else { continue }
        files.append(fileURL)
    }
    return files.sorted { $0.path < $1.path }
}
