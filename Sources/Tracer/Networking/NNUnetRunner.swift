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
///      `-c <configuration> -f <foldsCSV> [-chk <checkpoint>] --disable_tta`,
///      or `nnUNetv2_predict_from_modelfolder` when a concrete model folder
///      is configured.
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

        /// Direct trained-model folder override. Useful for exported models
        /// and legacy bundles whose folder name contains the trainer/plans/
        /// configuration, such as `autoPET3_Trainer__...__3d_fullres_bs3`.
        public var modelFolder: URL?

        /// Extra environment for the subprocess. Used sparingly, mainly to
        /// prepend a bundled nnU-Net package to PYTHONPATH for custom trainers.
        public var additionalEnvironment: [String: String] = [:]

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

        /// Optional Docker/Podman image for containerized worker execution.
        /// When set, Tracer invokes `docker run` through `WorkerProcess`
        /// instead of launching the local nnU-Net binary directly.
        public var dockerImage: String?
        public var dockerMounts: [DockerWorkerMount] = []
        public var dockerEnableGPU: Bool = true

        public init(predictBinaryPath: String? = nil,
                    resultsDir: URL? = nil,
                    rawDir: URL? = nil,
                    preprocessedDir: URL? = nil,
                    modelFolder: URL? = nil,
                    additionalEnvironment: [String: String] = [:],
                    configuration: String = "3d_fullres",
                    folds: [String] = ["0"],
                    checkpoint: String? = nil,
                    disableTestTimeAugmentation: Bool = true,
                    quiet: Bool = true,
                    timeoutSeconds: TimeInterval? = nil,
                    dockerImage: String? = nil,
                    dockerMounts: [DockerWorkerMount] = [],
                    dockerEnableGPU: Bool = true) {
            self.predictBinaryPath = predictBinaryPath
            self.resultsDir = resultsDir
            self.rawDir = rawDir
            self.preprocessedDir = preprocessedDir
            self.modelFolder = modelFolder
            self.additionalEnvironment = additionalEnvironment
            self.configuration = configuration
            self.folds = folds
            self.checkpoint = checkpoint
            self.disableTestTimeAugmentation = disableTestTimeAugmentation
            self.quiet = quiet
            self.timeoutSeconds = timeoutSeconds
            self.dockerImage = dockerImage
            self.dockerMounts = dockerMounts
            self.dockerEnableGPU = dockerEnableGPU
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
                return "nnU-Net CLI was not found. Install nnunetv2 in a reachable Python environment, including `nnUNetv2_predict` and `nnUNetv2_predict_from_modelfolder`."
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
    private var activeWorker: WorkerProcess?
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        binaryName: String = "nnUNetv2_predict"
    ) -> String? {
        let fm = FileManager.default
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            let overrideURL = URL(fileURLWithPath: expanded)
            if fm.isExecutableFile(atPath: expanded),
               overrideURL.lastPathComponent == binaryName {
                return expanded
            }
            let sibling = overrideURL.deletingLastPathComponent().appendingPathComponent(binaryName).path
            if fm.isExecutableFile(atPath: sibling) {
                return sibling
            }
            return binaryName == "nnUNetv2_predict" && fm.isExecutableFile(atPath: expanded) ? expanded : nil
        }

        var candidates: [String] = []
        var seen = Set<String>()
        func appendCandidate(_ rawPath: String) {
            guard !rawPath.isEmpty else { return }
            let expanded = (rawPath as NSString).expandingTildeInPath
            guard seen.insert(expanded).inserted else { return }
            candidates.append(expanded)
        }

        let pathDirs = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for dir in pathDirs {
            appendCandidate(URL(fileURLWithPath: dir).appendingPathComponent(binaryName).path)
        }

        let home = environment["HOME"] ?? NSHomeDirectory()
        [
            "/opt/homebrew/bin/\(binaryName)",
            "/usr/local/bin/\(binaryName)",
            "/usr/bin/\(binaryName)",
            "\(home)/miniforge3/envs/nnunet/bin/\(binaryName)",
            "\(home)/miniconda3/envs/nnunet/bin/\(binaryName)",
            "\(home)/mambaforge/envs/nnunet/bin/\(binaryName)",
            "\(home)/.conda/envs/nnunet/bin/\(binaryName)",
            "\(home)/.venv/bin/\(binaryName)",
        ].forEach(appendCandidate)

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    public func isAvailable() -> Bool {
        Self.locatePredictBinary(
            override: configuration.predictBinaryPath,
            binaryName: requiredBinaryName
        ) != nil
    }

    // MARK: - Cancellation

    public func cancel() {
        processLock.lock()
        cancelled = true
        activeProcess?.interrupt()
        activeWorker?.cancel()
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
            override: configuration.predictBinaryPath,
            binaryName: requiredBinaryName
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
        var args: [String]
        if let modelFolder = configuration.modelFolder {
            args = [
                "-i", inDir.path,
                "-o", outDir.path,
                "-m", modelFolder.path
            ]
            if !configuration.folds.isEmpty {
                args.append("-f")
                args.append(contentsOf: configuration.folds)
            }
        } else {
            args = [
                "-i", inDir.path,
                "-o", outDir.path,
                "-d", datasetID,
                "-c", configuration.configuration,
                "-f"
            ] + configuration.folds
        }

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
                                                   workingDirectory: workRoot,
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
        let datasetJSONs: [URL] = [
            configuration.modelFolder?.appendingPathComponent("dataset.json"),
            configuration.resultsDir?
                .appendingPathComponent(datasetID)
                .appendingPathComponent("dataset.json")
        ].compactMap { $0 }
        for datasetJSON in datasetJSONs {
            if let names = try? parseDatasetLabelNames(at: datasetJSON) {
                for (idx, cls) in labelMap.classes.enumerated() {
                    if let name = names[Int(cls.labelID)] {
                        labelMap.classes[idx].name = name
                    }
                }
                break
            }
        }

        return InferenceResult(labelMap: labelMap,
                               durationSeconds: elapsed,
                               stderr: stderr)
    }

    // MARK: - Subprocess plumbing

    private var requiredBinaryName: String {
        configuration.modelFolder == nil
            ? "nnUNetv2_predict"
            : "nnUNetv2_predict_from_modelfolder"
    }

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
                               workingDirectory: URL?,
                               logSink: @escaping @Sendable (String) -> Void) async throws -> (stdout: String, stderr: String) {
        // Forward nnU-Net_results if configured.
        var env = ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment)
        for (key, value) in configuration.additionalEnvironment {
            if key == "PYTHONPATH",
               let existing = env["PYTHONPATH"],
               !existing.isEmpty,
               !value.contains(existing) {
                env[key] = "\(value):\(existing)"
            } else {
                env[key] = value
            }
        }
        if let r = configuration.resultsDir?.path { env["nnUNet_results"] = r }
        if let r = configuration.rawDir?.path { env["nnUNet_raw"] = r }
        if let r = configuration.preprocessedDir?.path { env["nnUNet_preprocessed"] = r }

        let worker: WorkerProcess
        if let image = configuration.dockerImage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !image.isEmpty {
            let mounts = dockerMounts(workingDirectory: workingDirectory)
            worker = DockerWorkerProcess(configuration: DockerWorkerConfiguration(
                image: image,
                mounts: mounts,
                enableGPU: configuration.dockerEnableGPU
            ))
        } else {
            worker = LocalWorkerProcess()
        }
        let canStart = withProcessLock {
            if cancelled {
                return false
            }
            activeWorker = worker
            return true
        }
        guard canStart else {
            throw RunError.cancelled
        }

        do {
            let result = try await worker.run(WorkerProcessRequest(
                executablePath: binary,
                arguments: arguments,
                environment: env,
                workingDirectory: workingDirectory,
                timeoutSeconds: configuration.timeoutSeconds,
                streamStdout: false,
                streamStderr: true
            ), logSink: logSink)
            let wasCancelled = withProcessLock {
                let value = cancelled
                activeWorker = nil
                activeProcess = nil
                return value
            }
            if wasCancelled {
                throw RunError.cancelled
            }
            return (result.stdout, result.stderr)
        } catch WorkerProcessError.cancelled {
            withProcessLock {
                activeWorker = nil
                activeProcess = nil
            }
            throw RunError.cancelled
        } catch WorkerProcessError.timedOut(let exitCode, let stderr) {
            withProcessLock {
                activeWorker = nil
                activeProcess = nil
            }
            let seconds = configuration.timeoutSeconds.map { "\(Int($0))s" } ?? "the configured timeout"
            throw RunError.subprocessFailed(exitCode: exitCode,
                                            stderr: "nnU-Net timed out after \(seconds): \(stderr)")
        } catch WorkerProcessError.nonZeroExit(let exitCode, let stderr) {
            withProcessLock {
                activeWorker = nil
                activeProcess = nil
            }
            throw RunError.subprocessFailed(exitCode: exitCode, stderr: stderr)
        } catch {
            withProcessLock {
                activeWorker = nil
                activeProcess = nil
            }
            throw RunError.subprocessFailed(exitCode: -1, stderr: "\(error)")
        }
    }

    private func dockerMounts(workingDirectory: URL?) -> [DockerWorkerMount] {
        var mounts = configuration.dockerMounts

        func appendUnique(_ mount: DockerWorkerMount) {
            let hostPath = URL(fileURLWithPath: mount.hostPath).standardizedFileURL.path
            let containerPath = URL(fileURLWithPath: mount.containerPath).standardizedFileURL.path
            let alreadyMounted = mounts.contains { existing in
                URL(fileURLWithPath: existing.hostPath).standardizedFileURL.path == hostPath ||
                URL(fileURLWithPath: existing.containerPath).standardizedFileURL.path == containerPath
            }
            if !alreadyMounted {
                mounts.append(mount)
            }
        }

        if let workingDirectory {
            appendUnique(DockerWorkerMount(hostPath: workingDirectory.path,
                                           containerPath: workingDirectory.path,
                                           access: .readWrite))
        }
        if let resultsDir = configuration.resultsDir {
            appendUnique(DockerWorkerMount(hostPath: resultsDir.path,
                                           containerPath: resultsDir.path,
                                           access: .readOnly))
        }
        if let modelFolder = configuration.modelFolder {
            appendUnique(DockerWorkerMount(hostPath: modelFolder.path,
                                           containerPath: modelFolder.path,
                                           access: .readOnly))
        }
        if let rawDir = configuration.rawDir {
            appendUnique(DockerWorkerMount(hostPath: rawDir.path,
                                           containerPath: rawDir.path,
                                           access: .readWrite))
        }
        if let preprocessedDir = configuration.preprocessedDir {
            appendUnique(DockerWorkerMount(hostPath: preprocessedDir.path,
                                           containerPath: preprocessedDir.path,
                                           access: .readWrite))
        }

        return mounts
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
