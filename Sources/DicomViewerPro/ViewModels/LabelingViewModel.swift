import Foundation
import SwiftUI
import simd

/// State and operations for interactive labeling/segmentation.
@MainActor
public final class LabelingViewModel: ObservableObject {

    // MARK: - Label maps

    /// All label maps in the session (one per volume or per fusion pair).
    @Published public var labelMaps: [LabelMap] = []

    /// The currently active label map (writes go here).
    @Published public var activeLabelMap: LabelMap?

    /// The currently selected class ID for painting.
    @Published public var activeClassID: UInt16 = 1

    // MARK: - Tool state

    @Published public var labelingTool: LabelingTool = .none
    @Published public var brushRadius: Int = 3
    @Published public var brush3D: Bool = false

    // SUV/threshold controls
    @Published public var thresholdValue: Double = 2.5   // typical SUV cutoff
    @Published public var percentOfMax: Double = 0.4      // 40% of SUV_max (EANM)
    @Published public var regionGrowTolerance: Double = 50  // HU/intensity tolerance

    // MARK: - Landmark registration

    @Published public var landmarks: [LandmarkPair] = []
    @Published public var currentTransform: Transform3D = .identity
    @Published public var treMM: Double = 0.0

    // MARK: - Cross-linking

    @Published public var crosshair = CrosshairSync()

    // MARK: - Presets

    @Published public var availablePresets: [LabelPresetSet] = LabelPresets.all

    public init() {}

    // MARK: - Label map lifecycle

    /// Create a new empty label map for the given volume.
    @discardableResult
    public func createLabelMap(for volume: ImageVolume,
                                name: String = "Labels",
                                presetSet: LabelPresetSet? = nil) -> LabelMap {
        let map = LabelMap(
            parentSeriesUID: volume.seriesUID,
            depth: volume.depth,
            height: volume.height,
            width: volume.width,
            name: name,
            classes: presetSet?.classes ?? []
        )
        labelMaps.append(map)
        activeLabelMap = map
        if let first = map.classes.first {
            activeClassID = first.labelID
        }
        return map
    }

    /// Apply a preset to the active map — adds new classes (doesn't overwrite existing).
    public func applyPreset(_ preset: LabelPresetSet) {
        guard let map = activeLabelMap else { return }
        let existing = Set(map.classes.map { $0.labelID })
        for cls in preset.classes where !existing.contains(cls.labelID) {
            map.classes.append(cls)
        }
        if let first = preset.classes.first {
            activeClassID = first.labelID
        }
    }

    public func selectClass(_ id: UInt16) {
        activeClassID = id
    }

    public func addClass(name: String, color: Color,
                         category: LabelCategory = .custom) {
        guard let map = activeLabelMap else { return }
        map.addClass(LabelClass(name: name, category: category, color: color))
    }

    public func removeLabelMap(_ map: LabelMap) {
        labelMaps.removeAll { $0.id == map.id }
        if activeLabelMap?.id == map.id {
            activeLabelMap = labelMaps.first
        }
    }

    // MARK: - Brush painting

    public func paint(axis: Int, sliceIndex: Int, pixelX: Int, pixelY: Int,
                      erase: Bool = false) {
        guard let map = activeLabelMap else { return }
        if brush3D {
            let (z, y, x) = voxelCoordForClick(axis: axis, sliceIndex: sliceIndex,
                                                pixelX: pixelX, pixelY: pixelY)
            BrushTool.paint3D(label: map, z: z, y: y, x: x,
                              radius: brushRadius, classID: activeClassID,
                              mode: erase ? .erase : .paint)
        } else {
            BrushTool.paint2D(label: map, axis: axis, sliceIndex: sliceIndex,
                              pixelX: pixelX, pixelY: pixelY,
                              radius: brushRadius, classID: activeClassID,
                              mode: erase ? .erase : .paint)
        }
        map.objectWillChange.send()
    }

    public func paintStroke(axis: Int, sliceIndex: Int,
                             from: (Int, Int), to: (Int, Int),
                             erase: Bool = false) {
        guard let map = activeLabelMap else { return }
        BrushTool.paintLine(label: map, axis: axis, sliceIndex: sliceIndex,
                            fromX: from.0, fromY: from.1,
                            toX: to.0, toY: to.1,
                            radius: brushRadius, classID: activeClassID,
                            mode: erase ? .erase : .paint)
        map.objectWillChange.send()
    }

    // MARK: - PET-specific segmentation

    /// Fixed threshold across the whole volume.
    public func thresholdAll(volume: ImageVolume, above: Double) {
        guard let map = activeLabelMap else { return }
        PETSegmentation.thresholdAbove(
            volume: volume, label: map,
            threshold: above, classID: activeClassID
        )
        map.objectWillChange.send()
    }

    /// 40% of max inside a bounding box around a seed.
    public func percentOfMaxAroundSeed(volume: ImageVolume,
                                       seed: (z: Int, y: Int, x: Int),
                                       boxRadius: Int = 30,
                                       percent: Double) {
        guard let map = activeLabelMap else { return }
        let box = VoxelBox.around(seed, radius: boxRadius, in: volume)
        PETSegmentation.percentOfMax(
            volume: volume, label: map,
            percent: percent, classID: activeClassID, boundingBox: box
        )
        map.objectWillChange.send()
    }

    /// Region grow from a seed voxel.
    public func regionGrow(volume: ImageVolume,
                           seed: (z: Int, y: Int, x: Int),
                           tolerance: Double) {
        guard let map = activeLabelMap else { return }
        PETSegmentation.regionGrow(
            volume: volume, label: map,
            seed: seed, tolerance: tolerance,
            classID: activeClassID
        )
        map.objectWillChange.send()
    }

    // MARK: - Morphology

    public func dilateActive(iterations: Int = 1) {
        guard let map = activeLabelMap else { return }
        PETSegmentation.dilate(label: map, classID: activeClassID, iterations: iterations)
        map.objectWillChange.send()
    }

    public func erodeActive(iterations: Int = 1) {
        guard let map = activeLabelMap else { return }
        PETSegmentation.erode(label: map, classID: activeClassID, iterations: iterations)
        map.objectWillChange.send()
    }

    // MARK: - Landmark registration

    public func addLandmark(fixed: SIMD3<Double>, moving: SIMD3<Double>,
                             label: String = "") {
        landmarks.append(LandmarkPair(fixed: fixed, moving: moving, label: label))
        updateTransform()
    }

    public func removeLandmark(id: UUID) {
        landmarks.removeAll { $0.id == id }
        updateTransform()
    }

    public func clearLandmarks() {
        landmarks.removeAll()
        currentTransform = .identity
        treMM = 0
    }

    public func updateTransform() {
        if landmarks.count >= 3 {
            currentTransform = LandmarkRegistration.rigid(landmarks: landmarks)
            treMM = LandmarkRegistration.tre(currentTransform, landmarks: landmarks)
        } else {
            currentTransform = .identity
            treMM = 0
        }
    }

    // MARK: - Label migration

    /// Migrate the active label map to the target volume via `currentTransform`.
    public func migrateActiveLabel(sourceVolume: ImageVolume,
                                    toTarget target: ImageVolume) -> LabelMap? {
        guard let map = activeLabelMap else { return nil }
        let migrated = LabelMigration.migrate(
            source: map,
            sourceVolume: sourceVolume,
            targetVolume: target,
            transform: currentTransform
        )
        labelMaps.append(migrated)
        return migrated
    }

    // MARK: - Coordinate helpers

    public func voxelCoordForClick(axis: Int, sliceIndex: Int,
                                    pixelX: Int, pixelY: Int) -> (z: Int, y: Int, x: Int) {
        switch axis {
        case 0: return (z: pixelY, y: pixelX, x: sliceIndex)
        case 1: return (z: pixelY, y: sliceIndex, x: pixelX)
        default: return (z: sliceIndex, y: pixelY, x: pixelX)
        }
    }

    // MARK: - I/O

    public func saveActiveLabel(to url: URL, format: LabelIO.Format,
                                 parentVolume: ImageVolume) throws {
        guard let map = activeLabelMap else { return }
        switch format {
        case .niftiLabelmap, .niftiGz, .itkSnap:
            try LabelIO.saveNIfTI(map, to: url, parentVolume: parentVolume,
                                   writeLabelDescriptor: true)
        case .nrrdLabelmap:
            try LabelIO.saveNRRD(map, to: url, parentVolume: parentVolume)
        case .slicerSeg:
            try LabelIO.saveSlicerSeg(map, to: url, parentVolume: parentVolume)
        case .json:
            try LabelIO.saveJSON(labelMap: map, annotations: [], to: url)
        case .csv:
            try LabelIO.saveLandmarks(landmarks, to: url)
        case .dicomSeg, .dicomRTStruct:
            // TODO: DICOM SEG / RTSTRUCT export is planned (reader is included)
            throw NSError(domain: "LabelIO", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "DICOM SEG/RTSTRUCT export not yet implemented; use NIfTI or NRRD"])
        }
    }

    public func loadLabel(from url: URL, parentVolume: ImageVolume) throws {
        let name = url.lastPathComponent.lowercased()
        let map: LabelMap
        if name.hasSuffix(".seg.nrrd") || name.hasSuffix(".nrrd") {
            // TODO: NRRD reader; for now fall back to treating as NIfTI if possible
            throw NSError(domain: "LabelIO", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "NRRD reader not yet implemented — convert to NIfTI first"])
        } else if name.hasSuffix(".nii") || name.hasSuffix(".nii.gz") {
            map = try LabelIO.loadNIfTILabelmap(from: url, parentVolume: parentVolume)
        } else if name.hasSuffix(".dcm") {
            // Try RTSTRUCT
            map = try RTStructIO.loadRTStruct(from: url, referenceVolume: parentVolume)
        } else {
            throw NSError(domain: "LabelIO", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported label file: \(name)"])
        }
        labelMaps.append(map)
        activeLabelMap = map
        if let first = map.classes.first {
            activeClassID = first.labelID
        }
    }
}

public enum LabelingTool: String, CaseIterable, Identifiable {
    case none, brush, eraser, threshold, regionGrow, landmark

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none:       return "—"
        case .brush:      return "Brush"
        case .eraser:     return "Eraser"
        case .threshold:  return "Threshold"
        case .regionGrow: return "Region Grow"
        case .landmark:   return "Landmark"
        }
    }
    public var systemImage: String {
        switch self {
        case .none:       return "hand.point.up"
        case .brush:      return "paintbrush.pointed"
        case .eraser:     return "eraser"
        case .threshold:  return "thermometer.medium"
        case .regionGrow: return "drop"
        case .landmark:   return "mappin.and.ellipse"
        }
    }

    /// Rich description shown as hover tooltip in panels.
    public var helpText: String {
        switch self {
        case .none:
            return "Viewer mode\nUse the main toolbar tools (W/L, Pan, Zoom, Measure)."
        case .brush:
            return "Brush\n"
                 + "Click and drag on any slice to paint voxels with the active class.\n"
                 + "Adjust brush size below. Toggle 3D to paint a sphere through\n"
                 + "multiple slices at once."
        case .eraser:
            return "Eraser\n"
                 + "Click and drag to erase voxels back to background (label 0)."
        case .threshold:
            return "Threshold / SUV Segmentation\n"
                 + "• Click 'Apply' to segment the whole volume by fixed intensity\n"
                 + "  threshold (e.g., SUV ≥ 2.5 for PET lesions)\n"
                 + "• Click a seed voxel to auto-segment by 40% of SUVmax around it\n"
                 + "  (EANM-standard PET tumor delineation)"
        case .regionGrow:
            return "Region Growing\n"
                 + "Click a seed voxel; flood-fills connected voxels whose intensity\n"
                 + "is within ±tolerance of the seed. Useful for delineating\n"
                 + "homogeneous regions like organs."
        case .landmark:
            return "Landmark Registration\n"
                 + "Click matching anatomical points in the fixed and moving\n"
                 + "volumes. After 3+ pairs, a rigid transform is computed\n"
                 + "and TRE is reported. Use 'Migrate Label' to transfer\n"
                 + "the mask across volumes."
        }
    }
}
