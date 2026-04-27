import Foundation

/// Render a `RadiologyReport` to text in one of several formats.
///
/// The formatter is **pure** — no side effects, takes a value, returns a
/// value. Tests exercise every branch without touching the file system.
///
/// Format choices:
///   • `.plainText` — what the user copy/pastes into their email or PACS
///     freetext field. Section headers in CAPS, blank line between sections.
///   • `.markdown` — what the report editor renders to disk for git-style
///     diffing across revisions. Section headers as `##`. Provenance
///     badges are inlined as comments so a downstream Markdown viewer
///     doesn't need to understand them.
///   • `.signedLetter` — adds the sign-off block ("Reported by ... on ...")
///     and a footer with the report id. Used by the Print → PDF action.
///   • `.hl7Friendly` — flat single-line-per-section text suitable for
///     stuffing into an HL7 v2 OBX-5 segment. Strips Markdown / line
///     breaks, escapes pipe chars (HL7 field separator).
///
/// HL7 OBX framing is *not* the formatter's job — caller wraps the output
/// in MSH/PID/OBR/OBX. Same for FHIR R4 DiagnosticReport and DICOM SR;
/// those land in C3 where the export pipeline lives.
public enum ReportFormatter {

    public enum Style: String, Codable, Equatable, Sendable, CaseIterable {
        case plainText
        case markdown
        case signedLetter
        case hl7Friendly
    }

    /// Render the report. `now` is injected so unit tests get reproducible
    /// timestamps without freezing system time.
    public static func format(_ report: RadiologyReport,
                              style: Style,
                              now: Date = Date(),
                              calendar: Calendar = .current) -> String {
        switch style {
        case .plainText:    return renderPlainText(report)
        case .markdown:     return renderMarkdown(report)
        case .signedLetter: return renderSignedLetter(report, now: now, calendar: calendar)
        case .hl7Friendly:  return renderHL7(report)
        }
    }

    // MARK: - Plain text

    private static func renderPlainText(_ report: RadiologyReport) -> String {
        var out = ""
        appendHeader(&out, report.metadata)
        for section in report.sections where !section.sentences.isEmpty {
            out.append(section.title.uppercased())
            out.append("\n")
            out.append(joinedSentences(section.sentences))
            out.append("\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Markdown

    private static func renderMarkdown(_ report: RadiologyReport) -> String {
        var out = ""
        let m = report.metadata
        if !m.patientName.isEmpty || !m.patientID.isEmpty {
            out.append("# Radiology Report\n\n")
            if !m.patientName.isEmpty {
                out.append("**Patient:** \(m.patientName)")
                if !m.patientID.isEmpty { out.append(" · \(m.patientID)") }
                out.append("\n")
            }
            if !m.modality.isEmpty || !m.studyDescription.isEmpty {
                let mod = [m.modality, m.studyDescription]
                    .filter { !$0.isEmpty }
                    .joined(separator: " — ")
                out.append("**Study:** \(mod)\n")
            }
            if let d = m.studyDate {
                out.append("**Study Date:** \(formatDate(d))\n")
            }
            out.append("\n")
        }
        for section in report.sections where !section.sentences.isEmpty {
            out.append("## \(section.title)\n\n")
            for sentence in section.sentences {
                out.append("- \(sentence.text)")
                if sentence.provenance != .dictated && sentence.provenance != .typed {
                    out.append(" <!-- provenance: \(sentence.provenance.rawValue) -->")
                }
                out.append("\n")
            }
            out.append("\n")
        }
        if let signOff = report.signOff {
            out.append("---\n\n")
            out.append("_Signed by \(signOff.clinician) on \(formatDate(signOff.timestamp))._\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Signed letter (PDF-friendly)

    private static func renderSignedLetter(_ report: RadiologyReport,
                                           now: Date,
                                           calendar: Calendar) -> String {
        var out = renderPlainText(report)
        out.append("\n\n")
        if let signOff = report.signOff {
            out.append("Reported by: \(signOff.clinician)\n")
            out.append("Sign-off: \(formatDateTime(signOff.timestamp))\n")
        } else {
            out.append("Status: DRAFT — not yet signed\n")
            out.append("Generated: \(formatDateTime(now))\n")
        }
        out.append("Report ID: \(report.id.uuidString)\n")
        return out
    }

    // MARK: - HL7-friendly flat string

    private static func renderHL7(_ report: RadiologyReport) -> String {
        var pieces: [String] = []
        for section in report.sections where !section.sentences.isEmpty {
            let body = joinedSentences(section.sentences)
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\\", with: "\\E\\")
                .replacingOccurrences(of: "|", with: "\\F\\")
                .replacingOccurrences(of: "^", with: "\\S\\")
                .replacingOccurrences(of: "&", with: "\\T\\")
                .replacingOccurrences(of: "~", with: "\\R\\")
            pieces.append("\(section.title.uppercased()): \(body)")
        }
        return pieces.joined(separator: " // ")
    }

    // MARK: - Helpers

    private static func appendHeader(_ out: inout String, _ m: ReportMetadata) {
        var line: [String] = []
        if !m.patientName.isEmpty { line.append("Patient: \(m.patientName)") }
        if !m.patientID.isEmpty   { line.append("ID: \(m.patientID)") }
        if let d = m.studyDate    { line.append("Study Date: \(formatDate(d))") }
        if !m.modality.isEmpty    { line.append("Modality: \(m.modality)") }
        if !m.studyUID.isEmpty    { line.append("Study UID: \(m.studyUID)") }
        if !m.accessionNumber.isEmpty { line.append("Accession: \(m.accessionNumber)") }
        if !line.isEmpty {
            out.append(line.joined(separator: " · "))
            out.append("\n\n")
        }
    }

    private static func joinedSentences(_ sentences: [ReportSentence]) -> String {
        sentences.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                 .filter { !$0.isEmpty }
                 .joined(separator: " ")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    public static func formatDateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }
}
