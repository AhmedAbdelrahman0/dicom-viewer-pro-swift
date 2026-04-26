import XCTest
import CoreGraphics
@testable import Tracer

/// Coverage for C3 — AI features:
///   • DictationCommandInterpreter (every grammar branch)
///   • HeuristicImpressionDrafter (scoring + draft assembly)
///   • AISuggestionAcceptor (accept / reject / find pending)
///   • StubPixelToTextSuggester (deterministic placeholder output)
///   • Closure-backed drafter / suggester (test seam)
final class DictationAITests: XCTestCase {

    // MARK: - DictationCommandInterpreter

    func testInterpretSwitchSection() {
        XCTAssertEqual(DictationCommandInterpreter.interpret("section impression"),
                       .switchSection(.impression))
        XCTAssertEqual(DictationCommandInterpreter.interpret("Switch to Findings."),
                       .switchSection(.findings))
        XCTAssertEqual(DictationCommandInterpreter.interpret("go to history"),
                       .switchSection(.clinicalHistory))
    }

    func testInterpretDeleteFamily() {
        for phrase in ["delete that", "delete last", "delete last sentence",
                       "remove that", "remove last", "scratch that"] {
            XCTAssertEqual(DictationCommandInterpreter.interpret(phrase),
                           .deleteLastSentence,
                           "expected delete for: \(phrase)")
        }
    }

    func testInterpretAcceptRejectFamilies() {
        XCTAssertEqual(DictationCommandInterpreter.interpret("accept that"),
                       .acceptLastSuggestion)
        XCTAssertEqual(DictationCommandInterpreter.interpret("Accept Suggestion."),
                       .acceptLastSuggestion)
        XCTAssertEqual(DictationCommandInterpreter.interpret("looks good"),
                       .acceptLastSuggestion)
        XCTAssertEqual(DictationCommandInterpreter.interpret("reject that"),
                       .rejectLastSuggestion)
        XCTAssertEqual(DictationCommandInterpreter.interpret("discard that"),
                       .rejectLastSuggestion)
    }

    func testInterpretAIFeatures() {
        XCTAssertEqual(DictationCommandInterpreter.interpret("draft impression"),
                       .draftImpression)
        XCTAssertEqual(DictationCommandInterpreter.interpret("Vibe Impression"),
                       .draftImpression)
        XCTAssertEqual(DictationCommandInterpreter.interpret("describe view"),
                       .describeView)
        XCTAssertEqual(DictationCommandInterpreter.interpret("Describe what you see"),
                       .describeView)
    }

    func testInterpretLifecycle() {
        XCTAssertEqual(DictationCommandInterpreter.interpret("save report"),
                       .saveReport)
        XCTAssertEqual(DictationCommandInterpreter.interpret("new report"),
                       .newReport)
        XCTAssertEqual(DictationCommandInterpreter.interpret("sign off as Dr Hatem"),
                       .signOff(clinician: "Dr Hatem"))
        XCTAssertEqual(DictationCommandInterpreter.interpret("signed by jane doe"),
                       .signOff(clinician: "Jane Doe"))
    }

    func testInterpretPassthroughForRegularSpeech() {
        let raw = "The liver is normal in size."
        XCTAssertEqual(DictationCommandInterpreter.interpret(raw),
                       .passthrough(raw))
    }

    func testInterpretPassthroughForEmptyInput() {
        XCTAssertEqual(DictationCommandInterpreter.interpret(""),
                       .passthrough(""))
    }

    func testInterpretSignOffWithoutNameDoesNotMatch() {
        // "sign off as" with empty name should fall through, not produce
        // signOff("") which would silently sign anonymously.
        let raw = "sign off as"
        if case .signOff = DictationCommandInterpreter.interpret(raw) {
            XCTFail("empty sign-off name should not produce a signOff command")
        }
    }

    // MARK: - HeuristicImpressionDrafter — scoring

    func testScoreFavoursLesionLanguage() {
        let high = HeuristicImpressionDrafter.score(
            "Spiculated lesion in the right upper lobe with FDG-avid uptake."
        )
        let low = HeuristicImpressionDrafter.score(
            "Liver is unremarkable in size."
        )
        XCTAssertGreaterThan(high, low)
    }

    func testScoreNumericMeasurementsBumpScore() {
        let withMeasurement = HeuristicImpressionDrafter.score(
            "Nodule measuring 1.2 cm in the left upper lobe."
        )
        let withoutMeasurement = HeuristicImpressionDrafter.score(
            "Nodule in the left upper lobe."
        )
        XCTAssertGreaterThan(withMeasurement, withoutMeasurement)
    }

    // MARK: - HeuristicImpressionDrafter — draft

    func testDraftFromEmptyFindingsThrows() async {
        let drafter = HeuristicImpressionDrafter()
        let report = RadiologyReport()
        do {
            _ = try await drafter.draft(from: report)
            XCTFail("expected insufficientInput error")
        } catch let e as ImpressionDrafterError {
            switch e {
            case .insufficientInput: break
            default: XCTFail("expected insufficientInput, got \(e)")
            }
        } catch {
            XCTFail("expected ImpressionDrafterError, got \(error)")
        }
    }

    func testDraftReturnsAIDraftedSentence() async throws {
        let drafter = HeuristicImpressionDrafter()
        var report = RadiologyReport()
        report = RadiologyReportMutator.appendSentence(
            ReportSentence(text: "Spiculated 1.5 cm FDG-avid nodule in the right upper lobe.",
                           provenance: .dictated),
            to: .findings, in: report
        )
        let drafted = try await drafter.draft(from: report)
        XCTAssertNotNil(drafted)
        XCTAssertEqual(drafted?.provenance, .aiDrafted)
        XCTAssertTrue(drafted!.text.lowercased().contains("nodule"))
        // Always carries the verify-before-sign-off disclaimer.
        XCTAssertTrue(drafted!.text.contains("verify before sign-off"))
    }

    func testDraftFallbackWhenNothingScores() async throws {
        let drafter = HeuristicImpressionDrafter()
        var report = RadiologyReport()
        report = RadiologyReportMutator.appendSentence(
            ReportSentence(text: "Patient was supine.", provenance: .typed),
            to: .findings, in: report
        )
        let drafted = try await drafter.draft(from: report)
        XCTAssertNotNil(drafted)
        XCTAssertEqual(drafted?.provenance, .aiDrafted)
        XCTAssertTrue(drafted!.text.lowercased().contains("no acute"))
    }

    func testDraftFallbackUsesPETLanguageWhenModalityIsPET() async throws {
        let drafter = HeuristicImpressionDrafter()
        var report = RadiologyReport()
        report.metadata.modality = "PT"
        report = RadiologyReportMutator.appendSentence(
            ReportSentence(text: "Patient was supine.", provenance: .typed),
            to: .findings, in: report
        )
        let drafted = try await drafter.draft(from: report)
        XCTAssertTrue(drafted!.text.lowercased().contains("fdg"))
    }

    func testDraftCombinesMultipleHighScoringSentences() async throws {
        let drafter = HeuristicImpressionDrafter()
        var report = RadiologyReport()
        for s in [
            "Spiculated 1.5 cm FDG-avid nodule in the right upper lobe.",
            "Hypermetabolic mediastinal lymphadenopathy.",
            "New 8 mm liver lesion."
        ] {
            report = RadiologyReportMutator.appendSentence(
                ReportSentence(text: s, provenance: .dictated),
                to: .findings, in: report
            )
        }
        let drafted = try await drafter.draft(from: report)
        XCTAssertNotNil(drafted)
        // Two of three top sentences should appear (semicolons join them).
        let text = drafted!.text.lowercased()
        XCTAssertTrue(text.contains(";"), "draft should combine multiple sentences")
    }

    // MARK: - ClosureImpressionDrafter

    func testClosureDrafterCallsClosure() async throws {
        let drafter = ClosureImpressionDrafter(
            id: "stub", displayName: "Stub", isOnDevice: true
        ) { _ in
            ReportSentence(text: "Stubbed impression.", provenance: .aiDrafted)
        }
        let result = try await drafter.draft(from: RadiologyReport())
        XCTAssertEqual(result?.text, "Stubbed impression.")
    }

    // MARK: - AISuggestionAcceptor

    func testFindLastPendingReturnsNilWhenNoneExist() {
        let report = RadiologyReport()
        XCTAssertNil(AISuggestionAcceptor.findLastPending(in: report))
    }

    func testFindLastPendingReturnsMostRecentAISentence() {
        var report = RadiologyReport()
        // Older AI sentence in Findings.
        let older = ReportSentence(text: "Older", provenance: .aiDrafted)
        report = RadiologyReportMutator.appendSentence(older, to: .findings, in: report)
        // Newer AI sentence in Impression.
        let newer = ReportSentence(text: "Newer", provenance: .vlmSuggested)
        report = RadiologyReportMutator.appendSentence(newer, to: .impression, in: report)
        let result = AISuggestionAcceptor.findLastPending(in: report)
        XCTAssertEqual(result?.0, newer.id)
        XCTAssertEqual(result?.1, .impression)
    }

    func testAcceptLastPendingFlipsProvenance() {
        var report = RadiologyReport()
        let s = ReportSentence(text: "Suggested", provenance: .aiDrafted)
        report = RadiologyReportMutator.appendSentence(s, to: .impression, in: report)
        report = AISuggestionAcceptor.acceptLastPending(in: report)
        let updated = report.sections.first { $0.kind == .impression }!.sentences.first!
        XCTAssertEqual(updated.provenance, .acceptedAISuggestion)
        XCTAssertEqual(updated.text, "Suggested")
    }

    func testAcceptLastPendingNoOpWhenNoneExist() {
        let original = RadiologyReport()
        let result = AISuggestionAcceptor.acceptLastPending(in: original)
        XCTAssertEqual(result.sections.map(\.id), original.sections.map(\.id))
    }

    func testRejectLastPendingRemovesSentence() {
        var report = RadiologyReport()
        let s = ReportSentence(text: "Suggested", provenance: .aiDrafted)
        report = RadiologyReportMutator.appendSentence(s, to: .impression, in: report)
        report = AISuggestionAcceptor.rejectLastPending(in: report)
        XCTAssertTrue(report.sections.first { $0.kind == .impression }!.sentences.isEmpty)
    }

    func testDeleteLastSentenceInSection() {
        var report = RadiologyReport()
        let s1 = ReportSentence(text: "First", provenance: .dictated)
        let s2 = ReportSentence(text: "Second", provenance: .dictated)
        report = RadiologyReportMutator.appendSentence(s1, to: .findings, in: report)
        report = RadiologyReportMutator.appendSentence(s2, to: .findings, in: report)
        report = AISuggestionAcceptor.deleteLastSentence(in: .findings, of: report)
        let remaining = report.sections.first { $0.kind == .findings }!.sentences
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.text, "First")
    }

    func testDeleteLastSentenceOnEmptySectionIsNoOp() {
        let report = RadiologyReport()
        let result = AISuggestionAcceptor.deleteLastSentence(in: .impression, of: report)
        XCTAssertTrue(result.sections.first { $0.kind == .impression }!.sentences.isEmpty)
    }

    func testIsPendingSuggestion() {
        XCTAssertTrue(AISuggestionAcceptor.isPendingSuggestion(
            ReportSentence(text: "x", provenance: .aiDrafted)))
        XCTAssertTrue(AISuggestionAcceptor.isPendingSuggestion(
            ReportSentence(text: "x", provenance: .vlmSuggested)))
        XCTAssertFalse(AISuggestionAcceptor.isPendingSuggestion(
            ReportSentence(text: "x", provenance: .dictated)))
        XCTAssertFalse(AISuggestionAcceptor.isPendingSuggestion(
            ReportSentence(text: "x", provenance: .acceptedAISuggestion)))
    }

    // MARK: - StubPixelToTextSuggester

    func testStubSuggesterReturnsVLMTaggedSentence() async throws {
        let suggester = StubPixelToTextSuggester()
        let img = makeSolidImage(width: 256, height: 256)
        let result = try await suggester.suggest(
            image: img,
            context: PixelToTextContext(modality: "CT", bodyPart: "chest", sliceIndex: 42)
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.provenance, .vlmSuggested)
        XCTAssertTrue(result!.text.contains("CT"))
        XCTAssertTrue(result!.text.contains("chest"))
        XCTAssertTrue(result!.text.contains("256"))
        XCTAssertTrue(result!.text.contains("slice 42"))
    }

    func testStubSuggesterFallbackForBlankContext() async throws {
        let suggester = StubPixelToTextSuggester()
        let img = makeSolidImage(width: 64, height: 64)
        let result = try await suggester.suggest(
            image: img,
            context: PixelToTextContext()
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.text.lowercased().contains("displayed slice"))
    }

    // MARK: - ClosurePixelToTextSuggester

    func testClosureSuggesterCallsClosure() async throws {
        var capturedContext: PixelToTextContext?
        let suggester = ClosurePixelToTextSuggester(
            id: "test", displayName: "Test", isOnDevice: true
        ) { _, ctx in
            capturedContext = ctx
            return ReportSentence(text: "From closure.", provenance: .vlmSuggested)
        }
        let result = try await suggester.suggest(
            image: makeSolidImage(width: 8, height: 8),
            context: PixelToTextContext(modality: "MR", bodyPart: "brain")
        )
        XCTAssertEqual(result?.text, "From closure.")
        XCTAssertEqual(capturedContext?.modality, "MR")
        XCTAssertEqual(capturedContext?.bodyPart, "brain")
    }

    // MARK: - Helpers

    /// Build a tiny opaque CGImage so we can pump something through the
    /// suggester without depending on a DICOM volume in tests.
    private func makeSolidImage(width: Int, height: Int) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 200, count: width * height * bytesPerPixel)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 } // alpha
        let space = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}
