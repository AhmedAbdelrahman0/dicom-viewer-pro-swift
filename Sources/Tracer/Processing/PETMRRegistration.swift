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
        case .rigidAnatomical: return "Rigid anatomy"
        case .rigidThenDeformable: return "Rigid + body warp"
        }
    }

    public var helpText: String {
        switch self {
        case .geometry:
            return "Use scanner/world geometry only. Best for simultaneous PET/MR or already registered images."
        case .rigidAnatomical:
            return "Initialize PET→MR fusion by matching robust body/anatomy centroids before resampling."
        case .rigidThenDeformable:
            return "Apply rigid anatomy alignment plus a conservative body-envelope affine warp for non-simultaneous PET/MR."
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
            return result(transform: rigid.transform,
                          anchor: rigid.anchorDescription,
                          displacementMM: rigid.displacementMM,
                          notePrefix: "PET/MR rigid anatomical initialization")

        case .rigidThenDeformable:
            let rigid = rigidByAnatomicalAnchor(moving: pet, fixed: mr)
            let bodyFit = bodyEnvelopeAffine(moving: pet, fixed: mr) ?? rigid.transform
            let combined = bodyFit
            return result(transform: combined,
                          anchor: rigid.anchorDescription,
                          displacementMM: rigid.displacementMM,
                          notePrefix: "PET/MR rigid + body-envelope warp")
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
                                           fixed: ImageVolume) -> Transform3D? {
        guard let movingBox = bodyBoundingBox(for: moving),
              let fixedBox = bodyBoundingBox(for: fixed) else {
            return nil
        }

        func safeScale(_ fixedExtent: Double, _ movingExtent: Double) -> Double {
            guard fixedExtent.isFinite, movingExtent.isFinite, movingExtent > 1 else { return 1 }
            return max(0.75, min(1.35, fixedExtent / movingExtent))
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
        return Transform3D(matrix: matrix)
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

    private static func bodyBoundingBox(for volume: ImageVolume) -> (min: SIMD3<Double>, max: SIMD3<Double>, center: SIMD3<Double>, extent: SIMD3<Double>)? {
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
