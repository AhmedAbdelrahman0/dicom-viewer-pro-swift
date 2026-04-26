import Foundation
import SwiftUI

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
        await engine.cancel()
        // Don't await eventTask — it'll finish naturally when the
        // engine's stream emits its final event or terminates.
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
        case .final(let text, _):
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
        case .idle:
            partialTranscript = ""
            inputLevel = 0
        case .error(let message):
            statusMessage = message
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
