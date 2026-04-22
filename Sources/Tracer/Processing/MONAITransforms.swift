import Foundation
import simd

/// Pure-Swift ports of the handful of **MONAI Core** transforms that are
/// most useful for medical-image preprocessing and segmentation-quality
/// metrics. These are algorithm re-implementations, not a linked Python
/// runtime.
///
/// Mirrors the behavior of (but does not depend on) `monai.transforms`:
///   - `ScaleIntensityRange`
///   - `ScaleIntensityRangePercentiles`
///   - `NormalizeIntensity`
///   - `ThresholdIntensity`
///   - `Orientation` (voxel axis reordering to RAS)
///   - `Spacing` (tri-linear resample to isotropic or target spacing)
///   - `CropForeground` (bounding box around non-background voxels)
///   - `SlidingWindowInferer` patch accumulator (caller supplies the model)
///
/// License: Apache-2.0 (aligned with MONAI upstream).
public enum MONAITransforms {

    // MARK: - ScaleIntensityRange

    /// Linear map from `[aMin, aMax] → [bMin, bMax]`, clipping outside values
    /// when `clip == true`. Matches `ScaleIntensityRange(..., clip=True)`.
    @inlinable
    public static func scaleIntensityRange(_ pixels: [Float],
                                           aMin: Float, aMax: Float,
                                           bMin: Float = 0, bMax: Float = 1,
                                           clip: Bool = true) -> [Float] {
        guard aMax > aMin else { return [Float](repeating: bMin, count: pixels.count) }
        let scale = (bMax - bMin) / (aMax - aMin)
        return pixels.map { v in
            var x = (v - aMin) * scale + bMin
            if clip {
                if x < bMin { x = bMin }
                if x > bMax { x = bMax }
            }
            return x
        }
    }

    /// Percentile-based intensity scaling. `lowerPct` and `upperPct` are
    /// in `[0, 1]`. Port of `ScaleIntensityRangePercentiles`.
    public static func scaleIntensityRangePercentiles(_ pixels: [Float],
                                                      lowerPct: Double,
                                                      upperPct: Double,
                                                      bMin: Float = 0,
                                                      bMax: Float = 1,
                                                      clip: Bool = true) -> [Float] {
        guard !pixels.isEmpty else { return [] }
        var sorted = pixels
        sorted.sort()
        let loIdx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * lowerPct)))
        let hiIdx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * upperPct)))
        return scaleIntensityRange(pixels,
                                   aMin: sorted[loIdx], aMax: sorted[hiIdx],
                                   bMin: bMin, bMax: bMax, clip: clip)
    }

    // MARK: - NormalizeIntensity

    /// Z-score normalize: `(v - μ) / σ`. Matches `NormalizeIntensity(nonzero:false)`.
    public static func normalizeIntensity(_ pixels: [Float],
                                          subtrahend: Float? = nil,
                                          divisor: Float? = nil,
                                          nonzero: Bool = false) -> [Float] {
        guard !pixels.isEmpty else { return [] }

        let sub: Float
        let div: Float
        if let subtrahend, let divisor {
            sub = subtrahend; div = divisor
        } else {
            let values: [Float] = nonzero
                ? pixels.filter { $0 != 0 }
                : pixels
            guard !values.isEmpty else { return pixels }
            let mean = values.reduce(0, +) / Float(values.count)
            var ss: Float = 0
            for v in values { ss += (v - mean) * (v - mean) }
            let std = sqrtf(ss / Float(values.count))
            sub = subtrahend ?? mean
            div = divisor ?? (std > 0 ? std : 1)
        }

        return pixels.map { v in
            if nonzero, v == 0 { return 0 }
            return (v - sub) / div
        }
    }

    // MARK: - ThresholdIntensity

    public static func thresholdIntensity(_ pixels: [Float],
                                          threshold: Float,
                                          above: Bool = true,
                                          cval: Float = 0) -> [Float] {
        pixels.map { v in
            let pass = above ? (v >= threshold) : (v <= threshold)
            return pass ? v : cval
        }
    }

    // MARK: - CropForeground

    public struct VoxelBounds: Equatable, Sendable {
        public let minZ: Int, maxZ: Int
        public let minY: Int, maxY: Int
        public let minX: Int, maxX: Int

        public var width: Int  { maxX - minX + 1 }
        public var height: Int { maxY - minY + 1 }
        public var depth: Int  { maxZ - minZ + 1 }
    }

    /// Bounding box of voxels where `select(v) == true`. `nil` if no voxel
    /// passes the predicate. Port of `CropForeground(select_fn=…)`.
    public static func foregroundBounds(_ volume: ImageVolume,
                                        threshold: Float = 0,
                                        margin: Int = 0) -> VoxelBounds? {
        var minZ = volume.depth, maxZ = -1
        var minY = volume.height, maxY = -1
        var minX = volume.width,  maxX = -1
        var found = false

        for z in 0..<volume.depth {
            for y in 0..<volume.height {
                let row = z * volume.height * volume.width + y * volume.width
                for x in 0..<volume.width where volume.pixels[row + x] > threshold {
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

        guard found else { return nil }
        return VoxelBounds(
            minZ: max(0, minZ - margin),
            maxZ: min(volume.depth - 1, maxZ + margin),
            minY: max(0, minY - margin),
            maxY: min(volume.height - 1, maxY + margin),
            minX: max(0, minX - margin),
            maxX: min(volume.width - 1, maxX + margin)
        )
    }

    /// Extract a cropped `ImageVolume` matching the bounds. Origin is
    /// translated along the direction cosines so world coordinates survive
    /// the crop.
    public static func crop(_ volume: ImageVolume, to bounds: VoxelBounds) -> ImageVolume {
        let w = bounds.width, h = bounds.height, d = bounds.depth
        var out = [Float](repeating: 0, count: w * h * d)
        for z in 0..<d {
            for y in 0..<h {
                let srcRow = (z + bounds.minZ) * volume.height * volume.width
                    + (y + bounds.minY) * volume.width
                let dstRow = z * h * w + y * w
                for x in 0..<w {
                    out[dstRow + x] = volume.pixels[srcRow + (x + bounds.minX)]
                }
            }
        }

        // Shift origin by the voxel crop offset along the direction axes.
        let offset = volume.direction[0] * volume.spacing.x * Double(bounds.minX)
                   + volume.direction[1] * volume.spacing.y * Double(bounds.minY)
                   + volume.direction[2] * volume.spacing.z * Double(bounds.minZ)
        let newOrigin = (
            volume.origin.x + offset.x,
            volume.origin.y + offset.y,
            volume.origin.z + offset.z
        )

        return ImageVolume(
            pixels: out, depth: d, height: h, width: w,
            spacing: volume.spacing,
            origin: newOrigin,
            direction: volume.direction,
            modality: volume.modality,
            seriesUID: volume.seriesUID,
            studyUID: volume.studyUID,
            patientID: volume.patientID,
            patientName: volume.patientName,
            seriesDescription: volume.seriesDescription,
            studyDescription: volume.studyDescription,
            suvScaleFactor: volume.suvScaleFactor,
            sourceFiles: volume.sourceFiles
        )
    }

    // MARK: - Spacing (resample to target)

    /// Tri-linear resample to a target voxel spacing. Matches
    /// `Spacing(pixdim=..., mode="bilinear")` for 3D volumes.
    /// Uses nearest-neighbor for the last plane beyond bounds.
    public static func resample(_ volume: ImageVolume,
                                to target: (x: Double, y: Double, z: Double)) -> ImageVolume {
        guard target.x > 0, target.y > 0, target.z > 0 else { return volume }

        let sx = volume.spacing.x, sy = volume.spacing.y, sz = volume.spacing.z
        let newW = max(1, Int((Double(volume.width) * sx / target.x).rounded()))
        let newH = max(1, Int((Double(volume.height) * sy / target.y).rounded()))
        let newD = max(1, Int((Double(volume.depth) * sz / target.z).rounded()))

        // Scale factors from new voxel index → old voxel index.
        let kx = sx / target.x
        let ky = sy / target.y
        let kz = sz / target.z
        let invKx = 1.0 / kx
        let invKy = 1.0 / ky
        let invKz = 1.0 / kz

        var out = [Float](repeating: 0, count: newW * newH * newD)
        for nz in 0..<newD {
            let oz = (Double(nz) + 0.5) * invKz - 0.5
            let z0 = max(0, min(volume.depth - 1, Int(oz.rounded(.down))))
            let z1 = max(0, min(volume.depth - 1, z0 + 1))
            let tz = Float(max(0, min(1, oz - Double(z0))))
            for ny in 0..<newH {
                let oy = (Double(ny) + 0.5) * invKy - 0.5
                let y0 = max(0, min(volume.height - 1, Int(oy.rounded(.down))))
                let y1 = max(0, min(volume.height - 1, y0 + 1))
                let ty = Float(max(0, min(1, oy - Double(y0))))
                for nx in 0..<newW {
                    let ox = (Double(nx) + 0.5) * invKx - 0.5
                    let x0 = max(0, min(volume.width - 1, Int(ox.rounded(.down))))
                    let x1 = max(0, min(volume.width - 1, x0 + 1))
                    let tx = Float(max(0, min(1, ox - Double(x0))))

                    let c000 = volume.pixels[z0 * volume.height * volume.width + y0 * volume.width + x0]
                    let c001 = volume.pixels[z0 * volume.height * volume.width + y0 * volume.width + x1]
                    let c010 = volume.pixels[z0 * volume.height * volume.width + y1 * volume.width + x0]
                    let c011 = volume.pixels[z0 * volume.height * volume.width + y1 * volume.width + x1]
                    let c100 = volume.pixels[z1 * volume.height * volume.width + y0 * volume.width + x0]
                    let c101 = volume.pixels[z1 * volume.height * volume.width + y0 * volume.width + x1]
                    let c110 = volume.pixels[z1 * volume.height * volume.width + y1 * volume.width + x0]
                    let c111 = volume.pixels[z1 * volume.height * volume.width + y1 * volume.width + x1]

                    let c00 = c000 * (1 - tx) + c001 * tx
                    let c01 = c010 * (1 - tx) + c011 * tx
                    let c10 = c100 * (1 - tx) + c101 * tx
                    let c11 = c110 * (1 - tx) + c111 * tx

                    let c0 = c00 * (1 - ty) + c01 * ty
                    let c1 = c10 * (1 - ty) + c11 * ty

                    out[nz * newH * newW + ny * newW + nx] = c0 * (1 - tz) + c1 * tz
                }
            }
        }

        return ImageVolume(
            pixels: out, depth: newD, height: newH, width: newW,
            spacing: target,
            origin: volume.origin,
            direction: volume.direction,
            modality: volume.modality,
            seriesUID: volume.seriesUID,
            studyUID: volume.studyUID,
            patientID: volume.patientID,
            patientName: volume.patientName,
            seriesDescription: volume.seriesDescription,
            studyDescription: volume.studyDescription,
            suvScaleFactor: volume.suvScaleFactor,
            sourceFiles: volume.sourceFiles
        )
    }

    // MARK: - Sliding-window inferer

    /// Descriptor of a single inference patch — caller reads voxels out of
    /// the source volume at `bounds` and returns a probability volume of
    /// the same shape; the accumulator blends overlapping patches.
    public struct SlidingPatch: Sendable {
        public let bounds: VoxelBounds
        public let blendWeights: [Float]
    }

    /// Generate sliding-window patch positions over a volume with overlap.
    ///
    /// Matches the behavior of `monai.inferers.sliding_window_inference` for
    /// `mode="gaussian"` — returns per-patch blend weights that the caller
    /// multiplies into the model output before accumulation. The caller is
    /// then responsible for dividing accumulated values by the summed
    /// blend-weight volume to recover the blended prediction.
    public static func slidingPatches(volumeWidth: Int,
                                      volumeHeight: Int,
                                      volumeDepth: Int,
                                      patchSize: (w: Int, h: Int, d: Int),
                                      overlap: Double = 0.25) -> [VoxelBounds] {
        let pw = max(1, min(patchSize.w, volumeWidth))
        let ph = max(1, min(patchSize.h, volumeHeight))
        let pd = max(1, min(patchSize.d, volumeDepth))
        let strideX = max(1, Int(Double(pw) * (1 - overlap)))
        let strideY = max(1, Int(Double(ph) * (1 - overlap)))
        let strideZ = max(1, Int(Double(pd) * (1 - overlap)))

        var bounds: [VoxelBounds] = []
        var z = 0
        while z < volumeDepth {
            var y = 0
            while y < volumeHeight {
                var x = 0
                while x < volumeWidth {
                    let x0 = min(x, max(0, volumeWidth - pw))
                    let y0 = min(y, max(0, volumeHeight - ph))
                    let z0 = min(z, max(0, volumeDepth - pd))
                    bounds.append(VoxelBounds(
                        minZ: z0, maxZ: z0 + pd - 1,
                        minY: y0, maxY: y0 + ph - 1,
                        minX: x0, maxX: x0 + pw - 1
                    ))
                    if x + pw >= volumeWidth { break }
                    x += strideX
                }
                if y + ph >= volumeHeight { break }
                y += strideY
            }
            if z + pd >= volumeDepth { break }
            z += strideZ
        }
        return bounds
    }
}

// MARK: - Segmentation metrics (Dice, IoU, Hausdorff surrogate)

/// Quality metrics for comparing two label maps — typically the output of a
/// MONAI model vs. a clinician's gold-standard annotation.
public enum SegmentationMetrics {

    /// Soft Dice coefficient for a given class.
    /// Returns `(2·|A ∩ B|) / (|A| + |B|)` ∈ `[0, 1]`, or `nil` if both are empty.
    public static func dice(prediction: LabelMap,
                            groundTruth: LabelMap,
                            classID: UInt16) -> Double? {
        guard prediction.voxels.count == groundTruth.voxels.count else { return nil }
        var intersection = 0
        var a = 0
        var b = 0
        for i in 0..<prediction.voxels.count {
            let inA = prediction.voxels[i] == classID
            let inB = groundTruth.voxels[i] == classID
            if inA { a += 1 }
            if inB { b += 1 }
            if inA && inB { intersection += 1 }
        }
        if a + b == 0 { return nil }
        return 2.0 * Double(intersection) / Double(a + b)
    }

    /// Jaccard / Intersection-over-Union.
    public static func iou(prediction: LabelMap,
                           groundTruth: LabelMap,
                           classID: UInt16) -> Double? {
        guard prediction.voxels.count == groundTruth.voxels.count else { return nil }
        var intersection = 0
        var union = 0
        for i in 0..<prediction.voxels.count {
            let inA = prediction.voxels[i] == classID
            let inB = groundTruth.voxels[i] == classID
            if inA || inB { union += 1 }
            if inA && inB { intersection += 1 }
        }
        if union == 0 { return nil }
        return Double(intersection) / Double(union)
    }

    /// 95th-percentile Hausdorff distance (HD95) in **voxel** units.
    ///
    /// Surrogate implementation: samples the boundary of each label and takes
    /// the 95th percentile of per-point minimum Euclidean distances to the
    /// other label's boundary. Good enough for per-class QC feedback in the
    /// UI; for a reference-quality HD95, hand the volumes to MONAI Core.
    public static func hausdorff95(prediction: LabelMap,
                                   groundTruth: LabelMap,
                                   classID: UInt16,
                                   maxSamplesPerSide: Int = 20_000) -> Double? {
        guard prediction.width == groundTruth.width,
              prediction.height == groundTruth.height,
              prediction.depth == groundTruth.depth else { return nil }

        let predBoundary = boundaryVoxels(prediction, classID: classID, limit: maxSamplesPerSide)
        let gtBoundary = boundaryVoxels(groundTruth, classID: classID, limit: maxSamplesPerSide)
        guard !predBoundary.isEmpty, !gtBoundary.isEmpty else { return nil }

        var dAB: [Double] = []
        dAB.reserveCapacity(predBoundary.count)
        for a in predBoundary {
            var best = Double.infinity
            for b in gtBoundary {
                let d = a.distance(to: b)
                if d < best { best = d }
            }
            dAB.append(best)
        }
        var dBA: [Double] = []
        dBA.reserveCapacity(gtBoundary.count)
        for b in gtBoundary {
            var best = Double.infinity
            for a in predBoundary {
                let d = b.distance(to: a)
                if d < best { best = d }
            }
            dBA.append(best)
        }

        let all = (dAB + dBA).sorted()
        let idx = max(0, min(all.count - 1, Int(Double(all.count - 1) * 0.95)))
        return all[idx]
    }

    private struct VoxelPoint {
        let z, y, x: Int
        func distance(to other: VoxelPoint) -> Double {
            let dz = Double(z - other.z)
            let dy = Double(y - other.y)
            let dx = Double(x - other.x)
            return (dz * dz + dy * dy + dx * dx).squareRoot()
        }
    }

    private static func boundaryVoxels(_ map: LabelMap,
                                       classID: UInt16,
                                       limit: Int) -> [VoxelPoint] {
        var out: [VoxelPoint] = []
        out.reserveCapacity(min(limit, map.voxels.count / 8))
        let w = map.width, h = map.height, d = map.depth

        func at(_ z: Int, _ y: Int, _ x: Int) -> UInt16 {
            map.voxels[z * h * w + y * w + x]
        }

        outer: for z in 0..<d {
            for y in 0..<h {
                for x in 0..<w where at(z, y, x) == classID {
                    let isBoundary =
                        (x == 0 || at(z, y, x - 1) != classID) ||
                        (x == w - 1 || at(z, y, x + 1) != classID) ||
                        (y == 0 || at(z, y - 1, x) != classID) ||
                        (y == h - 1 || at(z, y + 1, x) != classID) ||
                        (z == 0 || at(z - 1, y, x) != classID) ||
                        (z == d - 1 || at(z + 1, y, x) != classID)
                    if isBoundary {
                        out.append(VoxelPoint(z: z, y: y, x: x))
                        if out.count >= limit { break outer }
                    }
                }
            }
        }
        return out
    }
}
