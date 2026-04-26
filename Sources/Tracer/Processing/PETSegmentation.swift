import Foundation

/// PET-specific segmentation utilities: SUV thresholding, percentage of max,
/// and connected-component region growing from a seed voxel.
public enum PETSegmentation {

    // MARK: - Fixed SUV threshold

    /// Segment all voxels above `threshold` (in SUV units if volume is PET).
    /// Returns number of voxels assigned.
    @discardableResult
    public static func thresholdAbove(volume: ImageVolume,
                                       label: LabelMap,
                                       threshold: Double,
                                       classID: UInt16,
                                       mode: BrushTool.Mode = .paint,
                                       boundingBox: VoxelBox? = nil,
                                       valueTransform: ((Double) -> Double)? = nil) -> Int {
        guard volume.depth == label.depth,
              volume.height == label.height,
              volume.width == label.width else { return 0 }

        let bb = boundingBox ?? VoxelBox.all(in: volume)
        var voxels = label.voxels
        var count = 0
        for z in bb.minZ...bb.maxZ {
            for y in bb.minY...bb.maxY {
                let rowStart = z * label.height * label.width + y * label.width
                for x in bb.minX...bb.maxX {
                    let raw = Double(volume.pixels[rowStart + x])
                    let p = valueTransform?(raw) ?? raw
                    if p >= threshold {
                        let idx = rowStart + x
                        apply(mode: mode, to: &voxels, index: idx, classID: classID)
                        count += 1
                    }
                }
            }
        }
        label.voxels = voxels
        return count
    }

    /// Segment all voxels whose transformed value lies inside a closed range.
    /// This is used for CT HU masks (e.g. lung, fat, bone) and for custom
    /// PET/intensity windows when a reader wants a bounded contour.
    @discardableResult
    public static func thresholdRange(volume: ImageVolume,
                                      label: LabelMap,
                                      lower: Double,
                                      upper: Double,
                                      classID: UInt16,
                                      mode: BrushTool.Mode = .paint,
                                      boundingBox: VoxelBox? = nil,
                                      valueTransform: ((Double) -> Double)? = nil) -> Int {
        guard volume.depth == label.depth,
              volume.height == label.height,
              volume.width == label.width else { return 0 }

        let lo = min(lower, upper)
        let hi = max(lower, upper)
        let bb = boundingBox ?? VoxelBox.all(in: volume)
        var voxels = label.voxels
        var count = 0
        for z in bb.minZ...bb.maxZ {
            for y in bb.minY...bb.maxY {
                let rowStart = z * label.height * label.width + y * label.width
                for x in bb.minX...bb.maxX {
                    let raw = Double(volume.pixels[rowStart + x])
                    let value = valueTransform?(raw) ?? raw
                    guard value >= lo, value <= hi else { continue }
                    let idx = rowStart + x
                    apply(mode: mode, to: &voxels, index: idx, classID: classID)
                    count += 1
                }
            }
        }
        label.voxels = voxels
        return count
    }

    // MARK: - Percentage of max SUV

    /// Segment voxels above `percent * SUV_max_in_box` (e.g. 0.4 = 40% of max).
    /// Widely used for PET tumor segmentation (Boellaard 2014, EANM 2.0 guidelines).
    @discardableResult
    public static func percentOfMax(volume: ImageVolume,
                                     label: LabelMap,
                                     percent: Double,
                                     classID: UInt16,
                                     boundingBox: VoxelBox,
                                     valueTransform: ((Double) -> Double)? = nil) -> Int {
        let suvMax = regionMax(volume: volume, box: boundingBox, valueTransform: valueTransform)
        let thresh = suvMax * percent
        return thresholdAbove(volume: volume, label: label,
                              threshold: thresh, classID: classID,
                              boundingBox: boundingBox,
                              valueTransform: valueTransform)
    }

    // MARK: - Seeded region growing

    /// Flood-fill from a seed voxel including all connected voxels whose
    /// intensity is within `tolerance` of the seed's intensity.
    /// - Parameters:
    ///   - tolerance: +/- value from seed intensity
    ///   - maxVoxels: safety cap (default 10M)
    @discardableResult
    public static func regionGrow(volume: ImageVolume,
                                   label: LabelMap,
                                   seed: (z: Int, y: Int, x: Int),
                                   tolerance: Double,
                                   classID: UInt16,
                                   maxVoxels: Int = 10_000_000) -> Int {
        guard volume.depth == label.depth,
              volume.height == label.height,
              volume.width == label.width else { return 0 }
        guard seed.z >= 0, seed.z < volume.depth,
              seed.y >= 0, seed.y < volume.height,
              seed.x >= 0, seed.x < volume.width else { return 0 }

        let seedIdx = label.index(z: seed.z, y: seed.y, x: seed.x)
        let seedValue = Double(volume.pixels[seedIdx])
        let minV = seedValue - tolerance
        let maxV = seedValue + tolerance

        // 6-connected BFS
        var queue: [(Int, Int, Int)] = [seed]
        var visited = [Bool](repeating: false, count: volume.pixels.count)
        visited[seedIdx] = true
        var voxels = label.voxels
        var count = 0

        while !queue.isEmpty && count < maxVoxels {
            let (z, y, x) = queue.removeLast()
            let idx = label.index(z: z, y: y, x: x)
            let v = Double(volume.pixels[idx])
            if v < minV || v > maxV { continue }
            voxels[idx] = classID
            count += 1

            let neighbors: [(Int, Int, Int)] = [
                (z + 1, y, x), (z - 1, y, x),
                (z, y + 1, x), (z, y - 1, x),
                (z, y, x + 1), (z, y, x - 1),
            ]
            for n in neighbors {
                guard n.0 >= 0, n.0 < volume.depth,
                      n.1 >= 0, n.1 < volume.height,
                      n.2 >= 0, n.2 < volume.width else { continue }
                let nidx = label.index(z: n.0, y: n.1, x: n.2)
                if !visited[nidx] {
                    visited[nidx] = true
                    queue.append(n)
                }
            }
        }
        label.voxels = voxels
        return count
    }

    /// Region grow with a fixed SUV threshold (common clinical protocol).
    /// Fills connected voxels above `threshold` starting from seed.
    @discardableResult
    public static func regionGrowAboveThreshold(volume: ImageVolume,
                                                 label: LabelMap,
                                                 seed: (z: Int, y: Int, x: Int),
                                                 threshold: Double,
                                                 classID: UInt16,
                                                 maxVoxels: Int = 10_000_000,
                                                 valueTransform: ((Double) -> Double)? = nil) -> Int {
        guard volume.depth == label.depth,
              volume.height == label.height,
              volume.width == label.width else { return 0 }
        guard seed.z >= 0, seed.z < volume.depth,
              seed.y >= 0, seed.y < volume.height,
              seed.x >= 0, seed.x < volume.width else { return 0 }

        var queue: [(Int, Int, Int)] = [seed]
        var visited = [Bool](repeating: false, count: volume.pixels.count)
        let seedIdx = label.index(z: seed.z, y: seed.y, x: seed.x)
        visited[seedIdx] = true
        var voxels = label.voxels
        var count = 0

        while !queue.isEmpty && count < maxVoxels {
            let (z, y, x) = queue.removeLast()
            let idx = label.index(z: z, y: y, x: x)
            let raw = Double(volume.pixels[idx])
            if (valueTransform?(raw) ?? raw) < threshold { continue }
            voxels[idx] = classID
            count += 1

            for n in [(z+1, y, x), (z-1, y, x),
                       (z, y+1, x), (z, y-1, x),
                       (z, y, x+1), (z, y, x-1)] {
                guard n.0 >= 0, n.0 < volume.depth,
                      n.1 >= 0, n.1 < volume.height,
                      n.2 >= 0, n.2 < volume.width else { continue }
                let nidx = label.index(z: n.0, y: n.1, x: n.2)
                if !visited[nidx] {
                    visited[nidx] = true
                    queue.append(n)
                }
            }
        }
        label.voxels = voxels
        return count
    }

    /// Connected flood-fill from a seed while enforcing a transformed-value
    /// range. Useful for HU-bounded CT volumes where whole-volume thresholding
    /// would otherwise pick up every similar structure in the scan.
    @discardableResult
    public static func regionGrowInRange(volume: ImageVolume,
                                         label: LabelMap,
                                         seed: (z: Int, y: Int, x: Int),
                                         lower: Double,
                                         upper: Double,
                                         classID: UInt16,
                                         maxVoxels: Int = 10_000_000,
                                         valueTransform: ((Double) -> Double)? = nil) -> Int {
        guard volume.depth == label.depth,
              volume.height == label.height,
              volume.width == label.width else { return 0 }
        guard seed.z >= 0, seed.z < volume.depth,
              seed.y >= 0, seed.y < volume.height,
              seed.x >= 0, seed.x < volume.width else { return 0 }

        let lo = min(lower, upper)
        let hi = max(lower, upper)
        var queue: [(Int, Int, Int)] = [seed]
        var visited = [Bool](repeating: false, count: volume.pixels.count)
        visited[label.index(z: seed.z, y: seed.y, x: seed.x)] = true
        var voxels = label.voxels
        var count = 0

        while !queue.isEmpty && count < maxVoxels {
            let (z, y, x) = queue.removeLast()
            let idx = label.index(z: z, y: y, x: x)
            let raw = Double(volume.pixels[idx])
            let value = valueTransform?(raw) ?? raw
            guard value >= lo, value <= hi else { continue }
            voxels[idx] = classID
            count += 1

            for n in [(z+1, y, x), (z-1, y, x),
                      (z, y+1, x), (z, y-1, x),
                      (z, y, x+1), (z, y, x-1)] {
                guard n.0 >= 0, n.0 < volume.depth,
                      n.1 >= 0, n.1 < volume.height,
                      n.2 >= 0, n.2 < volume.width else { continue }
                let nidx = label.index(z: n.0, y: n.1, x: n.2)
                guard !visited[nidx] else { continue }
                visited[nidx] = true
                queue.append(n)
            }
        }
        label.voxels = voxels
        return count
    }

    // MARK: - SUV gradient edge segmentation

    /// Seeded PET edge segmentation that grows from a hot voxel while stopping
    /// expansion at strong local SUV gradients. This is intended for PET lesion
    /// contouring workflows where fixed SUV thresholding starts the lesion and
    /// the gradient boundary prevents spill into adjacent background.
    @discardableResult
    public static func gradientEdge(volume: ImageVolume,
                                    label: LabelMap,
                                    seed: (z: Int, y: Int, x: Int),
                                    minimumValue: Double,
                                    gradientCutoffFraction: Double,
                                    classID: UInt16,
                                    searchRadius: Int = 30,
                                    maxVoxels: Int = 2_000_000,
                                    valueTransform: ((Double) -> Double)? = nil) -> PETGradientSegmentationResult {
        guard volume.depth == label.depth,
              volume.height == label.height,
              volume.width == label.width else {
            return .empty(minimumValue: minimumValue)
        }
        guard seed.z >= 0, seed.z < volume.depth,
              seed.y >= 0, seed.y < volume.height,
              seed.x >= 0, seed.x < volume.width else {
            return .empty(minimumValue: minimumValue)
        }

        let radius = max(1, searchRadius)
        let box = VoxelBox.around(seed, radius: radius, in: volume)
        let seedValue = transformedValue(volume: volume, z: seed.z, y: seed.y, x: seed.x, transform: valueTransform)
        guard seedValue >= minimumValue else {
            return .empty(minimumValue: minimumValue, seedValue: seedValue)
        }

        let localMax = regionMax(volume: volume, box: box, valueTransform: valueTransform)
        guard localMax.isFinite, localMax >= minimumValue else {
            return .empty(minimumValue: minimumValue, seedValue: seedValue)
        }

        let maxGradient = maxGradientMagnitude(volume: volume,
                                               box: box,
                                               minimumValue: minimumValue,
                                               valueTransform: valueTransform)
        let fraction = max(0.05, min(0.95, gradientCutoffFraction))
        let gradientCutoff = maxGradient * fraction
        let coreValue = localMax * 0.9
        let boxWidth = box.maxX - box.minX + 1
        let boxHeight = box.maxY - box.minY + 1
        let boxDepth = box.maxZ - box.minZ + 1
        let localCount = boxWidth * boxHeight * boxDepth
        var visited = [Bool](repeating: false, count: localCount)
        var queue: [(z: Int, y: Int, x: Int)] = [seed]
        visited[localIndex(seed, box: box, width: boxWidth, height: boxHeight)] = true
        var voxels = label.voxels
        var count = 0
        var stoppedAtEdge = false

        while !queue.isEmpty && count < maxVoxels {
            let voxel = queue.removeLast()
            let idx = label.index(z: voxel.z, y: voxel.y, x: voxel.x)
            let value = transformedValue(volume: volume, z: voxel.z, y: voxel.y, x: voxel.x, transform: valueTransform)
            guard value >= minimumValue else { continue }

            voxels[idx] = classID
            count += 1

            let gradient = gradientMagnitude(volume: volume,
                                             z: voxel.z, y: voxel.y, x: voxel.x,
                                             valueTransform: valueTransform)
            let isBoundary = gradientCutoff > 0 &&
                gradient >= gradientCutoff &&
                value < coreValue
            if isBoundary {
                stoppedAtEdge = true
                continue
            }

            for neighbor in sixConnectedNeighbors(of: voxel) {
                guard box.contains(neighbor),
                      neighbor.z >= 0, neighbor.z < volume.depth,
                      neighbor.y >= 0, neighbor.y < volume.height,
                      neighbor.x >= 0, neighbor.x < volume.width else { continue }
                let local = localIndex(neighbor, box: box, width: boxWidth, height: boxHeight)
                guard !visited[local] else { continue }
                visited[local] = true
                queue.append(neighbor)
            }
        }
        label.voxels = voxels

        return PETGradientSegmentationResult(
            voxelCount: count,
            seedValue: seedValue,
            maxValue: localMax,
            minimumValue: minimumValue,
            maxGradient: maxGradient,
            gradientCutoff: gradientCutoff,
            stoppedAtEdge: stoppedAtEdge
        )
    }

    // MARK: - Morphology

    /// Dilate all voxels of a given class by one voxel (6-connected).
    public static func dilate(label: LabelMap, classID: UInt16, iterations: Int = 1) {
        for _ in 0..<iterations {
            let original = label.voxels
            var voxels = original
            for z in 0..<label.depth {
                for y in 0..<label.height {
                    let rowStart = z * label.height * label.width + y * label.width
                    for x in 0..<label.width {
                        let idx = rowStart + x
                        if original[idx] == classID { continue }
                        for n in [(z+1, y, x), (z-1, y, x),
                                   (z, y+1, x), (z, y-1, x),
                                   (z, y, x+1), (z, y, x-1)] {
                            guard n.0 >= 0, n.0 < label.depth,
                                  n.1 >= 0, n.1 < label.height,
                                  n.2 >= 0, n.2 < label.width else { continue }
                            if original[label.index(z: n.0, y: n.1, x: n.2)] == classID {
                                voxels[idx] = classID
                                break
                            }
                        }
                    }
                }
            }
            label.voxels = voxels
        }
    }

    /// Erode a class by one voxel (6-connected).
    public static func erode(label: LabelMap, classID: UInt16, iterations: Int = 1) {
        for _ in 0..<iterations {
            let original = label.voxels
            var voxels = original
            for z in 0..<label.depth {
                for y in 0..<label.height {
                    let rowStart = z * label.height * label.width + y * label.width
                    for x in 0..<label.width {
                        let idx = rowStart + x
                        if original[idx] != classID { continue }
                        for n in [(z+1, y, x), (z-1, y, x),
                                   (z, y+1, x), (z, y-1, x),
                                   (z, y, x+1), (z, y, x-1)] {
                            guard n.0 >= 0, n.0 < label.depth,
                                  n.1 >= 0, n.1 < label.height,
                                  n.2 >= 0, n.2 < label.width else {
                                // Border voxel - erode it
                                voxels[idx] = 0
                                break
                            }
                            if original[label.index(z: n.0, y: n.1, x: n.2)] != classID {
                                voxels[idx] = 0
                                break
                            }
                        }
                    }
                }
            }
            label.voxels = voxels
        }
    }

    // MARK: - Helpers

    public static func regionMax(volume: ImageVolume,
                                 box: VoxelBox,
                                 valueTransform: ((Double) -> Double)? = nil) -> Double {
        var m = -Double.infinity
        for z in box.minZ...box.maxZ {
            for y in box.minY...box.maxY {
                let rowStart = z * volume.height * volume.width + y * volume.width
                for x in box.minX...box.maxX {
                    let raw = Double(volume.pixels[rowStart + x])
                    let v = valueTransform?(raw) ?? raw
                    if v > m { m = v }
                }
            }
        }
        return m
    }

    private static func maxGradientMagnitude(volume: ImageVolume,
                                             box: VoxelBox,
                                             minimumValue: Double,
                                             valueTransform: ((Double) -> Double)?) -> Double {
        var maxGradient = 0.0
        for z in box.minZ...box.maxZ {
            for y in box.minY...box.maxY {
                for x in box.minX...box.maxX {
                    let value = transformedValue(volume: volume, z: z, y: y, x: x, transform: valueTransform)
                    guard value >= minimumValue else { continue }
                    let gradient = gradientMagnitude(volume: volume,
                                                     z: z, y: y, x: x,
                                                     valueTransform: valueTransform)
                    if gradient > maxGradient {
                        maxGradient = gradient
                    }
                }
            }
        }
        return maxGradient
    }

    private static func gradientMagnitude(volume: ImageVolume,
                                          z: Int,
                                          y: Int,
                                          x: Int,
                                          valueTransform: ((Double) -> Double)?) -> Double {
        let dx = derivative(volume: volume,
                            lower: (z, y, max(x - 1, 0)),
                            center: (z, y, x),
                            upper: (z, y, min(x + 1, volume.width - 1)),
                            spacing: volume.spacing.x,
                            valueTransform: valueTransform)
        let dy = derivative(volume: volume,
                            lower: (z, max(y - 1, 0), x),
                            center: (z, y, x),
                            upper: (z, min(y + 1, volume.height - 1), x),
                            spacing: volume.spacing.y,
                            valueTransform: valueTransform)
        let dz = derivative(volume: volume,
                            lower: (max(z - 1, 0), y, x),
                            center: (z, y, x),
                            upper: (min(z + 1, volume.depth - 1), y, x),
                            spacing: volume.spacing.z,
                            valueTransform: valueTransform)
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    private static func derivative(volume: ImageVolume,
                                   lower: (z: Int, y: Int, x: Int),
                                   center: (z: Int, y: Int, x: Int),
                                   upper: (z: Int, y: Int, x: Int),
                                   spacing: Double,
                                   valueTransform: ((Double) -> Double)?) -> Double {
        guard spacing > 0 else { return 0 }
        let lowerValue = transformedValue(volume: volume, z: lower.z, y: lower.y, x: lower.x, transform: valueTransform)
        let centerValue = transformedValue(volume: volume, z: center.z, y: center.y, x: center.x, transform: valueTransform)
        let upperValue = transformedValue(volume: volume, z: upper.z, y: upper.y, x: upper.x, transform: valueTransform)

        if lower == center && upper == center {
            return 0
        }
        if lower == center {
            return (upperValue - centerValue) / spacing
        }
        if upper == center {
            return (centerValue - lowerValue) / spacing
        }
        return (upperValue - lowerValue) / (2 * spacing)
    }

    private static func transformedValue(volume: ImageVolume,
                                         z: Int,
                                         y: Int,
                                         x: Int,
                                         transform: ((Double) -> Double)?) -> Double {
        let raw = Double(volume.intensity(z: z, y: y, x: x))
        return transform?(raw) ?? raw
    }

    private static func sixConnectedNeighbors(of voxel: (z: Int, y: Int, x: Int)) -> [(z: Int, y: Int, x: Int)] {
        [
            (voxel.z + 1, voxel.y, voxel.x), (voxel.z - 1, voxel.y, voxel.x),
            (voxel.z, voxel.y + 1, voxel.x), (voxel.z, voxel.y - 1, voxel.x),
            (voxel.z, voxel.y, voxel.x + 1), (voxel.z, voxel.y, voxel.x - 1),
        ]
    }

    private static func apply(mode: BrushTool.Mode,
                              to voxels: inout [UInt16],
                              index: Int,
                              classID: UInt16) {
        switch mode {
        case .paint:
            voxels[index] = classID
        case .erase:
            voxels[index] = 0
        case .eraseClass:
            if voxels[index] == classID {
                voxels[index] = 0
            }
        }
    }

    private static func localIndex(_ voxel: (z: Int, y: Int, x: Int),
                                   box: VoxelBox,
                                   width: Int,
                                   height: Int) -> Int {
        (voxel.z - box.minZ) * height * width +
        (voxel.y - box.minY) * width +
        (voxel.x - box.minX)
    }
}

public struct PETGradientSegmentationResult: Equatable, Sendable {
    public let voxelCount: Int
    public let seedValue: Double
    public let maxValue: Double
    public let minimumValue: Double
    public let maxGradient: Double
    public let gradientCutoff: Double
    public let stoppedAtEdge: Bool

    static func empty(minimumValue: Double, seedValue: Double = 0) -> PETGradientSegmentationResult {
        PETGradientSegmentationResult(
            voxelCount: 0,
            seedValue: seedValue,
            maxValue: 0,
            minimumValue: minimumValue,
            maxGradient: 0,
            gradientCutoff: 0,
            stoppedAtEdge: false
        )
    }
}

/// A 3D voxel bounding box (inclusive).
public struct VoxelBox: Sendable {
    public var minZ, maxZ, minY, maxY, minX, maxX: Int

    public init(minZ: Int, maxZ: Int, minY: Int, maxY: Int, minX: Int, maxX: Int) {
        self.minZ = minZ; self.maxZ = maxZ
        self.minY = minY; self.maxY = maxY
        self.minX = minX; self.maxX = maxX
    }

    public static func all(in volume: ImageVolume) -> VoxelBox {
        VoxelBox(minZ: 0, maxZ: volume.depth - 1,
                 minY: 0, maxY: volume.height - 1,
                 minX: 0, maxX: volume.width - 1)
    }

    public static func around(_ voxel: (z: Int, y: Int, x: Int),
                              radius: Int, in volume: ImageVolume) -> VoxelBox {
        VoxelBox(
            minZ: max(0, voxel.z - radius), maxZ: min(volume.depth - 1, voxel.z + radius),
            minY: max(0, voxel.y - radius), maxY: min(volume.height - 1, voxel.y + radius),
            minX: max(0, voxel.x - radius), maxX: min(volume.width - 1, voxel.x + radius)
        )
    }

    public func contains(_ voxel: (z: Int, y: Int, x: Int)) -> Bool {
        voxel.z >= minZ && voxel.z <= maxZ &&
        voxel.y >= minY && voxel.y <= maxY &&
        voxel.x >= minX && voxel.x <= maxX
    }
}
