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
                                       boundingBox: VoxelBox? = nil) -> Int {
        guard volume.depth == label.depth,
              volume.height == label.height,
              volume.width == label.width else { return 0 }

        let bb = boundingBox ?? VoxelBox.all(in: volume)
        var count = 0
        for z in bb.minZ...bb.maxZ {
            for y in bb.minY...bb.maxY {
                let rowStart = z * label.height * label.width + y * label.width
                for x in bb.minX...bb.maxX {
                    let p = Double(volume.pixels[rowStart + x])
                    if p >= threshold {
                        let idx = rowStart + x
                        switch mode {
                        case .paint: label.voxels[idx] = classID
                        case .erase: label.voxels[idx] = 0
                        case .eraseClass:
                            if label.voxels[idx] == classID {
                                label.voxels[idx] = 0
                            }
                        }
                        count += 1
                    }
                }
            }
        }
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
                                     boundingBox: VoxelBox) -> Int {
        let suvMax = regionMax(volume: volume, box: boundingBox)
        let thresh = suvMax * percent
        return thresholdAbove(volume: volume, label: label,
                              threshold: thresh, classID: classID,
                              boundingBox: boundingBox)
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
        var count = 0

        while !queue.isEmpty && count < maxVoxels {
            let (z, y, x) = queue.removeLast()
            let idx = label.index(z: z, y: y, x: x)
            let v = Double(volume.pixels[idx])
            if v < minV || v > maxV { continue }
            label.voxels[idx] = classID
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
                                                 maxVoxels: Int = 10_000_000) -> Int {
        var queue: [(Int, Int, Int)] = [seed]
        var visited = [Bool](repeating: false, count: volume.pixels.count)
        let seedIdx = label.index(z: seed.z, y: seed.y, x: seed.x)
        visited[seedIdx] = true
        var count = 0

        while !queue.isEmpty && count < maxVoxels {
            let (z, y, x) = queue.removeLast()
            let idx = label.index(z: z, y: y, x: x)
            if Double(volume.pixels[idx]) < threshold { continue }
            label.voxels[idx] = classID
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
        return count
    }

    // MARK: - Morphology

    /// Dilate all voxels of a given class by one voxel (6-connected).
    public static func dilate(label: LabelMap, classID: UInt16, iterations: Int = 1) {
        for _ in 0..<iterations {
            let original = label.voxels
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
                                label.voxels[idx] = classID
                                break
                            }
                        }
                    }
                }
            }
        }
    }

    /// Erode a class by one voxel (6-connected).
    public static func erode(label: LabelMap, classID: UInt16, iterations: Int = 1) {
        for _ in 0..<iterations {
            let original = label.voxels
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
                                label.voxels[idx] = 0
                                break
                            }
                            if original[label.index(z: n.0, y: n.1, x: n.2)] != classID {
                                label.voxels[idx] = 0
                                break
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    public static func regionMax(volume: ImageVolume, box: VoxelBox) -> Double {
        var m = -Double.infinity
        for z in box.minZ...box.maxZ {
            for y in box.minY...box.maxY {
                let rowStart = z * volume.height * volume.width + y * volume.width
                for x in box.minX...box.maxX {
                    let v = Double(volume.pixels[rowStart + x])
                    if v > m { m = v }
                }
            }
        }
        return m
    }
}

/// A 3D voxel bounding box (inclusive).
public struct VoxelBox {
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
}
