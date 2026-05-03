import Foundation

public struct PACSStudyMetadataDraft: Equatable, Sendable {
    public var patientName: String
    public var patientID: String
    public var accessionNumber: String
    public var studyDescription: String
    public var studyDate: String
    public var studyTime: String
    public var referringPhysicianName: String
    public var bodyPartExamined: String

    public init(patientName: String = "",
                patientID: String = "",
                accessionNumber: String = "",
                studyDescription: String = "",
                studyDate: String = "",
                studyTime: String = "",
                referringPhysicianName: String = "",
                bodyPartExamined: String = "") {
        self.patientName = patientName
        self.patientID = patientID
        self.accessionNumber = accessionNumber
        self.studyDescription = studyDescription
        self.studyDate = studyDate
        self.studyTime = studyTime
        self.referringPhysicianName = referringPhysicianName
        self.bodyPartExamined = bodyPartExamined
    }

    public init(study: PACSWorklistStudy) {
        self.init(
            patientName: study.patientName,
            patientID: study.patientID,
            accessionNumber: study.accessionNumber,
            studyDescription: study.studyDescription,
            studyDate: study.studyDate,
            studyTime: study.studyTime,
            referringPhysicianName: study.referringPhysicianName,
            bodyPartExamined: study.series.first?.bodyPartExamined ?? ""
        )
    }

    public static func anonymized(from study: PACSWorklistStudy) -> PACSStudyMetadataDraft {
        let suffix = abs(study.id.hashValue) % 1_000_000
        return PACSStudyMetadataDraft(
            patientName: "Anonymous^\(suffix)",
            patientID: String(format: "TRACER%06d", suffix),
            accessionNumber: "",
            studyDescription: study.studyDescription.isEmpty ? "Anonymized Study" : study.studyDescription,
            studyDate: study.studyDate,
            studyTime: study.studyTime,
            referringPhysicianName: "",
            bodyPartExamined: study.series.first?.bodyPartExamined ?? ""
        )
    }

    public func applying(to snapshot: PACSIndexedSeriesSnapshot) -> PACSIndexedSeriesSnapshot {
        var edited = snapshot
        edited.patientName = normalized(patientName)
        edited.patientID = normalized(patientID)
        edited.accessionNumber = normalized(accessionNumber)
        edited.studyDescription = normalized(studyDescription)
        edited.studyDate = normalized(studyDate)
        edited.studyTime = normalized(studyTime)
        edited.referringPhysicianName = normalized(referringPhysicianName)
        edited.bodyPartExamined = normalized(bodyPartExamined)
        edited.indexedAt = Date()
        return edited
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PACSAdminDICOMModality: String, CaseIterable, Identifiable, Codable, Sendable {
    case CT
    case MR
    case PT
    case OT

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .CT: return "CT"
        case .MR: return "MR"
        case .PT: return "PET"
        case .OT: return "Other"
        }
    }

    var sopClassUID: String {
        switch self {
        case .CT: return "1.2.840.10008.5.1.4.1.1.2"
        case .MR: return "1.2.840.10008.5.1.4.1.1.4"
        case .PT: return "1.2.840.10008.5.1.4.1.1.128"
        case .OT: return "1.2.840.10008.5.1.4.1.1.7"
        }
    }
}

public struct DICOMSeriesCreationDraft: Equatable, Sendable {
    public var patientName: String
    public var patientID: String
    public var accessionNumber: String
    public var studyDescription: String
    public var seriesDescription: String
    public var referringPhysicianName: String
    public var bodyPartExamined: String
    public var modality: PACSAdminDICOMModality
    public var rows: Int
    public var columns: Int
    public var slices: Int

    public init(patientName: String = "Admin^Synthetic",
                patientID: String = "TRACER-ADMIN",
                accessionNumber: String = "",
                studyDescription: String = "Tracer Admin Synthetic Study",
                seriesDescription: String = "Synthetic Image Series",
                referringPhysicianName: String = "",
                bodyPartExamined: String = "",
                modality: PACSAdminDICOMModality = .CT,
                rows: Int = 64,
                columns: Int = 64,
                slices: Int = 8) {
        self.patientName = patientName
        self.patientID = patientID
        self.accessionNumber = accessionNumber
        self.studyDescription = studyDescription
        self.seriesDescription = seriesDescription
        self.referringPhysicianName = referringPhysicianName
        self.bodyPartExamined = bodyPartExamined
        self.modality = modality
        self.rows = rows
        self.columns = columns
        self.slices = slices
    }

    public var validationMessage: String? {
        if patientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Patient ID is required."
        }
        if patientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Patient name is required."
        }
        if studyDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Study name is required."
        }
        if seriesDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Series name is required."
        }
        if rows < 1 || columns < 1 || slices < 1 {
            return "Rows, columns, and slices must be greater than zero."
        }
        return nil
    }

    var normalized: DICOMSeriesCreationDraft {
        var copy = self
        copy.patientName = trimmed(patientName)
        copy.patientID = trimmed(patientID)
        copy.accessionNumber = trimmed(accessionNumber)
        copy.studyDescription = trimmed(studyDescription)
        copy.seriesDescription = trimmed(seriesDescription)
        copy.referringPhysicianName = trimmed(referringPhysicianName)
        copy.bodyPartExamined = trimmed(bodyPartExamined)
        copy.rows = min(max(rows, 1), 512)
        copy.columns = min(max(columns, 1), 512)
        copy.slices = min(max(slices, 1), 256)
        return copy
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct PACSAdminDICOMCreationResult: Sendable {
    public let outputDirectory: URL
    public let snapshot: PACSIndexedSeriesSnapshot
}

public enum PACSAdminDICOMFactory {
    public static var defaultOutputRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return (documents ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Tracer Admin DICOM", isDirectory: true)
    }

    public static func createSyntheticSeries(draft rawDraft: DICOMSeriesCreationDraft,
                                             outputRoot: URL = defaultOutputRoot,
                                             now: Date = Date()) throws -> PACSAdminDICOMCreationResult {
        if let validationMessage = rawDraft.validationMessage {
            throw PACSAdminError.invalidDraft(validationMessage)
        }

        let draft = rawDraft.normalized
        let dateTime = dicomDateTime(now: now)
        let studyDate = dateTime.date
        let studyTime = dateTime.time
        let studyUID = DICOMExportWriter.makeUID()
        let seriesUID = DICOMExportWriter.makeUID()
        let frameOfReferenceUID = DICOMExportWriter.makeUID()

        let folder = outputRoot
            .appendingPathComponent(pathComponent(draft.patientID), isDirectory: true)
            .appendingPathComponent(pathComponent(draft.studyDescription), isDirectory: true)
            .appendingPathComponent("\(pathComponent(draft.seriesDescription))-\(seriesUID.suffix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var paths: [String] = []
        for z in 0..<draft.slices {
            let sopUID = DICOMExportWriter.makeUID()
            let dataset = makeDataset(draft: draft,
                                      sopClassUID: draft.modality.sopClassUID,
                                      sopInstanceUID: sopUID,
                                      studyUID: studyUID,
                                      seriesUID: seriesUID,
                                      frameOfReferenceUID: frameOfReferenceUID,
                                      studyDate: studyDate,
                                      studyTime: studyTime,
                                      z: z)
            let file = DICOMExportWriter.part10File(sopClassUID: draft.modality.sopClassUID,
                                                    sopInstanceUID: sopUID,
                                                    dataset: dataset)
            let url = folder.appendingPathComponent(String(format: "IM-%04d.dcm", z + 1))
            try file.write(to: url, options: [.atomic])
            paths.append(url.path)
        }

        let snapshot = PACSIndexedSeriesSnapshot(
            id: "admin-dicom:\(seriesUID)",
            kind: .dicom,
            seriesUID: seriesUID,
            studyUID: studyUID,
            modality: draft.modality.rawValue,
            patientID: draft.patientID,
            patientName: draft.patientName,
            accessionNumber: draft.accessionNumber,
            studyDescription: draft.studyDescription,
            studyDate: studyDate,
            studyTime: studyTime,
            referringPhysicianName: draft.referringPhysicianName,
            bodyPartExamined: draft.bodyPartExamined,
            seriesDescription: draft.seriesDescription,
            sourcePath: folder.path,
            filePaths: paths,
            instanceCount: paths.count,
            indexedAt: now
        )

        return PACSAdminDICOMCreationResult(outputDirectory: folder, snapshot: snapshot)
    }

    private static func makeDataset(draft: DICOMSeriesCreationDraft,
                                    sopClassUID: String,
                                    sopInstanceUID: String,
                                    studyUID: String,
                                    seriesUID: String,
                                    frameOfReferenceUID: String,
                                    studyDate: String,
                                    studyTime: String,
                                    z: Int) -> Data {
        var dataset = Data()
        dataset.appendDICOMElement(group: 0x0008, element: 0x0008, vr: "CS", strings: ["ORIGINAL", "PRIMARY", "AXIAL"])
        dataset.appendDICOMElement(group: 0x0008, element: 0x0016, vr: "UI", string: sopClassUID)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0018, vr: "UI", string: sopInstanceUID)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0020, vr: "DA", string: studyDate)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0030, vr: "TM", string: studyTime)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0050, vr: "SH", string: draft.accessionNumber)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0060, vr: "CS", string: draft.modality.rawValue)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0070, vr: "LO", string: "Tracer")
        dataset.appendDICOMElement(group: 0x0008, element: 0x0090, vr: "PN", string: draft.referringPhysicianName)
        dataset.appendDICOMElement(group: 0x0008, element: 0x1030, vr: "LO", string: draft.studyDescription)
        dataset.appendDICOMElement(group: 0x0008, element: 0x103E, vr: "LO", string: draft.seriesDescription)
        dataset.appendDICOMElement(group: 0x0010, element: 0x0010, vr: "PN", string: draft.patientName)
        dataset.appendDICOMElement(group: 0x0010, element: 0x0020, vr: "LO", string: draft.patientID)
        dataset.appendDICOMElement(group: 0x0018, element: 0x0015, vr: "CS", string: draft.bodyPartExamined)
        dataset.appendDICOMElement(group: 0x0018, element: 0x0050, vr: "DS", string: "1")
        dataset.appendDICOMElement(group: 0x0020, element: 0x000D, vr: "UI", string: studyUID)
        dataset.appendDICOMElement(group: 0x0020, element: 0x000E, vr: "UI", string: seriesUID)
        dataset.appendDICOMElement(group: 0x0020, element: 0x0010, vr: "SH", string: "1")
        dataset.appendDICOMElement(group: 0x0020, element: 0x0011, vr: "IS", string: "1")
        dataset.appendDICOMElement(group: 0x0020, element: 0x0013, vr: "IS", string: "\(z + 1)")
        dataset.appendDICOMElement(group: 0x0020, element: 0x0032, vr: "DS", string: DICOMExportWriter.ds([0, 0, Double(z)]))
        dataset.appendDICOMElement(group: 0x0020, element: 0x0037, vr: "DS", string: DICOMExportWriter.ds([1, 0, 0, 0, 1, 0]))
        dataset.appendDICOMElement(group: 0x0020, element: 0x0052, vr: "UI", string: frameOfReferenceUID)
        dataset.appendDICOMElement(group: 0x0020, element: 0x1041, vr: "DS", string: DICOMExportWriter.formatDS(Double(z)))
        dataset.appendDICOMElement(group: 0x0028, element: 0x0002, vr: "US", uint16: 1)
        dataset.appendDICOMElement(group: 0x0028, element: 0x0004, vr: "CS", string: "MONOCHROME2")
        dataset.appendDICOMElement(group: 0x0028, element: 0x0010, vr: "US", uint16: UInt16(draft.rows))
        dataset.appendDICOMElement(group: 0x0028, element: 0x0011, vr: "US", uint16: UInt16(draft.columns))
        dataset.appendDICOMElement(group: 0x0028, element: 0x0030, vr: "DS", string: "1\\1")
        dataset.appendDICOMElement(group: 0x0028, element: 0x0100, vr: "US", uint16: 16)
        dataset.appendDICOMElement(group: 0x0028, element: 0x0101, vr: "US", uint16: 16)
        dataset.appendDICOMElement(group: 0x0028, element: 0x0102, vr: "US", uint16: 15)
        dataset.appendDICOMElement(group: 0x0028, element: 0x0103, vr: "US", uint16: 0)
        dataset.appendDICOMElement(group: 0x0028, element: 0x1052, vr: "DS", string: "0")
        dataset.appendDICOMElement(group: 0x0028, element: 0x1053, vr: "DS", string: "1")
        dataset.appendDICOMElement(group: 0x7FE0, element: 0x0010, vr: "OW", bytes: pixelData(rows: draft.rows, columns: draft.columns, z: z))
        return dataset
    }

    private static func pixelData(rows: Int, columns: Int, z: Int) -> Data {
        var data = Data()
        data.reserveCapacity(rows * columns * 2)
        for y in 0..<rows {
            for x in 0..<columns {
                let value = UInt16(min(4095, 128 + z * 24 + x + y))
                data.appendDICOMUInt16LE(value)
            }
        }
        return data
    }

    private static func dicomDateTime(now: Date) -> (date: String, time: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)

        formatter.dateFormat = "yyyyMMdd"
        let date = formatter.string(from: now)
        formatter.dateFormat = "HHmmss"
        let time = formatter.string(from: now)
        return (date, time)
    }

    private static func pathComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let parts = value
            .components(separatedBy: invalid)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joined = parts.joined(separator: "-")
        return joined.isEmpty ? "Tracer" : String(joined.prefix(80))
    }
}

public enum PACSAdminError: LocalizedError {
    case invalidDraft(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDraft(let message): return message
        }
    }
}
