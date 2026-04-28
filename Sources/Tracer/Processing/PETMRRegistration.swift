import Foundation
import simd

public enum PETMRRegistrationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case geometry
    case rigidAnatomical
    case rigidThenDeformable

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .geometry: return "Geometry only"
        case .rigidAnatomical: return "Rigid + pixel match"
        case .rigidThenDeformable: return "Pixel match + body warp"
        }
    }

    public var helpText: String {
        switch self {
        case .geometry:
            return "Use scanner/world geometry only. Best for simultaneous PET/MR or already registered images."
        case .rigidAnatomical:
            return "Initialize PET→MR fusion with body/anatomy centroids, then refine by pixel-to-pixel mutual information before resampling."
        case .rigidThenDeformable:
            return "Apply pixel-to-pixel mutual-information alignment plus a conservative body-envelope affine correction for non-simultaneous PET/MR."
        }
    }
}

public struct PETMRRegistrationResult: Sendable {
    public let movingToFixed: Transform3D
    public let fixedToMoving: Transform3D
    public let anchorDescription: String
    public let displacementMM: Double
    public let note: String
}

public enum PETMRRegistrationEngine {

    public static func estimatePETToMR(pet: ImageVolume,
                                       mr: ImageVolume,
                                       mode: PETMRRegistrationMode) -> PETMRRegistrationResult {
        switch mode {
        case .geometry:
            return PETMRRegistrationResult(
                movingToFixed: .identity,
                fixedToMoving: .identity,
                anchorDescription: "scanner/world geometry",
                displacementMM: 0,
                note: "PET/MR fusion uses scanner/world geometry only"
            )

        case .rigidAnatomical:
            let rigid = rigidByAnatomicalAnchor(moving: pet, fixed: mr)
            let refined = refineTranslationByMutualInformation(moving: pet,
                                                               fixed: mr,
                                                               initialMovingToFixed: rigid.transform)
            return result(transform: refined.transform,
                          anchor: rigid.anchorDescription,
                          displacementMM: rigid.displacementMM + refined.refinementMM,
                          notePrefix: refined.didRefine
                            ? "PET/MR rigid anatomical + pixel-to-pixel mutual-information initialization"
                            : "PET/MR rigid anatomical + pixel-to-pixel mutual-information check")

        case .rigidThenDeformable:
            let rigid = rigidByAnatomicalAnchor(moving: pet, fixed: mr)
            let refined = refineTranslationByMutualInformation(moving: pet,
                                                               fixed: mr,
                                                               initialMovingToFixed: rigid.transform)
            let bodyFit = bodyEnvelopeAffine(moving: pet,
                                             fixed: mr,
                                             initialMovingToFixed: refined.transform) ?? refined.transform
            let combined = bodyFit
            return result(transform: combined,
                          anchor: rigid.anchorDescription,
                          displacementMM: rigid.displacementMM + refined.refinementMM,
                          notePrefix: refined.didRefine
                            ? "PET/MR pixel-to-pixel MI + body-envelope warp"
                            : "PET/MR pixel-to-pixel MI check + body-envelope warp")
        }
    }

    private static func result(transform: Transform3D,
                               anchor: String,
                               displacementMM: Double,
                               notePrefix: String) -> PETMRRegistrationResult {
        PETMRRegistrationResult(
            movingToFixed: transform,
            fixedToMoving: transform.inverse,
            anchorDescription: anchor,
            displacementMM: displacementMM,
            note: "\(notePrefix): \(anchor), initial offset \(String(format: "%.1f", displacementMM)) mm. Review local anatomy before labeling."
        )
    }

    private static func rigidByAnatomicalAnchor(moving: ImageVolume,
                                                fixed: ImageVolume)
        -> (transform: Transform3D, anchorDescription: String, displacementMM: Double) {
        let movingAnchor = anchorCentroid(for: moving)
        let fixedAnchor = anchorCentroid(for: fixed)
        let offset = fixedAnchor.point - movingAnchor.point
        return (
            Transform3D.translation(offset.x, offset.y, offset.z),
            "\(movingAnchor.description) → \(fixedAnchor.description)",
            simd_length(offset)
        )
    }

    private static func bodyEnvelopeAffine(moving: ImageVolume,
                                           fixed: ImageVolume,
                                           initialMovingToFixed: Transform3D) -> Transform3D? {
        guard let movingBox = bodyBoundingBox(for: moving, transform: initialMovingToFixed),
              let fixedBox = bodyBoundingBox(for: fixed) else {
            return nil
        }

        func safeScale(_ fixedExtent: Double, _ movingExtent: Double) -> Double {
            guard fixedExtent.isFinite, movingExtent.isFinite, movingExtent > 1 else { return 1 }
            let ratio = fixedExtent / movingExtent
            // PET often has a larger field of view than MRI. That is not a
            // reason to shrink anatomy. Only apply an affine scale when the
            // body/anatomy envelopes are plausibly comparable; otherwise the
            // PET is resampled/cropped onto the MRI grid after rigid/MI
            // alignment.
            guard ratio >= 0.65, ratio <= 1.55 else { return 1 }
            return max(0.85, min(1.15, ratio))
        }

        let sourceCenter = movingBox.center
        let targetCenter = fixedBox.center
        let scale = SIMD3<Double>(
            safeScale(fixedBox.extent.x, movingBox.extent.x),
            safeScale(fixedBox.extent.y, movingBox.extent.y),
            safeScale(fixedBox.extent.z, movingBox.extent.z)
        )

        var matrix = matrix_identity_double4x4
        matrix[0, 0] = scale.x
        matrix[1, 1] = scale.y
        matrix[2, 2] = scale.z
        matrix[3, 0] = targetCenter.x - scale.x * sourceCenter.x
        matrix[3, 1] = targetCenter.y - scale.y * sourceCenter.y
        matrix[3, 2] = targetCenter.z - scale.z * sourceCenter.z
        let correction = Transform3D(matrix: matrix)
        return correction.concatenate(initialMovingToFixed)
    }

    private static func anchorCentroid(for volume: ImageVolume) -> (point: SIMD3<Double>, description: String) {
        let modality = Modality.normalize(volume.modality)
        if modality == .CT,
           let bone = centroid(volume: volume, mask: .ctBone) {
            return (bone, "CT bone anchor")
        }
        if let body = centroid(volume: volume, mask: maskKind(for: modality)) {
            switch modality {
            case .MR:
                return (body, "MR body/anatomy anchor")
            case .PT:
                return (body, "PET uptake/body anchor")
            default:
                return (body, "\(modality.displayName) body anchor")
            }
        }
        return (geometryCenter(volume), "\(modality.displayName) geometry center")
    }

    private static func bodyBoundingBox(for volume: ImageVolume,
                                        transform: Transform3D = .identity) -> (min: SIMD3<Double>, max: SIMD3<Double>, center: SIMD3<Double>, extent: SIMD3<Double>)? {
        let modality = Modality.normalize(volume.modality)
        let mask = maskKind(for: modality)
        let step = samplingStride(for: volume)
        var found = false
        var minPoint = SIMD3<Double>(Double.greatestFiniteMagnitude,
                                     Double.greatestFiniteMagnitude,
                                     Double.greatestFiniteMagnitude)
        var maxPoint = SIMD3<Double>(-Double.greatestFiniteMagnitude,
                                     -Double.greatestFiniteMagnitude,
                                     -Double.greatestFiniteMagnitude)

        for z in Swift.stride(from: 0, to: volume.depth, by: step) {
            for y in Swift.stride(from: 0, to: volume.height, by: step) {
                for x in Swift.stride(from: 0, to: volume.width, by: step) {
                    let value = volume.intensity(z: z, y: y, x: x)
                    guard mask.includes(value, range: volume.intensityRange) else { continue }
                    let point = transform.apply(to: volume.worldPoint(z: z, y: y, x: x))
                    minPoint = simd_min(minPoint, point)
                    maxPoint = simd_max(maxPoint, point)
                    found = true
                }
            }
        }

        guard found else { return nil }
        let center = (minPoint + maxPoint) / 2
        return (minPoint, maxPoint, center, maxPoint - minPoint)
    }

    private static func refineTranslationByMutualInformation(moving: ImageVolume,
                                                             fixed: ImageVolume,
                                                             initialMovingToFixed: Transform3D) -> (transform: Transform3D, refinementMM: Double, didRefine: Bool) {
        let samples = fixedSamples(for: fixed)
        guard samples.count >= 128 else {
            return (initialMovingToFixed, 0, false)
        }
        let fixedRange = finiteRange(samples.map { $0.value })
        let movingRange = moving.intensityRange
        guard fixedRange.max > fixedRange.min,
              movingRange.max > movingRange.min else {
            return (initialMovingToFixed, 0, false)
        }

        var bestOffset = SIMD3<Double>(0, 0, 0)
        var bestScore = mutualInformationScore(
            moving: moving,
            fixedSamples: samples,
            fixedRange: fixedRange,
            movingRange: movingRange,
            movingToFixed: initialMovingToFixed
        )
        guard bestScore.isFinite else {
            return (initialMovingToFixed, 0, false)
        }

        let passes: [(radius: Double, step: Double)] = [
            (30, 15),
            (12, 6),
            (4, 2)
        ]
        for pass in passes {
            var localBest = bestOffset
            var localScore = bestScore
            var dz = -pass.radius
            while dz <= pass.radius + 0.0001 {
                var dy = -pass.radius
                while dy <= pass.radius + 0.0001 {
                    var dx = -pass.radius
                    while dx <= pass.radius + 0.0001 {
                        let offset = bestOffset + SIMD3<Double>(dx, dy, dz)
                        let candidate = Transform3D.translation(offset.x, offset.y, offset.z)
                            .concatenate(initialMovingToFixed)
                        let score = mutualInformationScore(
                            moving: moving,
                            fixedSamples: samples,
                            fixedRange: fixedRange,
                            movingRange: movingRange,
                            movingToFixed: candidate
                        )
                        if score > localScore {
                            localScore = score
                            localBest = offset
                        }
                        dx += pass.step
                    }
                    dy += pass.step
                }
                dz += pass.step
            }
            bestOffset = localBest
            bestScore = localScore
        }

        let refinementMM = simd_length(bestOffset)
        guard refinementMM >= 0.5 else {
            return (initialMovingToFixed, 0, false)
        }
        let refined = Transform3D.translation(bestOffset.x, bestOffset.y, bestOffset.z)
            .concatenate(initialMovingToFixed)
        return (refined, refinementMM, true)
    }

    private static func fixedSamples(for fixed: ImageVolume) -> [(world: SIMD3<Double>, value: Float)] {
        let modality = Modality.normalize(fixed.modality)
        let mask = maskKind(for: modality)
        let step = max(1, Int(pow(Double(max(1, fixed.width * fixed.height * fixed.depth)) / 12_000.0, 1.0 / 3.0).rounded()))
        var samples: [(world: SIMD3<Double>, value: Float)] = []
        samples.reserveCapacity(12_000)
        for z in Swift.stride(from: 0, to: fixed.depth, by: step) {
            for y in Swift.stride(from: 0, to: fixed.height, by: step) {
                for x in Swift.stride(from: 0, to: fixed.width, by: step) {
                    let value = fixed.intensity(z: z, y: y, x: x)
                    guard mask.includes(value, range: fixed.intensityRange) else { continue }
                    samples.append((fixed.worldPoint(z: z, y: y, x: x), value))
                }
            }
        }
        if samples.count >= 128 {
            return samples
        }
        for z in Swift.stride(from: 0, to: fixed.depth, by: step) {
            for y in Swift.stride(from: 0, to: fixed.height, by: step) {
                for x in Swift.stride(from: 0, to: fixed.width, by: step) {
                    let value = fixed.intensity(z: z, y: y, x: x)
                    guard value.isFinite else { continue }
                    samples.append((fixed.worldPoint(z: z, y: y, x: x), value))
                }
            }
        }
        return samples
    }

    private static func mutualInformationScore(moving: ImageVolume,
                                               fixedSamples: [(world: SIMD3<Double>, value: Float)],
                                               fixedRange: (min: Float, max: Float),
                                               movingRange: (min: Float, max: Float),
                                               movingToFixed: Transform3D) -> Double {
        let fixedToMoving = movingToFixed.inverse
        let bins = 32
        var joint = [Double](repeating: 0, count: bins * bins)
        var fixedHist = [Double](repeating: 0, count: bins)
        var movingHist = [Double](repeating: 0, count: bins)
        var count = 0.0

        for sample in fixedSamples {
            let movingWorld = fixedToMoving.apply(to: sample.world)
            let voxel = moving.voxelCoordinates(from: movingWorld)
            guard let movingValue = linearSample(moving, x: voxel.x, y: voxel.y, z: voxel.z) else { continue }
            let fixedBin = histogramBin(sample.value, range: fixedRange, bins: bins)
            let movingBin = histogramBin(movingValue, range: movingRange, bins: bins)
            joint[fixedBin * bins + movingBin] += 1
            fixedHist[fixedBin] += 1
            movingHist[movingBin] += 1
            count += 1
        }

        guard count >= 128 else { return -.infinity }
        let hFixed = entropy(fixedHist, count: count)
        let hMoving = entropy(movingHist, count: count)
        let hJoint = entropy(joint, count: count)
        guard hFixed > 0, hMoving > 0, hJoint > 0 else { return -.infinity }
        let mi = hFixed + hMoving - hJoint
        return mi / sqrt(hFixed * hMoving)
    }

    private static func finiteRange(_ values: [Float]) -> (min: Float, max: Float) {
        var minValue = Float.greatestFiniteMagnitude
        var maxValue = -Float.greatestFiniteMagnitude
        for value in values where value.isFinite {
            minValue = min(minValue, value)
            maxValue = max(maxValue, value)
        }
        guard minValue.isFinite, maxValue.isFinite else { return (0, 1) }
        return (minValue, maxValue)
    }

    private static func histogramBin(_ value: Float,
                                     range: (min: Float, max: Float),
                                     bins: Int) -> Int {
        let denominator = max(0.000001, range.max - range.min)
        let normalized = max(0, min(1, (value - range.min) / denominator))
        return min(bins - 1, max(0, Int(normalized * Float(bins - 1))))
    }

    private static func entropy(_ histogram: [Double], count: Double) -> Double {
        var result = 0.0
        for value in histogram where value > 0 {
            let p = value / count
            result -= p * log(p)
        }
        return result
    }

    private static func linearSample(_ volume: ImageVolume,
                                     x: Double,
                                     y: Double,
                                     z: Double) -> Float? {
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let z0 = Int(floor(z))
        guard x0 >= 0, y0 >= 0, z0 >= 0,
              x <= Double(volume.width - 1),
              y <= Double(volume.height - 1),
              z <= Double(volume.depth - 1) else { return nil }
        let x1 = min(x0 + 1, volume.width - 1)
        let y1 = min(y0 + 1, volume.height - 1)
        let z1 = min(z0 + 1, volume.depth - 1)
        let dx = Float(x - Double(x0))
        let dy = Float(y - Double(y0))
        let dz = Float(z - Double(z0))

        func at(_ xi: Int, _ yi: Int, _ zi: Int) -> Float {
            volume.pixels[zi * volume.height * volume.width + yi * volume.width + xi]
        }

        let c00 = at(x0, y0, z0) * (1 - dx) + at(x1, y0, z0) * dx
        let c01 = at(x0, y0, z1) * (1 - dx) + at(x1, y0, z1) * dx
        let c10 = at(x0, y1, z0) * (1 - dx) + at(x1, y1, z0) * dx
        let c11 = at(x0, y1, z1) * (1 - dx) + at(x1, y1, z1) * dx
        let c0 = c00 * (1 - dy) + c10 * dy
        let c1 = c01 * (1 - dy) + c11 * dy
        return c0 * (1 - dz) + c1 * dz
    }

    private static func centroid(volume: ImageVolume, mask: MaskKind) -> SIMD3<Double>? {
        let step = samplingStride(for: volume)
        var sum = SIMD3<Double>(0, 0, 0)
        var count = 0.0
        for z in Swift.stride(from: 0, to: volume.depth, by: step) {
            for y in Swift.stride(from: 0, to: volume.height, by: step) {
                for x in Swift.stride(from: 0, to: volume.width, by: step) {
                    let value = volume.intensity(z: z, y: y, x: x)
                    guard mask.includes(value, range: volume.intensityRange) else { continue }
                    sum += volume.worldPoint(z: z, y: y, x: x)
                    count += 1
                }
            }
        }
        guard count >= 32 else { return nil }
        return sum / count
    }

    private static func geometryCenter(_ volume: ImageVolume) -> SIMD3<Double> {
        volume.worldPoint(voxel: SIMD3<Double>(
            Double(volume.width - 1) / 2,
            Double(volume.height - 1) / 2,
            Double(volume.depth - 1) / 2
        ))
    }

    private static func samplingStride(for volume: ImageVolume) -> Int {
        let voxels = max(1, volume.width * volume.height * volume.depth)
        return max(1, Int(pow(Double(voxels) / 140_000.0, 1.0 / 3.0).rounded()))
    }

    private static func maskKind(for modality: Modality) -> MaskKind {
        switch modality {
        case .CT: return .ctBody
        case .PT: return .petBody
        case .MR: return .mrBody
        default: return .nonZeroBody
        }
    }
}

private enum MaskKind {
    case ctBone
    case ctBody
    case petBody
    case mrBody
    case nonZeroBody

    func includes(_ value: Float, range: (min: Float, max: Float)) -> Bool {
        guard value.isFinite else { return false }
        let span = max(1, range.max - range.min)
        switch self {
        case .ctBone:
            return value > 250
        case .ctBody:
            return value > -500 && value < 3000
        case .petBody:
            return value > max(0, range.min + span * 0.12)
        case .mrBody:
            return value > range.min + span * 0.08
        case .nonZeroBody:
            return abs(value) > 0.0001
        }
    }
}
