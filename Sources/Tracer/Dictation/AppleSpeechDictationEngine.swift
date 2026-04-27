import Foundation
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Dictation engine backed by Apple's first-party `SFSpeechRecognizer`.
/// Free, no extra dependencies, runs fully on-device when the user has
/// enabled "Listen for ‘Hey Siri’" / dictation in System Settings (which
/// downloads the offline model). Lower medical-vocabulary accuracy than
/// Whisper-class engines, but it's the right baseline for shipping
/// dictation today without bloating the app with model downloads.
///
/// The `requiresOnDeviceRecognition` flag is set so transcription never
/// hits Apple's cloud — important for clinical / research data.
///
/// Apple's recognizer wants its audio fed via `AVAudioPCMBuffer` directly
/// rather than raw Float arrays. Tracer's `DictationEngine` protocol
/// uses raw `[Float]`, so we re-wrap each chunk into a buffer with the
/// canonical format the recogniser expects (16 kHz mono Float32 — same
/// shape `AudioCapture` already produces).
public final class AppleSpeechDictationEngine: DictationEngine, @unchecked Sendable {
    public let id: String = "apple-speech"
    public let displayName: String = "Apple Speech (on-device)"
    public let locale: String
    public var isOnDevice: Bool { true }

    public private(set) var events: AsyncStream<DictationEvent>
    private var eventsContinuation: AsyncStream<DictationEvent>.Continuation?

    #if canImport(Speech)
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    #endif

    private let lock = NSLock()
    private var active = false

    /// `radiologyHints` are stuffed into `contextualStrings` so the
    /// recogniser biases towards radiology vocab without retraining.
    /// Same idea as Whisper's `initial_prompt`. Default list is small +
    /// generic; callers can extend per-institution.
    public var radiologyHints: [String] = AppleSpeechDictationEngine.defaultHints

    public init(locale: String = Locale.current.identifier) {
        self.locale = locale
        var c: AsyncStream<DictationEvent>.Continuation!
        self.events = AsyncStream<DictationEvent> { c = $0 }
        self.eventsContinuation = c

        #if canImport(Speech)
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
        #endif
    }

    public func start() async throws {
        let alreadyActive = lock.withLock { active }
        if alreadyActive {
            throw DictationEngineError.sessionAlreadyActive
        }

        #if canImport(Speech)
        guard let recognizer else {
            throw DictationEngineError.localeUnsupported(
                "no SFSpeechRecognizer for locale \(locale)"
            )
        }
        guard recognizer.isAvailable else {
            throw DictationEngineError.engineUnavailable(
                "SFSpeechRecognizer reports unavailable — make sure dictation is enabled in System Settings → Keyboard"
            )
        }

        let auth = await Self.requestSpeechAuthorization()
        switch auth {
        case .authorized: break
        case .denied:
            throw DictationEngineError.permissionDenied("speech recognition denied")
        case .restricted, .notDetermined:
            throw DictationEngineError.permissionDenied("speech recognition not authorised")
        @unknown default:
            throw DictationEngineError.permissionDenied("unknown authorisation state")
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true   // privacy: never hits Apple cloud
        if !radiologyHints.isEmpty {
            req.contextualStrings = radiologyHints
        }
        if #available(macOS 13.0, *) {
            req.addsPunctuation = true
        }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handleResult(result, error: error)
        }

        lock.withLock { active = true }
        #else
        throw DictationEngineError.engineUnavailable("Speech framework unavailable on this platform")
        #endif
    }

    public func feed(_ pcm: [Float]) async {
        #if canImport(Speech) && canImport(AVFoundation)
        guard let request else { return }
        guard !pcm.isEmpty else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.canonicalSampleRate,
            channels: AudioCapture.canonicalChannels,
            interleaved: false
        ) else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(pcm.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        if let dst = buffer.floatChannelData?[0] {
            pcm.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: pcm.count)
            }
        }
        request.append(buffer)
        #endif
    }

    public func finish() async {
        #if canImport(Speech)
        guard request != nil else {
            lock.withLock { active = false }
            eventsContinuation?.yield(.idle)
            return
        }
        request?.endAudio()
        // Keep the engine active until Speech delivers its final result
        // or an error. This prevents a fast stop/start from mixing the
        // previous utterance into the next recording session.
        #endif
    }

    public func cancel() async {
        lock.withLock { active = false }
        #if canImport(Speech)
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        #endif
        eventsContinuation?.yield(.idle)
    }

    // MARK: - Private

    #if canImport(Speech)
    private func handleResult(_ result: SFSpeechRecognitionResult?,
                              error: Error?) {
        if let error {
            // SFSpeechRecognitionTask returns an error when the user
            // calls cancel() too — guard so we don't surface that as a
            // user-facing message.
            let nsError = error as NSError
            let cancelled = (nsError.domain == "kAFAssistantErrorDomain"
                             || nsError.localizedDescription.lowercased().contains("cancel"))
            if !cancelled {
                eventsContinuation?.yield(.error(error.localizedDescription))
            }
            cleanupRecognitionSession()
            eventsContinuation?.yield(.idle)
            return
        }
        guard let result else { return }
        let text = result.bestTranscription.formattedString
        let confidences = result.bestTranscription.segments.map { Double($0.confidence) }
        let mean: Double? = {
            guard !confidences.isEmpty else { return nil }
            return confidences.reduce(0, +) / Double(confidences.count)
        }()
        if result.isFinal {
            eventsContinuation?.yield(.final(text, confidence: mean))
            cleanupRecognitionSession()
            eventsContinuation?.yield(.idle)
        } else {
            eventsContinuation?.yield(.partial(text, confidence: mean))
        }
    }

    private func cleanupRecognitionSession() {
        lock.withLock { active = false }
        task = nil
        request = nil
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
    #endif

    /// Default radiology vocab hints. Short list of frequently-mistran-
    /// scribed terms; users add more via the Dictation settings panel.
    /// Hints don't lock the recogniser's vocabulary — they bias it.
    public static let defaultHints: [String] = [
        // Modalities + acquisitions
        "FDG", "PET", "PET/CT", "MRI", "DWI", "ADC",
        "T1-weighted", "T2-weighted", "FLAIR",
        "iodinated contrast", "gadolinium",
        // Common organ anatomy
        "mediastinum", "hilum", "pleura", "pericardium",
        "porta hepatis", "retroperitoneum", "mesentery",
        // Lesion descriptors
        "spiculated", "hypoechoic", "hyperechoic", "isoechoic",
        "hypoenhancing", "hyperenhancing",
        "FDG-avid", "non-FDG-avid",
        "lytic lesion", "sclerotic lesion",
        // Measurements
        "SUVmax", "SUVmean", "SUVpeak", "TMTV",
        "Hounsfield units",
        // Common reporting phrases
        "no evidence of disease",
        "stable disease compared to prior",
        "complete metabolic response",
        "partial metabolic response",
        "progressive metabolic disease",
        "Deauville score",
        // Organs
        "liver", "spleen", "pancreas", "adrenal gland",
        "kidney", "bladder", "prostate", "uterus", "ovary",
        "thyroid", "parotid", "submandibular gland",
    ]
}

#if !canImport(Speech)
// On platforms without Speech (e.g. Linux test runners), provide a stub
// authorisation status so this file still compiles for unit testing the
// surrounding modules. The init throws on `start()` via `engineUnavailable`.
public enum SFSpeechRecognizerAuthorizationStatus {
    case notDetermined, restricted, denied, authorized
}
#endif
