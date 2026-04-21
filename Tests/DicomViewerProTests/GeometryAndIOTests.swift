import XCTest
import simd
@testable import DicomViewerPro
#if canImport(MetalKit)
import MetalKit
#endif

final class GeometryAndIOTests: XCTestCase {
    func testVolumeWorldVoxelRoundTripUsesDirection() {
        let direction = simd_double3x3(
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 0, 1)
        )
        let volume = ImageVolume(
            pixels: [0],
            depth: 1,
            height: 1,
            width: 1,
            spacing: (2, 3, 4),
            origin: (10, 20, 30),
            direction: direction
        )

        let voxel = SIMD3<Double>(2, 3, 4)
        let world = volume.worldPoint(voxel: voxel)
        let roundTrip = volume.voxelCoordinates(from: world)

        XCTAssertEqual(roundTrip.x, voxel.x, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.y, voxel.y, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.z, voxel.z, accuracy: 1e-9)
    }

    func testNIfTILoaderPreservesSFormAsLPSGeometry() throws {
        var data = Data(count: 352)
        data.writeInt32LE(348, at: 0)
        data.writeInt16LE(3, at: 40)
        data.writeInt16LE(1, at: 42)
        data.writeInt16LE(1, at: 44)
        data.writeInt16LE(1, at: 46)
        data.writeInt16LE(1, at: 48)
        data.writeInt16LE(16, at: 70)
        data.writeInt16LE(32, at: 72)
        data.writeFloat32LE(1, at: 76)
        data.writeFloat32LE(2, at: 80)
        data.writeFloat32LE(3, at: 84)
        data.writeFloat32LE(4, at: 88)
        data.writeFloat32LE(352, at: 108)
        data.writeFloat32LE(1, at: 112)
        data.writeInt16LE(2, at: 254)
        data.writeFloat32LE(2, at: 280)
        data.writeFloat32LE(10, at: 292)
        data.writeFloat32LE(3, at: 300)
        data.writeFloat32LE(20, at: 308)
        data.writeFloat32LE(4, at: 320)
        data.writeFloat32LE(30, at: 324)
        data[344] = 0x6E
        data[345] = 0x2B
        data[346] = 0x31
        data[347] = 0x00
        data.appendFloat32LE(42)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).nii")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let volume = try NIfTILoader.load(url)

        XCTAssertEqual(volume.spacing.x, 2, accuracy: 1e-6)
        XCTAssertEqual(volume.spacing.y, 3, accuracy: 1e-6)
        XCTAssertEqual(volume.spacing.z, 4, accuracy: 1e-6)
        XCTAssertEqual(volume.origin.x, -10, accuracy: 1e-6)
        XCTAssertEqual(volume.origin.y, -20, accuracy: 1e-6)
        XCTAssertEqual(volume.origin.z, 30, accuracy: 1e-6)
        XCTAssertEqual(volume.direction[0].x, -1, accuracy: 1e-6)
        XCTAssertEqual(volume.direction[1].y, -1, accuracy: 1e-6)
        XCTAssertEqual(volume.direction[2].z, 1, accuracy: 1e-6)
        XCTAssertEqual(volume.pixels[0], 42, accuracy: 1e-6)
    }

    func testCompressedDICOMTransferSyntaxFailsBeforePixelRead() {
        let dcm = DICOMFile()
        dcm.rows = 1
        dcm.columns = 1
        dcm.transferSyntaxUID = "1.2.840.10008.1.2.4.50"
        dcm.pixelDataLength = 128
        dcm.filePath = "/does/not/exist.dcm"

        XCTAssertThrowsError(try DICOMLoader.loadSeries([dcm])) { error in
            guard case DICOMError.unsupportedTransferSyntax(let uid) = error else {
                return XCTFail("Expected unsupported transfer syntax, got \(error)")
            }
            XCTAssertEqual(uid, "1.2.840.10008.1.2.4.50")
        }
    }

    func testPACSIndexBuilderCreatesDICOMSearchableSnapshot() {
        let dcm = DICOMFile()
        dcm.filePath = "/tmp/series/image001.dcm"
        let series = DICOMSeries(
            uid: "1.2.3",
            modality: "CT",
            description: "Chest CT",
            patientID: "MRN123",
            patientName: "Test Patient",
            studyUID: "9.8.7",
            studyDescription: "Trauma",
            studyDate: "20260421",
            files: [dcm]
        )

        let record = PACSIndexBuilder.record(
            for: series,
            sourcePath: "/tmp/series",
            indexedAt: Date(timeIntervalSince1970: 0)
        )
        let snapshot = record.snapshot

        XCTAssertEqual(record.id, "dicom:1.2.3")
        XCTAssertEqual(record.kind, .dicom)
        XCTAssertTrue(record.searchableText.contains("Chest CT"))
        XCTAssertEqual(snapshot.filePaths, ["/tmp/series/image001.dcm"])
        XCTAssertEqual(snapshot.displayName, "CT - Chest CT")
    }

    func testAssistantCommandInterpreterExtractsViewerActions() {
        let actions = AssistantCommandInterpreter().actions(
            for: "Show lungs, switch to distance measurement, axial 42"
        )

        XCTAssertTrue(actions.contains(.applyWindowPreset("Lung")))
        XCTAssertTrue(actions.contains(.setViewerTool(.distance)))
        XCTAssertTrue(actions.contains(.setSlice(axis: 2, index: 42)))
    }

    func testAssistantCommandInterpreterExtractsSegmentationActions() {
        let actions = AssistantCommandInterpreter().actions(
            for: "Create label map with TotalSegmentator, select liver, threshold SUV 2.5"
        )

        XCTAssertTrue(actions.contains(.createLabelMap("TotalSegmentator")))
        XCTAssertTrue(actions.contains(.applyLabelPreset("TotalSegmentator")))
        XCTAssertTrue(actions.contains(.selectLabel("liver")))
        XCTAssertTrue(actions.contains(.setLabelingTool(.threshold)))
        XCTAssertTrue(actions.contains(.threshold(2.5)))
    }

    func testAssistantCommandInterpreterExtractsSUVCalculationActions() {
        let actions = AssistantCommandInterpreter().actions(
            for: "Use SUVbw from kBq/mL, patient weight 70 kg, injected dose 350 MBq"
        )

        XCTAssertTrue(actions.contains(.setSUVMode(.bodyWeight)))
        XCTAssertTrue(actions.contains(.setSUVActivityUnit(.kbqml)))
        XCTAssertTrue(actions.contains(.setSUVPatientWeight(70)))
        XCTAssertTrue(actions.contains(.setSUVInjectedDose(350)))
    }

    @MainActor
    func testAssistantCanUpdateSUVCalculationSettings() {
        let vm = ViewerViewModel()
        let report = vm.performAssistantCommand(
            "Use SUVbw from kBq/mL, patient weight 70 kg, injected dose 350 MBq"
        )

        XCTAssertTrue(report.didApplyActions)
        XCTAssertEqual(vm.suvSettings.mode, .bodyWeight)
        XCTAssertEqual(vm.suvSettings.activityUnit, .kbqml)
        XCTAssertEqual(vm.suvSettings.patientWeightKg, 70, accuracy: 1e-9)
        XCTAssertEqual(vm.suvSettings.injectedDoseMBq, 350, accuracy: 1e-9)
        XCTAssertEqual(vm.suvValue(rawStoredValue: 5), 1.0, accuracy: 1e-9)
    }

    func testSUVCalculationModesSupportClinicalInputs() {
        var settings = SUVCalculationSettings()
        XCTAssertEqual(settings.suv(forStoredValue: 4.2), 4.2, accuracy: 1e-9)

        settings.mode = .manualScale
        settings.manualScaleFactor = 0.01
        XCTAssertEqual(settings.suv(forStoredValue: 420), 4.2, accuracy: 1e-9)

        settings.mode = .bodyWeight
        settings.activityUnit = .kbqml
        settings.patientWeightKg = 70
        settings.injectedDoseMBq = 350
        settings.residualDoseMBq = 0
        XCTAssertEqual(settings.suv(forStoredValue: 5), 1.0, accuracy: 1e-9)
    }

    func testRegionStatsUseSUVTransformForLabelMap() {
        let volume = ImageVolume(
            pixels: [1, 2, 4, 8],
            depth: 1,
            height: 2,
            width: 2,
            spacing: (1, 1, 10),
            modality: "PT"
        )
        let map = LabelMap(parentSeriesUID: volume.seriesUID, depth: 1, height: 2, width: 2)
        map.setValue(1, z: 0, y: 0, x: 1)
        map.setValue(1, z: 0, y: 1, x: 1)

        let stats = RegionStats.compute(volume, map, classID: 1) { raw in
            raw * 2
        }

        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.mean, 5, accuracy: 1e-9)
        XCTAssertEqual(stats.max, 8, accuracy: 1e-9)
        XCTAssertEqual(stats.suvMax ?? 0, 16, accuracy: 1e-9)
        XCTAssertEqual(stats.suvMean ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(stats.tlg ?? 0, 0.2, accuracy: 1e-9)
    }

    func testPETSegmentationThresholdUsesSUVTransform() {
        let volume = ImageVolume(
            pixels: [1, 2, 3, 4],
            depth: 1,
            height: 2,
            width: 2,
            modality: "PT"
        )
        let map = LabelMap(parentSeriesUID: volume.seriesUID, depth: 1, height: 2, width: 2)

        let count = PETSegmentation.thresholdAbove(
            volume: volume,
            label: map,
            threshold: 5,
            classID: 1,
            valueTransform: { $0 * 2 }
        )

        XCTAssertEqual(count, 2)
        XCTAssertEqual(map.voxelCounts()[1], 2)
    }

    @MainActor
    func testSUVThresholdUsesPETOverlayForCTLabelMap() {
        let ct = ImageVolume(
            pixels: [0, 0, 0, 0],
            depth: 1,
            height: 2,
            width: 2,
            modality: "CT"
        )
        let pet = ImageVolume(
            pixels: [1, 2, 3, 4],
            depth: 1,
            height: 2,
            width: 2,
            modality: "PT"
        )
        let vm = ViewerViewModel()
        vm.currentVolume = ct
        let pair = FusionPair(base: ct, overlay: pet)
        pair.resampledOverlay = pet
        vm.fusion = pair
        vm.suvSettings.mode = .manualScale
        vm.suvSettings.manualScaleFactor = 2
        let map = vm.labeling.createLabelMap(for: ct)

        vm.thresholdActiveLabel(atOrAbove: 5)

        XCTAssertEqual(map.voxelCounts()[1], 2)
        XCTAssertTrue(vm.statusMessage.contains("SUV"))
    }

    #if canImport(MetalKit)
    func testMetalVolumeRendererBuildsPipelineWhenMetalIsAvailable() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable in this test environment")
        }

        let renderer = MetalVolumeRenderer()
        XCTAssertTrue(renderer.isReady)
    }

    func testVolumeTexturePayloadDownsamplesAndKeepsPhysicalExtent() {
        let volume = ImageVolume(
            pixels: Array(0..<64).map(Float.init),
            depth: 4,
            height: 4,
            width: 4,
            spacing: (2, 1, 1)
        )

        let payload = VolumeTexturePayload.make(from: volume, maxDimension: 2)

        XCTAssertEqual(payload.width, 2)
        XCTAssertEqual(payload.height, 2)
        XCTAssertEqual(payload.depth, 2)
        XCTAssertEqual(payload.pixels.count, 8)
        XCTAssertEqual(payload.extent.x, 1, accuracy: 1e-6)
        XCTAssertEqual(payload.extent.y, 0.5, accuracy: 1e-6)
        XCTAssertEqual(payload.extent.z, 0.5, accuracy: 1e-6)
    }
    #endif

    func testVolumeResamplerPreservesValuesWhenGeometryMatches() {
        let overlay = ImageVolume(
            pixels: Array(0..<8).map(Float.init),
            depth: 2,
            height: 2,
            width: 2,
            spacing: (1, 1, 1),
            origin: (0, 0, 0),
            modality: "PT"
        )
        let base = ImageVolume(
            pixels: Array(repeating: 0, count: 8),
            depth: 2,
            height: 2,
            width: 2,
            spacing: (1, 1, 1),
            origin: (0, 0, 0),
            modality: "CT"
        )

        let resampled = VolumeResampler.resample(overlay: overlay, toMatch: base)

        XCTAssertEqual(resampled.pixels, overlay.pixels)
        XCTAssertEqual(resampled.modality, "PT")
        XCTAssertEqual(resampled.width, base.width)
        XCTAssertEqual(resampled.height, base.height)
        XCTAssertEqual(resampled.depth, base.depth)
    }

    func testVolumeResamplerUsesWorldGeometry() {
        let overlay = ImageVolume(
            pixels: [
                0, 10, 20,
                0, 10, 20,
                0, 10, 20
            ],
            depth: 1,
            height: 3,
            width: 3,
            spacing: (1, 1, 1),
            origin: (0, 0, 0),
            modality: "PT"
        )
        let base = ImageVolume(
            pixels: [0],
            depth: 1,
            height: 1,
            width: 1,
            spacing: (1, 1, 1),
            origin: (2, 1, 0),
            modality: "CT"
        )

        let resampled = VolumeResampler.resample(overlay: overlay, toMatch: base)

        XCTAssertEqual(resampled.pixels[0], 20, accuracy: 1e-6)
        XCTAssertEqual(resampled.origin.x, 2, accuracy: 1e-6)
        XCTAssertEqual(resampled.origin.y, 1, accuracy: 1e-6)
    }
}

private extension Data {
    mutating func writeInt16LE(_ value: Int16, at offset: Int) {
        writeUInt16LE(UInt16(bitPattern: value), at: offset)
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func writeInt32LE(_ value: Int32, at offset: Int) {
        writeUInt32LE(UInt32(bitPattern: value), at: offset)
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    mutating func writeFloat32LE(_ value: Float, at offset: Int) {
        writeUInt32LE(value.bitPattern, at: offset)
    }

    mutating func appendFloat32LE(_ value: Float) {
        var bytes = Data(count: 4)
        bytes.writeFloat32LE(value, at: 0)
        append(bytes)
    }
}
