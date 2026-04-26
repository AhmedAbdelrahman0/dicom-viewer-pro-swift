import XCTest
@testable import Tracer

final class NuclearReconstructionTests: XCTestCase {
    func testForwardProjectionOfCenteredPointUsesDetectorCenter() throws {
        let geometry = try ParallelBeamGeometry(
            detectorCount: 9,
            anglesRadians: [0, Double.pi / 2],
            detectorSpacingMM: 1
        )
        let grid = try ReconstructionGrid2D(width: 5, height: 5, pixelSpacingMM: 1)
        var pixels = [Float](repeating: 0, count: grid.voxelCount)
        pixels[2 * grid.width + 2] = 7
        let image = try ReconstructionImage2D(grid: grid, modality: .pet, pixels: pixels)

        let sinogram = try NuclearReconstructor.forwardProject(image: image, geometry: geometry)

        XCTAssertEqual(sinogram.value(angleIndex: 0, detectorIndex: 4), 7, accuracy: 1e-5)
        XCTAssertEqual(sinogram.value(angleIndex: 1, detectorIndex: 4), 7, accuracy: 1e-5)
        XCTAssertEqual(sinogram.bins.reduce(0, +), 14, accuracy: 1e-5)
    }

    func testMLEMReconstructionKeepsPointSourcePositiveAndCentered() throws {
        let geometry = try ParallelBeamGeometry(
            detectorCount: 11,
            anglesRadians: stride(from: 0.0, to: Double.pi, by: Double.pi / 12).map { $0 },
            detectorSpacingMM: 1
        )
        let grid = try ReconstructionGrid2D(width: 7, height: 7, pixelSpacingMM: 1)
        var pixels = [Float](repeating: 0, count: grid.voxelCount)
        let centerIndex = 3 * grid.width + 3
        pixels[centerIndex] = 10
        let image = try ReconstructionImage2D(grid: grid, modality: .pet, pixels: pixels)
        let sinogram = try NuclearReconstructor.forwardProject(image: image, geometry: geometry)
        let options = try ReconstructionOptions(algorithm: .mlem, iterations: 6)

        let reconstruction = try NuclearReconstructor.reconstruct2D(
            sinogram: sinogram,
            grid: grid,
            options: options
        )

        let maxIndex = try XCTUnwrap(reconstruction.pixels.indices.max { lhs, rhs in
            reconstruction.pixels[lhs] < reconstruction.pixels[rhs]
        })
        XCTAssertEqual(maxIndex, centerIndex)
        XCTAssertTrue(reconstruction.pixels.allSatisfy { $0 >= 0 && $0.isFinite })
    }

    func testFilteredBackProjectionProducesFiniteImage() throws {
        let geometry = try ParallelBeamGeometry(
            detectorCount: 9,
            anglesRadians: stride(from: 0.0, to: Double.pi, by: Double.pi / 8).map { $0 },
            detectorSpacingMM: 1
        )
        let grid = try ReconstructionGrid2D(width: 5, height: 5, pixelSpacingMM: 1)
        var pixels = [Float](repeating: 0, count: grid.voxelCount)
        pixels[2 * grid.width + 2] = 5
        let image = try ReconstructionImage2D(grid: grid, modality: .spect, pixels: pixels)
        let sinogram = try NuclearReconstructor.forwardProject(image: image, geometry: geometry)
        let options = try ReconstructionOptions(algorithm: .filteredBackProjection)

        let reconstruction = try NuclearReconstructor.reconstruct2D(
            sinogram: sinogram,
            grid: grid,
            options: options
        )

        XCTAssertEqual(reconstruction.pixels.count, grid.voxelCount)
        XCTAssertTrue(reconstruction.pixels.allSatisfy(\.isFinite))
        XCTAssertEqual(reconstruction.modality, .spect)
    }

    func testRawFloat32SinogramLoaderReadsLittleEndianData() throws {
        let geometry = try ParallelBeamGeometry(
            detectorCount: 2,
            anglesRadians: [0, Double.pi / 2],
            detectorSpacingMM: 4
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sino")
        var data = Data()
        for value in [Float(1.25), Float(2.5), Float(3.75), Float(5)] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let sinogram = try SinogramIO.loadRawFloat32(
            url: url,
            geometry: geometry,
            modality: .pet,
            endian: .little
        )

        XCTAssertEqual(sinogram.bins, [1.25, 2.5, 3.75, 5])
    }

    func testRawFloat32SinogramLoaderRejectsWrongLength() throws {
        let geometry = try ParallelBeamGeometry(
            detectorCount: 2,
            anglesRadians: [0, Double.pi / 2],
            detectorSpacingMM: 4
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sino")
        try Data([0, 1, 2]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try SinogramIO.loadRawFloat32(
            url: url,
            geometry: geometry,
            modality: .pet
        )) { error in
            XCTAssertEqual(
                error as? ReconstructionError,
                .invalidSinogram("Raw sinogram has 3 bytes, expected 16.")
            )
        }
    }

    func testReconstructionImageConvertsToImageVolumeWithGeometry() throws {
        let grid = try ReconstructionGrid2D(width: 3, height: 2, pixelSpacingMM: 2)
        let image = try ReconstructionImage2D(
            grid: grid,
            modality: .pet,
            pixels: [0, 1, 2, 3, 4, 5]
        )

        let volume = try image.asImageVolume(sliceThicknessMM: 4)

        XCTAssertEqual(volume.depth, 1)
        XCTAssertEqual(volume.width, 3)
        XCTAssertEqual(volume.height, 2)
        XCTAssertEqual(volume.spacing.x, 2)
        XCTAssertEqual(volume.spacing.y, 2)
        XCTAssertEqual(volume.spacing.z, 4)
        XCTAssertEqual(volume.modality, "PT")
    }
}
