import Foundation

/// Abstract interface for a speech-to-text engine. Tracer's dictation
/// pipeline lets the user swap engines without the panel knowing the
/// difference — Apple's first-party speech framework today, WhisperKit
/// (Argmax CoreML conversion), Google's MedASR medical ASR model through
/// a local worker, optionally a remote Whisper / Parakeet endpoint on the
/// user's DGX Spark.
///
/// The engine receives **already-decoded 16 kHz mono Float32 PCM** from
/// `AudioCapture`. It does not own the microphone. Decoupling capture
/// from recognition means we can swap engines and test each piece in
/// isolation — capture geometry is shared (tested once); engines hand
/// transcription out via a unified `AsyncStream`.
///
/// Conformers are responsible for being thread-safe for the duration of
/// a session: `start()` is called from the main actor, but `feed(_:)`
/// may be invoked from the audio capture queue (high priority, no
/// blocking allowed).
public protocol DictationEngine: AnyObject, Sendable {
    /// Stable id used in logs / cohort / preset config.
    var id: String { get }
    /// Display name surfaced in the engine picker.
    var displayName: String { get }
    /// Locale identifier (BCP-47), e.g. `"en-US"`. Some engines support
    /// only a fixed locale; the panel disables the picker when this is
    /// non-nil and not equal to the user's preference.
    var locale: String { get }
    /// `true` when this engine runs entirely on-device. The Settings
    /// panel surfaces a "Dictation stays on this Mac" badge when every
    /// active engine returns true.
    var isOnDevice: Bool { get }

    /// Begin a session. Engines that need warm-up (model load, network
    /// handshake) do it here. Returns when the engine is ready to
    /// receive PCM via `feed(_:)`. Multiple `start` calls in a row
    /// without `stop` are an error.
    func start() async throws

    /// Hand the engine a chunk of 16 kHz mono Float32 PCM. The engine
    /// decides when to emit partial / final results.
    func feed(_ pcm: [Float]) async

    /// Tell the engine the user has stopped speaking. The engine should
    /// flush its buffer and emit one final `DictationEvent` before
    /// returning.
    func finish() async

    /// Hard-cancel the current session. Discards any pending audio and
    /// any partial result. Used when the user holds Esc / clicks the
    /// red X — separate from `finish()` which commits the buffer.
    func cancel() async

    /// Stream of recognition events. Engine emits `.partial` while the
    /// user is still speaking, then a single `.final` per utterance,
    /// then `.idle` after `finish()`. Errors come through the same
    /// stream as `.error`.
    var events: AsyncStream<DictationEvent> { get }
}

/// Recognition events. Closed enum — adding new cases requires bumping
/// downstream switch statements (deliberate; the report editor needs to
/// know every state).
public enum DictationEvent: Sendable, Equatable {
    /// Engine reported a partial transcription mid-utterance. Replace
    /// any prior partial in the UI; this is the running best guess.
    case partial(String, confidence: Double?)
    /// Engine finalised an utterance. Append to the report buffer.
    case final(String, confidence: Double?)
    /// Engine is idle; either user just tapped stop or there's nothing
    /// to transcribe.
    case idle
    /// Engine produced a non-fatal error. UI surfaces the message; the
    /// session may still continue.
    case error(String)
}

public enum DictationEngineError: Swift.Error, LocalizedError, Sendable {
    case permissionDenied(String)
    case engineUnavailable(String)
    case localeUnsupported(String)
    case audioFormatUnsupported(String)
    case sessionAlreadyActive
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let m):
            return "Dictation permission denied: \(m). Grant access in System Settings → Privacy & Security."
        case .engineUnavailable(let m):
            return "Dictation engine unavailable: \(m)"
        case .localeUnsupported(let m):
            return "Dictation locale unsupported: \(m)"
        case .audioFormatUnsupported(let m):
            return "Audio format not accepted by the engine: \(m)"
        case .sessionAlreadyActive:
            return "A dictation session is already running. Stop it before starting another."
        case .engineFailed(let m):
            return "Dictation engine failed: \(m)"
        }
    }
}

/// Helpful for the engine picker / Settings UI: the canonical engine
/// kinds Tracer knows about. Concrete instances live as `DictationEngine`
/// implementations; this enum is just a string id wrapper for serialised
/// config + chat addressability.
public enum DictationEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// macOS / iOS first-party SFSpeechRecognizer with `requiresOnDeviceRecognition`.
    /// Free, no extra deps. Lower medical-vocab accuracy than Whisper.
    case appleSpeech
    /// WhisperKit (Argmax). Higher accuracy, especially on radiology
    /// vocab when seeded with an initial prompt. Adds ~50 MB model
    /// download on first launch.
    case whisperKit
    /// Google Health AI Developer Foundations MedASR through a local
    /// Python worker. Medical/radiology-focused, model-backed, and not a
    /// real-time native macOS recogniser, so Tracer buffers the utterance
    /// and finalises on Stop.
    case googleMedASR
    /// Whisper running on the user's DGX Spark over SSH. Highest accuracy
    /// (large-v3) at the cost of network latency.
    case remoteDGXWhisper

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleSpeech:        return "Apple Speech (on-device)"
        case .whisperKit:         return "WhisperKit (Apple Silicon ANE)"
        case .googleMedASR:       return "Google MedASR (medical ASR)"
        case .remoteDGXWhisper:   return "Whisper · DGX Spark (remote)"
        }
    }

    public var isImplemented: Bool {
        switch self {
        case .appleSpeech, .googleMedASR:
            return true
        case .whisperKit, .remoteDGXWhisper:
            return false
        }
    }
}
