import XCTest
import SwiftUI
@testable import Tracer

final class LocalBrainPETDatasetSmokeTests: XCTestCase {
    private func smokeDirectory() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["TRACER_BRAIN_PET_SMOKE_DIR"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set TRACER_BRAIN_PET_SMOKE_DIR to run the local brain PET smoke test.")
        }
        let url = URL(fileURLWithPath: raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            XCTFail("TRACER_BRAIN_PET_SMOKE_DIR does not exist: \(url.path)")
            throw XCTSkip("Missing local brain PET smoke directory.")
        }
        return url
    }

    @MainActor
    func testViewerWorkflowLoadsBrainFDGPETMRIAndRunsAnalysis() async throws {
        let root = try smokeDirectory()
        let subjectID = ProcessInfo.processInfo.environment["TRACER_BRAIN_PET_SUBJECT"] ?? "sub-control05"
        let petURL = root
            .appendingPathComponent(subjectID, isDirectory: true)
            .appendingPathComponent("pet", isDirectory: true)
            .appendingPathComponent("\(subjectID)_pet.nii.gz")
        let mriURL = root
            .appendingPathComponent(subjectID, isDirectory: true)
            .appendingPathComponent("anat", isDirectory: true)
            .appendingPathComponent("\(subjectID)_T1w.nii.gz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: petURL.path), "Missing brain PET file: \(petURL.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mriURL.path), "Missing brain MRI file: \(mriURL.path)")

        let sessionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tracer-BrainPET-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionRoot) }

        let vm = ViewerViewModel(studySessionStore: StudySessionStore(rootURL: sessionRoot))
        vm.suvSettings.mode = .bodyWeight

        await vm.loadNIfTI(url: petURL, autoFuse: false)
        await vm.loadNIfTI(url: mriURL, autoFuse: false)

        let pet = try XCTUnwrap(vm.loadedPETVolumes.first, "Brain PET should load as PT.")
        let mri = try XCTUnwrap(vm.loadedMRVolumes.first, "T1w anatomy should load as MR.")
        XCTAssertEqual(Modality.normalize(pet.modality), .PT)
        XCTAssertEqual(Modality.normalize(mri.modality), .MR)
        XCTAssertEqual(pet.pixels.count, pet.width * pet.height * pet.depth)
        XCTAssertGreaterThan(pet.intensityRange.max, pet.intensityRange.min)

        let atlas = try makeCoarseBrainSmokeAtlas(for: pet)
        vm.labeling.labelMaps.append(atlas)
        vm.labeling.activeLabelMap = atlas

        let normals = BrainPETNormalDatabase(
            id: "local-brain-smoke-fdg",
            name: "Local brain smoke FDG normals",
            tracer: .fdg,
            referenceRegion: "Cerebellar gray",
            sourceDescription: "Synthetic normal rows for real-case pipeline smoke testing",
            entries: [
                .init(regionName: "Left temporal cortex gray", labelID: 1, meanSUVR: 1.0, sdSUVR: 0.25, sampleSize: 1),
                .init(regionName: "Right temporal cortex gray", labelID: 2, meanSUVR: 1.0, sdSUVR: 0.25, sampleSize: 1),
                .init(regionName: "White matter", labelID: 20, meanSUVR: 0.8, sdSUVR: 0.20, sampleSize: 1)
            ]
        )

        let report = try XCTUnwrap(vm.runActiveBrainPETAnalysis(
            tracer: .fdg,
            normalDatabase: normals,
            anatomyMode: .mriAssisted
        ))
        let anatomyReport = try XCTUnwrap(vm.brainPETAnatomyAwareReport)

        XCTAssertEqual(report.tracer, .fdg)
        XCTAssertEqual(anatomyReport.resolvedMode, .mriAssisted)
        XCTAssertEqual(anatomyReport.anatomySeriesDescription, mri.seriesDescription)
        XCTAssertGreaterThan(report.referenceMean, 0)
        XCTAssertNotNil(report.targetSUVR)
        XCTAssertFalse(report.regions.isEmpty)
        XCTAssertTrue(report.regions.contains { $0.name == "Left temporal cortex gray" && $0.zScore != nil })
        XCTAssertTrue(report.regions.contains { $0.name == "Right temporal cortex gray" && $0.zScore != nil })
        XCTAssertTrue(anatomyReport.qcMetrics.contains { $0.id == "anatomy" && $0.passed })
        XCTAssertTrue(anatomyReport.qcMetrics.contains { $0.id == "cortex" && $0.passed })
    }

    @MainActor
    func testWorklistOpenLoadsWholeBrainPETMRIStudy() async throws {
        let root = try smokeDirectory()
        let subjectID = ProcessInfo.processInfo.environment["TRACER_BRAIN_PET_SUBJECT"] ?? "sub-control05"
        let result = PACSDirectoryIndexer.scan(
            url: root,
            progressStride: 1_000,
            seriesDirectoryFastPath: true
        )
        let study = try XCTUnwrap(PACSWorklistStudy.grouped(from: result.records).first {
            $0.patientID == subjectID
        })
        XCTAssertTrue(study.series.contains { Modality.normalize($0.modality) == .PT })
        XCTAssertTrue(study.series.contains { Modality.normalize($0.modality) == .MR })

        let sessionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tracer-BrainPET-Worklist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionRoot) }

        let vm = ViewerViewModel(studySessionStore: StudySessionStore(rootURL: sessionRoot))
        await vm.openWorklistStudy(study)

        XCTAssertGreaterThanOrEqual(vm.loadedMRVolumes.count, 2)
        XCTAssertEqual(vm.loadedPETVolumes.count, 1)
        XCTAssertNotNil(vm.currentVolume)
        XCTAssertTrue(vm.statusMessage.contains("Opened") || vm.statusMessage.contains("Loaded"))
        XCTAssertTrue(vm.window.isFinite)
        XCTAssertTrue(vm.level.isFinite)
    }

    func testSimpleITKPETMRPrecisionPathRunsOnLocalBrainCase() async throws {
        guard simpleITKAvailable() else {
            throw XCTSkip("Python SimpleITK is not installed.")
        }
        let root = try smokeDirectory()
        let subjectID = ProcessInfo.processInfo.environment["TRACER_BRAIN_PET_SUBJECT"] ?? "sub-control01"
        let petURL = root
            .appendingPathComponent(subjectID, isDirectory: true)
            .appendingPathComponent("pet", isDirectory: true)
            .appendingPathComponent("\(subjectID)_pet.nii.gz")
        let mriURL = root
            .appendingPathComponent(subjectID, isDirectory: true)
            .appendingPathComponent("anat", isDirectory: true)
            .appendingPathComponent("\(subjectID)_T1w.nii.gz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: petURL.path), "Missing brain PET file: \(petURL.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mriURL.path), "Missing brain MRI file: \(mriURL.path)")

        let pet = try NIfTILoader.load(petURL, modalityHint: "PT")
        let mri = try NIfTILoader.load(mriURL, modalityHint: "MR")
        let registration = PETMRRegistrationEngine.estimatePETToMR(
            pet: pet,
            mr: mri,
            mode: .rigidAnatomical
        )
        let prealigned = VolumeResampler.resample(
            source: pet,
            target: mri,
            transform: registration.fixedToMoving,
            mode: .linear
        )
        let config = PETMRDeformableRegistrationConfiguration(
            backend: .simpleITKMI,
            executablePath: "python3",
            extraArguments: "--sampling 0.03 --iterations 20 --bins 32",
            timeoutSeconds: 120,
            metricPreset: .multimodalMI
        )

        let result = try await PETMRDeformableRegistrationRunner.register(
            fixed: mri,
            movingPrealigned: prealigned,
            configuration: config
        )

        XCTAssertTrue(ImageVolumeGeometry.gridsMatch(mri, result.warpedMoving))
        XCTAssertTrue(result.note.contains("SimpleITK MI"))
        let iterationCount = optimizerIterations(from: result.deformationQuality?.notes ?? [])
        XCTAssertGreaterThan(iterationCount, 0, "SimpleITK should report non-zero optimizer iterations: \(result.deformationQuality?.notes ?? [])")
        XCTAssertFalse(result.stderr.localizedCaseInsensitiveContains("registration failed"), result.stderr)
        XCTAssertFalse(result.warpedMoving.pixels.allSatisfy { !$0.isFinite || abs($0) < 1e-8 })
        XCTAssertGreaterThan(meanAbsoluteDifference(prealigned, result.warpedMoving), 1e-6, "SimpleITK should change the prealigned PET voxels.")
    }

    @MainActor
    func testAutomaticPETMRRejectsIterativeSimpleITKWhenItDoesNotImproveLocalBrainCase() async throws {
        guard simpleITKAvailable() else {
            throw XCTSkip("Python SimpleITK is not installed.")
        }
        let root = try smokeDirectory()
        let subjectID = ProcessInfo.processInfo.environment["TRACER_BRAIN_PET_SUBJECT"] ?? "sub-control01"
        let petURL = root
            .appendingPathComponent(subjectID, isDirectory: true)
            .appendingPathComponent("pet", isDirectory: true)
            .appendingPathComponent("\(subjectID)_pet.nii.gz")
        let mriURL = root
            .appendingPathComponent(subjectID, isDirectory: true)
            .appendingPathComponent("anat", isDirectory: true)
            .appendingPathComponent("\(subjectID)_T1w.nii.gz")

        let pet = try NIfTILoader.load(petURL, modalityHint: "PT")
        let mri = try NIfTILoader.load(mriURL, modalityHint: "MR")
        let vm = ViewerViewModel()
        vm.loadedVolumes = [mri, pet]
        vm.displayVolume(mri)
        vm.petMRRegistrationMode = .automaticBestFit
        vm.petMRDeformableRegistration = PETMRDeformableRegistrationConfiguration(
            backend: .simpleITKMI,
            executablePath: "python3",
            extraArguments: "--sampling 0.03 --iterations 20 --bins 32",
            timeoutSeconds: 120,
            metricPreset: .multimodalMI
        )

        await vm.fusePETMR(base: mri, overlay: pet)

        let pair = try XCTUnwrap(vm.fusion)
        XCTAssertTrue(pair.registrationNote.localizedCaseInsensitiveContains("Scanner/world geometry retained"),
                      "Auto should keep the safer candidate when iterative refinement does not improve QA, note: \(pair.registrationNote)")
        XCTAssertFalse(pair.registrationDiagnostics.isEmpty, "Auto PET/MR should expose candidate diagnostics.")
        XCTAssertTrue(pair.registrationDiagnostics.contains { $0.localizedCaseInsensitiveContains("SELECTED: Scanner geometry") },
                      "Diagnostics should identify the selected candidate: \(pair.registrationDiagnostics)")
        XCTAssertTrue(pair.registrationDiagnostics.contains { $0.localizedCaseInsensitiveContains("SimpleITK") },
                      "Diagnostics should prove the SimpleITK candidate actually ran: \(pair.registrationDiagnostics)")
        let displayed = pair.displayedOverlay
        let scannerGeometry = VolumeResampler.resample(overlay: pet, toMatch: mri, mode: .linear)
        XCTAssertLessThan(meanAbsoluteDifference(scannerGeometry, displayed), 1e-6,
                          "Auto should not display the worse iterative overlay when it fails QA.")
    }

    private func makeCoarseBrainSmokeAtlas(for volume: ImageVolume) throws -> LabelMap {
        let atlas = LabelMap(
            parentSeriesUID: volume.seriesUID,
            depth: volume.depth,
            height: volume.height,
            width: volume.width,
            name: "Brain PET smoke atlas",
            classes: [
                LabelClass(labelID: 1, name: "Left temporal cortex gray", category: .brain, color: .orange),
                LabelClass(labelID: 2, name: "Right temporal cortex gray", category: .brain, color: .blue),
                LabelClass(labelID: 10, name: "Cerebellar gray", category: .brain, color: .green),
                LabelClass(labelID: 20, name: "White matter", category: .brain, color: .gray)
            ]
        )
        let finiteMax = volume.pixels.lazy.filter(\.isFinite).max() ?? 0
        let threshold = max(finiteMax * 0.05, 0.000001)
        let bounds = try positiveBounds(volume: volume, threshold: threshold)

        var voxels = atlas.voxels
        var counts: [UInt16: Int] = [:]
        fill(labelID: 1, volume: volume, threshold: threshold, bounds: bounds,
             x: 0.18..<0.42, y: 0.25..<0.72, z: 0.35..<0.70,
             voxels: &voxels, counts: &counts)
        fill(labelID: 2, volume: volume, threshold: threshold, bounds: bounds,
             x: 0.58..<0.82, y: 0.25..<0.72, z: 0.35..<0.70,
             voxels: &voxels, counts: &counts)
        fill(labelID: 10, volume: volume, threshold: threshold, bounds: bounds,
             x: 0.35..<0.65, y: 0.15..<0.48, z: 0.05..<0.30,
             voxels: &voxels, counts: &counts)
        fill(labelID: 20, volume: volume, threshold: threshold, bounds: bounds,
             x: 0.42..<0.58, y: 0.38..<0.62, z: 0.40..<0.62,
             voxels: &voxels, counts: &counts)

        for labelID in [UInt16(1), 2, 10, 20] where counts[labelID, default: 0] == 0 {
            backfill(labelID: labelID,
                     volume: volume,
                     threshold: threshold,
                     bounds: bounds,
                     voxels: &voxels,
                     counts: &counts)
        }

        for labelID in [UInt16(1), 2, 10, 20] {
            XCTAssertGreaterThan(counts[labelID, default: 0], 0, "Smoke atlas missing label \(labelID).")
        }
        atlas.voxels = voxels
        return atlas
    }

    private struct Bounds {
        let minZ: Int
        let maxZ: Int
        let minY: Int
        let maxY: Int
        let minX: Int
        let maxX: Int
    }

    private func positiveBounds(volume: ImageVolume, threshold: Float) throws -> Bounds {
        var minZ = volume.depth
        var minY = volume.height
        var minX = volume.width
        var maxZ = -1
        var maxY = -1
        var maxX = -1
        let slice = volume.width * volume.height
        for index in volume.pixels.indices where volume.pixels[index].isFinite && volume.pixels[index] > threshold {
            let z = index / slice
            let y = (index % slice) / volume.width
            let x = index % volume.width
            minZ = min(minZ, z)
            minY = min(minY, y)
            minX = min(minX, x)
            maxZ = max(maxZ, z)
            maxY = max(maxY, y)
            maxX = max(maxX, x)
        }
        guard maxZ >= minZ, maxY >= minY, maxX >= minX else {
            XCTFail("Brain PET volume has no positive finite voxels for smoke atlas.")
            throw XCTSkip("Brain PET volume is empty.")
        }
        return Bounds(minZ: minZ, maxZ: maxZ, minY: minY, maxY: maxY, minX: minX, maxX: maxX)
    }

    private func fill(labelID: UInt16,
                      volume: ImageVolume,
                      threshold: Float,
                      bounds: Bounds,
                      x: Range<Double>,
                      y: Range<Double>,
                      z: Range<Double>,
                      voxels: inout [UInt16],
                      counts: inout [UInt16: Int]) {
        let xr = indexRange(bounds.minX, bounds.maxX, fraction: x)
        let yr = indexRange(bounds.minY, bounds.maxY, fraction: y)
        let zr = indexRange(bounds.minZ, bounds.maxZ, fraction: z)
        for zz in zr {
            for yy in yr {
                let row = (zz * volume.height + yy) * volume.width
                for xx in xr {
                    let index = row + xx
                    guard volume.pixels[index].isFinite, volume.pixels[index] > threshold else { continue }
                    voxels[index] = labelID
                    counts[labelID, default: 0] += 1
                }
            }
        }
    }

    private func backfill(labelID: UInt16,
                          volume: ImageVolume,
                          threshold: Float,
                          bounds: Bounds,
                          voxels: inout [UInt16],
                          counts: inout [UInt16: Int]) {
        var assigned = 0
        let slice = volume.width * volume.height
        let target = max(128, min(2048, slice / 8))
        for z in bounds.minZ...bounds.maxZ {
            for y in bounds.minY...bounds.maxY {
                let row = (z * volume.height + y) * volume.width
                for x in bounds.minX...bounds.maxX {
                    let index = row + x
                    guard voxels[index] == 0,
                          volume.pixels[index].isFinite,
                          volume.pixels[index] > threshold else { continue }
                    voxels[index] = labelID
                    counts[labelID, default: 0] += 1
                    assigned += 1
                    if assigned >= target { return }
                }
            }
        }
    }

    private func indexRange(_ minIndex: Int, _ maxIndex: Int, fraction: Range<Double>) -> Range<Int> {
        let span = max(1, maxIndex - minIndex + 1)
        let lower = minIndex + Int((Double(span) * fraction.lowerBound).rounded(.down))
        let upper = minIndex + Int((Double(span) * fraction.upperBound).rounded(.up))
        let clampedLower = max(minIndex, min(maxIndex, lower))
        let clampedUpper = max(clampedLower + 1, min(maxIndex + 1, upper))
        return clampedLower..<clampedUpper
    }

    private func simpleITKAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import SimpleITK"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func optimizerIterations(from notes: [String]) -> Int {
        for note in notes where note.hasPrefix("optimizerIterations=") {
            return Int(note.dropFirst("optimizerIterations=".count)) ?? 0
        }
        return 0
    }

    private func meanAbsoluteDifference(_ lhs: ImageVolume, _ rhs: ImageVolume) -> Double {
        guard lhs.pixels.count == rhs.pixels.count, !lhs.pixels.isEmpty else { return 0 }
        var sum = 0.0
        for index in lhs.pixels.indices {
            let a = lhs.pixels[index]
            let b = rhs.pixels[index]
            guard a.isFinite, b.isFinite else { continue }
            sum += abs(Double(a - b))
        }
        return sum / Double(lhs.pixels.count)
    }
}
