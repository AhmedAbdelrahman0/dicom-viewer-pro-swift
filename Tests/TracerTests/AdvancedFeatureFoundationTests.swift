import XCTest
@testable import Tracer

final class AdvancedFeatureFoundationTests: XCTestCase {
    func testDICOMDecompressorDetectsCompressedTransferSyntax() {
        let dcm = DICOMFile()
        dcm.transferSyntaxUID = "1.2.840.10008.1.2.1"
        dcm.pixelDataUndefinedLength = false
        XCTAssertFalse(DICOMDecompressor.needsDecompression(dcm))

        dcm.transferSyntaxUID = "1.2.840.10008.1.2.4.90"
        XCTAssertTrue(DICOMDecompressor.needsDecompression(dcm))

        dcm.transferSyntaxUID = "1.2.840.10008.1.2.1"
        dcm.pixelDataUndefinedLength = true
        XCTAssertTrue(DICOMDecompressor.needsDecompression(dcm))
    }

    func testDICOMDecompressorComposesToolArguments() {
        let source = URL(fileURLWithPath: "/tmp/in.dcm")
        let destination = URL(fileURLWithPath: "/tmp/out.dcm")

        let gdcm = DICOMDecompressor.command(tool: .gdcmconv,
                                             executablePath: "/opt/homebrew/bin/gdcmconv",
                                             source: source,
                                             destination: destination)
        XCTAssertEqual(gdcm.arguments, ["--raw", "/tmp/in.dcm", "/tmp/out.dcm"])

        let dcmtk = DICOMDecompressor.command(tool: .dcmconv,
                                              executablePath: "/usr/local/bin/dcmconv",
                                              source: source,
                                              destination: destination)
        XCTAssertEqual(dcmtk.arguments, ["+te", "/tmp/in.dcm", "/tmp/out.dcm"])
    }

    func testSimpleITKBridgeBuildsWorkerArguments() {
        let config = SimpleITKBridgeConfiguration(pythonExecutablePath: "/usr/bin/env")
        let request = SimpleITKBridgeRequest(
            operation: .resampleToReference,
            inputURL: URL(fileURLWithPath: "/tmp/in.nii"),
            outputURL: URL(fileURLWithPath: "/tmp/out.nii"),
            referenceURL: URL(fileURLWithPath: "/tmp/ref.nii"),
            spacing: (1.0, 1.0, 2.0),
            iterations: 12,
            interpolator: .nearest
        )

        let args = config.workerArguments(scriptPath: "/repo/workers/simpleitk/bridge.py",
                                          request: request,
                                          outputJSONPath: "/tmp/result.json")

        XCTAssertEqual(args.prefix(2), ["python3", "/repo/workers/simpleitk/bridge.py"])
        XCTAssertTrue(args.contains("resample-to-reference"))
        XCTAssertTrue(args.contains("/tmp/ref.nii"))
        XCTAssertTrue(args.contains("1.0,1.0,2.0"))
        XCTAssertTrue(args.contains("nearest"))
        XCTAssertTrue(args.contains("/tmp/result.json"))
    }

    func testVolumeWorkerRunsActiveContourOperation() {
        let volume = sphereVolume(size: 7, foreground: 10)
        let input = VolumeLabelOperationInput(
            mapID: UUID(),
            mapName: "Snake",
            classes: [LabelClass(labelID: 1, name: "Snake", category: .organ, color: .green)],
            startingVoxels: [UInt16](repeating: 0, count: volume.pixels.count),
            volume: volume,
            classID: 1,
            usesSUV: false,
            suvSettings: SUVCalculationSettings(),
            operation: .activeContour(
                seed: (z: 3, y: 3, x: 3),
                radius: 2,
                speed: .regionCompetition(midpoint: 5, halfWidth: 1),
                parameters: LevelSetSegmentation.Parameters(iterations: 8)
            ),
            diffLimit: 10_000
        )

        let result = VolumeOperationWorker.runLabelOperation(input)

        XCTAssertNotNil(result.levelSet)
        XCTAssertGreaterThan(result.voxelCount, 0)
        XCTAssertTrue(result.voxels.contains(1))
    }

    @MainActor
    func testLabelingViewModelExportsActiveMesh() throws {
        let volume = ImageVolume(
            pixels: [Float](repeating: 0, count: 27),
            depth: 3,
            height: 3,
            width: 3
        )
        let vm = LabelingViewModel()
        let map = vm.createLabelMap(for: volume, name: "Cube")
        map.classes = [LabelClass(labelID: 1, name: "Cube", category: .organ, color: .green)]
        vm.activeClassID = 1
        for z in 0...1 {
            for y in 0...1 {
                for x in 0...1 {
                    map.setValue(1, z: z, y: y, x: x)
                }
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-mesh-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cube.stl")

        let mesh = try XCTUnwrap(vm.exportActiveMesh(to: url,
                                                     format: .stl,
                                                     parentVolume: volume,
                                                     smoothingIterations: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertGreaterThan(mesh.triangleCount, 0)
    }

    func testLabelingToolIncludesActiveContour() {
        XCTAssertTrue(LabelingTool.allCases.contains(.activeContour))
        XCTAssertEqual(LabelingTool.activeContour.displayName, "Snake")
        XCTAssertFalse(LabelingTool.activeContour.helpText.isEmpty)
    }

    private func sphereVolume(size: Int, foreground: Float) -> ImageVolume {
        let center = size / 2
        var pixels = [Float](repeating: 0, count: size * size * size)
        for z in 0..<size {
            for y in 0..<size {
                for x in 0..<size {
                    let dz = z - center
                    let dy = y - center
                    let dx = x - center
                    if dx * dx + dy * dy + dz * dz <= 9 {
                        pixels[z * size * size + y * size + x] = foreground
                    }
                }
            }
        }
        return ImageVolume(pixels: pixels,
                           depth: size,
                           height: size,
                           width: size,
                           modality: "MR")
    }
}
