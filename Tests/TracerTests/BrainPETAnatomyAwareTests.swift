import XCTest
import SwiftUI
@testable import Tracer

final class BrainPETAnatomyAwareTests: XCTestCase {
    func testMRIAnatomyAwareAmyloidExcludesWhiteMatterFromTarget() throws {
        let pet = makeVolume(
            pixels: [3, 6, 2],
            modality: "PT",
            description: "Florbetapir PET"
        )
        let mri = makeVolume(
            pixels: [1, 1, 1],
            modality: "MR",
            description: "T1 MPRAGE"
        )
        let atlas = makeBrainAtlas()

        let report = try BrainPETAnalysis.analyzeAnatomyAware(
            volume: pet,
            atlas: atlas,
            anatomyVolume: mri,
            requestedMode: .mriAssisted,
            configuration: BrainPETAnalysisConfiguration(tracer: .amyloidFlorbetapir)
        )

        XCTAssertEqual(report.resolvedMode, .mriAssisted)
        XCTAssertEqual(report.confidence, .high)
        XCTAssertEqual(report.standardReport.targetSUVR ?? 0, 2.25, accuracy: 1e-9)
        XCTAssertEqual(report.anatomyAwareReport.targetSUVR ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(report.delta.targetSUVR ?? 0, -0.75, accuracy: 1e-9)
        XCTAssertTrue(report.qcMetrics.contains { $0.id == "whiteMatter" && $0.passed })
    }

    func testCTAssistedModeWarnsThatCTIsRegistrationScaffold() throws {
        let pet = makeVolume(
            pixels: [3, 6, 2],
            modality: "PT",
            description: "Florbetapir PET"
        )
        let ct = makeVolume(
            pixels: [35, 35, 35],
            modality: "CT",
            description: "Low dose CT"
        )

        let report = try BrainPETAnalysis.analyzeAnatomyAware(
            volume: pet,
            atlas: makeBrainAtlas(),
            anatomyVolume: ct,
            requestedMode: .ctAssisted,
            configuration: BrainPETAnalysisConfiguration(tracer: .amyloidFlorbetapir)
        )

        XCTAssertEqual(report.resolvedMode, .ctAssisted)
        XCTAssertTrue(report.warnings.contains { $0.contains("low-dose CT alone is limited") })
        XCTAssertEqual(report.anatomyAwareReport.targetSUVR ?? 0, 1.5, accuracy: 1e-9)
    }

    func testRequestedMRIWithoutMRIFallsBackToPETOnly() throws {
        let pet = makeVolume(
            pixels: [3, 6, 2],
            modality: "PT",
            description: "Florbetapir PET"
        )

        let report = try BrainPETAnalysis.analyzeAnatomyAware(
            volume: pet,
            atlas: makeBrainAtlas(),
            anatomyVolume: nil,
            requestedMode: .mriAssisted,
            configuration: BrainPETAnalysisConfiguration(tracer: .amyloidFlorbetapir)
        )

        XCTAssertEqual(report.resolvedMode, .petOnly)
        XCTAssertEqual(report.confidence, .low)
        XCTAssertTrue(report.warnings.contains { $0.contains("fell back to PET-only") })
    }

    private func makeVolume(pixels: [Float],
                            modality: String,
                            description: String) -> ImageVolume {
        ImageVolume(
            pixels: pixels,
            depth: 1,
            height: 1,
            width: 3,
            modality: modality,
            studyUID: "brain-pet-study",
            seriesDescription: description
        )
    }

    private func makeBrainAtlas() -> LabelMap {
        let atlas = LabelMap(
            parentSeriesUID: "brain-pet",
            depth: 1,
            height: 1,
            width: 3,
            name: "Brain tissue atlas",
            classes: [
                LabelClass(labelID: 1, name: "Frontal cortex gray matter", category: .brain, color: .red),
                LabelClass(labelID: 2, name: "Frontal white matter", category: .brain, color: .blue),
                LabelClass(labelID: 3, name: "Cerebellar gray", category: .brain, color: .green)
            ]
        )
        atlas.voxels = [1, 2, 3]
        return atlas
    }
}
