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

    func testNNUnetRunnerReportsAvailabilityFromPATH() {
        // We don't assume nnUNetv2_predict is installed in CI — just prove
        // the detector runs without crashing and returns a reasonable value.
        let located = NNUnetRunner.locatePredictBinary(override: "/bin/does-not-exist")
        XCTAssertNil(located,
                     "Explicit bad path override must not be resolved as valid")
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
