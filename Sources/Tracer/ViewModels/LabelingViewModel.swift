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

    @Published public private(set) var undoDepth: Int = 0
    @Published public private(set) var redoDepth: Int = 0
    @Published public private(set) var hasUnsavedChanges: Bool = false

    // MARK: - Tool state

    @Published public var labelingTool: LabelingTool = .none
    @Published public var brushRadius: Int = 3
    @Published public var brush3D: Bool = false

    // SUV/threshold controls
    @Published public var thresholdValue: Double = 2.5   // typical SUV cutoff
    @Published public var percentOfMax: Double = 0.4      // 40% of SUV_max (EANM)
    @Published public var gradientCutoffFraction: Double = 0.45
    @Published public var gradientSearchRadius: Int = 30
    @Published public var regionGrowTolerance: Double = 50  // HU/intensity tolerance

    /// Sphere radius in **mm** for the Quick Lesion tool. 8 mm covers a
    /// typical small (≤ 1 cm) FDG-avid lesion comfortably while leaving
    /// the surrounding background voxels out, which is what the
    /// downstream radiomics features want for a sharp signature.
    /// Range exposed in the UI: 3 – 30 mm.
    @Published public var lesionSphereRadiusMM: Double = 8.0

    /// Stable id used by `placeLesionSphere` so every quick-lesion
    /// click joins the same class — separate connected components,
    /// one classifier sweep over them all. Persisted only as a
    /// memoised lookup; the actual class lives in the active label map.
    public static let quickLesionClassName = "Quick Lesions"

    // MARK: - Landmark registration

    @Published public var landmarks: [LandmarkPair] = []
    @Published public var currentTransform: Transform3D = .identity
    @Published public var treMM: Double = 0.0
    @Published public var landmarkCaptureTarget: LandmarkCaptureTarget = .fixed
    @Published public var pendingFixedLandmark: SIMD3<Double>?
    @Published public var pendingMovingLandmark: SIMD3<Double>?

    // MARK: - Cross-linking

    @Published public var crosshair = CrosshairSync()

    // MARK: - Presets

    @Published public var availablePresets: [LabelPresetSet] = LabelPresets.all

    private struct VoxelEditRecord {
        let mapID: UUID
        let name: String
        let indices: [Int]
        let before: [UInt16]
        let after: [UInt16]

        /// Approximate resident memory used by this record's sparse diff.
        /// Indices are `Int` (8 B on 64-bit) and `before`/`after` are `UInt16` (2 B each).
        var byteSize: Int {
            indices.count * (MemoryLayout<Int>.stride + 2 * MemoryLayout<UInt16>.stride)
        }
    }

    private var undoStack: [VoxelEditRecord] = []
    private var redoStack: [VoxelEditRecord] = []
    private var activeEditBaseline: (mapID: UUID, name: String, voxels: [UInt16])?
    private var currentHistoryBytes: Int = 0
    private let maxUndoRecords = 40
    private let maxTrackedChangedVoxels = 5_000_000
    /// Total resident memory budget for undo + redo stacks (256 MB).
    /// Older records are evicted when appending a new edit would exceed this.
    private let maxHistoryBytes = 256 * 1024 * 1024

    /// Published so the UI can show how much undo memory the session is using.
    @Published public private(set) var historyMemoryBytes: Int = 0

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
        hasUnsavedChanges = true
        return map
    }

    /// Apply a preset to the active map — adds new classes (doesn't overwrite existing).
    public func applyPreset(_ preset: LabelPresetSet) {
        guard let map = activeLabelMap else { return }
        let existing = Set(map.classes.map { $0.labelID })
        var added = false
        for cls in preset.classes where !existing.contains(cls.labelID) {
            map.classes.append(cls)
            added = true
        }
        if let first = preset.classes.first {
            activeClassID = first.labelID
        }
        if added {
            hasUnsavedChanges = true
            map.objectWillChange.send()
        }
    }

    public func selectClass(_ id: UInt16) {
        activeClassID = id
    }

    public func addClass(name: String, color: Color,
                         category: LabelCategory = .custom) {
        guard let map = activeLabelMap else { return }
        map.addClass(LabelClass(name: name, category: category, color: color))
        hasUnsavedChanges = true
        map.objectWillChange.send()
    }

    public func removeLabelMap(_ map: LabelMap) {
        labelMaps.removeAll { $0.id == map.id }
        if activeLabelMap?.id == map.id {
            activeLabelMap = labelMaps.first
        }
        let reclaimed = (undoStack + redoStack)
            .filter { $0.mapID == map.id }
            .reduce(0) { $0 + $1.byteSize }
        currentHistoryBytes -= reclaimed
        if currentHistoryBytes < 0 { currentHistoryBytes = 0 }
        undoStack.removeAll { $0.mapID == map.id }
        redoStack.removeAll { $0.mapID == map.id }
        refreshHistoryDepths()
        hasUnsavedChanges = true
    }

    public func beginVoxelEdit(named name: String) {
        guard activeEditBaseline == nil, let map = activeLabelMap else { return }
        activeEditBaseline = (map.id, name, map.voxels)
    }

    public func commitVoxelEdit() {
        guard let baseline = activeEditBaseline else { return }
        activeEditBaseline = nil
        guard let map = labelMaps.first(where: { $0.id == baseline.mapID }) else { return }
        recordVoxelChanges(map: map, name: baseline.name, before: baseline.voxels)
    }

    public func cancelVoxelEdit() {
        activeEditBaseline = nil
    }

    public func recordVoxelEdit(named name: String, _ body: () -> Void) {
        guard activeEditBaseline == nil, let map = activeLabelMap else {
            body()
            return
        }
        let before = map.voxels
        body()
        recordVoxelChanges(map: map, name: name, before: before)
    }

    @discardableResult
    public func applyVoxelReplacement(mapID: UUID,
                                      voxels: [UInt16],
                                      diff: VoxelEditDiff,
                                      name: String) -> Bool {
        guard let map = labelMaps.first(where: { $0.id == mapID }),
              voxels.count == map.voxels.count else {
            return false
        }

        if diff.isEmpty {
            return false
        }

        if diff.overflowed {
            clearHistory()
        } else {
            guard diff.indices.count == diff.before.count,
                  diff.indices.count == diff.after.count else {
                return false
            }
            dropRedoStack()
            let record = VoxelEditRecord(
                mapID: map.id,
                name: name,
                indices: diff.indices,
                before: diff.before,
                after: diff.after
            )
            undoStack.append(record)
            currentHistoryBytes += record.byteSize
            trimHistoryToLimits()
        }

        map.voxels = voxels
        activeLabelMap = map
        hasUnsavedChanges = true
        map.objectWillChange.send()
        refreshHistoryDepths()
        return true
    }

    public func markSaved() {
        hasUnsavedChanges = false
    }

    public func markDirty() {
        hasUnsavedChanges = true
    }

    public func undo() {
        guard let record = undoStack.popLast(),
              let map = labelMaps.first(where: { $0.id == record.mapID }) else {
            refreshHistoryDepths()
            return
        }
        for i in 0..<record.indices.count {
            map.voxels[record.indices[i]] = record.before[i]
        }
        redoStack.append(record)
        activeLabelMap = map
        hasUnsavedChanges = true
        map.objectWillChange.send()
        refreshHistoryDepths()
    }

    public func redo() {
        guard let record = redoStack.popLast(),
              let map = labelMaps.first(where: { $0.id == record.mapID }) else {
            refreshHistoryDepths()
            return
        }
        for i in 0..<record.indices.count {
            map.voxels[record.indices[i]] = record.after[i]
        }
        undoStack.append(record)
        activeLabelMap = map
        hasUnsavedChanges = true
        map.objectWillChange.send()
        refreshHistoryDepths()
    }

    @discardableResult
    public func resetActiveClass() -> Int {
        applyMutation(named: "Reset active class") { map in
            var changed = 0
            for i in 0..<map.voxels.count where map.voxels[i] == activeClassID {
                map.voxels[i] = 0
                changed += 1
            }
            return changed
        } ?? 0
    }

    @discardableResult
    public func resetActiveLabelMap() -> Int {
        applyMutation(named: "Reset label map") { map in
            let changed = map.voxels.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
            map.voxels = [UInt16](repeating: 0, count: map.voxels.count)
            return changed
        } ?? 0
    }

    @discardableResult
    public func resetAllLabelMaps() -> Int {
        let originalID = activeLabelMap?.id
        var total = 0
        for map in labelMaps {
            activeLabelMap = map
            total += resetActiveLabelMap()
        }
        activeLabelMap = labelMaps.first { $0.id == originalID } ?? labelMaps.first
        return total
    }

    // MARK: - Brush painting

    public func paint(axis: Int, sliceIndex: Int, pixelX: Int, pixelY: Int,
                      erase: Bool = false, recordUndo: Bool = true) {
        guard let map = activeLabelMap else { return }
        let ownsEdit = recordUndo && activeEditBaseline == nil
        if ownsEdit { beginVoxelEdit(named: erase ? "Erase" : "Paint") }
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
        if ownsEdit { commitVoxelEdit() } else { hasUnsavedChanges = true }
        map.objectWillChange.send()
    }

    public func paintStroke(axis: Int, sliceIndex: Int,
                             from: (Int, Int), to: (Int, Int),
                             erase: Bool = false, recordUndo: Bool = true) {
        guard let map = activeLabelMap else { return }
        let ownsEdit = recordUndo && activeEditBaseline == nil
        if ownsEdit { beginVoxelEdit(named: erase ? "Erase stroke" : "Paint stroke") }
        BrushTool.paintLine(label: map, axis: axis, sliceIndex: sliceIndex,
                            fromX: from.0, fromY: from.1,
                            toX: to.0, toY: to.1,
                            radius: brushRadius, classID: activeClassID,
                            mode: erase ? .erase : .paint)
        if ownsEdit { commitVoxelEdit() } else { hasUnsavedChanges = true }
        map.objectWillChange.send()
    }

    // MARK: - PET-specific segmentation

    /// Fixed threshold across the whole volume.
    public func thresholdAll(volume: ImageVolume,
                             above: Double,
                             valueTransform: ((Double) -> Double)? = nil) {
        applyMutation(named: "Threshold") { map in
            PETSegmentation.thresholdAbove(
                volume: volume, label: map,
                threshold: above, classID: activeClassID,
                valueTransform: valueTransform
            )
        }
    }

    /// 40% of max inside a bounding box around a seed.
    public func percentOfMaxAroundSeed(volume: ImageVolume,
                                       seed: (z: Int, y: Int, x: Int),
                                       boxRadius: Int = 30,
                                       percent: Double,
                                       valueTransform: ((Double) -> Double)? = nil) {
        let box = VoxelBox.around(seed, radius: boxRadius, in: volume)
        applyMutation(named: "Percent of max") { map in
            PETSegmentation.percentOfMax(
                volume: volume, label: map,
                percent: percent, classID: activeClassID, boundingBox: box,
                valueTransform: valueTransform
            )
        }
    }

    /// Region grow from a seed voxel.
    public func regionGrow(volume: ImageVolume,
                           seed: (z: Int, y: Int, x: Int),
                           tolerance: Double) {
        applyMutation(named: "Region grow") { map in
            PETSegmentation.regionGrow(
                volume: volume, label: map,
                seed: seed, tolerance: tolerance,
                classID: activeClassID
            )
        }
    }

    @discardableResult
    public func gradientEdge(volume: ImageVolume,
                             seed: (z: Int, y: Int, x: Int),
                             minimumValue: Double,
                             gradientCutoffFraction: Double,
                             searchRadius: Int,
                             valueTransform: ((Double) -> Double)? = nil) -> PETGradientSegmentationResult {
        applyMutation(named: "SUV gradient edge") { map in
            PETSegmentation.gradientEdge(
                volume: volume,
                label: map,
                seed: seed,
                minimumValue: minimumValue,
                gradientCutoffFraction: gradientCutoffFraction,
                classID: activeClassID,
                searchRadius: searchRadius,
                valueTransform: valueTransform
            )
        } ?? .empty(minimumValue: minimumValue)
    }

    // MARK: - Morphology

    public func dilateActive(iterations: Int = 1) {
        applyMutation(named: "Dilate") { map in
            PETSegmentation.dilate(label: map, classID: activeClassID, iterations: iterations)
        }
    }

    public func erodeActive(iterations: Int = 1) {
        applyMutation(named: "Erode") { map in
            PETSegmentation.erode(label: map, classID: activeClassID, iterations: iterations)
        }
    }

    @discardableResult
    public func keepLargestIslandActive() -> Int {
        applyMutation(named: "Keep largest island") { map in
            LabelOperations.keepLargestIsland(label: map, classID: activeClassID)
        } ?? 0
    }

    @discardableResult
    public func removeSmallIslandsActive(minVoxels: Int) -> Int {
        applyMutation(named: "Remove small islands") { map in
            LabelOperations.removeSmallIslands(
                label: map,
                classID: activeClassID,
                minVoxels: minVoxels
            )
        } ?? 0
    }

    @discardableResult
    public func applyLogicalOperation(sourceClassID: UInt16,
                                      operation: LabelLogicalOperation) -> Int {
        applyMutation(named: operation.displayName) { map in
            LabelOperations.logical(
                label: map,
                targetID: activeClassID,
                modifierID: sourceClassID,
                operation: operation
            )
        } ?? 0
    }

    // MARK: - Landmark registration

    public func addLandmark(fixed: SIMD3<Double>, moving: SIMD3<Double>,
                             label: String = "") {
        landmarks.append(LandmarkPair(fixed: fixed, moving: moving, label: label))
        updateTransform()
    }

    @discardableResult
    public func captureLandmarkPoint(_ point: SIMD3<Double>) -> String {
        switch landmarkCaptureTarget {
        case .fixed:
            if let moving = pendingMovingLandmark {
                addLandmarkPair(fixed: point, moving: moving)
                pendingMovingLandmark = nil
                landmarkCaptureTarget = .fixed
                return "Landmark pair \(landmarks.count) captured"
            }
            pendingFixedLandmark = point
            landmarkCaptureTarget = .moving
            return "Fixed point captured; switch to the moving volume and click its match"

        case .moving:
            if let fixed = pendingFixedLandmark {
                addLandmarkPair(fixed: fixed, moving: point)
                pendingFixedLandmark = nil
                landmarkCaptureTarget = .fixed
                return "Landmark pair \(landmarks.count) captured"
            }
            pendingMovingLandmark = point
            landmarkCaptureTarget = .fixed
            return "Moving point captured; switch to the fixed volume and click its match"
        }
    }

    public func cancelPendingLandmark() {
        pendingFixedLandmark = nil
        pendingMovingLandmark = nil
        landmarkCaptureTarget = .fixed
    }

    public func removeLandmark(id: UUID) {
        landmarks.removeAll { $0.id == id }
        updateTransform()
    }

    public func clearLandmarks() {
        landmarks.removeAll()
        cancelPendingLandmark()
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

    // MARK: - Quick Lesion (sphere seed) tool

    /// Drop a small spherical lesion mask centered on the given voxel,
    /// painted into the "Quick Lesions" class of the active label map.
    /// Skips the full segmentation pipeline so the user can produce a
    /// classifier-ready label in seconds.
    ///
    /// Behaviour:
    ///   • If no active label map exists, one is created on `parentVolume`'s
    ///     grid.
    ///   • If the "Quick Lesions" class doesn't yet exist, it's appended
    ///     with an orange colour. Subsequent calls reuse the same class
    ///     id, so two clicks → one class with two connected components,
    ///     which `PETQuantification.compute(connectedComponents: true)`
    ///     enumerates as two separate lesions.
    ///   • Sphere geometry is computed in **mm space** (radius is in mm),
    ///     so an anisotropic 5 mm × 5 mm × 3 mm volume gets a correctly-
    ///     elongated voxel sphere.
    ///   • Voxels outside the volume bounds are clipped silently.
    ///   • The new class is set active so the user can continue clicking.
    ///
    /// - Returns: the class id used, or nil when the inputs are invalid.
    @discardableResult
    public func placeLesionSphere(centerVoxel seed: (z: Int, y: Int, x: Int),
                                  radiusMM: Double,
                                  parentVolume: ImageVolume) -> UInt16? {
        guard radiusMM > 0 else { return nil }

        // Ensure we have a label map on the same grid as the volume the
        // user just clicked. Existing maps that don't match the click
        // are left alone; we make a fresh one for this volume.
        let map: LabelMap
        if let existing = activeLabelMap,
           existing.depth == parentVolume.depth,
           existing.height == parentVolume.height,
           existing.width == parentVolume.width {
            map = existing
        } else {
            map = createLabelMap(for: parentVolume,
                                 name: "Quick Lesions",
                                 presetSet: nil)
        }

        // Find or create the "Quick Lesions" class entry. Reusing the
        // same class id across multiple clicks means components stay
        // separable in the classifier loop.
        let classID: UInt16
        if let existing = map.classes.first(where: {
            $0.name.caseInsensitiveCompare(Self.quickLesionClassName) == .orderedSame
        }) {
            classID = existing.labelID
        } else {
            classID = map.addClass(LabelClass(
                name: Self.quickLesionClassName,
                category: .lesion,
                color: .orange
            ))
        }
        activeClassID = classID

        // Mm-space sphere → voxel-space ellipsoid (handles anisotropic
        // spacing). Distance check uses (dx_mm)² + (dy_mm)² + (dz_mm)²
        // ≤ r² so the result is a real sphere in patient space.
        let r2 = radiusMM * radiusMM
        let sx = parentVolume.spacing.x
        let sy = parentVolume.spacing.y
        let sz = parentVolume.spacing.z
        let xRadiusVox = max(1, Int((radiusMM / max(sx, 1e-9)).rounded(.up)))
        let yRadiusVox = max(1, Int((radiusMM / max(sy, 1e-9)).rounded(.up)))
        let zRadiusVox = max(1, Int((radiusMM / max(sz, 1e-9)).rounded(.up)))
        let zMin = Swift.max(0, seed.z - zRadiusVox)
        let zMax = Swift.min(parentVolume.depth - 1, seed.z + zRadiusVox)
        let yMin = Swift.max(0, seed.y - yRadiusVox)
        let yMax = Swift.min(parentVolume.height - 1, seed.y + yRadiusVox)
        let xMin = Swift.max(0, seed.x - xRadiusVox)
        let xMax = Swift.min(parentVolume.width - 1, seed.x + xRadiusVox)

        let w = parentVolume.width, h = parentVolume.height
        for z in zMin...zMax {
            let dz = Double(z - seed.z) * sz
            let dz2 = dz * dz
            for y in yMin...yMax {
                let dy = Double(y - seed.y) * sy
                let yzSq = dz2 + dy * dy
                if yzSq > r2 { continue }
                let rowStart = z * h * w + y * w
                for x in xMin...xMax {
                    let dx = Double(x - seed.x) * sx
                    if yzSq + dx * dx <= r2 {
                        map.voxels[rowStart + x] = classID
                    }
                }
            }
        }

        hasUnsavedChanges = true
        map.objectWillChange.send()
        return classID
    }

    /// Reset the "Quick Lesions" class back to background — useful when
    /// the user wants to redo their seeds without juggling other classes.
    /// No-op when the active map has no quick-lesion class.
    public func clearQuickLesions() {
        guard let map = activeLabelMap,
              let cls = map.classes.first(where: {
                  $0.name.caseInsensitiveCompare(Self.quickLesionClassName) == .orderedSame
              }) else { return }
        let id = cls.labelID
        for i in 0..<map.voxels.count where map.voxels[i] == id {
            map.voxels[i] = 0
        }
        hasUnsavedChanges = true
        map.objectWillChange.send()
    }

    // MARK: - I/O

    public func saveActiveLabel(to url: URL,
                                format: LabelIO.Format,
                                parentVolume: ImageVolume,
                                annotations: [Annotation] = []) throws {
        guard let map = activeLabelMap else { return }
        switch format {
        case .labelPackage:
            try LabelIO.saveLabelPackage(labelMap: map,
                                         annotations: annotations,
                                         landmarks: landmarks,
                                         parentVolume: parentVolume,
                                         to: url)
        case .niftiLabelmap, .itkSnap:
            try LabelIO.saveNIfTI(map, to: url, parentVolume: parentVolume,
                                   writeLabelDescriptor: true)
        case .niftiGz:
            try LabelIO.saveNIfTIGz(map, to: url, parentVolume: parentVolume,
                                     writeLabelDescriptor: true)
        case .nrrdLabelmap:
            try LabelIO.saveNRRD(map, to: url, parentVolume: parentVolume)
        case .slicerSeg:
            try LabelIO.saveSlicerSeg(map, to: url, parentVolume: parentVolume)
        case .json:
            try LabelIO.saveJSON(labelMap: map, annotations: annotations, to: url)
        case .csv:
            try LabelIO.saveLandmarks(landmarks, to: url)
        case .dicomSeg, .dicomRTStruct:
            // TODO: DICOM SEG / RTSTRUCT export is planned (reader is included)
            throw NSError(domain: "LabelIO", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "DICOM SEG/RTSTRUCT export not yet implemented; use NIfTI or NRRD"])
        }
        markSaved()
    }

    @discardableResult
    public func loadLabel(from url: URL, parentVolume: ImageVolume) throws -> LabelImportResult {
        let name = url.lastPathComponent.lowercased()
        let result: LabelImportResult
        if name.hasSuffix(".dvlabels") {
            let package = try LabelIO.loadLabelPackage(from: url, parentVolume: parentVolume)
            result = LabelImportResult(
                labelMap: package.labelMap,
                annotations: package.annotations,
                landmarks: package.landmarks
            )
        } else if name.hasSuffix(".seg.nrrd") || name.hasSuffix(".nrrd") {
            result = LabelImportResult(
                labelMap: try LabelIO.loadNRRDLabelmap(from: url, parentVolume: parentVolume),
                annotations: [],
                landmarks: []
            )
        } else if name.hasSuffix(".nii") || name.hasSuffix(".nii.gz") {
            result = LabelImportResult(
                labelMap: try LabelIO.loadNIfTILabelmap(from: url, parentVolume: parentVolume),
                annotations: [],
                landmarks: []
            )
        } else if name.hasSuffix(".dcm") {
            // Try RTSTRUCT
            result = LabelImportResult(
                labelMap: try RTStructIO.loadRTStruct(from: url, referenceVolume: parentVolume),
                annotations: [],
                landmarks: []
            )
        } else {
            throw NSError(domain: "LabelIO", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported label file: \(name)"])
        }
        let map = result.labelMap
        labelMaps.append(map)
        activeLabelMap = map
        if let first = map.classes.first {
            activeClassID = first.labelID
        }
        if !result.landmarks.isEmpty {
            landmarks = result.landmarks
            updateTransform()
        }
        clearHistory()
        markSaved()
        return result
    }

    private func addLandmarkPair(fixed: SIMD3<Double>, moving: SIMD3<Double>) {
        let label = "LM\(landmarks.count + 1)"
        landmarks.append(LandmarkPair(fixed: fixed, moving: moving, label: label))
        updateTransform()
    }

    /// Single path for every label-voxel mutation on the active map.
    ///
    /// Handles the three things every mutation needs:
    /// 1. Guard — returns `nil` when no map is active.
    /// 2. Undo — records the before/after diff under `name`.
    /// 3. Signal — fires `objectWillChange` on the mutated map so SwiftUI
    ///    refreshes overlays that observe it.
    ///
    /// Using this helper instead of the `recordVoxelEdit + map.objectWillChange.send()`
    /// pattern prevents the signal from being forgotten at a new call site.
    @discardableResult
    private func applyMutation<T>(named name: String,
                                  _ body: (LabelMap) -> T) -> T? {
        guard let map = activeLabelMap else { return nil }
        var result: T?
        recordVoxelEdit(named: name) {
            result = body(map)
        }
        map.objectWillChange.send()
        return result
    }

    private func recordVoxelChanges(map: LabelMap, name: String, before: [UInt16]) {
        guard before.count == map.voxels.count else { return }
        var indices: [Int] = []
        var oldValues: [UInt16] = []
        var newValues: [UInt16] = []

        for i in 0..<before.count where before[i] != map.voxels[i] {
            if indices.count >= maxTrackedChangedVoxels {
                clearHistory()
                hasUnsavedChanges = true
                return
            }
            indices.append(i)
            oldValues.append(before[i])
            newValues.append(map.voxels[i])
        }

        guard !indices.isEmpty else { return }
        // A new forward edit invalidates the redo stack — reclaim its bytes.
        dropRedoStack()

        let record = VoxelEditRecord(
            mapID: map.id,
            name: name,
            indices: indices,
            before: oldValues,
            after: newValues
        )
        undoStack.append(record)
        currentHistoryBytes += record.byteSize
        trimHistoryToLimits()
        hasUnsavedChanges = true
        refreshHistoryDepths()
    }

    /// Drop the oldest records until both count and byte budgets are met.
    private func trimHistoryToLimits() {
        if undoStack.count > maxUndoRecords {
            let overflow = undoStack.count - maxUndoRecords
            for record in undoStack.prefix(overflow) {
                currentHistoryBytes -= record.byteSize
            }
            undoStack.removeFirst(overflow)
        }
        while currentHistoryBytes > maxHistoryBytes {
            if let oldest = undoStack.first {
                currentHistoryBytes -= oldest.byteSize
                undoStack.removeFirst()
            } else if let oldestRedo = redoStack.first {
                // Shouldn't normally happen — redo is cleared on new edits — but
                // guard the invariant so we never overcount.
                currentHistoryBytes -= oldestRedo.byteSize
                redoStack.removeFirst()
            } else {
                break
            }
        }
        if currentHistoryBytes < 0 { currentHistoryBytes = 0 }
    }

    private func dropRedoStack() {
        let redoBytes = redoStack.reduce(0) { $0 + $1.byteSize }
        currentHistoryBytes -= redoBytes
        if currentHistoryBytes < 0 { currentHistoryBytes = 0 }
        redoStack.removeAll()
    }

    private func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        activeEditBaseline = nil
        currentHistoryBytes = 0
        refreshHistoryDepths()
    }

    private func refreshHistoryDepths() {
        undoDepth = undoStack.count
        redoDepth = redoStack.count
        historyMemoryBytes = currentHistoryBytes
    }
}

public struct LabelImportResult {
    public let labelMap: LabelMap
    public let annotations: [Annotation]
    public let landmarks: [LandmarkPair]
}

public enum LabelingTool: String, CaseIterable, Identifiable, Sendable {
    case none, brush, eraser, threshold, suvGradient, regionGrow, landmark, lesionSphere

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none:         return "—"
        case .brush:        return "Brush"
        case .eraser:       return "Eraser"
        case .threshold:    return "Threshold"
        case .suvGradient:  return "SUV Gradient"
        case .regionGrow:   return "Region Grow"
        case .landmark:     return "Landmark"
        case .lesionSphere: return "Quick Lesion"
        }
    }
    public var systemImage: String {
        switch self {
        case .none:         return "hand.point.up"
        case .brush:        return "paintbrush.pointed"
        case .eraser:       return "eraser"
        case .threshold:    return "thermometer.medium"
        case .suvGradient:  return "waveform.path.ecg"
        case .regionGrow:   return "drop"
        case .landmark:     return "mappin.and.ellipse"
        case .lesionSphere: return "circle.dashed"
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
        case .suvGradient:
            return "SUV Gradient Edge\n"
                 + "Click a lesion seed; grows connected voxels above the SUV floor\n"
                 + "and stops at strong local SUV gradients. Use this for PET-edge\n"
                 + "style lesion contouring before manual clean-up."
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
        case .lesionSphere:
            return "Quick Lesion (sphere seed)\n"
                 + "Click a lesion to drop a small sphere mask centered\n"
                 + "on the click point. Each click adds another sphere\n"
                 + "into the same 'Quick Lesions' class so they show up\n"
                 + "as separate connected components in classification.\n"
                 + "Use this to skip the full segmentation pipeline when\n"
                 + "you already know which lesions you want to classify."
        }
    }
}

public enum LandmarkCaptureTarget: String, CaseIterable, Identifiable {
    case fixed, moving

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fixed:  return "Fixed"
        case .moving: return "Moving"
        }
    }
}
