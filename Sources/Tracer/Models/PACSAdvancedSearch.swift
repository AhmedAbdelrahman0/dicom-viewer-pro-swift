import Foundation

public struct PACSAdvancedSearchQuery: Equatable, Sendable {
    public let rawText: String
    public let clauses: [Clause]

    public init(rawText: String, clauses: [Clause]) {
        self.rawText = rawText
        self.clauses = clauses
    }

    public var isEmpty: Bool {
        clauses.isEmpty
    }

    public var usesFieldSyntax: Bool {
        clauses.contains { clause in
            switch clause {
            case .field, .range:
                return true
            case .text:
                return false
            case .not(let wrapped):
                switch wrapped {
                case .field, .range: return true
                case .text, .not: return false
                }
            }
        }
    }

    public static func parse(_ rawText: String) -> PACSAdvancedSearchQuery {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return PACSAdvancedSearchQuery(rawText: rawText, clauses: [])
        }

        let tokens = coalescedRangeTokens(from: normalized)
        var clauses: [Clause] = []
        var negateNext = false
        for token in tokens {
            let upper = token.uppercased()
            if upper == "AND" || upper == "&&" {
                continue
            }
            if upper == "NOT" || token == "-" {
                negateNext = true
                continue
            }
            guard let clause = parseClause(token) else { continue }
            clauses.append(negateNext ? .not(clause) : clause)
            negateNext = false
        }
        return PACSAdvancedSearchQuery(rawText: rawText, clauses: clauses)
    }

    public func matches(_ snapshot: PACSIndexedSeriesSnapshot) -> Bool {
        guard !clauses.isEmpty else { return true }
        return clauses.allSatisfy { $0.matches(snapshot) }
    }

    public func matches(_ study: PACSWorklistStudy) -> Bool {
        guard !clauses.isEmpty else { return true }
        return clauses.allSatisfy { $0.matches(study) }
    }

    public indirect enum Clause: Equatable, Sendable {
        case text(String)
        case field(PACSAdvancedSearchField, String)
        case range(PACSAdvancedSearchField, lower: String, upper: String)
        case not(Clause)

        public func matches(_ snapshot: PACSIndexedSeriesSnapshot) -> Bool {
            switch self {
            case .text(let term):
                return normalized(snapshot.searchableText).contains(normalized(term))
            case .field(let field, let value):
                return field.values(in: snapshot).contains { PACSAdvancedSearchQuery.matches(value: $0, pattern: value) }
            case .range(let field, let lower, let upper):
                return field.values(in: snapshot).contains { PACSAdvancedSearchQuery.value($0, isInRangeLower: lower, upper: upper) }
            case .not(let clause):
                return !clause.matches(snapshot)
            }
        }

        public func matches(_ study: PACSWorklistStudy) -> Bool {
            switch self {
            case .text(let term):
                return normalized(study.searchableText).contains(normalized(term))
            case .field(let field, let value):
                return field.values(in: study).contains { PACSAdvancedSearchQuery.matches(value: $0, pattern: value) }
            case .range(let field, let lower, let upper):
                return field.values(in: study).contains { PACSAdvancedSearchQuery.value($0, isInRangeLower: lower, upper: upper) }
            case .not(let clause):
                return !clause.matches(study)
            }
        }

        private func normalized(_ value: String) -> String {
            PACSAdvancedSearchQuery.normalized(value)
        }
    }

    private static func parseClause(_ token: String) -> Clause? {
        guard let colon = token.firstIndex(of: ":") else {
            let text = strippedQuotes(token)
            return text.isEmpty ? nil : .text(text)
        }
        let fieldName = String(token[..<colon])
        guard let field = PACSAdvancedSearchField(alias: fieldName) else {
            return .text(strippedQuotes(token))
        }
        let value = String(token[token.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("[") && value.hasSuffix("]") {
            let inner = String(value.dropFirst().dropLast())
            if let range = parseRange(inner) {
                return .range(field, lower: range.lower, upper: range.upper)
            }
        }
        return .field(field, strippedQuotes(value))
    }

    private static func parseRange(_ value: String) -> (lower: String, upper: String)? {
        let uppercased = value.uppercased()
        guard let range = uppercased.range(of: " TO ") else { return nil }
        let lower = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (strippedQuotes(lower), strippedQuotes(upper))
    }

    private static func coalescedRangeTokens(from raw: String) -> [String] {
        let parts = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        var tokens: [String] = []
        var index = 0
        while index < parts.count {
            var token = parts[index]
            if token.contains(":[") && !token.contains("]") {
                index += 1
                while index < parts.count {
                    token += " " + parts[index]
                    if parts[index].contains("]") { break }
                    index += 1
                }
            }
            tokens.append(token)
            index += 1
        }
        return tokens
    }

    private static func matches(value: String, pattern: String) -> Bool {
        let candidate = normalized(value)
        let needle = normalized(strippedQuotes(pattern))
        guard !needle.isEmpty else { return true }
        if needle == "*" { return true }
        if needle.hasPrefix("*") && needle.hasSuffix("*") {
            return candidate.contains(String(needle.dropFirst().dropLast()))
        }
        if needle.hasPrefix("*") {
            return candidate.hasSuffix(String(needle.dropFirst()))
        }
        if needle.hasSuffix("*") {
            return candidate.hasPrefix(String(needle.dropLast()))
        }
        return candidate == needle || candidate.contains(needle)
    }

    private static func value(_ value: String, isInRangeLower lower: String, upper: String) -> Bool {
        let candidate = normalized(value)
        guard !candidate.isEmpty else { return false }
        let low = normalized(lower)
        let high = normalized(upper)
        if low != "*" && candidate.localizedStandardCompare(low) == .orderedAscending {
            return false
        }
        if high != "*" && candidate.localizedStandardCompare(high) == .orderedDescending {
            return false
        }
        return true
    }

    private static func strippedQuotes(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2,
           ((text.hasPrefix("\"") && text.hasSuffix("\"")) ||
            (text.hasPrefix("'") && text.hasSuffix("'"))) {
            text.removeFirst()
            text.removeLast()
        }
        return text
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum PACSAdvancedSearchField: String, CaseIterable, Identifiable, Sendable {
    case any
    case patientID
    case patientName
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
    case sourcePath
    case kind

    public var id: String { rawValue }

    public init?(alias: String) {
        let key = alias
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch key {
        case "any", "all", "text":
            self = .any
        case "patientid", "mrn", "00100020":
            self = .patientID
        case "patientname", "patient", "name", "00100010":
            self = .patientName
        case "accession", "accessionnumber", "00080050":
            self = .accessionNumber
        case "studydescription", "study", "description", "00081030":
            self = .studyDescription
        case "studydate", "date", "00080020":
            self = .studyDate
        case "studytime", "time", "00080030":
            self = .studyTime
        case "referringphysician", "referringphysicianname", "00080090":
            self = .referringPhysicianName
        case "bodypart", "bodypartexamined", "00180015":
            self = .bodyPartExamined
        case "modality", "00080060", "00080061":
            self = .modality
        case "series", "seriesdescription", "0008103e":
            self = .seriesDescription
        case "studyuid", "studyinstanceuid", "0020000d":
            self = .studyUID
        case "seriesuid", "seriesinstanceuid", "0020000e":
            self = .seriesUID
        case "path", "source", "sourcepath", "uri":
            self = .sourcePath
        case "kind", "format":
            self = .kind
        default:
            return nil
        }
    }

    public func values(in snapshot: PACSIndexedSeriesSnapshot) -> [String] {
        switch self {
        case .any:
            return [snapshot.searchableText]
        case .patientID:
            return [snapshot.patientID]
        case .patientName:
            return [snapshot.patientName]
        case .accessionNumber:
            return [snapshot.accessionNumber]
        case .studyDescription:
            return [snapshot.studyDescription]
        case .studyDate:
            return [snapshot.studyDate]
        case .studyTime:
            return [snapshot.studyTime]
        case .referringPhysicianName:
            return [snapshot.referringPhysicianName]
        case .bodyPartExamined:
            return [snapshot.bodyPartExamined]
        case .modality:
            return [snapshot.modality, Modality.normalize(snapshot.modality).displayName]
        case .seriesDescription:
            return [snapshot.seriesDescription]
        case .studyUID:
            return [snapshot.studyUID]
        case .seriesUID:
            return [snapshot.seriesUID]
        case .sourcePath:
            return [snapshot.sourcePath] + snapshot.filePaths
        case .kind:
            return [snapshot.kind.rawValue, snapshot.kind.displayName]
        }
    }

    public func values(in study: PACSWorklistStudy) -> [String] {
        switch self {
        case .any:
            return [study.searchableText]
        case .patientID:
            return [study.patientID]
        case .patientName:
            return [study.patientName]
        case .accessionNumber:
            return [study.accessionNumber]
        case .studyDescription:
            return [study.studyDescription]
        case .studyDate:
            return [study.studyDate]
        case .studyTime:
            return [study.studyTime]
        case .referringPhysicianName:
            return [study.referringPhysicianName]
        case .bodyPartExamined:
            return study.series.map(\.bodyPartExamined)
        case .modality:
            return study.series.flatMap { [$0.modality, Modality.normalize($0.modality).displayName] } + [study.modalitySummary]
        case .seriesDescription:
            return study.series.map(\.seriesDescription)
        case .studyUID:
            return [study.studyUID]
        case .seriesUID:
            return study.series.map(\.seriesUID)
        case .sourcePath:
            return [study.sourcePath] + study.series.flatMap { [$0.sourcePath] + $0.filePaths }
        case .kind:
            return Array(Set(study.series.flatMap { [$0.kind.rawValue, $0.kind.displayName] }))
        }
    }
}
