import Foundation

/// Pure (no-side-effect) parser that classifies a finalised dictation
/// utterance as one of several commands. Returns `.passthrough(text)`
/// when the utterance is normal speech that should land in the report
/// as a regular sentence.
///
/// Lives separately from `DictationSession` so the same interpreter can
/// be reused by a future global push-to-talk hotkey, the assistant chat,
/// or the macro picker. Tests exercise every branch without spinning up
/// the audio pipeline.
///
/// Command grammar (case-insensitive, punctuation-tolerant):
///   Section switching         "section impression" / "switch to findings" /
///                             "go to history"
///   Sentence editing          "delete that" / "delete last sentence" /
///                             "remove last"
///   Acceptance                "accept that" / "accept suggestion" /
///                             "reject that"
///   AI features               "draft impression" / "vibe impression" /
///                             "describe view" / "describe what you see"
///   Lifecycle                 "save report" / "sign off as <name>" /
///                             "new report"
///
/// The interpreter does NOT mutate state — it returns a typed command and
/// the caller (DictationSession + DictationPanel) wires the side effect.
public enum DictationCommand: Equatable, Sendable {
    case passthrough(String)

    case switchSection(ReportSection.Kind)

    /// Remove the last sentence from the active section.
    case deleteLastSentence
    /// Accept the most recent AI/VLM suggestion (flip provenance to
    /// `acceptedAISuggestion`). No-op if none exists.
    case acceptLastSuggestion
    /// Reject (delete) the most recent AI/VLM suggestion.
    case rejectLastSuggestion

    /// Trigger the impression drafter on the current report.
    case draftImpression
    /// Trigger the pixel-to-text suggester on the current viewport image.
    case describeView

    /// Persist the report to disk.
    case saveReport
    /// Sign the report off; clinician name comes after "as".
    case signOff(clinician: String)
    /// Reset the report to a fresh blank.
    case newReport
}

public enum DictationCommandInterpreter {

    /// Parse `raw` into a command. Pure — same input always returns the
    /// same command.
    public static func interpret(_ raw: String) -> DictationCommand {
        let normalised = normalise(raw)
        if normalised.isEmpty { return .passthrough(raw) }

        // Section switching — reuse the existing parser so behaviour
        // matches what users learned in C2.
        if let section = DictationSession.parseSectionCommand(raw) {
            return .switchSection(section)
        }

        // Delete-last family
        if matchesAny(normalised, [
            "delete that", "delete last", "delete last sentence",
            "remove that", "remove last", "remove last sentence",
            "scratch that"
        ]) {
            return .deleteLastSentence
        }

        // Accept / reject family
        if matchesAny(normalised, [
            "accept that", "accept suggestion", "accept ai", "accept vlm",
            "looks good", "accept it"
        ]) {
            return .acceptLastSuggestion
        }
        if matchesAny(normalised, [
            "reject that", "reject suggestion", "reject ai", "reject vlm",
            "discard that"
        ]) {
            return .rejectLastSuggestion
        }

        // AI features
        if matchesAny(normalised, [
            "draft impression", "vibe impression", "vibe report",
            "draft the impression", "ai impression", "auto impression"
        ]) {
            return .draftImpression
        }
        if matchesAny(normalised, [
            "describe view", "describe what you see", "describe slice",
            "pixel to text", "describe image"
        ]) {
            return .describeView
        }

        // Lifecycle
        if matchesAny(normalised, ["save report", "save the report", "save"]) {
            return .saveReport
        }
        if matchesAny(normalised, ["new report", "start new report", "blank report"]) {
            return .newReport
        }
        if let name = signOffName(normalised) {
            return .signOff(clinician: name)
        }

        return .passthrough(raw)
    }

    // MARK: - Helpers

    /// Lowercase, trim, drop terminal punctuation, collapse runs of
    /// whitespace. Same normalisation MacroEngine uses for triggers,
    /// reused so users can mix command and macro idioms freely.
    public static func normalise(_ raw: String) -> String {
        let lower = raw.lowercased()
        var out = ""
        var lastWasSpace = false
        for scalar in lower.unicodeScalars {
            let cs = CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ".,!?;:—–-"))
            if cs.contains(scalar) {
                if !lastWasSpace, !out.isEmpty {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.append(Character(scalar))
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchesAny(_ normalised: String, _ patterns: [String]) -> Bool {
        for p in patterns where normalised == p { return true }
        return false
    }

    /// Recognise "sign off as <name>" / "sign as <name>" / "signed by <name>".
    /// Returns the (trimmed) clinician name or nil when no match.
    private static func signOffName(_ normalised: String) -> String? {
        let prefixes = ["sign off as ", "signoff as ", "sign as ", "signed by "]
        for p in prefixes where normalised.hasPrefix(p) {
            let name = String(normalised.dropFirst(p.count))
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : Self.titleCase(name)
        }
        return nil
    }

    /// Restore a reasonable casing for a name we just lowercased. Best-
    /// effort: capitalises the first letter of each whitespace-separated
    /// token. `dr hatem` → `Dr Hatem`.
    private static func titleCase(_ s: String) -> String {
        s.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
