import XCTest
@testable import Tracer

final class AutoContourWorkflowTests: XCTestCase {
    func testTemplatesExposeClinicalProtocolsAndPreferredRoutes() {
        let ids = Set(AutoContourWorkflow.templates.map(\.id))
        XCTAssertTrue(ids.contains("head-neck-oar"))
        XCTAssertTrue(ids.contains("thorax-oar"))
        XCTAssertTrue(ids.contains("pet-oncology-lesions"))

        let pet = AutoContourWorkflow.template(id: "pet-oncology-lesions")
        XCTAssertEqual(pet?.preferredNNUnetEntryID, "LesionTracer-AutoPETIII")
        XCTAssertTrue(pet?.structures.contains(where: { $0.name == "FDG-avid lesion" && $0.priority == .required }) == true)
    }

    func testPlanningRoutesProtocolStructures() throws {
        let volume = ImageVolume(pixels: [Float](repeating: 0, count: 4 * 4 * 4),
                                 depth: 4,
                                 height: 4,
                                 width: 4,
                                 modality: "PT",
                                 seriesDescription: "FDG PET")
        let template = try XCTUnwrap(AutoContourWorkflow.template(id: "pet-oncology-lesions"))

        let session = AutoContourWorkflow.plan(template: template, volume: volume)

        XCTAssertEqual(session.preferredNNUnetEntry?.id, "LesionTracer-AutoPETIII")
        XCTAssertGreaterThan(session.routedStructureCount, 0)
        XCTAssertEqual(session.protocolTemplate.structures.count, session.structurePlans.count)
    }

    func testQAFlagsMissingAndEmptyRequiredStructures() throws {
        let volume = ImageVolume(pixels: [Float](repeating: 0, count: 3 * 3 * 3),
                                 depth: 3,
                                 height: 3,
                                 width: 3,
                                 modality: "CT")
        let template = try XCTUnwrap(AutoContourWorkflow.template(id: "thorax-oar"))
        let map = LabelMap(parentSeriesUID: volume.seriesUID,
                           depth: volume.depth,
                           height: volume.height,
                           width: volume.width,
                           name: "Blank thorax",
                           classes: AutoContourWorkflow.labelPreset(for: template).classes)

        let report = AutoContourWorkflow.qaReport(labelMap: map,
                                                  template: template,
                                                  referenceVolume: volume)

        XCTAssertTrue(report.hasBlockingFindings)
        XCTAssertGreaterThan(report.emptyRequiredCount, 0)
        XCTAssertTrue(report.findings.contains { $0.message == "No contour voxels are present." })
    }

    func testQAPassesRequiredPetLesionWhenMaskExists() throws {
        let volume = ImageVolume(pixels: [Float](repeating: 0, count: 3 * 3 * 3),
                                 depth: 3,
                                 height: 3,
                                 width: 3,
                                 modality: "PT")
        let template = try XCTUnwrap(AutoContourWorkflow.template(id: "pet-oncology-lesions"))
        let map = LabelMap(parentSeriesUID: volume.seriesUID,
                           depth: volume.depth,
                           height: volume.height,
                           width: volume.width,
                           name: "PET lesions",
                           classes: AutoContourWorkflow.labelPreset(for: template).classes)
        let lesionID = try XCTUnwrap(map.classes.first { $0.name == "FDG-avid lesion" }?.labelID)
        map.voxels[13] = lesionID

        let report = AutoContourWorkflow.qaReport(labelMap: map,
                                                  template: template,
                                                  referenceVolume: volume)

        XCTAssertFalse(report.hasBlockingFindings)
        XCTAssertEqual(report.missingRequiredCount, 0)
        XCTAssertEqual(report.emptyRequiredCount, 0)
    }

    @MainActor
    func testViewerPreparesStructureSetAndBlocksBlankApproval() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-autocontour-tests-\(UUID().uuidString)", isDirectory: true)
        let vm = ViewerViewModel(
            studySessionStore: StudySessionStore(rootURL: root.appendingPathComponent("StudySessions", isDirectory: true)),
            viewerSessionStore: ViewerSessionStore(rootURL: root.appendingPathComponent("ViewerSessions", isDirectory: true)),
            segmentationRunStore: SegmentationRunRegistryStore(rootURL: root.appendingPathComponent("SegmentationRuns", isDirectory: true))
        )
        vm.currentVolume = ImageVolume(pixels: [Float](repeating: 0, count: 4 * 4 * 4),
                                       depth: 4,
                                       height: 4,
                                       width: 4,
                                       modality: "CT",
                                       seriesDescription: "Thorax CT")

        let session = vm.planAutoContour(templateID: "thorax-oar")
        let map = vm.prepareAutoContourStructureSet()
        let report = vm.refreshAutoContourQA()
        let approved = vm.approveAutoContourSession()

        XCTAssertEqual(session?.protocolTemplate.id, "thorax-oar")
        XCTAssertTrue(map?.classes.contains(where: { $0.name == "Heart" }) == true)
        XCTAssertTrue(report?.hasBlockingFindings == true)
        XCTAssertNil(approved)
        XCTAssertEqual(vm.autoContourSession?.status, .blocked)
    }
}
