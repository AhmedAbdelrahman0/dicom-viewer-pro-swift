import Foundation
import simd

public enum Lu177DosimetryError: Error, LocalizedError, Equatable {
    case invalidInput(String)
    case gridMismatch(String)
    case missingCalibration(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message),
             .gridMismatch(let message),
             .missingCalibration(let message):
            return message
        }
    }
}

public enum Lu177ActivityInputUnit: String, CaseIterable, Sendable {
    case activityConcentrationBqPerML
    case counts

    public var displayName: String {
        switch self {
        case .activityConcentrationBqPerML: return "Activity concentration (Bq/mL)"
        case .counts: return "SPECT counts"
        }
    }
}

public enum Lu177TailModel: String, CaseIterable, Sendable {
    case physicalHalfLife
    case monoExponentialFitWithPhysicalFallback
    case noTail

    public var displayName: String {
        switch self {
        case .physicalHalfLife: return "Physical half-life tail"
        case .monoExponentialFitWithPhysicalFallback: return "Mono-exponential tail"
        case .noTail: return "Measured interval only"
        }
    }
}

public struct Lu177SPECTCalibration: Equatable, Sendable {
    public let bqPerMLPerCount: Double
    public let backgroundCounts: Double

    public init(bqPerMLPerCount: Double, backgroundCounts: Double = 0) throws {
        guard bqPerMLPerCount > 0, bqPerMLPerCount.isFinite else {
            throw Lu177DosimetryError.invalidInput("SPECT calibration factor must be a positive finite Bq/mL per count value.")
        }
        guard backgroundCounts >= 0, backgroundCounts.isFinite else {
            throw Lu177DosimetryError.invalidInput("Background counts must be a non-negative finite value.")
        }
        self.bqPerMLPerCount = bqPerMLPerCount
        self.backgroundCounts = backgroundCounts
    }

    public func activityConcentration(counts: Float) -> Float {
        let corrected = max(0, Double(counts) - backgroundCounts)
        return Float(corrected * bqPerMLPerCount)
    }
}

public struct Lu177DosimetryTimePoint: Identifiable, Sendable {
    public let id: UUID
    public let activityVolume: ImageVolume
    public let hoursPostAdministration: Double
    public let inputUnit: Lu177ActivityInputUnit
    public let calibration: Lu177SPECTCalibration?

    public init(id: UUID = UUID(),
                activityVolume: ImageVolume,
                hoursPostAdministration: Double,
                inputUnit: Lu177ActivityInputUnit = .activityConcentrationBqPerML,
                calibration: Lu177SPECTCalibration? = nil) throws {
        guard hoursPostAdministration >= 0, hoursPostAdministration.isFinite else {
            throw Lu177DosimetryError.invalidInput("Imaging time must be a non-negative finite number of hours after administration.")
        }
        guard !activityVolume.pixels.isEmpty else {
            throw Lu177DosimetryError.invalidInput("Lu-177 dosimetry requires non-empty SPECT activity volumes.")
        }
        if inputUnit == .counts, calibration == nil {
            throw Lu177DosimetryError.missingCalibration("Count-based SPECT input requires a calibration factor before dose can be computed.")
        }

        self.id = id
        self.activityVolume = activityVolume
        self.hoursPostAdministration = hoursPostAdministration
        self.inputUnit = inputUnit
        self.calibration = calibration
    }

    public func activityConcentrationPixels() throws -> [Float] {
        switch inputUnit {
        case .activityConcentrationBqPerML:
            guard activityVolume.pixels.allSatisfy(\.isFinite) else {
                throw Lu177DosimetryError.invalidInput("Activity concentration volume contains NaN or infinite values.")
            }
            return activityVolume.pixels.map { max(0, $0) }
        case .counts:
            guard let calibration else {
                throw Lu177DosimetryError.missingCalibration("Count-based SPECT input requires a calibration factor before dose can be computed.")
            }
            return activityVolume.pixels.map { calibration.activityConcentration(counts: $0) }
        }
    }
}

public struct CTDensityCalibration: Equatable, Sendable {
    public let minimumDensityGPerML: Float
    public let maximumDensityGPerML: Float

    public init(minimumDensityGPerML: Float = 0.001,
                maximumDensityGPerML: Float = 3.0) throws {
        guard minimumDensityGPerML > 0,
              maximumDensityGPerML > minimumDensityGPerML,
              minimumDensityGPerML.isFinite,
              maximumDensityGPerML.isFinite else {
            throw Lu177DosimetryError.invalidInput("CT density calibration limits must be finite and positive.")
        }
        self.minimumDensityGPerML = minimumDensityGPerML
        self.maximumDensityGPerML = maximumDensityGPerML
    }

    public static var standard: CTDensityCalibration {
        try! CTDensityCalibration()
    }

    /// Conservative HU-to-density ramp for absorbed-dose mass correction.
    /// A site-specific bilinear calibration should replace this for clinical use.
    public func densityGPerML(hu: Float) -> Float {
        let density: Float
        if hu <= -1_000 {
            density = minimumDensityGPerML
        } else if hu < 0 {
            density = 1 + hu / 1_000
        } else {
            density = 1 + hu / 1_000
        }
        return min(max(density, minimumDensityGPerML), maximumDensityGPerML)
    }
}

public struct Lu177DoseModel: Equatable, Sendable {
    public let name: String
    public let meanEnergyMeVPerDecay: Double
    public let nonLocalContributionFraction: Double

    public init(name: String = "Lu-177 local deposition",
                meanEnergyMeVPerDecay: Double = 0.1479,
                nonLocalContributionFraction: Double = 0) throws {
        guard meanEnergyMeVPerDecay > 0, meanEnergyMeVPerDecay.isFinite else {
            throw Lu177DosimetryError.invalidInput("Mean emitted energy must be a positive finite MeV/decay value.")
        }
        guard nonLocalContributionFraction >= 0, nonLocalContributionFraction.isFinite else {
            throw Lu177DosimetryError.invalidInput("Non-local dose contribution fraction must be non-negative and finite.")
        }
        self.name = name
        self.meanEnergyMeVPerDecay = meanEnergyMeVPerDecay
        self.nonLocalContributionFraction = nonLocalContributionFraction
    }

    public static var lu177LocalDeposition: Lu177DoseModel {
        try! Lu177DoseModel()
    }

    public var joulesPerDecay: Double {
        meanEnergyMeVPerDecay * 1.602176634e-13 * (1 + nonLocalContributionFraction)
    }
}

public struct Lu177DosimetryOptions: Equatable, Sendable {
    public let physicalHalfLifeHours: Double
    public let tailModel: Lu177TailModel
    public let doseModel: Lu177DoseModel
    public let densityCalibration: CTDensityCalibration
    public let outputSeriesDescription: String

    public init(physicalHalfLifeHours: Double = 159.53,
                tailModel: Lu177TailModel = .monoExponentialFitWithPhysicalFallback,
                doseModel: Lu177DoseModel = .lu177LocalDeposition,
                densityCalibration: CTDensityCalibration = .standard,
                outputSeriesDescription: String = "Lu-177 absorbed dose map") throws {
        guard physicalHalfLifeHours > 0, physicalHalfLifeHours.isFinite else {
            throw Lu177DosimetryError.invalidInput("Lu-177 physical half-life must be a positive finite number of hours.")
        }
        self.physicalHalfLifeHours = physicalHalfLifeHours
        self.tailModel = tailModel
        self.doseModel = doseModel
        self.densityCalibration = densityCalibration
        self.outputSeriesDescription = outputSeriesDescription
    }

    public static var standard: Lu177DosimetryOptions {
        try! Lu177DosimetryOptions()
    }

    public var physicalDecayConstantPerHour: Double {
        log(2) / physicalHalfLifeHours
    }
}

public struct Lu177VOIDoseSummary: Identifiable, Equatable, Sendable {
    public let id: UInt16
    public let classID: UInt16
    public let className: String
    public let voxelCount: Int
    public let volumeML: Double
    public let meanDoseGy: Double
    public let minDoseGy: Double
    public let maxDoseGy: Double
    public let timeIntegratedActivityBqHours: Double
}

public struct Lu177DosimetryReport: Equatable, Sendable {
    public let sourceVolumeIdentity: String
    public let timePointHours: [Double]
    public let tailModel: Lu177TailModel
    public let doseModelName: String
    public let minDoseGy: Double
    public let meanDoseGy: Double
    public let maxDoseGy: Double
    public let totalTimeIntegratedActivityBqHours: Double
    public let voiSummaries: [Lu177VOIDoseSummary]
    public let warnings: [String]
}

public struct Lu177DosimetryResult: Sendable {
    public let absorbedDoseMapGy: ImageVolume
    public let timeIntegratedActivityMapBqHoursPerML: ImageVolume
    public let densityMapGPerML: ImageVolume?
    public let report: Lu177DosimetryReport
}

public enum Lu177DosimetryEngine {
    public static func createAbsorbedDoseMap(timePoints: [Lu177DosimetryTimePoint],
                                             ctVolume: ImageVolume? = nil,
                                             labelMap: LabelMap? = nil,
                                             options: Lu177DosimetryOptions = .standard) throws -> Lu177DosimetryResult {
        let sorted = try validateAndSort(timePoints)
        let reference = sorted[0].activityVolume
        for point in sorted.dropFirst() {
            try validateSameGrid(reference, point.activityVolume, role: "SPECT time point")
        }
        if let ctVolume {
            try validateSameGrid(reference, ctVolume, role: "CT density map")
        }
        if let labelMap {
            try validateLabelGrid(reference, labelMap)
        }

        let activities = try sorted.map { try $0.activityConcentrationPixels() }
        let times = sorted.map(\.hoursPostAdministration)
        let tiaPixels = integrateActivityConcentration(
            activities: activities,
            timesHours: times,
            options: options
        )
        let densityPixels = ctVolume.map {
            $0.pixels.map { options.densityCalibration.densityGPerML(hu: $0) }
        } ?? [Float](repeating: 1, count: reference.pixels.count)
        let dosePixels = absorbedDosePixels(
            timeIntegratedActivityBqHoursPerML: tiaPixels,
            densityGPerML: densityPixels,
            doseModel: options.doseModel
        )

        let doseVolume = ImageVolume(
            pixels: dosePixels,
            depth: reference.depth,
            height: reference.height,
            width: reference.width,
            spacing: reference.spacing,
            origin: reference.origin,
            direction: reference.direction,
            modality: "DOSE",
            studyUID: reference.studyUID,
            patientID: reference.patientID,
            patientName: reference.patientName,
            seriesDescription: options.outputSeriesDescription,
            studyDescription: reference.studyDescription,
            sourceFiles: reference.sourceFiles
        )
        let tiaVolume = ImageVolume(
            pixels: tiaPixels,
            depth: reference.depth,
            height: reference.height,
            width: reference.width,
            spacing: reference.spacing,
            origin: reference.origin,
            direction: reference.direction,
            modality: "NM",
            studyUID: reference.studyUID,
            patientID: reference.patientID,
            patientName: reference.patientName,
            seriesDescription: "Lu-177 time-integrated activity",
            studyDescription: reference.studyDescription,
            sourceFiles: reference.sourceFiles
        )
        let densityVolume = ctVolume.map { ct in
            ImageVolume(
                pixels: densityPixels,
                depth: ct.depth,
                height: ct.height,
                width: ct.width,
                spacing: ct.spacing,
                origin: ct.origin,
                direction: ct.direction,
                modality: "DENSITY",
                studyUID: ct.studyUID,
                patientID: ct.patientID,
                patientName: ct.patientName,
                seriesDescription: "CT-derived density map",
                studyDescription: ct.studyDescription,
                sourceFiles: ct.sourceFiles
            )
        }

        let warnings = warningsForWorkflow(
            timePoints: sorted,
            hasCT: ctVolume != nil,
            options: options
        )
        let report = Lu177DosimetryReport(
            sourceVolumeIdentity: reference.sessionIdentity,
            timePointHours: times,
            tailModel: options.tailModel,
            doseModelName: options.doseModel.name,
            minDoseGy: Double(dosePixels.min() ?? 0),
            meanDoseGy: mean(dosePixels),
            maxDoseGy: Double(dosePixels.max() ?? 0),
            totalTimeIntegratedActivityBqHours: totalTimeIntegratedActivity(
                tiaPixels,
                reference: reference
            ),
            voiSummaries: labelMap.map {
                computeVOISummaries(
                    dosePixels: dosePixels,
                    tiaPixels: tiaPixels,
                    labelMap: $0,
                    reference: reference
                )
            } ?? [],
            warnings: warnings
        )

        return Lu177DosimetryResult(
            absorbedDoseMapGy: doseVolume,
            timeIntegratedActivityMapBqHoursPerML: tiaVolume,
            densityMapGPerML: densityVolume,
            report: report
        )
    }

    public static func integrateActivityConcentration(activities: [[Float]],
                                                      timesHours: [Double],
                                                      options: Lu177DosimetryOptions = .standard) -> [Float] {
        guard let first = activities.first,
              activities.count == timesHours.count,
              activities.allSatisfy({ $0.count == first.count }) else {
            return []
        }

        var integrated = [Double](repeating: 0, count: first.count)
        if activities.count > 1 {
            for timeIndex in 0..<(activities.count - 1) {
                let dt = max(0, timesHours[timeIndex + 1] - timesHours[timeIndex])
                guard dt > 0 else { continue }
                for voxelIndex in first.indices {
                    let a0 = max(0, Double(activities[timeIndex][voxelIndex]))
                    let a1 = max(0, Double(activities[timeIndex + 1][voxelIndex]))
                    integrated[voxelIndex] += 0.5 * (a0 + a1) * dt
                }
            }
        }

        if options.tailModel != .noTail, let last = activities.last {
            for voxelIndex in first.indices {
                let lastActivity = max(0, Double(last[voxelIndex]))
                guard lastActivity > 0 else { continue }
                let lambda = decayConstantForTail(
                    activities: activities,
                    timesHours: timesHours,
                    voxelIndex: voxelIndex,
                    physicalLambda: options.physicalDecayConstantPerHour,
                    tailModel: options.tailModel
                )
                integrated[voxelIndex] += lastActivity / lambda
            }
        }

        return integrated.map { Float(max(0, $0)) }
    }

    public static func absorbedDosePixels(timeIntegratedActivityBqHoursPerML: [Float],
                                          densityGPerML: [Float],
                                          doseModel: Lu177DoseModel = .lu177LocalDeposition) -> [Float] {
        guard timeIntegratedActivityBqHoursPerML.count == densityGPerML.count else { return [] }
        return timeIntegratedActivityBqHoursPerML.indices.map { index in
            let tia = max(0, Double(timeIntegratedActivityBqHoursPerML[index]))
            let density = max(0.001, Double(densityGPerML[index]))
            let dose = tia * 3_600 * doseModel.joulesPerDecay * 1_000 / density
            return Float(dose.isFinite ? dose : 0)
        }
    }

    private static func validateAndSort(_ timePoints: [Lu177DosimetryTimePoint]) throws -> [Lu177DosimetryTimePoint] {
        guard !timePoints.isEmpty else {
            throw Lu177DosimetryError.invalidInput("At least one Lu-177 SPECT time point is required.")
        }
        let sorted = timePoints.sorted { $0.hoursPostAdministration < $1.hoursPostAdministration }
        for index in 1..<sorted.count {
            guard sorted[index].hoursPostAdministration > sorted[index - 1].hoursPostAdministration else {
                throw Lu177DosimetryError.invalidInput("Lu-177 SPECT time points must have unique acquisition times.")
            }
        }
        return sorted
    }

    private static func validateSameGrid(_ reference: ImageVolume,
                                         _ candidate: ImageVolume,
                                         role: String,
                                         tolerance: Double = 1e-4) throws {
        guard reference.width == candidate.width,
              reference.height == candidate.height,
              reference.depth == candidate.depth else {
            throw Lu177DosimetryError.gridMismatch("\(role) dimensions \(candidate.width)x\(candidate.height)x\(candidate.depth) do not match reference \(reference.width)x\(reference.height)x\(reference.depth).")
        }

        let spacingOK = close(reference.spacing.x, candidate.spacing.x, tolerance)
            && close(reference.spacing.y, candidate.spacing.y, tolerance)
            && close(reference.spacing.z, candidate.spacing.z, tolerance)
        let originOK = close(reference.origin.x, candidate.origin.x, tolerance)
            && close(reference.origin.y, candidate.origin.y, tolerance)
            && close(reference.origin.z, candidate.origin.z, tolerance)
        guard spacingOK, originOK else {
            throw Lu177DosimetryError.gridMismatch("\(role) spacing/origin does not match the reference SPECT grid.")
        }

        for column in 0..<3 {
            for row in 0..<3 {
                guard close(reference.direction[column][row], candidate.direction[column][row], tolerance) else {
                    throw Lu177DosimetryError.gridMismatch("\(role) direction matrix does not match the reference SPECT grid.")
                }
            }
        }
    }

    private static func validateLabelGrid(_ reference: ImageVolume,
                                          _ labelMap: LabelMap) throws {
        guard reference.width == labelMap.width,
              reference.height == labelMap.height,
              reference.depth == labelMap.depth else {
            throw Lu177DosimetryError.gridMismatch("Label map dimensions \(labelMap.width)x\(labelMap.height)x\(labelMap.depth) do not match reference \(reference.width)x\(reference.height)x\(reference.depth).")
        }
    }

    private static func decayConstantForTail(activities: [[Float]],
                                             timesHours: [Double],
                                             voxelIndex: Int,
                                             physicalLambda: Double,
                                             tailModel: Lu177TailModel) -> Double {
        guard tailModel == .monoExponentialFitWithPhysicalFallback,
              activities.count >= 2 else {
            return physicalLambda
        }

        var points: [(time: Double, logActivity: Double)] = []
        points.reserveCapacity(activities.count)
        for index in activities.indices {
            let activity = Double(activities[index][voxelIndex])
            if activity > 0, activity.isFinite {
                points.append((timesHours[index], log(activity)))
            }
        }
        guard points.count >= 2 else { return physicalLambda }

        let meanTime = points.reduce(0) { $0 + $1.time } / Double(points.count)
        let meanLogActivity = points.reduce(0) { $0 + $1.logActivity } / Double(points.count)
        var numerator = 0.0
        var denominator = 0.0
        for point in points {
            numerator += (point.time - meanTime) * (point.logActivity - meanLogActivity)
            denominator += pow(point.time - meanTime, 2)
        }
        guard denominator > 0 else { return physicalLambda }
        let slope = numerator / denominator
        let fittedLambda = -slope
        if fittedLambda.isFinite, fittedLambda > physicalLambda {
            return fittedLambda
        }
        return physicalLambda
    }

    private static func computeVOISummaries(dosePixels: [Float],
                                            tiaPixels: [Float],
                                            labelMap: LabelMap,
                                            reference: ImageVolume) -> [Lu177VOIDoseSummary] {
        let classIDs = Set(labelMap.voxels.filter { $0 != 0 })
        let voxelVolumeML = reference.spacing.x * reference.spacing.y * reference.spacing.z / 1_000
        return classIDs.sorted().compactMap { classID in
            var doseValues: [Double] = []
            var tiaSum = 0.0
            for index in labelMap.voxels.indices where labelMap.voxels[index] == classID {
                doseValues.append(Double(dosePixels[index]))
                tiaSum += Double(tiaPixels[index]) * voxelVolumeML
            }
            guard !doseValues.isEmpty else { return nil }
            let name = labelMap.classInfo(id: classID)?.name ?? "class_\(classID)"
            let sum = doseValues.reduce(0, +)
            return Lu177VOIDoseSummary(
                id: classID,
                classID: classID,
                className: name,
                voxelCount: doseValues.count,
                volumeML: Double(doseValues.count) * voxelVolumeML,
                meanDoseGy: sum / Double(doseValues.count),
                minDoseGy: doseValues.min() ?? 0,
                maxDoseGy: doseValues.max() ?? 0,
                timeIntegratedActivityBqHours: tiaSum
            )
        }
    }

    private static func totalTimeIntegratedActivity(_ tiaPixels: [Float],
                                                    reference: ImageVolume) -> Double {
        let voxelVolumeML = reference.spacing.x * reference.spacing.y * reference.spacing.z / 1_000
        return tiaPixels.reduce(0) { $0 + Double($1) * voxelVolumeML }
    }

    private static func warningsForWorkflow(timePoints: [Lu177DosimetryTimePoint],
                                            hasCT: Bool,
                                            options: Lu177DosimetryOptions) -> [String] {
        var warnings = [
            "Lu-177 absorbed dose map uses a local-deposition model, not voxel S-values or Monte Carlo transport.",
            "Clinical use requires site-specific SPECT calibration, recovery correction, registration QA, and medical physicist review."
        ]
        if !hasCT {
            warnings.append("No CT density map was supplied; all voxels were treated as water-density tissue.")
        }
        if timePoints.count == 1 {
            warnings.append("Only one SPECT time point was supplied; time integration uses the configured tail model without measured clearance.")
        }
        if options.tailModel == .noTail {
            warnings.append("Tail integration is disabled; dose will omit activity after the final imaging time point.")
        }
        return warnings
    }

    private static func mean(_ pixels: [Float]) -> Double {
        guard !pixels.isEmpty else { return 0 }
        return pixels.reduce(0) { $0 + Double($1) } / Double(pixels.count)
    }

    private static func close(_ lhs: Double, _ rhs: Double, _ tolerance: Double) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
