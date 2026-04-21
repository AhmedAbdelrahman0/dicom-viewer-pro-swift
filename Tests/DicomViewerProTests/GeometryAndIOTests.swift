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
        XCTAssertTrue(record.searchableText.contains("chest ct"))
        XCTAssertEqual(snapshot.filePaths, ["/tmp/series/image001.dcm"])
        XCTAssertEqual(snapshot.displayName, "CT - Chest CT")
    }

    func testPACSDirectoryIndexerDeduplicatesLargeStudyFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacs-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try makeMinimalDICOM(
            patientName: "Alpha^Patient",
            patientID: "MRN-A",
            studyUID: "study-a",
            studyDate: "20260421",
            seriesUID: "series-a",
            seriesDescription: "PET WB",
            modality: "PT",
            sopUID: "sop-a-1"
        ).write(to: root.appendingPathComponent("a1.dcm"))
        try makeMinimalDICOM(
            patientName: "Alpha^Patient",
            patientID: "MRN-A",
            studyUID: "study-a",
            studyDate: "20260421",
            seriesUID: "series-a",
            seriesDescription: "PET WB",
            modality: "PT",
            sopUID: "sop-a-1"
        ).write(to: root.appendingPathComponent("a1-copy.dcm"))
        try makeMinimalDICOM(
            patientName: "Beta^Patient",
            patientID: "MRN-B",
            studyUID: "study-b",
            studyDate: "20260420",
            seriesUID: "series-b",
            seriesDescription: "CT AC",
            modality: "CT",
            sopUID: "sop-b-1"
        ).write(to: root.appendingPathComponent("b1.dcm"))

        let result = PACSDirectoryIndexer.scan(
            url: root,
            headerByteLimit: 4096,
            progressStride: 1
        )

        XCTAssertEqual(result.scannedFiles, 3)
        XCTAssertEqual(result.dicomInstances, 3)
        XCTAssertEqual(result.records.count, 2)
        let alpha = try XCTUnwrap(result.records.first { $0.seriesUID == "series-a" })
        XCTAssertEqual(alpha.instanceCount, 1)
        XCTAssertTrue(alpha.searchableText.contains("alpha"))
        XCTAssertTrue(alpha.filePaths.first?.hasSuffix(".dcm") == true)
    }

    @MainActor
    func testViewerDoesNotAppendDuplicateVolumeIdentity() {
        let vm = ViewerViewModel()
        let first = ImageVolume(
            pixels: [1],
            depth: 1,
            height: 1,
            width: 1,
            modality: "CT",
            seriesUID: "1.2.3",
            sourceFiles: ["/tmp/a/image.dcm"]
        )
        let duplicate = ImageVolume(
            pixels: [2],
            depth: 1,
            height: 1,
            width: 1,
            modality: "CT",
            seriesUID: "1.2.3",
            sourceFiles: ["/tmp/copy/image.dcm"]
        )

        XCTAssertTrue(vm.addLoadedVolumeIfNeeded(first).inserted)
        XCTAssertFalse(vm.addLoadedVolumeIfNeeded(duplicate).inserted)
        XCTAssertEqual(vm.loadedVolumes.count, 1)
        XCTAssertEqual(vm.loadedVolumes.first?.pixels, [1])
    }

    @MainActor
    func testViewerMergesDuplicateDICOMSeriesByUIDAndSOP() {
        let vm = ViewerViewModel()
        let firstFile = DICOMFile()
        firstFile.sopInstanceUID = "1.2.3.4"
        firstFile.filePath = "/tmp/original/image001.dcm"
        let duplicateFile = DICOMFile()
        duplicateFile.sopInstanceUID = "1.2.3.4"
        duplicateFile.filePath = "/tmp/copy/image001.dcm"
        let newFile = DICOMFile()
        newFile.sopInstanceUID = "1.2.3.5"
        newFile.filePath = "/tmp/original/image002.dcm"

        let original = DICOMSeries(
            uid: "series.uid",
            modality: "CT",
            description: "CT",
            patientID: "P1",
            patientName: "Patient",
            studyUID: "study.uid",
            studyDescription: "Study",
            studyDate: "20260421",
            files: [firstFile]
        )
        let duplicate = DICOMSeries(
            uid: "series.uid",
            modality: "CT",
            description: "CT",
            patientID: "P1",
            patientName: "Patient",
            studyUID: "study.uid",
            studyDescription: "Study",
            studyDate: "20260421",
            files: [duplicateFile]
        )
        let update = DICOMSeries(
            uid: "series.uid",
            modality: "CT",
            description: "CT",
            patientID: "P1",
            patientName: "Patient",
            studyUID: "study.uid",
            studyDescription: "Study",
            studyDate: "20260421",
            files: [newFile]
        )

        let firstMerge = vm.mergeScannedSeries([original])
        XCTAssertEqual(firstMerge.added.count, 1)
        XCTAssertEqual(vm.loadedSeries.count, 1)

        let duplicateMerge = vm.mergeScannedSeries([duplicate])
        XCTAssertEqual(duplicateMerge.skipped, 1)
        XCTAssertEqual(vm.loadedSeries.first?.files.count, 1)

        let updateMerge = vm.mergeScannedSeries([update])
        XCTAssertEqual(updateMerge.updated, 1)
        XCTAssertEqual(vm.loadedSeries.first?.files.count, 2)
    }

    @MainActor
    func testViewerLoadNIfTIDoesNotAppendSameFileTwice() async throws {
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
        data.writeFloat32LE(1, at: 80)
        data.writeFloat32LE(1, at: 84)
        data.writeFloat32LE(1, at: 88)
        data.writeFloat32LE(352, at: 108)
        data.writeFloat32LE(1, at: 112)
        data[344] = 0x6E
        data[345] = 0x2B
        data[346] = 0x31
        data[347] = 0x00
        data.appendFloat32LE(7)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-\(UUID().uuidString).nii")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let vm = ViewerViewModel()
        await vm.loadNIfTI(url: url)
        await vm.loadNIfTI(url: url)

        XCTAssertEqual(vm.loadedVolumes.count, 1)
        XCTAssertEqual(vm.currentVolume?.pixels.first, 7)
        XCTAssertEqual(vm.loadedVolumes.first?.sourceFiles, [NIfTILoader.canonicalSourcePath(for: url)])
        XCTAssertTrue(vm.statusMessage.contains("Already loaded"))
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

    func testAssistantCommandInterpreterExtractsSUVGradientActions() {
        let actions = AssistantCommandInterpreter().actions(
            for: "Use PET Edge SUV 2.5 with edge stop 0.75"
        )

        XCTAssertTrue(actions.contains(.setLabelingTool(.suvGradient)))
        XCTAssertTrue(actions.contains(.setGradientMinimumSUV(2.5)))
        XCTAssertTrue(actions.contains(.setGradientEdgeFraction(0.75)))
        XCTAssertFalse(actions.contains(.threshold(2.5)))
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

    func testPETSegmentationGradientEdgeStopsAtSUVDrop() {
        let volume = ImageVolume(
            pixels: [0, 3, 8, 6, 2, 0],
            depth: 1,
            height: 1,
            width: 6,
            modality: "PT"
        )
        let map = LabelMap(parentSeriesUID: volume.seriesUID, depth: 1, height: 1, width: 6)

        let result = PETSegmentation.gradientEdge(
            volume: volume,
            label: map,
            seed: (z: 0, y: 0, x: 2),
            minimumValue: 2.5,
            gradientCutoffFraction: 0.75,
            classID: 1
        )

        XCTAssertEqual(result.voxelCount, 3)
        XCTAssertTrue(result.stoppedAtEdge)
        XCTAssertGreaterThan(result.gradientCutoff, 0)
        XCTAssertEqual(map.voxels, [0, 1, 1, 1, 0, 0])
    }

    func testNRRDLabelmapRoundTripsClassesAndVoxels() throws {
        let volume = ImageVolume(
            pixels: [0, 0, 0, 0],
            depth: 1,
            height: 2,
            width: 2,
            spacing: (2, 3, 4),
            modality: "CT"
        )
        let map = LabelMap(parentSeriesUID: volume.seriesUID, depth: 1, height: 2, width: 2)
        map.classes = [
            LabelClass(labelID: 1, name: "Lesion", category: .lesion, color: .red),
            LabelClass(labelID: 2, name: "Liver", category: .organ, color: .green)
        ]
        map.voxels = [0, 1, 2, 1]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("labels-\(UUID().uuidString).seg.nrrd")
        defer { try? FileManager.default.removeItem(at: url) }

        try LabelIO.saveSlicerSeg(map, to: url, parentVolume: volume)
        let loaded = try LabelIO.loadNRRDLabelmap(from: url, parentVolume: volume)

        XCTAssertEqual(loaded.voxels, map.voxels)
        XCTAssertEqual(loaded.classes.map(\.labelID).sorted(), [1, 2])
        XCTAssertTrue(loaded.classes.contains { $0.name == "Lesion" })
    }

    func testNativeLabelPackageRoundTripsAnnotationsAndLandmarks() throws {
        let volume = ImageVolume(
            pixels: [0, 0, 0, 0],
            depth: 1,
            height: 2,
            width: 2,
            modality: "CT"
        )
        let map = LabelMap(parentSeriesUID: volume.seriesUID, depth: 1, height: 2, width: 2, name: "Case Labels")
        map.classes = [LabelClass(labelID: 1, name: "Tumor", category: .tumor, color: .red)]
        map.voxels = [0, 1, 1, 0]
        var annotation = Annotation(type: .distance, points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], axis: 2, sliceIndex: 0)
        annotation.value = 1.414
        annotation.unit = "mm"
        annotation.label = "caliper"
        let landmark = LandmarkPair(
            fixed: SIMD3<Double>(1, 2, 3),
            moving: SIMD3<Double>(4, 5, 6),
            label: "LM1"
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("labels-\(UUID().uuidString).dvlabels")
        defer { try? FileManager.default.removeItem(at: url) }

        try LabelIO.saveLabelPackage(
            labelMap: map,
            annotations: [annotation],
            landmarks: [landmark],
            parentVolume: volume,
            to: url
        )
        let loaded = try LabelIO.loadLabelPackage(from: url, parentVolume: volume)

        XCTAssertEqual(loaded.labelMap.name, "Case Labels")
        XCTAssertEqual(loaded.labelMap.voxels, map.voxels)
        XCTAssertEqual(loaded.labelMap.classes.first?.name, "Tumor")
        XCTAssertEqual(loaded.annotations.count, 1)
        XCTAssertEqual(loaded.annotations.first?.label, "caliper")
        XCTAssertEqual(loaded.landmarks.first?.label, "LM1")
        XCTAssertEqual(loaded.landmarks.first?.moving.z ?? 0, 6, accuracy: 1e-9)
    }

    @MainActor
    func testLabelUndoRedoRestoresVoxelEdits() {
        let volume = ImageVolume(
            pixels: [0, 0, 0, 0],
            depth: 1,
            height: 2,
            width: 2
        )
        let labeling = LabelingViewModel()
        let map = labeling.createLabelMap(for: volume)

        labeling.paint(axis: 2, sliceIndex: 0, pixelX: 1, pixelY: 0)
        XCTAssertEqual(map.value(z: 0, y: 0, x: 1), 1)
        XCTAssertEqual(labeling.undoDepth, 1)

        labeling.undo()
        XCTAssertEqual(map.value(z: 0, y: 0, x: 1), 0)
        XCTAssertEqual(labeling.redoDepth, 1)

        labeling.redo()
        XCTAssertEqual(map.value(z: 0, y: 0, x: 1), 1)
    }

    func testIslandCleanupKeepsLargestComponent() {
        let map = LabelMap(parentSeriesUID: "series", depth: 1, height: 3, width: 4)
        map.voxels = [
            1, 1, 0, 1,
            1, 0, 0, 0,
            0, 0, 1, 1
        ]

        let removed = LabelOperations.keepLargestIsland(label: map, classID: 1)

        XCTAssertEqual(removed, 3)
        XCTAssertEqual(map.voxelCounts()[1], 3)
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

    @MainActor
    func testSUVGradientUsesPETOverlayForCTLabelMap() {
        let ct = ImageVolume(
            pixels: [0, 0, 0, 0, 0, 0],
            depth: 1,
            height: 1,
            width: 6,
            modality: "CT"
        )
        let pet = ImageVolume(
            pixels: [0, 3, 8, 6, 2, 0],
            depth: 1,
            height: 1,
            width: 6,
            modality: "PT"
        )
        let vm = ViewerViewModel()
        vm.currentVolume = ct
        let pair = FusionPair(base: ct, overlay: pet)
        pair.resampledOverlay = pet
        vm.fusion = pair
        let map = vm.labeling.createLabelMap(for: ct)

        vm.gradientActiveLabelAroundSeed(
            seed: (z: 0, y: 0, x: 2),
            minimumValue: 2.5,
            gradientCutoffFraction: 0.75,
            searchRadius: 5
        )

        XCTAssertEqual(map.voxels, [0, 1, 1, 1, 0, 0])
        XCTAssertTrue(vm.statusMessage.contains("SUV gradient"))
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

private func makeMinimalDICOM(patientName: String,
                              patientID: String,
                              studyUID: String,
                              studyDate: String,
                              seriesUID: String,
                              seriesDescription: String,
                              modality: String,
                              sopUID: String) -> Data {
    var data = Data(count: 128)
    data.append("DICM".data(using: .ascii)!)
    data.appendDICOMElement(group: 0x0002, element: 0x0010, vr: "UI", string: "1.2.840.10008.1.2.1")
    data.appendDICOMElement(group: 0x0010, element: 0x0010, vr: "PN", string: patientName)
    data.appendDICOMElement(group: 0x0010, element: 0x0020, vr: "LO", string: patientID)
    data.appendDICOMElement(group: 0x0008, element: 0x0020, vr: "DA", string: studyDate)
    data.appendDICOMElement(group: 0x0008, element: 0x1030, vr: "LO", string: "Indexed Study")
    data.appendDICOMElement(group: 0x0020, element: 0x000D, vr: "UI", string: studyUID)
    data.appendDICOMElement(group: 0x0020, element: 0x000E, vr: "UI", string: seriesUID)
    data.appendDICOMElement(group: 0x0008, element: 0x103E, vr: "LO", string: seriesDescription)
    data.appendDICOMElement(group: 0x0008, element: 0x0060, vr: "CS", string: modality)
    data.appendDICOMElement(group: 0x0008, element: 0x0018, vr: "UI", string: sopUID)
    data.appendDICOMElement(group: 0x0028, element: 0x0010, vr: "US", uint16: 1)
    data.appendDICOMElement(group: 0x0028, element: 0x0011, vr: "US", uint16: 1)
    return data
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

    mutating func appendDICOMElement(group: UInt16,
                                     element: UInt16,
                                     vr: String,
                                     string: String) {
        var value = string.data(using: .ascii) ?? Data()
        if value.count % 2 != 0 {
            value.append(0)
        }
        appendDICOMElementHeader(group: group, element: element, vr: vr, length: value.count)
        append(value)
    }

    mutating func appendDICOMElement(group: UInt16,
                                     element: UInt16,
                                     vr: String,
                                     uint16: UInt16) {
        var value = Data()
        value.appendUInt16LE(uint16)
        appendDICOMElementHeader(group: group, element: element, vr: vr, length: value.count)
        append(value)
    }

    private mutating func appendDICOMElementHeader(group: UInt16,
                                                   element: UInt16,
                                                   vr: String,
                                                   length: Int) {
        appendUInt16LE(group)
        appendUInt16LE(element)
        append(vr.data(using: .ascii)!)
        appendUInt16LE(UInt16(length))
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
}
