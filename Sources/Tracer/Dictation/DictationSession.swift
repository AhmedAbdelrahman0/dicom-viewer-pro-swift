import Foundation
import SwiftUI
import CoreGraphics

/// MainActor orchestrator for an active dictation session — wires the
/// `AudioCapture` pipeline to a `DictationEngine` and republishes the
/// transcription stream as `@Published` state for SwiftUI.
///
/// Lifecycle:
///   1. `start()` requests permission, starts capture, kicks the engine.
///   2. PCM chunks flow capture → engine → transcription events.
///   3. Partials replace `partialTranscript`; finals append to `finalTranscript`.
///   4. `stop()` flushes the engine, drains a final result, ends capture.
///   5. `cancel()` aborts everything; throws away any pending text.
///
/// The session is the **only** dictation state SwiftUI sees. The engine
/// is swappable (`AppleSpeechDictationEngine` today, `WhisperKit` when
/// we add it) but the panel binds to `DictationSession` regardless.
@MainActor
public final class DictationSession: ObservableObject {

    @Published public private(set) var isRecording: Bool = false
    /// Running partial transcription — replace-on-update, not append.
    /// Cleared when a final event arrives.
    @Published public private(set) var partialTranscript: String = ""
    /// Accumulated finalised text. Sentences end with the punctuation
    /// the engine emits (Apple Speech adds it on macOS 13+; Whisper
    /// emits punctuation natively).
    @Published public private(set) var finalTranscript: String = ""
    /// Live RMS level for a VU meter. 0 = silence, ~0.5 = loud speech.
    @Published public private(set) var inputLevel: Float = 0
    /// User-facing error / status message. Cleared on next `start()`.
    @Published public var statusMessage: String = ""
    /// Engine description for the UI badge.
    @Published public private(set) var engineDescription: String = ""

    public let capture: AudioCapture
    private(set) var engine: DictationEngine

    /// Optional report binding. When set, finalised dictation sentences
    /// are routed to `report.appendSentence(_:to:activeSection)` and the
    /// macro engine is consulted for trigger detection. The session still
    /// publishes `finalTranscript` so existing callers / tests don't have
    /// to know about the report layer.
    public weak var reportStore: RadiologyReportStore?
    public var macros: MacroEngine = MacroEngine()
    /// Section incoming sentences land in. Defaults to `.findings`; the
    /// command parser updates this when the user dictates ".section
    /// impression" / "section impression".
    @Published public var activeSection: ReportSection.Kind = .findings

    /// Drafter used for the "draft impression" voice command and the
    /// panel's `Draft Impression` button. Heuristic by default; callers
    /// swap in MedGemma / DGX-Whisper drafters via `setImpressionDrafter`.
    public private(set) var impressionDrafter: ImpressionDrafter = HeuristicImpressionDrafter()
    /// Suggester used for "describe view". Stub by default — wired into
    /// MedGemma vision in a later commit. Optional `imageProvider`
    /// closure injected by the panel: returns the current viewport
    /// CGImage or nil if no slice is loaded.
    public private(set) var pixelToText: PixelToTextSuggester = StubPixelToTextSuggester()
    public var imageProvider: (@Sendable () -> (image: CGImage,
                                                context: PixelToTextContext)?)? = nil

    private var captureTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    public init(engine: DictationEngine = AppleSpeechDictationEngine(),
                capture: AudioCapture = AudioCapture()) {
        self.engine = engine
        self.capture = capture
        self.engineDescription = engine.displayName
    }

    /// Hot-swap the engine. Tearing down a running session is the
    /// caller's responsibility (we'd lose the in-flight transcript
    /// otherwise). Use this from the engine picker in the panel.
    public func setEngine(_ newEngine: DictationEngine) {
        guard !isRecording else {
            statusMessage = "Stop dictation before switching engines."
            return
        }
        eventTask?.cancel()
        eventTask = nil
        captureTask?.cancel()
        captureTask = nil
        engine = newEngine
        engineDescription = newEngine.displayName
    }

    // MARK: - Lifecycle

    /// Start a session. Requests mic permission, kicks the engine,
    /// pumps PCM chunks through it. Errors land in `statusMessage`.
    public func start() async {
        guard !isRecording else { return }
        statusMessage = ""
        partialTranscript = ""
        // Don't clear finalTranscript — successive push-to-talk presses
        // accumulate into the same report buffer until the user explicitly
        // resets via `clearTranscripts()`.

        do {
            try await capture.requestPermission()
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        do {
            try await engine.start()
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        do {
            try capture.start()
        } catch {
            await engine.cancel()
            statusMessage = error.localizedDescription
            return
        }

        isRecording = true
        startPumps()
    }

    /// Tell the engine the user has finished speaking. The engine
    /// flushes its buffer and emits one final event before idling.
    /// Capture stops immediately; we keep the event pump alive long
    /// enough to receive the trailing final result.
    public func stop() async {
        guard isRecording else { return }
        isRecording = false
        capture.stop()
        await engine.finish()
    }

    /// Hard-cancel; throw away anything pending.
    public func cancel() async {
        if isRecording {
            isRecording = false
            capture.stop()
        }
        captureTask?.cancel()
        captureTask = nil
        eventTask?.cancel()
        eventTask = nil
        await engine.cancel()
        partialTranscript = ""
    }

    /// Wipe both buffers — used when starting a new report or when the
    /// user clicks "Clear" in the panel.
    public func clearTranscripts() {
        partialTranscript = ""
        finalTranscript = ""
    }

    // MARK: - Pumps

    private func startPumps() {
        captureTask?.cancel()
        let captureStream = capture.chunks
        let engineRef = engine

        captureTask = Task { [weak self] in
            for await chunk in captureStream {
                if Task.isCancelled { break }
                await engineRef.feed(chunk.samples)
                let rms = AudioCaptureMath.rms(chunk.samples)
                await MainActor.run { [weak self] in
                    self?.inputLevel = rms
                }
            }
        }

        guard eventTask == nil else { return }
        let eventStream = engine.events
        eventTask = Task { [weak self] in
            for await event in eventStream {
                if Task.isCancelled { break }
                await MainActor.run { [weak self] in
                    self?.handle(event: event)
                }
            }
        }
    }

    private func handle(event: DictationEvent) {
        switch event {
        case .partial(let text, _):
            partialTranscript = text
        case .final(let text, let confidence):
            // Engines vary on whether they re-emit the whole utterance
            // or just the delta. Apple Speech sends the cumulative
            // utterance — we replace the partial then append it as a
            // sentence to the final buffer.
            partialTranscript = ""
            if !finalTranscript.isEmpty,
               !finalTranscript.hasSuffix(" "),
               !text.hasPrefix(" ") {
                finalTranscript.append(" ")
            }
            finalTranscript.append(text)
            routeFinal(text: text, confidence: confidence)
        case .idle:
            partialTranscript = ""
            inputLevel = 0
        case .error(let message):
            statusMessage = message
        }
    }

    /// Route a finalised utterance through the command interpreter and
    /// then into the report buffer. Five branches:
    ///   1. No report bound → just keep `finalTranscript` (legacy mode).
    ///   2. Recognised command (DictationCommandInterpreter) → execute
    ///      the local side effect and skip writing.
    ///   3. Starts with a macro trigger → expand and append.
    ///   4. Pure-passthrough text → single dictated sentence in active
    ///      section.
    private func routeFinal(text: String, confidence: Double?) {
        guard let store = reportStore else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let command = DictationCommandInterpreter.interpret(trimmed)
        switch command {
        case .switchSection(let kind):
            activeSection = kind
            statusMessage = "Section: \(kind.rawValue)"
        case .deleteLastSentence:
            store.applyMutation { current in
                AISuggestionAcceptor.deleteLastSentence(in: self.activeSection, of: current)
            }
            statusMessage = "Deleted last sentence in \(activeSection.rawValue)."
        case .acceptLastSuggestion:
            store.applyMutation { current in
                AISuggestionAcceptor.acceptLastPending(in: current)
            }
            statusMessage = "Accepted last suggestion."
        case .rejectLastSuggestion:
            store.applyMutation { current in
                AISuggestionAcceptor.rejectLastPending(in: current)
            }
            statusMessage = "Rejected last suggestion."
        case .draftImpression:
            Task { await self.draftImpressionRequested() }
        case .describeView:
            Task { await self.describeViewRequested() }
        case .saveReport:
            store.save()
        case .signOff(let clinician):
            store.signOff(by: clinician)
            statusMessage = "Signed off as \(clinician)."
        case .newReport:
            store.resetToBlank()
        case .passthrough(let raw):
            handlePassthrough(raw, confidence: confidence, store: store)
        }
    }

    private func handlePassthrough(_ trimmed: String,
                                   confidence: Double?,
                                   store: RadiologyReportStore) {
        if let (macro, remainder) = macros.detectTrigger(in: trimmed) {
            let macroRef = macro
            store.applyMutation { current in
                self.macros.apply(macroRef, to: current)
            }
            if !remainder.isEmpty {
                let extra = ReportSentence(
                    text: remainder,
                    provenance: .dictated,
                    confidence: confidence
                )
                store.appendSentence(extra, to: activeSection)
            }
            statusMessage = "Macro: \(macro.displayName)"
            return
        }

        let sentence = ReportSentence(
            text: trimmed,
            provenance: .dictated,
            confidence: confidence
        )
        store.appendSentence(sentence, to: activeSection)
    }

    // MARK: - AI feature setters

    public func setImpressionDrafter(_ drafter: ImpressionDrafter) {
        impressionDrafter = drafter
    }

    public func setPixelToTextSuggester(_ suggester: PixelToTextSuggester) {
        pixelToText = suggester
    }

    // MARK: - AI feature triggers

    /// Run the drafter on the current report and append the result into
    /// the Impression section. Surfaced both via "draft impression" voice
    /// command and the panel's button.
    public func draftImpressionRequested() async {
        guard let store = reportStore else {
            statusMessage = "No report — start dictating to draft an impression."
            return
        }
        statusMessage = "Drafting impression…"
        do {
            guard let suggestion = try await impressionDrafter.draft(from: store.report) else {
                statusMessage = "Drafter declined — not enough Findings yet."
                return
            }
            store.appendSentence(suggestion, to: .impression)
            statusMessage = "Drafted impression — review before accepting."
        } catch let e as ImpressionDrafterError {
            statusMessage = e.errorDescription ?? "Impression draft failed."
        } catch {
            statusMessage = "Impression draft failed: \(error.localizedDescription)"
        }
    }

    /// Run the pixel-to-text suggester on the current viewport image and
    /// append the result into the Findings section. Requires
    /// `imageProvider` to be set; otherwise reports a friendly status.
    public func describeViewRequested() async {
        guard let store = reportStore else {
            statusMessage = "No report — open a report first."
            return
        }
        guard let provider = imageProvider, let snap = provider() else {
            statusMessage = "No viewport image available — load a study first."
            return
        }
        statusMessage = "Describing view…"
        do {
            guard let suggestion = try await pixelToText.suggest(image: snap.image,
                                                                 context: snap.context) else {
                statusMessage = "Suggester returned no description."
                return
            }
            store.appendSentence(suggestion, to: .findings)
            statusMessage = "Suggestion drafted — review before accepting."
        } catch let e as PixelToTextSuggesterError {
            statusMessage = e.errorDescription ?? "Pixel-to-text failed."
        } catch {
            statusMessage = "Pixel-to-text failed: \(error.localizedDescription)"
        }
    }

    /// Recognise voice section-switch commands. Returns nil when the text
    /// is normal dictation. Forms accepted (case-insensitive):
    ///   "section impression"
    ///   "switch to impression"
    ///   "go to findings"
    /// Section names match `ReportSection.Kind` raw values plus a few
    /// common aliases ("history" → clinicalHistory).
    /// `nonisolated` — pure string parsing, no actor state.
    public nonisolated static func parseSectionCommand(_ raw: String) -> ReportSection.Kind? {
        let cleaned = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let prefixes = ["section ", "switch to ", "go to "]
        var body: String? = nil
        for p in prefixes where cleaned.hasPrefix(p) {
            body = String(cleaned.dropFirst(p.count))
            break
        }
        guard let target = body?.trimmingCharacters(in: .whitespaces),
              !target.isEmpty else { return nil }
        switch target {
        case "history", "clinical history": return .clinicalHistory
        case "technique":                   return .technique
        case "comparison":                  return .comparison
        case "findings":                    return .findings
        case "impression":                  return .impression
        case "recommendations", "recommendation":
                                            return .recommendations
        default: return nil
        }
    }

    /// Convenience: split the accumulated final transcript into
    /// sentences for downstream report-section assignment. Naive split
    /// on `.`, `?`, `!` — enough for triage; the v3 report editor will
    /// have a smarter sentence segmenter.
    public func sentences() -> [String] {
        DictationSession.splitSentences(finalTranscript)
    }

    /// Static + pure for testability. `nonisolated` so off-main callers
    /// (XCTest harness, future report-formatter background tasks) can use
    /// it without hopping onto the main actor for what is just a
    /// character-by-character loop.
    public nonisolated static func splitSentences(_ raw: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for ch in raw {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let trail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trail.isEmpty { sentences.append(trail) }
        return sentences
    }
}
