import Foundation

public enum PACSMetadataExportGranularity: String, CaseIterable, Identifiable, Codable, Sendable {
    case study
    case series

    public var id: String { rawValue }
}

public enum PACSMetadataExportColumn: String, CaseIterable, Identifiable, Codable, Sendable {
    case patientID
    case patientName
    case accessionNumber
    case studyDate
    case studyTime
    case modality
    case studyDescription
    case seriesDescription
    case studyUID
    case seriesUID
    case bodyPartExamined
    case referringPhysicianName
    case instanceCount
    case sourcePath

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .patientID: return "PatientID"
        case .patientName: return "PatientName"
        case .accessionNumber: return "AccessionNumber"
        case .studyDate: return "StudyDate"
        case .studyTime: return "StudyTime"
        case .modality: return "Modality"
        case .studyDescription: return "StudyDescription"
        case .seriesDescription: return "SeriesDescription"
        case .studyUID: return "StudyInstanceUID"
        case .seriesUID: return "SeriesInstanceUID"
        case .bodyPartExamined: return "BodyPartExamined"
        case .referringPhysicianName: return "ReferringPhysicianName"
        case .instanceCount: return "InstanceCount"
        case .sourcePath: return "SourcePath"
        }
    }

    public var dicomTag: String {
        switch self {
        case .patientID: return "(0010,0020)"
        case .patientName: return "(0010,0010)"
        case .accessionNumber: return "(0008,0050)"
        case .studyDate: return "(0008,0020)"
        case .studyTime: return "(0008,0030)"
        case .modality: return "(0008,0060)"
        case .studyDescription: return "(0008,1030)"
        case .seriesDescription: return "(0008,103E)"
        case .studyUID: return "(0020,000D)"
        case .seriesUID: return "(0020,000E)"
        case .bodyPartExamined: return "(0018,0015)"
        case .referringPhysicianName: return "(0008,0090)"
        case .instanceCount: return ""
        case .sourcePath: return ""
        }
    }

    public static let defaultStudyColumns: [PACSMetadataExportColumn] = [
        .patientID,
        .patientName,
        .accessionNumber,
        .studyDate,
        .modality,
        .studyDescription,
        .studyUID,
        .instanceCount,
        .sourcePath,
    ]

    public static let defaultSeriesColumns: [PACSMetadataExportColumn] = [
        .patientID,
        .patientName,
        .accessionNumber,
        .studyDate,
        .modality,
        .studyDescription,
        .seriesDescription,
        .studyUID,
        .seriesUID,
        .bodyPartExamined,
        .instanceCount,
        .sourcePath,
    ]

    public func value(study: PACSWorklistStudy, series: PACSIndexedSeriesSnapshot?) -> String {
        switch self {
        case .patientID: return study.patientID
        case .patientName: return study.patientName
        case .accessionNumber: return study.accessionNumber
        case .studyDate: return study.studyDate
        case .studyTime: return study.studyTime
        case .modality: return series?.modality ?? study.modalitySummary
        case .studyDescription: return study.studyDescription
        case .seriesDescription: return series?.seriesDescription ?? study.series.map(\.seriesDescription).joined(separator: " | ")
        case .studyUID: return study.studyUID
        case .seriesUID: return series?.seriesUID ?? study.series.map(\.seriesUID).joined(separator: " | ")
        case .bodyPartExamined: return series?.bodyPartExamined ?? study.series.map(\.bodyPartExamined).filter { !$0.isEmpty }.joined(separator: " | ")
        case .referringPhysicianName: return study.referringPhysicianName
        case .instanceCount: return "\(series?.instanceCount ?? study.instanceCount)"
        case .sourcePath: return series?.sourcePath ?? study.sourcePath
        }
    }
}

public enum PACSMetadataExporter {
    public static func csvData(studies: [PACSWorklistStudy],
                               columns: [PACSMetadataExportColumn],
                               granularity: PACSMetadataExportGranularity = .series) -> Data {
        var rows: [[String]] = [columns.map(\.title)]
        for study in studies {
            switch granularity {
            case .study:
                rows.append(columns.map { $0.value(study: study, series: nil) })
            case .series:
                for series in study.series {
                    rows.append(columns.map { $0.value(study: study, series: series) })
                }
            }
        }
        let text = rows.map { row in
            row.map(csvEscaped).joined(separator: ",")
        }
        .joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    public static func csvData(studies: [PACSWorklistStudy],
                               granularity: PACSMetadataExportGranularity = .series) -> Data {
        let columns = granularity == .study
            ? PACSMetadataExportColumn.defaultStudyColumns
            : PACSMetadataExportColumn.defaultSeriesColumns
        return csvData(studies: studies, columns: columns, granularity: granularity)
    }

    private static func csvEscaped(_ value: String) -> String {
        if value.contains("\"") || value.contains(",") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
