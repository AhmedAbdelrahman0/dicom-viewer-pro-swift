import XCTest
import SwiftUI
@testable import Tracer

final class Lu177DosimetryTests: XCTestCase {
    func testNoTailDoseMapUsesTrapezoidalTIAAndWaterDensity() throws {
        let spect0 = makeVolume(pixels: [2, 2], modality: "NM")
        let spect1 = makeVolume(pixels: [2, 2], modality: "NM")
        let points = [
            try Lu177DosimetryTimePoint(activityVolume: spect0, hoursPostAdministration: 0),
            try Lu177DosimetryTimePoint(activityVolume: spect1, hoursPostAdministration: 2)
        ]
        let doseModel = try Lu177DoseModel(meanEnergyMeVPerDecay: 1)
        let options = try Lu177DosimetryOptions(
            tailModel: .noTail,
            doseModel: doseModel
        )

        let result = try Lu177DosimetryEngine.createAbsorbedDoseMap(
            timePoints: points,
            options: options
        )

        let expectedTIA: Float = 4
        let expectedDose = Double(expectedTIA) * 3_600 * doseModel.joulesPerDecay * 1_000
        XCTAssertEqual(result.timeIntegratedActivityMapBqHoursPerML.pixels, [expectedTIA, expectedTIA])
        XCTAssertEqual(Double(result.absorbedDoseMapGy.pixels[0]), expectedDose, accuracy: expectedDose * 1e-5)
        XCTAssertEqual(result.report.totalTimeIntegratedActivityBqHours, 8, accuracy: 1e-8)
        XCTAssertTrue(result.report.warnings.contains { $0.contains("Tail integration is disabled") })
    }

    func testSingleTimePointDoseMapUsesEffectiveHalfLifeBackExtrapolation() throws {
        let spect = makeVolume(pixels: [10], modality: "NM")
        let point = try Lu177DosimetryTimePoint(
            activityVolume: spect,
            hoursPostAdministration: 24
        )
        let model = try Lu177SingleTimePointModel(
            effectiveHalfLifeHours: 48,
            modelName: "Kidney prior-cycle fit"
        )
        let doseModel = try Lu177DoseModel(meanEnergyMeVPerDecay: 1)
        let options = try Lu177DosimetryOptions(
            tailModel: .noTail,
            doseModel: doseModel
        )

        let result = try Lu177DosimetryEngine.createSingleTimePointAbsorbedDoseMap(
            timePoint: point,
            singleTimePointModel: model,
            options: options
        )

        let lambda = Foundation.log(2.0) / 48
        let expectedTIA = 10 * Foundation.exp(lambda * 24) / lambda
        let expectedDose = expectedTIA * 3_600 * doseModel.joulesPerDecay * 1_000
        XCTAssertEqual(result.report.acquisitionMode, .singleTimePoint)
        XCTAssertEqual(Double(result.timeIntegratedActivityMapBqHoursPerML.pixels[0]), expectedTIA, accuracy: expectedTIA * 1e-5)
        XCTAssertEqual(Double(result.absorbedDoseMapGy.pixels[0]), expectedDose, accuracy: expectedDose * 1e-5)
        XCTAssertTrue(result.report.warnings.contains { $0.contains("Single-time-point dosimetry uses Kidney prior-cycle fit") })
    }

    func testMultipleTimePointWorkflowRequiresAtLeastTwoTimePoints() throws {
        let spect = makeVolume(pixels: [1], modality: "NM")
        let point = try Lu177DosimetryTimePoint(activityVolume: spect, hoursPostAdministration: 24)

        XCTAssertThrowsError(try Lu177DosimetryEngine.createMultipleTimePointAbsorbedDoseMap(timePoints: [point])) { error in
            XCTAssertEqual(
                error as? Lu177DosimetryError,
                .invalidInput("Multiple-time-point dosimetry requires at least two SPECT/CT time points.")
            )
        }
    }

    func testCTDensityMapReducesDoseInHighDensityBoneLikeVoxel() throws {
        let spect0 = makeVolume(pixels: [1, 1], modality: "NM")
        let spect1 = makeVolume(pixels: [1, 1], modality: "NM")
        let ct = makeVolume(pixels: [0, 1_000], modality: "CT")
        let points = [
            try Lu177DosimetryTimePoint(activityVolume: spect0, hoursPostAdministration: 0),
            try Lu177DosimetryTimePoint(activityVolume: spect1, hoursPostAdministration: 1)
        ]
        let options = try Lu177DosimetryOptions(
            tailModel: .noTail,
            doseModel: try Lu177DoseModel(meanEnergyMeVPerDecay: 1)
        )

        let result = try Lu177DosimetryEngine.createAbsorbedDoseMap(
            timePoints: points,
            ctVolume: ct,
            options: options
        )

        let density = try XCTUnwrap(result.densityMapGPerML)
        XCTAssertEqual(Double(density.pixels[0]), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(density.pixels[1]), 2, accuracy: 1e-6)
        XCTAssertEqual(
            Double(result.absorbedDoseMapGy.pixels[1]),
            Double(result.absorbedDoseMapGy.pixels[0]) / 2,
            accuracy: Double(result.absorbedDoseMapGy.pixels[0]) * 1e-5
        )
    }

    func testRecoveryCoefficientCorrectionBoostsSmallVOIActivity() throws {
        let spect0 = makeVolume(pixels: [1, 1, 5], modality: "NM")
        let spect1 = makeVolume(pixels: [1, 1, 5], modality: "NM")
        let labelMap = LabelMap(parentSeriesUID: spect0.seriesUID, depth: 1, height: 1, width: 3)
        labelMap.classes = [
            LabelClass(labelID: 1, name: "Small lesion", category: .tumor, color: .yellow)
        ]
        labelMap.voxels = [1, 1, 0]
        let recovery = try Lu177RecoveryCoefficientTable(
            name: "Local sphere phantom",
            samples: [
                try Lu177RecoveryCoefficientSample(volumeML: 1, coefficient: 0.4),
                try Lu177RecoveryCoefficientSample(volumeML: 2, coefficient: 0.5),
                try Lu177RecoveryCoefficientSample(volumeML: 10, coefficient: 0.9)
            ]
        )
        let options = try Lu177DosimetryOptions(
            tailModel: .noTail,
            recoveryCoefficientTable: recovery
        )

        let result = try Lu177DosimetryEngine.createAbsorbedDoseMap(
            timePoints: [
                try Lu177DosimetryTimePoint(activityVolume: spect0, hoursPostAdministration: 0),
                try Lu177DosimetryTimePoint(activityVolume: spect1, hoursPostAdministration: 1)
            ],
            labelMap: labelMap,
            options: options
        )

        XCTAssertEqual(result.report.recoveryCorrectionName, "Local sphere phantom")
        XCTAssertEqual(result.timeIntegratedActivityMapBqHoursPerML.pixels[0], 2, accuracy: 1e-6)
        XCTAssertEqual(result.timeIntegratedActivityMapBqHoursPerML.pixels[1], 2, accuracy: 1e-6)
        XCTAssertEqual(result.timeIntegratedActivityMapBqHoursPerML.pixels[2], 5, accuracy: 1e-6)
        XCTAssertTrue(result.report.warnings.contains { $0.contains("Applied SPECT partial-volume") })
    }

    func testTimePointAlignmentQAFlagsShiftedActivityCentroid() throws {
        let reference = makeVolume(pixels: [10, 0, 0], modality: "NM", spacing: (10, 10, 10))
        let shifted = makeVolume(pixels: [0, 0, 10], modality: "NM", spacing: (10, 10, 10))
        let points = [
            try Lu177DosimetryTimePoint(activityVolume: reference, hoursPostAdministration: 4),
            try Lu177DosimetryTimePoint(activityVolume: shifted, hoursPostAdministration: 24)
        ]

        let qa = try Lu177DosimetryEngine.timePointAlignmentQA(
            timePoints: points,
            warningThresholdMM: 5
        )

        XCTAssertEqual(qa.count, 1)
        XCTAssertEqual(qa[0].centerOfMassShiftMM, 20, accuracy: 1e-8)
        XCTAssertFalse(qa[0].passed)
        XCTAssertNotNil(qa[0].warning)
    }

    func testDoseVolumeHistogramReportsCumulativeDoseMetrics() throws {
        let doseMap = makeVolume(pixels: [0.5, 1.5, 2.5, 3.5], modality: "DOSE", height: 2, width: 2)
        let labelMap = LabelMap(parentSeriesUID: doseMap.seriesUID, depth: 1, height: 2, width: 2)
        labelMap.classes = [
            LabelClass(labelID: 1, name: "Kidney", category: .organ, color: .red)
        ]
        labelMap.voxels = [1, 1, 1, 1]

        let histograms = Lu177DosimetryEngine.doseVolumeHistograms(
            doseMap: doseMap,
            labelMap: labelMap,
            binWidthGy: 1
        )

        let kidney = try XCTUnwrap(histograms.first)
        XCTAssertEqual(kidney.name, "Kidney")
        XCTAssertEqual(kidney.totalVolumeML, 4, accuracy: 1e-8)
        XCTAssertEqual(kidney.meanDoseGy, 2, accuracy: 1e-8)
        XCTAssertEqual(kidney.doseCoveringVolume(percent: 50), 2.5, accuracy: 1e-8)
        XCTAssertEqual(kidney.volumeReceivingDose(atLeast: 2), 2, accuracy: 1e-8)
        XCTAssertEqual(kidney.bins[2].cumulativeVolumeML, 2, accuracy: 1e-8)
    }

    func testDosimetryCurvesBuildVOITimeActivityAndDoseCurves() throws {
        let spect0 = makeVolume(pixels: [1, 2, 3, 4], modality: "NM", height: 2, width: 2)
        let spect1 = makeVolume(pixels: [0.5, 1, 1.5, 2], modality: "NM", height: 2, width: 2)
        let labelMap = LabelMap(parentSeriesUID: spect0.seriesUID, depth: 1, height: 2, width: 2)
        labelMap.classes = [
            LabelClass(labelID: 1, name: "Kidney", category: .organ, color: .red),
            LabelClass(labelID: 2, name: "Tumor", category: .tumor, color: .yellow)
        ]
        labelMap.voxels = [1, 1, 2, 0]
        let points = [
            try Lu177DosimetryTimePoint(activityVolume: spect0, hoursPostAdministration: 0),
            try Lu177DosimetryTimePoint(activityVolume: spect1, hoursPostAdministration: 2)
        ]
        let options = try Lu177DosimetryOptions(
            physicalHalfLifeHours: 160,
            tailModel: .monoExponentialFitWithPhysicalFallback,
            doseModel: try Lu177DoseModel(meanEnergyMeVPerDecay: 1)
        )

        let curves = try Lu177DosimetryEngine.createDosimetryCurves(
            timePoints: points,
            labelMap: labelMap,
            options: options
        )

        let kidney = try XCTUnwrap(curves.first { $0.name == "Kidney" })
        XCTAssertEqual(kidney.acquisitionMode, .multipleTimePoint)
        XCTAssertEqual(kidney.points.count, 2)
        XCTAssertEqual(kidney.points[0].activityBq, 3, accuracy: 1e-8)
        XCTAssertEqual(kidney.points[1].activityBq, 1.5, accuracy: 1e-8)
        XCTAssertEqual(kidney.effectiveHalfLifeHours ?? 0, 2, accuracy: 1e-5)
        XCTAssertGreaterThan(kidney.timeIntegratedActivityBqHours, 0)
        XCTAssertGreaterThan(kidney.absorbedDoseGy, 0)
    }

    func testSingleTimePointDosimetryCurveUsesProvidedEffectiveHalfLife() throws {
        let spect = makeVolume(pixels: [10, 0], modality: "NM")
        let point = try Lu177DosimetryTimePoint(activityVolume: spect, hoursPostAdministration: 24)
        let model = try Lu177SingleTimePointModel(effectiveHalfLifeHours: 72)

        let curves = try Lu177DosimetryEngine.createDosimetryCurves(
            timePoints: [point],
            singleTimePointModel: model
        )

        let curve = try XCTUnwrap(curves.first)
        let lambda = Foundation.log(2.0) / 72
        let expectedTIA = 10 * Foundation.exp(lambda * 24) / lambda
        XCTAssertEqual(curve.acquisitionMode, .singleTimePoint)
        XCTAssertEqual(curve.effectiveHalfLifeHours ?? 0, 72, accuracy: 1e-8)
        XCTAssertEqual(curve.timeIntegratedActivityBqHours, expectedTIA, accuracy: expectedTIA * 1e-8)
        XCTAssertTrue(curve.warnings.contains { $0.contains("Single-time-point curve uses") })
    }

    func testMonteCarloDoseTransportSpreadsDoseBeyondSourceVoxel() throws {
        var tia = [Float](repeating: 0, count: 5 * 5 * 5)
        let centerIndex = 2 * 5 * 5 + 2 * 5 + 2
        tia[centerIndex] = 10_000
        let density = [Float](repeating: 1, count: tia.count)
        let reference = makeVolume(
            pixels: [Float](repeating: 0, count: tia.count),
            modality: "NM",
            depth: 5,
            height: 5,
            width: 5,
            spacing: (1, 1, 1)
        )
        let localModel = try Lu177DoseModel(meanEnergyMeVPerDecay: 1)
        let monteCarloOptions = try Lu177MonteCarloOptions(
            historiesPerSourceVoxel: 4_000,
            maxTotalHistories: 4_000,
            maximumBetaRangeMM: 2.8,
            meanBetaPathLengthMM: 1.4,
            stepLengthMM: 0.5,
            randomSeed: 42
        )
        let monteCarloModel = try Lu177DoseModel(
            name: "Test Monte Carlo",
            calculationMethod: .monteCarloBetaTransport,
            meanEnergyMeVPerDecay: 1,
            monteCarloOptions: monteCarloOptions
        )

        let local = Lu177DosimetryEngine.absorbedDosePixels(
            timeIntegratedActivityBqHoursPerML: tia,
            densityGPerML: density,
            doseModel: localModel,
            referenceVolume: reference
        )
        let monteCarlo = Lu177DosimetryEngine.absorbedDosePixels(
            timeIntegratedActivityBqHoursPerML: tia,
            densityGPerML: density,
            doseModel: monteCarloModel,
            referenceVolume: reference
        )

        let neighborIndices = [
            centerIndex - 1,
            centerIndex + 1,
            centerIndex - 5,
            centerIndex + 5,
            centerIndex - 25,
            centerIndex + 25
        ]
        let neighborDose = neighborIndices.reduce(Float(0)) { $0 + monteCarlo[$1] }
        XCTAssertEqual(local.filter { $0 > 0 }.count, 1)
        XCTAssertGreaterThan(neighborDose, 0)
        XCTAssertLessThan(monteCarlo[centerIndex], local[centerIndex])
    }

    func testMonteCarloWorkflowLabelsReportAndWarnings() throws {
        var pixels = [Float](repeating: 0, count: 3 * 3 * 3)
        pixels[13] = 100
        let spect0 = makeVolume(pixels: pixels, modality: "NM", depth: 3, height: 3, width: 3, spacing: (1, 1, 1))
        let spect1 = makeVolume(pixels: pixels, modality: "NM", depth: 3, height: 3, width: 3, spacing: (1, 1, 1))
        let points = [
            try Lu177DosimetryTimePoint(activityVolume: spect0, hoursPostAdministration: 0),
            try Lu177DosimetryTimePoint(activityVolume: spect1, hoursPostAdministration: 1)
        ]
        let monteCarloModel = try Lu177DoseModel(
            name: "Lu-177 native MC",
            calculationMethod: .monteCarloBetaTransport,
            monteCarloOptions: try Lu177MonteCarloOptions(
                historiesPerSourceVoxel: 128,
                maxTotalHistories: 128,
                maximumBetaRangeMM: 1.5,
                meanBetaPathLengthMM: 0.75,
                stepLengthMM: 0.5,
                randomSeed: 7
            )
        )
        let options = try Lu177DosimetryOptions(
            tailModel: .noTail,
            doseModel: monteCarloModel
        )

        let result = try Lu177DosimetryEngine.createAbsorbedDoseMap(
            timePoints: points,
            options: options
        )

        XCTAssertEqual(result.report.doseCalculationMethod, .monteCarloBetaTransport)
        XCTAssertEqual(result.report.doseModelName, "Lu-177 native MC")
        XCTAssertTrue(result.report.warnings.contains { $0.contains("native stochastic beta transport") })
        XCTAssertTrue(result.report.warnings.contains { $0.contains("histories/source voxel") })
    }

    func testMonteCarloDoseModelRequiresMonteCarloOptions() {
        XCTAssertThrowsError(try Lu177DoseModel(calculationMethod: .monteCarloBetaTransport)) { error in
            XCTAssertEqual(
                error as? Lu177DosimetryError,
                .invalidInput("Monte Carlo beta transport requires Monte Carlo options.")
            )
        }
    }

    func testCountCalibrationConvertsSpectCountsToActivityConcentration() throws {
        let calibration = try Lu177SPECTCalibration(
            bqPerMLPerCount: 2,
            backgroundCounts: 10
        )
        let spect = makeVolume(pixels: [10, 15, 20], modality: "NM")
        let point = try Lu177DosimetryTimePoint(
            activityVolume: spect,
            hoursPostAdministration: 24,
            inputUnit: .counts,
            calibration: calibration
        )

        XCTAssertEqual(try point.activityConcentrationPixels(), [0, 10, 20])
    }

    func testMonoExponentialTailFitsVoxelClearanceAndFallsBackToPhysicalWhenSlower() throws {
        let fast0 = [Float(8), Float(4)]
        let fast1 = [Float(4), Float(4)]
        let points = [
            try Lu177DosimetryTimePoint(activityVolume: makeVolume(pixels: fast0, modality: "NM"), hoursPostAdministration: 0),
            try Lu177DosimetryTimePoint(activityVolume: makeVolume(pixels: fast1, modality: "NM"), hoursPostAdministration: 1)
        ]
        let options = try Lu177DosimetryOptions(
            physicalHalfLifeHours: 10,
            tailModel: .monoExponentialFitWithPhysicalFallback
        )

        let tia = Lu177DosimetryEngine.integrateActivityConcentration(
            activities: try points.map { try $0.activityConcentrationPixels() },
            timesHours: points.map(\.hoursPostAdministration),
            options: options
        )

        let fittedFastTail = 4 / Foundation.log(2.0)
        XCTAssertEqual(Double(tia[0]), 6 + fittedFastTail, accuracy: 1e-4)
        let physicalTail = 4 / (Foundation.log(2.0) / 10)
        XCTAssertEqual(Double(tia[1]), 4 + physicalTail, accuracy: 1e-4)
    }

    func testDoseReportIncludesVOISummariesFromLabelMap() throws {
        let spect0 = makeVolume(pixels: [1, 2, 3, 4], modality: "NM", height: 2, width: 2)
        let spect1 = makeVolume(pixels: [1, 2, 3, 4], modality: "NM", height: 2, width: 2)
        let labelMap = LabelMap(parentSeriesUID: spect0.seriesUID, depth: 1, height: 2, width: 2)
        labelMap.classes = [
            LabelClass(labelID: 1, name: "Kidney", category: .organ, color: .red),
            LabelClass(labelID: 2, name: "Tumor", category: .tumor, color: .yellow)
        ]
        labelMap.voxels = [1, 1, 2, 0]
        let points = [
            try Lu177DosimetryTimePoint(activityVolume: spect0, hoursPostAdministration: 0),
            try Lu177DosimetryTimePoint(activityVolume: spect1, hoursPostAdministration: 1)
        ]
        let options = try Lu177DosimetryOptions(
            tailModel: .noTail,
            doseModel: try Lu177DoseModel(meanEnergyMeVPerDecay: 1)
        )

        let result = try Lu177DosimetryEngine.createAbsorbedDoseMap(
            timePoints: points,
            labelMap: labelMap,
            options: options
        )

        XCTAssertEqual(result.report.voiSummaries.count, 2)
        XCTAssertEqual(result.report.voiSummaries[0].className, "Kidney")
        XCTAssertEqual(result.report.voiSummaries[0].voxelCount, 2)
        XCTAssertEqual(result.report.voiSummaries[0].volumeML, 2)
        XCTAssertEqual(result.report.voiSummaries[1].className, "Tumor")
        XCTAssertEqual(result.report.voiSummaries[1].voxelCount, 1)
    }

    func testCumulativeTherapyDoseScalesReferenceDoseForFourCycles() throws {
        let spect0 = makeVolume(pixels: [2, 4], modality: "NM")
        let spect1 = makeVolume(pixels: [2, 4], modality: "NM")
        let reference = try Lu177DosimetryEngine.createAbsorbedDoseMap(
            timePoints: [
                try Lu177DosimetryTimePoint(activityVolume: spect0, hoursPostAdministration: 0),
                try Lu177DosimetryTimePoint(activityVolume: spect1, hoursPostAdministration: 1)
            ],
            options: try Lu177DosimetryOptions(
                tailModel: .noTail,
                doseModel: try Lu177DoseModel(meanEnergyMeVPerDecay: 1)
            )
        )

        let cumulative = try Lu177DosimetryEngine.cumulativeTherapyDose(
            referenceResult: reference,
            cycleCount: 4
        )

        XCTAssertEqual(cumulative.cycleCount, 4)
        XCTAssertEqual(cumulative.totalRelativeDoseScale, 4)
        XCTAssertEqual(
            Double(cumulative.cumulativeDoseMapGy.pixels[0]),
            Double(reference.absorbedDoseMapGy.pixels[0]) * 4,
            accuracy: Double(reference.absorbedDoseMapGy.pixels[0]) * 1e-5
        )
        XCTAssertEqual(cumulative.meanDoseGy, reference.report.meanDoseGy * 4, accuracy: reference.report.meanDoseGy * 1e-5)
    }

    func testCumulativeTherapyDoseUsesAdministeredActivityScalesForSixCycles() throws {
        let spect0 = makeVolume(pixels: [1], modality: "NM")
        let spect1 = makeVolume(pixels: [1], modality: "NM")
        let reference = try Lu177DosimetryEngine.createAbsorbedDoseMap(
            timePoints: [
                try Lu177DosimetryTimePoint(activityVolume: spect0, hoursPostAdministration: 0),
                try Lu177DosimetryTimePoint(activityVolume: spect1, hoursPostAdministration: 1)
            ],
            options: try Lu177DosimetryOptions(tailModel: .noTail)
        )

        let cumulative = try Lu177DosimetryEngine.cumulativeTherapyDose(
            referenceResult: reference,
            administeredActivitiesGBq: [7.4, 7.4, 3.7, 7.4, 3.7, 7.4]
        )

        XCTAssertEqual(cumulative.cycleCount, 6)
        XCTAssertEqual(cumulative.totalRelativeDoseScale, 5, accuracy: 1e-8)
        XCTAssertEqual(cumulative.cycles[2].relativeDoseScale, 0.5, accuracy: 1e-8)
        XCTAssertEqual(
            Double(cumulative.cumulativeDoseMapGy.pixels[0]),
            Double(reference.absorbedDoseMapGy.pixels[0]) * 5,
            accuracy: Double(reference.absorbedDoseMapGy.pixels[0]) * 1e-5
        )
        XCTAssertTrue(cumulative.warnings.contains { $0.contains("same biodistribution") })
    }

    func testGridMismatchThrowsBeforeDoseComputation() throws {
        let reference = makeVolume(pixels: [1, 2], modality: "NM", spacing: (10, 10, 10))
        let shifted = makeVolume(pixels: [1, 2], modality: "NM", spacing: (10, 10, 10), origin: (1, 0, 0))
        let points = [
            try Lu177DosimetryTimePoint(activityVolume: reference, hoursPostAdministration: 0),
            try Lu177DosimetryTimePoint(activityVolume: shifted, hoursPostAdministration: 1)
        ]

        XCTAssertThrowsError(try Lu177DosimetryEngine.createAbsorbedDoseMap(timePoints: points)) { error in
            guard case Lu177DosimetryError.gridMismatch(let message) = error else {
                return XCTFail("Expected grid mismatch, got \(error)")
            }
            XCTAssertTrue(message.contains("spacing/origin"))
        }
    }

    private func makeVolume(pixels: [Float],
                            modality: String,
                            depth: Int = 1,
                            height: Int = 1,
                            width: Int? = nil,
                            spacing: (Double, Double, Double) = (10, 10, 10),
                            origin: (Double, Double, Double) = (0, 0, 0)) -> ImageVolume {
        let resolvedWidth = width ?? pixels.count
        return ImageVolume(
            pixels: pixels,
            depth: depth,
            height: height,
            width: resolvedWidth,
            spacing: spacing,
            origin: origin,
            modality: modality,
            seriesUID: UUID().uuidString,
            studyUID: "study",
            patientID: "patient"
        )
    }
}
