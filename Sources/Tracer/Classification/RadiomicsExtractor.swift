import Foundation
import simd

/// Native-Swift radiomics feature extractor. Computes a curated subset of
/// the pyradiomics feature bank — ~30 of the most-cited shape, first-order,
/// and GLCM texture features — for a single lesion (the voxels in `mask`
/// where `mask.voxels == classID` and the coordinates fall inside `bounds`).
///
/// Output is a `[String: Double]` dictionary keyed by pyradiomics-compatible
/// feature names (e.g. `"original_firstorder_Mean"`), so trained models
/// exported from pyradiomics pipelines can consume it directly.
///
/// Reference:
///   Van Griethuysen et al., *"Computational Radiomics System to Decode
///   the Radiographic Phenotype"*, Cancer Res 2017 (pyradiomics).
///
/// This extractor is intentionally compact: ~30 features that together
/// capture most of the pyradiomics discriminative signal for lesion
/// classification tasks (lung, liver, breast, PET). Users who need the
/// full 100+ feature set should feed the extracted VOI to a Python
/// pyradiomics pipeline via `SubprocessLesionClassifier`.
public enum RadiomicsExtractor {

    /// Number of gray levels to discretise to for GLCM features. Matches
    /// pyradiomics' default.
    public static var glcmGrayLevels: Int = 32

    /// Upper cap on surface-voxel samples when computing Maximum3DDiameter
    /// — the naïve algorithm is O(N²), so large lesions get sub-sampled.
    public static var maximum3DDiameterSampleCap: Int = 2000

    public static func extract(volume: ImageVolume,
                               mask: LabelMap,
                               classID: UInt16,
                               bounds: MONAITransforms.VoxelBounds) throws -> [String: Double] {
        guard bounds.width > 0, bounds.height > 0, bounds.depth > 0 else {
            throw ClassificationError.emptyLesion
        }
        guard volume.width == mask.width,
              volume.height == mask.height,
              volume.depth == mask.depth else {
            throw ClassificationError.gridMismatch(
                "mask \(mask.width)x\(mask.height)x\(mask.depth) vs volume \(volume.width)x\(volume.height)x\(volume.depth)"
            )
        }

        // Collect intensity values + voxel coordinates that belong to the
        // lesion. A single pass over the bounding box is fine.
        var intensities: [Float] = []
        intensities.reserveCapacity(bounds.width * bounds.height * bounds.depth / 2)
        var lesionVoxels: [SIMD3<Int>] = []
        lesionVoxels.reserveCapacity(intensities.capacity)

        let w = volume.width, h = volume.height
        for z in bounds.minZ...bounds.maxZ {
            for y in bounds.minY...bounds.maxY {
                let rowStart = z * h * w + y * w
                for x in bounds.minX...bounds.maxX {
                    if mask.voxels[rowStart + x] == classID {
                        intensities.append(volume.pixels[rowStart + x])
                        lesionVoxels.append(SIMD3(x, y, z))
                    }
                }
            }
        }

        guard intensities.count >= 2 else {
            throw ClassificationError.emptyLesion
        }

        var features: [String: Double] = [:]

        // First-order statistics.
        firstOrder(intensities: intensities, features: &features)

        // Shape features.
        shape(lesionVoxels: lesionVoxels,
              mask: mask,
              classID: classID,
              spacing: volume.spacing,
              features: &features)

        // GLCM on a representative axial slice (the one containing the most
        // lesion voxels — tends to be the lesion's "widest" cross-section).
        glcm(volume: volume,
             mask: mask,
             classID: classID,
             bounds: bounds,
             features: &features)

        return features
    }

    // MARK: - First-order

    private static func firstOrder(intensities: [Float],
                                   features: inout [String: Double]) {
        let values = intensities.map { Double($0) }
        let n = Double(values.count)

        let sum = values.reduce(0, +)
        let mean = sum / n
        let sumSq = values.reduce(0) { $0 + $1 * $1 }
        let variance = sumSq / n - mean * mean
        let stddev = sqrt(max(0, variance))

        let sorted = values.sorted()
        let minV = sorted.first ?? 0
        let maxV = sorted.last ?? 0

        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
            return sorted[idx]
        }
        let p10 = percentile(0.10)
        let p25 = percentile(0.25)
        let p50 = percentile(0.50)
        let p75 = percentile(0.75)
        let p90 = percentile(0.90)

        // Centralised moments for skewness / kurtosis.
        var m3 = 0.0, m4 = 0.0
        for v in values {
            let d = v - mean
            let d2 = d * d
            m3 += d2 * d
            m4 += d2 * d2
        }
        m3 /= n
        m4 /= n
        let skewness = stddev > 0 ? m3 / pow(stddev, 3) : 0
        let kurtosis = stddev > 0 ? m4 / pow(stddev, 4) - 3 : 0  // excess kurtosis

        let meanAbsoluteDeviation = values.reduce(0) { $0 + abs($1 - mean) } / n
        let energy = sumSq
        let rms = sqrt(sumSq / n)

        // Histogram-based entropy / uniformity over the same gray-level bin
        // count the GLCM uses.
        let bins = Self.glcmGrayLevels
        let range = max(maxV - minV, 1e-12)
        var hist = [Double](repeating: 0, count: bins)
        for v in values {
            let idx = min(bins - 1, max(0, Int((v - minV) / range * Double(bins - 1))))
            hist[idx] += 1
        }
        var entropy = 0.0
        var uniformity = 0.0
        for count in hist where count > 0 {
            let p = count / n
            entropy -= p * log2(p)
            uniformity += p * p
        }

        features["original_firstorder_Mean"] = mean
        features["original_firstorder_StandardDeviation"] = stddev
        features["original_firstorder_Variance"] = variance
        features["original_firstorder_Minimum"] = minV
        features["original_firstorder_Maximum"] = maxV
        features["original_firstorder_Range"] = maxV - minV
        features["original_firstorder_Median"] = p50
        features["original_firstorder_10Percentile"] = p10
        features["original_firstorder_90Percentile"] = p90
        features["original_firstorder_InterquartileRange"] = p75 - p25
        features["original_firstorder_Skewness"] = skewness
        features["original_firstorder_Kurtosis"] = kurtosis
        features["original_firstorder_MeanAbsoluteDeviation"] = meanAbsoluteDeviation
        features["original_firstorder_Energy"] = energy
        features["original_firstorder_RootMeanSquared"] = rms
        features["original_firstorder_Entropy"] = entropy
        features["original_firstorder_Uniformity"] = uniformity
    }

    // MARK: - Shape

    private static func shape(lesionVoxels: [SIMD3<Int>],
                              mask: LabelMap,
                              classID: UInt16,
                              spacing: (x: Double, y: Double, z: Double),
                              features: inout [String: Double]) {
        let voxelCount = lesionVoxels.count
        let voxelVolume = spacing.x * spacing.y * spacing.z
        let volumeMM3 = Double(voxelCount) * voxelVolume

        // Surface area — count exposed faces for each lesion voxel.
        var exposedFaces = 0
        let w = mask.width, h = mask.height, d = mask.depth
        for v in lesionVoxels {
            let x = v.x, y = v.y, z = v.z
            let i = z * h * w + y * w + x
            func neighborIsLesion(_ nx: Int, _ ny: Int, _ nz: Int) -> Bool {
                guard nx >= 0, nx < w, ny >= 0, ny < h, nz >= 0, nz < d else { return false }
                return mask.voxels[nz * h * w + ny * w + nx] == classID
            }
            if !neighborIsLesion(x - 1, y, z) { exposedFaces += 1 }
            if !neighborIsLesion(x + 1, y, z) { exposedFaces += 1 }
            if !neighborIsLesion(x, y - 1, z) { exposedFaces += 1 }
            if !neighborIsLesion(x, y + 1, z) { exposedFaces += 1 }
            if !neighborIsLesion(x, y, z - 1) { exposedFaces += 1 }
            if !neighborIsLesion(x, y, z + 1) { exposedFaces += 1 }
            _ = i  // suppress unused-warning for possible future use
        }
        let faceAreaYZ = spacing.y * spacing.z
        let faceAreaXZ = spacing.x * spacing.z
        let faceAreaXY = spacing.x * spacing.y
        // Approximate: each exposed face is a mean spacing-face-area. For
        // near-isotropic spacings this is accurate to ~1 %.
        let meanFaceArea = (faceAreaYZ + faceAreaXZ + faceAreaXY) / 3
        let surfaceMM2 = Double(exposedFaces) * meanFaceArea

        // Sphericity: (pi^(1/3) * (6V)^(2/3)) / SA — 1.0 for a perfect sphere.
        let sphericity = surfaceMM2 > 0
            ? pow(.pi, 1.0 / 3.0) * pow(6 * volumeMM3, 2.0 / 3.0) / surfaceMM2
            : 0

        // PCA of lesion voxel world positions for major / minor / least axes.
        var mean = SIMD3<Double>.zero
        for v in lesionVoxels {
            mean += SIMD3<Double>(Double(v.x) * spacing.x,
                                   Double(v.y) * spacing.y,
                                   Double(v.z) * spacing.z)
        }
        mean /= Double(voxelCount)

        var cov = simd_double3x3()
        for v in lesionVoxels {
            let world = SIMD3<Double>(Double(v.x) * spacing.x,
                                      Double(v.y) * spacing.y,
                                      Double(v.z) * spacing.z)
            let d = world - mean
            cov[0][0] += d.x * d.x; cov[0][1] += d.x * d.y; cov[0][2] += d.x * d.z
            cov[1][0] += d.y * d.x; cov[1][1] += d.y * d.y; cov[1][2] += d.y * d.z
            cov[2][0] += d.z * d.x; cov[2][1] += d.z * d.y; cov[2][2] += d.z * d.z
        }
        let inv = 1.0 / Double(voxelCount)
        for r in 0..<3 { for c in 0..<3 { cov[r][c] *= inv } }

        // Eigenvalues via the symmetric 3x3 characteristic polynomial.
        let eigen = eigenvaluesSymmetric3x3(cov)
        let sorted = eigen.sorted(by: >)
        // pyradiomics defines major/minor/least axis lengths as
        // 4*sqrt(λ). See pyradiomics shape docs.
        let major = 4 * sqrt(max(0, sorted[0]))
        let minor = 4 * sqrt(max(0, sorted[1]))
        let least = 4 * sqrt(max(0, sorted[2]))
        let elongation = major > 0 ? sqrt(max(0, sorted[1]) / max(1e-12, sorted[0])) : 0
        let flatness   = major > 0 ? sqrt(max(0, sorted[2]) / max(1e-12, sorted[0])) : 0

        // Maximum 3D diameter — sub-sample surface voxels for O(k²) pairwise
        // distance (k ≤ `maximum3DDiameterSampleCap`).
        let diameter = maximum3DDiameter(
            lesionVoxels: lesionVoxels,
            mask: mask,
            classID: classID,
            spacing: spacing
        )

        features["original_shape_VoxelVolume"] = volumeMM3
        features["original_shape_VoxelCount"] = Double(voxelCount)
        features["original_shape_SurfaceArea"] = surfaceMM2
        features["original_shape_SurfaceVolumeRatio"] = volumeMM3 > 0 ? surfaceMM2 / volumeMM3 : 0
        features["original_shape_Sphericity"] = sphericity
        features["original_shape_MajorAxisLength"] = major
        features["original_shape_MinorAxisLength"] = minor
        features["original_shape_LeastAxisLength"] = least
        features["original_shape_Elongation"] = elongation
        features["original_shape_Flatness"] = flatness
        features["original_shape_Maximum3DDiameter"] = diameter
    }

    private static func maximum3DDiameter(lesionVoxels: [SIMD3<Int>],
                                          mask: LabelMap,
                                          classID: UInt16,
                                          spacing: (x: Double, y: Double, z: Double)) -> Double {
        // Keep only surface voxels (≥1 exposed face). Sub-sample to the cap.
        let w = mask.width, h = mask.height, d = mask.depth
        var surface: [SIMD3<Double>] = []
        surface.reserveCapacity(lesionVoxels.count / 4)
        for v in lesionVoxels {
            let (x, y, z) = (v.x, v.y, v.z)
            func inside(_ nx: Int, _ ny: Int, _ nz: Int) -> Bool {
                guard nx >= 0, nx < w, ny >= 0, ny < h, nz >= 0, nz < d else { return false }
                return mask.voxels[nz * h * w + ny * w + nx] == classID
            }
            if !inside(x - 1, y, z) || !inside(x + 1, y, z)
                || !inside(x, y - 1, z) || !inside(x, y + 1, z)
                || !inside(x, y, z - 1) || !inside(x, y, z + 1) {
                surface.append(SIMD3(
                    Double(x) * spacing.x,
                    Double(y) * spacing.y,
                    Double(z) * spacing.z
                ))
            }
        }
        if surface.isEmpty { return 0 }
        let cap = maximum3DDiameterSampleCap
        if surface.count > cap {
            let stride = surface.count / cap
            surface = stride > 0
                ? Swift.stride(from: 0, to: surface.count, by: max(1, stride)).map { surface[$0] }
                : surface
        }
        var maxSq = 0.0
        for i in 0..<surface.count {
            for j in (i + 1)..<surface.count {
                let delta = surface[i] - surface[j]
                let sq = simd_length_squared(delta)
                if sq > maxSq { maxSq = sq }
            }
        }
        return sqrt(maxSq)
    }

    /// Closed-form eigenvalues of a real 3x3 symmetric matrix. Uses the
    /// Smith (1961) formulation: avoids iterative solvers; numerically
    /// stable enough for the covariance matrices we build here.
    private static func eigenvaluesSymmetric3x3(_ m: simd_double3x3) -> [Double] {
        let a11 = m[0][0], a12 = m[0][1], a13 = m[0][2]
        let a22 = m[1][1], a23 = m[1][2]
        let a33 = m[2][2]
        let p1 = a12 * a12 + a13 * a13 + a23 * a23
        if p1 < 1e-20 {
            // Diagonal.
            return [a11, a22, a33]
        }
        let q = (a11 + a22 + a33) / 3
        let p2 = (a11 - q) * (a11 - q) + (a22 - q) * (a22 - q) + (a33 - q) * (a33 - q) + 2 * p1
        let p = sqrt(p2 / 6)
        var b = m
        for r in 0..<3 { b[r][r] -= q }
        let pInv = 1.0 / p
        for r in 0..<3 { for c in 0..<3 { b[r][c] *= pInv } }
        let det = b[0][0] * (b[1][1] * b[2][2] - b[1][2] * b[2][1])
                - b[0][1] * (b[1][0] * b[2][2] - b[1][2] * b[2][0])
                + b[0][2] * (b[1][0] * b[2][1] - b[1][1] * b[2][0])
        var r = det / 2
        if r < -1 { r = -1 }
        if r > 1 { r = 1 }
        let phi = acos(r) / 3
        let eig1 = q + 2 * p * cos(phi)
        let eig3 = q + 2 * p * cos(phi + 2.0 * .pi / 3.0)
        let eig2 = 3 * q - eig1 - eig3
        return [eig1, eig2, eig3]
    }

    // MARK: - GLCM (on representative axial slice)

    private static func glcm(volume: ImageVolume,
                             mask: LabelMap,
                             classID: UInt16,
                             bounds: MONAITransforms.VoxelBounds,
                             features: inout [String: Double]) {
        // Pick the axial slice with the most lesion voxels inside bounds.
        let w = volume.width, h = volume.height
        var bestZ = bounds.minZ
        var bestCount = 0
        for z in bounds.minZ...bounds.maxZ {
            var count = 0
            for y in bounds.minY...bounds.maxY {
                let rowStart = z * h * w + y * w
                for x in bounds.minX...bounds.maxX {
                    if mask.voxels[rowStart + x] == classID { count += 1 }
                }
            }
            if count > bestCount {
                bestCount = count
                bestZ = z
            }
        }
        if bestCount < 4 {
            // Too little signal on any one slice — skip GLCM, leave features
            // undefined. Callers that need complete feature vectors should
            // treat missing keys as zero.
            return
        }

        // Discretise to gray levels inside the lesion only.
        var values: [Float] = []
        values.reserveCapacity(bestCount)
        for y in bounds.minY...bounds.maxY {
            let rowStart = bestZ * h * w + y * w
            for x in bounds.minX...bounds.maxX where mask.voxels[rowStart + x] == classID {
                values.append(volume.pixels[rowStart + x])
            }
        }
        guard let minV = values.min(), let maxV = values.max() else { return }
        let range = max(Double(maxV - minV), 1e-12)
        let bins = Self.glcmGrayLevels

        @inline(__always) func bin(of value: Float) -> Int {
            let v = Double(value - minV) / range
            return min(bins - 1, max(0, Int(v * Double(bins - 1))))
        }

        // Build co-occurrence matrix for horizontal neighbour (offset 1,0).
        var glcm = Array(repeating: [Double](repeating: 0, count: bins), count: bins)
        var pairCount = 0
        for y in bounds.minY...bounds.maxY {
            let rowStart = bestZ * h * w + y * w
            for x in bounds.minX..<bounds.maxX {
                let i = rowStart + x
                if mask.voxels[i] == classID, mask.voxels[i + 1] == classID {
                    let a = bin(of: volume.pixels[i])
                    let b = bin(of: volume.pixels[i + 1])
                    glcm[a][b] += 1
                    glcm[b][a] += 1   // symmetric GLCM
                    pairCount += 2
                }
            }
        }
        guard pairCount > 0 else { return }
        let norm = 1.0 / Double(pairCount)

        var contrast = 0.0, energy = 0.0, homogeneity = 0.0
        var meanI = 0.0, meanJ = 0.0
        for i in 0..<bins {
            for j in 0..<bins {
                let p = glcm[i][j] * norm
                if p == 0 { continue }
                let di = Double(i)
                let dj = Double(j)
                contrast += (di - dj) * (di - dj) * p
                energy += p * p
                homogeneity += p / (1 + abs(di - dj))
                meanI += di * p
                meanJ += dj * p
            }
        }
        var varI = 0.0, varJ = 0.0, covIJ = 0.0
        for i in 0..<bins {
            for j in 0..<bins {
                let p = glcm[i][j] * norm
                if p == 0 { continue }
                varI += (Double(i) - meanI) * (Double(i) - meanI) * p
                varJ += (Double(j) - meanJ) * (Double(j) - meanJ) * p
                covIJ += (Double(i) - meanI) * (Double(j) - meanJ) * p
            }
        }
        let correlation = (varI > 0 && varJ > 0)
            ? covIJ / sqrt(varI * varJ)
            : 0

        features["original_glcm_Contrast"] = contrast
        features["original_glcm_JointEnergy"] = energy
        features["original_glcm_Homogeneity"] = homogeneity
        features["original_glcm_Correlation"] = correlation
    }
}
