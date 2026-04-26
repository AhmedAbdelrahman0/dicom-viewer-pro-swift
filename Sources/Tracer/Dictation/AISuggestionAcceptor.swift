import Foundation

/// Pure helpers for accepting / rejecting AI- or VLM-suggested sentences
/// in a `RadiologyReport`. Lives separately from the mutator so the
/// command interpreter can compose these without giving every call site
/// the full mutator API.
///
/// "Accept" doesn't delete the audit trail — the `acceptedAISuggestion`
/// provenance preserves the AI origin while telling the formatter to
/// treat the sentence as committed (no italic, no gray, no comment in
/// Markdown export). "Reject" outright removes the sentence.
public enum AISuggestionAcceptor {

    /// Returns true if the sentence carries an unaccepted suggestion.
    public static func isPendingSuggestion(_ sentence: ReportSentence) -> Bool {
        sentence.provenance == .aiDrafted || sentence.provenance == .vlmSuggested
    }

    /// Walk all sections back-to-front and find the most recent
    /// pending AI/VLM sentence. Returns nil when there is none.
    public static func findLastPending(in report: RadiologyReport) -> (UUID, ReportSection.Kind)? {
        for section in report.sections.reversed() {
            for sentence in section.sentences.reversed() {
                if isPendingSuggestion(sentence) {
                    return (sentence.id, section.kind)
                }
            }
        }
        return nil
    }

    /// Flip the most recent pending AI/VLM suggestion to
    /// `acceptedAISuggestion`. No-op if none exists. Returns the updated
    /// report unchanged in that case so callers can compose blindly.
    public static func acceptLastPending(in report: RadiologyReport) -> RadiologyReport {
        guard let (id, _) = findLastPending(in: report) else { return report }
        return RadiologyReportMutator.updateSentence(
            id: id,
            newText: existingTextForID(id, in: report) ?? "",
            provenance: .acceptedAISuggestion,
            in: report
        )
    }

    /// Remove the most recent pending AI/VLM suggestion. No-op when none.
    public static func rejectLastPending(in report: RadiologyReport) -> RadiologyReport {
        guard let (id, _) = findLastPending(in: report) else { return report }
        return RadiologyReportMutator.removeSentence(id: id, in: report)
    }

    /// Look up the current text for a sentence id, used by `accept` so
    /// the flip preserves the wording.
    private static func existingTextForID(_ id: UUID,
                                          in report: RadiologyReport) -> String? {
        for section in report.sections {
            if let s = section.sentences.first(where: { $0.id == id }) {
                return s.text
            }
        }
        return nil
    }

    /// Delete the last sentence in `section`, regardless of provenance.
    /// Used by the "delete that" / "scratch that" command. No-op on
    /// empty sections.
    public static func deleteLastSentence(in section: ReportSection.Kind,
                                          of report: RadiologyReport) -> RadiologyReport {
        guard let idx = report.sectionIndex(for: section),
              let last = report.sections[idx].sentences.last else {
            return report
        }
        return RadiologyReportMutator.removeSentence(id: last.id, in: report)
    }
}
