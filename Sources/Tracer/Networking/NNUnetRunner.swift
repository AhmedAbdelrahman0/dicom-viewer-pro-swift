import Foundation

/// Run **nnU-Net v2** inference on an `ImageVolume` by shelling out to the
/// `nnUNetv2_predict` CLI installed in the user's Python environment.
///
/// This is the most efficient integration path for a macOS Swift app because:
///   • it uses the user's existing PyTorch install (Apple-Silicon MPS or CUDA),
///   • it avoids bundling / converting each model to CoreML,
///   • it runs fully offline — no server required,
///   • it benefits automatically as new nnU-Net releases ship.
///
/// The runner:
///   1. Writes the current volume to a temp directory as a NIfTI file named
///      `<caseID>_0000.nii.gz` (nnU-Net's required "channel-0" convention;
///      single-modality models expect one file per case).
///   2. Invokes `nnUNetv2_predict -i <inDir> -o <outDir> -d <datasetID>`
///      `-c <configuration> -f <foldsCSV> [-chk <checkpoint>] --disable_tta`.
///   3. Reads the resulting `<caseID>.nii.gz` label file back into a `LabelMap`.
///   4. Optionally re-maps label IDs to human-readable class names using the
///      model's `dataset.json` labels.
///
/// Cancellable: call `cancel()` mid-run to send the child process a SIGINT.
/// On cancel the method throws `.cancelled` and cleans up temp files.
public final class NNUnetRunner: @unchecked Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Path to the `nnUNetv2_predict` binary. Defaults to the plain name;
        /// the runner will search `PATH` and a few conventional locations
        /// (`/opt/homebrew/bin`, `~/miniforge3/envs/nnunet/bin`, etc.).
        public var predictBinaryPath: String?

        /// `nnUNet_results` environment variable value — where model weights
        /// live. Required unless the user has exported it globally.
        public var resultsDir: URL?
        public var rawDir: URL?
        public var preprocessedDir: URL?

        /// Inference configuration: `"3d_fullres"`, `"3d_lowres"`, `"2d"`, or
        /// `"3d_cascade_fullres"`.
        public var configuration: String = "3d_fullres"

        /// Folds to ensemble. `["0"]` for fast single-fold, `["0","1","2","3","4"]`
        /// for the full 5-fold average, or `["all"]` for a single all-data model.
        public var folds: [String] = ["0"]

        /// Optional checkpoint override — `"checkpoint_final.pth"` by default.
        public var checkpoint: String?

        /// If true, pass `--disable_tta` — skips 8× test-time augmentation
        /// flipping. ~8× faster; usually 1-3 % Dice cost.
        public var disableTestTimeAugmentation: Bool = true

        /// Disable nnU-Net's own in-process progress bar (cleaner log stream).
        public var quiet: Bool = true

        /// Max wait time for the process in seconds. `nil` = unlimited.
        public var timeoutSeconds: TimeInterval?

        public init(predictBinaryPath: String? = nil,
                    resultsDir: URL? = nil,
                    configuration: String = "3d_fullres",
                    folds: [String] = ["0"],
                    checkpoint: String? = nil,
                    disableTestTimeAugmentation: Bool = true,
                    quiet: Bool = true,
                    timeoutSeconds: TimeInterval? = nil) {
            self.predictBinaryPath = predictBinaryPath
            self.resultsDir = resultsDir
            self.configuration = configuration
            self.folds = folds
            self.checkpoint = checkpoint
            self.disableTestTimeAugmentation = disableTestTimeAugmentation
            self.quiet = quiet
            self.timeoutSeconds = timeoutSeconds
        }
    }

    // MARK: - Errors

    public enum RunError: Error, LocalizedError {
        case binaryNotFound
        case cancelled
        case missingOutput(String)
        case subprocessFailed(exitCode: Int32, stderr: String)
        case geometryMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "nnUNetv2_predict was not found. Install it with `pip install nnunetv2` in a reachable Python environment."
            case .cancelled:
                return "nnU-Net inference was cancelled."
            case .missingOutput(let path):
                return "nnU-Net did not produce the expected output at \(path)."
            case .subprocessFailed(let code, let stderr):
                let snippet = stderr.count > 600 ? String(stderr.suffix(600)) : stderr
                return "nnU-Net exited \(code):\n\(snippet)"
            case .geometryMismatch(let msg):
                return "nnU-Net input geometry mismatch: \(msg)"
            }
        }
    }

    // MARK: - Result

    public struct InferenceResult: @unchecked Sendable {
        public let labelMap: LabelMap
        public let durationSeconds: TimeInterval
        public let stderr: String
    }

    // MARK: - State

    public private(set) var configuration: Configuration
    private var activeProcess: Process?
    private let processLock = NSLock()
    private var cancelled: Bool = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func update(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Availability

    /// Search PATH and conventional Python-env locations for
    /// `nnUNetv2_predict`. Returns the absolute path when found.
    public static func locatePredictBinary(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fm = FileManager.default
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? expanded : nil
        }

        var candidates: [String] = []
        var seen = Set<String>()
        func appendCandidate(_ rawPath: String) {
            guard !rawPath.isEmpty else { return }
            let expanded = (rawPath as NSString).expandingTildeInPath
            guard seen.insert(expanded).inserted else { return }
            candidates.append(expanded)
        }

        let binaryName = "nnUNetv2_predict"
        let pathDirs = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for dir in pathDirs {
            appendCandidate(URL(fileURLWithPath: dir).appendingPathComponent(binaryName).path)
        }

        let home = environment["HOME"] ?? NSHomeDirectory()
        [
            "/opt/homebrew/bin/nnUNetv2_predict",
            "/usr/local/bin/nnUNetv2_predict",
            "/usr/bin/nnUNetv2_predict",
            "\(home)/miniforge3/envs/nnunet/bin/nnUNetv2_predict",
            "\(home)/miniconda3/envs/nnunet/bin/nnUNetv2_predict",
            "\(home)/mambaforge/envs/nnunet/bin/nnUNetv2_predict",
            "\(home)/.conda/envs/nnunet/bin/nnUNetv2_predict",
            "\(home)/.venv/bin/nnUNetv2_predict",
        ].forEach(appendCandidate)

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    public func isAvailable() -> Bool {
        Self.locatePredictBinary(override: configuration.predictBinaryPath) != nil
    }

    // MARK: - Cancellation

    public func cancel() {
        processLock.lock()
        cancelled = true
        activeProcess?.interrupt()
        processLock.unlock()
    }

    // MARK: - Inference

    /// Run inference on `volume` using the given nnU-Net `datasetID`
    /// (e.g. `"Dataset003_Liver"`), returning a populated `LabelMap` bound to
    /// the same voxel grid.
    ///
    /// `logSink` receives each line of the process's stderr as it streams.
    public func runInference(volume: ImageVolume,
                             datasetID: String,
                             logSink: @escaping @Sendable (String) -> Void = { _ in }) async throws -> InferenceResult {
        try await runInference(
            channels: [volume],
            referenceVolume: volume,
            datasetID: datasetID,
            logSink: logSink
        )
    }

    /// Multi-channel variant: writes each `channels[i]` to disk as
    /// `<caseID>_000i.nii`, matching nnU-Net's channel-file convention.
    ///
    /// Use this for models like `Dataset221_AutoPETII_2023` and LesionTracer
    /// where channel 0 is CT (HU) and channel 1 is PET (SUV-scaled). All
    /// channels must share the same voxel grid; the returned `LabelMap` is
    /// bound to `referenceVolume`'s geometry.
    public func runInference(channels: [ImageVolume],
                             referenceVolume: ImageVolume,
                             datasetID: String,
                             logSink: @escaping @Sendable (String) -> Void = { _ in }) async throws -> InferenceResult {
        setCancelled(false)
        guard !channels.isEmpty else {
            throw RunError.geometryMismatch("at least one channel volume is required")
        }

        // Validate geometry *before* hitting the filesystem / subprocess —
        // no need to require nnunetv2 just to reject malformed inputs, and
        // this makes the contract easier to unit-test.
        for (idx, channel) in channels.enumerated() {
            if let mismatch = Self.gridMismatchDescription(
                channel,
                reference: referenceVolume,
                channelIndex: idx
            ) {
                throw RunError.geometryMismatch(mismatch)
            }
        }

        guard let binary = Self.locatePredictBinary(
            override: configuration.predictBinaryPath
        ) else {
            throw RunError.binaryNotFound
        }

        // Temp staging.
        let workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nnunet-\(UUID().uuidString)", isDirectory: true)
        let inDir = workRoot.appendingPathComponent("in", isDirectory: true)
        let outDir = workRoot.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: inDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        let caseID = "case000"
        for (idx, channel) in channels.enumerated() {
            // `_0000`, `_0001`, ... — nnU-Net's per-channel naming convention.
            let channelTag = String(format: "_%04d", idx)
            let inputFile = inDir.appendingPathComponent("\(caseID)\(channelTag).nii")
            try NIfTIWriter.write(channel, to: inputFile)
        }

        // Build the command.
        var args: [String] = [
            "-i", inDir.path,
            "-o", outDir.path,
            "-d", datasetID,
            "-c", configuration.configuration,
            "-f"
        ] + configuration.folds

        if let chk = configuration.checkpoint, !chk.isEmpty {
            args.append(contentsOf: ["-chk", chk])
        }
        if configuration.disableTestTimeAugmentation {
            args.append("--disable_tta")
        }
        if configuration.quiet {
            args.append("--disable_progress_bar")
        }

        let startedAt = Date()
        let (_, stderr) = try await launchAndWait(binary: binary,
                                                   arguments: args,
                                                   logSink: logSink)
        let elapsed = Date().timeIntervalSince(startedAt)

        // nnU-Net writes `<caseID>.nii.gz` in the output dir.
        let outputFileGz = outDir.appendingPathComponent("\(caseID).nii.gz")
        let outputFile = outDir.appendingPathComponent("\(caseID).nii")
        let labelURL = FileManager.default.fileExists(atPath: outputFileGz.path)
            ? outputFileGz
            : outputFile
        guard FileManager.default.fileExists(atPath: labelURL.path) else {
            throw RunError.missingOutput(labelURL.path)
        }

        let labelMap = try LabelIO.loadNIfTILabelmap(from: labelURL, parentVolume: referenceVolume)
        labelMap.name = "nnU-Net · \(datasetID)"

        // If a `dataset.json` sits next to the model, pull its label names.
        if let resultsDir = configuration.resultsDir {
            let datasetJSON = resultsDir
                .appendingPathComponent(datasetID)
                .appendingPathComponent("dataset.json")
            if let names = try? parseDatasetLabelNames(at: datasetJSON) {
                for (idx, cls) in labelMap.classes.enumerated() {
                    if let name = names[Int(cls.labelID)] {
                        labelMap.classes[idx].name = name
                    }
                }
            }
        }

        return InferenceResult(labelMap: labelMap,
                               durationSeconds: elapsed,
                               stderr: stderr)
    }

    // MARK: - Subprocess plumbing

    static func gridMismatchDescription(_ channel: ImageVolume,
                                        reference: ImageVolume,
                                        channelIndex: Int,
                                        tolerance: Double = 1e-4) -> String? {
        guard channel.width == reference.width,
              channel.height == reference.height,
              channel.depth == reference.depth else {
            return "channel \(channelIndex) is \(channel.width)x\(channel.height)x\(channel.depth), reference is \(reference.width)x\(reference.height)x\(reference.depth) — resample before calling"
        }

        guard abs(channel.spacing.x - reference.spacing.x) < tolerance,
              abs(channel.spacing.y - reference.spacing.y) < tolerance,
              abs(channel.spacing.z - reference.spacing.z) < tolerance else {
            return "channel \(channelIndex) spacing \(format(channel.spacing)) does not match reference \(format(reference.spacing)) — resample before calling"
        }

        guard abs(channel.origin.x - reference.origin.x) < tolerance,
              abs(channel.origin.y - reference.origin.y) < tolerance,
              abs(channel.origin.z - reference.origin.z) < tolerance else {
            return "channel \(channelIndex) origin \(format(channel.origin)) does not match reference \(format(reference.origin)) — resample before calling"
        }

        for column in 0..<3 {
            for row in 0..<3 where abs(channel.direction[column][row] - reference.direction[column][row]) >= tolerance {
                return "channel \(channelIndex) direction does not match reference — resample before calling"
            }
        }

        return nil
    }

    private static func format(_ v: (x: Double, y: Double, z: Double)) -> String {
        String(format: "(%.4f, %.4f, %.4f)", v.x, v.y, v.z)
    }

    private func launchAndWait(binary: String,
                               arguments: [String],
                               logSink: @escaping @Sendable (String) -> Void) async throws -> (stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = arguments

        // Forward nnU-Net_results if configured.
        var env = ProcessInfo.processInfo.environment
        if let r = configuration.resultsDir?.path { env["nnUNet_results"] = r }
        if let r = configuration.rawDir?.path { env["nnUNet_raw"] = r }
        if let r = configuration.preprocessedDir?.path { env["nnUNet_preprocessed"] = r }
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Drain both pipes while the process runs. Some nnU-Net/Python setups
        // are surprisingly chatty on stdout; waiting until exit can fill the
        // pipe buffer and stall inference indefinitely.
        let stdoutBuffer = StreamedBuffer(sink: { _ in })
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutBuffer.append(chunk)
        }

        // Stream stderr line-by-line to the log sink.
        let stderrBuffer = StreamedBuffer(sink: logSink)
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrBuffer.append(chunk)
        }

        let canStart = withProcessLock {
            if cancelled {
                return false
            }
            activeProcess = proc
            return true
        }
        guard canStart else {
            throw RunError.cancelled
        }

        do {
            try proc.run()
        } catch {
            throw RunError.subprocessFailed(exitCode: -1, stderr: "\(error)")
        }

        let timedOut = await ProcessWaiter.wait(
            for: proc,
            timeoutSeconds: configuration.timeoutSeconds
        )

        // Drain.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stdoutBuffer.append(remainingStdout)
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stderrBuffer.append(remainingStderr)
        let stdoutStr = stdoutBuffer.flush()

        let wasCancelled = withProcessLock {
            let value = cancelled
            activeProcess = nil
            return value
        }

        if wasCancelled {
            throw RunError.cancelled
        }

        if timedOut {
            let seconds = configuration.timeoutSeconds.map { "\(Int($0))s" } ?? "the configured timeout"
            throw RunError.subprocessFailed(exitCode: proc.terminationStatus,
                                            stderr: "nnU-Net timed out after \(seconds): \(stderrBuffer.flush())")
        }

        let exit = proc.terminationStatus
        if exit != 0 {
            throw RunError.subprocessFailed(exitCode: exit, stderr: stderrBuffer.flush())
        }
        return (stdoutStr, stderrBuffer.flush())
    }

    private func setCancelled(_ value: Bool) {
        processLock.lock()
        cancelled = value
        processLock.unlock()
    }

    private func withProcessLock<T>(_ body: () -> T) -> T {
        processLock.lock()
        defer { processLock.unlock() }
        return body()
    }

    private func parseDatasetLabelNames(at url: URL) throws -> [Int: String] {
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else { return [:] }

        // nnU-Net v2 datasets store: `"labels": { "background": 0, "liver": 1, ... }`
        guard let labels = dict["labels"] as? [String: Any] else { return [:] }
        var out: [Int: String] = [:]
        for (name, rawValue) in labels {
            if let id = rawValue as? Int { out[id] = name }
            else if let s = rawValue as? String, let id = Int(s) { out[id] = name }
        }
        return out
    }
}

// MARK: - Streaming stderr buffer

private final class StreamedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var carry = ""
    private let sink: @Sendable (String) -> Void

    init(sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }

    func append(_ data: Data) {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        buffer.append(text)
        let combined = carry + text
        var lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if !combined.hasSuffix("\n") {
            carry = lines.popLast() ?? ""
        } else {
            carry = ""
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            sink(line)
        }
    }

    func flush() -> String {
        lock.lock()
        let snapshot = buffer
        lock.unlock()
        return snapshot
    }
}
