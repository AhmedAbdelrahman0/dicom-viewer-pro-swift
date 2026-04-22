import Foundation
import SwiftUI

/// A 3D integer label volume aligned to a parent `ImageVolume`.
///
/// Each voxel stores a `UInt16` class ID. Value `0` means "background /
/// unlabeled". Non-zero values index into the associated `LabelClass` list.
public final class LabelMap: Identifiable, ObservableObject, @unchecked Sendable {
    public let id = UUID()

    /// Parent volume UID — this label map is defined in that volume's voxel grid.
    public let parentSeriesUID: String

    /// Spatial dimensions (must match the parent volume).
    public let depth: Int
    public let height: Int
    public let width: Int

    /// Dense 3D mask as UInt16 (supports up to 65k classes). Published so views redraw.
    @Published public var voxels: [UInt16]

    /// Class definitions for each non-zero value.
    @Published public var classes: [LabelClass]

    /// Overall display opacity for this label map.
    @Published public var opacity: Double = 0.5

    /// Whether this label map is visible in overlays.
    @Published public var visible: Bool = true

    /// Display name for the label map.
    @Published public var name: String

    public init(parentSeriesUID: String,
                depth: Int,
                height: Int,
                width: Int,
                name: String = "Labels",
                classes: [LabelClass] = []) {
        self.parentSeriesUID = parentSeriesUID
        self.depth = depth
        self.height = height
        self.width = width
        self.voxels = [UInt16](repeating: 0, count: depth * height * width)
        self.name = name
        self.classes = classes
    }

    public func snapshot(name: String? = nil) -> LabelMap {
        let copy = LabelMap(
            parentSeriesUID: parentSeriesUID,
            depth: depth,
            height: height,
            width: width,
            name: name ?? self.name,
            classes: classes
        )
        copy.voxels = voxels
        copy.opacity = opacity
        copy.visible = visible
        return copy
    }

    // MARK: - Voxel access

    @inlinable
    public func index(z: Int, y: Int, x: Int) -> Int {
        z * height * width + y * width + x
    }

    public func value(z: Int, y: Int, x: Int) -> UInt16 {
        guard z >= 0, z < depth, y >= 0, y < height, x >= 0, x < width else { return 0 }
        return voxels[index(z: z, y: y, x: x)]
    }

    public func setValue(_ v: UInt16, z: Int, y: Int, x: Int) {
        guard z >= 0, z < depth, y >= 0, y < height, x >= 0, x < width else { return }
        voxels[index(z: z, y: y, x: x)] = v
    }

    /// Get a 2D slice of label values.
    public func slice(axis: Int, index: Int) -> (values: [UInt16], width: Int, height: Int) {
        switch axis {
        case 0:
            let x = clamp(index, 0, width - 1)
            var out = [UInt16](repeating: 0, count: depth * height)
            for z in 0..<depth {
                for y in 0..<height {
                    out[z * height + y] = voxels[z * height * width + y * width + x]
                }
            }
            return (out, height, depth)
        case 1:
            let y = clamp(index, 0, height - 1)
            var out = [UInt16](repeating: 0, count: depth * width)
            for z in 0..<depth {
                let rowStart = z * height * width + y * width
                for x in 0..<width {
                    out[z * width + x] = voxels[rowStart + x]
                }
            }
            return (out, width, depth)
        default:
            let z = clamp(index, 0, depth - 1)
            let start = z * height * width
            let end = start + height * width
            return (Array(voxels[start..<end]), width, height)
        }
    }

    // MARK: - Class management

    /// Add a class; returns the assigned label ID.
    @discardableResult
    public func addClass(_ cls: LabelClass) -> UInt16 {
        // If cls.labelID is 0, auto-assign next free ID
        var id = cls.labelID
        if id == 0 {
            let used = Set(classes.map { $0.labelID })
            id = 1
            while used.contains(id) { id += 1 }
        }
        var c = cls
        c.labelID = id
        classes.append(c)
        return id
    }

    public func removeClass(id: UInt16) {
        classes.removeAll { $0.labelID == id }
        // Zero out all voxels of this class
        for i in 0..<voxels.count where voxels[i] == id {
            voxels[i] = 0
        }
    }

    public func classInfo(id: UInt16) -> LabelClass? {
        classes.first { $0.labelID == id }
    }

    // MARK: - Statistics

    /// Count voxels per class.
    public func voxelCounts() -> [UInt16: Int] {
        var counts: [UInt16: Int] = [:]
        for v in voxels where v != 0 {
            counts[v, default: 0] += 1
        }
        return counts
    }

    /// Volume in mm³ for a given class.
    public func volumeMM3(classID: UInt16, spacing: (Double, Double, Double)) -> Double {
        let voxelCount = voxels.reduce(0) { $0 + ($1 == classID ? 1 : 0) }
        let voxelVol = spacing.0 * spacing.1 * spacing.2
        return Double(voxelCount) * voxelVol
    }

    /// Bounding box of a class in voxel coordinates.
    public func boundingBox(classID: UInt16) -> (minZ: Int, maxZ: Int,
                                                    minY: Int, maxY: Int,
                                                    minX: Int, maxX: Int)? {
        var minZ = depth, maxZ = -1, minY = height, maxY = -1, minX = width, maxX = -1
        var found = false

        for z in 0..<depth {
            for y in 0..<height {
                let rowStart = z * height * width + y * width
                for x in 0..<width {
                    if voxels[rowStart + x] == classID {
                        if z < minZ { minZ = z }
                        if z > maxZ { maxZ = z }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        found = true
                    }
                }
            }
        }
        return found ? (minZ, maxZ, minY, maxY, minX, maxX) : nil
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        max(lo, min(hi, v))
    }
}

/// Compute statistics for a label region against an intensity volume.
public struct RegionStats {
    public let count: Int
    public let mean: Double
    public let min: Double
    public let max: Double
    public let std: Double
    public let volumeMM3: Double

    /// PET-specific SUV statistics (if volume has SUV scaling).
    public let suvMax: Double?
    public let suvMean: Double?
    public let suvPeak: Double?     // 1cm³ max SUV — "SUV peak"
    public let tlg: Double?         // Total lesion glycolysis = mean × volume (for SUV data)

    public static func compute(_ volume: ImageVolume,
                               _ labelMap: LabelMap,
                               classID: UInt16,
                               suvTransform: ((Double) -> Double)? = nil) -> RegionStats {
        guard volume.depth == labelMap.depth,
              volume.height == labelMap.height,
              volume.width == labelMap.width else {
            return RegionStats(count: 0, mean: 0, min: 0, max: 0, std: 0,
                               volumeMM3: 0, suvMax: nil, suvMean: nil,
                               suvPeak: nil, tlg: nil)
        }

        var vals: [Double] = []
        vals.reserveCapacity(10_000)

        for i in 0..<labelMap.voxels.count where labelMap.voxels[i] == classID {
            vals.append(Double(volume.pixels[i]))
        }

        guard !vals.isEmpty else {
            return RegionStats(count: 0, mean: 0, min: 0, max: 0, std: 0,
                               volumeMM3: 0, suvMax: nil, suvMean: nil,
                               suvPeak: nil, tlg: nil)
        }

        let mean = vals.reduce(0, +) / Double(vals.count)
        let mn = vals.min() ?? 0
        let mx = vals.max() ?? 0
        let variance = vals.reduce(0) { $0 + pow($1 - mean, 2) } / Double(vals.count)
        let std = sqrt(variance)

        let voxVol = volume.spacing.x * volume.spacing.y * volume.spacing.z
        let volMM3 = Double(vals.count) * voxVol

        let isPET = Modality.normalize(volume.modality) == .PT
        let defaultSUVTransform: ((Double) -> Double)? = {
            if let suvScale = volume.suvScaleFactor {
                return { $0 * suvScale }
            }
            return isPET ? { $0 } : nil
        }()
        let transform = suvTransform ?? defaultSUVTransform

        let suvValues = transform.map { mapper in vals.map(mapper) }
        let suvMax: Double? = suvValues?.max()
        let suvMean: Double? = suvValues.map { $0.reduce(0, +) / Double($0.count) }
        let tlg: Double? = (transform != nil && suvMean != nil) ? suvMean! * (volMM3 / 1000) : nil

        return RegionStats(
            count: vals.count,
            mean: mean,
            min: mn,
            max: mx,
            std: std,
            volumeMM3: volMM3,
            suvMax: suvMax,
            suvMean: suvMean,
            suvPeak: suvMax,  // Simple approximation; true SUVpeak uses 1cm³ sphere
            tlg: tlg
        )
    }
}
