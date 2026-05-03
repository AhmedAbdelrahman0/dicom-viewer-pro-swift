import XCTest
@testable import Tracer

final class PACSFeatureExpansionTests: XCTestCase {
    func testAdvancedSearchMatchesFieldsAndRanges() {
        let pet = makeStudy(
            patientID: "MRN-1",
            patientName: "Doe^Jane",
            modality: "PT",
            studyDate: "20260214",
            studyDescription: "FDG PET CT",
            seriesDescription: "PET WB"
        )
        let ct = makeStudy(
            patientID: "MRN-2",
            patientName: "Smith^John",
            modality: "CT",
            studyDate: "20240101",
            studyDescription: "Chest CT",
            seriesDescription: "CT CHEST"
        )

        let query = PACSAdvancedSearchQuery.parse("Modality:PET AND StudyDate:[20260101 TO 20261231] Jane")

        XCTAssertTrue(query.usesFieldSyntax)
        XCTAssertTrue(query.matches(pet))
        XCTAssertFalse(query.matches(ct))
    }

    func testMetadataExporterWritesSeriesCSV() throws {
        let study = makeStudy(
            patientID: "MRN,1",
            patientName: "Doe^Jane",
            modality: "PT",
            studyDate: "20260214",
            studyDescription: "FDG PET/CT",
            seriesDescription: "PET WB"
        )

        let data = PACSMetadataExporter.csvData(
            studies: [study],
            columns: [.patientID, .patientName, .modality, .seriesDescription],
            granularity: .series
        )
        let csv = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(csv.hasPrefix("PatientID,PatientName,Modality,SeriesDescription"))
        XCTAssertTrue(csv.contains("\"MRN,1\",Doe^Jane,PT,PET WB"))
    }

    func testVNAConnectionJSONIgnoresObsoleteProviderField() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy",
          "baseURLString": "https://vna.example/dicomweb",
          "bearerToken": "",
          "isEnabled": true,
          "timeoutSeconds": 60,
          "providerRawValue": "experimental"
        }
        """

        let connection = try JSONDecoder().decode(VNAConnection.self, from: Data(json.utf8))

        XCTAssertEqual(connection.name, "Legacy")
        XCTAssertEqual(connection.normalizedBaseURLString, "https://vna.example/dicomweb")
    }

    func testThumbnailStoreGeneratesThumbnailForSyntheticDICOM() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-thumbnail-source-\(UUID().uuidString)", isDirectory: true)
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-thumbnail-cache-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cache)
        }

        let result = try PACSAdminDICOMFactory.createSyntheticSeries(
            draft: DICOMSeriesCreationDraft(rows: 16, columns: 16, slices: 1),
            outputRoot: root
        )
        let store = PACSThumbnailStore(rootURL: cache, thumbnailSize: 32)

        let thumbnail = try XCTUnwrap(store.thumbnail(for: result.snapshot))

        XCTAssertEqual(thumbnail.seriesID, result.snapshot.id)
        XCTAssertGreaterThan(thumbnail.width, 0)
        XCTAssertGreaterThan(thumbnail.height, 0)
        XCTAssertEqual(thumbnail.pixels.count, thumbnail.width * thumbnail.height)
        XCTAssertNotNil(store.load(seriesID: result.snapshot.id))
    }

    func testArchiveWatchStorePersistsRootIDs() throws {
        let suiteName = "Tracer.PACSArchiveWatchStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PACSArchiveWatchStore(defaults: defaults, key: "watched")

        XCTAssertTrue(store.load().isEmpty)
        XCTAssertEqual(store.setWatched(true, rootID: "/tmp/archive"), Set(["/tmp/archive"]))
        XCTAssertTrue(store.setWatched(false, rootID: "/tmp/archive").isEmpty)
    }
}

private func makeStudy(patientID: String,
                       patientName: String,
                       modality: String,
                       studyDate: String,
                       studyDescription: String,
                       seriesDescription: String) -> PACSWorklistStudy {
    let snapshot = PACSIndexedSeriesSnapshot(
        id: "series-\(patientID)-\(modality)",
        kind: .dicom,
        seriesUID: "1.2.826.\(patientID).1",
        studyUID: "1.2.826.\(patientID)",
        modality: modality,
        patientID: patientID,
        patientName: patientName,
        accessionNumber: "ACC-\(patientID)",
        studyDescription: studyDescription,
        studyDate: studyDate,
        studyTime: "101500",
        referringPhysicianName: "Ref^Doctor",
        bodyPartExamined: "CHEST",
        seriesDescription: seriesDescription,
        sourcePath: "/tmp/\(patientID)",
        filePaths: ["/tmp/\(patientID)/1.dcm"],
        instanceCount: 1,
        indexedAt: Date(timeIntervalSince1970: 0)
    )
    return PACSWorklistStudy(
        id: "study-\(patientID)",
        patientID: patientID,
        patientName: patientName,
        accessionNumber: snapshot.accessionNumber,
        studyUID: snapshot.studyUID,
        studyDescription: studyDescription,
        studyDate: studyDate,
        studyTime: snapshot.studyTime,
        referringPhysicianName: snapshot.referringPhysicianName,
        sourcePath: snapshot.sourcePath,
        series: [snapshot],
        status: .unread,
        indexedAt: snapshot.indexedAt
    )
}
