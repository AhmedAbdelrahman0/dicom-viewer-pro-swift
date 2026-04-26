import XCTest
import simd
@testable import Tracer

final class SyntheticCTTests: XCTestCase {
    func testSyntheticCTHeuristicPreservesGeometryAndCreatesCTVolume() throws {
        let direction = simd_double3x3(
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 0, 1)
        )
        let pet = ImageVolume(
            pixels: [0, 2, 8, 12, 1, 0, 0, 4],
            depth: 2,
            height: 2,
            width: 2,
            spacing: (2, 3, 4),
            origin: (10, 20, 30),
            direction: direction,
            modality: "PT",
            studyUID: "study",
            patientID: "patient",
            patientName: "name",
            seriesDescription: "PET",
            studyDescription: "Study"
        )
        let options = try SyntheticCTOptions(smoothingRadiusVoxels: 0)

        let result = try SyntheticCTGenerator.generate(from: pet, options: options)

        XCTAssertEqual(result.volume.modality, "CT")
        XCTAssertEqual(result.volume.depth, pet.depth)
        XCTAssertEqual(result.volume.height, pet.height)
        XCTAssertEqual(result.volume.width, pet.width)
        XCTAssertEqual(result.volume.spacing.x, pet.spacing.x)
        XCTAssertEqual(result.volume.spacing.y, pet.spacing.y)
        XCTAssertEqual(result.volume.spacing.z, pet.spacing.z)
        XCTAssertEqual(result.volume.origin.x, pet.origin.x)
        XCTAssertEqual(result.volume.origin.y, pet.origin.y)
        XCTAssertEqual(result.volume.origin.z, pet.origin.z)
        XCTAssertEqual(result.volume.direction, pet.direction)
        XCTAssertEqual(result.volume.studyUID, "study")
        XCTAssertEqual(result.report.dimensions, SyntheticCTDimensions(width: 2, height: 2, depth: 2))
        XCTAssertEqual(result.report.bodyVoxelCount, 5)
        XCTAssertNotNil(result.report.warning)
    }

    func testSyntheticCTHeuristicUsesVolumeAwareSUVScaling() throws {
        let pet = ImageVolume(
            pixels: [0, 1, 5],
            depth: 1,
            height: 1,
            width: 3,
            modality: "PT",
            suvScaleFactor: 2
        )
        var suvSettings = SUVCalculationSettings()
        suvSettings.mode = .storedSUV
        let options = try SyntheticCTOptions(
            bodySUVThreshold: 1.5,
            intenseUptakeSUV: 10,
            smoothingRadiusVoxels: 0
        )

        let result = try SyntheticCTGenerator.generate(
            from: pet,
            suvSettings: suvSettings,
            options: options
        )

        XCTAssertEqual(result.volume.pixels[0], -1_000)
        XCTAssertGreaterThan(result.volume.pixels[1], 35)
        XCTAssertEqual(result.volume.pixels[2], 110, accuracy: 1e-4)
        XCTAssertEqual(result.report.bodyVoxelCount, 2)
    }

    func testSyntheticCTHeuristicKeepsAirOutsideBodyAfterSmoothing() throws {
        let pet = ImageVolume(
            pixels: [0, 0, 0, 0, 8, 0, 0, 0, 0],
            depth: 1,
            height: 3,
            width: 3,
            modality: "PET"
        )
        let options = try SyntheticCTOptions(
            bodySUVThreshold: 1,
            intenseUptakeSUV: 8,
            smoothingRadiusVoxels: 1
        )

        let result = try SyntheticCTGenerator.generate(from: pet, options: options)

        XCTAssertEqual(result.volume.pixels[0], -1_000)
        XCTAssertEqual(result.volume.pixels[1], -1_000)
        XCTAssertEqual(result.volume.pixels[3], -1_000)
        XCTAssertEqual(result.volume.pixels[4], 110, accuracy: 1e-4)
    }

    func testSyntheticCTRejectsNonPETInput() throws {
        let ct = ImageVolume(
            pixels: [0],
            depth: 1,
            height: 1,
            width: 1,
            modality: "CT"
        )

        XCTAssertThrowsError(try SyntheticCTGenerator.generate(from: ct)) { error in
            XCTAssertEqual(
                error as? SyntheticCTError,
                .unsupportedModality("Synthetic CT generation expects PET/PT input, got CT.")
            )
        }
    }

    func testSyntheticCTRejectsModelMethodsWithoutConfiguredRunner() throws {
        let pet = ImageVolume(
            pixels: [1],
            depth: 1,
            height: 1,
            width: 1,
            modality: "PT"
        )
        let options = try SyntheticCTOptions(method: .coreMLModel)

        XCTAssertThrowsError(try SyntheticCTGenerator.generate(from: pet, options: options)) { error in
            XCTAssertEqual(
                error as? SyntheticCTError,
                .invalidOptions("Core ML synthetic CT model requires a configured model runner.")
            )
        }
    }
}
