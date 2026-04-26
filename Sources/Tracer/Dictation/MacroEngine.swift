import Foundation

/// Templated-text expansion for the dictation workflow.
///
/// Radiology reports repeat — "liver is normal in size with no focal lesion",
/// "no FDG-avid lymphadenopathy" — and dictating those phrases word-for-word
/// burns clinician time. Macros let the user say or type a short trigger
/// (e.g. `.liver normal` or `macro liver normal`) and have the full paragraph
/// expanded into the active section, attributed with `Provenance.macro` so
/// it's visually distinguishable from dictated text.
///
/// Field substitution: a macro body may contain `{{field}}` placeholders.
/// At expansion time the engine substitutes values from a context dict
/// (`{"size": "1.2 cm", "side": "right"}`). Missing fields render as the
/// literal `[?field?]` so the editor's red-flag pass can surface
/// unfilled-in macros before sign-off.
///
/// Triggering rules (mirrors PowerScribe, Fluency Direct, etc):
///   • Dot prefix — `.liver normal` matches macro id "liver normal"
///   • Word prefix — "macro <id>" or "expand <id>"
///   • Triggers are case-insensitive, whitespace-collapsed, punctuation-
///     stripped — the user can dictate "macro, liver — normal." and it
///     resolves the same as ".liver normal"
///
/// Catalog scope: the engine ships a small default catalog (7 macros)
/// covering the highest-frequency normal-finding paragraphs in PET/CT,
/// CT chest/abdomen/pelvis, and MRI brain. Sites add their own via
/// `MacroEngine.register(_:)` — macros persist to disk in C2.4 alongside
/// the report.
public struct DictationMacro: Codable, Equatable, Sendable, Identifiable, Hashable {
    public let id: String
    /// Human-friendly display in the macro picker (e.g. "Liver — normal").
    public var displayName: String
    /// Trigger phrase (already lowercased / collapsed at construction time).
    public var trigger: String
    public var body: String
    /// Section the expanded body should land in. `.findings` is the most
    /// common; impression-only macros target `.impression`.
    public var defaultSection: ReportSection.Kind
    /// Optional list of fields the body expects, used by the UI to show a
    /// quick-fill dialog before insertion. Missing fields are tolerated
    /// (rendered as `[?field?]`); listed fields just nudge the editor.
    public var fields: [String]

    public init(id: String,
                displayName: String,
                trigger: String,
                body: String,
                defaultSection: ReportSection.Kind = .findings,
                fields: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.trigger = MacroEngine.normaliseTrigger(trigger)
        self.body = body
        self.defaultSection = defaultSection
        self.fields = fields
    }
}

public final class MacroEngine: @unchecked Sendable {

    public private(set) var catalog: [DictationMacro]
    private let lock = NSLock()

    public init(catalog: [DictationMacro] = MacroEngine.defaultCatalog()) {
        self.catalog = catalog
    }

    // MARK: - Catalog management

    public func register(_ macro: DictationMacro) {
        lock.withLock {
            // Replace if id already present so the user can edit existing
            // macros without managing a separate update path.
            catalog.removeAll(where: { $0.id == macro.id })
            catalog.append(macro)
        }
    }

    public func unregister(id: String) {
        lock.withLock {
            catalog.removeAll(where: { $0.id == id })
        }
    }

    public func macro(forId id: String) -> DictationMacro? {
        lock.withLock { catalog.first(where: { $0.id == id }) }
    }

    /// Look up a macro by its trigger phrase. Used by the dictation
    /// command router when it sees `.something` as the first token.
    public func macro(forTrigger trigger: String) -> DictationMacro? {
        let needle = Self.normaliseTrigger(trigger)
        return lock.withLock { catalog.first(where: { $0.trigger == needle }) }
    }

    // MARK: - Trigger detection

    /// Returns the macro and remaining text if `text` starts with a macro
    /// trigger. The remaining text is dropped onto the section after the
    /// macro body so dictating ".liver normal Then the spleen is enlarged"
    /// expands the liver macro and appends "Then the spleen is enlarged."
    /// Nil return means no macro match.
    public func detectTrigger(in text: String) -> (DictationMacro, remaining: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Pattern 1: dot prefix → ".liver normal"
        if trimmed.hasPrefix(".") {
            let body = String(trimmed.dropFirst())
            return matchByLongestTrigger(in: body)
        }

        // Pattern 2: word prefix → "macro liver normal" / "expand liver normal"
        let lower = trimmed.lowercased()
        for keyword in ["macro ", "expand "] {
            if lower.hasPrefix(keyword) {
                let body = String(trimmed.dropFirst(keyword.count))
                return matchByLongestTrigger(in: body)
            }
        }

        return nil
    }

    /// Match the longest catalog trigger that the input starts with.
    /// Longest-match avoids ambiguity when one trigger is a prefix of
    /// another (e.g. "liver" vs "liver lesion").
    private func matchByLongestTrigger(in input: String) -> (DictationMacro, remaining: String)? {
        let normalised = Self.normaliseTrigger(input)
        // Sort by descending trigger length so the first hit is longest.
        let sorted = lock.withLock {
            catalog.sorted { $0.trigger.count > $1.trigger.count }
        }
        for macro in sorted {
            if normalised == macro.trigger {
                return (macro, "")
            }
            if normalised.hasPrefix(macro.trigger + " ") {
                let remainder = String(normalised.dropFirst(macro.trigger.count + 1))
                return (macro, remainder)
            }
        }
        return nil
    }

    // MARK: - Expansion

    /// Substitute `{{field}}` placeholders in `macro.body` using `fields`.
    /// Missing fields render as `[?fieldName?]`; the editor's "ready to
    /// sign?" check refuses to sign reports containing literal `[?...?]`.
    public func expand(_ macro: DictationMacro,
                       fields: [String: String] = [:]) -> String {
        var body = macro.body
        // Greedy regex-free pass: walk the string, find {{...}}, swap.
        var output = ""
        output.reserveCapacity(body.count)
        while let openRange = body.range(of: "{{") {
            output.append(contentsOf: body[..<openRange.lowerBound])
            body = String(body[openRange.upperBound...])
            if let closeRange = body.range(of: "}}") {
                let key = String(body[..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let replacement = fields[key] ?? "[?\(key)?]"
                output.append(contentsOf: replacement)
                body = String(body[closeRange.upperBound...])
            } else {
                // Unterminated placeholder — emit as literal so the user sees
                // the syntax error rather than losing the body.
                output.append(contentsOf: "{{")
                break
            }
        }
        output.append(contentsOf: body)
        return output
    }

    /// Apply a macro to a report. Inserts the expanded body into
    /// `macro.defaultSection` (or `targetSection` override) tagged with
    /// `Provenance.macro`. The full paragraph becomes a *single*
    /// `ReportSentence` — the formatter will split on punctuation if the
    /// caller wants finer-grained ordering.
    public func apply(_ macro: DictationMacro,
                      fields: [String: String] = [:],
                      targetSection: ReportSection.Kind? = nil,
                      to report: RadiologyReport) -> RadiologyReport {
        let expanded = expand(macro, fields: fields)
        let sentence = ReportSentence(
            text: expanded,
            provenance: .macro,
            confidence: nil
        )
        return RadiologyReportMutator.appendSentence(
            sentence,
            to: targetSection ?? macro.defaultSection,
            in: report
        )
    }

    // MARK: - Default catalog

    /// Seed catalog covering the highest-frequency normals in radiology
    /// reports. Numbers come from the SNOMED-CT-aligned RadLex normal
    /// finding templates; deliberately conservative phrasing (no
    /// "unremarkable" alone — pairs with "in size and morphology" so
    /// downstream NLP doesn't get a single-word section).
    public static func defaultCatalog() -> [DictationMacro] {
        [
            DictationMacro(
                id: "normal-liver",
                displayName: "Liver — normal",
                trigger: "liver normal",
                body: "The liver is normal in size and morphology. There is no focal hepatic lesion or biliary dilatation. The hepatic vasculature is patent.",
                defaultSection: .findings
            ),
            DictationMacro(
                id: "normal-spleen",
                displayName: "Spleen — normal",
                trigger: "spleen normal",
                body: "The spleen is normal in size and homogeneous. No focal splenic lesion is identified.",
                defaultSection: .findings
            ),
            DictationMacro(
                id: "normal-pancreas",
                displayName: "Pancreas — normal",
                trigger: "pancreas normal",
                body: "The pancreas is normal in size and contour. No focal pancreatic mass or ductal dilatation.",
                defaultSection: .findings
            ),
            DictationMacro(
                id: "normal-kidneys",
                displayName: "Kidneys — normal",
                trigger: "kidneys normal",
                body: "The kidneys are normal in size with preserved corticomedullary differentiation. No hydronephrosis or focal renal lesion.",
                defaultSection: .findings
            ),
            DictationMacro(
                id: "normal-lungs",
                displayName: "Lungs — normal",
                trigger: "lungs normal",
                body: "The lungs are clear bilaterally. No focal consolidation, pulmonary nodule, or pleural effusion.",
                defaultSection: .findings
            ),
            DictationMacro(
                id: "no-fdg-avid-disease",
                displayName: "PET — no FDG-avid disease",
                trigger: "no fdg",
                body: "No abnormally FDG-avid lymphadenopathy or focal hypermetabolic lesion is identified within the surveyed field of view.",
                defaultSection: .findings
            ),
            DictationMacro(
                id: "complete-metabolic-response",
                displayName: "Impression — complete metabolic response",
                trigger: "cmr",
                body: "Complete metabolic response by Deauville score 1, with resolution of previously FDG-avid disease compared to the prior study from {{prior_date}}.",
                defaultSection: .impression,
                fields: ["prior_date"]
            ),
        ]
    }

    // MARK: - Internals

    /// Normalise a trigger or candidate input: lowercase, collapse runs of
    /// whitespace, strip punctuation. Means "macro, liver — normal." and
    /// ".liver normal" both resolve to "liver normal".
    public static func normaliseTrigger(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        var lastWasSpace = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar) {
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
}
