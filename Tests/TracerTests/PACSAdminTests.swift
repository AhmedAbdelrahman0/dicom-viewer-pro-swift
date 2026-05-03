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

    func testDICOMTagEditValidatesAndAppliesSupportedTags() {
        let snapshot = makeAdminSnapshot(studyUID: "1.2.3", seriesUID: "1.2.3.4")
        var draft = PACSAdminTagEditDraft(tag: .studyDate, value: "2026-01-01")
        XCTAssertNotNil(draft.validationMessage)

        draft.value = "20260503"
        XCTAssertNil(draft.validationMessage)
        let edited = draft.applying(to: [snapshot])
        XCTAssertEqual(edited.first?.studyDate, "20260503")

        let uidDraft = PACSAdminTagEditDraft(tag: .seriesUID, value: "1..2")
        XCTAssertNotNil(uidDraft.validationMessage)
    }

    func testBatchOperationAppliesAcrossStudies() {
        let studies = [
            makeAdminStudy(id: "study-a", accession: "A1"),
            makeAdminStudy(id: "study-b", accession: "A2"),
        ]
        let draft = PACSAdminBatchOperationDraft(kind: .setBodyPart, value: "chest")

        let snapshots = draft.applying(to: studies)

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(Set(snapshots.map(\.bodyPartExamined)), ["CHEST"])
    }

    func testDeidentificationPlanRemapsUIDsAndFlagsBurnedInRisk() {
        let study = makeAdminStudy(id: "study-a",
                                   description: "Secondary Capture PET",
                                   accession: "A1")

        let plan = PACSAdminDeidentificationPlan.make(studies: [study])

        XCTAssertEqual(plan.snapshots.count, 1)
        XCTAssertEqual(plan.snapshots[0].patientName, "Anonymous^000001")
        XCTAssertEqual(plan.snapshots[0].patientID, "TRACER000001")
        XCTAssertEqual(plan.snapshots[0].accessionNumber, "")
        XCTAssertNotEqual(plan.snapshots[0].studyUID, study.studyUID)
        XCTAssertNotEqual(plan.snapshots[0].seriesUID, study.series[0].seriesUID)
        XCTAssertEqual(plan.uidMappings.count, 2)
        XCTAssertTrue(plan.warnings.contains { $0.contains("burned-in PHI") })
    }

    func testQuarantineFindingsDetectMissingPatientAndDuplicateUIDs() {
        let first = makeAdminStudy(id: "study-a", patientID: "", studyUID: "1.2.3", seriesUID: "1.2.3.4")
        let second = makeAdminStudy(id: "study-b", patientID: "MRN", studyUID: "1.2.3", seriesUID: "1.2.3.5")

        let findings = PACSAdminQuarantineFinding.evaluate(studies: [first, second])

        XCTAssertTrue(findings.contains { $0.title == "Missing Patient ID" })
        XCTAssertTrue(findings.contains { $0.title == "Duplicate Study UID" })
    }

    func testWorkflowRulesAndHealthSnapshotSummarizeAdminState() {
        let pet = makeAdminStudy(id: "study-a", modality: "PT", description: "FDG PET/CT")
        let rules = PACSAdminWorkflowRule.defaults

        XCTAssertTrue(rules[0].matches(pet))

        let health = PACSAdminHealthSnapshot.make(studies: [pet],
                                                  vnaConnectionCount: 2,
                                                  routeQueueCount: 1,
                                                  quarantineIssueCount: 3)
        XCTAssertEqual(health.studyCount, 1)
        XCTAssertEqual(health.seriesCount, 1)
        XCTAssertEqual(health.instanceCount, 1)
        XCTAssertEqual(health.vnaConnectionCount, 2)
        XCTAssertEqual(health.routeQueueCount, 1)
        XCTAssertEqual(health.quarantineIssueCount, 3)
    }

    func testAuditAndRoutingStoresRoundTrip() throws {
        let suiteName = "Tracer.PACSAdminTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let audit = PACSAdminAuditStore(defaults: defaults, key: "audit")
        audit.append(PACSAdminAuditEvent(kind: .tagEdit, studyID: "study", summary: "Edited tag"))
        XCTAssertEqual(audit.load().first?.summary, "Edited tag")

        let routes = PACSAdminRoutingQueueStore(defaults: defaults, key: "routes")
        let queued = PACSAdminRouteQueueItem(endpointName: "VNA",
                                             endpointURL: "https://vna.example/dicomweb",
                                             studyID: "study",
                                             studyDescription: "PET",
                                             instanceCount: 4)
        routes.upsert(queued)
        XCTAssertEqual(routes.load().first?.instanceCount, 4)

        var sent = queued
        sent.status = .sent
        routes.upsert(sent)
        XCTAssertTrue(routes.clearCompleted().isEmpty)
    }
}

private func makeAdminStudy(id: String,
                            patientID: String = "MRN",
                            modality: String = "CT",
                            description: String = "Admin Study",
                            accession: String = "ACC",
                            studyUID: String = "1.2.826.0.1",
                            seriesUID: String = "1.2.826.0.1.1") -> PACSWorklistStudy {
    let snapshot = makeAdminSnapshot(patientID: patientID,
                                     modality: modality,
                                     description: description,
                                     accession: accession,
                                     studyUID: studyUID,
                                     seriesUID: seriesUID)
    return PACSWorklistStudy(
        id: id,
        patientID: patientID,
        patientName: "Admin^Patient",
        accessionNumber: accession,
        studyUID: studyUID,
        studyDescription: description,
        studyDate: "20260503",
        studyTime: "010203",
        referringPhysicianName: "Ref^Physician",
        sourcePath: "/tmp/admin",
        series: [snapshot],
        status: .unread,
        indexedAt: Date(timeIntervalSince1970: 0)
    )
}

private func makeAdminSnapshot(patientID: String = "MRN",
                               modality: String = "CT",
                               description: String = "Admin Study",
                               accession: String = "ACC",
                               studyUID: String = "1.2.826.0.1",
                               seriesUID: String = "1.2.826.0.1.1") -> PACSIndexedSeriesSnapshot {
    PACSIndexedSeriesSnapshot(
        id: "series-\(seriesUID)",
        kind: .dicom,
        seriesUID: seriesUID,
        studyUID: studyUID,
        modality: modality,
        patientID: patientID,
        patientName: "Admin^Patient",
        accessionNumber: accession,
        studyDescription: description,
        studyDate: "20260503",
        studyTime: "010203",
        referringPhysicianName: "Ref^Physician",
        bodyPartExamined: "CHEST",
        seriesDescription: "\(modality) Admin",
        sourcePath: "/tmp/admin",
        filePaths: ["/tmp/admin/1.dcm"],
        instanceCount: 1,
        indexedAt: Date(timeIntervalSince1970: 0)
    )
}
