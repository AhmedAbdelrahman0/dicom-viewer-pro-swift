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

public enum Lu177DoseCalculationMethod: String, CaseIterable, Sendable {
    case localDeposition
    case monteCarloBetaTransport

    public var displayName: String {
        switch self {
        case .localDeposition: return "Local deposition"
        case .monteCarloBetaTransport: return "Monte Carlo beta transport"
        }
    }
}

public enum Lu177DosimetryAcquisitionMode: String, CaseIterable, Sendable {
    case singleTimePoint
    case multipleTimePoint

    public var displayName: String {
        switch self {
        case .singleTimePoint: return "Single time point"
        case .multipleTimePoint: return "Multiple time points"
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

public struct Lu177MonteCarloOptions: Equatable, Sendable {
    public let historiesPerSourceVoxel: Int
    public let maxTotalHistories: Int
    public let maximumBetaRangeMM: Double
    public let meanBetaPathLengthMM: Double
    public let stepLengthMM: Double
    public let minimumSourceTIABqHoursPerML: Float
    public let randomSeed: UInt64

    public init(historiesPerSourceVoxel: Int = 64,
                maxTotalHistories: Int = 500_000,
                maximumBetaRangeMM: Double = 1.8,
                meanBetaPathLengthMM: Double = 0.67,
                stepLengthMM: Double = 0.25,
                minimumSourceTIABqHoursPerML: Float = 0,
                randomSeed: UInt64 = 0x177D051) throws {
        guard historiesPerSourceVoxel > 0 else {
            throw Lu177DosimetryError.invalidInput("Monte Carlo histories per source voxel must be positive.")
        }
        guard maxTotalHistories > 0 else {
            throw Lu177DosimetryError.invalidInput("Monte Carlo history budget must be positive.")
        }
        guard maximumBetaRangeMM > 0, maximumBetaRangeMM.isFinite else {
            throw Lu177DosimetryError.invalidInput("Monte Carlo beta range must be a positive finite length.")
        }
        guard meanBetaPathLengthMM > 0,
              meanBetaPathLengthMM <= maximumBetaRangeMM,
              meanBetaPathLengthMM.isFinite else {
            throw Lu177DosimetryError.invalidInput("Monte Carlo mean beta path length must be positive, finite, and no larger than the maximum range.")
        }
        guard stepLengthMM > 0,
              stepLengthMM <= maximumBetaRangeMM,
              stepLengthMM.isFinite else {
            throw Lu177DosimetryError.invalidInput("Monte Carlo step length must be positive, finite, and no larger than the maximum range.")
        }
        guard minimumSourceTIABqHoursPerML >= 0,
              minimumSourceTIABqHoursPerML.isFinite else {
            throw Lu177DosimetryError.invalidInput("Monte Carlo source threshold must be non-negative and finite.")
        }

        self.historiesPerSourceVoxel = historiesPerSourceVoxel
        self.maxTotalHistories = maxTotalHistories
        self.maximumBetaRangeMM = maximumBetaRangeMM
        self.meanBetaPathLengthMM = meanBetaPathLengthMM
        self.stepLengthMM = stepLengthMM
        self.minimumSourceTIABqHoursPerML = minimumSourceTIABqHoursPerML
        self.randomSeed = randomSeed
    }

    public static var standard: Lu177MonteCarloOptions {
        try! Lu177MonteCarloOptions()
    }
}

public struct Lu177DoseModel: Equatable, Sendable {
    public let name: String
    public let calculationMethod: Lu177DoseCalculationMethod
    public let meanEnergyMeVPerDecay: Double
    public let nonLocalContributionFraction: Double
    public let monteCarloOptions: Lu177MonteCarloOptions?

    public init(name: String = "Lu-177 local deposition",
                calculationMethod: Lu177DoseCalculationMethod = .localDeposition,
                meanEnergyMeVPerDecay: Double = 0.1479,
                nonLocalContributionFraction: Double = 0,
                monteCarloOptions: Lu177MonteCarloOptions? = nil) throws {
        guard meanEnergyMeVPerDecay > 0, meanEnergyMeVPerDecay.isFinite else {
            throw Lu177DosimetryError.invalidInput("Mean emitted energy must be a positive finite MeV/decay value.")
        }
        guard nonLocalContributionFraction >= 0, nonLocalContributionFraction.isFinite else {
            throw Lu177DosimetryError.invalidInput("Non-local dose contribution fraction must be non-negative and finite.")
        }
        if calculationMethod == .monteCarloBetaTransport, monteCarloOptions == nil {
            throw Lu177DosimetryError.invalidInput("Monte Carlo beta transport requires Monte Carlo options.")
        }
        self.name = name
        self.calculationMethod = calculationMethod
        self.meanEnergyMeVPerDecay = meanEnergyMeVPerDecay
        self.nonLocalContributionFraction = nonLocalContributionFraction
        self.monteCarloOptions = monteCarloOptions
    }

    public static var lu177LocalDeposition: Lu177DoseModel {
        try! Lu177DoseModel()
    }

    public static var lu177MonteCarloBetaTransport: Lu177DoseModel {
        try! Lu177DoseModel(
            name: "Lu-177 Monte Carlo beta transport",
            calculationMethod: .monteCarloBetaTransport,
            monteCarloOptions: .standard
        )
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
    public let recoveryCoefficientTable: Lu177RecoveryCoefficientTable?
    public let registrationWarningThresholdMM: Double
    public let doseVolumeHistogramBinWidthGy: Double
    public let outputSeriesDescription: String

    public init(physicalHalfLifeHours: Double = 159.53,
                tailModel: Lu177TailModel = .monoExponentialFitWithPhysicalFallback,
                doseModel: Lu177DoseModel = .lu177LocalDeposition,
                densityCalibration: CTDensityCalibration = .standard,
                recoveryCoefficientTable: Lu177RecoveryCoefficientTable? = nil,
                registrationWarningThresholdMM: Double = 10,
                doseVolumeHistogramBinWidthGy: Double = 1,
                outputSeriesDescription: String = "Lu-177 absorbed dose map") throws {
        guard physicalHalfLifeHours > 0, physicalHalfLifeHours.isFinite else {
            throw Lu177DosimetryError.invalidInput("Lu-177 physical half-life must be a positive finite number of hours.")
        }
        guard registrationWarningThresholdMM > 0, registrationWarningThresholdMM.isFinite else {
            throw Lu177DosimetryError.invalidInput("Registration warning threshold must be a positive finite distance.")
        }
        guard doseVolumeHistogramBinWidthGy > 0, doseVolumeHistogramBinWidthGy.isFinite else {
            throw Lu177DosimetryError.invalidInput("Dose-volume histogram bin width must be a positive finite Gy value.")
        }
        self.physicalHalfLifeHours = physicalHalfLifeHours
        self.tailModel = tailModel
        self.doseModel = doseModel
        self.densityCalibration = densityCalibration
        self.recoveryCoefficientTable = recoveryCoefficientTable
        self.registrationWarningThresholdMM = registrationWarningThresholdMM
        self.doseVolumeHistogramBinWidthGy = doseVolumeHistogramBinWidthGy
        self.outputSeriesDescription = outputSeriesDescription
    }

    public static var standard: Lu177DosimetryOptions {
        try! Lu177DosimetryOptions()
    }

    public var physicalDecayConstantPerHour: Double {
        log(2) / physicalHalfLifeHours
    }
}

public struct Lu177SingleTimePointModel: Equatable, Sendable {
    public let effectiveHalfLifeHours: Double
    public let modelName: String
    public let extrapolateBackToAdministration: Bool

    public init(effectiveHalfLifeHours: Double,
                modelName: String = "Single-time-point effective half-life",
                extrapolateBackToAdministration: Bool = true) throws {
        guard effectiveHalfLifeHours > 0, effectiveHalfLifeHours.isFinite else {
            throw Lu177DosimetryError.invalidInput("Single-time-point effective half-life must be a positive finite number of hours.")
        }
        self.effectiveHalfLifeHours = effectiveHalfLifeHours
        self.modelName = modelName
        self.extrapolateBackToAdministration = extrapolateBackToAdministration
    }

    public var decayConstantPerHour: Double {
        log(2) / effectiveHalfLifeHours
    }
}

public struct Lu177DosimetryCurvePoint: Equatable, Sendable {
    public let timeHours: Double
    public let activityBq: Double
    public let meanActivityConcentrationBqPerML: Double
    public let doseRateGyPerHour: Double
}

public struct Lu177DosimetryCurve: Identifiable, Equatable, Sendable {
    public let id: String
    public let labelID: UInt16?
    public let name: String
    public let acquisitionMode: Lu177DosimetryAcquisitionMode
    public let points: [Lu177DosimetryCurvePoint]
    public let effectiveHalfLifeHours: Double?
    public let timeIntegratedActivityBqHours: Double
    public let absorbedDoseGy: Double
    public let warnings: [String]
}

public struct Lu177RecoveryCoefficientSample: Equatable, Sendable {
    public let volumeML: Double
    public let coefficient: Double

    public init(volumeML: Double, coefficient: Double) throws {
        guard volumeML > 0, volumeML.isFinite else {
            throw Lu177DosimetryError.invalidInput("Recovery coefficient volume must be a positive finite mL value.")
        }
        guard coefficient > 0, coefficient <= 1.5, coefficient.isFinite else {
            throw Lu177DosimetryError.invalidInput("Recovery coefficient must be finite and greater than zero.")
        }
        self.volumeML = volumeML
        self.coefficient = coefficient
    }
}

public struct Lu177RecoveryCoefficientTable: Equatable, Sendable {
    public let name: String
    public let samples: [Lu177RecoveryCoefficientSample]
    public let maxCorrectionFactor: Double

    public init(name: String,
                samples: [Lu177RecoveryCoefficientSample],
                maxCorrectionFactor: Double = 5) throws {
        guard !samples.isEmpty else {
            throw Lu177DosimetryError.invalidInput("Recovery coefficient table requires at least one volume/coefficient sample.")
        }
        guard maxCorrectionFactor >= 1, maxCorrectionFactor.isFinite else {
            throw Lu177DosimetryError.invalidInput("Maximum recovery correction factor must be finite and at least 1.")
        }
        self.name = name
        self.samples = samples.sorted { $0.volumeML < $1.volumeML }
        self.maxCorrectionFactor = maxCorrectionFactor
    }

    public func coefficient(forVolumeML volumeML: Double) -> Double {
        guard let first = samples.first, let last = samples.last else { return 1 }
        if volumeML <= first.volumeML { return first.coefficient }
        if volumeML >= last.volumeML { return last.coefficient }

        for index in 0..<(samples.count - 1) {
            let lower = samples[index]
            let upper = samples[index + 1]
            guard volumeML >= lower.volumeML, volumeML <= upper.volumeML else { continue }
            let fraction = (volumeML - lower.volumeML) / (upper.volumeML - lower.volumeML)
            return lower.coefficient + fraction * (upper.coefficient - lower.coefficient)
        }
        return last.coefficient
    }

    public func correctionFactor(forVolumeML volumeML: Double) -> Double {
        min(maxCorrectionFactor, 1 / max(coefficient(forVolumeML: volumeML), 1e-6))
    }
}

public struct Lu177TimePointAlignmentQA: Equatable, Sendable {
    public let movingTimeHours: Double
    public let centerOfMassShiftMM: Double
    public let totalActivityRatio: Double
    public let passed: Bool
    public let warning: String?
}

public struct Lu177DoseVolumeHistogramBin: Equatable, Sendable {
    public let lowerDoseGy: Double
    public let upperDoseGy: Double
    public let voxelCount: Int
    public let volumeML: Double
    public let cumulativeVolumeML: Double
}

public struct Lu177DoseVolumeHistogram: Identifiable, Equatable, Sendable {
    public let id: String
    public let labelID: UInt16
    public let name: String
    public let totalVolumeML: Double
    public let minDoseGy: Double
    public let meanDoseGy: Double
    public let maxDoseGy: Double
    public let bins: [Lu177DoseVolumeHistogramBin]
    public let sortedDoseDescendingGy: [Double]

    public func doseCoveringVolume(percent: Double) -> Double {
        guard !sortedDoseDescendingGy.isEmpty else { return 0 }
        let clamped = min(100, max(0, percent))
        let index = max(0, min(sortedDoseDescendingGy.count - 1, Int(ceil(clamped / 100 * Double(sortedDoseDescendingGy.count))) - 1))
        return sortedDoseDescendingGy[index]
    }

    public func volumeReceivingDose(atLeast doseGy: Double) -> Double {
        guard !sortedDoseDescendingGy.isEmpty else { return 0 }
        let count = sortedDoseDescendingGy.reduce(0) { $0 + ($1 >= doseGy ? 1 : 0) }
        return totalVolumeML * Double(count) / Double(sortedDoseDescendingGy.count)
    }
}

public struct Lu177TherapyCycleDose: Identifiable, Equatable, Sendable {
    public let id: Int
    public let cycleNumber: Int
    public let administeredActivityGBq: Double?
    public let relativeDoseScale: Double

    public init(cycleNumber: Int,
                administeredActivityGBq: Double?,
                relativeDoseScale: Double) throws {
        guard cycleNumber > 0 else {
            throw Lu177DosimetryError.invalidInput("Therapy cycle number must be positive.")
        }
        if let administeredActivityGBq {
            guard administeredActivityGBq > 0, administeredActivityGBq.isFinite else {
                throw Lu177DosimetryError.invalidInput("Administered activity must be a positive finite GBq value.")
            }
        }
        guard relativeDoseScale >= 0, relativeDoseScale.isFinite else {
            throw Lu177DosimetryError.invalidInput("Relative cycle dose scale must be non-negative and finite.")
        }
        self.id = cycleNumber
        self.cycleNumber = cycleNumber
        self.administeredActivityGBq = administeredActivityGBq
        self.relativeDoseScale = relativeDoseScale
    }
}

public struct Lu177CumulativeTherapyDoseResult: Sendable {
    public let cycleCount: Int
    public let cycles: [Lu177TherapyCycleDose]
    public let totalRelativeDoseScale: Double
    public let cumulativeDoseMapGy: ImageVolume
    public let minDoseGy: Double
    public let meanDoseGy: Double
    public let maxDoseGy: Double
    public let voiSummaries: [Lu177VOIDoseSummary]
    public let warnings: [String]
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
    public let acquisitionMode: Lu177DosimetryAcquisitionMode
    public let tailModel: Lu177TailModel
    public let doseModelName: String
    public let doseCalculationMethod: Lu177DoseCalculationMethod
    public let minDoseGy: Double
    public let meanDoseGy: Double
    public let maxDoseGy: Double
    public let totalTimeIntegratedActivityBqHours: Double
    public let voiSummaries: [Lu177VOIDoseSummary]
    public let doseVolumeHistograms: [Lu177DoseVolumeHistogram]
    public let alignmentQA: [Lu177TimePointAlignmentQA]
    public let recoveryCorrectionName: String?
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

        let rawActivities = try sorted.map { try $0.activityConcentrationPixels() }
        let alignmentQA = try timePointAlignmentQA(
            timePoints: sorted,
            warningThresholdMM: options.registrationWarningThresholdMM
        )
        let recoveryCorrectionName = options.recoveryCoefficientTable != nil && labelMap != nil
            ? options.recoveryCoefficientTable?.name
            : nil
        let activities = applyRecoveryCorrectionIfNeeded(
            activities: rawActivities,
            reference: reference,
            labelMap: labelMap,
            table: options.recoveryCoefficientTable
        )
        let times = sorted.map(\.hoursPostAdministration)
        let tiaPixels = integrateActivityConcentration(
            activities: activities,
            timesHours: times,
            options: options
        )
        let densityPixels = ctVolume.map {
            $0.pixels.map { options.densityCalibration.densityGPerML(hu: $0) }
        } ?? [Float](repeating: 1, count: reference.pixels.count)
        return makeDosimetryResult(
            reference: reference,
            timePointHours: times,
            acquisitionMode: sorted.count == 1 ? .singleTimePoint : .multipleTimePoint,
            tiaPixels: tiaPixels,
            densityPixels: densityPixels,
            ctVolume: ctVolume,
            labelMap: labelMap,
            options: options,
            extraWarnings: workflowWarnings(
                alignmentQA: alignmentQA,
                recoveryTable: options.recoveryCoefficientTable,
                recoveryApplied: recoveryCorrectionName != nil
            ),
            alignmentQA: alignmentQA,
            recoveryCorrectionName: recoveryCorrectionName
        )
    }

    public static func createSingleTimePointAbsorbedDoseMap(timePoint: Lu177DosimetryTimePoint,
                                                            singleTimePointModel: Lu177SingleTimePointModel,
                                                            ctVolume: ImageVolume? = nil,
                                                            labelMap: LabelMap? = nil,
                                                            options: Lu177DosimetryOptions = .standard) throws -> Lu177DosimetryResult {
        let reference = timePoint.activityVolume
        if let ctVolume {
            try validateSameGrid(reference, ctVolume, role: "CT density map")
        }
        if let labelMap {
            try validateLabelGrid(reference, labelMap)
        }
        let rawActivity = try timePoint.activityConcentrationPixels()
        let recoveryCorrectionName = options.recoveryCoefficientTable != nil && labelMap != nil
            ? options.recoveryCoefficientTable?.name
            : nil
        let activity = applyRecoveryCorrectionIfNeeded(
            activities: [rawActivity],
            reference: reference,
            labelMap: labelMap,
            table: options.recoveryCoefficientTable
        ).first ?? rawActivity
        let tiaPixels = integrateSingleTimePointActivityConcentration(
            activity: activity,
            timeHours: timePoint.hoursPostAdministration,
            model: singleTimePointModel
        )
        let densityPixels = ctVolume.map {
            $0.pixels.map { options.densityCalibration.densityGPerML(hu: $0) }
        } ?? [Float](repeating: 1, count: reference.pixels.count)
        let warning = singleTimePointModel.extrapolateBackToAdministration
            ? "Single-time-point dosimetry uses \(singleTimePointModel.modelName) and extrapolates measured activity back to administration."
            : "Single-time-point dosimetry uses \(singleTimePointModel.modelName) only from the imaging time onward."

        var extraWarnings = [
            warning,
            "Single-time-point dosimetry is an approximation; verify the assumed effective half-life against serial imaging or local protocol."
        ]
        extraWarnings.append(contentsOf: workflowWarnings(
            alignmentQA: [],
            recoveryTable: options.recoveryCoefficientTable,
            recoveryApplied: recoveryCorrectionName != nil
        ))

        return makeDosimetryResult(
            reference: reference,
            timePointHours: [timePoint.hoursPostAdministration],
            acquisitionMode: .singleTimePoint,
            tiaPixels: tiaPixels,
            densityPixels: densityPixels,
            ctVolume: ctVolume,
            labelMap: labelMap,
            options: options,
            extraWarnings: extraWarnings,
            alignmentQA: [],
            recoveryCorrectionName: recoveryCorrectionName
        )
    }

    public static func createMultipleTimePointAbsorbedDoseMap(timePoints: [Lu177DosimetryTimePoint],
                                                              ctVolume: ImageVolume? = nil,
                                                              labelMap: LabelMap? = nil,
                                                              options: Lu177DosimetryOptions = .standard) throws -> Lu177DosimetryResult {
        guard timePoints.count >= 2 else {
            throw Lu177DosimetryError.invalidInput("Multiple-time-point dosimetry requires at least two SPECT/CT time points.")
        }
        return try createAbsorbedDoseMap(
            timePoints: timePoints,
            ctVolume: ctVolume,
            labelMap: labelMap,
            options: options
        )
    }

    public static func integrateSingleTimePointActivityConcentration(activity: [Float],
                                                                     timeHours: Double,
                                                                     model: Lu177SingleTimePointModel) -> [Float] {
        guard timeHours >= 0, timeHours.isFinite else { return [] }
        let lambda = model.decayConstantPerHour
        let scale = model.extrapolateBackToAdministration
            ? exp(lambda * timeHours) / lambda
            : 1 / lambda
        return activity.map {
            let value = max(0, Double($0)) * scale
            return Float(value.isFinite ? value : 0)
        }
    }

    public static func createDosimetryCurves(timePoints: [Lu177DosimetryTimePoint],
                                             labelMap: LabelMap? = nil,
                                             ctVolume: ImageVolume? = nil,
                                             singleTimePointModel: Lu177SingleTimePointModel? = nil,
                                             options: Lu177DosimetryOptions = .standard) throws -> [Lu177DosimetryCurve] {
        let sorted = try validateAndSort(timePoints)
        let reference = sorted[0].activityVolume
        for point in sorted.dropFirst() {
            try validateSameGrid(reference, point.activityVolume, role: "SPECT time point")
        }
        if let labelMap {
            try validateLabelGrid(reference, labelMap)
        }
        if let ctVolume {
            try validateSameGrid(reference, ctVolume, role: "CT density map")
        }

        let rawActivities = try sorted.map { try $0.activityConcentrationPixels() }
        let activities = applyRecoveryCorrectionIfNeeded(
            activities: rawActivities,
            reference: reference,
            labelMap: labelMap,
            table: options.recoveryCoefficientTable
        )
        let times = sorted.map(\.hoursPostAdministration)
        let densityPixels = ctVolume.map {
            $0.pixels.map { options.densityCalibration.densityGPerML(hu: $0) }
        } ?? [Float](repeating: 1, count: reference.pixels.count)
        let regions = curveRegions(reference: reference, labelMap: labelMap, densityPixels: densityPixels)
        let acquisitionMode: Lu177DosimetryAcquisitionMode = sorted.count == 1 ? .singleTimePoint : .multipleTimePoint

        return try regions.map { region in
            let points = activities.indices.map { timeIndex in
                curvePoint(
                    timeHours: times[timeIndex],
                    activityPixels: activities[timeIndex],
                    region: region,
                    doseModel: options.doseModel
                )
            }
            let scalarActivities = points.map(\.activityBq)
            let effectiveHalfLife = effectiveHalfLifeForCurve(
                activitiesBq: scalarActivities,
                timesHours: times,
                physicalHalfLifeHours: options.physicalHalfLifeHours,
                singleTimePointModel: singleTimePointModel
            )
            let tia = try integratedCurveActivityBqHours(
                activitiesBq: scalarActivities,
                timesHours: times,
                options: options,
                singleTimePointModel: singleTimePointModel
            )
            let dose = region.massKG > 0
                ? tia * 3_600 * options.doseModel.joulesPerDecay / region.massKG
                : 0
            var warnings: [String] = []
            if acquisitionMode == .singleTimePoint {
                if let singleTimePointModel {
                    warnings.append("Single-time-point curve uses \(singleTimePointModel.modelName), effective half-life \(singleTimePointModel.effectiveHalfLifeHours) h.")
                } else {
                    warnings.append("Single-time-point curve used the physical half-life fallback because no effective half-life model was supplied.")
                }
            }
            return Lu177DosimetryCurve(
                id: region.id,
                labelID: region.labelID,
                name: region.name,
                acquisitionMode: acquisitionMode,
                points: points,
                effectiveHalfLifeHours: effectiveHalfLife,
                timeIntegratedActivityBqHours: tia,
                absorbedDoseGy: dose.isFinite ? dose : 0,
                warnings: warnings
            )
        }
    }

    public static func timePointAlignmentQA(timePoints: [Lu177DosimetryTimePoint],
                                            warningThresholdMM: Double = 10) throws -> [Lu177TimePointAlignmentQA] {
        let sorted = try validateAndSort(timePoints)
        guard sorted.count > 1 else { return [] }
        let reference = sorted[0].activityVolume
        let referenceActivity = try sorted[0].activityConcentrationPixels()
        let referenceCenter = centerOfMass(activityPixels: referenceActivity, volume: reference)
        let referenceTotal = referenceActivity.reduce(0) { $0 + Double($1) }

        return try sorted.dropFirst().map { point in
            try validateSameGrid(reference, point.activityVolume, role: "SPECT time point")
            let activity = try point.activityConcentrationPixels()
            let center = centerOfMass(activityPixels: activity, volume: point.activityVolume)
            let shift = simd_length(center - referenceCenter)
            let total = activity.reduce(0) { $0 + Double($1) }
            let ratio = referenceTotal > 0 ? total / referenceTotal : 0
            let passed = shift <= warningThresholdMM
            let warning = passed ? nil : "SPECT time point at \(point.hoursPostAdministration) h has activity center-of-mass shift \(String(format: "%.2f", shift)) mm from the reference time point."
            return Lu177TimePointAlignmentQA(
                movingTimeHours: point.hoursPostAdministration,
                centerOfMassShiftMM: shift,
                totalActivityRatio: ratio,
                passed: passed,
                warning: warning
            )
        }
    }

    public static func applyRecoveryCorrection(activities: [[Float]],
                                               reference: ImageVolume,
                                               labelMap: LabelMap,
                                               table: Lu177RecoveryCoefficientTable) -> [[Float]] {
        applyRecoveryCorrectionIfNeeded(
            activities: activities,
            reference: reference,
            labelMap: labelMap,
            table: table
        )
    }

    public static func doseVolumeHistograms(doseMap: ImageVolume,
                                            labelMap: LabelMap,
                                            binWidthGy: Double = 1) -> [Lu177DoseVolumeHistogram] {
        guard doseMap.width == labelMap.width,
              doseMap.height == labelMap.height,
              doseMap.depth == labelMap.depth,
              binWidthGy > 0,
              binWidthGy.isFinite else {
            return []
        }
        let classIDs = Set(labelMap.voxels.filter { $0 != 0 })
        let voxelVolumeML = doseMap.spacing.x * doseMap.spacing.y * doseMap.spacing.z / 1_000
        return classIDs.sorted().compactMap { classID in
            let doses = labelMap.voxels.indices
                .filter { labelMap.voxels[$0] == classID }
                .map { max(0, Double(doseMap.pixels[$0])) }
            guard !doses.isEmpty else { return nil }

            let maxDose = doses.max() ?? 0
            let binCount = max(1, Int(ceil(maxDose / binWidthGy)) + 1)
            var counts = [Int](repeating: 0, count: binCount)
            for dose in doses {
                let binIndex = max(0, min(binCount - 1, Int(floor(dose / binWidthGy))))
                counts[binIndex] += 1
            }

            var cumulativeCount = 0
            var bins = [Lu177DoseVolumeHistogramBin](repeating: Lu177DoseVolumeHistogramBin(
                lowerDoseGy: 0,
                upperDoseGy: binWidthGy,
                voxelCount: 0,
                volumeML: 0,
                cumulativeVolumeML: 0
            ), count: binCount)
            for index in stride(from: binCount - 1, through: 0, by: -1) {
                cumulativeCount += counts[index]
                bins[index] = Lu177DoseVolumeHistogramBin(
                    lowerDoseGy: Double(index) * binWidthGy,
                    upperDoseGy: Double(index + 1) * binWidthGy,
                    voxelCount: counts[index],
                    volumeML: Double(counts[index]) * voxelVolumeML,
                    cumulativeVolumeML: Double(cumulativeCount) * voxelVolumeML
                )
            }

            let sortedDescending = doses.sorted(by: >)
            let meanDose = doses.reduce(0, +) / Double(doses.count)
            return Lu177DoseVolumeHistogram(
                id: "dvh_\(classID)",
                labelID: classID,
                name: labelMap.classInfo(id: classID)?.name ?? "class_\(classID)",
                totalVolumeML: Double(doses.count) * voxelVolumeML,
                minDoseGy: doses.min() ?? 0,
                meanDoseGy: meanDose,
                maxDoseGy: maxDose,
                bins: bins,
                sortedDoseDescendingGy: sortedDescending
            )
        }
    }

    public static func cumulativeTherapyDose(referenceResult: Lu177DosimetryResult,
                                             cycleCount: Int) throws -> Lu177CumulativeTherapyDoseResult {
        guard cycleCount > 0 else {
            throw Lu177DosimetryError.invalidInput("Therapy cycle count must be positive.")
        }
        let cycles = try (1...cycleCount).map {
            try Lu177TherapyCycleDose(cycleNumber: $0, administeredActivityGBq: nil, relativeDoseScale: 1)
        }
        return makeCumulativeTherapyDose(referenceResult: referenceResult, cycles: cycles)
    }

    public static func cumulativeTherapyDose(referenceResult: Lu177DosimetryResult,
                                             administeredActivitiesGBq: [Double],
                                             referenceAdministeredActivityGBq: Double? = nil) throws -> Lu177CumulativeTherapyDoseResult {
        guard !administeredActivitiesGBq.isEmpty else {
            throw Lu177DosimetryError.invalidInput("At least one therapy cycle activity is required.")
        }
        let referenceActivity = referenceAdministeredActivityGBq ?? administeredActivitiesGBq[0]
        guard referenceActivity > 0, referenceActivity.isFinite else {
            throw Lu177DosimetryError.invalidInput("Reference administered activity must be a positive finite GBq value.")
        }
        let cycles = try administeredActivitiesGBq.enumerated().map { offset, activity in
            try Lu177TherapyCycleDose(
                cycleNumber: offset + 1,
                administeredActivityGBq: activity,
                relativeDoseScale: activity / referenceActivity
            )
        }
        return makeCumulativeTherapyDose(referenceResult: referenceResult, cycles: cycles)
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
                                          doseModel: Lu177DoseModel = .lu177LocalDeposition,
                                          referenceVolume: ImageVolume? = nil) -> [Float] {
        guard timeIntegratedActivityBqHoursPerML.count == densityGPerML.count else { return [] }
        if doseModel.calculationMethod == .monteCarloBetaTransport,
           let referenceVolume,
           let monteCarloOptions = doseModel.monteCarloOptions {
            return monteCarloAbsorbedDosePixels(
                timeIntegratedActivityBqHoursPerML: timeIntegratedActivityBqHoursPerML,
                densityGPerML: densityGPerML,
                referenceVolume: referenceVolume,
                doseModel: doseModel,
                options: monteCarloOptions
            )
        }
        return timeIntegratedActivityBqHoursPerML.indices.map { index in
            let tia = max(0, Double(timeIntegratedActivityBqHoursPerML[index]))
            let density = max(0.001, Double(densityGPerML[index]))
            let dose = tia * 3_600 * doseModel.joulesPerDecay * 1_000 / density
            return Float(dose.isFinite ? dose : 0)
        }
    }

    private static func monteCarloAbsorbedDosePixels(timeIntegratedActivityBqHoursPerML: [Float],
                                                     densityGPerML: [Float],
                                                     referenceVolume: ImageVolume,
                                                     doseModel: Lu177DoseModel,
                                                     options: Lu177MonteCarloOptions) -> [Float] {
        guard timeIntegratedActivityBqHoursPerML.count == referenceVolume.pixels.count,
              densityGPerML.count == referenceVolume.pixels.count else {
            return []
        }

        let activeSources = timeIntegratedActivityBqHoursPerML.indices.filter {
            timeIntegratedActivityBqHoursPerML[$0] > options.minimumSourceTIABqHoursPerML
        }
        guard !activeSources.isEmpty else {
            return [Float](repeating: 0, count: referenceVolume.pixels.count)
        }

        let historiesPerSource = max(
            1,
            min(options.historiesPerSourceVoxel, options.maxTotalHistories / activeSources.count)
        )
        let voxelVolumeML = referenceVolume.spacing.x * referenceVolume.spacing.y * referenceVolume.spacing.z / 1_000
        let voxelMassKG = densityGPerML.map {
            max(0.001, Double($0)) * voxelVolumeML / 1_000
        }
        var depositedEnergyJ = [Double](repeating: 0, count: referenceVolume.pixels.count)
        var generator = SeededRandom(seed: options.randomSeed)

        for sourceIndex in activeSources {
            let sourceTIA = max(0, Double(timeIntegratedActivityBqHoursPerML[sourceIndex]))
            let sourceDecays = sourceTIA * voxelVolumeML * 3_600
            let sourceEnergyJ = sourceDecays * doseModel.joulesPerDecay
            guard sourceEnergyJ > 0, sourceEnergyJ.isFinite else { continue }

            let energyPerHistory = sourceEnergyJ / Double(historiesPerSource)
            let sourceVoxel = voxelCoordinate(index: sourceIndex, reference: referenceVolume)

            for _ in 0..<historiesPerSource {
                let direction = randomUnitVector(generator: &generator)
                let rangeWaterMM = sampleBetaRangeMM(options: options, generator: &generator)
                let targets = transportTargets(
                    source: sourceVoxel,
                    direction: direction,
                    rangeWaterMM: rangeWaterMM,
                    densityGPerML: densityGPerML,
                    reference: referenceVolume,
                    stepLengthMM: options.stepLengthMM
                )
                guard !targets.isEmpty else {
                    depositedEnergyJ[sourceIndex] += energyPerHistory
                    continue
                }
                let energyPerTarget = energyPerHistory / Double(targets.count)
                for target in targets {
                    depositedEnergyJ[target] += energyPerTarget
                }
            }
        }

        return depositedEnergyJ.indices.map { index in
            let dose = depositedEnergyJ[index] / voxelMassKG[index]
            return Float(dose.isFinite ? max(0, dose) : 0)
        }
    }

    private static func transportTargets(source: (z: Int, y: Int, x: Int),
                                         direction: SIMD3<Double>,
                                         rangeWaterMM: Double,
                                         densityGPerML: [Float],
                                         reference: ImageVolume,
                                         stepLengthMM: Double) -> [Int] {
        let sourceIndex = voxelIndex(
            z: source.z,
            y: source.y,
            x: source.x,
            width: reference.width,
            height: reference.height
        )
        guard rangeWaterMM > 0, rangeWaterMM.isFinite else { return [sourceIndex] }

        var targets = [sourceIndex]
        targets.reserveCapacity(max(1, Int(ceil(rangeWaterMM / stepLengthMM)) + 1))
        let sourcePositionMM = SIMD3<Double>(
            Double(source.x) * reference.spacing.x,
            Double(source.y) * reference.spacing.y,
            Double(source.z) * reference.spacing.z
        )
        var waterEquivalentMM = 0.0
        var distanceMM = 0.0

        while waterEquivalentMM < rangeWaterMM {
            distanceMM += stepLengthMM
            let position = sourcePositionMM + direction * distanceMM
            guard let target = voxelIndex(
                physicalPositionMM: position,
                reference: reference
            ) else {
                break
            }
            targets.append(target)
            waterEquivalentMM += stepLengthMM * max(0.001, Double(densityGPerML[target]))
        }

        return targets
    }

    private static func sampleBetaRangeMM(options: Lu177MonteCarloOptions,
                                          generator: inout SeededRandom) -> Double {
        let exponent = max(0.001, options.maximumBetaRangeMM / options.meanBetaPathLengthMM - 1)
        let u = max(generator.nextUnitDouble(), Double.leastNonzeroMagnitude)
        return options.maximumBetaRangeMM * pow(u, exponent)
    }

    private static func randomUnitVector(generator: inout SeededRandom) -> SIMD3<Double> {
        let z = 2 * generator.nextUnitDouble() - 1
        let phi = 2 * Double.pi * generator.nextUnitDouble()
        let radius = sqrt(max(0, 1 - z * z))
        return SIMD3<Double>(
            radius * cos(phi),
            radius * sin(phi),
            z
        )
    }

    private static func voxelCoordinate(index: Int,
                                        reference: ImageVolume) -> (z: Int, y: Int, x: Int) {
        let plane = reference.height * reference.width
        let z = index / plane
        let remainder = index - z * plane
        let y = remainder / reference.width
        let x = remainder - y * reference.width
        return (z, y, x)
    }

    private static func voxelIndex(physicalPositionMM: SIMD3<Double>,
                                   reference: ImageVolume) -> Int? {
        let x = Int(round(physicalPositionMM.x / reference.spacing.x))
        let y = Int(round(physicalPositionMM.y / reference.spacing.y))
        let z = Int(round(physicalPositionMM.z / reference.spacing.z))
        guard x >= 0, x < reference.width,
              y >= 0, y < reference.height,
              z >= 0, z < reference.depth else {
            return nil
        }
        return voxelIndex(z: z, y: y, x: x, width: reference.width, height: reference.height)
    }

    private static func voxelIndex(z: Int, y: Int, x: Int, width: Int, height: Int) -> Int {
        z * height * width + y * width + x
    }

    private static func makeDosimetryResult(reference: ImageVolume,
                                            timePointHours: [Double],
                                            acquisitionMode: Lu177DosimetryAcquisitionMode,
                                            tiaPixels: [Float],
                                            densityPixels: [Float],
                                            ctVolume: ImageVolume?,
                                            labelMap: LabelMap?,
                                            options: Lu177DosimetryOptions,
                                            extraWarnings: [String],
                                            alignmentQA: [Lu177TimePointAlignmentQA],
                                            recoveryCorrectionName: String?) -> Lu177DosimetryResult {
        let dosePixels = absorbedDosePixels(
            timeIntegratedActivityBqHoursPerML: tiaPixels,
            densityGPerML: densityPixels,
            doseModel: options.doseModel,
            referenceVolume: reference
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
        let histograms = labelMap.map {
            Lu177DosimetryEngine.doseVolumeHistograms(
                doseMap: doseVolume,
                labelMap: $0,
                binWidthGy: options.doseVolumeHistogramBinWidthGy
            )
        } ?? []

        var warnings = warningsForWorkflow(
            timePointCount: timePointHours.count,
            hasCT: ctVolume != nil,
            options: options
        )
        warnings.append(contentsOf: extraWarnings)
        let report = Lu177DosimetryReport(
            sourceVolumeIdentity: reference.sessionIdentity,
            timePointHours: timePointHours,
            acquisitionMode: acquisitionMode,
            tailModel: options.tailModel,
            doseModelName: options.doseModel.name,
            doseCalculationMethod: options.doseModel.calculationMethod,
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
            doseVolumeHistograms: histograms,
            alignmentQA: alignmentQA,
            recoveryCorrectionName: recoveryCorrectionName,
            warnings: warnings
        )

        return Lu177DosimetryResult(
            absorbedDoseMapGy: doseVolume,
            timeIntegratedActivityMapBqHoursPerML: tiaVolume,
            densityMapGPerML: densityVolume,
            report: report
        )
    }

    private static func makeCumulativeTherapyDose(referenceResult: Lu177DosimetryResult,
                                                  cycles: [Lu177TherapyCycleDose]) -> Lu177CumulativeTherapyDoseResult {
        let totalScale = cycles.reduce(0) { $0 + $1.relativeDoseScale }
        let referenceVolume = referenceResult.absorbedDoseMapGy
        let cumulativePixels = referenceVolume.pixels.map {
            Float(Double($0) * totalScale)
        }
        let cumulativeVolume = ImageVolume(
            pixels: cumulativePixels,
            depth: referenceVolume.depth,
            height: referenceVolume.height,
            width: referenceVolume.width,
            spacing: referenceVolume.spacing,
            origin: referenceVolume.origin,
            direction: referenceVolume.direction,
            modality: "DOSE",
            studyUID: referenceVolume.studyUID,
            patientID: referenceVolume.patientID,
            patientName: referenceVolume.patientName,
            seriesDescription: "Cumulative Lu-177 absorbed dose (\(cycles.count) cycles)",
            studyDescription: referenceVolume.studyDescription,
            sourceFiles: referenceVolume.sourceFiles
        )
        let scaledVOIs = referenceResult.report.voiSummaries.map { summary in
            Lu177VOIDoseSummary(
                id: summary.id,
                classID: summary.classID,
                className: summary.className,
                voxelCount: summary.voxelCount,
                volumeML: summary.volumeML,
                meanDoseGy: summary.meanDoseGy * totalScale,
                minDoseGy: summary.minDoseGy * totalScale,
                maxDoseGy: summary.maxDoseGy * totalScale,
                timeIntegratedActivityBqHours: summary.timeIntegratedActivityBqHours * totalScale
            )
        }
        let warnings = [
            "Cumulative therapy dose assumes each cycle has the same biodistribution and clearance as the reference dosimetry result, scaled only by administered activity.",
            "Use measured per-cycle SPECT/CT dosimetry when organ dose limits or adaptive treatment decisions are clinically important."
        ]
        return Lu177CumulativeTherapyDoseResult(
            cycleCount: cycles.count,
            cycles: cycles,
            totalRelativeDoseScale: totalScale,
            cumulativeDoseMapGy: cumulativeVolume,
            minDoseGy: Double(cumulativePixels.min() ?? 0),
            meanDoseGy: mean(cumulativePixels),
            maxDoseGy: Double(cumulativePixels.max() ?? 0),
            voiSummaries: scaledVOIs,
            warnings: warnings
        )
    }

    private struct CurveRegion {
        let id: String
        let labelID: UInt16?
        let name: String
        let indices: [Int]
        let volumeML: Double
        let massKG: Double
    }

    private static func curveRegions(reference: ImageVolume,
                                     labelMap: LabelMap?,
                                     densityPixels: [Float]) -> [CurveRegion] {
        let voxelVolumeML = reference.spacing.x * reference.spacing.y * reference.spacing.z / 1_000
        if let labelMap {
            let classIDs = Set(labelMap.voxels.filter { $0 != 0 })
            return classIDs.sorted().compactMap { classID in
                let indices = labelMap.voxels.indices.filter { labelMap.voxels[$0] == classID }
                guard !indices.isEmpty else { return nil }
                let massKG = indices.reduce(0) {
                    $0 + max(0.001, Double(densityPixels[$1])) * voxelVolumeML / 1_000
                }
                return CurveRegion(
                    id: "label_\(classID)",
                    labelID: classID,
                    name: labelMap.classInfo(id: classID)?.name ?? "class_\(classID)",
                    indices: indices,
                    volumeML: Double(indices.count) * voxelVolumeML,
                    massKG: massKG
                )
            }
        }

        let indices = Array(reference.pixels.indices)
        let massKG = indices.reduce(0) {
            $0 + max(0.001, Double(densityPixels[$1])) * voxelVolumeML / 1_000
        }
        return [
            CurveRegion(
                id: "whole_volume",
                labelID: nil,
                name: "Whole SPECT volume",
                indices: indices,
                volumeML: Double(indices.count) * voxelVolumeML,
                massKG: massKG
            )
        ]
    }

    private static func curvePoint(timeHours: Double,
                                   activityPixels: [Float],
                                   region: CurveRegion,
                                   doseModel: Lu177DoseModel) -> Lu177DosimetryCurvePoint {
        let activityBq = region.indices.reduce(0) {
            $0 + Double(activityPixels[$1]) * region.volumeML / Double(max(region.indices.count, 1))
        }
        let meanActivityConcentration = region.volumeML > 0 ? activityBq / region.volumeML : 0
        let doseRate = region.massKG > 0
            ? activityBq * doseModel.joulesPerDecay / region.massKG
            : 0
        return Lu177DosimetryCurvePoint(
            timeHours: timeHours,
            activityBq: activityBq,
            meanActivityConcentrationBqPerML: meanActivityConcentration,
            doseRateGyPerHour: doseRate * 3_600
        )
    }

    private static func integratedCurveActivityBqHours(activitiesBq: [Double],
                                                       timesHours: [Double],
                                                       options: Lu177DosimetryOptions,
                                                       singleTimePointModel: Lu177SingleTimePointModel?) throws -> Double {
        guard activitiesBq.count == timesHours.count, !activitiesBq.isEmpty else { return 0 }
        if activitiesBq.count == 1 {
            if let singleTimePointModel {
                let scale = singleTimePointModel.extrapolateBackToAdministration
                    ? exp(singleTimePointModel.decayConstantPerHour * timesHours[0]) / singleTimePointModel.decayConstantPerHour
                    : 1 / singleTimePointModel.decayConstantPerHour
                return max(0, activitiesBq[0]) * scale
            }
            return max(0, activitiesBq[0]) / options.physicalDecayConstantPerHour
        }

        var total = 0.0
        for index in 0..<(activitiesBq.count - 1) {
            let dt = max(0, timesHours[index + 1] - timesHours[index])
            total += 0.5 * (max(0, activitiesBq[index]) + max(0, activitiesBq[index + 1])) * dt
        }
        if options.tailModel != .noTail, let last = activitiesBq.last {
            let lambda = scalarDecayConstantForTail(
                activitiesBq: activitiesBq,
                timesHours: timesHours,
                physicalLambda: options.physicalDecayConstantPerHour,
                tailModel: options.tailModel
            )
            total += max(0, last) / lambda
        }
        return total
    }

    private static func effectiveHalfLifeForCurve(activitiesBq: [Double],
                                                  timesHours: [Double],
                                                  physicalHalfLifeHours: Double,
                                                  singleTimePointModel: Lu177SingleTimePointModel?) -> Double? {
        if let singleTimePointModel {
            return singleTimePointModel.effectiveHalfLifeHours
        }
        guard activitiesBq.count >= 2 else {
            return physicalHalfLifeHours
        }
        let lambda = scalarDecayConstantForTail(
            activitiesBq: activitiesBq,
            timesHours: timesHours,
            physicalLambda: log(2) / physicalHalfLifeHours,
            tailModel: .monoExponentialFitWithPhysicalFallback
        )
        return log(2) / lambda
    }

    private static func applyRecoveryCorrectionIfNeeded(activities: [[Float]],
                                                        reference: ImageVolume,
                                                        labelMap: LabelMap?,
                                                        table: Lu177RecoveryCoefficientTable?) -> [[Float]] {
        guard let labelMap, let table else { return activities }
        guard reference.width == labelMap.width,
              reference.height == labelMap.height,
              reference.depth == labelMap.depth else {
            return activities
        }

        let voxelVolumeML = reference.spacing.x * reference.spacing.y * reference.spacing.z / 1_000
        let counts = labelMap.voxelCounts()
        var correctionByClass: [UInt16: Float] = [:]
        for (classID, voxelCount) in counts {
            let volumeML = Double(voxelCount) * voxelVolumeML
            correctionByClass[classID] = Float(table.correctionFactor(forVolumeML: volumeML))
        }

        return activities.map { activity in
            var corrected = activity
            for index in labelMap.voxels.indices {
                let classID = labelMap.voxels[index]
                guard classID != 0, let factor = correctionByClass[classID] else { continue }
                corrected[index] = max(0, activity[index] * factor)
            }
            return corrected
        }
    }

    private static func centerOfMass(activityPixels: [Float],
                                     volume: ImageVolume) -> SIMD3<Double> {
        var weighted = SIMD3<Double>(0, 0, 0)
        var total = 0.0
        for index in activityPixels.indices {
            let activity = max(0, Double(activityPixels[index]))
            guard activity > 0 else { continue }
            let coordinate = voxelCoordinate(index: index, reference: volume)
            let world = volume.worldPoint(z: coordinate.z, y: coordinate.y, x: coordinate.x)
            weighted += world * activity
            total += activity
        }
        guard total > 0 else {
            return volume.worldPoint(
                z: volume.depth / 2,
                y: volume.height / 2,
                x: volume.width / 2
            )
        }
        return weighted / total
    }

    private static func workflowWarnings(alignmentQA: [Lu177TimePointAlignmentQA],
                                         recoveryTable: Lu177RecoveryCoefficientTable?,
                                         recoveryApplied: Bool) -> [String] {
        var warnings = alignmentQA.compactMap(\.warning)
        if let recoveryTable {
            if recoveryApplied {
                warnings.append("Applied SPECT partial-volume/recovery correction using \(recoveryTable.name); verify the recovery table against the local scanner, collimator, reconstruction, and object-size protocol.")
            } else {
                warnings.append("Recovery coefficient table \(recoveryTable.name) was configured but not applied because no matching label map was supplied.")
            }
        }
        return warnings
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

    private static func scalarDecayConstantForTail(activitiesBq: [Double],
                                                   timesHours: [Double],
                                                   physicalLambda: Double,
                                                   tailModel: Lu177TailModel) -> Double {
        guard tailModel == .monoExponentialFitWithPhysicalFallback,
              activitiesBq.count == timesHours.count,
              activitiesBq.count >= 2 else {
            return physicalLambda
        }

        let points = activitiesBq.indices.compactMap { index -> (time: Double, logActivity: Double)? in
            let activity = activitiesBq[index]
            guard activity > 0, activity.isFinite else { return nil }
            return (timesHours[index], log(activity))
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
        let fittedLambda = -(numerator / denominator)
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

    private static func warningsForWorkflow(timePointCount: Int,
                                            hasCT: Bool,
                                            options: Lu177DosimetryOptions) -> [String] {
        var warnings: [String]
        switch options.doseModel.calculationMethod {
        case .localDeposition:
            warnings = [
                "Lu-177 absorbed dose map uses a local-deposition model, not voxel S-values or Monte Carlo transport.",
                "Clinical use requires site-specific SPECT calibration, recovery correction, registration QA, and medical physicist review."
            ]
        case .monteCarloBetaTransport:
            warnings = [
                "Lu-177 absorbed dose map uses native stochastic beta transport; it is not a substitute for a commissioned Geant4/GATE or other clinically validated Monte Carlo engine.",
                "Clinical use requires site-specific SPECT calibration, recovery correction, registration QA, transport validation, and medical physicist review."
            ]
        }
        if !hasCT {
            warnings.append("No CT density map was supplied; all voxels were treated as water-density tissue.")
        }
        if let monteCarlo = options.doseModel.monteCarloOptions {
            warnings.append("Monte Carlo settings: \(monteCarlo.historiesPerSourceVoxel) histories/source voxel, \(monteCarlo.maxTotalHistories) history budget, seed \(monteCarlo.randomSeed).")
        }
        if timePointCount == 1 {
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

    private struct SeededRandom {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed == 0 ? 0x177D051 : seed
        }

        mutating func nextUnitDouble() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let value = state >> 11
            return Double(value) / Double(1 << 53)
        }
    }
}
