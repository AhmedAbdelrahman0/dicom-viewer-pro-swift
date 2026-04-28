import XCTest
import SwiftUI
@testable import Tracer

final class LocalPETCTDatasetSmokeTests: XCTestCase {
    private func smokeDirectory() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["TRACER_PETCT_SMOKE_DIR"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set TRACER_PETCT_SMOKE_DIR to run the local PET/CT study smoke test.")
        }
        let url = URL(fileURLWithPath: raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            XCTFail("TRACER_PETCT_SMOKE_DIR does not exist: \(url.path)")
            throw XCTSkip("Missing local PET/CT smoke directory.")
        }
        return url
    }

    func testLocalFDGPETCTStudyLoadsAndQuantifies() throws {
        let root = try smokeDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("CT.nii.gz").path),
                      "Missing native-resolution CT.nii.gz")
        let ct = try load("CTres.nii.gz", in: root, hint: "CT")
        let pet = try load("PET.nii.gz", in: root, hint: "PT")
        let suv = try load("SUV.nii.gz", in: root, hint: "PT")
        let seg = try load("SEG.nii.gz", in: root, hint: "SEG")

        for volume in [ct, pet, suv, seg] {
            XCTAssertGreaterThan(volume.width, 0)
            XCTAssertGreaterThan(volume.height, 0)
            XCTAssertGreaterThan(volume.depth, 0)
            XCTAssertEqual(volume.pixels.count, volume.width * volume.height * volume.depth)
            XCTAssertTrue(volume.intensityRange.min.isFinite)
            XCTAssertTrue(volume.intensityRange.max.isFinite)
            XCTAssertGreaterThanOrEqual(volume.intensityRange.max, volume.intensityRange.min)
        }

        XCTAssertTrue(sameDimensions(suv, seg), "SUV and SEG must share a voxel grid for label quantification.")
        XCTAssertTrue(sameGeometry(suv, seg), "SUV and SEG must preserve shared affine geometry.")

        let label = LabelMap(parentSeriesUID: suv.seriesUID,
                             depth: seg.depth,
                             height: seg.height,
                             width: seg.width,
                             name: "FDG lesion mask")
        label.classes = [LabelClass(labelID: 1, name: "FDG lesion", category: .pathology, color: .red)]
        var labelVoxels = label.voxels
        var positiveVoxels = 0
        for i in seg.pixels.indices where seg.pixels[i] > 0.5 {
            labelVoxels[i] = 1
            positiveVoxels += 1
        }
        label.voxels = labelVoxels
        XCTAssertGreaterThan(positiveVoxels, 0, "SEG.nii.gz should contain at least one lesion voxel.")

        let report = try PETQuantification.compute(petVolume: suv,
                                                   labelMap: label,
                                                   classes: [1],
                                                   connectedComponents: false)
        XCTAssertGreaterThan(report.lesionCount, 0)
        XCTAssertGreaterThan(report.maxSUV, 0)
        XCTAssertGreaterThan(report.totalMetabolicTumorVolumeML, 0)

        let thresholdLabel = LabelMap(parentSeriesUID: suv.seriesUID,
                                      depth: suv.depth,
                                      height: suv.height,
                                      width: suv.width,
                                      name: "SUV threshold")
        thresholdLabel.classes = [LabelClass(labelID: 1, name: "SUV >= 2.5", category: .pathology, color: .orange)]
        let thresholdCount = PETSegmentation.thresholdAbove(volume: suv,
                                                            label: thresholdLabel,
                                                            threshold: 2.5,
                                                            classID: 1)
        XCTAssertGreaterThan(thresholdCount, 0, "SUV thresholding should find uptake in this FDG study.")
    }

    @MainActor
    func testViewerWorkflowLoadsOncologyCaseAndMeasuresROIs() async throws {
        let root = try smokeDirectory()
        let sessionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tracer-OncologyCase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionRoot) }

        let vm = ViewerViewModel(studySessionStore: StudySessionStore(rootURL: sessionRoot))
        vm.suvSettings.mode = .storedSUV

        await vm.loadNIfTI(url: root.appendingPathComponent("CTres.nii.gz"), autoFuse: false)
        await vm.loadNIfTI(url: root.appendingPathComponent("SUV.nii.gz"), autoFuse: true)

        let ct = try XCTUnwrap(vm.loadedCTVolumes.first, "CTres should load through the viewer path.")
        let pet = try XCTUnwrap(vm.loadedPETVolumes.first, "SUV PET should load through the viewer path.")
        if vm.fusion == nil {
            await vm.fusePETCT(base: ct, overlay: pet)
        }
        let fusion = try XCTUnwrap(vm.fusion, "PET/CT fusion should be configured for the oncology case.")
        XCTAssertTrue(fusion.isPETCT)
        XCTAssertTrue(ImageVolumeGeometry.gridsMatch(fusion.baseVolume, fusion.displayedOverlay),
                      "Displayed PET overlay must be on the CT grid for fused measurement/review.")

        let labelImport = try vm.labeling.loadLabel(
            from: root.appendingPathComponent("SEG.nii.gz"),
            parentVolume: pet
        )
        let labelMap = labelImport.labelMap
        let classID = try XCTUnwrap(labelMap.classes.first?.labelID)
        let stats = try XCTUnwrap(vm.activePETRegionStats(for: labelMap, classID: classID))
        XCTAssertGreaterThan(stats.suvMax ?? 0, 0)
        XCTAssertGreaterThan(stats.suvMean ?? 0, 0)

        let maxIndex = try XCTUnwrap(pet.pixels.indices.max(by: { pet.pixels[$0] < pet.pixels[$1] }))
        let sliceSize = pet.width * pet.height
        let z = maxIndex / sliceSize
        let y = (maxIndex % sliceSize) / pet.width
        let x = maxIndex % pet.width
        let suvROI = try XCTUnwrap(vm.addSphericalSUVROI(
            at: pet.worldPoint(z: z, y: y, x: x),
            radiusMM: 10
        ))
        XCTAssertGreaterThan(suvROI.suvMax, 0)
        XCTAssertEqual(vm.suvROIMeasurements.count, 1)

        let huROI = try XCTUnwrap(vm.addSphericalIntensityROI(
            at: ct.worldPoint(z: ct.depth / 2, y: ct.height / 2, x: ct.width / 2),
            in: ct,
            radiusMM: 10
        ))
        XCTAssertEqual(huROI.unit, "HU")
        XCTAssertEqual(vm.intensityROIMeasurements.count, 1)
    }

    private func load(_ filename: String, in root: URL, hint: String) throws -> ImageVolume {
        let url = root.appendingPathComponent(filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing \(filename)")
        return try NIfTILoader.load(url, modalityHint: hint)
    }

    private func sameDimensions(_ lhs: ImageVolume, _ rhs: ImageVolume) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.depth == rhs.depth
    }

    private func sameGeometry(_ lhs: ImageVolume, _ rhs: ImageVolume, tolerance: Double = 1e-4) -> Bool {
        guard sameDimensions(lhs, rhs) else { return false }
        let spacingOK = abs(lhs.spacing.x - rhs.spacing.x) <= tolerance
            && abs(lhs.spacing.y - rhs.spacing.y) <= tolerance
            && abs(lhs.spacing.z - rhs.spacing.z) <= tolerance
        let originOK = abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.origin.z - rhs.origin.z) <= tolerance
        guard spacingOK, originOK else { return false }
        for c in 0..<3 {
            for r in 0..<3 where abs(lhs.direction[c][r] - rhs.direction[c][r]) > tolerance {
                return false
            }
        }
        return true
    }
}
