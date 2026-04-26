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
