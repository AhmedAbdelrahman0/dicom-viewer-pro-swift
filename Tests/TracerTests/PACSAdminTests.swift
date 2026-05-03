import XCTest
@testable import Tracer

final class PACSAdminTests: XCTestCase {
    func testMetadataDraftAppliesToIndexedSnapshot() {
        let snapshot = PACSIndexedSeriesSnapshot(
            id: "series-1",
            kind: .dicom,
            seriesUID: "1.2.3",
            studyUID: "1.2",
            modality: "CT",
            patientID: "OLD-ID",
            patientName: "Old^Name",
            accessionNumber: "OLD-ACC",
            studyDescription: "Old Study",
            studyDate: "20260101",
            studyTime: "120000",
            referringPhysicianName: "Old^Ref",
            bodyPartExamined: "CHEST",
            seriesDescription: "CT Chest",
            sourcePath: "/tmp/study",
            filePaths: ["/tmp/study/1.dcm"],
            instanceCount: 1,
            indexedAt: Date(timeIntervalSince1970: 0)
        )

        let draft = PACSStudyMetadataDraft(
            patientName: " New^Name ",
            patientID: " NEW-ID ",
            accessionNumber: " NEW-ACC ",
            studyDescription: " New Study ",
            studyDate: "20260202",
            studyTime: "130000",
            referringPhysicianName: " New^Ref ",
            bodyPartExamined: "ABDOMEN"
        )

        let edited = draft.applying(to: snapshot)

        XCTAssertEqual(edited.patientName, "New^Name")
        XCTAssertEqual(edited.patientID, "NEW-ID")
        XCTAssertEqual(edited.accessionNumber, "NEW-ACC")
        XCTAssertEqual(edited.studyDescription, "New Study")
        XCTAssertEqual(edited.studyDate, "20260202")
        XCTAssertEqual(edited.studyTime, "130000")
        XCTAssertEqual(edited.referringPhysicianName, "New^Ref")
        XCTAssertEqual(edited.bodyPartExamined, "ABDOMEN")
        XCTAssertEqual(edited.seriesDescription, "CT Chest")
    }

    func testAdminDICOMFactoryCreatesParseablePart10Series() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-admin-dicom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = DICOMSeriesCreationDraft(
            patientName: "Admin^Case",
            patientID: "ADMIN-001",
            accessionNumber: "ACC-001",
            studyDescription: "Admin Synthetic Study",
            seriesDescription: "Admin CT",
            referringPhysicianName: "Ref^Doctor",
            bodyPartExamined: "CHEST",
            modality: .CT,
            rows: 8,
            columns: 10,
            slices: 3
        )

        let result = try PACSAdminDICOMFactory.createSyntheticSeries(
            draft: draft,
            outputRoot: root,
            now: Date(timeIntervalSince1970: 1_777_777_777)
        )

        XCTAssertEqual(result.snapshot.kind, .dicom)
        XCTAssertEqual(result.snapshot.patientName, "Admin^Case")
        XCTAssertEqual(result.snapshot.patientID, "ADMIN-001")
        XCTAssertEqual(result.snapshot.studyDescription, "Admin Synthetic Study")
        XCTAssertEqual(result.snapshot.seriesDescription, "Admin CT")
        XCTAssertEqual(result.snapshot.modality, "CT")
        XCTAssertEqual(result.snapshot.instanceCount, 3)
        XCTAssertEqual(result.snapshot.filePaths.count, 3)

        let first = try DICOMLoader.parseHeader(at: URL(fileURLWithPath: result.snapshot.filePaths[0]))
        XCTAssertEqual(first.patientName, "Admin^Case")
        XCTAssertEqual(first.patientID, "ADMIN-001")
        XCTAssertEqual(first.accessionNumber, "ACC-001")
        XCTAssertEqual(first.studyDescription, "Admin Synthetic Study")
        XCTAssertEqual(first.seriesDescription, "Admin CT")
        XCTAssertEqual(first.modality, "CT")
        XCTAssertEqual(first.rows, 8)
        XCTAssertEqual(first.columns, 10)
        XCTAssertEqual(first.bitsAllocated, 16)
        XCTAssertEqual(first.pixelDataLength, 160)

        let files = try result.snapshot.filePaths.map { try DICOMLoader.parseHeader(at: URL(fileURLWithPath: $0)) }
        let volume = try DICOMLoader.loadSeries(files)
        XCTAssertEqual(volume.width, 10)
        XCTAssertEqual(volume.height, 8)
        XCTAssertEqual(volume.depth, 3)
        XCTAssertEqual(volume.patientName, "Admin^Case")
        XCTAssertEqual(volume.seriesDescription, "Admin CT")
    }
}
