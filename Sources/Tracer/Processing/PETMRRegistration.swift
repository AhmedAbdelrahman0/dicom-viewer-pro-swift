import Foundation
import simd

public enum PETMRRegistrationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automaticBestFit
    case geometry
    case rigidAnatomical
    case rigidThenDeformable

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automaticBestFit: return "Auto best fit"
        case .geometry: return "Geometry only"
        case .rigidAnatomical: return "Rigid rotation + pixel match"
        case .rigidThenDeformable: return "Similarity pixel fit + body warp"
        }
    }

    public var helpText: String {
        switch self {
        case .automaticBestFit:
            return "Use scanner geometry first, test rigid/body-fit/visual-fit, add local segmentation polish, and run available external engines such as SimpleITK, then only accept a more complex fit when PET/MR QA improves materially."
        case .geometry:
            return "Use scanner/world geometry only. Best for simultaneous PET/MR or already registered images."
        case .rigidAnatomical:
            return "Initialize PET→MR fusion with body/anatomy centroids, search small rigid rotations, then refine by pixel-to-pixel mutual information before resampling."
        case .rigidThenDeformable:
            return "Fit PET to MRI by body/anatomy envelope, rotation, and controlled scale, then apply a conservative body-envelope correction for non-simultaneous PET/MR."
        }
    }
}

public struct PETMRRegistrationResult: Sendable {
    public let movingToFixed: Transform3D
    public let fixedToMoving: Transform3D
    public let anchorDescription: String
    public let displacementMM: Double
    public let optimizerDescription: String
    public let rotationDegrees: SIMD3<Double>
    public let scale: Double
    public let score: Double?
    public let note: String
}

public struct PETMRVisualFitCorrection: Sendable {
    public let sourceToDisplay: Transform3D
    public let scale: Double
    public let translationMM: SIMD3<Double>
    public let note: String
}

public enum PETMRRegistrationEngine {

    public static func estimatePETToMR(pet: ImageVolume,
                                       mr: ImageVolume,
                                       mode: PETMRRegistrationMode) -> PETMRRegistrationResult {
        switch mode {
        case .automaticBestFit:
            return estimatePETToMR(pet: pet, mr: mr, mode: .rigidThenDeformable)

        case .geometry:
            return PETMRRegistrationResult(
                movingToFixed: .identity,
                fixedToMoving: .identity,
                anchorDescription: "scanner/world geometry",
                displacementMM: 0,
                optimizerDescription: "scanner/world geometry",
                rotationDegrees: SIMD3<Double>(0, 0, 0),
                scale: 1,
                score: nil,
                note: "PET/MR fusion uses scanner/world geometry only"
            )

        case .rigidAnatomical:
            let rigid = rigidByAnatomicalAnchor(moving: pet, fixed: mr)
            let similarity = refineRigidByPixelSimilarity(moving: pet,
                                                          fixed: mr,
                                                          initialMovingToFixed: rigid.transform,
                                                          allowScale: false)
            let refined = refineTranslationByMutualInformation(moving: pet,
                                                               fixed: mr,
                                                               initialMovingToFixed: similarity.transform)
            return result(transform: refined.transform,
                          moving: pet,
                          anchor: rigid.anchorDescription,
                          optimizer: similarity,
                          translationRefinementMM: refined.refinementMM,
                          notePrefix: refined.didRefine
                            ? "PET/MR rigid rotation + pixel-to-pixel mutual-information initialization"
                            : "PET/MR rigid rotation + pixel-to-pixel mutual-information check")

        case .rigidThenDeformable:
            let rigid = rigidByAnatomicalAnchor(moving: pet, fixed: mr)
            let similarity = refineRigidByPixelSimilarity(moving: pet,
                                                          fixed: mr,
                                                          initialMovingToFixed: rigid.transform,
                                                          allowScale: true)
            let refined = refineTranslationByMutualInformation(moving: pet,
                                                               fixed: mr,
                                                               initialMovingToFixed: similarity.transform)
            let bodyFit = bodyEnvelopeAffine(moving: pet,
                                             fixed: mr,
                                             initialMovingToFixed: refined.transform) ?? refined.transform
            let combined = bodyFit
            return result(transform: combined,
                          moving: pet,
                          anchor: rigid.anchorDescription,
                          optimizer: similarity,
                          translationRefinementMM: refined.refinementMM,
                          notePrefix: refined.didRefine
                            ? "PET/MR similarity pixel fit + body-envelope warp"
                            : "PET/MR similarity pixel fit check + body-envelope warp")
        }
    }

    private static func result(transform: Transform3D,
                               moving: ImageVolume,
                               anchor: String,
                               optimizer: SimilaritySearchResult,
                               translationRefinementMM: Double,
                               notePrefix: String) -> PETMRRegistrationResult {
        let displacementMM = centerShift(moving: moving, transform: transform)
        let scoreText = optimizer.score.map { String(format: "%.3f", $0) } ?? "n/a"
        let transformText = String(
            format: "rotation X %.1f° / Y %.1f° / Z %.1f°, scale %.2fx, translation polish %.1f mm, score %@",
            optimizer.rotationDegrees.x,
            optimizer.rotationDegrees.y,
            optimizer.rotationDegrees.z,
            optimizer.scale,
            translationRefinementMM,
            scoreText
        )
        return PETMRRegistrationResult(
            movingToFixed: transform,
            fixedToMoving: transform.inverse,
            anchorDescription: anchor,
            displacementMM: displacementMM,
            optimizerDescription: transformText,
            rotationDegrees: optimizer.rotationDegrees,
            scale: optimizer.scale,
            score: optimizer.score,
            note: "\(notePrefix): \(anchor), \(transformText), center shift \(String(format: "%.1f", displacementMM)) mm. Review local anatomy before labeling."
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

    private static func refineRigidByPixelSimilarity(moving: ImageVolume,
                                                     fixed: ImageVolume,
                                                     initialMovingToFixed: Transform3D,
                                                     allowScale: Bool) -> SimilaritySearchResult {
        let samples = registrationSamples(for: fixed)
        guard samples.count >= 128 else {
            return SimilaritySearchResult(
                transform: initialMovingToFixed,
                rotationDegrees: SIMD3<Double>(0, 0, 0),
                scale: 1,
                score: nil,
                didImprove: false
            )
        }

        let intensitySamples: [(world: SIMD3<Double>, value: Float)] = samples.map {
            (world: $0.world, value: $0.value)
        }
        let movingMaskSamples = maskWorldSamples(for: moving)
        let fixedRange = finiteRange(intensitySamples.map { $0.value })
        let movingRange = moving.intensityRange
        guard movingMaskSamples.count >= 32,
              fixedRange.max > fixedRange.min,
              movingRange.max > movingRange.min else {
            return SimilaritySearchResult(
                transform: initialMovingToFixed,
                rotationDegrees: SIMD3<Double>(0, 0, 0),
                scale: 1,
                score: nil,
                didImprove: false
            )
        }

        let movingBox = bodyBoundingBox(for: moving)
        let fixedBox = bodyBoundingBox(for: fixed)
        let movingCenter = movingBox?.center ?? geometryCenter(moving)
        let fixedCenter = fixedBox?.center ?? geometryCenter(fixed)
        let baseScale = allowScale
            ? envelopeScale(movingExtent: movingBox?.extent, fixedExtent: fixedBox?.extent)
            : 1

        var best = SimilarityCandidate(
            transform: initialMovingToFixed,
            rotation: SIMD3<Double>(0, 0, 0),
            scale: 1,
            score: registrationScore(
                moving: moving,
                fixed: fixed,
                fixedSamples: samples,
                fixedIntensitySamples: intensitySamples,
                movingMaskSamples: movingMaskSamples,
                fixedRange: fixedRange,
                movingRange: movingRange,
                movingToFixed: initialMovingToFixed
            )
        )

        let coarseScaleMultipliers = allowScale ? [0.78, 0.90, 1.0, 1.10, 1.24] : [1.0]
        let coarseRX = degrees([-12, 0, 12])
        let coarseRY = degrees([-12, 0, 12])
        let coarseRZ = degrees([-180, -90, -45, -30, -15, 0, 15, 30, 45, 90, 180])
        for sx in coarseScaleMultipliers {
            let scale = clamp(baseScale * sx, allowScale ? 0.50 : 1.0, allowScale ? 1.85 : 1.0)
            for rx in coarseRX {
                for ry in coarseRY {
                    for rz in coarseRZ {
                        evaluateSimilarityCandidate(
                            moving: moving,
                            fixed: fixed,
                            fixedSamples: samples,
                            fixedIntensitySamples: intensitySamples,
                            movingMaskSamples: movingMaskSamples,
                            fixedRange: fixedRange,
                            movingRange: movingRange,
                            movingCenter: movingCenter,
                            fixedCenter: fixedCenter,
                            rotation: SIMD3<Double>(rx, ry, rz),
                            scale: scale,
                            best: &best
                        )
                    }
                }
            }
        }

        let fineScaleOffsets = allowScale ? [-0.08, -0.04, 0, 0.04, 0.08] : [0]
        let fineRX = offsets(around: best.rotation.x, degrees: [-5, 0, 5])
        let fineRY = offsets(around: best.rotation.y, degrees: [-5, 0, 5])
        let fineRZ = offsets(around: best.rotation.z, degrees: [-10, -5, 0, 5, 10])
        for ds in fineScaleOffsets {
            let scale = clamp(best.scale + ds, allowScale ? 0.50 : 1.0, allowScale ? 1.85 : 1.0)
            for rx in fineRX {
                for ry in fineRY {
                    for rz in fineRZ {
                        evaluateSimilarityCandidate(
                            moving: moving,
                            fixed: fixed,
                            fixedSamples: samples,
                            fixedIntensitySamples: intensitySamples,
                            movingMaskSamples: movingMaskSamples,
                            fixedRange: fixedRange,
                            movingRange: movingRange,
                            movingCenter: movingCenter,
                            fixedCenter: fixedCenter,
                            rotation: SIMD3<Double>(rx, ry, rz),
                            scale: scale,
                            best: &best
                        )
                    }
                }
            }
        }

        let didImprove = best.score.isFinite
        return SimilaritySearchResult(
            transform: didImprove ? best.transform : initialMovingToFixed,
            rotationDegrees: radiansToDegrees(best.rotation),
            scale: didImprove ? best.scale : 1,
            score: didImprove ? best.score : nil,
            didImprove: didImprove
        )
    }

    private static func evaluateSimilarityCandidate(moving: ImageVolume,
                                                    fixed: ImageVolume,
                                                    fixedSamples: [RegistrationSample],
                                                    fixedIntensitySamples: [(world: SIMD3<Double>, value: Float)],
                                                    movingMaskSamples: [SIMD3<Double>],
                                                    fixedRange: (min: Float, max: Float),
                                                    movingRange: (min: Float, max: Float),
                                                    movingCenter: SIMD3<Double>,
                                                    fixedCenter: SIMD3<Double>,
                                                    rotation: SIMD3<Double>,
                                                    scale: Double,
                                                    best: inout SimilarityCandidate) {
        let candidate = centeredSimilarityTransform(
            movingCenter: movingCenter,
            fixedCenter: fixedCenter,
            rotation: rotation,
            scale: scale
        )
        let score = registrationScore(
            moving: moving,
            fixed: fixed,
            fixedSamples: fixedSamples,
            fixedIntensitySamples: fixedIntensitySamples,
            movingMaskSamples: movingMaskSamples,
            fixedRange: fixedRange,
            movingRange: movingRange,
            movingToFixed: candidate
        )
        if score > best.score + 0.0001 {
            best = SimilarityCandidate(
                transform: candidate,
                rotation: rotation,
                scale: scale,
                score: score
            )
        }
    }

    private static func centeredSimilarityTransform(movingCenter: SIMD3<Double>,
                                                    fixedCenter: SIMD3<Double>,
                                                    rotation: SIMD3<Double>,
                                                    scale: Double) -> Transform3D {
        let toMovingOrigin = Transform3D.translation(-movingCenter.x, -movingCenter.y, -movingCenter.z)
        let scaled = Transform3D.scale(scale)
        let rotated = Transform3D.rotationZ(rotation.z)
            .concatenate(Transform3D.rotationY(rotation.y))
            .concatenate(Transform3D.rotationX(rotation.x))
        let toFixedCenter = Transform3D.translation(fixedCenter.x, fixedCenter.y, fixedCenter.z)
        return toFixedCenter
            .concatenate(rotated)
            .concatenate(scaled)
            .concatenate(toMovingOrigin)
    }

    private static func envelopeScale(movingExtent: SIMD3<Double>?,
                                      fixedExtent: SIMD3<Double>?) -> Double {
        guard let movingExtent, let fixedExtent else { return 1 }
        var ratios: [Double] = []
        for axis in 0..<3 {
            let moving = movingExtent[axis]
            let fixed = fixedExtent[axis]
            guard moving.isFinite, fixed.isFinite, moving > 10, fixed > 10 else { continue }
            let ratio = fixed / moving
            if ratio.isFinite, ratio >= 0.35, ratio <= 2.80 {
                ratios.append(ratio)
            }
        }
        guard !ratios.isEmpty else { return 1 }
        ratios.sort()
        let median = ratios[ratios.count / 2]
        return clamp(median, 0.50, 1.85)
    }

    private static func registrationScore(moving: ImageVolume,
                                          fixed: ImageVolume,
                                          fixedSamples: [RegistrationSample],
                                          fixedIntensitySamples: [(world: SIMD3<Double>, value: Float)],
                                          movingMaskSamples: [SIMD3<Double>],
                                          fixedRange: (min: Float, max: Float),
                                          movingRange: (min: Float, max: Float),
                                          movingToFixed: Transform3D) -> Double {
        let overlap = maskOverlapScore(moving: moving,
                                       fixedSamples: fixedSamples,
                                       movingToFixed: movingToFixed)
        guard overlap.isFinite else { return -.infinity }
        let containment = movingContainmentScore(movingMaskSamples: movingMaskSamples,
                                                fixed: fixed,
                                                movingToFixed: movingToFixed)
        guard containment.isFinite else { return -.infinity }
        let nmi = mutualInformationScore(
            moving: moving,
            fixedSamples: fixedIntensitySamples,
            fixedRange: fixedRange,
            movingRange: movingRange,
            movingToFixed: movingToFixed
        )
        let boundedNMI = nmi.isFinite ? max(0, min(1.5, nmi)) : 0
        return 0.62 * overlap + 0.28 * containment + 0.22 * boundedNMI
    }

    private static func maskOverlapScore(moving: ImageVolume,
                                         fixedSamples: [RegistrationSample],
                                         movingToFixed: Transform3D) -> Double {
        let movingMask = maskKind(for: Modality.normalize(moving.modality))
        let fixedToMoving = movingToFixed.inverse
        var intersection = 0.0
        var fixedCount = 0.0
        var movingCount = 0.0
        var pairedCount = 0.0
        for sample in fixedSamples {
            if sample.fixedInMask { fixedCount += 1 }
            let movingWorld = fixedToMoving.apply(to: sample.world)
            let voxel = moving.voxelCoordinates(from: movingWorld)
            guard let movingValue = linearSample(moving, x: voxel.x, y: voxel.y, z: voxel.z) else { continue }
            let movingInMask = movingMask.includes(movingValue, range: moving.intensityRange)
            if movingInMask { movingCount += 1 }
            if sample.fixedInMask && movingInMask { intersection += 1 }
            pairedCount += 1
        }
        guard pairedCount >= 128,
              fixedCount >= 32,
              movingCount >= 32 else { return -.infinity }
        let dice = (2 * intersection) / max(1, fixedCount + movingCount)
        let coverage = intersection / max(1, fixedCount)
        return 0.70 * dice + 0.30 * coverage
    }

    private static func movingContainmentScore(movingMaskSamples: [SIMD3<Double>],
                                               fixed: ImageVolume,
                                               movingToFixed: Transform3D) -> Double {
        let fixedMask = maskKind(for: Modality.normalize(fixed.modality))
        var inside = 0.0
        var total = 0.0
        for movingWorld in movingMaskSamples {
            let fixedWorld = movingToFixed.apply(to: movingWorld)
            let voxel = fixed.voxelCoordinates(from: fixedWorld)
            total += 1
            guard let fixedValue = linearSample(fixed, x: voxel.x, y: voxel.y, z: voxel.z) else {
                continue
            }
            if fixedMask.includes(fixedValue, range: fixed.intensityRange) {
                inside += 1
            }
        }
        guard total >= 32 else { return -.infinity }
        return inside / total
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
            // PET can have a larger acquired field of view than MRI, but the
            // uptake/body envelope should still fit inside the MR anatomy
            // envelope after PET/MR registration. Keep the correction bounded
            // enough for QA while allowing brain PET/MR pairs that need a
            // visible shrink to avoid a permanently oversized overlay.
            guard ratio >= 0.55, ratio <= 1.70 else { return 1 }
            return max(0.70, min(1.25, ratio))
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

    public static func postResampleVisualFit(movingOnFixedGrid: ImageVolume,
                                             fixed: ImageVolume) -> PETMRVisualFitCorrection? {
        guard Modality.normalize(movingOnFixedGrid.modality) == .PT,
              Modality.normalize(fixed.modality) == .MR,
              hasSameGrid(movingOnFixedGrid, fixed) else {
            return nil
        }

        if let brainFit = brainPETVisualFit(movingOnFixedGrid: movingOnFixedGrid, fixed: fixed) {
            return brainFit
        }

        guard let movingBox = bodyBoundingBox(for: movingOnFixedGrid),
              let fixedBox = bodyBoundingBox(for: fixed) else {
            return nil
        }
        return visualFitCorrection(movingBox: movingBox,
                                   fixedBox: fixedBox,
                                   scaleRange: 0.70...1.20,
                                   minimumScaleDelta: 0.04,
                                   minimumTranslationMM: 3,
                                   notePrefix: "Post-resample PET/MR visual envelope fit",
                                   scaleStrategy: .median)
    }

    public static func postResampleSegmentationPolish(movingOnFixedGrid: ImageVolume,
                                                       fixed: ImageVolume) -> PETMRVisualFitCorrection? {
        guard Modality.normalize(movingOnFixedGrid.modality) == .PT,
              Modality.normalize(fixed.modality) == .MR,
              hasSameGrid(movingOnFixedGrid, fixed),
              isLikelyBrainMR(fixed) else {
            return nil
        }

        let samples = registrationSamples(for: fixed)
        let intensitySamples: [(world: SIMD3<Double>, value: Float)] = samples.map {
            (world: $0.world, value: $0.value)
        }
        let movingMaskSamples = maskWorldSamples(for: movingOnFixedGrid)
        let fixedRange = finiteRange(intensitySamples.map { $0.value })
        let movingRange = movingOnFixedGrid.intensityRange
        guard samples.count >= 128,
              movingMaskSamples.count >= 32,
              fixedRange.max > fixedRange.min,
              movingRange.max > movingRange.min else {
            return nil
        }

        let center = geometryCenter(fixed)
        let identityScore = segmentationPolishScore(
            moving: movingOnFixedGrid,
            fixed: fixed,
            fixedSamples: samples,
            fixedIntensitySamples: intensitySamples,
            movingMaskSamples: movingMaskSamples,
            fixedRange: fixedRange,
            movingRange: movingRange,
            movingToFixed: .identity
        )
        guard identityScore.isFinite else { return nil }

        var best = SegmentationPolishCandidate(
            transform: .identity,
            translationMM: SIMD3<Double>(0, 0, 0),
            rotationRadians: SIMD3<Double>(0, 0, 0),
            score: identityScore
        )

        func evaluate(translation: SIMD3<Double>, rotation: SIMD3<Double>) {
            let transform = segmentationPolishTransform(center: center,
                                                        translationMM: translation,
                                                        rotationRadians: rotation)
            let score = segmentationPolishScore(
                moving: movingOnFixedGrid,
                fixed: fixed,
                fixedSamples: samples,
                fixedIntensitySamples: intensitySamples,
                movingMaskSamples: movingMaskSamples,
                fixedRange: fixedRange,
                movingRange: movingRange,
                movingToFixed: transform
            )
            if score > best.score + 0.0005 {
                best = SegmentationPolishCandidate(transform: transform,
                                                   translationMM: translation,
                                                   rotationRadians: rotation,
                                                   score: score)
            }
        }

        let translationPasses: [(radius: Double, step: Double)] = [
            (6, 3),
            (2, 1),
            (0.75, 0.75)
        ]
        for pass in translationPasses {
            let anchor = best.translationMM
            var dz = -pass.radius
            while dz <= pass.radius + 0.0001 {
                var dy = -pass.radius
                while dy <= pass.radius + 0.0001 {
                    var dx = -pass.radius
                    while dx <= pass.radius + 0.0001 {
                        evaluate(translation: anchor + SIMD3<Double>(dx, dy, dz),
                                 rotation: best.rotationRadians)
                        dx += pass.step
                    }
                    dy += pass.step
                }
                dz += pass.step
            }
        }

        let rotationOffsets = degrees([-2, -1, 0, 1, 2])
        let translationAnchor = best.translationMM
        let rotationAnchor = best.rotationRadians
        for rx in rotationOffsets {
            for ry in rotationOffsets {
                for rz in rotationOffsets {
                    evaluate(translation: translationAnchor,
                             rotation: rotationAnchor + SIMD3<Double>(rx, ry, rz))
                }
            }
        }

        let finalTranslationAnchor = best.translationMM
        let finalRotation = best.rotationRadians
        for offset in [
            SIMD3<Double>(0.5, 0, 0), SIMD3<Double>(-0.5, 0, 0),
            SIMD3<Double>(0, 0.5, 0), SIMD3<Double>(0, -0.5, 0),
            SIMD3<Double>(0, 0, 0.5), SIMD3<Double>(0, 0, -0.5)
        ] {
            evaluate(translation: finalTranslationAnchor + offset, rotation: finalRotation)
        }

        let scoreGain = best.score - identityScore
        let shiftMM = simd_length(best.translationMM)
        let rotationDegrees = radiansToDegrees(best.rotationRadians)
        let maxRotation = max(abs(rotationDegrees.x), max(abs(rotationDegrees.y), abs(rotationDegrees.z)))
        guard scoreGain >= 0.018,
              shiftMM >= 0.35 || maxRotation >= 0.30 else {
            return nil
        }

        let note = String(
            format: "Post-resample PET/MR segmentation polish, local edge/MI QA +%.3f, shift X %.1f / Y %.1f / Z %.1f mm, rotate X %.1f° / Y %.1f° / Z %.1f°",
            scoreGain,
            best.translationMM.x,
            best.translationMM.y,
            best.translationMM.z,
            rotationDegrees.x,
            rotationDegrees.y,
            rotationDegrees.z
        )
        return PETMRVisualFitCorrection(sourceToDisplay: best.transform,
                                        scale: 1,
                                        translationMM: best.translationMM,
                                        note: note)
    }

    private static func brainPETVisualFit(movingOnFixedGrid: ImageVolume,
                                          fixed: ImageVolume) -> PETMRVisualFitCorrection? {
        guard isLikelyBrainMR(fixed) else { return nil }
        guard let movingBox = intensityBoundingBox(for: movingOnFixedGrid,
                                                   percentile: 99,
                                                   positiveOnly: true),
              let fixedBox = intensityBoundingBox(for: fixed,
                                                  percentile: 80,
                                                  positiveOnly: true) else {
            return nil
        }
        return visualFitCorrection(movingBox: movingBox,
                                   fixedBox: fixedBox,
                                   scaleRange: 0.65...1.15,
                                   minimumScaleDelta: 0.03,
                                   minimumTranslationMM: 2,
                                   notePrefix: "Post-resample PET/MR brain uptake fit",
                                   scaleStrategy: .axisFitInside(maxSpreadFromMedian: 0.18))
    }

    private enum VisualFitScaleStrategy {
        case median
        case fitInside
        case axisFitInside(maxSpreadFromMedian: Double)
    }

    private static func visualFitCorrection(
        movingBox: (min: SIMD3<Double>, max: SIMD3<Double>, center: SIMD3<Double>, extent: SIMD3<Double>),
        fixedBox: (min: SIMD3<Double>, max: SIMD3<Double>, center: SIMD3<Double>, extent: SIMD3<Double>),
        scaleRange: ClosedRange<Double>,
        minimumScaleDelta: Double,
        minimumTranslationMM: Double,
        notePrefix: String,
        scaleStrategy: VisualFitScaleStrategy
    ) -> PETMRVisualFitCorrection? {
        var ratios: [Double] = []
        for axis in 0..<3 {
            let movingExtent = movingBox.extent[axis]
            let fixedExtent = fixedBox.extent[axis]
            guard movingExtent.isFinite, fixedExtent.isFinite,
                  movingExtent > 10, fixedExtent > 10 else { continue }
            let ratio = fixedExtent / movingExtent
            if ratio.isFinite, ratio >= 0.45, ratio <= 1.45 {
                ratios.append(ratio)
            }
        }
        guard !ratios.isEmpty else { return nil }
        ratios.sort()
        let rawScale: Double
        let axisScale: SIMD3<Double>
        switch scaleStrategy {
        case .median:
            rawScale = ratios[ratios.count / 2]
            let clamped = clamp(rawScale, scaleRange.lowerBound, scaleRange.upperBound)
            axisScale = SIMD3<Double>(repeating: clamped)
        case .fitInside:
            rawScale = ratios.first ?? ratios[ratios.count / 2]
            let clamped = clamp(rawScale, scaleRange.lowerBound, scaleRange.upperBound)
            axisScale = SIMD3<Double>(repeating: clamped)
        case .axisFitInside(let maxSpreadFromMedian):
            rawScale = ratios.first ?? ratios[ratios.count / 2]
            let medianScale = clamp(ratios[ratios.count / 2], scaleRange.lowerBound, scaleRange.upperBound)
            let lower = max(scaleRange.lowerBound, medianScale * (1 - max(0, maxSpreadFromMedian)))
            let upper = min(scaleRange.upperBound, medianScale * (1 + max(0, maxSpreadFromMedian)))
            axisScale = SIMD3<Double>(
                boundedAxisScale(fixedBox.extent.x, movingBox.extent.x, fallback: medianScale, lower: lower, upper: upper),
                boundedAxisScale(fixedBox.extent.y, movingBox.extent.y, fallback: medianScale, lower: lower, upper: upper),
                boundedAxisScale(fixedBox.extent.z, movingBox.extent.z, fallback: medianScale, lower: lower, upper: upper)
            )
        }
        let scale = min(axisScale.x, min(axisScale.y, axisScale.z))
        let centerDelta = fixedBox.center - movingBox.center

        let scaleDelta = max(abs(axisScale.x - 1), max(abs(axisScale.y - 1), abs(axisScale.z - 1)))
        guard scaleDelta >= minimumScaleDelta || simd_length(centerDelta) >= minimumTranslationMM else {
            return nil
        }

        let sourceToDisplay = Transform3D.translation(fixedBox.center.x,
                                                      fixedBox.center.y,
                                                      fixedBox.center.z)
            .concatenate(Transform3D.scale(axisScale))
            .concatenate(Transform3D.translation(-movingBox.center.x,
                                                 -movingBox.center.y,
                                                 -movingBox.center.z))
        let scaleText: String
        switch scaleStrategy {
        case .axisFitInside:
            scaleText = String(format: "scale X %.2fx / Y %.2fx / Z %.2fx",
                               axisScale.x,
                               axisScale.y,
                               axisScale.z)
        case .median, .fitInside:
            scaleText = String(format: "scale %.2fx", scale)
        }
        let note = String(format: "\(notePrefix) %@, shift X %.1f / Y %.1f / Z %.1f mm",
                          scaleText,
                          centerDelta.x,
                          centerDelta.y,
                          centerDelta.z)
        return PETMRVisualFitCorrection(sourceToDisplay: sourceToDisplay,
                                        scale: scale,
                                        translationMM: centerDelta,
                                        note: note)
    }

    private static func segmentationPolishTransform(center: SIMD3<Double>,
                                                     translationMM: SIMD3<Double>,
                                                     rotationRadians: SIMD3<Double>) -> Transform3D {
        let rotation = Transform3D.rotationZ(rotationRadians.z)
            .concatenate(Transform3D.rotationY(rotationRadians.y))
            .concatenate(Transform3D.rotationX(rotationRadians.x))
        return Transform3D.translation(translationMM.x, translationMM.y, translationMM.z)
            .concatenate(Transform3D.translation(center.x, center.y, center.z))
            .concatenate(rotation)
            .concatenate(Transform3D.translation(-center.x, -center.y, -center.z))
    }

    private static func segmentationPolishScore(moving: ImageVolume,
                                                fixed: ImageVolume,
                                                fixedSamples: [RegistrationSample],
                                                fixedIntensitySamples: [(world: SIMD3<Double>, value: Float)],
                                                movingMaskSamples: [SIMD3<Double>],
                                                fixedRange: (min: Float, max: Float),
                                                movingRange: (min: Float, max: Float),
                                                movingToFixed: Transform3D) -> Double {
        let overlap = maskOverlapScore(moving: moving,
                                       fixedSamples: fixedSamples,
                                       movingToFixed: movingToFixed)
        guard overlap.isFinite else { return -.infinity }
        let containment = movingContainmentScore(movingMaskSamples: movingMaskSamples,
                                                fixed: fixed,
                                                movingToFixed: movingToFixed)
        guard containment.isFinite else { return -.infinity }
        let nmi = mutualInformationScore(moving: moving,
                                         fixedSamples: fixedIntensitySamples,
                                         fixedRange: fixedRange,
                                         movingRange: movingRange,
                                         movingToFixed: movingToFixed)
        let edge = edgeAgreementScore(moving: moving,
                                      fixed: fixed,
                                      fixedSamples: fixedSamples,
                                      movingToFixed: movingToFixed)
        let boundedNMI = nmi.isFinite ? max(0, min(1.5, nmi)) : 0
        let boundedEdge = edge.isFinite ? max(0, min(1, edge)) : 0
        return 0.36 * overlap + 0.20 * containment + 0.24 * boundedNMI + 0.20 * boundedEdge
    }

    private static func edgeAgreementScore(moving: ImageVolume,
                                           fixed: ImageVolume,
                                           fixedSamples: [RegistrationSample],
                                           movingToFixed: Transform3D) -> Double {
        let fixedToMoving = movingToFixed.inverse
        var count = 0
        var fixedEnergy = 0.0
        var movingEnergy = 0.0
        var product = 0.0
        for sample in fixedSamples where sample.fixedInMask {
            let fixedVoxel = fixed.voxelCoordinates(from: sample.world)
            let movingWorld = fixedToMoving.apply(to: sample.world)
            let movingVoxel = moving.voxelCoordinates(from: movingWorld)
            guard let fixedEdge = gradientMagnitude(fixed,
                                                    x: fixedVoxel.x,
                                                    y: fixedVoxel.y,
                                                    z: fixedVoxel.z),
                  let movingEdge = gradientMagnitude(moving,
                                                     x: movingVoxel.x,
                                                     y: movingVoxel.y,
                                                     z: movingVoxel.z) else {
                continue
            }
            let f = log1p(fixedEdge)
            let m = log1p(movingEdge)
            fixedEnergy += f * f
            movingEnergy += m * m
            product += f * m
            count += 1
        }
        guard count >= 64,
              fixedEnergy > 1e-8,
              movingEnergy > 1e-8 else {
            return -.infinity
        }
        return product / sqrt(fixedEnergy * movingEnergy)
    }

    private static func gradientMagnitude(_ volume: ImageVolume,
                                          x: Double,
                                          y: Double,
                                          z: Double) -> Double? {
        let xi = Int(round(x))
        let yi = Int(round(y))
        let zi = Int(round(z))
        guard xi > 0, xi < volume.width - 1,
              yi > 0, yi < volume.height - 1,
              zi > 0, zi < volume.depth - 1 else {
            return nil
        }
        let dx = Double(volume.intensity(z: zi, y: yi, x: xi + 1) -
                        volume.intensity(z: zi, y: yi, x: xi - 1)) / max(0.001, 2 * volume.spacing.x)
        let dy = Double(volume.intensity(z: zi, y: yi + 1, x: xi) -
                        volume.intensity(z: zi, y: yi - 1, x: xi)) / max(0.001, 2 * volume.spacing.y)
        let dz = Double(volume.intensity(z: zi + 1, y: yi, x: xi) -
                        volume.intensity(z: zi - 1, y: yi, x: xi)) / max(0.001, 2 * volume.spacing.z)
        let magnitude = sqrt(dx * dx + dy * dy + dz * dz)
        return magnitude.isFinite ? magnitude : nil
    }

    private static func boundedAxisScale(_ fixedExtent: Double,
                                         _ movingExtent: Double,
                                         fallback: Double,
                                         lower: Double,
                                         upper: Double) -> Double {
        guard fixedExtent.isFinite,
              movingExtent.isFinite,
              movingExtent > 10,
              fixedExtent > 10 else {
            return fallback
        }
        let ratio = fixedExtent / movingExtent
        guard ratio.isFinite else { return fallback }
        return clamp(ratio, lower, upper)
    }

    private static func intensityBoundingBox(for volume: ImageVolume,
                                             percentile: Double,
                                             positiveOnly: Bool) -> (min: SIMD3<Double>, max: SIMD3<Double>, center: SIMD3<Double>, extent: SIMD3<Double>)? {
        let thresholdStride = max(1, Int(ceil(pow(Double(max(1, volume.width * volume.height * volume.depth)) / 200_000.0, 1.0 / 3.0))))
        var sampled: [Float] = []
        sampled.reserveCapacity(220_000)
        for z in Swift.stride(from: 0, to: volume.depth, by: thresholdStride) {
            for y in Swift.stride(from: 0, to: volume.height, by: thresholdStride) {
                for x in Swift.stride(from: 0, to: volume.width, by: thresholdStride) {
                    let value = volume.intensity(z: z, y: y, x: x)
                    guard value.isFinite else { continue }
                    if positiveOnly && value <= 0 { continue }
                    sampled.append(value)
                }
            }
        }
        guard sampled.count >= 32 else { return nil }
        sampled.sort()
        let boundedPercentile = max(0, min(100, percentile))
        let percentileIndex = Int((Double(sampled.count - 1) * boundedPercentile / 100.0).rounded())
        let threshold = sampled[max(0, min(sampled.count - 1, percentileIndex))]

        let boxStride = max(1, thresholdStride / 2)
        var found = false
        var minPoint = SIMD3<Double>(Double.greatestFiniteMagnitude,
                                     Double.greatestFiniteMagnitude,
                                     Double.greatestFiniteMagnitude)
        var maxPoint = SIMD3<Double>(-Double.greatestFiniteMagnitude,
                                     -Double.greatestFiniteMagnitude,
                                     -Double.greatestFiniteMagnitude)
        for z in Swift.stride(from: 0, to: volume.depth, by: boxStride) {
            for y in Swift.stride(from: 0, to: volume.height, by: boxStride) {
                for x in Swift.stride(from: 0, to: volume.width, by: boxStride) {
                    let value = volume.intensity(z: z, y: y, x: x)
                    guard value.isFinite, value >= threshold else { continue }
                    if positiveOnly && value <= 0 { continue }
                    let point = volume.worldPoint(z: z, y: y, x: x)
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

    private static func isLikelyBrainMR(_ volume: ImageVolume) -> Bool {
        let extent = SIMD3<Double>(
            Double(max(1, volume.width - 1)) * volume.spacing.x,
            Double(max(1, volume.height - 1)) * volume.spacing.y,
            Double(max(1, volume.depth - 1)) * volume.spacing.z
        )
        let largest = max(extent.x, max(extent.y, extent.z))
        let smallest = min(extent.x, min(extent.y, extent.z))
        return largest <= 320 && smallest >= 80
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

    private static func hasSameGrid(_ lhs: ImageVolume, _ rhs: ImageVolume) -> Bool {
        lhs.width == rhs.width &&
        lhs.height == rhs.height &&
        lhs.depth == rhs.depth &&
        simd_length(SIMD3<Double>(lhs.spacing.x, lhs.spacing.y, lhs.spacing.z) -
                    SIMD3<Double>(rhs.spacing.x, rhs.spacing.y, rhs.spacing.z)) < 0.001 &&
        simd_length(lhs.originVector - rhs.originVector) < 0.001 &&
        simd_length(lhs.direction.columns.0 - rhs.direction.columns.0) < 0.001 &&
        simd_length(lhs.direction.columns.1 - rhs.direction.columns.1) < 0.001 &&
        simd_length(lhs.direction.columns.2 - rhs.direction.columns.2) < 0.001
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

    private static func registrationSamples(for fixed: ImageVolume) -> [RegistrationSample] {
        let modality = Modality.normalize(fixed.modality)
        let mask = maskKind(for: modality)
        let step = max(1, Int(ceil(pow(Double(max(1, fixed.width * fixed.height * fixed.depth)) / 12_000.0, 1.0 / 3.0))))
        var samples: [RegistrationSample] = []
        samples.reserveCapacity(16_000)
        for z in Swift.stride(from: 0, to: fixed.depth, by: step) {
            for y in Swift.stride(from: 0, to: fixed.height, by: step) {
                for x in Swift.stride(from: 0, to: fixed.width, by: step) {
                    let value = fixed.intensity(z: z, y: y, x: x)
                    guard value.isFinite else { continue }
                    samples.append(RegistrationSample(
                        world: fixed.worldPoint(z: z, y: y, x: x),
                        value: value,
                        fixedInMask: mask.includes(value, range: fixed.intensityRange)
                    ))
                }
            }
        }
        return samples
    }

    private static func maskWorldSamples(for moving: ImageVolume) -> [SIMD3<Double>] {
        let modality = Modality.normalize(moving.modality)
        let mask = maskKind(for: modality)
        let step = max(1, Int(ceil(pow(Double(max(1, moving.width * moving.height * moving.depth)) / 12_000.0, 1.0 / 3.0))))
        var samples: [SIMD3<Double>] = []
        samples.reserveCapacity(16_000)
        for z in Swift.stride(from: 0, to: moving.depth, by: step) {
            for y in Swift.stride(from: 0, to: moving.height, by: step) {
                for x in Swift.stride(from: 0, to: moving.width, by: step) {
                    let value = moving.intensity(z: z, y: y, x: x)
                    guard mask.includes(value, range: moving.intensityRange) else { continue }
                    samples.append(moving.worldPoint(z: z, y: y, x: x))
                }
            }
        }
        return samples
    }

    private static func fixedSamples(for fixed: ImageVolume) -> [(world: SIMD3<Double>, value: Float)] {
        let modality = Modality.normalize(fixed.modality)
        let mask = maskKind(for: modality)
        let step = max(1, Int(ceil(pow(Double(max(1, fixed.width * fixed.height * fixed.depth)) / 10_000.0, 1.0 / 3.0))))
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

    private static func centerShift(moving: ImageVolume,
                                    transform: Transform3D) -> Double {
        let center = geometryCenter(moving)
        return simd_length(transform.apply(to: center) - center)
    }

    private static func degrees(_ values: [Double]) -> [Double] {
        values.map { $0 * .pi / 180.0 }
    }

    private static func offsets(around value: Double, degrees values: [Double]) -> [Double] {
        values.map { value + $0 * .pi / 180.0 }
    }

    private static func radiansToDegrees(_ radians: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(
            radians.x * 180.0 / .pi,
            radians.y * 180.0 / .pi,
            radians.z * 180.0 / .pi
        )
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        max(lower, min(upper, value))
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

private struct RegistrationSample {
    let world: SIMD3<Double>
    let value: Float
    let fixedInMask: Bool
}

private struct SimilarityCandidate {
    let transform: Transform3D
    let rotation: SIMD3<Double>
    let scale: Double
    let score: Double
}

private struct SimilaritySearchResult {
    let transform: Transform3D
    let rotationDegrees: SIMD3<Double>
    let scale: Double
    let score: Double?
    let didImprove: Bool
}

private struct SegmentationPolishCandidate {
    let transform: Transform3D
    let translationMM: SIMD3<Double>
    let rotationRadians: SIMD3<Double>
    let score: Double
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
