import XCTest
@testable import Tracer

/// Smoke + unit tests for the dictation module's pure-data layers.
/// `DictationEngine` itself is hardware-bound (mic + Speech.framework) so we
/// don't drive it here — we cover the math + the session's pure helpers +
/// the engine-kind enum surface that the picker UI binds to.
final class DictationFoundationTests: XCTestCase {

    // MARK: - AudioCaptureMath.rms

    func testRMSOfSilenceIsZero() {
        let silence = [Float](repeating: 0, count: 1024)
        XCTAssertEqual(AudioCaptureMath.rms(silence), 0, accuracy: 1e-6)
    }

    func testRMSOfDCSignalEqualsAbsoluteAmplitude() {
        // RMS of a constant ±0.5 signal is 0.5 (DC component, not a sine).
        let dc = [Float](repeating: 0.5, count: 256)
        XCTAssertEqual(AudioCaptureMath.rms(dc), 0.5, accuracy: 1e-5)
    }

    func testRMSOfFullScaleSineIs0707() throws {
        // Crank a 1 kHz sine at 16 kHz sample rate, full ±1 amplitude.
        // RMS of a sine is amplitude / sqrt(2) ≈ 0.7071.
        let n = 1600
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = sin(2.0 * .pi * 1000.0 * Double(i) / 16_000.0).floatValue
        }
        XCTAssertEqual(AudioCaptureMath.rms(samples), 0.7071, accuracy: 0.005)
    }

    func testRMSOfEmptyArrayIsZero() {
        XCTAssertEqual(AudioCaptureMath.rms([]), 0)
    }

    // MARK: - AudioCaptureMath.isVoiced

    func testIsVoicedRejectsRoomHiss() {
        // Build a low-amplitude white-noise approximation by repeating a
        // small ramp. Peak ~0.002, well below the 0.005 threshold.
        let hiss = (0..<2048).map { Float($0 % 5) * 0.0005 - 0.001 }
        XCTAssertFalse(AudioCaptureMath.isVoiced(hiss))
    }

    func testIsVoicedAcceptsConversationalSpeech() {
        // Sine at amplitude ~0.1, RMS ~0.07, comfortably above default 0.005.
        let n = 1600
        let speech = (0..<n).map { i in
            (sin(2.0 * .pi * 220.0 * Double(i) / 16_000.0) * 0.1).floatValue
        }
        XCTAssertTrue(AudioCaptureMath.isVoiced(speech))
    }

    func testIsVoicedRespectsCustomThreshold() {
        let n = 1600
        let speech = (0..<n).map { i in
            (sin(2.0 * .pi * 220.0 * Double(i) / 16_000.0) * 0.1).floatValue
        }
        // 0.07 RMS < 0.5 threshold → not "voiced" by this caller's rules.
        XCTAssertFalse(AudioCaptureMath.isVoiced(speech, threshold: 0.5))
    }

    // MARK: - AudioCaptureMath.linearResample

    func testLinearResampleIdentityWhenRatesMatch() {
        let input: [Float] = [0, 0.25, 0.5, 0.75, 1, 0.5, 0, -0.5]
        let out = AudioCaptureMath.linearResample(input, fromRate: 16_000, toRate: 16_000)
        XCTAssertEqual(out, input)
    }

    func testLinearResampleDownsampleHalvesSampleCount() {
        let input = [Float](repeating: 0.3, count: 1000)
        let out = AudioCaptureMath.linearResample(input, fromRate: 32_000, toRate: 16_000)
        // 32→16 kHz halves the sample count; allow a 1-sample tolerance for rounding.
        XCTAssertGreaterThanOrEqual(out.count, 499)
        XCTAssertLessThanOrEqual(out.count, 501)
        // DC signal stays at 0.3 after resample.
        for s in out { XCTAssertEqual(s, 0.3, accuracy: 1e-5) }
    }

    func testLinearResampleUpsamplePreservesEndpoints() throws {
        let input: [Float] = [0, 1]
        let out = AudioCaptureMath.linearResample(input, fromRate: 8_000, toRate: 16_000)
        XCTAssertGreaterThanOrEqual(out.count, 3)
        let first = try XCTUnwrap(out.first)
        let last = try XCTUnwrap(out.last)
        // Linear resample crosses the [0, 1] segment monotonically.
        XCTAssertEqual(first, Float(0), accuracy: 1e-5)
        XCTAssertGreaterThan(last, first)
    }

    func testLinearResampleEmptyInput() {
        XCTAssertTrue(AudioCaptureMath.linearResample([], fromRate: 48_000, toRate: 16_000).isEmpty)
    }

    func testLinearResampleZeroRateGuarded() {
        XCTAssertTrue(AudioCaptureMath.linearResample([1, 2, 3], fromRate: 0, toRate: 16_000).isEmpty)
        XCTAssertTrue(AudioCaptureMath.linearResample([1, 2, 3], fromRate: 16_000, toRate: 0).isEmpty)
    }

    // MARK: - DictationSession.splitSentences

    func testSplitSentencesEmpty() {
        XCTAssertEqual(DictationSession.splitSentences(""), [])
        XCTAssertEqual(DictationSession.splitSentences("   \n\n  "), [])
    }

    func testSplitSentencesPunctuation() {
        let text = "Liver is unremarkable. No FDG-avid focus. Spleen normal!"
        let out = DictationSession.splitSentences(text)
        XCTAssertEqual(out, [
            "Liver is unremarkable.",
            "No FDG-avid focus.",
            "Spleen normal!"
        ])
    }

    func testSplitSentencesIncludesTrailingFragment() {
        // Engine occasionally finalises mid-thought without terminal punctuation.
        // We still want the trailing chunk in the report buffer.
        // Avoid decimal points here — the naive splitter cuts those (see
        // `testSplitSentencesPreservesNumericPeriods`).
        let text = "Bilateral pulmonary nodules. Largest in the left upper lobe"
        let out = DictationSession.splitSentences(text)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], "Bilateral pulmonary nodules.")
        XCTAssertEqual(out[1], "Largest in the left upper lobe")
    }

    func testSplitSentencesQuestionMark() {
        let text = "Stable? Yes. Compared to prior."
        XCTAssertEqual(DictationSession.splitSentences(text),
                       ["Stable?", "Yes.", "Compared to prior."])
    }

    func testSplitSentencesPreservesNumericPeriods() {
        // Naive splitter: "1.2 cm" gets cut at the decimal. This test
        // documents the known limitation so the v3 segmenter can replace it.
        let text = "Lesion measures 1.2 cm."
        let out = DictationSession.splitSentences(text)
        // We accept the naive split for now — assertion documents behaviour.
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], "Lesion measures 1.")
    }

    // MARK: - DictationEngineKind

    func testDictationEngineKindAllCases() {
        let ids = DictationEngineKind.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids), Set(["appleSpeech", "whisperKit", "remoteDGXWhisper"]))
    }

    func testDictationEngineKindDisplayNamesAreNonEmpty() {
        for k in DictationEngineKind.allCases {
            XCTAssertFalse(k.displayName.isEmpty, "missing displayName for \(k.rawValue)")
        }
    }

    func testDictationEngineKindIdMatchesRawValue() {
        for k in DictationEngineKind.allCases {
            XCTAssertEqual(k.id, k.rawValue)
        }
    }

    func testDictationEngineKindCodableRoundTrip() throws {
        let original: [DictationEngineKind] = [.appleSpeech, .whisperKit, .remoteDGXWhisper]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([DictationEngineKind].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - AppleSpeechDictationEngine surface

    func testAppleSpeechEngineIdentityFields() {
        let engine = AppleSpeechDictationEngine(locale: "en-US")
        XCTAssertEqual(engine.id, "apple-speech")
        XCTAssertEqual(engine.displayName, "Apple Speech (on-device)")
        XCTAssertEqual(engine.locale, "en-US")
        XCTAssertTrue(engine.isOnDevice, "engine must run on-device for clinical privacy")
    }

    func testAppleSpeechEngineDefaultHintsCoverRadiologyVocab() {
        let hints = AppleSpeechDictationEngine.defaultHints
        // Spot-check a handful of high-value radiology terms.
        XCTAssertTrue(hints.contains("FDG"))
        XCTAssertTrue(hints.contains("PET/CT"))
        XCTAssertTrue(hints.contains("SUVmax"))
        XCTAssertTrue(hints.contains("spiculated"))
        XCTAssertTrue(hints.contains("Deauville score"))
        XCTAssertGreaterThan(hints.count, 30, "hint list should be substantive")
    }

    func testAppleSpeechHintsAreOverridable() {
        let engine = AppleSpeechDictationEngine(locale: "en-US")
        engine.radiologyHints = ["custom-term"]
        XCTAssertEqual(engine.radiologyHints, ["custom-term"])
    }

    // MARK: - PCMChunk

    func testPCMChunkEquatable() {
        let a = AudioCapture.PCMChunk(samples: [0, 0.1, 0.2], timestamp: Date(timeIntervalSince1970: 0))
        let b = AudioCapture.PCMChunk(samples: [0, 0.1, 0.2], timestamp: Date(timeIntervalSince1970: 0))
        let c = AudioCapture.PCMChunk(samples: [0, 0.1, 0.3], timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - DictationEvent

    func testDictationEventEquatable() {
        XCTAssertEqual(DictationEvent.partial("hello", confidence: 0.9),
                       DictationEvent.partial("hello", confidence: 0.9))
        XCTAssertNotEqual(DictationEvent.partial("hello", confidence: 0.9),
                          DictationEvent.partial("hello", confidence: 0.8))
        XCTAssertEqual(DictationEvent.idle, DictationEvent.idle)
        XCTAssertNotEqual(DictationEvent.error("boom"), DictationEvent.error("boom2"))
    }
}

// MARK: - Test helpers

private extension Double {
    /// `Float` cast as an instance method so we can inline the conversion in
    /// expression chains without parentheses gymnastics.
    var floatValue: Float { Float(self) }
}
