import Foundation

/// In-memory data model for a single radiology report. Designed to be the
/// **only** state the dictation pipeline mutates; the section editor binds
/// to it directly, the formatter renders it, and the persistence layer
/// snapshots it. No mutation paths bypass this struct.
///
/// Design choices for v1:
///   • Value-type top to bottom (`struct` everywhere). Drives Equatable +
///     Codable for free, makes diffing trivial, gives SwiftUI cheap
///     change-detection. Mutation goes through the owning
///     `RadiologyReportStore` actor.
///   • Provenance is first-class on every sentence. Hallucinations and
///     drafted impressions need to be visually distinguishable from
///     dictated content (radiology-AI lit consensus on safety) — we tag at
///     ingest, not at render time.
///   • Findings carry optional RadLex / SNOMED CT / LOINC codes. v1 leaves
///     those nil; the NLP linker (C3) fills them. Schema is in place so
///     the linker doesn't need to touch the report struct definition.
///   • Sections are an *ordered list with a stable id*, not a dictionary.
///     Two reports' "Findings" sections compare positionally, and the UI
///     can drag-reorder without remapping keys.
///
/// Schema versioning: `schemaVersion` is bumped on incompatible changes.
/// The persistence layer (see `RadiologyReportStore`) refuses to load a
/// snapshot newer than `currentSchemaVersion` so future-you can't quietly
/// drop fields the loader doesn't understand.
public struct RadiologyReport: Codable, Equatable, Sendable, Identifiable {

    public static let currentSchemaVersion: Int = 1

    public let id: UUID
    public var schemaVersion: Int
    public var metadata: ReportMetadata
    public var sections: [ReportSection]
    /// Append-only revision log. Each `commit*` operation on the store
    /// appends an entry. Used by the audit panel and the regulatory paper
    /// trail (sign-off + every edit-after-sign-off must be traceable).
    public var revisions: [ReportRevision]
    /// Sign-off marks the report as final. Mutations after sign-off are
    /// allowed but produce a new revision with `kind == .addendum` —
    /// matches HL7 ORU report-status transition `F → C` (Corrected).
    public var signOff: ReportSignOff?

    public init(id: UUID = UUID(),
                schemaVersion: Int = RadiologyReport.currentSchemaVersion,
                metadata: ReportMetadata = ReportMetadata(),
                sections: [ReportSection] = RadiologyReport.defaultSections(),
                revisions: [ReportRevision] = [],
                signOff: ReportSignOff? = nil) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.metadata = metadata
        self.sections = sections
        self.revisions = revisions
        self.signOff = signOff
    }

    /// Built-in starter sections matching ACR's standard reporting outline.
    /// Users can rename, reorder, add, or remove via the structured
    /// editor; these are just the v1 defaults.
    public static func defaultSections() -> [ReportSection] {
        [
            ReportSection(kind: .clinicalHistory, title: "Clinical History"),
            ReportSection(kind: .technique, title: "Technique"),
            ReportSection(kind: .comparison, title: "Comparison"),
            ReportSection(kind: .findings, title: "Findings"),
            ReportSection(kind: .impression, title: "Impression"),
        ]
    }

    /// Whether the report is still mutable without producing an addendum.
    public var isFinalised: Bool { signOff != nil }

    /// Returns the index of the section whose kind matches `kind`, or nil.
    public func sectionIndex(for kind: ReportSection.Kind) -> Int? {
        sections.firstIndex(where: { $0.kind == kind })
    }
}

// MARK: - Metadata

/// Patient + study identifiers + dictating clinician. Pulled from the
/// active DICOM volume when the user opens dictation; mutable so the user
/// can fix typos before sign-off.
public struct ReportMetadata: Codable, Equatable, Sendable {
    public var studyKey: String
    public var studyUID: String
    public var patientID: String
    public var patientName: String
    public var studyDate: Date?
    public var studyDescription: String
    public var modality: String
    public var accessionNumber: String
    public var sourceVolumeIdentities: [String]
    public var reportingClinician: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(studyKey: String = "",
                studyUID: String = "",
                patientID: String = "",
                patientName: String = "",
                studyDate: Date? = nil,
                studyDescription: String = "",
                modality: String = "",
                accessionNumber: String = "",
                sourceVolumeIdentities: [String] = [],
                reportingClinician: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.studyKey = studyKey
        self.studyUID = studyUID
        self.patientID = patientID
        self.patientName = patientName
        self.studyDate = studyDate
        self.studyDescription = studyDescription
        self.modality = modality
        self.accessionNumber = accessionNumber
        self.sourceVolumeIdentities = sourceVolumeIdentities
        self.reportingClinician = reportingClinician
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case studyKey
        case studyUID
        case patientID
        case patientName
        case studyDate
        case studyDescription
        case modality
        case accessionNumber
        case sourceVolumeIdentities
        case reportingClinician
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        studyKey = try container.decodeIfPresent(String.self, forKey: .studyKey) ?? ""
        studyUID = try container.decodeIfPresent(String.self, forKey: .studyUID) ?? ""
        patientID = try container.decodeIfPresent(String.self, forKey: .patientID) ?? ""
        patientName = try container.decodeIfPresent(String.self, forKey: .patientName) ?? ""
        studyDate = try container.decodeIfPresent(Date.self, forKey: .studyDate)
        studyDescription = try container.decodeIfPresent(String.self, forKey: .studyDescription) ?? ""
        modality = try container.decodeIfPresent(String.self, forKey: .modality) ?? ""
        accessionNumber = try container.decodeIfPresent(String.self, forKey: .accessionNumber) ?? ""
        sourceVolumeIdentities = try container.decodeIfPresent([String].self, forKey: .sourceVolumeIdentities) ?? []
        reportingClinician = try container.decodeIfPresent(String.self, forKey: .reportingClinician) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

// MARK: - Section

public struct ReportSection: Codable, Equatable, Sendable, Identifiable {

    /// Canonical section kinds ACR/RSNA reporting templates use. The
    /// `.custom` case lets users add institution-specific sections (e.g.
    /// "TMTV summary") without losing the type-safety on the canonical
    /// ones. Code paths that key off a specific section (the formatter,
    /// the AI impression drafter) only branch on the canonical cases.
    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        case clinicalHistory
        case technique
        case comparison
        case findings
        case impression
        case recommendations
        case custom
    }

    public let id: UUID
    public var kind: Kind
    public var title: String
    /// Sentences are the unit of provenance — each one tracks who
    /// authored it (user, macro expansion, AI). Re-ordering sentences
    /// preserves provenance.
    public var sentences: [ReportSentence]

    public init(id: UUID = UUID(),
                kind: Kind,
                title: String,
                sentences: [ReportSentence] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sentences = sentences
    }

    /// Concatenated plain text of the section. Convenience for unit
    /// tests and cheap UI rendering.
    public var plainText: String {
        sentences.map(\.text).joined(separator: " ")
    }
}

// MARK: - Sentence + provenance

public struct ReportSentence: Codable, Equatable, Sendable, Identifiable {

    /// Where the sentence came from. Drives the section editor's badge
    /// colour and the post-sign-off audit summary. Adding a new case is a
    /// breaking change — bump `RadiologyReport.currentSchemaVersion`.
    public enum Provenance: String, Codable, Equatable, Sendable, CaseIterable {
        /// User dictated this directly via the speech engine.
        case dictated
        /// User typed this into the editor.
        case typed
        /// A macro template expanded into this text.
        case macro
        /// LLM drafted this (e.g. vibe-reporting impression). Not yet
        /// accepted by the user — surfaced in italics until accepted.
        case aiDrafted
        /// Vision-language model proposed this from the image (pixel-to-
        /// text). Same UI treatment as `aiDrafted` until accepted.
        case vlmSuggested
        /// User explicitly accepted an AI/VLM suggestion. Treated as
        /// dictated for export but the audit log preserves the AI origin.
        case acceptedAISuggestion
    }

    public let id: UUID
    public var text: String
    public var provenance: Provenance
    /// Engine confidence (0...1) when provenance is dictated. Used by the
    /// editor to underline low-confidence sentences for user review.
    public var confidence: Double?
    /// Optional finding link — when the sentence came from an Organ-
    /// Finding row in the structured editor, we keep the back-reference so
    /// edits to the finding flow back to the sentence and vice-versa.
    public var findingID: UUID?
    /// Free-form codes (RadLex / SNOMED CT / LOINC). v1 leaves empty.
    public var codes: [ConceptCode]
    public var createdAt: Date

    public init(id: UUID = UUID(),
                text: String,
                provenance: Provenance,
                confidence: Double? = nil,
                findingID: UUID? = nil,
                codes: [ConceptCode] = [],
                createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.provenance = provenance
        self.confidence = confidence
        self.findingID = findingID
        self.codes = codes
        self.createdAt = createdAt
    }
}

// MARK: - Concept codes

/// Single coded concept. The `system` is one of a handful of well-known
/// vocabularies; we use the URL form rather than free-form strings so two
/// codes from different reports compare reliably.
public struct ConceptCode: Codable, Equatable, Sendable, Hashable {
    public enum System: String, Codable, Equatable, Sendable, CaseIterable {
        case radlex      = "http://radlex.org/"
        case snomed      = "http://snomed.info/sct"
        case loinc       = "http://loinc.org"
        case icd10       = "http://hl7.org/fhir/sid/icd-10"
        case custom      = "urn:tracer:custom"
    }
    public var system: System
    public var code: String
    public var display: String

    public init(system: System, code: String, display: String) {
        self.system = system
        self.code = code
        self.display = display
    }
}

// MARK: - Revisions

public struct ReportRevision: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Equatable, Sendable {
        /// A normal in-progress edit before sign-off. Not exported to
        /// downstream systems; just for the local audit panel.
        case edit
        /// User signed the report (or unsigned it).
        case signOff
        case signOffRescinded
        /// Edit that occurred after sign-off — must be exported as an
        /// HL7 corrected/addended report.
        case addendum
    }

    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    public let author: String
    public let summary: String

    public init(id: UUID = UUID(),
                timestamp: Date = Date(),
                kind: Kind,
                author: String,
                summary: String) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.author = author
        self.summary = summary
    }
}

// MARK: - Sign-off

public struct ReportSignOff: Codable, Equatable, Sendable {
    public var clinician: String
    public var timestamp: Date
    /// PIN / token used to authenticate the sign-off. v1 just records
    /// presence; future commits validate against the user's keychain.
    public var attestationHash: String?

    public init(clinician: String,
                timestamp: Date = Date(),
                attestationHash: String? = nil) {
        self.clinician = clinician
        self.timestamp = timestamp
        self.attestationHash = attestationHash
    }
}

// MARK: - Mutation API (pure)

/// Pure-data operations — the store wraps these on `@MainActor` and emits
/// SwiftUI updates, but every transformation is exercised here so unit
/// tests don't need to spin up an actor.
public enum RadiologyReportMutator {

    /// Append a sentence to the section identified by `kind`. Returns the
    /// updated report. If the section doesn't exist, the report is
    /// returned unchanged — callers that want auto-create semantics must
    /// pre-insert the section.
    public static func appendSentence(_ sentence: ReportSentence,
                                      to kind: ReportSection.Kind,
                                      in report: RadiologyReport) -> RadiologyReport {
        var copy = report
        guard let idx = copy.sectionIndex(for: kind) else { return copy }
        copy.sections[idx].sentences.append(sentence)
        copy.metadata.updatedAt = Date()
        return copy
    }

    /// Replace the sentence at `sentenceID`. Returns the report unchanged
    /// if the id isn't found — the editor logs a warning in that case.
    public static func updateSentence(id sentenceID: UUID,
                                      newText: String,
                                      provenance: ReportSentence.Provenance? = nil,
                                      in report: RadiologyReport) -> RadiologyReport {
        var copy = report
        for sIdx in copy.sections.indices {
            if let tIdx = copy.sections[sIdx].sentences.firstIndex(where: { $0.id == sentenceID }) {
                copy.sections[sIdx].sentences[tIdx].text = newText
                if let p = provenance {
                    copy.sections[sIdx].sentences[tIdx].provenance = p
                }
                copy.metadata.updatedAt = Date()
                return copy
            }
        }
        return copy
    }

    /// Remove a sentence by id. No-op if the id is not present.
    public static func removeSentence(id sentenceID: UUID,
                                      in report: RadiologyReport) -> RadiologyReport {
        var copy = report
        for sIdx in copy.sections.indices {
            if let tIdx = copy.sections[sIdx].sentences.firstIndex(where: { $0.id == sentenceID }) {
                copy.sections[sIdx].sentences.remove(at: tIdx)
                copy.metadata.updatedAt = Date()
                return copy
            }
        }
        return copy
    }

    /// Replace the entire content of a section with the given sentences.
    /// Used by the macro engine when the user runs a full-section macro
    /// like `.normal liver`.
    public static func replaceSection(_ kind: ReportSection.Kind,
                                      with sentences: [ReportSentence],
                                      in report: RadiologyReport) -> RadiologyReport {
        var copy = report
        guard let idx = copy.sectionIndex(for: kind) else { return copy }
        copy.sections[idx].sentences = sentences
        copy.metadata.updatedAt = Date()
        return copy
    }

    /// Append a custom section by title. No-op if a custom section with
    /// the same title already exists (case-insensitive comparison).
    public static func addCustomSection(title: String,
                                        in report: RadiologyReport) -> RadiologyReport {
        var copy = report
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return copy }
        if copy.sections.contains(where: {
            $0.kind == .custom && $0.title.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            return copy
        }
        copy.sections.append(ReportSection(kind: .custom, title: trimmed))
        copy.metadata.updatedAt = Date()
        return copy
    }

    /// Reorder sections by id list. Any ids not in the list keep their
    /// original relative order at the tail.
    public static func reorderSections(by ids: [UUID],
                                       in report: RadiologyReport) -> RadiologyReport {
        var copy = report
        let lookup = Dictionary(uniqueKeysWithValues: copy.sections.map { ($0.id, $0) })
        var remaining = copy.sections
        var ordered: [ReportSection] = []
        for id in ids {
            if let s = lookup[id] {
                ordered.append(s)
                remaining.removeAll(where: { $0.id == id })
            }
        }
        copy.sections = ordered + remaining
        copy.metadata.updatedAt = Date()
        return copy
    }

    /// Mark the report signed by `clinician`. If the report is already
    /// signed, replaces the existing sign-off (i.e. re-signing is allowed
    /// before any addendum has been recorded).
    public static func signOff(by clinician: String,
                               attestationHash: String? = nil,
                               in report: RadiologyReport) -> RadiologyReport {
        var copy = report
        copy.signOff = ReportSignOff(
            clinician: clinician,
            timestamp: Date(),
            attestationHash: attestationHash
        )
        copy.revisions.append(ReportRevision(
            kind: .signOff,
            author: clinician,
            summary: "Report signed off"
        ))
        copy.metadata.updatedAt = Date()
        return copy
    }

    /// Rescind a prior sign-off — re-opens the report for in-progress
    /// edits. Records a `signOffRescinded` revision so the audit panel
    /// can show why the report flipped back to draft.
    public static func rescindSignOff(by clinician: String,
                                      in report: RadiologyReport) -> RadiologyReport {
        var copy = report
        guard copy.signOff != nil else { return copy }
        copy.signOff = nil
        copy.revisions.append(ReportRevision(
            kind: .signOffRescinded,
            author: clinician,
            summary: "Sign-off rescinded"
        ))
        copy.metadata.updatedAt = Date()
        return copy
    }

    /// Append an audit-log entry. Use when the caller has already mutated
    /// the report some other way and wants to record what happened.
    public static func recordRevision(kind: ReportRevision.Kind,
                                      author: String,
                                      summary: String,
                                      in report: RadiologyReport) -> RadiologyReport {
        var copy = report
        copy.revisions.append(ReportRevision(
            kind: kind,
            author: author,
            summary: summary
        ))
        copy.metadata.updatedAt = Date()
        return copy
    }
}
