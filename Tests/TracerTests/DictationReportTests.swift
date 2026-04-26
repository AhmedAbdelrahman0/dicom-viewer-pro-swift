import XCTest
@testable import Tracer

/// Coverage for C2 of the dictation workflow:
///   • RadiologyReport mutator (append/update/remove/replace/reorder/sign)
///   • MacroEngine (trigger normalisation, longest-match, field expansion)
///   • ReportFormatter (plain text / Markdown / HL7)
///   • DictationSession.parseSectionCommand
///   • RadiologyReportStore round-trip + schema-version refusal
///
/// Store tests use a hermetic tmp directory so they never touch
/// ~/Library/Application Support.
final class DictationReportTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultReportHasFiveStarterSections() {
        let report = RadiologyReport()
        let kinds = report.sections.map(\.kind)
        XCTAssertEqual(kinds, [
            .clinicalHistory, .technique, .comparison, .findings, .impression
        ])
        XCTAssertFalse(report.isFinalised)
    }

    func testReportIDIsStableAcrossEncode() throws {
        let original = RadiologyReport()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RadiologyReport.self, from: encoded)
        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.schemaVersion, decoded.schemaVersion)
    }

    // MARK: - Mutator

    func testAppendSentenceLandsInTargetSection() {
        var r = RadiologyReport()
        let s = ReportSentence(text: "Liver is normal.", provenance: .dictated)
        r = RadiologyReportMutator.appendSentence(s, to: .findings, in: r)
        let findings = r.sections.first { $0.kind == .findings }!
        XCTAssertEqual(findings.sentences.count, 1)
        XCTAssertEqual(findings.sentences.first?.text, "Liver is normal.")
    }

    func testAppendSentenceToMissingSectionIsNoOp() {
        var r = RadiologyReport(sections: []) // no sections at all
        let s = ReportSentence(text: "x", provenance: .dictated)
        r = RadiologyReportMutator.appendSentence(s, to: .findings, in: r)
        XCTAssertTrue(r.sections.isEmpty)
    }

    func testUpdateSentenceByID() {
        var r = RadiologyReport()
        let s = ReportSentence(text: "Old text.", provenance: .dictated)
        r = RadiologyReportMutator.appendSentence(s, to: .findings, in: r)
        let id = r.sections.first { $0.kind == .findings }!.sentences.first!.id
        r = RadiologyReportMutator.updateSentence(id: id, newText: "New text.",
                                                  provenance: .typed, in: r)
        let updated = r.sections.first { $0.kind == .findings }!.sentences.first!
        XCTAssertEqual(updated.text, "New text.")
        XCTAssertEqual(updated.provenance, .typed)
    }

    func testRemoveSentenceByID() {
        var r = RadiologyReport()
        let s = ReportSentence(text: "x", provenance: .dictated)
        r = RadiologyReportMutator.appendSentence(s, to: .findings, in: r)
        let id = r.sections.first { $0.kind == .findings }!.sentences.first!.id
        r = RadiologyReportMutator.removeSentence(id: id, in: r)
        XCTAssertTrue(r.sections.first { $0.kind == .findings }!.sentences.isEmpty)
    }

    func testRemoveUnknownSentenceIsNoOp() {
        let r1 = RadiologyReport()
        let r2 = RadiologyReportMutator.removeSentence(id: UUID(), in: r1)
        XCTAssertEqual(r1.sections.map(\.id), r2.sections.map(\.id))
    }

    func testReplaceSection() {
        var r = RadiologyReport()
        let s = ReportSentence(text: "First", provenance: .dictated)
        r = RadiologyReportMutator.appendSentence(s, to: .findings, in: r)
        let macro = ReportSentence(text: "Macro paragraph.", provenance: .macro)
        r = RadiologyReportMutator.replaceSection(.findings, with: [macro], in: r)
        let findings = r.sections.first { $0.kind == .findings }!
        XCTAssertEqual(findings.sentences.count, 1)
        XCTAssertEqual(findings.sentences.first?.provenance, .macro)
    }

    func testAddCustomSectionDeduplicatesByTitle() {
        var r = RadiologyReport()
        r = RadiologyReportMutator.addCustomSection(title: "TMTV Summary", in: r)
        r = RadiologyReportMutator.addCustomSection(title: "tmtv summary", in: r)
        let customs = r.sections.filter { $0.kind == .custom }
        XCTAssertEqual(customs.count, 1)
        XCTAssertEqual(customs.first?.title, "TMTV Summary")
    }

    func testAddCustomSectionRejectsBlankTitle() {
        var r = RadiologyReport()
        r = RadiologyReportMutator.addCustomSection(title: "   ", in: r)
        XCTAssertFalse(r.sections.contains(where: { $0.kind == .custom }))
    }

    func testReorderSections() {
        var r = RadiologyReport()
        let original = r.sections.map(\.id)
        let reversed: [UUID] = original.reversed()
        r = RadiologyReportMutator.reorderSections(by: reversed, in: r)
        XCTAssertEqual(r.sections.map(\.id), reversed)
    }

    func testReorderSectionsKeepsUnreferencedSectionsAtTail() {
        var r = RadiologyReport()
        let firstTwo = Array(r.sections.prefix(2).map(\.id))
        r = RadiologyReportMutator.reorderSections(by: firstTwo, in: r)
        XCTAssertEqual(r.sections.count, 5)  // none dropped
        XCTAssertEqual(Array(r.sections.prefix(2).map(\.id)), firstTwo)
    }

    func testSignOffStampsAndAppendsRevision() {
        var r = RadiologyReport()
        r = RadiologyReportMutator.signOff(by: "Dr Hatem", in: r)
        XCTAssertNotNil(r.signOff)
        XCTAssertEqual(r.signOff?.clinician, "Dr Hatem")
        XCTAssertEqual(r.revisions.last?.kind, .signOff)
        XCTAssertTrue(r.isFinalised)
    }

    func testRescindSignOff() {
        var r = RadiologyReport()
        r = RadiologyReportMutator.signOff(by: "Dr Hatem", in: r)
        r = RadiologyReportMutator.rescindSignOff(by: "Dr Hatem", in: r)
        XCTAssertNil(r.signOff)
        XCTAssertEqual(r.revisions.last?.kind, .signOffRescinded)
        XCTAssertFalse(r.isFinalised)
    }

    // MARK: - MacroEngine — normalisation

    func testNormaliseTriggerCollapsesPunctuationAndCase() {
        XCTAssertEqual(MacroEngine.normaliseTrigger(".Liver, Normal!"),
                       "liver normal")
        XCTAssertEqual(MacroEngine.normaliseTrigger("LIVER   normal"),
                       "liver normal")
        XCTAssertEqual(MacroEngine.normaliseTrigger("liver — normal"),
                       "liver normal")
    }

    // MARK: - MacroEngine — trigger detection

    func testDetectTriggerDotPrefix() {
        let engine = MacroEngine()
        let result = engine.detectTrigger(in: ".liver normal")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0.id, "normal-liver")
        XCTAssertEqual(result?.remaining, "")
    }

    func testDetectTriggerWordPrefixMacro() {
        let engine = MacroEngine()
        let result = engine.detectTrigger(in: "macro spleen normal")
        XCTAssertEqual(result?.0.id, "normal-spleen")
    }

    func testDetectTriggerWordPrefixExpand() {
        let engine = MacroEngine()
        let result = engine.detectTrigger(in: "expand kidneys normal")
        XCTAssertEqual(result?.0.id, "normal-kidneys")
    }

    func testDetectTriggerWithTrailingDictation() {
        let engine = MacroEngine()
        let result = engine.detectTrigger(in: ".liver normal but with steatosis")
        XCTAssertEqual(result?.0.id, "normal-liver")
        XCTAssertEqual(result?.remaining, "but with steatosis")
    }

    func testDetectTriggerNoMatch() {
        let engine = MacroEngine()
        XCTAssertNil(engine.detectTrigger(in: "nothing here"))
        XCTAssertNil(engine.detectTrigger(in: ""))
    }

    func testDetectTriggerLongestMatchWins() {
        let engine = MacroEngine()
        engine.register(DictationMacro(
            id: "liver",
            displayName: "Liver",
            trigger: "liver",
            body: "Short."
        ))
        // "liver normal" (default) is longer than "liver" — should win.
        let result = engine.detectTrigger(in: ".liver normal")
        XCTAssertEqual(result?.0.id, "normal-liver")
    }

    // MARK: - MacroEngine — expansion

    func testExpandReplacesPlaceholders() {
        let engine = MacroEngine()
        let macro = DictationMacro(
            id: "test",
            displayName: "Test",
            trigger: "test",
            body: "Compared to {{prior_date}}: response {{rate}}.",
            fields: ["prior_date", "rate"]
        )
        let out = engine.expand(macro, fields: [
            "prior_date": "2026-01-01",
            "rate": "complete"
        ])
        XCTAssertEqual(out, "Compared to 2026-01-01: response complete.")
    }

    func testExpandMissingFieldRendersBracketedHint() {
        let engine = MacroEngine()
        let macro = DictationMacro(
            id: "test",
            displayName: "Test",
            trigger: "test",
            body: "Date: {{prior_date}}.",
            fields: ["prior_date"]
        )
        let out = engine.expand(macro, fields: [:])
        XCTAssertEqual(out, "Date: [?prior_date?].")
    }

    func testExpandUnterminatedPlaceholderEmitsLiteral() {
        let engine = MacroEngine()
        let macro = DictationMacro(
            id: "test", displayName: "Test", trigger: "test",
            body: "Broken {{field"
        )
        let out = engine.expand(macro)
        // Literal "{{" preserved so the user can see + fix the syntax error.
        XCTAssertTrue(out.contains("{{"))
    }

    func testApplyMacroAppendsAsMacroSentence() {
        let engine = MacroEngine()
        let macro = engine.macro(forId: "normal-liver")!
        var r = RadiologyReport()
        r = engine.apply(macro, to: r)
        let findings = r.sections.first { $0.kind == .findings }!
        XCTAssertEqual(findings.sentences.count, 1)
        XCTAssertEqual(findings.sentences.first?.provenance, .macro)
    }

    func testRegisterAndUnregister() {
        let engine = MacroEngine()
        let custom = DictationMacro(
            id: "custom", displayName: "Custom", trigger: "custom phrase",
            body: "Custom body."
        )
        engine.register(custom)
        XCTAssertNotNil(engine.macro(forId: "custom"))
        engine.unregister(id: "custom")
        XCTAssertNil(engine.macro(forId: "custom"))
    }

    // MARK: - DictationSession.parseSectionCommand

    func testParseSectionCommandRecognisesPrefixes() {
        XCTAssertEqual(DictationSession.parseSectionCommand("section impression"), .impression)
        XCTAssertEqual(DictationSession.parseSectionCommand("Section Findings."), .findings)
        XCTAssertEqual(DictationSession.parseSectionCommand("switch to comparison"), .comparison)
        XCTAssertEqual(DictationSession.parseSectionCommand("go to history"), .clinicalHistory)
        XCTAssertEqual(DictationSession.parseSectionCommand("section recommendations"), .recommendations)
    }

    func testParseSectionCommandReturnsNilForRegularSpeech() {
        XCTAssertNil(DictationSession.parseSectionCommand("the liver is normal."))
        XCTAssertNil(DictationSession.parseSectionCommand(""))
        XCTAssertNil(DictationSession.parseSectionCommand("section unknown-section"))
    }

    // MARK: - ReportFormatter

    func testFormatPlainTextSkipsEmptySections() {
        var r = RadiologyReport()
        let s = ReportSentence(text: "The liver is normal.", provenance: .dictated)
        r = RadiologyReportMutator.appendSentence(s, to: .findings, in: r)
        let out = ReportFormatter.format(r, style: .plainText)
        XCTAssertTrue(out.contains("FINDINGS"))
        XCTAssertTrue(out.contains("The liver is normal."))
        XCTAssertFalse(out.contains("CLINICAL HISTORY"))   // empty section omitted
        XCTAssertFalse(out.contains("IMPRESSION"))         // empty section omitted
    }

    func testFormatMarkdownIncludesProvenanceCommentForNonHumanSentences() {
        var r = RadiologyReport()
        let dictated = ReportSentence(text: "Liver normal.", provenance: .dictated)
        let aiDraft = ReportSentence(text: "Stable disease.", provenance: .aiDrafted)
        r = RadiologyReportMutator.appendSentence(dictated, to: .findings, in: r)
        r = RadiologyReportMutator.appendSentence(aiDraft, to: .impression, in: r)
        let out = ReportFormatter.format(r, style: .markdown)
        XCTAssertTrue(out.contains("## Findings"))
        XCTAssertTrue(out.contains("## Impression"))
        XCTAssertTrue(out.contains("provenance: aiDrafted"))
        XCTAssertFalse(out.contains("provenance: dictated"))
    }

    func testFormatHL7EscapesPipeAndCaret() {
        var r = RadiologyReport()
        let s = ReportSentence(text: "Notes contain pipe | and caret ^ chars.",
                               provenance: .typed)
        r = RadiologyReportMutator.appendSentence(s, to: .findings, in: r)
        let out = ReportFormatter.format(r, style: .hl7Friendly)
        XCTAssertTrue(out.contains("\\F\\"))   // pipe → \F\
        XCTAssertTrue(out.contains("\\S\\"))   // caret → \S\
        XCTAssertFalse(out.contains("|"))
        XCTAssertFalse(out.contains("^"))
    }

    func testFormatSignedLetterStampsClinician() {
        var r = RadiologyReport()
        let s = ReportSentence(text: "Liver is normal.", provenance: .dictated)
        r = RadiologyReportMutator.appendSentence(s, to: .findings, in: r)
        r = RadiologyReportMutator.signOff(by: "Dr Hatem", in: r)
        let out = ReportFormatter.format(r, style: .signedLetter, now: Date())
        XCTAssertTrue(out.contains("Reported by: Dr Hatem"))
    }

    func testFormatSignedLetterFlagsDraftWhenUnsigned() {
        let r = RadiologyReport()
        let out = ReportFormatter.format(r, style: .signedLetter, now: Date())
        XCTAssertTrue(out.contains("DRAFT"))
    }

    // MARK: - RadiologyReportStore — persistence round-trip

    @MainActor
    func testStoreRoundTripsThroughDisk() throws {
        let tmp = try makeTempDir()
        let storeA = RadiologyReportStore(storageDirectory: tmp)
        storeA.setMetadata { m in
            m.patientName = "Test Patient"
            m.modality = "PT"
        }
        storeA.appendSentence(
            ReportSentence(text: "Liver is normal.", provenance: .dictated),
            to: .findings
        )
        guard let url = storeA.save() else {
            XCTFail("save() returned nil — \(storeA.statusMessage)")
            return
        }

        let storeB = RadiologyReportStore(storageDirectory: tmp)
        storeB.load(from: url)
        XCTAssertEqual(storeB.report.metadata.patientName, "Test Patient")
        let findings = storeB.report.sections.first { $0.kind == .findings }!
        XCTAssertEqual(findings.sentences.first?.text, "Liver is normal.")
    }

    @MainActor
    func testStoreRecentsListUpdatesAfterSave() throws {
        let tmp = try makeTempDir()
        let store = RadiologyReportStore(storageDirectory: tmp)
        store.setMetadata { m in m.patientName = "Aaa" }
        XCTAssertNotNil(store.save())
        XCTAssertEqual(store.recentReports.count, 1)
        XCTAssertEqual(store.recentReports.first?.patientName, "Aaa")
    }

    @MainActor
    func testStoreRefusesNewerSchema() throws {
        let tmp = try makeTempDir()
        // Write a fake report with a future schema version.
        var fake = RadiologyReport()
        fake.schemaVersion = RadiologyReport.currentSchemaVersion + 1
        let url = tmp.appendingPathComponent("\(fake.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(fake).write(to: url)

        let store = RadiologyReportStore(storageDirectory: tmp)
        store.load(from: url)
        XCTAssertTrue(store.statusMessage.lowercased().contains("schema"),
                      "expected schema-refusal status, got \(store.statusMessage)")
        XCTAssertEqual(store.report.schemaVersion, RadiologyReport.currentSchemaVersion,
                       "report must NOT be replaced when refused")
    }

    @MainActor
    func testStoreApplyMutationDelegatesToMutator() {
        let store = RadiologyReportStore(storageDirectory: FileManager.default.temporaryDirectory)
        store.applyMutation { current in
            RadiologyReportMutator.signOff(by: "Auto", in: current)
        }
        XCTAssertNotNil(store.report.signOff)
        XCTAssertEqual(store.report.revisions.last?.kind, .signOff)
    }

    // MARK: - Test helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
