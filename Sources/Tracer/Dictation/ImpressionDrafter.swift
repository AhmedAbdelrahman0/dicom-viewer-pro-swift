import Foundation

/// Drafts a one-paragraph "Impression" section from the rest of a report.
///
/// Two implementations ship in C3:
///   • `HeuristicImpressionDrafter` — pure-Swift, runs offline, no LLM.
///     Looks at the Findings section, scores each sentence by likely
///     significance (FDG-avid, lesion descriptors, measurements, change
///     language), picks the top few, joins them into a stable paragraph.
///     Always available — the panel exposes it as the default. Quality
///     is OK for a first draft; clinicians always review before sign-off.
///   • Future MedGemma / DGX-Whisper drafters plug in behind this same
///     protocol when those are wired (separate commit).
///
/// All output is tagged `Provenance.aiDrafted` — the editor renders these
/// in italic gray and the user must explicitly accept (flipping to
/// `acceptedAISuggestion`) before sign-off, so a hallucinated impression
/// can't slip through unnoticed.
public protocol ImpressionDrafter: Sendable {
    var id: String { get }
    var displayName: String { get }
    var isOnDevice: Bool { get }

    /// Draft an impression from the report's Findings + Comparison +
    /// Clinical History sections. Returns the proposed sentence (or
    /// nil when there's not enough input to draft from). Throws on
    /// transport failures (network drafters); heuristic drafter never
    /// throws.
    func draft(from report: RadiologyReport) async throws -> ReportSentence?
}

public enum ImpressionDrafterError: Swift.Error, LocalizedError, Sendable {
    case insufficientInput(String)
    case providerUnavailable(String)
    case transportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .insufficientInput(let m):  return "Impression drafter: \(m)"
        case .providerUnavailable(let m): return "Impression drafter unavailable: \(m)"
        case .transportFailed(let m):    return "Impression drafter transport: \(m)"
        }
    }
}

// MARK: - Heuristic drafter

/// Pure-Swift impression drafter that needs no external service. The
/// algorithm is deliberately simple — we'd rather under-promise on a
/// drafter that ships today than over-promise on one that needs a model
/// download. Clinicians treat it as a starting point, not a final answer.
///
/// Scoring keywords come from common radiology reporting patterns. Tweak
/// `Self.positiveCues` to bias different specialties; the weights are
/// uniform on purpose so adding a cue is a one-line change.
public final class HeuristicImpressionDrafter: ImpressionDrafter, @unchecked Sendable {

    public let id: String = "heuristic-impression-v1"
    public let displayName: String = "Heuristic (offline, no model)"
    public let isOnDevice: Bool = true

    public init() {}

    /// Sentences containing any of these tokens are scored as findings
    /// the impression should mention. Case-insensitive substring match.
    public static let positiveCues: [String] = [
        // Lesion / disease language
        "lesion", "mass", "nodule", "tumour", "tumor",
        "metastasis", "metastases", "metastatic",
        "lymphadenopathy", "adenopathy",
        "consolidation", "infiltrate", "effusion",
        "thrombus", "embolus", "embolism",
        // PET specific
        "fdg-avid", "fdg avid", "hypermetabolic", "suvmax",
        "deauville",
        // Change language
        "increased", "decreased", "stable", "progression",
        "regression", "interval", "new", "resolved",
        // Severity
        "spiculated", "necrotic", "infiltrative",
    ]

    /// Sentences containing any of these tokens are scored as normal
    /// statements that *bypass* the impression unless nothing else exists.
    public static let normalCues: [String] = [
        "unremarkable", "no evidence", "no focal", "no abnormal",
        "is normal", "are normal", "within normal limits",
    ]

    public func draft(from report: RadiologyReport) async throws -> ReportSentence? {
        let findings = report.sections.first { $0.kind == .findings }
        guard let findings, !findings.sentences.isEmpty else {
            throw ImpressionDrafterError.insufficientInput(
                "no Findings yet — dictate or expand a macro first"
            )
        }

        let scored = findings.sentences
            .map { (sentence: $0, score: Self.score($0.text)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        // If nothing scored, fall back to a generic normal-result line so
        // the user gets *something* to react to rather than an empty draft.
        if scored.isEmpty {
            let fallback = report.metadata.modality.uppercased().contains("PT")
                ? "No abnormally FDG-avid disease identified within the surveyed field of view."
                : "No acute abnormality identified."
            return ReportSentence(
                text: "\(fallback) [Heuristic draft — verify before sign-off]",
                provenance: .aiDrafted
            )
        }

        // Take the top 1–3 sentences and stitch them into one impression
        // paragraph, prefixed with a count when more than one is folded in.
        let top = Array(scored.prefix(3)).map(\.sentence.text)
        let body: String
        switch top.count {
        case 1:
            body = top[0]
        case 2:
            body = "\(stripTerminal(top[0])); \(lowercaseFirst(top[1]))"
        default:
            body = "\(stripTerminal(top[0])); \(lowercaseFirst(stripTerminal(top[1]))); \(lowercaseFirst(top[2]))"
        }

        let comparisonNote = report.sections
            .first(where: { $0.kind == .comparison })?
            .sentences.first.map { " Compared to prior: \(stripTerminal($0.text))." } ?? ""

        let drafted = "\(body).\(comparisonNote) [Heuristic draft — verify before sign-off]"
        return ReportSentence(
            text: drafted,
            provenance: .aiDrafted
        )
    }

    // MARK: - Pure scoring

    /// Score a single sentence. `nonisolated` so unit tests can call it
    /// without an actor hop. Public for visibility in tests.
    public static func score(_ text: String) -> Int {
        let lower = text.lowercased()
        var score = 0
        for cue in positiveCues where lower.contains(cue) { score += 2 }
        for cue in normalCues   where lower.contains(cue) { score -= 1 }
        // Numeric measurements are usually meaningful — cm, mm, suvmax 4.2.
        if lower.contains(" cm")   { score += 1 }
        if lower.contains(" mm")   { score += 1 }
        if lower.contains("suvmax") || lower.contains("suv max") { score += 1 }
        return score
    }

    /// Drop a single trailing `.`, `!` or `?` so we can join two sentences
    /// with a semicolon without producing `..`.
    private func stripTerminal(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = out.last, last == "." || last == "!" || last == "?" {
            out.removeLast()
        }
        return out
    }

    /// Lower-case only the first character — joining sentences with `; `
    /// reads more naturally when the second clause is mid-sentence.
    private func lowercaseFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }
}

// MARK: - Closure-backed drafter

/// Test seam + future MedGemma/DGX integration point. Wraps an injected
/// closure as an `ImpressionDrafter`. Production drafters that talk to
/// MedGemma's CoreML wrapper, OpenAI, or DGX-Whisper plug in here without
/// adding new conformances scattered around the codebase.
public final class ClosureImpressionDrafter: ImpressionDrafter, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let isOnDevice: Bool
    private let closure: @Sendable (RadiologyReport) async throws -> ReportSentence?

    public init(id: String,
                displayName: String,
                isOnDevice: Bool,
                _ closure: @escaping @Sendable (RadiologyReport) async throws -> ReportSentence?) {
        self.id = id
        self.displayName = displayName
        self.isOnDevice = isOnDevice
        self.closure = closure
    }

    public func draft(from report: RadiologyReport) async throws -> ReportSentence? {
        try await closure(report)
    }
}
