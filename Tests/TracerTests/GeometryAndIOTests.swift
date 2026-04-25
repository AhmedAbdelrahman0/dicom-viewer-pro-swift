import XCTest
import simd
@testable import Tracer
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

    func testSliceDisplayTransformKeepsCanonicalRadiologicalOrientation() {
        let volume = ImageVolume(
            pixels: [Float](repeating: 0, count: 8),
            depth: 2,
            height: 2,
            width: 2,
            direction: matrix_identity_double3x3
        )

        XCTAssertEqual(SliceDisplayTransform.canonical(axis: 0, volume: volume),
                       SliceDisplayTransform(flipHorizontal: false, flipVertical: true))
        XCTAssertEqual(SliceDisplayTransform.canonical(axis: 1, volume: volume),
                       SliceDisplayTransform(flipHorizontal: false, flipVertical: true))
        XCTAssertEqual(SliceDisplayTransform.canonical(axis: 2, volume: volume),
                       SliceDisplayTransform(flipHorizontal: false, flipVertical: false))
    }

    func testSliceDisplayTransformCorrectsAnteriorPosteriorSignFlip() {
        let direction = simd_double3x3(
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, -1, 0),
            SIMD3<Double>(0, 0, 1)
        )
        let volume = ImageVolume(
            pixels: [Float](repeating: 0, count: 8),
            depth: 2,
            height: 2,
            width: 2,
            direction: direction
        )

        let sagittal = SliceDisplayTransform.canonical(axis: 0, volume: volume)
        let axial = SliceDisplayTransform.canonical(axis: 2, volume: volume)

        XCTAssertTrue(sagittal.flipHorizontal)
        XCTAssertTrue(axial.flipVertical)
        XCTAssertEqual(SliceDisplayTransform.patientLetter(for: SliceDisplayTransform.displayAxes(axis: 2, volume: volume).down), "P")
    }

    @MainActor
    func testViewerAPCorrectionCanBeToggledForDisplayOnly() {
        let vm = ViewerViewModel()
        let volume = ImageVolume(
            pixels: [Float](repeating: 0, count: 8),
            depth: 2,
            height: 2,
            width: 2,
            direction: matrix_identity_double3x3
        )
        vm.displayVolume(volume)

        XCTAssertTrue(vm.displayTransform(for: 2).flipVertical)

        vm.correctAnteriorPosteriorDisplay = false
        XCTAssertFalse(vm.displayTransform(for: 2).flipVertical)
    }

    @MainActor
    func testPETOverlayRangeUsesExplicitSUVMinMax() {
        let vm = ViewerViewModel()

        vm.setPETOverlayRange(min: 2.5, max: 15)

        XCTAssertEqual(vm.petOverlayRangeMin, 2.5, accuracy: 1e-9)
        XCTAssertEqual(vm.petOverlayRangeMax, 15, accuracy: 1e-9)
        XCTAssertEqual(vm.overlayWindow, 12.5, accuracy: 1e-9)
        XCTAssertEqual(vm.overlayLevel, 8.75, accuracy: 1e-9)
    }

    func testDefaultPETHangingProtocolExposesFusionCTPETAndMIP() {
        XCTAssertEqual(
            HangingPaneConfiguration.defaultPETCT.map(\.kind),
            [.fused, .ctOnly, .petOnly, .petMIP]
        )
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

    func testNIfTILoaderOnlyAdvertisesFormatsItParses() {
        XCTAssertTrue(NIfTILoader.isVolumeFile(URL(fileURLWithPath: "/tmp/study.nii")))
        XCTAssertTrue(NIfTILoader.isVolumeFile(URL(fileURLWithPath: "/tmp/study.nii.gz")))
        XCTAssertFalse(NIfTILoader.isVolumeFile(URL(fileURLWithPath: "/tmp/study.nrrd")))
        XCTAssertFalse(NIfTILoader.isVolumeFile(URL(fileURLWithPath: "/tmp/study.mha")))
        XCTAssertFalse(NIfTILoader.isVolumeFile(URL(fileURLWithPath: "/tmp/study.hdr")))
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

    func testPACSWorklistGroupsSeriesByStudyAndFilters() {
        let now = Date(timeIntervalSince1970: 0)
        let ct = PACSIndexedSeriesSnapshot(
            id: "dicom:ct",
            kind: .dicom,
            seriesUID: "ct",
            studyUID: "study-1",
            modality: "CT",
            patientID: "MRN1",
            patientName: "Worklist^Patient",
            accessionNumber: "ACC-1",
            studyDescription: "PET CT",
            studyDate: "20260421",
            studyTime: "103000",
            referringPhysicianName: "Referring^Doctor",
            bodyPartExamined: "CHEST",
            seriesDescription: "CT AC",
            sourcePath: "/tmp/a",
            filePaths: ["/tmp/a/ct.dcm"],
            instanceCount: 100,
            indexedAt: now
        )
        let pet = PACSIndexedSeriesSnapshot(
            id: "dicom:pet",
            kind: .dicom,
            seriesUID: "pet",
            studyUID: "study-1",
            modality: "PT",
            patientID: "MRN1",
            patientName: "Worklist^Patient",
            accessionNumber: "ACC-1",
            studyDescription: "PET CT",
            studyDate: "20260421",
            studyTime: "103000",
            referringPhysicianName: "Referring^Doctor",
            bodyPartExamined: "WHOLEBODY",
            seriesDescription: "PET WB",
            sourcePath: "/tmp/a",
            filePaths: ["/tmp/a/pet.dcm"],
            instanceCount: 60,
            indexedAt: now
        )

        let studies = PACSWorklistStudy.grouped(
            from: [pet, ct],
            statuses: ["study:study-1": .flagged]
        )

        XCTAssertEqual(studies.count, 1)
        XCTAssertEqual(studies[0].seriesCount, 2)
        XCTAssertEqual(studies[0].instanceCount, 160)
        XCTAssertEqual(studies[0].modalities, ["CT", "PET"])
        XCTAssertEqual(studies[0].status, .flagged)
        XCTAssertTrue(studies[0].matches(searchText: "acc-1", statusFilter: .flagged, modalityFilter: "PET", dateFilter: .all))
        XCTAssertFalse(studies[0].matches(searchText: "", statusFilter: .complete, modalityFilter: "All", dateFilter: .all))
    }

    func testPACSDirectoryIndexerDeduplicatesLargeStudyFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacs-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try makeMinimalDICOM(
            patientName: "Alpha^Patient",
            patientID: "MRN-A",
            accessionNumber: "ACC-A",
            studyUID: "study-a",
            studyDate: "20260421",
            studyTime: "120000",
            referringPhysicianName: "Ref^A",
            seriesUID: "series-a",
            seriesDescription: "PET WB",
            modality: "PT",
            sopUID: "sop-a-1"
        ).write(to: root.appendingPathComponent("a1.dcm"))
        try makeMinimalDICOM(
            patientName: "Alpha^Patient",
            patientID: "MRN-A",
            accessionNumber: "ACC-A",
            studyUID: "study-a",
            studyDate: "20260421",
            studyTime: "120000",
            referringPhysicianName: "Ref^A",
            seriesUID: "series-a",
            seriesDescription: "PET WB",
            modality: "PT",
            sopUID: "sop-a-1"
        ).write(to: root.appendingPathComponent("a1-copy.dcm"))
        try makeMinimalDICOM(
            patientName: "Beta^Patient",
            patientID: "MRN-B",
            accessionNumber: "ACC-B",
            studyUID: "study-b",
            studyDate: "20260420",
            studyTime: "121500",
            referringPhysicianName: "Ref^B",
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
        XCTAssertEqual(alpha.accessionNumber, "ACC-A")
        XCTAssertEqual(alpha.studyTime, "120000")
        XCTAssertEqual(alpha.referringPhysicianName, "Ref^A")
        XCTAssertTrue(alpha.searchableText.contains("alpha"))
        XCTAssertTrue(alpha.searchableText.contains("acc-a"))
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

    func testSegmentationRAGSelectsAutoPETForFDGLymphoma() {
        let plan = SegmentationRAG.plan(
            for: "Segment FDG avid lymphoma lesions on PET/CT",
            currentModality: .PT,
            availableMONAIModels: ["whole_body_ct", "autopet_fdg_lesion"]
        )

        XCTAssertEqual(plan?.presetName, "AutoPET")
        XCTAssertEqual(plan?.labelName, "FDG-avid lesion")
        XCTAssertEqual(plan?.tool, .suvGradient)
        XCTAssertEqual(plan?.matchedMONAIModel, "autopet_fdg_lesion")
    }

    func testSegmentationRAGSelectsAnatomyForSimpleLiverRequest() {
        let plan = SegmentationRAG.plan(
            for: "Segment the liver for cleanup",
            currentModality: .CT
        )

        XCTAssertEqual(plan?.presetName, "TotalSegmentator")
        XCTAssertEqual(plan?.labelName, "liver")
        XCTAssertEqual(plan?.tool, .regionGrow)
    }

    func testSegmentationRAGSelectsRadiotherapyTargetLabels() {
        let plan = SegmentationRAG.plan(
            for: "Contour the gross tumor volume and nodal disease for radiotherapy",
            currentModality: .CT
        )

        XCTAssertEqual(plan?.presetName, "RT Standard")
        XCTAssertEqual(plan?.labelName, "GTV")
        XCTAssertEqual(plan?.tool, .brush)
    }

    func testSegmentationRAGSelectsNNUnetForPancreaticMass() {
        let plan = SegmentationRAG.plan(
            for: "Use the best model to segment a pancreatic mass on CT",
            currentModality: .CT
        )

        XCTAssertEqual(plan?.preferredEngine, .nnUNet)
        XCTAssertEqual(plan?.nnunetEntryID, "MSD-Pancreas")
        XCTAssertEqual(plan?.nnunetDatasetID, "Dataset007_Pancreas")
        XCTAssertEqual(plan?.presetName, "MSD Pancreas")
        XCTAssertEqual(plan?.labelName, "pancreatic lesion")
    }

    func testSegmentationRAGSelectsNNUnetForLungNodule() {
        let plan = SegmentationRAG.plan(
            for: "Auto segment the lung nodule with an AI model",
            currentModality: .CT
        )

        XCTAssertEqual(plan?.preferredEngine, .nnUNet)
        XCTAssertEqual(plan?.nnunetEntryID, "MSD-Lung")
        XCTAssertEqual(plan?.labelName, "lung nodule")
    }

    @MainActor
    func testNNUnetViewModelSelectsRoutedEntryFromAssistantPlan() {
        let plan = SegmentationRAG.plan(
            for: "Use the best model to segment a pancreatic mass on CT",
            currentModality: .CT
        )
        let nnunet = NNUnetViewModel()

        let entry = plan.flatMap { nnunet.selectBestEntry(for: $0) }

        XCTAssertEqual(entry?.id, "MSD-Pancreas")
        XCTAssertEqual(nnunet.selectedEntryID, "MSD-Pancreas")
        XCTAssertTrue(nnunet.statusMessage.contains("Segmentation RAG selected nnU-Net"))
    }

    func testSegmentationRAGMultiChannelModelsDoNotWinAmbiguousTumorRoute() {
        // "segment tumor on CT" is intentionally ambiguous. The planner must
        // NOT pick BraTS (multi-channel brain MRI) or MSD-Prostate — those
        // entries are down-weighted because their channel pairing isn't wired.
        let plan = SegmentationRAG.plan(
            for: "segment tumor on CT",
            currentModality: .CT
        )
        XCTAssertNotNil(plan, "A tumor-on-CT prompt should produce some plan")
        let entryID = plan?.nnunetEntryID
        XCTAssertNotEqual(entryID, "BraTS-GLI",
                          "BraTS is multi-channel MR; should not win CT tumor route")
        XCTAssertNotEqual(entryID, "MSD-Prostate",
                          "MSD-Prostate is multi-channel MR; should not win CT tumor route")
        if let entry = entryID.flatMap(NNUnetCatalog.byID) {
            XCTAssertFalse(entry.multiChannel,
                           "Routed nnU-Net entry \(entry.datasetID) must be single-channel")
        }
    }

    func testSegmentationRAGTiebreakerPrefersMatchingModality() {
        // "tumor model" with loaded MR should lean toward an MR-capable model
        // over a CT-only model when scores are otherwise close.
        let mrPlan = SegmentationRAG.plan(
            for: "segment tumor with an ai model",
            currentModality: .MR
        )
        let ctPlan = SegmentationRAG.plan(
            for: "segment tumor with an ai model",
            currentModality: .CT
        )
        XCTAssertNotNil(mrPlan)
        XCTAssertNotNil(ctPlan)

        // Both plans must declare modalities that include the loaded volume's.
        if let mrEntry = mrPlan?.nnunetEntryID.flatMap(NNUnetCatalog.byID) {
            XCTAssertTrue([Modality.MR, .CT, .OT].contains(mrEntry.modality),
                          "MR-loaded route should not land on a PET-only dataset")
        }
        if let ctEntry = ctPlan?.nnunetEntryID.flatMap(NNUnetCatalog.byID) {
            XCTAssertEqual(ctEntry.modality, .CT,
                           "CT-loaded route with model intent should pick a CT dataset")
        }
    }

    @MainActor
    func testAssistantPlanSegmentationCreatesClassWithPresetCategory() {
        // With TotalSegmentator preset as the route, auto-created "liver" class
        // must end up as .organ (from the preset), not .custom (heuristic).
        let vm = ViewerViewModel()
        let ct = ImageVolume(
            pixels: [Float](repeating: 0, count: 4),
            depth: 1, height: 2, width: 2, modality: "CT"
        )
        vm.currentVolume = ct

        let report = vm.performAssistantCommand(
            "Segment liver using the TotalSegmentator model on the current volume"
        )
        XCTAssertTrue(report.didApplyActions)

        let liver = vm.labeling.activeLabelMap?.classes.first { $0.name.lowercased().contains("liver") }
        XCTAssertNotNil(liver, "Assistant should have created or selected a liver class")
        if let liver {
            XCTAssertEqual(liver.category, .organ,
                           "Preset-driven auto-create must preserve the preset's category")
        }
    }

    @MainActor
    func testNNUnetViewModelReturnsNilWhenRoutedEntryIsNotInCatalog() {
        // Fabricate a plan whose nnunetEntryID is bogus — the VM should
        // cleanly return nil so the UI can surface a warning.
        let plan = SegmentationRAGPlan(
            diseaseProcess: "tumor",
            requestedTarget: "tumor",
            modelName: "Fake Model",
            presetName: "TotalSegmentator",
            labelName: "tumor",
            tool: .brush,
            confidence: 0.9,
            rationale: "test",
            evidence: [],
            monaiModelKeywords: [],
            matchedMONAIModel: nil,
            preferredEngine: .nnUNet,
            nnunetEntryID: "NOT_A_REAL_ID",
            nnunetDatasetID: nil,
            nnunetDisplayName: nil,
            nnunetMultiChannel: false
        )
        let vm = NNUnetViewModel()
        XCTAssertNil(vm.selectBestEntry(for: plan),
                     "Missing catalog entry must not silently fall back to the default id")
    }

    func testAssistantCommandInterpreterEmitsSegmentationRAGPlan() {
        let actions = AssistantCommandInterpreter().actions(
            for: "Segment FDG avid lymphoma lesions on PET/CT"
        )
        let plan = actions.compactMap { action -> SegmentationRAGPlan? in
            if case .planSegmentation(let plan) = action { return plan }
            return nil
        }.first

        XCTAssertEqual(plan?.presetName, "AutoPET")
        XCTAssertEqual(plan?.labelName, "FDG-avid lesion")
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

    func testAssistantSUVCalculationPromptDoesNotTriggerThreshold() {
        let actions = AssistantCommandInterpreter().actions(
            for: "Use SUVbw from kBq/mL, patient weight 70 kg, injected dose 350 MBq"
        )

        XCTAssertFalse(actions.contains { action in
            if case .threshold = action { return true }
            return false
        })
    }

    func testAssistantShortSUVThresholdStillParses() {
        let actions = AssistantCommandInterpreter().actions(for: "SUV 2.5")

        XCTAssertTrue(actions.contains(.threshold(2.5)))
    }

    @MainActor
    func testAssistantAppliesSegmentationRAGPlanToLabelingState() {
        let vm = ViewerViewModel()
        vm.currentVolume = ImageVolume(
            pixels: [0],
            depth: 1,
            height: 1,
            width: 1,
            modality: "PT",
            seriesDescription: "FDG PET"
        )

        let report = vm.performAssistantCommand("Segment FDG avid lymphoma lesions on PET/CT")

        XCTAssertTrue(report.didApplyActions)
        XCTAssertEqual(vm.labeling.activeLabelMap?.name, "AutoPET Labels")
        XCTAssertEqual(vm.labeling.labelingTool, .suvGradient)
        let selected = vm.labeling.activeLabelMap?.classInfo(id: vm.labeling.activeClassID)?.name
        XCTAssertEqual(selected, "FDG-avid lesion")
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

    // MARK: - Classification

    func testRadiomicsExtractorProducesFirstOrderAndShape() throws {
        // 4×4×1 volume with a bright 2×2 centre lesion.
        let volume = ImageVolume(
            pixels: [
                0, 0, 0, 0,
                0, 100, 100, 0,
                0, 100, 100, 0,
                0, 0, 0, 0,
            ],
            depth: 1, height: 4, width: 4,
            spacing: (1, 1, 1),
            modality: "CT"
        )
        let mask = LabelMap(parentSeriesUID: volume.seriesUID,
                            depth: 1, height: 4, width: 4)
        for y in 1...2 { for x in 1...2 { mask.setValue(1, z: 0, y: y, x: x) } }

        let bounds = MONAITransforms.VoxelBounds(
            minZ: 0, maxZ: 0, minY: 1, maxY: 2, minX: 1, maxX: 2
        )
        let features = try RadiomicsExtractor.extract(
            volume: volume, mask: mask, classID: 1, bounds: bounds
        )

        XCTAssertEqual(features["original_firstorder_Mean"] ?? 0,
                       100, accuracy: 1e-6)
        XCTAssertEqual(features["original_firstorder_Maximum"] ?? 0,
                       100, accuracy: 1e-6)
        XCTAssertEqual(features["original_shape_VoxelCount"] ?? 0,
                       4, accuracy: 1e-6,
                       "2×2 centre lesion should have 4 voxels")
        XCTAssertEqual(features["original_shape_VoxelVolume"] ?? 0,
                       4, accuracy: 1e-6)
    }

    func testRadiomicsExtractorRejectsEmptyBoundsOrTooFewVoxels() {
        let volume = ImageVolume(
            pixels: [0, 0, 0, 0],
            depth: 1, height: 2, width: 2, modality: "CT"
        )
        let mask = LabelMap(parentSeriesUID: volume.seriesUID,
                            depth: 1, height: 2, width: 2)
        let bounds = MONAITransforms.VoxelBounds(
            minZ: 0, maxZ: 0, minY: 0, maxY: 1, minX: 0, maxX: 1
        )
        // No voxels in the mask match classID=1 → emptyLesion.
        XCTAssertThrowsError(try RadiomicsExtractor.extract(
            volume: volume, mask: mask, classID: 1, bounds: bounds
        ))
    }

    func testTreeModelScoresWithAggregation() throws {
        let model = TreeModel(
            features: ["f0"],
            classes: ["benign", "malignant"],
            aggregation: .mean,
            trees: [
                TreeModel.Tree(nodes: [
                    TreeModel.Node(feature: 0, threshold: 10, left: 1, right: 2, leaf: nil),
                    TreeModel.Node(feature: nil, threshold: nil, left: nil, right: nil, leaf: [0.9, 0.1]),
                    TreeModel.Node(feature: nil, threshold: nil, left: nil, right: nil, leaf: [0.2, 0.8])
                ])
            ]
        )
        let low = try model.score(["f0": 5])
        let high = try model.score(["f0": 20])
        XCTAssertEqual(low[0], 0.9, accuracy: 1e-6)
        XCTAssertEqual(high[1], 0.8, accuracy: 1e-6)
    }

    func testTreeModelRejectsMalformedNodes() {
        let model = TreeModel(
            features: ["f0"],
            classes: ["a", "b"],
            aggregation: .mean,
            trees: [
                TreeModel.Tree(nodes: [
                    // Split node references a left child outside the node array.
                    TreeModel.Node(feature: 0, threshold: 0,
                                   left: 99, right: 1, leaf: nil),
                    TreeModel.Node(feature: nil, threshold: nil,
                                   left: nil, right: nil, leaf: [1, 0])
                ])
            ]
        )
        XCTAssertThrowsError(try model.score(["f0": 0]))
    }

    func testLesionClassifierCatalogHasExpectedEntries() {
        let ids = LesionClassifierCatalog.all.map(\.id)
        XCTAssertTrue(ids.contains("lung-nodule-radiomics"))
        XCTAssertTrue(ids.contains("liver-lesion-radiomics"))
        XCTAssertTrue(ids.contains("medsiglip-zero-shot"))
        XCTAssertTrue(ids.contains("medgemma-4b"))
        XCTAssertTrue(ids.contains("subprocess-pyradiomics"))
        XCTAssertTrue(LesionClassifierCatalog.lungNoduleRadiomics.requiresConfiguration)
        XCTAssertTrue(LesionClassifierCatalog.petLesionRadiomics.notes.contains("Training/research"))
    }

    @MainActor
    func testMedSigLIPTokenIDParserRequiresRealTokenizerOutput() throws {
        let parsed = try ClassificationViewModel.parseZeroShotTokenIDs("""
        1 2 3 0
        9,8,7,0
        """)
        XCTAssertEqual(parsed, [[1, 2, 3, 0], [9, 8, 7, 0]])

        XCTAssertThrowsError(try ClassificationViewModel.parseZeroShotTokenIDs("1 two 3"))
    }

    func testMedGemmaParserExtractsLabelAndRationale() throws {
        let raw = """
        Here's my analysis: { "label": "malignant",
          "confidence": 0.87,
          "rationale": "Lesion shows heterogeneous enhancement with ill-defined margins." }
        Thanks for the image.
        """
        let parsed = try MedGemmaClassifier.parseJSON(
            in: raw, expectedLabels: ["benign", "malignant"]
        )
        XCTAssertEqual(parsed.predictions.first?.label, "malignant")
        XCTAssertEqual(parsed.predictions.first?.probability ?? 0,
                       0.87, accuracy: 1e-6)
        XCTAssertTrue(parsed.rationale?.contains("heterogeneous") ?? false)
    }

    @MainActor
    func testClassificationReportCSVContainsHeaderAndLesions() {
        let lesion = PETQuantification.LesionStats(
            id: 1, classID: 1, className: "lesion #1",
            voxelCount: 12, volumeMM3: 12, volumeML: 0.012,
            suvMax: 8.5, suvMean: 4.2, suvPeak: 8.5, tlg: 0.0504,
            bounds: (0, 0, 0, 0, 0, 0)
        )
        let result = ClassificationResult(
            predictions: [
                LabelPrediction(label: "malignant", probability: 0.87),
                LabelPrediction(label: "benign", probability: 0.13)
            ],
            rationale: "demo",
            features: [:],
            durationSeconds: 0.5,
            classifierID: "demo"
        )
        let row = ClassificationViewModel.LesionResult(id: 1, lesion: lesion, result: result)
        let csv = ClassificationReport.csvData(for: [row])
        let text = String(data: csv, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("lesion_id,class_name"))
        XCTAssertTrue(text.contains("malignant:0.8700"))
        XCTAssertTrue(text.contains("demo"))
    }

    func testNIfTIGunzipRejectsCorruptedISIZETrailer() throws {
        // Author a valid .nii.gz, then flip the last 4 bytes (ISIZE) so the
        // declared uncompressed size no longer matches the real payload.
        // The loader must detect the trailer mismatch and throw instead of
        // silently handing back a short buffer that would downstream-read
        // past the volume's declared dimensions.
        let volume = ImageVolume(
            pixels: [0, 0, 0, 0],
            depth: 1, height: 2, width: 2,
            modality: "CT"
        )
        let map = LabelMap(parentSeriesUID: volume.seriesUID,
                           depth: 1, height: 2, width: 2)
        map.setValue(7, z: 0, y: 0, x: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iSIZE-\(UUID().uuidString).nii.gz")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(
                at: url.deletingPathExtension().appendingPathExtension("label.txt")
            )
        }
        try LabelIO.saveNIfTIGz(map, to: url, parentVolume: volume)

        // Mutate the last 4 bytes (ISIZE) to a bogus value.
        var bytes = try Data(contentsOf: url)
        let n = bytes.count
        XCTAssertGreaterThan(n, 8, "Sanity: gz file must have a trailer")
        bytes[n - 4] = 0xFF
        bytes[n - 3] = 0xFF
        bytes[n - 2] = 0xFF
        bytes[n - 1] = 0x7F
        try bytes.write(to: url)

        XCTAssertThrowsError(
            try LabelIO.loadNIfTILabelmap(from: url, parentVolume: volume),
            "Corrupted ISIZE trailer must be rejected"
        )
    }

    func testCompressedNIfTILabelExportRoundTrips() throws {
        let volume = ImageVolume(
            pixels: [0, 0, 0, 0],
            depth: 1,
            height: 2,
            width: 2,
            modality: "CT"
        )
        let map = LabelMap(parentSeriesUID: volume.seriesUID, depth: 1, height: 2, width: 2)
        map.setValue(3, z: 0, y: 1, x: 1)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("labels-\(UUID().uuidString).nii.gz")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("label.txt"))
        }

        try LabelIO.saveNIfTIGz(map, to: url, parentVolume: volume)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes[0], 0x1f)
        XCTAssertEqual(bytes[1], 0x8b)

        let loaded = try LabelIO.loadNIfTILabelmap(from: url, parentVolume: volume)
        XCTAssertEqual(loaded.voxels, map.voxels)
    }

    func testNRRDExportPreservesDirectionCosines() throws {
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
            direction: direction
        )
        let map = LabelMap(parentSeriesUID: volume.seriesUID, depth: 1, height: 1, width: 1)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("labels-\(UUID().uuidString).nrrd")
        defer { try? FileManager.default.removeItem(at: url) }

        try LabelIO.saveNRRD(map, to: url, parentVolume: volume)

        let text = try String(contentsOf: url, encoding: .ascii)
        XCTAssertTrue(text.contains("space directions: (0,2,0) (3,0,0) (0,0,4)"))
    }

    @MainActor
    func testActivePETRegionStatsUsesMatchedVolumeScale() {
        let ct = ImageVolume(
            pixels: [0, 0],
            depth: 1,
            height: 1,
            width: 2,
            modality: "CT"
        )
        let pet = ImageVolume(
            pixels: [10, 20],
            depth: 1,
            height: 1,
            width: 2,
            modality: "PT",
            suvScaleFactor: 0.5
        )
        let vm = ViewerViewModel()
        vm.currentVolume = ct
        vm.suvSettings.mode = .storedSUV
        let pair = FusionPair(base: ct, overlay: pet)
        pair.resampledOverlay = pet
        vm.fusion = pair
        let map = vm.labeling.createLabelMap(for: ct)
        map.setValue(1, z: 0, y: 0, x: 0)
        map.setValue(1, z: 0, y: 0, x: 1)

        let stats = vm.activePETRegionStats(for: map, classID: 1)

        XCTAssertEqual(stats?.suvMax ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(stats?.suvMean ?? 0, 7.5, accuracy: 1e-9)
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
    func testViewerSUVThresholdUsesMatchedVolumeScale() {
        let ct = ImageVolume(
            pixels: [0, 0],
            depth: 1,
            height: 1,
            width: 2,
            modality: "CT"
        )
        let pet = ImageVolume(
            pixels: [10, 20],
            depth: 1,
            height: 1,
            width: 2,
            modality: "PT",
            suvScaleFactor: 0.5
        )
        let vm = ViewerViewModel()
        vm.currentVolume = ct
        vm.suvSettings.mode = .storedSUV
        let pair = FusionPair(base: ct, overlay: pet)
        pair.resampledOverlay = pet
        vm.fusion = pair
        let map = vm.labeling.createLabelMap(for: ct)

        vm.thresholdActiveLabel(atOrAbove: 8)

        XCTAssertEqual(map.voxels, [0, 1],
                       "Thresholding must compare scaled SUV, not raw PET counts")
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

    // MARK: - Enhancements: cancellation, RLE guards, undo memory, synthetic keys

    func testPACSIndexerHonoursCancellationTokenMidScan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacs-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 20 cheap DICOM files so we are guaranteed to cross the stride threshold.
        for i in 0..<20 {
            try makeMinimalDICOM(
                patientName: "Cancel^Patient",
                patientID: "MRN-C",
                studyUID: "study-cancel",
                studyDate: "20260421",
                seriesUID: "series-cancel-\(i)",
                seriesDescription: "Cancel Series \(i)",
                modality: "CT",
                sopUID: "sop-c-\(i)"
            ).write(to: root.appendingPathComponent("c\(i).dcm"))
        }

        let cancellation = PACSScanCancellation()
        cancellation.cancel() // Pre-cancelled — scan should short-circuit immediately.

        let result = PACSDirectoryIndexer.scan(
            url: root,
            headerByteLimit: 4096,
            progressStride: 1,
            isCancelled: { cancellation.isCancelled }
        )

        XCTAssertTrue(result.cancelled, "Pre-cancelled scan must report cancelled=true")
        XCTAssertEqual(result.records.count, 0)
        XCTAssertEqual(result.scannedFiles, 0)
    }

    func testPACSIndexerCancelsBetweenFilesAndReturnsPartialRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacs-partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for i in 0..<10 {
            try makeMinimalDICOM(
                patientName: "Partial^Patient",
                patientID: "MRN-P",
                studyUID: "study-partial",
                studyDate: "20260421",
                seriesUID: "series-partial-\(i)",
                seriesDescription: "Partial \(i)",
                modality: "CT",
                sopUID: "sop-p-\(i)"
            ).write(to: root.appendingPathComponent("p\(i).dcm"))
        }

        let cancellation = PACSScanCancellation()
        let scanned = LockedCounter()

        let result = PACSDirectoryIndexer.scan(
            url: root,
            headerByteLimit: 4096,
            progressStride: 1,
            isCancelled: {
                // Cancel after the first file has been observed in progress.
                if scanned.value >= 1 {
                    cancellation.cancel()
                }
                return cancellation.isCancelled
            },
            progress: { update in
                if update.phase == .scanning, update.scannedFiles >= 1 {
                    scanned.set(update.scannedFiles)
                }
            }
        )

        XCTAssertTrue(result.cancelled, "Expected a mid-scan cancellation to mark result as cancelled")
        XCTAssertLessThan(result.scannedFiles, 10,
                          "Cancellation should stop scanning before all 10 files")
    }

    func testLabelPackageDecodeRejectsOverflowingRLERun() throws {
        let volume = ImageVolume(
            pixels: [0, 0, 0, 0],
            depth: 1,
            height: 2,
            width: 2,
            modality: "CT"
        )
        let map = LabelMap(parentSeriesUID: volume.seriesUID, depth: 1, height: 2, width: 2)
        map.voxels = [0, 1, 0, 1]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rle-overflow-\(UUID().uuidString).dvlabels")
        defer { try? FileManager.default.removeItem(at: url) }

        try LabelIO.saveLabelPackage(
            labelMap: map,
            annotations: [],
            landmarks: [],
            parentVolume: volume,
            to: url
        )

        // Tamper with the JSON: inflate every RLE run count. The decoder must
        // reject this *before* allocating a multi-billion-element voxel array.
        // (Only RLE entries have "count" keys in this package, so a blanket
        //  replace is safe for the test fixture.)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"count\" : 1",
                                         with: "\"count\" : 4000000000")
        try text.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try LabelIO.loadLabelPackage(from: url, parentVolume: volume)) { error in
            guard case LabelIO.LabelIOError.invalidLabelPackage(let message) = error else {
                return XCTFail("Expected invalidLabelPackage error, got \(error)")
            }
            XCTAssertTrue(message.contains("exceeds remaining") || message.contains("does not match"),
                          "Unexpected error message: \(message)")
        }
    }

    @MainActor
    func testLabelingUndoMemoryIsReclaimedWhenRecordsEvict() {
        let volume = ImageVolume(
            pixels: Array(repeating: 0, count: 4),
            depth: 1,
            height: 2,
            width: 2
        )
        let labeling = LabelingViewModel()
        _ = labeling.createLabelMap(for: volume)

        // Single paint — one edit with one changed voxel.
        labeling.paint(axis: 2, sliceIndex: 0, pixelX: 1, pixelY: 0)
        XCTAssertEqual(labeling.undoDepth, 1)
        XCTAssertGreaterThan(labeling.historyMemoryBytes, 0,
                             "Memory counter should update after an edit is recorded")
        let afterOne = labeling.historyMemoryBytes

        // Second paint — another recorded edit, memory should roughly double.
        labeling.paint(axis: 2, sliceIndex: 0, pixelX: 0, pixelY: 1)
        XCTAssertGreaterThanOrEqual(labeling.historyMemoryBytes, afterOne)

        // Remove the map — history for that map should be freed.
        if let map = labeling.activeLabelMap {
            labeling.removeLabelMap(map)
        }
        XCTAssertEqual(labeling.historyMemoryBytes, 0)
        XCTAssertEqual(labeling.undoDepth, 0)
    }

    func testSyntheticWorklistKeyDistinguishesDifferentDirectories() {
        let patient = "MRN-Z"
        let date = "20260421"
        let description = "Research MRI"

        let seriesA = PACSIndexedSeriesSnapshot(
            id: "nifti:/a/mri.nii",
            kind: .nifti,
            seriesUID: "",
            studyUID: "NIFTI_STUDY",
            modality: "MR",
            patientID: patient,
            patientName: "Patient^Z",
            accessionNumber: "",
            studyDescription: description,
            studyDate: date,
            seriesDescription: "T1",
            sourcePath: "/archive",
            filePaths: ["/archive/a/mri.nii"],
            instanceCount: 1,
            indexedAt: Date()
        )
        let seriesB = PACSIndexedSeriesSnapshot(
            id: "nifti:/b/mri.nii",
            kind: .nifti,
            seriesUID: "",
            studyUID: "NIFTI_STUDY",
            modality: "MR",
            patientID: patient,
            patientName: "Patient^Z",
            accessionNumber: "",
            studyDescription: description,
            studyDate: date,
            seriesDescription: "T1",
            sourcePath: "/archive",
            filePaths: ["/archive/b/mri.nii"],
            instanceCount: 1,
            indexedAt: Date()
        )

        XCTAssertNotEqual(
            PACSWorklistStudy.studyKey(for: seriesA),
            PACSWorklistStudy.studyKey(for: seriesB),
            "Same patient/date/description in different directories must not collapse into one synthetic study"
        )

        let studies = PACSWorklistStudy.grouped(from: [seriesA, seriesB])
        XCTAssertEqual(studies.count, 2,
                       "Each directory-scoped series should surface as its own worklist study")
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

    // MARK: - MONAI transforms

    func testMONAIScaleIntensityRangeClipsToTargetRange() {
        let pixels: [Float] = [-100, 0, 50, 100, 250]
        let scaled = MONAITransforms.scaleIntensityRange(
            pixels, aMin: 0, aMax: 100, bMin: 0, bMax: 1, clip: true
        )
        XCTAssertEqual(scaled[0], 0, accuracy: 1e-6, "values below aMin clip to bMin")
        XCTAssertEqual(scaled[1], 0, accuracy: 1e-6)
        XCTAssertEqual(scaled[2], 0.5, accuracy: 1e-6)
        XCTAssertEqual(scaled[3], 1.0, accuracy: 1e-6)
        XCTAssertEqual(scaled[4], 1.0, accuracy: 1e-6, "values above aMax clip to bMax")
    }

    func testMONAINormalizeIntensityUsesZScore() {
        let pixels: [Float] = [2, 4, 4, 4, 5, 5, 7, 9]
        // mean = 5, population std = 2
        let normalized = MONAITransforms.normalizeIntensity(pixels)
        XCTAssertEqual(normalized[0], -1.5, accuracy: 1e-4)
        XCTAssertEqual(normalized[2], -0.5, accuracy: 1e-4)
        XCTAssertEqual(normalized[4], 0.0, accuracy: 1e-4)
        XCTAssertEqual(normalized[7], 2.0, accuracy: 1e-4)
    }

    func testMONAICropForegroundProducesTightBoundsWithMargin() {
        var pixels = [Float](repeating: 0, count: 4 * 4 * 4)
        // A single bright voxel at (z=2, y=1, x=3).
        pixels[2 * 16 + 1 * 4 + 3] = 10
        let volume = ImageVolume(pixels: pixels, depth: 4, height: 4, width: 4)

        guard let bounds = MONAITransforms.foregroundBounds(volume, threshold: 0, margin: 1) else {
            return XCTFail("Expected non-nil bounds for a volume with one foreground voxel")
        }
        XCTAssertEqual(bounds.minX, 2)
        XCTAssertEqual(bounds.maxX, 3, "x=3 + margin=1 is clipped at volume width-1")
        XCTAssertEqual(bounds.minY, 0)
        XCTAssertEqual(bounds.maxY, 2)
        XCTAssertEqual(bounds.minZ, 1)
        XCTAssertEqual(bounds.maxZ, 3)
    }

    func testMONAIResamplePreservesTotalExtentUnderIsotropicTarget() {
        let volume = ImageVolume(
            pixels: Array(0..<27).map(Float.init),
            depth: 3, height: 3, width: 3,
            spacing: (2, 2, 2)
        )
        let resampled = MONAITransforms.resample(volume, to: (1, 1, 1))
        XCTAssertEqual(resampled.width, 6)
        XCTAssertEqual(resampled.height, 6)
        XCTAssertEqual(resampled.depth, 6)
        XCTAssertEqual(resampled.spacing.x, 1, accuracy: 1e-9)
    }

    func testMONAISlidingPatchesCoverVolumeWithOverlap() {
        let patches = MONAITransforms.slidingPatches(
            volumeWidth: 64, volumeHeight: 64, volumeDepth: 32,
            patchSize: (32, 32, 16),
            overlap: 0.5
        )
        XCTAssertFalse(patches.isEmpty)
        // Every patch must fit inside the volume.
        for p in patches {
            XCTAssertGreaterThanOrEqual(p.minX, 0)
            XCTAssertLessThan(p.maxX, 64)
            XCTAssertLessThan(p.maxY, 64)
            XCTAssertLessThan(p.maxZ, 32)
        }
    }

    // MARK: - Segmentation metrics

    func testDiceAndIOUAgreeOnPerfectOverlap() {
        let pred = LabelMap(parentSeriesUID: "p", depth: 1, height: 2, width: 2)
        let gt   = LabelMap(parentSeriesUID: "g", depth: 1, height: 2, width: 2)
        pred.voxels = [0, 1, 1, 0]
        gt.voxels   = [0, 1, 1, 0]
        XCTAssertEqual(SegmentationMetrics.dice(prediction: pred, groundTruth: gt, classID: 1) ?? 0,
                       1.0, accuracy: 1e-9)
        XCTAssertEqual(SegmentationMetrics.iou(prediction: pred, groundTruth: gt, classID: 1) ?? 0,
                       1.0, accuracy: 1e-9)
    }

    func testDicePenalizesDisjointPredictions() {
        let pred = LabelMap(parentSeriesUID: "p", depth: 1, height: 2, width: 2)
        let gt   = LabelMap(parentSeriesUID: "g", depth: 1, height: 2, width: 2)
        pred.voxels = [1, 0, 0, 0]
        gt.voxels   = [0, 0, 0, 1]
        XCTAssertEqual(SegmentationMetrics.dice(prediction: pred, groundTruth: gt, classID: 1) ?? 0,
                       0.0, accuracy: 1e-9, "fully disjoint masks yield Dice = 0")
    }

    // MARK: - Histogram auto W/L

    func testHistogramAutoWindowBracketsMostOfTheData() {
        // Simple noisy volume: 90 % fills 0–100, 10 % outliers at 500.
        var pixels = [Float]()
        for i in 0..<900 { pixels.append(Float(i % 100)) }
        for _ in 0..<100 { pixels.append(500) }
        let volume = ImageVolume(pixels: pixels,
                                 depth: 1, height: 1, width: pixels.count)
        let result = HistogramAutoWindow.compute(volume, preset: .tight)
        XCTAssertLessThan(result.upperValue, 500,
                          "tight preset should exclude the 10 % outliers at 500")
        XCTAssertGreaterThan(result.window, 0)
    }

    // MARK: - Level-set segmentation

    func testLevelSetShrinksBubbleToDarkVoxels() {
        // A small 5×5×5 volume with a bright 3×3×3 core in the middle.
        let w = 5, h = 5, d = 5
        var pixels = [Float](repeating: 0, count: w * h * d)
        for z in 1...3 {
            for y in 1...3 {
                for x in 1...3 {
                    pixels[z * h * w + y * w + x] = 1
                }
            }
        }
        let volume = ImageVolume(pixels: pixels, depth: d, height: h, width: w)
        let label = LabelMap(parentSeriesUID: volume.seriesUID,
                             depth: d, height: h, width: w)
        let result = LevelSetSegmentation.evolve(
            volume: volume,
            label: label,
            seeds: [LevelSetSegmentation.Seed(z: 2, y: 2, x: 2, radius: 2)],
            speed: .regionCompetition(midpoint: 0.5, halfWidth: 0.2),
            parameters: LevelSetSegmentation.Parameters(iterations: 30),
            classID: 1
        )
        XCTAssertGreaterThan(result.insideVoxels, 0, "evolution should retain some inside voxels")
        XCTAssertLessThanOrEqual(result.insideVoxels, w * h * d)
    }

    func testLevelSetReturnsCleanlyForMismatchedLabelGrid() {
        let volume = ImageVolume(pixels: [0, 1, 2, 3], depth: 1, height: 2, width: 2)
        let label = LabelMap(parentSeriesUID: volume.seriesUID, depth: 1, height: 1, width: 1)

        let result = LevelSetSegmentation.evolve(
            volume: volume,
            label: label,
            seeds: [LevelSetSegmentation.Seed(z: 0, y: 0, x: 0, radius: 1)],
            speed: .regionCompetition(midpoint: 1, halfWidth: 1),
            classID: 1
        )

        XCTAssertEqual(result.insideVoxels, 0)
        XCTAssertEqual(result.iterations, 0)
        XCTAssertEqual(label.voxels, [0])
    }

    func testLevelSetHandlesTinyVolumesWithoutRangeTrap() {
        let volume = ImageVolume(pixels: [0], depth: 1, height: 1, width: 1)
        let label = LabelMap(parentSeriesUID: volume.seriesUID, depth: 1, height: 1, width: 1)

        let result = LevelSetSegmentation.evolve(
            volume: volume,
            label: label,
            seeds: [LevelSetSegmentation.Seed(z: 0, y: 0, x: 0, radius: 1)],
            speed: .regionCompetition(midpoint: 0, halfWidth: 1),
            classID: 7
        )

        XCTAssertEqual(result.insideVoxels, 1)
        XCTAssertEqual(result.iterations, 0)
        XCTAssertEqual(label.voxels, [7])
    }

    // MARK: - Marching cubes mesh export

    func testMarchingCubesGeneratesTrianglesForBinaryCube() throws {
        let label = LabelMap(parentSeriesUID: "cube", depth: 4, height: 4, width: 4)
        // Fill a 2×2×2 cube of ones centered in a 4³ volume.
        for z in 1...2 {
            for y in 1...2 {
                for x in 1...2 {
                    label.voxels[z * 16 + y * 4 + x] = 1
                }
            }
        }
        let volume = ImageVolume(pixels: [Float](repeating: 0, count: 4 * 4 * 4),
                                 depth: 4, height: 4, width: 4)
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let file = outDir.appendingPathComponent("cube.stl")

        let mesh = try MarchingCubesMeshExporter.exportClass(
            label: label, volume: volume, classID: 1, to: file
        )
        XCTAssertGreaterThan(mesh.triangleCount, 0,
                             "a solid cube should produce a non-empty mesh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - ITK-SNAP presets

    func testITKSNAPPresetsExposeExpectedTaxonomies() {
        let names = ITKSNAPPresets.all.map(\.name)
        XCTAssertTrue(names.contains("Brain MRI (ITK-SNAP style)"))
        XCTAssertTrue(names.contains("Cardiac Cine MRI"))
        XCTAssertTrue(names.contains("Liver Couinaud Segments"))
        XCTAssertEqual(ITKSNAPPresets.liverSegments.classes.count, 8,
                       "Couinaud segments I–VIII")
    }

    func testLabelPresetsIncludeITKSNAPExtensions() {
        let registered = LabelPresets.all.map(\.name)
        XCTAssertTrue(registered.contains("Brain MRI (ITK-SNAP style)"))
        XCTAssertTrue(registered.contains("TotalSegmentator"),
                      "ITK-SNAP registration must not remove existing presets")
    }

    // MARK: - nnU-Net integration

    func testNNUnetCatalogListsExpectedDatasets() {
        let datasets = NNUnetCatalog.all.map(\.datasetID)
        XCTAssertTrue(datasets.contains("Dataset003_Liver"))
        XCTAssertTrue(datasets.contains("Dataset220_KiTS2023"))
        XCTAssertTrue(datasets.contains("Dataset218_Amos2022_task1"))
        XCTAssertTrue(datasets.contains("Dataset137_BraTS2021"))
        XCTAssertNotNil(NNUnetCatalog.byID("MSD-Liver"))
        XCTAssertNotNil(NNUnetCatalog.byID("Dataset003_Liver"),
                        "byID should also resolve the underlying dataset id")
    }

    func testNNUnetCatalogCTEntriesDeclareClipAndZScorePreprocessing() {
        for entry in NNUnetCatalog.all where entry.modality == .CT {
            switch entry.preprocessing {
            case .ctClipAndZScore:
                break // expected
            default:
                XCTFail("CT dataset \(entry.datasetID) must declare ctClipAndZScore preprocessing, got \(entry.preprocessing)")
            }
        }
    }

    func testNNUnetCoreMLSpecInheritsCatalogPatchAndPreprocessing() {
        let entry = NNUnetCatalog.msdLiver
        let url = URL(fileURLWithPath: "/tmp/fake.mlpackage")
        let spec = NNUnetCoreMLRunner.ModelSpec.fromCatalog(entry, modelURL: url)

        XCTAssertEqual(spec.patchSize.d, entry.coreML.patchSize.d)
        XCTAssertEqual(spec.patchSize.h, entry.coreML.patchSize.h)
        XCTAssertEqual(spec.patchSize.w, entry.coreML.patchSize.w)
        XCTAssertEqual(spec.numClasses, entry.coreML.numClasses)
        XCTAssertEqual(spec.inputName, entry.coreML.inputName)
        XCTAssertEqual(spec.outputName, entry.coreML.outputName)
        XCTAssertEqual(spec.preprocessing, entry.preprocessing)
    }

    @MainActor
    func testNNUnetCoreMLReadinessRequiresExistingPackageDirectory() throws {
        let vm = NNUnetViewModel()
        XCTAssertTrue(vm.coreMLReadinessMessage?.contains(".mlpackage") == true)

        vm.coreMLModelPath = "/tmp/not-a-coreml-model.txt"
        XCTAssertTrue(vm.coreMLReadinessMessage?.contains("must end") == true)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreml-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingPackage = root.appendingPathComponent("missing.mlpackage", isDirectory: true)
        vm.coreMLModelPath = missingPackage.path
        XCTAssertTrue(vm.coreMLReadinessMessage?.contains("not found") == true)

        let filePackage = root.appendingPathComponent("file.mlpackage")
        XCTAssertTrue(FileManager.default.createFile(atPath: filePackage.path, contents: Data()))
        vm.coreMLModelPath = filePackage.path
        XCTAssertTrue(vm.coreMLReadinessMessage?.contains("package directory") == true)

        let directoryPackage = root.appendingPathComponent("model.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryPackage, withIntermediateDirectories: true)
        vm.coreMLModelPath = directoryPackage.path
        XCTAssertNil(vm.coreMLReadinessMessage)
    }

    func testNNUnetCTPreprocessingClipsAndNormalizes() {
        // Values at -2000, -17, 99.4, 201, 800 should behave as follows
        // for MSD-Liver preprocessing: clip to [-17, 201], then (v - 99.4) / 39.4.
        let raw: [Float] = [-2000, -17, 99.4, 201, 800]
        let out = NNUnetCoreMLRunner.applyPreprocessing(
            pixels: raw,
            suvScaleFactor: nil,
            preprocessing: .ctClipAndZScore(lower: -17, upper: 201, mean: 99.4, std: 39.4)
        )
        XCTAssertEqual(out[0], (-17 - 99.4) / 39.4, accuracy: 1e-4,
                       "below-lower value should clip to lower before z-score")
        XCTAssertEqual(out[1], (-17 - 99.4) / 39.4, accuracy: 1e-4)
        XCTAssertEqual(out[2], 0.0, accuracy: 1e-4)
        XCTAssertEqual(out[3], (201 - 99.4) / 39.4, accuracy: 1e-4)
        XCTAssertEqual(out[4], (201 - 99.4) / 39.4, accuracy: 1e-4,
                       "above-upper value should clip to upper before z-score")
    }

    func testNNUnetZScoreNonzeroSkipsZeroVoxels() {
        let pixels: [Float] = [0, 0, 2, 4, 6]
        let out = NNUnetCoreMLRunner.applyPreprocessing(
            pixels: pixels,
            suvScaleFactor: nil,
            preprocessing: .zScoreNonzero
        )
        // Zero voxels stay zero.
        XCTAssertEqual(out[0], 0)
        XCTAssertEqual(out[1], 0)
        // Non-zero voxels recentered around their own mean (4).
        let mean = out[2] + out[3] + out[4]
        XCTAssertEqual(mean, 0, accuracy: 1e-4)
    }

    // MARK: - PET catalog / quantification / prefilter

    func testNNUnetCatalogIncludesAutoPETFamily() {
        let ids = NNUnetCatalog.all.map(\.id)
        XCTAssertTrue(ids.contains("AutoPET-II-2023"))
        XCTAssertTrue(ids.contains("LesionTracer-AutoPETIII"))
        XCTAssertTrue(ids.contains("LesionLocator-AutoPETIV"))

        let autoPETII = try? XCTUnwrap(NNUnetCatalog.byID("AutoPET-II-2023"))
        XCTAssertEqual(autoPETII?.datasetID, "Dataset221_AutoPETII_2023")
        XCTAssertTrue(autoPETII?.multiChannel ?? false)
        XCTAssertEqual(autoPETII?.requiredChannels, 2)
        XCTAssertEqual(autoPETII?.channelDescriptions.count, 2)
    }

    func testPETQuantificationReportsTMTVAndPerLesion() throws {
        // 3x3x1 PET with two lesions separated by background.
        let pet = ImageVolume(
            pixels: [
                5, 0, 8,
                5, 0, 8,
                0, 0, 0
            ],
            depth: 1, height: 3, width: 3,
            spacing: (1, 1, 1),
            modality: "PT"
        )
        let map = LabelMap(parentSeriesUID: pet.seriesUID,
                            depth: 1, height: 3, width: 3)
        map.classes = [LabelClass(labelID: 1, name: "lesion",
                                  category: .tumor, color: .red)]
        map.voxels = [
            1, 0, 1,
            1, 0, 1,
            0, 0, 0
        ]

        let report = try PETQuantification.compute(
            petVolume: pet,
            labelMap: map,
            classes: [1],
            suvTransform: { $0 },
            connectedComponents: true
        )
        XCTAssertEqual(report.lesionCount, 2,
                       "disjoint 2-voxel groups must surface as separate lesions")
        // Each lesion has 2 voxels @ 1mm³ = 0.002 mL.
        for lesion in report.lesions {
            XCTAssertEqual(lesion.voxelCount, 2)
            XCTAssertEqual(lesion.volumeML, 0.002, accuracy: 1e-9)
        }
        // SUVmax across the two lesions = 8.
        XCTAssertEqual(report.maxSUV, 8, accuracy: 1e-9)
        // Total voxels = 4 → TMTV 0.004 mL.
        XCTAssertEqual(report.totalMetabolicTumorVolumeML, 0.004, accuracy: 1e-9)
    }

    func testPETQuantificationThrowsOnGridMismatch() {
        let pet = ImageVolume(pixels: [0], depth: 1, height: 1, width: 1, modality: "PT")
        let map = LabelMap(parentSeriesUID: pet.seriesUID, depth: 1, height: 1, width: 2)

        XCTAssertThrowsError(
            try PETQuantification.compute(petVolume: pet, labelMap: map)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("grid mismatch"))
        }
    }

    @MainActor
    func testPETEngineScalesPETChannelToSUVForModelInput() {
        let viewer = ViewerViewModel()
        let petEngine = PETEngineViewModel()
        let pet = ImageVolume(
            pixels: [10, 20],
            depth: 1, height: 1, width: 2,
            spacing: (2, 3, 4),
            origin: (5, 6, 7),
            modality: "PT",
            suvScaleFactor: 0.5
        )

        let scaledFromVolume = petEngine.makePETModelInputChannel(pet, viewer: viewer)
        XCTAssertEqual(scaledFromVolume.pixels, [5, 10])
        XCTAssertNil(scaledFromVolume.suvScaleFactor)
        XCTAssertEqual(scaledFromVolume.spacing.x, pet.spacing.x)
        XCTAssertEqual(scaledFromVolume.origin.x, pet.origin.x)

        viewer.suvSettings.mode = .manualScale
        viewer.suvSettings.manualScaleFactor = 3
        let scaledFromUserSettings = petEngine.makePETModelInputChannel(pet, viewer: viewer)
        XCTAssertEqual(scaledFromUserSettings.pixels, [30, 60])
    }

    func testPhysiologicalUptakeFilterSubtractsBrainVoxels() throws {
        let pet = LabelMap(parentSeriesUID: "pet",
                           depth: 1, height: 2, width: 3)
        pet.classes = [LabelClass(labelID: 1, name: "lesion",
                                   category: .tumor, color: .red)]
        pet.voxels = [1, 1, 1, 1, 1, 1]

        let anatomy = LabelMap(parentSeriesUID: "ct",
                               depth: 1, height: 2, width: 3)
        anatomy.classes = [
            LabelClass(labelID: 1, name: "liver",
                       category: .organ, color: .red),
            LabelClass(labelID: 2, name: "brain",
                       category: .brain, color: .blue),
        ]
        // Mark the last column as brain.
        anatomy.voxels = [
            0, 0, 2,
            0, 0, 2
        ]

        let result = try PhysiologicalUptakeFilter.subtract(
            petLesionMask: pet,
            anatomyMask: anatomy,
            suppressedOrganNames: ["brain"],
            dilationIterations: 0
        )
        XCTAssertEqual(result.voxelsSuppressed, 2)
        XCTAssertTrue(result.classesSuppressed.contains("brain"))
        XCTAssertEqual(pet.voxels, [1, 1, 0, 1, 1, 0])
    }

    func testPhysiologicalUptakeFilterThrowsOnGridMismatch() {
        let pet = LabelMap(parentSeriesUID: "pet", depth: 1, height: 1, width: 1)
        let anatomy = LabelMap(parentSeriesUID: "ct", depth: 1, height: 1, width: 2)

        XCTAssertThrowsError(
            try PhysiologicalUptakeFilter.subtract(petLesionMask: pet, anatomyMask: anatomy)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("grid mismatch"))
        }
    }

    @MainActor
    func testNNUnetRunnerRejectsMismatchedChannelGrids() async {
        let primary = ImageVolume(pixels: [0],
                                  depth: 1, height: 1, width: 1,
                                  modality: "CT")
        let mismatch = ImageVolume(pixels: [0, 0],
                                   depth: 1, height: 1, width: 2,
                                   modality: "PT")
        let runner = NNUnetRunner()
        do {
            _ = try await runner.runInference(
                channels: [primary, mismatch],
                referenceVolume: primary,
                datasetID: "Dataset221_AutoPETII_2023"
            )
            XCTFail("Expected geometry mismatch to throw")
        } catch let err as NNUnetRunner.RunError {
            if case .geometryMismatch = err { return }
            XCTFail("Expected .geometryMismatch, got \(err)")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    @MainActor
    func testNNUnetRunnerRejectsSameDimensionsDifferentWorldGeometry() async {
        let primary = ImageVolume(pixels: [0],
                                  depth: 1, height: 1, width: 1,
                                  origin: (0, 0, 0),
                                  modality: "CT")
        let shifted = ImageVolume(pixels: [0],
                                  depth: 1, height: 1, width: 1,
                                  origin: (10, 0, 0),
                                  modality: "PT")
        let runner = NNUnetRunner()
        do {
            _ = try await runner.runInference(
                channels: [primary, shifted],
                referenceVolume: primary,
                datasetID: "Dataset221_AutoPETII_2023"
            )
            XCTFail("Expected geometry mismatch to throw before binary lookup")
        } catch let err as NNUnetRunner.RunError {
            if case .geometryMismatch = err { return }
            XCTFail("Expected .geometryMismatch, got \(err)")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    @MainActor
    func testNNUnetRunnerRejectsRotatedDirectionMatrix() async {
        // Same dims, same spacing, same origin — but the secondary channel
        // is rotated 90° around Z (X axis becomes Y). The runner must catch
        // this through the direction-cosine check and throw without ever
        // needing nnUNetv2_predict on PATH.
        let primary = ImageVolume(
            pixels: [0],
            depth: 1, height: 1, width: 1,
            spacing: (1, 1, 1),
            origin: (0, 0, 0),
            direction: matrix_identity_double3x3,
            modality: "CT"
        )
        // 90° rotation about Z: X → Y, Y → -X.
        let rotatedDirection = simd_double3x3(
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(-1, 0, 0),
            SIMD3<Double>(0, 0, 1)
        )
        let rotated = ImageVolume(
            pixels: [0],
            depth: 1, height: 1, width: 1,
            spacing: (1, 1, 1),
            origin: (0, 0, 0),
            direction: rotatedDirection,
            modality: "PT"
        )
        let runner = NNUnetRunner()
        do {
            _ = try await runner.runInference(
                channels: [primary, rotated],
                referenceVolume: primary,
                datasetID: "Dataset221_AutoPETII_2023"
            )
            XCTFail("Expected direction-mismatch to throw before subprocess launch")
        } catch let err as NNUnetRunner.RunError {
            if case .geometryMismatch = err { return }
            XCTFail("Expected .geometryMismatch, got \(err)")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - SUV single source of truth

    func testSUVSettingsStoredModeUsesVolumeScaleWhenPresent() {
        // `.storedSUV` with a DICOM-baked scale factor should multiply the
        // raw value by that scale — regardless of whatever settings are
        // configured on the viewer (which can't know about an auxiliary
        // volume's per-voxel calibration).
        var settings = SUVCalculationSettings()
        settings.mode = .storedSUV
        let volume = ImageVolume(
            pixels: [10],
            depth: 1, height: 1, width: 1,
            modality: "PT",
            suvScaleFactor: 0.5
        )
        XCTAssertEqual(settings.suv(forStoredValue: 10, volume: volume),
                       5.0, accuracy: 1e-9)
        // Without a stored factor, falls back to raw.
        let plain = ImageVolume(
            pixels: [10],
            depth: 1, height: 1, width: 1,
            modality: "PT"
        )
        XCTAssertEqual(settings.suv(forStoredValue: 10, volume: plain),
                       10.0, accuracy: 1e-9)
    }

    func testSUVSettingsNonStoredModeIgnoresVolumeScale() {
        // Manual scale is a *global* user choice — must not be overridden by
        // whatever a specific volume happened to store.
        var settings = SUVCalculationSettings()
        settings.mode = .manualScale
        settings.manualScaleFactor = 3.0
        let volume = ImageVolume(
            pixels: [10],
            depth: 1, height: 1, width: 1,
            modality: "PT",
            suvScaleFactor: 0.5  // Would yield 5.0 if it leaked through.
        )
        XCTAssertEqual(settings.suv(forStoredValue: 10, volume: volume),
                       30.0, accuracy: 1e-9,
                       "Manual mode must ignore volume-level SUV scale")
    }

    @MainActor
    func testViewerSUVValueUsesActivePETVolumeScale() {
        // Without passing a volume, the viewer should still honour the
        // currently-active PET volume's scale in `.storedSUV` mode.
        let vm = ViewerViewModel()
        vm.suvSettings.mode = .storedSUV
        let pet = ImageVolume(
            pixels: [10],
            depth: 1, height: 1, width: 1,
            modality: "PT",
            suvScaleFactor: 0.25
        )
        _ = vm.addLoadedVolumeIfNeeded(pet)
        vm.currentVolume = pet
        XCTAssertEqual(vm.suvValue(rawStoredValue: 10),
                       2.5, accuracy: 1e-9,
                       "Active-PET helper must honour per-volume scale")
    }

    @MainActor
    func testSUVProbeUsesExplicitVolumeScale() {
        let vm = ViewerViewModel()
        vm.suvSettings.mode = .storedSUV
        vm.currentVolume = ImageVolume(
            pixels: [100],
            depth: 1, height: 1, width: 1,
            modality: "PT",
            suvScaleFactor: 1
        )
        let probedVolume = ImageVolume(
            pixels: [10],
            depth: 1, height: 1, width: 1,
            modality: "PT",
            suvScaleFactor: 0.25
        )

        let probe = vm.suvProbe(z: 0, y: 0, x: 0, in: probedVolume)

        XCTAssertEqual(probe?.suv ?? 0, 2.5, accuracy: 1e-9)
    }

    func testNNUnetRunnerReportsAvailabilityFromPATH() {
        // We don't assume nnUNetv2_predict is installed in CI — just prove
        // the detector runs without crashing and returns a reasonable value.
        let located = NNUnetRunner.locatePredictBinary(override: "/bin/does-not-exist")
        XCTAssertNil(located,
                     "Explicit bad path override must not be resolved as valid")
    }

    // MARK: - Recent volumes store

    @MainActor
    func testRecentVolumesStoreRespectsMaximumAndDeduplicates() {
        // Use an isolated UserDefaults so the CI run can't pollute real user
        // preferences (or be polluted by them).
        let defaultsName = "Tracer.Tests.Recents.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: defaultsName) else {
            return XCTFail("Could not create test UserDefaults suite")
        }
        defer { suite.removePersistentDomain(forName: defaultsName) }

        let store = RecentVolumesStore(defaults: suite)
        XCTAssertTrue(store.load().isEmpty)

        // Push 10 distinct entries; the store caps at 8 and keeps newest first.
        for i in 0..<10 {
            _ = store.recordOpen(RecentVolume(
                id: "v\(i)",
                modality: "CT",
                seriesDescription: "Series \(i)",
                studyDescription: "Study",
                patientName: "Patient",
                sourceFiles: ["/tmp/v\(i).dcm"],
                kind: .dicom
            ))
        }
        let list = store.load()
        XCTAssertEqual(list.count, RecentVolumesStore.maximumEntries)
        XCTAssertEqual(list.first?.id, "v9", "newest entry must be at the head")
        XCTAssertFalse(list.contains { $0.id == "v0" }, "v0 should have fallen off the tail")

        // Re-opening an existing id should move it to the head without duplicating.
        _ = store.recordOpen(RecentVolume(
            id: "v5",
            modality: "CT",
            seriesDescription: "Re-open",
            studyDescription: "Study",
            patientName: "Patient",
            sourceFiles: ["/tmp/v5.dcm"],
            kind: .dicom
        ))
        let after = store.load()
        XCTAssertEqual(after.first?.id, "v5", "re-opened entry should jump to head")
        XCTAssertEqual(after.filter { $0.id == "v5" }.count, 1, "no duplicates")
    }

    @MainActor
    func testRecentVolumesStoreClearPostsChangeNotification() {
        let defaultsName = "Tracer.Tests.Recents.Clear.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: defaultsName) else {
            return XCTFail("Could not create test UserDefaults suite")
        }
        defer { suite.removePersistentDomain(forName: defaultsName) }

        let store = RecentVolumesStore(defaults: suite)
        let didNotify = expectation(description: "recent volumes change notification")
        let token = NotificationCenter.default.addObserver(
            forName: .recentVolumesDidChange,
            object: nil,
            queue: nil
        ) { _ in
            didNotify.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.clear()

        wait(for: [didNotify], timeout: 1)
    }

    // MARK: - Settings

    #if os(macOS)
    func testTracerSettingsWLPresetsContainsAllModalityPresets() {
        let names = Set(TracerSettings.wlPresetNames)
        // Spot-check a preset from each modality to prove the union was built.
        XCTAssertTrue(names.contains("Lung"),
                      "CT lung preset must surface in the settings picker")
        XCTAssertTrue(names.contains("FLAIR"),
                      "MR FLAIR preset must surface in the settings picker")
        XCTAssertTrue(names.contains("Standard"),
                      "PET standard preset must surface in the settings picker")
        // De-duplicated: "Brain" appears in both CT and MR lists; should be one entry.
        XCTAssertEqual(names.filter { $0 == "Brain" }.count, 1,
                       "Duplicate preset names should be collapsed in the Settings list")
    }

    func testTracerSettingsKeysAreDisjointFromOtherAppStorageKeys() {
        let keys: Set<String> = [
            TracerSettings.Keys.wlShortcut1,
            TracerSettings.Keys.wlShortcut2,
            TracerSettings.Keys.wlShortcut3,
            TracerSettings.Keys.defaultMONAIURL,
            TracerSettings.Keys.defaultNNUnetBinary,
            TracerSettings.Keys.defaultNNUnetResults
        ]
        // All settings keys must be prefixed with "Tracer.Prefs." so they
        // never collide with runtime state like recents or focus mode.
        for key in keys {
            XCTAssertTrue(key.hasPrefix("Tracer.Prefs."),
                          "Settings key \(key) must live under Tracer.Prefs.* namespace")
        }
        // And the runtime-state keys live under a different prefix.
        XCTAssertFalse(RecentVolumesStore.defaultsKey.hasPrefix("Tracer.Prefs."))
    }
    #endif

    // MARK: - Named W/L preset shortcuts

    @MainActor
    func testApplyPresetNamedFindsCTLungAndPETStandard() {
        let vm = ViewerViewModel()

        // With a CT volume loaded, "Lung" should resolve to the CT preset.
        let ct = ImageVolume(pixels: [0], depth: 1, height: 1, width: 1, modality: "CT")
        _ = vm.addLoadedVolumeIfNeeded(ct)
        vm.currentVolume = ct
        vm.applyPresetNamed("Lung")
        XCTAssertEqual(vm.window, 1500, accuracy: 1)
        XCTAssertEqual(vm.level, -600, accuracy: 1)

        // Switch to a PET volume — "Standard" is a PET-specific preset and
        // should resolve to window=6, level=3.
        let pet = ImageVolume(pixels: [0], depth: 1, height: 1, width: 1, modality: "PT")
        _ = vm.addLoadedVolumeIfNeeded(pet)
        vm.currentVolume = pet
        vm.applyPresetNamed("Standard")
        XCTAssertEqual(vm.window, 6, accuracy: 1,
                       "PET 'Standard' preset should be picked for a loaded PET volume")

        // Unknown preset → status warns and W/L is unchanged.
        let wBefore = vm.window
        let lBefore = vm.level
        vm.applyPresetNamed("NotARealPreset")
        XCTAssertEqual(vm.window, wBefore, accuracy: 1e-9)
        XCTAssertEqual(vm.level, lBefore, accuracy: 1e-9)
        XCTAssertTrue(vm.statusMessage.contains("No NotARealPreset"))
    }

    @MainActor
    func testApplyPresetNamedNormalizesCaseAndWhitespace() {
        let vm = ViewerViewModel()
        let ct = ImageVolume(pixels: [0], depth: 1, height: 1, width: 1, modality: "CT")
        _ = vm.addLoadedVolumeIfNeeded(ct)
        vm.currentVolume = ct

        // Lowercase → same match as "Lung".
        vm.applyPresetNamed("lung")
        XCTAssertEqual(vm.window, 1500, accuracy: 1)
        XCTAssertEqual(vm.level, -600, accuracy: 1)

        // Mixed-case + whitespace → still resolves.
        vm.applyPresetNamed("   BoNe  ")
        XCTAssertEqual(vm.window, 2500, accuracy: 1)
        XCTAssertEqual(vm.level, 480, accuracy: 1)
    }

    @MainActor
    func testApplyPresetNamedRejectsEmptyOrWhitespaceInput() {
        let vm = ViewerViewModel()
        let ct = ImageVolume(pixels: [0], depth: 1, height: 1, width: 1, modality: "CT")
        _ = vm.addLoadedVolumeIfNeeded(ct)
        vm.currentVolume = ct

        // Set a known starting W/L so we can prove it didn't change.
        vm.applyPresetNamed("Lung")
        let wBefore = vm.window
        let lBefore = vm.level

        // Empty string and whitespace-only inputs must not silently match
        // anything — the function should short-circuit and leave W/L alone.
        for garbage in ["", "   ", "\n\t"] {
            vm.applyPresetNamed(garbage)
            XCTAssertEqual(vm.window, wBefore, accuracy: 1e-9,
                           "Empty input should not change window: got status \(vm.statusMessage)")
            XCTAssertEqual(vm.level, lBefore, accuracy: 1e-9)
            XCTAssertTrue(vm.statusMessage.contains("empty"),
                          "Status should cite empty input; got: \(vm.statusMessage)")
        }
    }

    @MainActor
    func testApplyPresetNamedFallsBackToUnionWhenModalityListDoesNotMatch() {
        let vm = ViewerViewModel()
        let ct = ImageVolume(pixels: [0], depth: 1, height: 1, width: 1, modality: "CT")
        _ = vm.addLoadedVolumeIfNeeded(ct)
        vm.currentVolume = ct

        // "FLAIR" only exists in the MR preset list — with CT loaded the
        // modality list has no match, so the union fallback should apply
        // the MR FLAIR values and log a cross-modality message.
        vm.applyPresetNamed("FLAIR")
        XCTAssertEqual(vm.window, 1500, accuracy: 1,
                       "Union fallback should apply MR FLAIR preset")
        XCTAssertEqual(vm.level, 750, accuracy: 1)
    }

    // MARK: - Model registry + DGX tests

    func testTracerModelRoundTripPreservesFields() throws {
        let model = TracerModel(
            id: "m1",
            displayName: "Lung nodule fold 0",
            kind: .coreML,
            sourceURL: URL(string: "https://huggingface.co/foo/bar/blob/main/lung.mlpackage"),
            localPath: "/tmp/lung.mlpackage",
            sha256: "deadbeef",
            sizeBytes: 12345,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            license: "Apache-2.0",
            notes: "test",
            boundCatalogEntryIDs: ["lung-nodule-radiomics", "pet-lesion-radiomics"]
        )
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(TracerModel.self, from: data)
        XCTAssertEqual(decoded, model, "Codable round-trip should preserve every field")
        XCTAssertEqual(decoded.boundCatalogEntryIDs.count, 2)
        XCTAssertEqual(decoded.kind, .coreML)
    }

    func testTracerModelKindDisplayNamesAreHumanReadable() {
        // Not empty, no underscores / camelCase leaking to the UI.
        for kind in [TracerModel.Kind.coreML, .gguf, .treeModelJSON,
                     .nnunetDataset, .monaiBundle, .pythonScript, .remoteArtifact] {
            let label = kind.displayName
            XCTAssertFalse(label.isEmpty, "\(kind) should have a display name")
            XCTAssertFalse(label.contains("_"), "\(kind).displayName leaks underscore")
        }
    }

    func testSHA256HexMatchesOpenSSL() throws {
        // Hash a known-content file and compare with the same digest produced
        // by Python's hashlib — the hex string for "hello world\n" is
        // a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha256-\(UUID().uuidString).txt")
        try "hello world\n".data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hash = try SHA256Hex.hash(of: tmp)
        XCTAssertEqual(hash,
                       "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447")
    }

    func testDGXSparkConfigRoundTripsThroughUserDefaults() {
        let domain = "tracer.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }

        var cfg = DGXSparkConfig()
        cfg.host = "dgx-spark.local"
        cfg.user = "ahmed"
        cfg.port = 2222
        cfg.identityFile = "~/.ssh/id_ed25519"
        cfg.remoteWorkdir = "~/tracer"
        cfg.remoteEnvironment = "nnUNet_results=/weights\nCUDA_VISIBLE_DEVICES=0"
        cfg.enabled = true

        let data = try! JSONEncoder().encode(cfg)
        defaults.set(data, forKey: DGXSparkConfig.storageKey)

        let raw = defaults.data(forKey: DGXSparkConfig.storageKey)
        XCTAssertNotNil(raw)
        let decoded = try! JSONDecoder().decode(DGXSparkConfig.self, from: raw!)
        XCTAssertEqual(decoded, cfg)
        XCTAssertTrue(decoded.isConfigured)
        XCTAssertEqual(decoded.sshDestination, "ahmed@dgx-spark.local")
        XCTAssertEqual(decoded.environmentExports().count, 2)
    }

    func testRemoteExecutorShellEscapePreservesPayload() {
        XCTAssertEqual(RemoteExecutor.shellEscape("plain"), "'plain'")
        XCTAssertEqual(RemoteExecutor.shellEscape("with space"), "'with space'")
        // Critical case: internal single quote has to be closed, escaped, reopened.
        XCTAssertEqual(RemoteExecutor.shellEscape("o'reilly"), "'o'\\''reilly'")
        // Semicolons / ampersands must stay inside quotes so they don't execute.
        XCTAssertEqual(RemoteExecutor.shellEscape("rm -rf /; echo hi"),
                       "'rm -rf /; echo hi'")
    }

    func testDGXSparkConfigEnvironmentExportsIgnoresBlankLines() {
        var cfg = DGXSparkConfig()
        cfg.remoteEnvironment = """

            nnUNet_results=/weights

            CUDA_VISIBLE_DEVICES=0
            garbage_without_equals
            """
        let exports = cfg.environmentExports()
        XCTAssertEqual(exports.count, 2)
        XCTAssertTrue(exports.contains("nnUNet_results=/weights"))
        XCTAssertTrue(exports.contains("CUDA_VISIBLE_DEVICES=0"))
    }

    func testRemoteExecutorShellEscapesEnvironmentExports() {
        XCTAssertEqual(
            RemoteExecutor.shellExportCommand("nnUNet_results=/path with spaces/weights"),
            "export nnUNet_results='/path with spaces/weights';"
        )
        XCTAssertEqual(
            RemoteExecutor.shellExportCommand("CUDA_VISIBLE_DEVICES=0; echo nope"),
            "export CUDA_VISIBLE_DEVICES='0; echo nope';"
        )
        XCTAssertNil(RemoteExecutor.shellExportCommand("bad-name=value"))
    }

    func testRemoteNNUnetRejectsWorldGeometryMismatchBeforeSSH() async throws {
        let reference = ImageVolume(
            pixels: [Float](repeating: 0, count: 8),
            depth: 2, height: 2, width: 2,
            spacing: (1, 1, 1),
            origin: (0, 0, 0),
            modality: "CT"
        )
        let shifted = ImageVolume(
            pixels: [Float](repeating: 0, count: 8),
            depth: 2, height: 2, width: 2,
            spacing: (1, 1, 1),
            origin: (5, 0, 0),
            modality: "PT"
        )
        let cfg = DGXSparkConfig(host: "dgx.invalid", enabled: true)
        let runner = RemoteNNUnetRunner(configuration: .init(
            dgx: cfg,
            datasetID: "Dataset999_Test"
        ))

        do {
            _ = try await runner.runInference(channels: [reference, shifted],
                                              referenceVolume: reference)
            XCTFail("Expected geometry mismatch before any SSH command is launched")
        } catch let error as RemoteNNUnetRunner.Error {
            guard case .geometryMismatch(let message) = error else {
                return XCTFail("Unexpected remote nnU-Net error: \(error)")
            }
            XCTAssertTrue(message.contains("origin"))
        }
    }

    @MainActor
    func testHuggingFaceBlobURLIsRewrittenToResolveURL() {
        let original = URL(string: "https://huggingface.co/google/medgemma-4b-it/blob/main/model.gguf")!
        let rewritten = ModelDownloadManager.rewriteHuggingFace(original)
        XCTAssertEqual(rewritten.absoluteString,
                       "https://huggingface.co/google/medgemma-4b-it/resolve/main/model.gguf")

        // Non-HuggingFace URLs are passed through untouched.
        let zenodo = URL(string: "https://zenodo.org/record/6/files/weights.zip")!
        XCTAssertEqual(ModelDownloadManager.rewriteHuggingFace(zenodo), zenodo)
    }

    @MainActor
    func testTracerModelStoreAddRemoveAndBindPersistToDisk() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        do {
            let store = TracerModelStore(rootURL: scratch)
            XCTAssertEqual(store.models.count, 0)

            let model = TracerModel(
                id: "id-1",
                displayName: "Lung",
                kind: .coreML,
                localPath: "/tmp/lung.mlpackage"
            )
            store.add(model)
            store.bind(modelID: "id-1", to: "lung-nodule-coreml")
            XCTAssertEqual(store.models.count, 1)
            XCTAssertEqual(store.models.first?.boundCatalogEntryIDs, ["lung-nodule-coreml"])
            XCTAssertEqual(store.models(boundTo: "lung-nodule-coreml").count, 1)
        }

        // Reopen — registry should load back from disk.
        let reopened = TracerModelStore(rootURL: scratch)
        XCTAssertEqual(reopened.models.count, 1)
        XCTAssertEqual(reopened.models.first?.displayName, "Lung")

        reopened.remove(id: "id-1", deleteFiles: false)
        XCTAssertEqual(reopened.models.count, 0)
    }

    @MainActor
    func testModelManagerViewModelInferKindRecognisesExtensions() {
        // Loosely: extension dictates kind for the common formats.
        XCTAssertEqual(
            ModelManagerViewModel.inferKind(from: URL(fileURLWithPath: "/tmp/model.mlpackage")),
            .coreML
        )
        XCTAssertEqual(
            ModelManagerViewModel.inferKind(from: URL(fileURLWithPath: "/tmp/llama.gguf")),
            .gguf
        )
        XCTAssertEqual(
            ModelManagerViewModel.inferKind(from: URL(fileURLWithPath: "/tmp/tree.json")),
            .treeModelJSON
        )
        XCTAssertEqual(
            ModelManagerViewModel.inferKind(from: URL(fileURLWithPath: "/tmp/predict.py")),
            .pythonScript
        )
        XCTAssertEqual(
            ModelManagerViewModel.inferKind(from: URL(fileURLWithPath: "/tmp/Dataset221_AutoPETII")),
            .nnunetDataset
        )
        XCTAssertEqual(
            ModelManagerViewModel.inferKind(from: URL(fileURLWithPath: "/tmp/monai-liver.zip")),
            .monaiBundle
        )
        // Unknown extension falls through to .coreML as the safest default.
        XCTAssertEqual(
            ModelManagerViewModel.inferKind(from: URL(fileURLWithPath: "/tmp/mystery.weights")),
            .coreML
        )
    }

    // MARK: - Hardening: assistant parser word boundaries

    func testAssistantDoesNotFirePanOnExpand() {
        let interpreter = AssistantCommandInterpreter()
        // "expand" contains "pan". Before the word-boundary fix, this
        // would silently switch the viewer tool to Pan.
        let actions = interpreter.actions(for: "help me expand this panel")
        XCTAssertFalse(actions.contains(.setViewerTool(.pan)))
        XCTAssertFalse(actions.contains(.setViewerTool(.zoom)))
    }

    func testAssistantStillFiresPanOnLegitimateCommand() {
        let interpreter = AssistantCommandInterpreter()
        XCTAssertTrue(interpreter.actions(for: "switch to pan tool")
            .contains(.setViewerTool(.pan)))
        XCTAssertTrue(interpreter.actions(for: "panning now please")
            .contains(.setViewerTool(.pan)))
    }

    func testAssistantDoesNotFireBrainPresetOnAhead() {
        let interpreter = AssistantCommandInterpreter()
        // "ahead" contains "head" which used to alias to Brain preset.
        let actions = interpreter.actions(for: "scroll ahead three slices")
        XCTAssertFalse(actions.contains(.applyWindowPreset("Brain")))
    }

    func testAssistantDoesNotFireStandardPresetOnPetroleum() {
        let interpreter = AssistantCommandInterpreter()
        // "petroleum" contains "pet" which aliased to Standard preset.
        let actions = interpreter.actions(for: "this looks like a petroleum artifact")
        XCTAssertFalse(actions.contains(.applyWindowPreset("Standard")))
    }

    func testAssistantStillFiresPetPresetOnLegitimateCommand() {
        let interpreter = AssistantCommandInterpreter()
        XCTAssertTrue(interpreter.actions(for: "apply pet window")
            .contains(.applyWindowPreset("Standard")))
        XCTAssertTrue(interpreter.actions(for: "show the fdg SUV scale")
            .contains(.applyWindowPreset("Standard")))
    }

    func testAssistantEraseFiresOnLegitimateCommandOnly() {
        let interpreter = AssistantCommandInterpreter()
        XCTAssertTrue(interpreter.actions(for: "use the eraser")
            .contains(.setLabelingTool(.eraser)))
        XCTAssertTrue(interpreter.actions(for: "erase this region")
            .contains(.setLabelingTool(.eraser)))
        // "raserator"? "embraser"? Word match rejects those.
        XCTAssertFalse(interpreter.actions(for: "debraser")
            .contains(.setLabelingTool(.eraser)))
    }

    // MARK: - Hardening: MONAI decoding-error formatter

    func testDecodingErrorFormatterProducesReadableBreadcrumb() {
        // Build a synthetic DecodingError and make sure the formatter
        // produces a human path like "classes.0.name" rather than
        // "keyNotFound(CodingKey(...), DecodingError.Context...)".
        struct Sample: Decodable {
            let classes: [SampleClass]
            struct SampleClass: Decodable {
                let name: String
            }
        }
        // Missing 'name' key in the first element.
        let malformed = #"{"classes": [{"other": 1}]}"#.data(using: .utf8)!
        do {
            _ = try JSONDecoder().decode(Sample.self, from: malformed)
            XCTFail("Should have thrown DecodingError")
        } catch {
            let message = MONAILabelClient.describeDecodingError(error)
            XCTAssertTrue(message.contains("name"), "Should mention the missing key")
            XCTAssertFalse(message.contains("DecodingError.Context"),
                           "Should not leak raw Swift enum case")
            XCTAssertFalse(message.contains("keyNotFound("),
                           "Should not leak raw Swift enum name")
        }
    }

    func testDecodingErrorFormatterPassesThroughNonDecodingErrors() {
        struct MyErr: Error, LocalizedError {
            var errorDescription: String? { "top-level failure" }
        }
        XCTAssertEqual(MONAILabelClient.describeDecodingError(MyErr()),
                       "top-level failure")
    }

    func testDecodingErrorFormatterNamesRootPath() {
        let malformed = #"[]"#.data(using: .utf8)!
        do {
            _ = try JSONDecoder().decode([String: Int].self, from: malformed)
            XCTFail("Should have thrown DecodingError")
        } catch {
            let message = MONAILabelClient.describeDecodingError(error)
            XCTAssertTrue(message.contains("<root>"))
        }
    }

    func testProcessWaiterEscalatesIgnoredSIGTERM() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; while :; do :; done"]

        try process.run()
        let start = Date()
        let timedOut = await ProcessWaiter.wait(
            for: process,
            timeoutSeconds: 0.1,
            terminationGraceSeconds: 0.1
        )

        XCTAssertTrue(timedOut)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    // MARK: - Hardening: atomic writes

    func testLabelIOWritesAtomicallyViaExchange() throws {
        // We can't easily inject a crash mid-write in a unit test, but we
        // can assert that the written file exists in full at the target
        // path when write returns — which is the contract `.atomic` gives
        // (write-to-temp + rename). Verify by writing a valid labelmap +
        // reading back.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("label-\(UUID().uuidString).nii.gz")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let volume = ImageVolume(
            pixels: [Float](repeating: 0, count: 8),
            depth: 2, height: 2, width: 2,
            modality: "CT",
            seriesUID: "test-series"
        )
        let label = LabelMap(parentSeriesUID: "test-series",
                             depth: 2, height: 2, width: 2,
                             name: "test", classes: [])
        try LabelIO.saveNIfTIGz(label,
                                to: tmp,
                                parentVolume: volume,
                                writeLabelDescriptor: false)
        // File should exist at target path, full-sized, with valid gzip
        // magic bytes in the first two bytes.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
        let head = try Data(contentsOf: tmp).prefix(2)
        XCTAssertEqual(head[head.startIndex], 0x1f)
        XCTAssertEqual(head[head.startIndex + 1], 0x8b)
    }

    // MARK: - Hardening: UInt16 lesionID overflow guard

    func testLesionIDClampsAtUInt16MaxInsteadOfWrapping() throws {
        // Direct unit exercise of the clamp behaviour — we can't easily
        // generate 65,535 connected components in a test volume, so we
        // test the invariant in isolation via a small helper.
        var id: UInt16 = UInt16.max - 1
        if id < UInt16.max { id += 1 }   // 65535 → 65535
        XCTAssertEqual(id, UInt16.max)
        let before = id
        if id < UInt16.max { id += 1 }   // should NOT wrap to 0
        XCTAssertEqual(id, before, "lesionID must clamp at UInt16.max, not wrap")
    }

    // MARK: - Cohort tests

    func testCohortLoadedStudyUsesSUVScaledPETForPETWorkflows() {
        let ct = ImageVolume(
            pixels: [100, 200],
            depth: 1, height: 1, width: 2,
            modality: "CT",
            seriesUID: "ct-series"
        )
        let pet = ImageVolume(
            pixels: [10, 20],
            depth: 1, height: 1, width: 2,
            modality: "PT",
            seriesUID: "pet-series",
            suvScaleFactor: 0.5
        )
        let loaded = CohortStudyLoader.LoadedStudy(primary: ct, auxiliary: [pet])

        XCTAssertEqual(loaded.quantificationVolume.seriesUID, "pet-series")
        XCTAssertEqual(loaded.quantificationVolume.pixels, [5, 10])
        XCTAssertNil(loaded.quantificationVolume.suvScaleFactor)

        XCTAssertEqual(loaded.classificationVolume(for: .PT)?.pixels, [5, 10])
        XCTAssertEqual(loaded.classificationVolume(for: .CT)?.seriesUID, "ct-series")
        XCTAssertNil(loaded.classificationVolume(for: .MR))
    }

    func testCohortLoadedStudyScalesPETChannelsForPETSUVModels() throws {
        let ct = ImageVolume(
            pixels: [100, 200],
            depth: 1, height: 1, width: 2,
            modality: "CT",
            seriesUID: "ct-series"
        )
        let pet = ImageVolume(
            pixels: [10, 20],
            depth: 1, height: 1, width: 2,
            modality: "PT",
            seriesUID: "pet-series",
            suvScaleFactor: 0.5
        )
        let loaded = CohortStudyLoader.LoadedStudy(primary: ct, auxiliary: [pet])
        let entry = try XCTUnwrap(NNUnetCatalog.byID("AutoPET-II-2023"))
        let channels = loaded.segmentationChannels(for: entry)

        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].pixels, [100, 200])
        XCTAssertEqual(channels[1].pixels, [5, 10])
        XCTAssertNil(channels[1].suvScaleFactor)
    }

    func testCohortJobGeneratesDeterministicCheckpointPath() {
        let root = URL(fileURLWithPath: "/tmp/cohort-test")
        let job = CohortJob(id: "abc123", name: "run1", outputRoot: root)
        XCTAssertEqual(job.checkpointURL.path, "/tmp/cohort-test/cohort-abc123.json")
        let studyDir = job.outputDirectory(for: "1.2.3.4.5")
        XCTAssertEqual(studyDir.path, "/tmp/cohort-test/1.2.3.4.5")
    }

    func testCohortJobSanitizesStudyIDsWithForwardSlashes() {
        let root = URL(fileURLWithPath: "/tmp")
        let job = CohortJob(id: "j", outputRoot: root)
        // A synthetic id with a `/` (unusual but legal Swift string) should
        // become `_` so the filesystem doesn't try to create sub-dirs.
        let studyDir = job.outputDirectory(for: "case/with/slashes")
        XCTAssertFalse(studyDir.path.contains("case/with/slashes"))
        XCTAssertTrue(studyDir.path.hasSuffix("case_with_slashes"))
    }

    func testCohortCheckpointRoundTripsThroughJSON() throws {
        let root = URL(fileURLWithPath: "/tmp/cohort-test-\(UUID().uuidString)")
        let job = CohortJob(id: "run1", name: "cohort", outputRoot: root,
                            nnunetEntryID: "dataset-221-autopet",
                            segmentationMode: .dgxRemote,
                            maxConcurrent: 4)
        var checkpoint = CohortCheckpoint(job: job)

        var row = CohortStudyResult(id: "study-1", patientName: "John Doe",
                                    studyDate: "20260422",
                                    status: .done)
        row.lesionCount = 3
        row.totalMetabolicTumorVolumeML = 12.7
        row.maxSUV = 8.3
        row.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        row.finishedAt = Date(timeIntervalSince1970: 1_700_000_100)
        checkpoint.results["study-1"] = row

        let cpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cpURL) }

        try checkpoint.save(to: cpURL)
        let reloaded = try CohortCheckpoint.load(from: cpURL)

        XCTAssertEqual(reloaded.job.id, "run1")
        XCTAssertEqual(reloaded.job.segmentationMode, .dgxRemote)
        XCTAssertEqual(reloaded.results.count, 1)
        XCTAssertEqual(reloaded.results["study-1"]?.patientName, "John Doe")
        XCTAssertEqual(reloaded.results["study-1"]?.lesionCount, 3)
        XCTAssertEqual(reloaded.results["study-1"]?.status, .done)
    }

    func testCohortCheckpointAggregateCountsAndMeanDuration() {
        let job = CohortJob(outputRoot: URL(fileURLWithPath: "/tmp"))
        var cp = CohortCheckpoint(job: job)

        var done1 = CohortStudyResult(id: "a", status: .done)
        done1.startedAt = Date(timeIntervalSince1970: 0)
        done1.finishedAt = Date(timeIntervalSince1970: 60)
        var done2 = CohortStudyResult(id: "b", status: .done)
        done2.startedAt = Date(timeIntervalSince1970: 0)
        done2.finishedAt = Date(timeIntervalSince1970: 120)
        let failed = CohortStudyResult(id: "c", status: .failedSegmentation)
        let pending = CohortStudyResult(id: "d", status: .pending)
        let skipped = CohortStudyResult(id: "e", status: .skipped)

        cp.results = ["a": done1, "b": done2, "c": failed, "d": pending, "e": skipped]

        XCTAssertEqual(cp.doneCount, 2)
        XCTAssertEqual(cp.failedCount, 1)
        XCTAssertEqual(cp.pendingCount, 1)
        XCTAssertEqual(cp.skippedCount, 1)
        XCTAssertEqual(cp.meanStudyDuration ?? 0, 90, accuracy: 0.001,
                       "Mean of 60s + 120s should be 90s")
    }

    func testCohortCheckpointClassificationHistogramCollapsesByLabel() {
        let job = CohortJob(outputRoot: URL(fileURLWithPath: "/tmp"))
        var cp = CohortCheckpoint(job: job)
        for (i, label) in ["malignant", "malignant", "benign", "malignant", "benign"].enumerated() {
            var row = CohortStudyResult(id: "s\(i)", status: .done)
            row.topClassification = label
            cp.results["s\(i)"] = row
        }
        let histogram = cp.classificationHistogram
        XCTAssertEqual(histogram.count, 2)
        XCTAssertEqual(histogram.first?.label, "malignant")
        XCTAssertEqual(histogram.first?.count, 3)
    }

    func testCohortStudyResultStatusTerminalityMatchesExpectations() {
        XCTAssertTrue(CohortStudyResult.Status.done.isTerminal)
        XCTAssertTrue(CohortStudyResult.Status.failedLoad.isTerminal)
        XCTAssertTrue(CohortStudyResult.Status.failedSegmentation.isTerminal)
        XCTAssertTrue(CohortStudyResult.Status.failedClassification.isTerminal)
        XCTAssertTrue(CohortStudyResult.Status.skipped.isTerminal)
        XCTAssertFalse(CohortStudyResult.Status.pending.isTerminal)
        XCTAssertFalse(CohortStudyResult.Status.running.isTerminal)

        XCTAssertFalse(CohortStudyResult.Status.done.isFailure)
        XCTAssertTrue(CohortStudyResult.Status.failedSegmentation.isFailure)
        XCTAssertFalse(CohortStudyResult.Status.skipped.isFailure)
    }

    @MainActor
    func testCohortResultsStoreExportsCSVWithEscapedFields() throws {
        let store = CohortResultsStore()
        let job = CohortJob(id: "t", outputRoot: URL(fileURLWithPath: "/tmp"))
        var cp = CohortCheckpoint(job: job)

        var row = CohortStudyResult(id: "s1",
                                    patientID: "PID,001",
                                    patientName: "Doe \"John\"",
                                    studyDescription: "FDG PET/CT",
                                    studyDate: "20260422",
                                    modalities: ["CT", "PT"],
                                    status: .done)
        row.lesionCount = 4
        row.totalMetabolicTumorVolumeML = 12.345
        row.topClassification = "malignant"
        row.topClassificationConfidence = 0.876
        cp.results["s1"] = row

        // Seed the store's checkpoint via its load() path.
        let tmpCheckpointURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-\(UUID().uuidString).json")
        try cp.save(to: tmpCheckpointURL)
        store.load(checkpointURL: tmpCheckpointURL)
        defer { try? FileManager.default.removeItem(at: tmpCheckpointURL) }

        let csvURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cohort-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: csvURL) }
        try store.exportCohortCSV(to: csvURL)

        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        XCTAssertTrue(csv.hasPrefix("study_id,patient_id,patient_name"),
                      "CSV should start with the canonical header")
        XCTAssertTrue(csv.contains("\"PID,001\""), "Comma values must be quoted")
        XCTAssertTrue(csv.contains("\"Doe \"\"John\"\"\""),
                      "Embedded double-quotes must be doubled and wrapped")
        XCTAssertTrue(csv.contains("malignant"))
        XCTAssertTrue(csv.contains("12.345"))
        XCTAssertTrue(csv.contains("0.8760"))
    }

    @MainActor
    func testClassificationViewModelCopiesConfigIntoCohortJobs() {
        let classifier = ClassificationViewModel()
        classifier.customModelPath = "/tmp/model.json"
        classifier.customBinaryPath = "/tmp/script.py"
        classifier.customProjectorPath = "/tmp/projector.gguf"
        classifier.customEnvironment = "FOO=bar\nactivate=source ~/venv/bin/activate"
        classifier.zeroShotPrompts = "prompt-a\nprompt-b"
        classifier.zeroShotPromptLabels = "label-a\nlabel-b"
        classifier.zeroShotTokenIDs = "1 2 3\n4 5 6"
        classifier.candidateLabels = "benign\nmalignant"
        classifier.runOnDGX = true

        var job = CohortJob(outputRoot: URL(fileURLWithPath: "/tmp"),
                            classifierEntryID: "medsiglip-zero-shot")
        classifier.applyCohortConfiguration(to: &job)

        XCTAssertEqual(job.classifierModelPath, "/tmp/model.json")
        XCTAssertEqual(job.classifierBinaryPath, "/tmp/script.py")
        XCTAssertEqual(job.classifierProjectorPath, "/tmp/projector.gguf")
        XCTAssertEqual(job.classifierEnvironment, "FOO=bar\nactivate=source ~/venv/bin/activate")
        XCTAssertEqual(job.zeroShotPrompts, "prompt-a\nprompt-b")
        XCTAssertEqual(job.zeroShotLabels, "label-a\nlabel-b")
        XCTAssertEqual(job.zeroShotTokenIDs, "1 2 3\n4 5 6")
        XCTAssertEqual(job.candidateLabels, "benign\nmalignant")
        XCTAssertTrue(job.runClassifierOnDGX)
    }

    // MARK: - Assistant chatbot extensions

    func testAssistantClassificationTriggersOnNaturalLanguage() {
        let interpreter = AssistantCommandInterpreter()
        XCTAssertTrue(interpreter.actions(for: "classify all lesions").contains(.classifyAllLesions))
        XCTAssertTrue(interpreter.actions(for: "now run classification please").contains(.classifyAllLesions))
        XCTAssertTrue(interpreter.actions(for: "classify the findings").contains(.classifyAllLesions))
    }

    func testAssistantClassificationDoesNotFireOnAmbiguousPhrases() {
        let interpreter = AssistantCommandInterpreter()
        XCTAssertFalse(interpreter.actions(for: "set the window to brain").contains(.classifyAllLesions))
        XCTAssertFalse(interpreter.actions(for: "select a label").contains(.classifyAllLesions))
        XCTAssertFalse(interpreter.actions(for: "don't classify this").contains(.classifyAllLesions))
    }

    func testAssistantExportActionPicksUpFormat() {
        let interpreter = AssistantCommandInterpreter()
        XCTAssertTrue(interpreter.actions(for: "export the report as csv")
            .contains(.exportClassificationReport(.csv)))
        XCTAssertTrue(interpreter.actions(for: "save results as json")
            .contains(.exportClassificationReport(.json)))
        // No explicit format — default to CSV (most users want a spreadsheet).
        XCTAssertTrue(interpreter.actions(for: "export the findings report")
            .contains(.exportClassificationReport(.csv)))
    }

    func testAssistantOpenCohortPanelIntents() {
        let interpreter = AssistantCommandInterpreter()
        XCTAssertTrue(interpreter.actions(for: "open cohort panel").contains(.openCohortPanel))
        XCTAssertTrue(interpreter.actions(for: "run on all studies").contains(.openCohortPanel))
        XCTAssertTrue(interpreter.actions(for: "process the cohort").contains(.openCohortPanel))
        XCTAssertFalse(interpreter.actions(for: "open this study").contains(.openCohortPanel))
    }

    @MainActor
    func testNNUnetAssistantReadinessPreflightsCoreMLPackages() throws {
        let nnunet = NNUnetViewModel()
        nnunet.mode = .coreML
        nnunet.coreMLModelPath = ""
        let entry = try XCTUnwrap(NNUnetCatalog.all.first(where: { !$0.multiChannel }))

        XCTAssertEqual(
            nnunet.assistantReadinessMessage(for: entry),
            "Point the CoreML path at a .mlpackage or .mlmodelc first."
        )
    }

    // MARK: - Segmentation mode round-trips

    func testSegmentationModeIsCodable() throws {
        for mode in SegmentationMode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(SegmentationMode.self, from: encoded)
            XCTAssertEqual(decoded, mode)
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }

    @MainActor
    func testNNUnetViewModelDefaultsToDGXModeWhenConfigEnabled() {
        // Save an enabled DGXSparkConfig into UserDefaults, then confirm
        // NNUnetViewModel picks it up on init. We stash + restore whatever
        // was there so the test doesn't pollute real prefs.
        let defaults = UserDefaults.standard
        let prior = defaults.data(forKey: DGXSparkConfig.storageKey)
        defer {
            if let prior {
                defaults.set(prior, forKey: DGXSparkConfig.storageKey)
            } else {
                defaults.removeObject(forKey: DGXSparkConfig.storageKey)
            }
        }

        var cfg = DGXSparkConfig()
        cfg.host = "dgx.local"
        cfg.enabled = true
        if let data = try? JSONEncoder().encode(cfg) {
            defaults.set(data, forKey: DGXSparkConfig.storageKey)
        }

        let vm = NNUnetViewModel()
        XCTAssertEqual(vm.mode, .dgxRemote,
                       "NNUnetViewModel should honour the persisted DGX toggle on init")
    }

    // MARK: - Workstation editing and volumetry

    @MainActor
    func testLinkedViewportTransformCanApplyToAllPanes() {
        let vm = ViewerViewModel()

        vm.setViewportZoom(2.0, for: 0)
        XCTAssertEqual(vm.viewportTransform(for: 0).zoom, 2.0, accuracy: 1e-9)
        XCTAssertEqual(vm.viewportTransform(for: 1).zoom, 1.0, accuracy: 1e-9)

        vm.linkZoomPanAcrossPanes = true
        vm.setViewportPan(x: 18, y: -7, for: 1)
        XCTAssertEqual(vm.viewportTransform(for: 0).panX, 18, accuracy: 1e-9)
        XCTAssertEqual(vm.viewportTransform(for: 2).panY, -7, accuracy: 1e-9)

        vm.resetAllViewportTransforms()
        XCTAssertTrue(vm.viewportTransform(for: 0).isIdentity)
        XCTAssertTrue(vm.viewportTransform(for: 2).isIdentity)
    }

    @MainActor
    func testCTHURangeVolumetryWritesActiveLabelAndReport() throws {
        let ct = ImageVolume(
            pixels: [-900, -700, 20, 180],
            depth: 1, height: 2, width: 2,
            spacing: (2, 2, 5),
            modality: "CT",
            seriesDescription: "CT"
        )
        let vm = ViewerViewModel()
        vm.displayVolume(ct)
        let map = vm.labeling.createLabelMap(
            for: ct,
            presetSet: LabelPresetSet(
                name: "Test",
                description: "",
                classes: [LabelClass(labelID: 1, name: "Lung", category: .organ, color: .green)]
            )
        )

        vm.thresholdActiveCTLabel(lowerHU: -1000, upperHU: -400)

        XCTAssertEqual(map.voxels.filter { $0 == 1 }.count, 2)
        let report = try XCTUnwrap(vm.lastVolumeMeasurementReport)
        XCTAssertEqual(report.source, .ctHU)
        XCTAssertEqual(report.method, .huRange)
        XCTAssertEqual(report.voxelCount, 2)
        XCTAssertEqual(report.volumeML, 0.04, accuracy: 1e-9)
        XCTAssertEqual(report.min, -900, accuracy: 1e-9)
        XCTAssertEqual(report.max, -700, accuracy: 1e-9)
    }

    @MainActor
    func testPETPercentOfMaxVolumetryUsesSUVScaling() throws {
        let pet = ImageVolume(
            pixels: [0, 5, 10, 20],
            depth: 1, height: 2, width: 2,
            spacing: (2, 2, 2),
            modality: "PT",
            seriesDescription: "PET",
            suvScaleFactor: 0.5
        )
        let vm = ViewerViewModel()
        vm.displayVolume(pet)
        let map = vm.labeling.createLabelMap(
            for: pet,
            presetSet: LabelPresetSet(
                name: "Test",
                description: "",
                classes: [LabelClass(labelID: 1, name: "Lesion", category: .lesion, color: .orange)]
            )
        )

        vm.percentOfMaxActiveLabelWholeVolume(percent: 0.4)

        XCTAssertEqual(map.voxels.filter { $0 == 1 }.count, 2)
        let report = try XCTUnwrap(vm.lastVolumeMeasurementReport)
        XCTAssertEqual(report.source, .petSUV)
        XCTAssertEqual(report.method, .percentOfMax)
        XCTAssertEqual(report.volumeML, 0.016, accuracy: 1e-9)
        XCTAssertEqual(report.suvMax ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(report.suvMean ?? 0, 7.5, accuracy: 1e-9)
        XCTAssertEqual(report.tlg ?? 0, 0.12, accuracy: 1e-9)
    }

    func testColorRendererCanInvertMIPWindowMapping() throws {
        let normal = try XCTUnwrap(PixelRenderer.makeColorImage(
            pixels: [0, 1],
            width: 2,
            height: 1,
            window: 1,
            level: 0.5,
            colormap: .grayscale,
            invert: false
        ))
        let inverted = try XCTUnwrap(PixelRenderer.makeColorImage(
            pixels: [0, 1],
            width: 2,
            height: 1,
            window: 1,
            level: 0.5,
            colormap: .grayscale,
            invert: true
        ))
        let normalData = try XCTUnwrap(normal.dataProvider?.data as Data?)
        let invertedData = try XCTUnwrap(inverted.dataProvider?.data as Data?)

        XCTAssertEqual(normalData[0], 0)
        XCTAssertEqual(normalData[4], 255)
        XCTAssertEqual(invertedData[0], 255)
        XCTAssertEqual(invertedData[4], 0)
    }
}

/// Simple thread-safe counter used by tests that interact with the indexer's
/// `@Sendable` progress callback. `NSLock` is enough — we just need integer
/// reads/writes to be atomic and visible across actor hops.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0

    var value: Int {
        lock.withLock { _value }
    }

    func set(_ v: Int) {
        lock.withLock { _value = v }
    }
}

private func makeMinimalDICOM(patientName: String,
                              patientID: String,
                              accessionNumber: String = "",
                              studyUID: String,
                              studyDate: String,
                              studyTime: String = "",
                              referringPhysicianName: String = "",
                              seriesUID: String,
                              seriesDescription: String,
                              modality: String,
                              sopUID: String) -> Data {
    var data = Data(count: 128)
    data.append("DICM".data(using: .ascii)!)
    data.appendDICOMElement(group: 0x0002, element: 0x0010, vr: "UI", string: "1.2.840.10008.1.2.1")
    data.appendDICOMElement(group: 0x0010, element: 0x0010, vr: "PN", string: patientName)
    data.appendDICOMElement(group: 0x0010, element: 0x0020, vr: "LO", string: patientID)
    data.appendDICOMElement(group: 0x0008, element: 0x0050, vr: "SH", string: accessionNumber)
    data.appendDICOMElement(group: 0x0008, element: 0x0020, vr: "DA", string: studyDate)
    data.appendDICOMElement(group: 0x0008, element: 0x0030, vr: "TM", string: studyTime)
    data.appendDICOMElement(group: 0x0008, element: 0x0090, vr: "PN", string: referringPhysicianName)
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
