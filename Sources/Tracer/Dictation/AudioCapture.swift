import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Microphone capture pipeline that produces 16 kHz mono Float32 PCM
/// chunks suitable for any `DictationEngine`. The pipeline:
///
/// ```
/// [AVAudioEngine input @ device-native rate]
///     ─→ tap (4096-sample buffers)
///     ─→ AVAudioConverter (resample to 16 kHz, downmix to mono, F32)
///     ─→ async stream of [Float] chunks
/// ```
///
/// Push-to-talk pattern: the panel calls `start()` when the user holds
/// the dictation key, `stop()` when they release. The engine receives
/// audio via the chunk stream and emits transcription events on its own
/// stream. We deliberately don't try to "stream forever" — Whisper-style
/// engines work better on bounded utterances, and SFSpeechRecognizer
/// caps at ~60 s sessions anyway.
///
/// Instantiation is `Sendable`-friendly so a `DictationSession` actor
/// can own one. The actual `AVAudioEngine` operations happen on
/// AVFoundation's audio thread, but the public surface area is
/// thread-safe (mutations gated by an internal lock).
///
/// **Permissions** (must be set on the main app target):
///   • `NSMicrophoneUsageDescription` — required for `requestAccess`.
///   • App Sandbox: enable `com.apple.security.device.audio-input`.
public final class AudioCapture: @unchecked Sendable {

    /// Format the engine emits, regardless of the device's native rate.
    /// Whisper / Apple Speech both want this exact shape.
    public static let canonicalSampleRate: Double = 16_000
    public static let canonicalChannels: AVAudioChannelCount = 1

    public enum CaptureError: Swift.Error, LocalizedError, Sendable {
        case permissionDenied
        case audioEngineFailed(String)
        case formatMismatch(String)
        case alreadyRunning
        case notRunning

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is denied. Allow Tracer in System Settings → Privacy & Security → Microphone."
            case .audioEngineFailed(let m):
                return "Audio engine failed: \(m)"
            case .formatMismatch(let m):
                return "Microphone format mismatch: \(m)"
            case .alreadyRunning:
                return "Audio capture is already running."
            case .notRunning:
                return "Audio capture isn't running."
            }
        }
    }

    /// One captured chunk: 16 kHz mono Float32 PCM. Length varies (it's
    /// roughly proportional to the device buffer size + resample ratio,
    /// typically ~1300 samples per buffer when the mic is at 48 kHz).
    public struct PCMChunk: Sendable, Equatable {
        public let samples: [Float]
        public let timestamp: Date

        public init(samples: [Float], timestamp: Date = Date()) {
            self.samples = samples
            self.timestamp = timestamp
        }
    }

    #if canImport(AVFoundation)
    private let engine = AVAudioEngine()
    #endif

    private let lock = NSLock()
    private var running = false
    private var continuation: AsyncStream<PCMChunk>.Continuation?

    /// Stream the consumer reads chunks from. Created fresh on each
    /// `start()` call so the consumer can simply `for await chunk in
    /// capture.chunks` without juggling lifetimes.
    public private(set) var chunks: AsyncStream<PCMChunk>

    public init() {
        var localContinuation: AsyncStream<PCMChunk>.Continuation!
        self.chunks = AsyncStream<PCMChunk> { continuation in
            localContinuation = continuation
        }
        self.continuation = localContinuation
    }

    // MARK: - Permission

    /// Asks the OS for microphone access (idempotent — returns the
    /// cached answer if already granted/denied). Throws on denial.
    public func requestPermission() async throws {
        #if canImport(AVFoundation)
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if !granted { throw CaptureError.permissionDenied }
        #endif
    }

    // MARK: - Lifecycle

    /// Start the audio engine + tap. Throws if permission isn't granted
    /// or the engine refuses to start. Subsequent `chunks` reads will
    /// see PCM until `stop()` is called.
    public func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            throw CaptureError.alreadyRunning
        }
        running = true
        lock.unlock()

        #if canImport(AVFoundation)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let canonicalFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.canonicalSampleRate,
            channels: Self.canonicalChannels,
            interleaved: false
        ) else {
            throw CaptureError.formatMismatch("could not build 16 kHz mono Float32 format")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: canonicalFormat) else {
            throw CaptureError.formatMismatch(
                "no converter from \(inputFormat) to 16 kHz mono"
            )
        }

        // Tap delivers in input-device chunks (typically 4096 frames at
        // 48 kHz). We resample each tap to canonical and emit one PCMChunk.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            self.handleTap(buffer: buffer,
                           inputFormat: inputFormat,
                           canonicalFormat: canonicalFormat,
                           converter: converter)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock()
            running = false
            lock.unlock()
            throw CaptureError.audioEngineFailed(error.localizedDescription)
        }
        #endif
    }

    /// Stop the engine + tap. Idempotent; calling on a stopped engine
    /// is a no-op. Finishes the chunk stream so consumers `for await`
    /// loops exit naturally.
    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        lock.unlock()

        #if canImport(AVFoundation)
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        #endif

        continuation?.finish()
        // Reset the stream for the next session.
        var newContinuation: AsyncStream<PCMChunk>.Continuation!
        chunks = AsyncStream<PCMChunk> { c in newContinuation = c }
        continuation = newContinuation
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: - Private

    #if canImport(AVFoundation)
    /// Resample one tap buffer to canonical (16 kHz mono Float32) and
    /// emit it on the chunk stream. Errors are silently dropped — a
    /// single bad buffer is recoverable; we'd rather lose 80 ms of audio
    /// than crash the dictation session.
    private func handleTap(buffer: AVAudioPCMBuffer,
                           inputFormat: AVAudioFormat,
                           canonicalFormat: AVAudioFormat,
                           converter: AVAudioConverter) {
        // Output buffer needs enough capacity for the resample ratio.
        let ratio = canonicalFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 8)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat,
                                               frameCapacity: outCapacity) else {
            return
        }

        var error: NSError?
        var providedBuffer = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if providedBuffer {
                outStatus.pointee = .endOfStream
                return nil
            }
            providedBuffer = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil,
              let channelData = outBuffer.floatChannelData?[0],
              outBuffer.frameLength > 0 else {
            return
        }

        // Copy into a Swift array — the buffer's underlying memory will
        // be reused by AVAudioEngine on the next tap.
        let count = Int(outBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
        continuation?.yield(PCMChunk(samples: samples))
    }
    #endif
}

// MARK: - Pure-data helpers (testable without AVFoundation)

/// Resampling math + simple energy-based VAD. Both are exposed as static
/// pure functions so the test suite can exercise them without spinning
/// up an `AVAudioEngine`.
public enum AudioCaptureMath {

    /// Average sample magnitude. Used by the panel to render a live VU
    /// meter and by `AudioCapture` (future) to gate silence frames.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        return (sumSq / Float(samples.count)).squareRoot()
    }

    /// True when the chunk is louder than `threshold` (0–1 scale,
    /// linear amplitude, NOT dB). 0.005 is a reasonable default for
    /// suppressing room hiss on built-in MacBook mics.
    public static func isVoiced(_ samples: [Float],
                                threshold: Float = 0.005) -> Bool {
        rms(samples) >= threshold
    }

    /// Cheap deterministic resampler used in tests when we don't have
    /// `AVAudioConverter` available. Linear interpolation; not
    /// production-quality but fine for unit tests on synthetic input.
    public static func linearResample(_ input: [Float],
                                      fromRate: Double,
                                      toRate: Double) -> [Float] {
        guard fromRate > 0, toRate > 0, !input.isEmpty else { return [] }
        if abs(fromRate - toRate) < 1e-9 { return input }
        let ratio = toRate / fromRate
        let outCount = max(1, Int((Double(input.count) * ratio).rounded()))
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcIdx = Double(i) / ratio
            let lo = Int(srcIdx.rounded(.down))
            let hi = min(input.count - 1, lo + 1)
            let frac = Float(srcIdx - Double(lo))
            out[i] = input[lo] * (1 - frac) + input[hi] * frac
        }
        return out
    }
}
