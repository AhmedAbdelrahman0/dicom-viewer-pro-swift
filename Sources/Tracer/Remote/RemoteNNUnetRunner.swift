import Foundation

/// Remote-workstation-backed nnU-Net inference. Mirrors the shape of `NNUnetRunner`
/// so `NNUnetViewModel` can swap between local and remote execution with
/// no further plumbing.
///
/// Flow:
///   1. Write each input channel as a NIfTI locally under a staging dir.
///   2. scp the staging dir to `remoteWorkdir/<case-id>/in/`.
///   3. ssh `nnUNetv2_predict -i ... -o ...` on the remote workstation.
///   4. scp the predicted mask back.
///   5. Load it into a `LabelMap` and return.
///   6. Clean up the remote directory.
public final class RemoteNNUnetRunner: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var dgx: DGXSparkConfig
        /// nnU-Net dataset id (e.g. `Dataset221_AutoPETII_2023`).
        public var datasetID: String
        /// nnU-Net configuration (`3d_fullres` / `3d_lowres` / `2d`).
        public var configuration: String
        public var folds: [String]
        public var disableTestTimeAugmentation: Bool
        public var quiet: Bool
        public var timeoutSeconds: TimeInterval

        public init(dgx: DGXSparkConfig,
                    datasetID: String,
                    configuration: String = "3d_fullres",
                    folds: [String] = ["0"],
                    disableTestTimeAugmentation: Bool = true,
                    quiet: Bool = true,
                    timeoutSeconds: TimeInterval = 1800) {
            self.dgx = dgx
            self.datasetID = datasetID
            self.configuration = configuration
            self.folds = folds
            self.disableTestTimeAugmentation = disableTestTimeAugmentation
            self.quiet = quiet
            self.timeoutSeconds = timeoutSeconds
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case notConfigured
        case cancelled
        case missingRemoteOutput(String)
        case subprocessFailed(exitCode: Int32, stderr: String)
        case geometryMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Remote workstation is not configured. Settings -> Remote Workstation."
            case .cancelled:
                return "Remote inference was cancelled."
            case .missingRemoteOutput(let p):
                return "Remote nnU-Net produced no output at \(p)."
            case .subprocessFailed(let code, let stderr):
                let snippet = stderr.count > 600 ? String(stderr.suffix(600)) : stderr
                return "Remote nnU-Net exited \(code): \(snippet)"
            case .geometryMismatch(let msg):
                return "Channel geometry mismatch: \(msg)"
            }
        }
    }

    public struct InferenceResult: @unchecked Sendable {
        public let labelMap: LabelMap
        public let durationSeconds: TimeInterval
        public let stderr: String
    }

    public private(set) var configuration: Configuration
    private var cancelled = false
    private let lock = NSLock()

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func update(configuration: Configuration) {
        self.configuration = configuration
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func resetCancel() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Primary entry point. `channels[0]` becomes `_0000.nii`,
    /// `channels[1]` becomes `_0001.nii`, etc.
    public func runInference(channels: [ImageVolume],
                             referenceVolume: ImageVolume,
                             logSink: @escaping @Sendable (String) -> Void = { _ in }) async throws -> InferenceResult {
        guard configuration.dgx.isConfigured else { throw Error.notConfigured }
        guard !channels.isEmpty else {
            throw Error.geometryMismatch("no channels supplied")
        }
        resetCancel()

        // Geometry parity — same contract as the local runner.
        for (idx, channel) in channels.enumerated() {
            if let mismatch = NNUnetRunner.gridMismatchDescription(
                channel,
                reference: referenceVolume,
                channelIndex: idx
            ) {
                throw Error.geometryMismatch(mismatch)
            }
        }

        let caseID = "tracer-\(UUID().uuidString.prefix(8))"
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(caseID)-local", isDirectory: true)
        let localIn = localRoot.appendingPathComponent("in", isDirectory: true)
        let localOut = localRoot.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: localIn, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localOut, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }

        // Write channels locally.
        for (idx, channel) in channels.enumerated() {
            let tag = String(format: "_%04d", idx)
            let url = localIn.appendingPathComponent("\(caseID)\(tag).nii")
            try NIfTIWriter.write(channel, to: url)
        }

        let executor = RemoteExecutor(config: configuration.dgx)
        let remoteBase = "\(configuration.dgx.remoteWorkdir)/\(caseID)"
        let remoteIn = "\(remoteBase)/in"
        let remoteOut = "\(remoteBase)/out"
        defer { executor.remove(remoteBase) }
        if isCancelled { throw Error.cancelled }

        logSink("→ Staging \(channels.count) channel(s) to \(configuration.dgx.sshDestination):\(remoteIn)")
        try executor.uploadDirectory(localIn, toRemote: remoteIn)
        if isCancelled { throw Error.cancelled }

        // Build the nnU-Net command.
        let binary = configuration.dgx.remoteNNUnetBinary.isEmpty
            ? "nnUNetv2_predict"
            : configuration.dgx.remoteNNUnetBinary
        var parts: [String] = [
            RemoteExecutor.shellEscape(binary),
            "-i", RemoteExecutor.shellEscape(remoteIn),
            "-o", RemoteExecutor.shellEscape(remoteOut),
            "-d", RemoteExecutor.shellEscape(configuration.datasetID),
            "-c", RemoteExecutor.shellEscape(configuration.configuration),
            "-f"
        ]
        parts.append(contentsOf: configuration.folds.map { RemoteExecutor.shellEscape($0) })
        if configuration.disableTestTimeAugmentation { parts.append("--disable_tta") }
        if configuration.quiet { parts.append("--disable_progress_bar") }
        let command = "mkdir -p \(RemoteExecutor.shellEscape(remoteOut)) && " + parts.joined(separator: " ")

        logSink("→ ssh \(configuration.dgx.sshDestination): \(command)")
        let started = Date()
        let result = try executor.run(command, timeoutSeconds: configuration.timeoutSeconds)
        let elapsed = Date().timeIntervalSince(started)
        if isCancelled { throw Error.cancelled }
        logSink(result.stderr)
        guard result.exitCode == 0 else {
            throw Error.subprocessFailed(exitCode: result.exitCode, stderr: result.stderr)
        }

        // Pull the result file. Prefer the .nii.gz produced by stock nnU-Net
        // v2; fall back to plain .nii for users running an older fork.
        // We let scp's own exit code signal "not found" rather than a
        // separate `test -f` probe, which would leave a TOCTOU gap between
        // the check and the transfer.
        let remoteOutputGz = "\(remoteOut)/\(caseID).nii.gz"
        let remoteOutputNii = "\(remoteOut)/\(caseID).nii"
        let localOutputGz = localOut.appendingPathComponent("\(caseID).nii.gz")
        let localOutputNii = localOut.appendingPathComponent("\(caseID).nii")

        let labelURL: URL
        do {
            try executor.downloadFile(remoteOutputGz, toLocal: localOutputGz)
            labelURL = localOutputGz
        } catch {
            // scp exits non-zero for missing-file. Try the .nii fallback.
            do {
                try executor.downloadFile(remoteOutputNii, toLocal: localOutputNii)
                labelURL = localOutputNii
            } catch {
                throw Error.missingRemoteOutput(remoteOutputGz)
            }
        }

        let labelMap = try LabelIO.loadNIfTILabelmap(from: labelURL,
                                                     parentVolume: referenceVolume)
        labelMap.name = "nnU-Net · \(configuration.datasetID) (remote)"
        return InferenceResult(labelMap: labelMap,
                               durationSeconds: elapsed,
                               stderr: result.stderr)
    }
}
