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
        let suffix = stableNumericSuffix(for: study.id)
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

    private static func stableNumericSuffix(for value: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % 1_000_000)
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

public enum PACSAdminSupportedTag: String, CaseIterable, Identifiable, Codable, Sendable {
    case patientName
    case patientID
    case accessionNumber
    case studyDescription
    case studyDate
    case studyTime
    case referringPhysicianName
    case bodyPartExamined
    case modality
    case seriesDescription
    case studyUID
    case seriesUID

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .patientName: return "Patient Name"
        case .patientID: return "Patient ID"
        case .accessionNumber: return "Accession"
        case .studyDescription: return "Study Name"
        case .studyDate: return "Study Date"
        case .studyTime: return "Study Time"
        case .referringPhysicianName: return "Referring Physician"
        case .bodyPartExamined: return "Body Part"
        case .modality: return "Modality"
        case .seriesDescription: return "Series Name"
        case .studyUID: return "Study UID"
        case .seriesUID: return "Series UID"
        }
    }

    public var tag: String {
        switch self {
        case .patientName: return "(0010,0010)"
        case .patientID: return "(0010,0020)"
        case .accessionNumber: return "(0008,0050)"
        case .studyDescription: return "(0008,1030)"
        case .studyDate: return "(0008,0020)"
        case .studyTime: return "(0008,0030)"
        case .referringPhysicianName: return "(0008,0090)"
        case .bodyPartExamined: return "(0018,0015)"
        case .modality: return "(0008,0060)"
        case .seriesDescription: return "(0008,103E)"
        case .studyUID: return "(0020,000D)"
        case .seriesUID: return "(0020,000E)"
        }
    }

    public var vr: String {
        switch self {
        case .patientName, .referringPhysicianName: return "PN"
        case .patientID, .studyDescription, .seriesDescription: return "LO"
        case .accessionNumber: return "SH"
        case .studyDate: return "DA"
        case .studyTime: return "TM"
        case .bodyPartExamined, .modality: return "CS"
        case .studyUID, .seriesUID: return "UI"
        }
    }

    public func value(from snapshot: PACSIndexedSeriesSnapshot) -> String {
        switch self {
        case .patientName: return snapshot.patientName
        case .patientID: return snapshot.patientID
        case .accessionNumber: return snapshot.accessionNumber
        case .studyDescription: return snapshot.studyDescription
        case .studyDate: return snapshot.studyDate
        case .studyTime: return snapshot.studyTime
        case .referringPhysicianName: return snapshot.referringPhysicianName
        case .bodyPartExamined: return snapshot.bodyPartExamined
        case .modality: return snapshot.modality
        case .seriesDescription: return snapshot.seriesDescription
        case .studyUID: return snapshot.studyUID
        case .seriesUID: return snapshot.seriesUID
        }
    }

    public func applying(_ rawValue: String, to snapshot: PACSIndexedSeriesSnapshot) -> PACSIndexedSeriesSnapshot {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var edited = snapshot
        switch self {
        case .patientName: edited.patientName = value
        case .patientID: edited.patientID = value
        case .accessionNumber: edited.accessionNumber = value
        case .studyDescription: edited.studyDescription = value
        case .studyDate: edited.studyDate = value
        case .studyTime: edited.studyTime = value
        case .referringPhysicianName: edited.referringPhysicianName = value
        case .bodyPartExamined: edited.bodyPartExamined = value.uppercased()
        case .modality: edited.modality = value.uppercased()
        case .seriesDescription: edited.seriesDescription = value
        case .studyUID: edited.studyUID = value
        case .seriesUID: edited.seriesUID = value
        }
        edited.indexedAt = Date()
        return edited
    }

    public func validationMessage(for rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.rangeOfCharacter(from: .controlCharacters) == nil else {
            return "\(displayName) cannot contain control characters."
        }
        switch self {
        case .studyDate:
            guard value.isEmpty || (value.count == 8 && value.allSatisfy(\.isNumber)) else {
                return "Study Date must be YYYYMMDD."
            }
        case .studyTime:
            let allowed = CharacterSet(charactersIn: "0123456789.")
            guard value.isEmpty || value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                return "Study Time must be HHMMSS or HHMMSS.frac."
            }
        case .modality:
            guard value.isEmpty || value.count <= 16 else {
                return "Modality must fit DICOM CS length."
            }
        case .studyUID, .seriesUID:
            guard value.isEmpty || Self.isValidUID(value) else {
                return "\(displayName) must be a valid DICOM UID."
            }
        default:
            break
        }
        return nil
    }

    public static func isValidUID(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789.")
        return !value.isEmpty &&
            value.count <= 64 &&
            !value.hasPrefix(".") &&
            !value.hasSuffix(".") &&
            !value.contains("..") &&
            value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public struct PACSAdminTagEditDraft: Equatable, Sendable {
    public var tag: PACSAdminSupportedTag
    public var value: String

    public init(tag: PACSAdminSupportedTag = .studyDescription, value: String = "") {
        self.tag = tag
        self.value = value
    }

    public var validationMessage: String? {
        tag.validationMessage(for: value)
    }

    public func applying(to snapshots: [PACSIndexedSeriesSnapshot]) -> [PACSIndexedSeriesSnapshot] {
        snapshots.map { tag.applying(value, to: $0) }
    }

    public func diffRows(for study: PACSWorklistStudy) -> [PACSAdminDiffRow] {
        study.series.map { snapshot in
            PACSAdminDiffRow(
                scope: snapshot.seriesDescription.isEmpty ? snapshot.seriesUID : snapshot.seriesDescription,
                field: "\(tag.tag) \(tag.displayName)",
                before: tag.value(from: snapshot),
                after: value.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        .filter { $0.before != $0.after }
    }
}

public struct PACSAdminDiffRow: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var scope: String
    public var field: String
    public var before: String
    public var after: String
}

public enum PACSAdminBatchOperationKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case setStudyName
    case setPatientID
    case setAccession
    case setReferrer
    case setBodyPart
    case appendSeriesSuffix

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .setStudyName: return "Study Name"
        case .setPatientID: return "Patient ID"
        case .setAccession: return "Accession"
        case .setReferrer: return "Referrer"
        case .setBodyPart: return "Body Part"
        case .appendSeriesSuffix: return "Series Suffix"
        }
    }
}

public struct PACSAdminBatchOperationDraft: Equatable, Sendable {
    public var kind: PACSAdminBatchOperationKind
    public var value: String

    public init(kind: PACSAdminBatchOperationKind = .setStudyName, value: String = "") {
        self.kind = kind
        self.value = value
    }

    public var validationMessage: String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Batch value is required." }
        if trimmed.rangeOfCharacter(from: .controlCharacters) != nil {
            return "Batch value cannot contain control characters."
        }
        return nil
    }

    public func applying(to studies: [PACSWorklistStudy]) -> [PACSIndexedSeriesSnapshot] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return studies.flatMap { study in
            study.series.map { snapshot in
                var edited = snapshot
                switch kind {
                case .setStudyName:
                    edited.studyDescription = trimmed
                case .setPatientID:
                    edited.patientID = trimmed
                case .setAccession:
                    edited.accessionNumber = trimmed
                case .setReferrer:
                    edited.referringPhysicianName = trimmed
                case .setBodyPart:
                    edited.bodyPartExamined = trimmed.uppercased()
                case .appendSeriesSuffix:
                    if !edited.seriesDescription.hasSuffix(trimmed) {
                        edited.seriesDescription += " \(trimmed)"
                    }
                }
                edited.indexedAt = Date()
                return edited
            }
        }
    }
}

public enum PACSAdminDeidentificationPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case researchExport
    case teachingFile
    case externalConsult

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .researchExport: return "Research"
        case .teachingFile: return "Teaching"
        case .externalConsult: return "Consult"
        }
    }
}

public struct PACSAdminDeidentificationOptions: Equatable, Sendable {
    public var preset: PACSAdminDeidentificationPreset
    public var remapUIDs: Bool
    public var keepStudyDate: Bool
    public var patientIDPrefix: String

    public init(preset: PACSAdminDeidentificationPreset = .researchExport,
                remapUIDs: Bool = true,
                keepStudyDate: Bool = false,
                patientIDPrefix: String = "TRACER") {
        self.preset = preset
        self.remapUIDs = remapUIDs
        self.keepStudyDate = keepStudyDate
        self.patientIDPrefix = patientIDPrefix
    }
}

public struct PACSAdminDeidentificationPlan: Equatable, Sendable {
    public var snapshots: [PACSIndexedSeriesSnapshot]
    public var uidMappings: [PACSAdminUIDMapping]
    public var warnings: [String]
    public var manifest: String

    public static func make(studies: [PACSWorklistStudy],
                            options: PACSAdminDeidentificationOptions = PACSAdminDeidentificationOptions()) -> PACSAdminDeidentificationPlan {
        var mappings: [PACSAdminUIDMapping] = []
        var mappedStudyUIDs: [String: String] = [:]
        var mappedSeriesUIDs: [String: String] = [:]
        var output: [PACSIndexedSeriesSnapshot] = []
        var warnings = Set<String>()

        for (studyIndex, study) in studies.enumerated() {
            let anonID = "\(options.patientIDPrefix)\(String(format: "%06d", studyIndex + 1))"
            let anonName = "Anonymous^\(String(format: "%06d", studyIndex + 1))"
            for snapshot in study.series {
                var edited = snapshot
                edited.patientName = anonName
                edited.patientID = anonID
                edited.accessionNumber = ""
                edited.referringPhysicianName = ""
                edited.studyDescription = deidentifiedStudyDescription(study.studyDescription, preset: options.preset)
                if !options.keepStudyDate {
                    edited.studyDate = ""
                    edited.studyTime = ""
                }
                if options.remapUIDs {
                    if !snapshot.studyUID.isEmpty {
                        let mapped = mappedStudyUIDs[snapshot.studyUID] ?? DICOMExportWriter.makeUID()
                        mappedStudyUIDs[snapshot.studyUID] = mapped
                        edited.studyUID = mapped
                    }
                    if !snapshot.seriesUID.isEmpty {
                        let mapped = mappedSeriesUIDs[snapshot.seriesUID] ?? DICOMExportWriter.makeUID()
                        mappedSeriesUIDs[snapshot.seriesUID] = mapped
                        edited.seriesUID = mapped
                    }
                }
                edited.indexedAt = Date()
                output.append(edited)
            }

            for warning in burnedInWarnings(for: study) {
                warnings.insert(warning)
            }
        }

        mappings += mappedStudyUIDs.map { PACSAdminUIDMapping(kind: "Study", original: $0.key, replacement: $0.value) }
        mappings += mappedSeriesUIDs.map { PACSAdminUIDMapping(kind: "Series", original: $0.key, replacement: $0.value) }
        mappings.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.original < rhs.original
        }

        return PACSAdminDeidentificationPlan(
            snapshots: output,
            uidMappings: mappings,
            warnings: warnings.sorted(),
            manifest: manifestText(snapshotCount: output.count, mappingCount: mappings.count, options: options)
        )
    }

    private static func deidentifiedStudyDescription(_ value: String,
                                                     preset: PACSAdminDeidentificationPreset) -> String {
        let fallback: String
        switch preset {
        case .researchExport: fallback = "Research Export"
        case .teachingFile: fallback = "Teaching File"
        case .externalConsult: fallback = "External Consult"
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : "\(fallback) - \(trimmed)"
    }

    private static func burnedInWarnings(for study: PACSWorklistStudy) -> [String] {
        let text = ([study.studyDescription] + study.series.map(\.seriesDescription))
            .joined(separator: " ")
            .lowercased()
        let terms = ["secondary capture", "screen", "screenshot", "photo", "burned", "annotation"]
        guard terms.contains(where: { text.contains($0) }) else { return [] }
        return ["\(study.studyDescription.isEmpty ? study.id : study.studyDescription): review for burned-in PHI."]
    }

    private static func manifestText(snapshotCount: Int,
                                     mappingCount: Int,
                                     options: PACSAdminDeidentificationOptions) -> String {
        [
            "Tracer de-identification manifest",
            "Preset: \(options.preset.displayName)",
            "Series: \(snapshotCount)",
            "UID mappings: \(mappingCount)",
            "Dates retained: \(options.keepStudyDate ? "yes" : "no")"
        ].joined(separator: "\n")
    }
}

public struct PACSAdminUIDMapping: Identifiable, Equatable, Sendable {
    public var id: String { "\(kind):\(original)" }
    public var kind: String
    public var original: String
    public var replacement: String
}

public struct PACSAdminUIDPlan: Equatable, Sendable {
    public var regenerateStudyUID: Bool
    public var regenerateSeriesUIDs: Bool

    public init(regenerateStudyUID: Bool = true, regenerateSeriesUIDs: Bool = true) {
        self.regenerateStudyUID = regenerateStudyUID
        self.regenerateSeriesUIDs = regenerateSeriesUIDs
    }

    public func applying(to study: PACSWorklistStudy) -> (snapshots: [PACSIndexedSeriesSnapshot], mappings: [PACSAdminUIDMapping]) {
        let newStudyUID = regenerateStudyUID ? DICOMExportWriter.makeUID() : study.studyUID
        var mappings: [PACSAdminUIDMapping] = []
        if regenerateStudyUID, !study.studyUID.isEmpty {
            mappings.append(PACSAdminUIDMapping(kind: "Study", original: study.studyUID, replacement: newStudyUID))
        }

        let snapshots = study.series.map { snapshot in
            var edited = snapshot
            if regenerateStudyUID {
                edited.studyUID = newStudyUID
            }
            if regenerateSeriesUIDs {
                let newSeriesUID = DICOMExportWriter.makeUID()
                if !snapshot.seriesUID.isEmpty {
                    mappings.append(PACSAdminUIDMapping(kind: "Series", original: snapshot.seriesUID, replacement: newSeriesUID))
                }
                edited.seriesUID = newSeriesUID
            }
            edited.indexedAt = Date()
            return edited
        }
        return (snapshots, mappings)
    }
}

public enum PACSAdminTopologyOperation: String, CaseIterable, Identifiable, Codable, Sendable {
    case splitSeriesToStudies
    case mergeSameAccessionIntoSelected

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .splitSeriesToStudies: return "Split Series"
        case .mergeSameAccessionIntoSelected: return "Merge Accession"
        }
    }
}

public enum PACSAdminTopologyPlanner {
    public static func splitSeriesToStudies(_ study: PACSWorklistStudy) -> [PACSIndexedSeriesSnapshot] {
        study.series.map { snapshot in
            var edited = snapshot
            edited.studyUID = DICOMExportWriter.makeUID()
            edited.studyDescription = [study.studyDescription, snapshot.seriesDescription]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " - ")
            edited.indexedAt = Date()
            return edited
        }
    }

    public static func mergeSameAccession(into target: PACSWorklistStudy,
                                          from studies: [PACSWorklistStudy]) -> [PACSIndexedSeriesSnapshot] {
        let accession = target.accessionNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accession.isEmpty else { return [] }
        return studies
            .filter { $0.accessionNumber.caseInsensitiveCompare(accession) == .orderedSame }
            .flatMap { study in
                study.series.map { snapshot in
                    var edited = snapshot
                    edited.studyUID = target.studyUID
                    edited.studyDescription = target.studyDescription
                    edited.patientName = target.patientName
                    edited.patientID = target.patientID
                    edited.accessionNumber = target.accessionNumber
                    edited.indexedAt = Date()
                    return edited
                }
            }
    }
}

public enum PACSAdminQuarantineSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct PACSAdminQuarantineFinding: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var severity: PACSAdminQuarantineSeverity
    public var studyID: String
    public var title: String
    public var detail: String

    public static func evaluate(studies: [PACSWorklistStudy]) -> [PACSAdminQuarantineFinding] {
        var findings: [PACSAdminQuarantineFinding] = []
        var seenStudyUIDs: [String: String] = [:]
        var seenSeriesUIDs: [String: String] = [:]

        for study in studies {
            if study.patientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                findings.append(.init(severity: .error, studyID: study.id, title: "Missing Patient ID", detail: study.studyDescription))
            }
            if study.studyDate.count != 8 || !study.studyDate.allSatisfy(\.isNumber) {
                findings.append(.init(severity: .warning, studyID: study.id, title: "Invalid Study Date", detail: study.studyDate.isEmpty ? "blank" : study.studyDate))
            }
            if !study.studyUID.isEmpty, let prior = seenStudyUIDs[study.studyUID], prior != study.id {
                findings.append(.init(severity: .error, studyID: study.id, title: "Duplicate Study UID", detail: study.studyUID))
            } else if !study.studyUID.isEmpty {
                seenStudyUIDs[study.studyUID] = study.id
            }
            for series in study.series {
                if !series.seriesUID.isEmpty, let prior = seenSeriesUIDs[series.seriesUID], prior != series.id {
                    findings.append(.init(severity: .error, studyID: study.id, title: "Duplicate Series UID", detail: series.seriesUID))
                } else if !series.seriesUID.isEmpty {
                    seenSeriesUIDs[series.seriesUID] = series.id
                }
                if series.filePaths.isEmpty {
                    findings.append(.init(severity: .warning, studyID: study.id, title: "No Source Files", detail: series.seriesDescription))
                }
            }
        }
        return findings
    }
}

public enum PACSAdminWorkflowAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case autoIndex
    case autoContour
    case qaReview
    case exportSEG
    case routeToPACS

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoIndex: return "Index"
        case .autoContour: return "Auto-contour"
        case .qaReview: return "QA"
        case .exportSEG: return "Export SEG"
        case .routeToPACS: return "Route"
        }
    }
}

public struct PACSAdminWorkflowRule: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var modalityContains: String
    public var studyDescriptionContains: String
    public var actions: [PACSAdminWorkflowAction]
    public var isEnabled: Bool

    public init(id: UUID = UUID(),
                name: String,
                modalityContains: String = "",
                studyDescriptionContains: String = "",
                actions: [PACSAdminWorkflowAction],
                isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.modalityContains = modalityContains
        self.studyDescriptionContains = studyDescriptionContains
        self.actions = actions
        self.isEnabled = isEnabled
    }

    public func matches(_ study: PACSWorklistStudy) -> Bool {
        guard isEnabled else { return false }
        let modalityNeedle = modalityContains.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let descriptionNeedle = studyDescriptionContains.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !modalityNeedle.isEmpty && !study.modalitySummary.lowercased().contains(modalityNeedle) {
            return false
        }
        if !descriptionNeedle.isEmpty && !study.studyDescription.lowercased().contains(descriptionNeedle) {
            return false
        }
        return true
    }

    public static let defaults: [PACSAdminWorkflowRule] = [
        PACSAdminWorkflowRule(name: "PET/CT Contour Intake",
                              modalityContains: "PET",
                              actions: [.autoIndex, .autoContour, .qaReview, .exportSEG]),
        PACSAdminWorkflowRule(name: "Radiotherapy Route",
                              studyDescriptionContains: "RT",
                              actions: [.autoIndex, .qaReview, .routeToPACS]),
        PACSAdminWorkflowRule(name: "Research Export Prep",
                              actions: [.autoIndex, .qaReview])
    ]
}

public struct PACSAdminHealthSnapshot: Equatable, Sendable {
    public var studyCount: Int
    public var seriesCount: Int
    public var instanceCount: Int
    public var vnaConnectionCount: Int
    public var routeQueueCount: Int
    public var quarantineIssueCount: Int

    public static func make(studies: [PACSWorklistStudy],
                            vnaConnectionCount: Int,
                            routeQueueCount: Int,
                            quarantineIssueCount: Int) -> PACSAdminHealthSnapshot {
        PACSAdminHealthSnapshot(
            studyCount: studies.count,
            seriesCount: studies.reduce(0) { $0 + $1.seriesCount },
            instanceCount: studies.reduce(0) { $0 + $1.instanceCount },
            vnaConnectionCount: vnaConnectionCount,
            routeQueueCount: routeQueueCount,
            quarantineIssueCount: quarantineIssueCount
        )
    }
}

public enum PACSAdminAuditEventKind: String, Codable, Sendable {
    case adminMode
    case metadataEdit
    case tagEdit
    case batchEdit
    case deidentify
    case uidRemap
    case topology
    case quarantine
    case route
    case createDICOM
    case retire
}

public struct PACSAdminAuditEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var kind: PACSAdminAuditEventKind
    public var studyID: String
    public var summary: String

    public init(id: UUID = UUID(),
                timestamp: Date = Date(),
                kind: PACSAdminAuditEventKind,
                studyID: String = "",
                summary: String) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.studyID = studyID
        self.summary = summary
    }
}

public struct PACSAdminAuditStore {
    public static let defaultKey = "Tracer.PACSAdmin.Audit.v1"
    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    public init(defaults: UserDefaults = .standard,
                key: String = PACSAdminAuditStore.defaultKey,
                limit: Int = 200) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
    }

    public func load() -> [PACSAdminAuditEvent] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PACSAdminAuditEvent].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.timestamp > $1.timestamp }
    }

    @discardableResult
    public func append(_ event: PACSAdminAuditEvent) -> [PACSAdminAuditEvent] {
        let events = ([event] + load()).prefix(limit)
        let output = Array(events)
        if let data = try? JSONEncoder().encode(output) {
            defaults.set(data, forKey: key)
        }
        return output
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

public enum PACSAdminRouteStatus: String, Codable, Sendable {
    case queued
    case sending
    case sent
    case failed
}

public struct PACSAdminRouteQueueItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var endpointName: String
    public var endpointURL: String
    public var studyID: String
    public var studyDescription: String
    public var instanceCount: Int
    public var status: PACSAdminRouteStatus
    public var message: String

    public init(id: UUID = UUID(),
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                endpointName: String,
                endpointURL: String,
                studyID: String,
                studyDescription: String,
                instanceCount: Int,
                status: PACSAdminRouteStatus = .queued,
                message: String = "") {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.endpointName = endpointName
        self.endpointURL = endpointURL
        self.studyID = studyID
        self.studyDescription = studyDescription
        self.instanceCount = instanceCount
        self.status = status
        self.message = message
    }
}

public struct PACSAdminRoutingQueueStore {
    public static let defaultKey = "Tracer.PACSAdmin.RouteQueue.v1"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard,
                key: String = PACSAdminRoutingQueueStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [PACSAdminRouteQueueItem] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PACSAdminRouteQueueItem].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func upsert(_ item: PACSAdminRouteQueueItem) -> [PACSAdminRouteQueueItem] {
        var items = load()
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
        save(items)
        return load()
    }

    public func clearCompleted() -> [PACSAdminRouteQueueItem] {
        let remaining = load().filter { $0.status != .sent }
        save(remaining)
        return load()
    }

    private func save(_ items: [PACSAdminRouteQueueItem]) {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}
