import Foundation

public enum WorklistStudyStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case unread
    case inProgress
    case complete
    case flagged

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unread: return "Unread"
        case .inProgress: return "In Progress"
        case .complete: return "Complete"
        case .flagged: return "Flagged"
        }
    }
}

public enum WorklistStatusFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case inProgress
    case complete
    case flagged

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .unread: return WorklistStudyStatus.unread.displayName
        case .inProgress: return WorklistStudyStatus.inProgress.displayName
        case .complete: return WorklistStudyStatus.complete.displayName
        case .flagged: return WorklistStudyStatus.flagged.displayName
        }
    }

    public func includes(_ status: WorklistStudyStatus) -> Bool {
        switch self {
        case .all: return true
        case .unread: return status == .unread
        case .inProgress: return status == .inProgress
        case .complete: return status == .complete
        case .flagged: return status == .flagged
        }
    }
}

public enum WorklistDateFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case last7Days
    case last30Days

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All Dates"
        case .today: return "Today"
        case .last7Days: return "7 Days"
        case .last30Days: return "30 Days"
        }
    }

    public func includes(dicomDate: String, now: Date = Date()) -> Bool {
        guard self != .all else { return true }
        guard let date = Self.dicomDateFormatter.date(from: dicomDate) else { return false }
        let calendar = Calendar.current
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .last7Days:
            guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return true }
            return date >= calendar.startOfDay(for: start)
        case .last30Days:
            guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return true }
            return date >= calendar.startOfDay(for: start)
        }
    }

    private static let dicomDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

public struct PACSWorklistStudy: Identifiable, Hashable, Sendable {
    public let id: String
    public let patientID: String
    public let patientName: String
    public let accessionNumber: String
    public let studyUID: String
    public let studyDescription: String
    public let studyDate: String
    public let studyTime: String
    public let referringPhysicianName: String
    public let sourcePath: String
    public let series: [PACSIndexedSeriesSnapshot]
    public let status: WorklistStudyStatus
    public let indexedAt: Date

    public var modalities: [String] {
        Array(Set(series.map { Modality.normalize($0.modality).displayName })).sorted()
    }

    public var modalitySummary: String {
        modalities.joined(separator: "/")
    }

    public var seriesCount: Int {
        series.count
    }

    public var instanceCount: Int {
        series.reduce(0) { $0 + $1.instanceCount }
    }

    public var searchableText: String {
        ([
            patientID,
            patientName,
            accessionNumber,
            studyDescription,
            studyDate,
            studyTime,
            referringPhysicianName,
            modalitySummary,
            sourcePath,
        ] + series.map(\.seriesDescription))
            .joined(separator: " ")
            .lowercased()
    }

    public func matches(searchText: String,
                        statusFilter: WorklistStatusFilter,
                        modalityFilter: String,
                        dateFilter: WorklistDateFilter) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty && !searchableText.contains(query) {
            return false
        }
        if !statusFilter.includes(status) {
            return false
        }
        if modalityFilter != "All" && !modalities.contains(modalityFilter) {
            return false
        }
        return dateFilter.includes(dicomDate: studyDate)
    }

    public static func grouped(from series: [PACSIndexedSeriesSnapshot],
                               statuses: [String: WorklistStudyStatus] = [:]) -> [PACSWorklistStudy] {
        let grouped = Dictionary(grouping: series) { snapshot in
            studyKey(for: snapshot)
        }
        return grouped.compactMap { key, values in
            guard let first = values.sorted(by: seriesSort).first else { return nil }
            let sortedSeries = values.sorted(by: seriesSort)
            return PACSWorklistStudy(
                id: key,
                patientID: first.patientID,
                patientName: first.patientName,
                accessionNumber: first.accessionNumber,
                studyUID: first.studyUID,
                studyDescription: first.studyDescription,
                studyDate: first.studyDate,
                studyTime: first.studyTime,
                referringPhysicianName: first.referringPhysicianName,
                sourcePath: first.sourcePath,
                series: sortedSeries,
                status: statuses[key] ?? .unread,
                indexedAt: sortedSeries.map(\.indexedAt).max() ?? first.indexedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return statusSortValue(lhs.status) < statusSortValue(rhs.status)
            }
            if lhs.studyDate != rhs.studyDate { return lhs.studyDate > rhs.studyDate }
            if lhs.studyTime != rhs.studyTime { return lhs.studyTime > rhs.studyTime }
            return lhs.patientName < rhs.patientName
        }
    }

    private static func studyKey(for snapshot: PACSIndexedSeriesSnapshot) -> String {
        if !snapshot.studyUID.isEmpty && snapshot.studyUID != "NIFTI_STUDY" {
            return "study:\(snapshot.studyUID)"
        }
        if !snapshot.accessionNumber.isEmpty {
            return "accession:\(snapshot.accessionNumber)"
        }
        return "synthetic:\(snapshot.patientID):\(snapshot.studyDate):\(snapshot.studyDescription):\(snapshot.sourcePath)"
    }

    private static func seriesSort(_ lhs: PACSIndexedSeriesSnapshot,
                                   _ rhs: PACSIndexedSeriesSnapshot) -> Bool {
        let lhsRank = modalitySortRank(lhs.modality)
        let rhsRank = modalitySortRank(rhs.modality)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.seriesDescription < rhs.seriesDescription
    }

    private static func modalitySortRank(_ modality: String) -> Int {
        switch Modality.normalize(modality) {
        case .CT: return 0
        case .PT: return 1
        case .MR: return 2
        case .SEG: return 3
        default: return 10
        }
    }

    private static func statusSortValue(_ status: WorklistStudyStatus) -> Int {
        switch status {
        case .flagged: return 0
        case .unread: return 1
        case .inProgress: return 2
        case .complete: return 3
        }
    }
}
