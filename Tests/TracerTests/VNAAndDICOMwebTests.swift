import XCTest
@testable import Tracer

final class VNAAndDICOMwebTests: XCTestCase {
    func testVNAConnectionStoreRoundTripsConnections() throws {
        let suiteName = "Tracer.VNAConnectionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = VNAConnectionStore(defaults: defaults)
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let connection = VNAConnection(id: id,
                                       name: "Enterprise VNA",
                                       baseURLString: "vna.example.org/dicomweb",
                                       bearerToken: "token",
                                       lastUsedAt: Date(timeIntervalSince1970: 100))

        store.upsert(connection)
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, id)
        XCTAssertEqual(loaded.first?.normalizedBaseURLString, "https://vna.example.org/dicomweb")
        XCTAssertEqual(loaded.first?.bearerToken, "token")
    }

    func testDICOMwebMetadataDecoderMapsStudySeriesAndInstances() throws {
        let connection = VNAConnection(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "VNA",
            baseURLString: "https://vna.example.org/dicomweb"
        )

        let studiesJSON = """
        [
          {
            "00100010": { "vr": "PN", "Value": [{ "Alphabetic": "DOE^JANE" }] },
            "00100020": { "vr": "LO", "Value": ["MRN123"] },
            "00080050": { "vr": "SH", "Value": ["ACC456"] },
            "0020000D": { "vr": "UI", "Value": ["1.2.3"] },
            "00081030": { "vr": "LO", "Value": ["FDG PET/CT"] },
            "00080020": { "vr": "DA", "Value": ["20260426"] },
            "00080030": { "vr": "TM", "Value": ["101500"] },
            "00080061": { "vr": "CS", "Value": ["CT", "PT"] },
            "00201206": { "vr": "IS", "Value": [2] },
            "00201208": { "vr": "IS", "Value": ["321"] }
          }
        ]
        """

        let studies = try DICOMwebMetadataDecoder.decodeStudies(data: Data(studiesJSON.utf8),
                                                                connection: connection)

        XCTAssertEqual(studies.count, 1)
        XCTAssertEqual(studies[0].patientName, "DOE^JANE")
        XCTAssertEqual(studies[0].patientID, "MRN123")
        XCTAssertEqual(studies[0].accessionNumber, "ACC456")
        XCTAssertEqual(studies[0].studyInstanceUID, "1.2.3")
        XCTAssertEqual(studies[0].modalities, ["CT", "PET"])
        XCTAssertEqual(studies[0].seriesCount, 2)
        XCTAssertEqual(studies[0].instanceCount, 321)

        let seriesJSON = """
        [
          {
            "0020000D": { "vr": "UI", "Value": ["1.2.3"] },
            "0020000E": { "vr": "UI", "Value": ["1.2.3.4"] },
            "00080060": { "vr": "CS", "Value": ["PT"] },
            "0008103E": { "vr": "LO", "Value": ["PET AC"] },
            "00200011": { "vr": "IS", "Value": ["7"] },
            "00201209": { "vr": "IS", "Value": [123] }
          }
        ]
        """

        let series = try DICOMwebMetadataDecoder.decodeSeries(data: Data(seriesJSON.utf8),
                                                              connection: connection,
                                                              studyUID: "1.2.3")

        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].seriesInstanceUID, "1.2.3.4")
        XCTAssertEqual(series[0].modality, "PT")
        XCTAssertEqual(series[0].seriesDescription, "PET AC")
        XCTAssertEqual(series[0].seriesNumber, 7)
        XCTAssertEqual(series[0].instanceCount, 123)

        let instancesJSON = """
        [
          {
            "0020000D": { "vr": "UI", "Value": ["1.2.3"] },
            "0020000E": { "vr": "UI", "Value": ["1.2.3.4"] },
            "00080018": { "vr": "UI", "Value": ["1.2.3.4.5"] },
            "00200013": { "vr": "IS", "Value": ["9"] }
          }
        ]
        """

        let instances = try DICOMwebMetadataDecoder.decodeInstances(data: Data(instancesJSON.utf8),
                                                                    connection: connection,
                                                                    studyUID: "1.2.3",
                                                                    seriesUID: "1.2.3.4")

        XCTAssertEqual(instances.count, 1)
        XCTAssertEqual(instances[0].sopInstanceUID, "1.2.3.4.5")
        XCTAssertEqual(instances[0].instanceNumber, 9)
    }

    func testDICOMwebMultipartParserExtractsApplicationDicomParts() {
        var body = Data()
        body.append("--boundary-1\r\nContent-Type: application/dicom\r\n\r\n")
        body.append("DICOM-A")
        body.append("\r\n--boundary-1\r\nContent-Type: application/dicom\r\n\r\n")
        body.append("DICOM-B")
        body.append("\r\n--boundary-1--\r\n")

        let parts = DICOMwebMultipartParser.extractParts(
            from: body,
            contentType: "multipart/related; type=\"application/dicom\"; boundary=boundary-1"
        )

        XCTAssertEqual(parts.map { String(data: $0, encoding: .utf8) }, ["DICOM-A", "DICOM-B"])
    }

    func testVNACacheStoreWritesSafeDICOMPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tracer-VNACacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = VNACacheStore(rootURL: root)
        let connectionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let url = try store.writeInstance(Data("dicom".utf8),
                                          connectionID: connectionID,
                                          studyUID: "1.2/3",
                                          seriesUID: "4.5:6",
                                          sopInstanceUID: "7.8 9")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(url.path.contains(":"))
        XCTAssertFalse(url.path.contains(" "))
    }

    func testDICOMwebStoreInstancesBuildsSTOWMultipartRequest() async throws {
        let connection = VNAConnection(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "VNA",
            baseURLString: "https://vna.example.org/dicomweb",
            bearerToken: "secret"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DICOMwebStoreMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        DICOMwebStoreMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/dicomweb/studies/1.2.3")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/related") == true)
            let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream?.readAllData())
            let text = String(data: body, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains("DICOM-A"))
            XCTAssertTrue(text.contains("DICOM-B"))
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/dicom+json"])!
            return (response, Data("[]".utf8))
        }
        defer { DICOMwebStoreMockURLProtocol.handler = nil }

        let client = try DICOMwebClient(configuration: .init(connection: connection),
                                        session: session)
        try await client.storeInstances([Data("DICOM-A".utf8), Data("DICOM-B".utf8)],
                                        studyInstanceUID: "1.2.3")
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

private extension InputStream {
    func readAllData() -> Data {
        open()
        defer { close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while hasBytesAvailable {
            let count = read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}

private final class DICOMwebStoreMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
