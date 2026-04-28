import Foundation
import simd

public enum ImageVolumeGeometry {
    public static func gridsMatch(_ lhs: ImageVolume,
                                  _ rhs: ImageVolume,
                                  tolerance: Double = 1e-4) -> Bool {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.depth == rhs.depth else {
            return false
        }

        guard abs(lhs.spacing.x - rhs.spacing.x) < tolerance,
              abs(lhs.spacing.y - rhs.spacing.y) < tolerance,
              abs(lhs.spacing.z - rhs.spacing.z) < tolerance,
              abs(lhs.origin.x - rhs.origin.x) < tolerance,
              abs(lhs.origin.y - rhs.origin.y) < tolerance,
              abs(lhs.origin.z - rhs.origin.z) < tolerance else {
            return false
        }

        for column in 0..<3 {
            for row in 0..<3 where abs(lhs.direction[column][row] - rhs.direction[column][row]) >= tolerance {
                return false
            }
        }
        return true
    }

    public static func mismatchSummary(_ lhs: ImageVolume,
                                       _ rhs: ImageVolume,
                                       tolerance: Double = 1e-4) -> [String] {
        var warnings: [String] = []
        if lhs.width != rhs.width || lhs.height != rhs.height || lhs.depth != rhs.depth {
            warnings.append("grid size differs: fixed \(lhs.width)x\(lhs.height)x\(lhs.depth), moving \(rhs.width)x\(rhs.height)x\(rhs.depth)")
        }
        if abs(lhs.spacing.x - rhs.spacing.x) >= tolerance ||
            abs(lhs.spacing.y - rhs.spacing.y) >= tolerance ||
            abs(lhs.spacing.z - rhs.spacing.z) >= tolerance {
            warnings.append(String(format: "spacing differs: fixed %.3f/%.3f/%.3f mm, moving %.3f/%.3f/%.3f mm",
                                   lhs.spacing.x, lhs.spacing.y, lhs.spacing.z,
                                   rhs.spacing.x, rhs.spacing.y, rhs.spacing.z))
        }
        if abs(lhs.origin.x - rhs.origin.x) >= tolerance ||
            abs(lhs.origin.y - rhs.origin.y) >= tolerance ||
            abs(lhs.origin.z - rhs.origin.z) >= tolerance {
            warnings.append(String(format: "origin differs: fixed %.2f/%.2f/%.2f, moving %.2f/%.2f/%.2f",
                                   lhs.origin.x, lhs.origin.y, lhs.origin.z,
                                   rhs.origin.x, rhs.origin.y, rhs.origin.z))
        }
        var directionMismatch = false
        for column in 0..<3 {
            for row in 0..<3 where abs(lhs.direction[column][row] - rhs.direction[column][row]) >= tolerance {
                directionMismatch = true
            }
        }
        if directionMismatch {
            warnings.append("direction cosines differ")
        }
        return warnings
    }
}

public enum RegistrationQualityGrade: String, Codable, Equatable, Sendable {
    case pass
    case caution
    case fail
    case unknown

    public var displayName: String {
        switch self {
        case .pass: return "Pass"
        case .caution: return "Review"
        case .fail: return "Fail"
        case .unknown: return "Unknown"
        }
    }
}

public struct DeformationFieldQuality: Codable, Equatable, Sendable {
    public var jacobianMin: Double?
    public var jacobianMax: Double?
    public var foldingPercent: Double?
    public var inverseConsistencyRMSEMM: Double?
    public var landmarkTREMM: Double?
    public var notes: [String]

    public init(jacobianMin: Double? = nil,
                jacobianMax: Double? = nil,
                foldingPercent: Double? = nil,
                inverseConsistencyRMSEMM: Double? = nil,
                landmarkTREMM: Double? = nil,
                notes: [String] = []) {
        self.jacobianMin = jacobianMin
        self.jacobianMax = jacobianMax
        self.foldingPercent = foldingPercent
        self.inverseConsistencyRMSEMM = inverseConsistencyRMSEMM
        self.landmarkTREMM = landmarkTREMM
        self.notes = notes
    }

    public var grade: RegistrationQualityGrade {
        if let foldingPercent, foldingPercent > 1.0 { return .fail }
        if let jacobianMin, jacobianMin <= 0 { return .fail }
        if let inverseConsistencyRMSEMM, inverseConsistencyRMSEMM > 20 { return .fail }
        if let landmarkTREMM, landmarkTREMM > 20 { return .fail }
        if let foldingPercent, foldingPercent > 0.05 { return .caution }
        if let jacobianMin, jacobianMin < 0.15 { return .caution }
        if let jacobianMax, jacobianMax > 6 { return .caution }
        if let inverseConsistencyRMSEMM, inverseConsistencyRMSEMM > 8 { return .caution }
        if let landmarkTREMM, landmarkTREMM > 8 { return .caution }
        if jacobianMin == nil && jacobianMax == nil && foldingPercent == nil &&
            inverseConsistencyRMSEMM == nil && landmarkTREMM == nil {
            return .unknown
        }
        return .pass
    }

    public var warnings: [String] {
        var result = notes
        if let foldingPercent, foldingPercent > 0.05 {
            result.append(String(format: "folding %.2f%%", foldingPercent))
        }
        if let jacobianMin, jacobianMin <= 0 {
            result.append(String(format: "non-positive Jacobian min %.3f", jacobianMin))
        } else if let jacobianMin, jacobianMin < 0.15 {
            result.append(String(format: "low Jacobian min %.3f", jacobianMin))
        }
        if let jacobianMax, jacobianMax > 6 {
            result.append(String(format: "high Jacobian max %.2f", jacobianMax))
        }
        if let inverseConsistencyRMSEMM, inverseConsistencyRMSEMM > 8 {
            result.append(String(format: "inverse consistency %.1f mm", inverseConsistencyRMSEMM))
        }
        if let landmarkTREMM, landmarkTREMM > 8 {
            result.append(String(format: "landmark TRE %.1f mm", landmarkTREMM))
        }
        return result
    }
}

public struct RegistrationQualitySnapshot: Equatable, Sendable {
    public let label: String
    public let grade: RegistrationQualityGrade
    public let normalizedMutualInformation: Double?
    public let pearsonCorrelation: Double?
    public let edgeAlignment: Double?
    public let maskDice: Double?
    public let centroidResidualMM: Double?
    public let fixedMaskFraction: Double
    public let movingMaskFraction: Double
    public let sampleCount: Int
    public let warnings: [String]

    public init(label: String,
                grade: RegistrationQualityGrade,
                normalizedMutualInformation: Double?,
                pearsonCorrelation: Double?,
                edgeAlignment: Double? = nil,
                maskDice: Double?,
                centroidResidualMM: Double?,
                fixedMaskFraction: Double,
                movingMaskFraction: Double,
                sampleCount: Int,
                warnings: [String]) {
        self.label = label
        self.grade = grade
        self.normalizedMutualInformation = normalizedMutualInformation
        self.pearsonCorrelation = pearsonCorrelation
        self.edgeAlignment = edgeAlignment
        self.maskDice = maskDice
        self.centroidResidualMM = centroidResidualMM
        self.fixedMaskFraction = fixedMaskFraction
        self.movingMaskFraction = movingMaskFraction
        self.sampleCount = sampleCount
        self.warnings = warnings
    }
}

public struct RegistrationQualityComparison: Equatable, Sendable {
    public let before: RegistrationQualitySnapshot
    public let after: RegistrationQualitySnapshot
    public let deformation: DeformationFieldQuality?
    public let warnings: [String]
    public let grade: RegistrationQualityGrade

    public var nmiDelta: Double? {
        guard let before = before.normalizedMutualInformation,
              let after = after.normalizedMutualInformation else {
            return nil
        }
        return after - before
    }

    public var diceDelta: Double? {
        guard let before = before.maskDice,
              let after = after.maskDice else {
            return nil
        }
        return after - before
    }

    public var centroidImprovementMM: Double? {
        guard let before = before.centroidResidualMM,
              let after = after.centroidResidualMM else {
            return nil
        }
        return before - after
    }

    public var summary: String {
        var parts: [String] = []
        if let nmi = after.normalizedMutualInformation {
            parts.append(String(format: "NMI %.3f", nmi))
        }
        if let dice = after.maskDice {
            parts.append(String(format: "overlap %.2f", dice))
        }
        if let residual = after.centroidResidualMM {
            parts.append(String(format: "centroid %.1f mm", residual))
        }
        if let edge = after.edgeAlignment {
            parts.append(String(format: "edge %.2f", edge))
        }
        if parts.isEmpty {
            parts.append("QA needs richer image signal")
        }
        return parts.joined(separator: " · ")
    }
}

public enum RegistrationQualityAssurance {
    public static func evaluate(fixed: ImageVolume,
                                movingOnFixedGrid: ImageVolume,
                                label: String) -> RegistrationQualitySnapshot {
        guard ImageVolumeGeometry.gridsMatch(fixed, movingOnFixedGrid) else {
            return RegistrationQualitySnapshot(
                label: label,
                grade: .fail,
                normalizedMutualInformation: nil,
                pearsonCorrelation: nil,
                maskDice: nil,
                centroidResidualMM: nil,
                fixedMaskFraction: 0,
                movingMaskFraction: 0,
                sampleCount: 0,
                warnings: ImageVolumeGeometry.mismatchSummary(fixed, movingOnFixedGrid)
            )
        }

        let fixedMask = maskKind(for: Modality.normalize(fixed.modality))
        let movingMask = maskKind(for: Modality.normalize(movingOnFixedGrid.modality))
        let fixedRange = fixed.intensityRange
        let movingRange = movingOnFixedGrid.intensityRange
        let step = samplingStride(for: fixed)
        let bins = 64
        var joint = [Int](repeating: 0, count: bins * bins)
        var fixedHist = [Int](repeating: 0, count: bins)
        var movingHist = [Int](repeating: 0, count: bins)

        var count = 0
        var sumFixed = 0.0
        var sumMoving = 0.0
        var sumFixed2 = 0.0
        var sumMoving2 = 0.0
        var sumProduct = 0.0

        var fixedMaskCount = 0
        var movingMaskCount = 0
        var intersection = 0
        var fixedCentroid = SIMD3<Double>(0, 0, 0)
        var movingCentroid = SIMD3<Double>(0, 0, 0)
        var edgeCount = 0
        var sumFixedEdge2 = 0.0
        var sumMovingEdge2 = 0.0
        var sumEdgeProduct = 0.0

        let width = fixed.width
        let height = fixed.height
        for z in Swift.stride(from: 0, to: fixed.depth, by: step) {
            for y in Swift.stride(from: 0, to: fixed.height, by: step) {
                let rowStart = z * height * width + y * width
                for x in Swift.stride(from: 0, to: fixed.width, by: step) {
                    let index = rowStart + x
                    let fixedValue = fixed.pixels[index]
                    let movingValue = movingOnFixedGrid.pixels[index]
                    guard fixedValue.isFinite, movingValue.isFinite else { continue }

                    count += 1
                    let f = Double(fixedValue)
                    let m = Double(movingValue)
                    sumFixed += f
                    sumMoving += m
                    sumFixed2 += f * f
                    sumMoving2 += m * m
                    sumProduct += f * m

                    if let fBin = bin(value: fixedValue, range: fixedRange, bins: bins),
                       let mBin = bin(value: movingValue, range: movingRange, bins: bins) {
                        fixedHist[fBin] += 1
                        movingHist[mBin] += 1
                        joint[fBin * bins + mBin] += 1
                    }

                    let fixedInside = fixedMask.includes(fixedValue, range: fixedRange)
                    let movingInside = movingMask.includes(movingValue, range: movingRange)
                    if fixedInside {
                        fixedMaskCount += 1
                        fixedCentroid += fixed.worldPoint(z: z, y: y, x: x)
                    }
                    if movingInside {
                        movingMaskCount += 1
                        movingCentroid += fixed.worldPoint(z: z, y: y, x: x)
                    }
                    if fixedInside && movingInside {
                        intersection += 1
                    }

                    if fixedInside || movingInside,
                       let fixedEdge = gradientMagnitude(fixed, x: x, y: y, z: z),
                       let movingEdge = gradientMagnitude(movingOnFixedGrid, x: x, y: y, z: z) {
                        let f = log1p(fixedEdge)
                        let m = log1p(movingEdge)
                        sumFixedEdge2 += f * f
                        sumMovingEdge2 += m * m
                        sumEdgeProduct += f * m
                        edgeCount += 1
                    }
                }
            }
        }

        let nmi = normalizedMutualInformation(fixedHist: fixedHist, movingHist: movingHist, joint: joint, sampleCount: count)
        let pearson = pearsonCorrelation(count: count,
                                         sumFixed: sumFixed,
                                         sumMoving: sumMoving,
                                         sumFixed2: sumFixed2,
                                         sumMoving2: sumMoving2,
                                         sumProduct: sumProduct)
        let maskDice: Double?
        if fixedMaskCount + movingMaskCount > 0 {
            maskDice = 2.0 * Double(intersection) / Double(fixedMaskCount + movingMaskCount)
        } else {
            maskDice = nil
        }
        let edgeAlignment: Double?
        if edgeCount >= 32,
           sumFixedEdge2 > 1e-8,
           sumMovingEdge2 > 1e-8 {
            edgeAlignment = (sumEdgeProduct / sqrt(sumFixedEdge2 * sumMovingEdge2)).clamped(to: 0...1)
        } else {
            edgeAlignment = nil
        }

        let centroidResidual: Double?
        if fixedMaskCount >= 8, movingMaskCount >= 8 {
            let fixedCenter = fixedCentroid / Double(fixedMaskCount)
            let movingCenter = movingCentroid / Double(movingMaskCount)
            centroidResidual = simd_length(fixedCenter - movingCenter)
        } else {
            centroidResidual = nil
        }

        let fixedFraction = count > 0 ? Double(fixedMaskCount) / Double(count) : 0
        let movingFraction = count > 0 ? Double(movingMaskCount) / Double(count) : 0
        var warnings: [String] = []
        var grade: RegistrationQualityGrade = .pass

        if count < 256 {
            warnings.append("too few finite samples for reliable QA")
            grade = .caution
        }
        if movingMaskCount < 8 {
            warnings.append("moving PET/MR envelope is very sparse")
            grade = .caution
        }
        if let centroidResidual, centroidResidual > 120 {
            warnings.append(String(format: "large centroid residual %.1f mm", centroidResidual))
            grade = .fail
        } else if let centroidResidual, centroidResidual > 50 {
            warnings.append(String(format: "centroid residual %.1f mm needs review", centroidResidual))
            grade = maxGrade(grade, .caution)
        }
        if let maskDice, maskDice < 0.01, fixedMaskCount >= 8, movingMaskCount >= 8 {
            warnings.append("fixed and moving envelopes barely overlap")
            grade = maxGrade(grade, .caution)
        }
        if nmi == nil {
            warnings.append("NMI unavailable because one image is nearly constant")
            grade = maxGrade(grade, .caution)
        }
        if let edgeAlignment,
           edgeAlignment < 0.04,
           Modality.normalize(fixed.modality) == .MR,
           Modality.normalize(movingOnFixedGrid.modality) == .PT {
            warnings.append(String(format: "weak local edge agreement %.2f", edgeAlignment))
            grade = maxGrade(grade, .caution)
        }

        return RegistrationQualitySnapshot(
            label: label,
            grade: grade,
            normalizedMutualInformation: nmi,
            pearsonCorrelation: pearson,
            edgeAlignment: edgeAlignment,
            maskDice: maskDice,
            centroidResidualMM: centroidResidual,
            fixedMaskFraction: fixedFraction,
            movingMaskFraction: movingFraction,
            sampleCount: count,
            warnings: warnings
        )
    }

    public static func compare(before: RegistrationQualitySnapshot,
                               after: RegistrationQualitySnapshot,
                               deformation: DeformationFieldQuality? = nil,
                               allowBrainPETMRFitInside: Bool = false) -> RegistrationQualityComparison {
        var warnings = after.warnings
        var grade = after.grade

        if let beforeNMI = before.normalizedMutualInformation,
           let afterNMI = after.normalizedMutualInformation,
           afterNMI + 0.04 < beforeNMI {
            warnings.append(String(format: "NMI worsened from %.3f to %.3f", beforeNMI, afterNMI))
            grade = maxGrade(grade, .caution)
        }
        if let beforeDice = before.maskDice,
           let afterDice = after.maskDice,
           afterDice + 0.03 < beforeDice {
            let nmiStableOrImproved = (after.normalizedMutualInformation ?? -.infinity) + 0.01 >= (before.normalizedMutualInformation ?? .infinity)
            let centroidAcceptable = (after.centroidResidualMM ?? .infinity) <= 25
            let substantialOverlap = afterDice >= 0.50
            if !(allowBrainPETMRFitInside && nmiStableOrImproved && centroidAcceptable && substantialOverlap) {
                warnings.append(String(format: "envelope overlap worsened from %.2f to %.2f", beforeDice, afterDice))
                grade = maxGrade(grade, .caution)
            }
        }
        if let beforeResidual = before.centroidResidualMM,
           let afterResidual = after.centroidResidualMM,
           afterResidual > beforeResidual + 15 {
            warnings.append(String(format: "centroid residual worsened by %.1f mm", afterResidual - beforeResidual))
            grade = maxGrade(grade, .caution)
        }
        if let beforeEdge = before.edgeAlignment,
           let afterEdge = after.edgeAlignment,
           beforeEdge > 0.08,
           afterEdge + 0.04 < beforeEdge {
            warnings.append(String(format: "edge agreement worsened from %.2f to %.2f", beforeEdge, afterEdge))
            grade = maxGrade(grade, .caution)
        }
        if let deformation {
            warnings += deformation.warnings
            grade = maxGrade(grade, deformation.grade)
        }

        return RegistrationQualityComparison(
            before: before,
            after: after,
            deformation: deformation,
            warnings: unique(warnings),
            grade: grade
        )
    }

    public static func loadDeformationQualitySidecar(from url: URL) -> DeformationFieldQuality? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DeformationFieldQuality.self, from: data)
    }

    private static func samplingStride(for volume: ImageVolume) -> Int {
        let voxels = max(1, volume.width * volume.height * volume.depth)
        return max(1, Int(pow(Double(voxels) / 180_000.0, 1.0 / 3.0).rounded()))
    }

    private static func bin(value: Float, range: (min: Float, max: Float), bins: Int) -> Int? {
        let span = range.max - range.min
        guard span.isFinite, span > 1e-8 else { return nil }
        let normalized = (Double(value - range.min) / Double(span)).clamped(to: 0...0.999_999)
        return Int(normalized * Double(bins))
    }

    private static func normalizedMutualInformation(fixedHist: [Int],
                                                    movingHist: [Int],
                                                    joint: [Int],
                                                    sampleCount: Int) -> Double? {
        guard sampleCount > 0 else { return nil }
        let hx = entropy(fixedHist, sampleCount: sampleCount)
        let hy = entropy(movingHist, sampleCount: sampleCount)
        let hxy = entropy(joint, sampleCount: sampleCount)
        guard hxy > 1e-8, hx > 1e-8, hy > 1e-8 else { return nil }
        return (hx + hy) / hxy
    }

    private static func entropy(_ histogram: [Int], sampleCount: Int) -> Double {
        guard sampleCount > 0 else { return 0 }
        let total = Double(sampleCount)
        var result = 0.0
        for count in histogram where count > 0 {
            let p = Double(count) / total
            result -= p * log(p)
        }
        return result
    }

    private static func pearsonCorrelation(count: Int,
                                           sumFixed: Double,
                                           sumMoving: Double,
                                           sumFixed2: Double,
                                           sumMoving2: Double,
                                           sumProduct: Double) -> Double? {
        guard count > 2 else { return nil }
        let n = Double(count)
        let covariance = sumProduct - (sumFixed * sumMoving / n)
        let fixedVariance = sumFixed2 - (sumFixed * sumFixed / n)
        let movingVariance = sumMoving2 - (sumMoving * sumMoving / n)
        let denom = sqrt(max(0, fixedVariance) * max(0, movingVariance))
        guard denom > 1e-8 else { return nil }
        return (covariance / denom).clamped(to: -1...1)
    }

    private static func gradientMagnitude(_ volume: ImageVolume,
                                          x: Int,
                                          y: Int,
                                          z: Int) -> Double? {
        guard x > 0, x < volume.width - 1,
              y > 0, y < volume.height - 1,
              z > 0, z < volume.depth - 1 else {
            return nil
        }
        let dx = Double(volume.intensity(z: z, y: y, x: x + 1) -
                        volume.intensity(z: z, y: y, x: x - 1)) / max(0.001, 2 * volume.spacing.x)
        let dy = Double(volume.intensity(z: z, y: y + 1, x: x) -
                        volume.intensity(z: z, y: y - 1, x: x)) / max(0.001, 2 * volume.spacing.y)
        let dz = Double(volume.intensity(z: z + 1, y: y, x: x) -
                        volume.intensity(z: z - 1, y: y, x: x)) / max(0.001, 2 * volume.spacing.z)
        let magnitude = sqrt(dx * dx + dy * dy + dz * dz)
        return magnitude.isFinite ? magnitude : nil
    }

    private static func maskKind(for modality: Modality) -> RegistrationQAMask {
        switch modality {
        case .CT: return .ctBody
        case .PT: return .petUptakeEnvelope
        case .MR: return .mrBody
        default: return .nonZeroBody
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}

private enum RegistrationQAMask {
    case ctBody
    case petUptakeEnvelope
    case mrBody
    case nonZeroBody

    func includes(_ value: Float, range: (min: Float, max: Float)) -> Bool {
        guard value.isFinite else { return false }
        let span = max(1, range.max - range.min)
        switch self {
        case .ctBody:
            return value > -500 && value < 3000
        case .petUptakeEnvelope:
            return value > max(0, range.min + span * 0.06)
        case .mrBody:
            return value > range.min + span * 0.08
        case .nonZeroBody:
            return abs(value) > 0.0001
        }
    }
}

private func maxGrade(_ lhs: RegistrationQualityGrade,
                      _ rhs: RegistrationQualityGrade) -> RegistrationQualityGrade {
    severity(lhs) >= severity(rhs) ? lhs : rhs
}

private func severity(_ grade: RegistrationQualityGrade) -> Int {
    switch grade {
    case .pass: return 0
    case .unknown: return 1
    case .caution: return 2
    case .fail: return 3
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
