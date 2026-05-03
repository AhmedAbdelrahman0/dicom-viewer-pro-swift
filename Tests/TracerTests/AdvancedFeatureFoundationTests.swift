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

    func testImageOpsBridgeBuildsWorkerArguments() {
        let config = ImageOpsBridgeConfiguration(pythonExecutablePath: "/usr/bin/env")
        let request = ImageOpsBridgeRequest(
            operation: .resampleToReference,
            inputURL: URL(fileURLWithPath: "/tmp/in.nii"),
            outputURL: URL(fileURLWithPath: "/tmp/out.nii"),
            referenceURL: URL(fileURLWithPath: "/tmp/ref.nii"),
            spacing: (1.0, 1.0, 2.0),
            iterations: 12,
            interpolator: .nearest
        )

        let args = config.workerArguments(scriptPath: "/repo/workers/imageops/bridge.py",
                                          request: request,
                                          outputJSONPath: "/tmp/result.json")

        XCTAssertEqual(args.prefix(2), ["python3", "/repo/workers/imageops/bridge.py"])
        XCTAssertTrue(args.contains("resample-to-reference"))
        XCTAssertTrue(args.contains("/tmp/ref.nii"))
        XCTAssertTrue(args.contains("1.0,1.0,2.0"))
        XCTAssertTrue(args.contains("nearest"))
        XCTAssertTrue(args.contains("/tmp/result.json"))
    }

    func testRenamedInteropSurfacesStayNeutralAndUsable() {
        XCTAssertEqual(PETMRDeformableBackend.pythonMI.displayName, "Python MI refinement")
        XCTAssertEqual(PETMRDeformableBackend.pythonMI.defaultExecutableName, "python3")
        XCTAssertEqual(PETMRDeformableBackend.brainsFit.displayName, "BRAINSFit")
        XCTAssertEqual(PETMRDeformableBackend.brainsFit.defaultExecutableName, "BRAINSFit")
        XCTAssertEqual(PETMRDeformableBackend.greedy.displayName, "Greedy")
        XCTAssertEqual(PETMRDeformableBackend.greedy.defaultExecutableName, "greedy")

        let pythonConfig = PETMRDeformableRegistrationConfiguration(backend: .pythonMI)
        XCTAssertTrue(pythonConfig.readinessMessage.contains("Python MI refinement will run via python3"))

        XCTAssertEqual(LabelIO.Format.segmentationNRRD.rawValue, "Segmentation NRRD (.seg.nrrd)")
        XCTAssertEqual(LabelIO.Format.segmentationNRRD.canonicalExtension, "seg.nrrd")
        XCTAssertEqual(LabelIO.Format.labelDescriptor.rawValue, "NIfTI + Label Descriptor")
        XCTAssertEqual(LabelIO.Format.labelDescriptor.support, .sidecar)

        let candidates = ImageOpsBridgeConfiguration.defaultScriptCandidates()
        XCTAssertTrue(candidates.contains { $0.contains("workers/imageops/bridge.py") })
    }

    @MainActor
    func testRenamedRemoteSurfacesRemainConnectedAndPublicCopyStaysNeutral() {
        XCTAssertEqual(NNUnetViewModel.Mode.dgxRemote.displayName, "Remote Workstation")
        XCTAssertEqual(SegmentationMode.dgxRemote.displayName, "Remote Workstation")
        XCTAssertEqual(PETACCatalog.Backend.dgxRemote.displayName, "Remote Workstation")
        XCTAssertEqual(LesionDetectorCatalog.Backend.dgxRemote.displayName, "Remote Workstation")

        let disabled = DGXSparkConfig(enabled: false).readinessMessage ?? ""
        let missingHost = DGXSparkConfig(host: "", enabled: true).readinessMessage ?? ""
        assertPublicCopyIsNeutral(disabled)
        assertPublicCopyIsNeutral(missingHost)
        XCTAssertTrue(disabled.contains("Remote Workstation") || disabled.contains("Remote workstation"))
        XCTAssertTrue(missingHost.contains("remote workstation"))

        let remoteErrors = [
            RemoteExecutor.Error.notConfigured.errorDescription ?? "",
            RemoteNNUnetRunner.Error.notConfigured.errorDescription ?? "",
            RemoteLesionTracerRunner.Error.notConfigured.errorDescription ?? "",
            RemoteGAAINReferenceBuilder.Error.notConfigured.errorDescription ?? "",
            DetectionError.modelUnavailable("Remote workstation not configured. Settings -> Remote Workstation.").errorDescription ?? "",
            PETACError.modelUnavailable("Remote workstation not configured. Settings -> Remote Workstation.").errorDescription ?? ""
        ]
        for text in remoteErrors {
            assertPublicCopyIsNeutral(text)
            XCTAssertTrue(text.contains("Remote") || text.contains("remote"))
        }

        XCTAssertNotNil(NNUnetCatalog.byID("LesionTracer-AutoPETIII"))
        assertPublicCopyIsNeutral(PETEngineViewModel.Engine.lesionTracer.displayName)
        assertPublicCopyIsNeutral(NNUnetCatalog.lesionTracer.displayName)
        XCTAssertTrue(NNUnetCatalog.lesionTracer.displayName.contains("AutoPET III-compatible"))
    }

    func testRemoteWorkstationConfigSaveLoadAndNotificationStayConnected() {
        let defaults = UserDefaults.standard
        let original = defaults.data(forKey: DGXSparkConfig.storageKey)
        defer {
            if let original {
                defaults.set(original, forKey: DGXSparkConfig.storageKey)
            } else {
                defaults.removeObject(forKey: DGXSparkConfig.storageKey)
            }
        }

        let config = DGXSparkConfig(
            host: "remote.local",
            user: "tester",
            port: 2222,
            identityFile: "~/.ssh/id_test",
            remoteWorkdir: "~/tracer-test",
            remoteNNUnetBinary: "/opt/nnUNetv2_predict",
            remoteLlamaBinary: "/opt/llama-cli",
            remoteSegmentatorSourcePath: "~/pet-lesion-src",
            remoteSegmentatorModelFolder: "~/pet-lesion-model",
            remoteSegmentatorWorkerImage: "tracer/pet-lesion:latest",
            remoteSegmentatorBaseImage: "nvcr.io/nvidia/pytorch:25.03-py3",
            remoteEnvironment: "\n nnUNet_results=/weights with spaces\nCUDA_VISIBLE_DEVICES=0\nmissing_equals\n",
            enabled: true
        )

        let didNotify = expectation(description: "remote workstation config change notification")
        let token = NotificationCenter.default.addObserver(
            forName: .dgxSparkConfigDidChange,
            object: nil,
            queue: nil
        ) { note in
            guard let posted = note.object as? DGXSparkConfig,
                  posted.host == config.host,
                  posted.remoteWorkdir == config.remoteWorkdir else { return }
            didNotify.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        config.save()
        wait(for: [didNotify], timeout: 1)

        let loaded = DGXSparkConfig.load()
        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded.sshDestination, "tester@remote.local")
        XCTAssertTrue(loaded.isConfigured)
        XCTAssertNil(loaded.readinessMessage)
        XCTAssertEqual(
            loaded.environmentExports(),
            ["nnUNet_results=/weights with spaces", "CUDA_VISIBLE_DEVICES=0"]
        )
        XCTAssertEqual(
            loaded.environmentExports().compactMap(RemoteExecutor.shellExportCommand),
            [
                "export nnUNet_results='/weights with spaces';",
                "export CUDA_VISIBLE_DEVICES='0';"
            ]
        )
    }

    func testRemoteExecutorAndRunnerErrorsRemainNeutralAndBounded() {
        let droppedPrefix = "old-stderr-prefix"
        let longStderr = droppedPrefix + String(repeating: "x", count: 700) + "tail"
        let executorDescriptions: [String] = [
            RemoteExecutor.Error.notConfigured.errorDescription ?? "",
            RemoteExecutor.Error.commandFailed(exitCode: 17, stderr: longStderr).errorDescription ?? "",
            RemoteExecutor.Error.uploadFailed("permission denied").errorDescription ?? "",
            RemoteExecutor.Error.downloadFailed("missing archive").errorDescription ?? "",
            RemoteExecutor.Error.binaryMissing("/usr/bin/scp").errorDescription ?? "",
            RemoteExecutor.Error.timedOut(binary: "ssh", seconds: 12, stderr: "network stalled").errorDescription ?? ""
        ]
        let lesionDescriptions: [String] = [
            RemoteLesionTracerRunner.Error.notConfigured.errorDescription ?? "",
            RemoteLesionTracerRunner.Error.cancelled.errorDescription ?? "",
            RemoteLesionTracerRunner.Error.geometryMismatch("spacing mismatch").errorDescription ?? "",
            RemoteLesionTracerRunner.Error.missingRemoteOutput("/remote/out.nii.gz").errorDescription ?? "",
            RemoteLesionTracerRunner.Error.remoteFailed("exit 1").errorDescription ?? ""
        ]
        let gaainDescriptions: [String] = [
            RemoteGAAINReferenceBuilder.Error.notConfigured.errorDescription ?? "",
            RemoteGAAINReferenceBuilder.Error.missingLocalFile("/tmp/missing.zip").errorDescription ?? "",
            RemoteGAAINReferenceBuilder.Error.remoteFailed("exit 1").errorDescription ?? "",
            RemoteGAAINReferenceBuilder.Error.missingResultsArchive("/tmp/results.tgz").errorDescription ?? "",
            RemoteGAAINReferenceBuilder.Error.extractionFailed("tar failed").errorDescription ?? ""
        ]

        for text in executorDescriptions + lesionDescriptions + gaainDescriptions {
            XCTAssertFalse(text.isEmpty)
            assertPublicCopyIsNeutral(text)
        }

        let clipped = RemoteExecutor.Error.commandFailed(exitCode: 17, stderr: longStderr).errorDescription ?? ""
        XCTAssertTrue(clipped.hasSuffix(String(longStderr.suffix(600))))
        XCTAssertFalse(clipped.contains(droppedPrefix))
    }

    @MainActor
    func testCatalogDisplayNamesStayNeutralAndCompatibilityIDsRemainStable() {
        XCTAssertEqual(PETACCatalog.deepACDGX.id, "deep-ac-dgx")
        XCTAssertEqual(PETACCatalog.deepACDGX.backend, .dgxRemote)
        XCTAssertEqual(PETACCatalog.deepACDGX.backend.displayName, "Remote Workstation")
        XCTAssertEqual(LesionDetectorCatalog.ctFMLesionDetector.id, "ct-fm-detection-dgx")
        XCTAssertEqual(LesionDetectorCatalog.ctFMLesionDetector.backend, .dgxRemote)
        XCTAssertEqual(NNUnetCatalog.lesionTracer.id, "LesionTracer-AutoPETIII")
        XCTAssertEqual(PETEngineViewModel.Engine.lesionTracer.description.contains("user-provided"), true)

        let publicCatalogCopy = [
            PETACCatalog.deepACDGX.displayName,
            PETACCatalog.deepACDGX.description,
            PETACCatalog.deepACDGX.provenance,
            PETACCatalog.deepACDGX.license,
            LesionDetectorCatalog.ctFMLesionDetector.displayName,
            LesionDetectorCatalog.ctFMLesionDetector.description,
            LesionDetectorCatalog.ctFMLesionDetector.provenance,
            LesionDetectorCatalog.ctFMLesionDetector.license,
            NNUnetCatalog.lesionTracer.displayName,
            NNUnetCatalog.lesionTracer.description,
            NNUnetCatalog.lesionTracer.notes,
            PETEngineViewModel.Engine.lesionTracer.displayName,
            PETEngineViewModel.Engine.lesionTracer.description
        ]

        for text in publicCatalogCopy {
            assertPublicCopyIsNeutral(text)
        }
    }

    func testModelFamilyCopyUsesCompatibilityLanguage() {
        let modelCopy = [
            LesionClassifierCatalog.medSigLIPZeroShot.description,
            LesionClassifierCatalog.medSigLIPZeroShot.provenance,
            LesionClassifierCatalog.medSigLIPZeroShot.license,
            LesionClassifierCatalog.medGemma4B.description,
            LesionClassifierCatalog.medGemma4B.provenance,
            LesionClassifierCatalog.medGemma4B.license,
            LesionDetectorCatalog.medSigLIPHeatmap.provenance,
            LesionDetectorCatalog.medSigLIPHeatmap.license,
            LesionDetectorCatalog.medGemmaDescriber.provenance,
            LesionDetectorCatalog.medGemmaDescriber.license
        ]

        XCTAssertTrue(LesionClassifierCatalog.medSigLIPZeroShot.provenance.contains("compatible"))
        XCTAssertTrue(LesionClassifierCatalog.medGemma4B.provenance.contains("compatible"))
        for text in modelCopy {
            assertPublicCopyIsNeutral(text)
        }
    }

    func testLegalRiskTermsStayOutOfPublicDocs() throws {
        let packageRoot = packageRootURL()
        let publicDocs = [
            "README.md",
            "docs/BrainPETWorkflow.md",
            "workers/README.md"
        ]

        for relativePath in publicDocs {
            let url = packageRoot.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            assertPublicCopyIsNeutral(text, context: relativePath)
        }

        let readme = try String(contentsOf: packageRoot.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("DICOM® is the registered trademark"))
        let brainPETDoc = try String(contentsOf: packageRoot.appendingPathComponent("docs/BrainPETWorkflow.md"), encoding: .utf8)
        XCTAssertTrue(brainPETDoc.contains("Tracer does not bundle GAAIN data"))
        XCTAssertTrue(brainPETDoc.contains("GAAIN Data Import"))
    }

    func testOpenPACSInspiredFeaturesDoNotUseSourceProjectNamesInProductionText() throws {
        let packageRoot = packageRootURL()
        let forbiddenProjectNames = [
            "Dico" + "ogle",
            "Dico" + "olge"
        ]
        let scannedRoots = [
            "Sources",
            "README.md",
            "docs",
            "workers"
        ]
        let skippedExtensions: Set<String> = [
            "dcm", "gz", "ico", "jpg", "jpeg", "nii", "png", "tiff", "zip", "7z"
        ]

        for root in scannedRoots {
            let url = packageRoot.appendingPathComponent(root)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                XCTFail("Missing production scan root: \(root)")
                continue
            }

            let files: [URL]
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                files = enumerator?.compactMap { item in
                    guard let fileURL = item as? URL,
                          let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                          values.isRegularFile == true,
                          !skippedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                        return nil
                    }
                    return fileURL
                } ?? []
            } else {
                files = [url]
            }

            for fileURL in files {
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let relative = fileURL.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
                for projectName in forbiddenProjectNames {
                    XCTAssertFalse(text.contains(projectName), "Unexpected source project name in \(relative)")
                }
            }
        }
    }

    func testLegalRiskTermsStayOutOfPublicSourceSurfaces() throws {
        let packageRoot = packageRootURL()
        let publicSourceFiles = [
            "Sources/Tracer/Views/TracerSettingsView.swift",
            "Sources/Tracer/Views/BrainPETPanel.swift",
            "Sources/Tracer/Views/ClassificationPanel.swift",
            "Sources/Tracer/Views/LesionDetectorPanel.swift",
            "Sources/Tracer/Views/ModelManagerPanel.swift",
            "Sources/Tracer/Views/NNUnetPanel.swift",
            "Sources/Tracer/Views/PETACPanel.swift",
            "Sources/Tracer/Views/PETEnginePanel.swift",
            "Sources/Tracer/Views/TracerAboutView.swift",
            "Sources/Tracer/Dictation/DictationEngine.swift",
            "Sources/Tracer/Remote/DGXSparkConfig.swift",
            "Sources/Tracer/Remote/RemoteGAAINReferenceBuilder.swift",
            "Sources/Tracer/Processing/GAAINReferencePipeline.swift"
        ]

        for relativePath in publicSourceFiles {
            let text = try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
            assertPublicCopyIsNeutral(text, context: relativePath)
        }
    }

    func testWorkerCopyUsesCompatibilityLanguageAndNeutralAttribution() throws {
        let packageRoot = packageRootURL()
        let readme = try String(contentsOf: packageRoot.appendingPathComponent("workers/README.md"), encoding: .utf8)
        let worker = try String(contentsOf: packageRoot.appendingPathComponent("workers/medasr/transcribe_medasr.py"), encoding: .utf8)

        XCTAssertTrue(readme.contains("MedASR-compatible medical dictation worker"))
        XCTAssertTrue(readme.contains("Model identifiers are compatibility references"))
        XCTAssertTrue(worker.contains("MedASR-compatible dictation worker"))
        XCTAssertTrue(worker.contains("MedASR-compatible model"))
        assertPublicCopyIsNeutral(readme, context: "workers/README.md")
        assertPublicCopyIsNeutral(worker, context: "workers/medasr/transcribe_medasr.py")
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

    private func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func assertPublicCopyIsNeutral(_ text: String,
                                           context: String = "",
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        let forbiddenTerms = [
            "Dico" + "ogle",
            "Dico" + "olge",
            "M" + "IM",
            "Visage",
            "Sectra",
            "3D " + "Slicer",
            "ITK" + "-SNAP",
            "ITK" + "snap",
            "simple" + "ITK",
            "Simple" + "ITK",
            "Google " + "MedASR",
            "Google " + "MedGemma",
            "Google " + "MedSigLIP",
            "Google " + "HAI",
            "DGX " + "Spark",
            "PET " + "Segmentator",
            "GAAIN reference " + "builder",
            "Scan " + "GAAIN",
            "Run on " + "Spark",
            "Export " + "Spark Job",
            "Use Detected " + "NVIDIA",
            "NVIDIA " + "Spark",
            "Spark " + "Dataset",
            "Spark " + "archive",
            "Train on " + "DGX",
            "Validate on " + "DGX",
            "Remote path on " + "DGX"
        ]
        for term in forbiddenTerms {
            let contextSuffix = context.isEmpty ? "" : " in \(context)"
            XCTAssertFalse(text.contains(term), "Unexpected public/legal-risk term '\(term)'\(contextSuffix): \(text)", file: file, line: line)
        }
    }
}
