import Foundation

/// Dictation engine backed by Google's public MedASR model through a
/// local worker process.
///
/// MedASR is not exposed as a native Apple streaming recogniser. Tracer
/// therefore buffers the active push-to-talk utterance, writes one 16 kHz
/// mono WAV when the user presses Stop, and asks a Python worker to return
/// JSON: `{ "text": "...", "confidence": 0.92 }`.
public final class GoogleMedASRDictationEngine: DictationEngine, @unchecked Sendable {
    public static let defaultModelIdentifier = "google/medasr"
    public static let defaultDevice = "auto"

    public let id: String = "google-medasr"
    public let displayName: String
    public let locale: String
    public var isOnDevice: Bool { configuration.runsLocally }

    public private(set) var events: AsyncStream<DictationEvent>
    private var eventsContinuation: AsyncStream<DictationEvent>.Continuation?

    public var configuration: GoogleMedASRConfiguration

    private let lock = NSLock()
    private var active = false
    private var samples: [Float] = []
    private var activeWorker: WorkerProcess?
    private let makeWorker: @Sendable () -> WorkerProcess

    public init(configuration: GoogleMedASRConfiguration = GoogleMedASRConfiguration(),
                workerFactory: @escaping @Sendable () -> WorkerProcess = { LocalWorkerProcess() }) {
        self.configuration = configuration
        self.locale = configuration.locale
        self.displayName = "Google MedASR (\(configuration.modelIdentifier))"
        self.makeWorker = workerFactory
        var c: AsyncStream<DictationEvent>.Continuation!
        self.events = AsyncStream<DictationEvent> { c = $0 }
        self.eventsContinuation = c
    }

    public func start() async throws {
        let canStart = lock.withLock {
            if active { return false }
            active = true
            samples.removeAll(keepingCapacity: true)
            return true
        }
        guard canStart else {
            throw DictationEngineError.sessionAlreadyActive
        }
        guard resolvedScriptPath() != nil else {
            lock.withLock { active = false }
            throw DictationEngineError.engineUnavailable(
                "MedASR worker script not found. Set the script path or keep workers/medasr/transcribe_medasr.py beside Tracer."
            )
        }
    }

    public func feed(_ pcm: [Float]) async {
        guard !pcm.isEmpty else { return }
        lock.withLock {
            guard active else { return }
            let maxSamples = max(1, Int(configuration.maxAudioSeconds * AudioCapture.canonicalSampleRate))
            let available = max(0, maxSamples - samples.count)
            guard available > 0 else { return }
            samples.append(contentsOf: pcm.prefix(available))
        }
    }

    public func finish() async {
        let utterance = lock.withLock { () -> [Float] in
            let value = samples
            samples.removeAll(keepingCapacity: true)
            return value
        }
        guard !utterance.isEmpty else {
            lock.withLock { active = false }
            eventsContinuation?.yield(.idle)
            return
        }
        guard let scriptPath = resolvedScriptPath() else {
            lock.withLock { active = false }
            eventsContinuation?.yield(.error("MedASR worker script not found."))
            eventsContinuation?.yield(.idle)
            return
        }

        do {
            let result = try await runWorker(samples: utterance, scriptPath: scriptPath)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                eventsContinuation?.yield(.final(text, confidence: result.confidence))
            }
        } catch WorkerProcessError.cancelled {
            // User cancelled; idle silently.
        } catch let error as DictationEngineError {
            eventsContinuation?.yield(.error(error.localizedDescription))
        } catch {
            eventsContinuation?.yield(.error("MedASR transcription failed: \(error.localizedDescription)"))
        }

        lock.withLock {
            active = false
            activeWorker = nil
        }
        eventsContinuation?.yield(.idle)
    }

    public func cancel() async {
        let worker = lock.withLock { () -> WorkerProcess? in
            active = false
            samples.removeAll(keepingCapacity: true)
            let current = activeWorker
            activeWorker = nil
            return current
        }
        worker?.cancel()
        eventsContinuation?.yield(.idle)
    }

    private func runWorker(samples: [Float], scriptPath: String) async throws -> MedASRTranscriptionResult {
        let workingDirectory = try Self.makeWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let inputURL = workingDirectory.appendingPathComponent("utterance.wav")
        let outputURL = workingDirectory.appendingPathComponent("result.json")
        try PCM16WAVEncoder.write(samples: samples,
                                  sampleRate: Int(AudioCapture.canonicalSampleRate),
                                  to: inputURL)

        let worker = makeWorker()
        lock.withLock { activeWorker = worker }
        var env = ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment)
        env.merge(configuration.environment) { _, new in new }

        let request = WorkerProcessRequest(
            executablePath: configuration.pythonExecutablePath,
            arguments: configuration.workerArguments(scriptPath: scriptPath,
                                                     inputPath: inputURL.path,
                                                     outputPath: outputURL.path),
            environment: env,
            workingDirectory: workingDirectory,
            timeoutSeconds: configuration.timeoutSeconds,
            streamStdout: false,
            streamStderr: true
        )
        let processResult = try await worker.run(request) { [weak self] line in
            self?.eventsContinuation?.yield(.partial(line, confidence: nil))
        }
        let data: Data
        if FileManager.default.fileExists(atPath: outputURL.path) {
            data = try Data(contentsOf: outputURL)
        } else if !processResult.stdoutData.isEmpty {
            data = processResult.stdoutData
        } else {
            throw DictationEngineError.engineFailed("MedASR worker produced no JSON output.")
        }
        return try JSONDecoder().decode(MedASRTranscriptionResult.self, from: data)
    }

    private func resolvedScriptPath() -> String? {
        if let configured = configuration.scriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
        }
        return Self.defaultScriptCandidates().first { FileManager.default.fileExists(atPath: $0) }
    }

    public static func defaultScriptCandidates() -> [String] {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["TRACER_MEDASR_SCRIPT"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append((env as NSString).expandingTildeInPath)
        }
        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(URL(fileURLWithPath: cwd)
            .appendingPathComponent("workers/medasr/transcribe_medasr.py").path)
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL
                .appendingPathComponent("Workers/medasr/transcribe_medasr.py").path)
            candidates.append(resourceURL
                .appendingPathComponent("medasr/transcribe_medasr.py").path)
        }
        return candidates
    }

    private static func makeWorkingDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-medasr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

public struct GoogleMedASRConfiguration: Equatable, Codable, Sendable {
    public var pythonExecutablePath: String
    public var scriptPath: String?
    public var modelIdentifier: String
    public var device: String
    public var backend: String
    public var dtype: String
    public var locale: String
    public var timeoutSeconds: TimeInterval
    public var maxAudioSeconds: TimeInterval
    public var environment: [String: String]
    public var runsLocally: Bool

    public init(pythonExecutablePath: String = "/usr/bin/env",
                scriptPath: String? = nil,
                modelIdentifier: String = GoogleMedASRDictationEngine.defaultModelIdentifier,
                device: String = GoogleMedASRDictationEngine.defaultDevice,
                backend: String = "direct",
                dtype: String = "auto",
                locale: String = "en-US",
                timeoutSeconds: TimeInterval = 180,
                maxAudioSeconds: TimeInterval = 300,
                environment: [String: String] = [:],
                runsLocally: Bool = true) {
        self.pythonExecutablePath = pythonExecutablePath
        self.scriptPath = scriptPath
        self.modelIdentifier = modelIdentifier
        self.device = device
        self.backend = backend
        self.dtype = dtype
        self.locale = locale
        self.timeoutSeconds = timeoutSeconds
        self.maxAudioSeconds = maxAudioSeconds
        self.environment = environment
        self.runsLocally = runsLocally
    }

    public func workerArguments(scriptPath: String,
                                inputPath: String,
                                outputPath: String) -> [String] {
        let executableName = URL(fileURLWithPath: pythonExecutablePath).lastPathComponent
        var args: [String]
        if pythonExecutablePath == "/usr/bin/env" {
            args = ["python3", scriptPath]
        } else if executableName.hasPrefix("python") {
            args = [scriptPath]
        } else {
            args = []
        }
        args.append(contentsOf: [
            "--input", inputPath,
            "--output-json", outputPath,
            "--model", modelIdentifier,
            "--device", device,
            "--backend", backend,
            "--dtype", dtype
        ])
        return args
    }

    public static func parseEnvironmentLines(_ raw: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = value
        }
        return env
    }
}

public struct MedASRTranscriptionResult: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Double?

    public init(text: String, confidence: Double? = nil) {
        self.text = text
        self.confidence = confidence
    }
}

public enum PCM16WAVEncoder {
    public static func data(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        let payloadBytes = UInt32(samples.count * MemoryLayout<Int16>.size)
        appendASCII("RIFF", to: &data)
        appendUInt32LE(36 + payloadBytes, to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt16LE(channelCount, to: &data)
        appendUInt32LE(UInt32(sampleRate), to: &data)
        appendUInt32LE(byteRate, to: &data)
        appendUInt16LE(blockAlign, to: &data)
        appendUInt16LE(bitsPerSample, to: &data)
        appendASCII("data", to: &data)
        appendUInt32LE(payloadBytes, to: &data)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            let intSample = Int16((clipped * Float(Int16.max)).rounded())
            appendInt16LE(intSample, to: &data)
        }
        return data
    }

    public static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        try data(samples: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
    }

    private static func appendASCII(_ text: String, to data: inout Data) {
        data.append(contentsOf: text.utf8)
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendInt16LE(_ value: Int16, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
