import Foundation

/// DGX-Spark-backed lesion detector. Mirrors `RemoteLesionClassifier` and
/// `RemotePETACCorrector` — same NIfTI in, JSON out contract, but the
/// script lives on the DGX and runs over SSH.
///
/// Useful for detection models too heavy for local inference (CT-FM,
/// large 3D transformers) and for cohort runs that scale across hundreds
/// of studies.
///
/// Flow:
///   1. Write primary (and optional anatomical) NIfTI locally
///   2. scp them to `<remoteWorkdir>/det-<uuid>/`
///   3. ssh `python3 script --input … [--anatomical …]`
///   4. Parse the JSON response from stdout
///   5. Best-effort cleanup of the remote scratch dir
public final class RemoteLesionDetector: LesionDetector, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let supportedModalities: [Modality]
    public let provenance: String
    public let license: String
    public let requiresAnatomicalChannel: Bool

    public struct Spec: Sendable {
        public var dgx: DGXSparkConfig
        public var remoteScriptPath: String
        public var activationCommand: String
        public var scriptArguments: [String]
        public var timeoutSeconds: TimeInterval
        public var requiresAnatomicalChannel: Bool

        public init(dgx: DGXSparkConfig,
                    remoteScriptPath: String,
                    activationCommand: String = "",
                    scriptArguments: [String] = [],
                    timeoutSeconds: TimeInterval = 600,
                    requiresAnatomicalChannel: Bool = false) {
            self.dgx = dgx
            self.remoteScriptPath = remoteScriptPath
            self.activationCommand = activationCommand
            self.scriptArguments = scriptArguments
            self.timeoutSeconds = timeoutSeconds
            self.requiresAnatomicalChannel = requiresAnatomicalChannel
        }
    }

    private let spec: Spec

    public init(id: String,
                displayName: String,
                spec: Spec,
                supportedModalities: [Modality] = [],
                provenance: String = "User-supplied script on the DGX Spark.",
                license: String = "Depends on the user's model.") {
        self.id = id
        self.displayName = displayName
        self.spec = spec
        self.supportedModalities = supportedModalities
        self.provenance = provenance
        self.license = license
        self.requiresAnatomicalChannel = spec.requiresAnatomicalChannel
    }

    public func detect(volume: ImageVolume,
                       anatomical: ImageVolume?,
                       progress: @escaping @Sendable (String) -> Void)
        async throws -> [LesionDetection] {

        guard spec.dgx.isConfigured else {
            throw DetectionError.modelUnavailable("DGX Spark not configured. Settings → DGX Spark.")
        }
        try DetectionUtilities.validateInputs(volume: volume,
                                              anatomical: anatomical,
                                              requiresAnatomical: requiresAnatomicalChannel)

        let executor = RemoteExecutor(config: spec.dgx)

        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-detect-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }

        let localPrimary = localRoot.appendingPathComponent("input.nii")
        let localAnatomical = localRoot.appendingPathComponent("anatomical.nii")
        try NIfTIWriter.write(volume, to: localPrimary)
        if let anatomical {
            try NIfTIWriter.write(anatomical, to: localAnatomical)
        }
        progress("→ Wrote primary\(anatomical == nil ? "" : " + anatomical channel") locally")

        let remoteBase = "\(spec.dgx.remoteWorkdir)/det-\(UUID().uuidString.prefix(8))"
        let remotePrimary = "\(remoteBase)/input.nii"
        let remoteAnatomical = "\(remoteBase)/anatomical.nii"
        defer { executor.remove(remoteBase) }
        try executor.ensureRemoteDirectory(remoteBase)
        try executor.uploadFile(localPrimary, toRemote: remotePrimary)
        if anatomical != nil {
            try executor.uploadFile(localAnatomical, toRemote: remoteAnatomical)
        }
        progress("→ Uploaded to \(spec.dgx.sshDestination):\(remoteBase)")

        // Build the command. JSON goes on stdout, so we don't redirect.
        var parts: [String] = []
        if !spec.activationCommand.isEmpty {
            parts.append(spec.activationCommand)
            parts.append("&&")
        }
        parts.append("python3")
        parts.append(RemoteExecutor.shellEscape(spec.remoteScriptPath))
        for arg in spec.scriptArguments {
            parts.append(RemoteExecutor.shellEscape(arg))
        }
        parts.append("--input")
        parts.append(RemoteExecutor.shellEscape(remotePrimary))
        if anatomical != nil {
            parts.append("--anatomical")
            parts.append(RemoteExecutor.shellEscape(remoteAnatomical))
        }
        let command = parts.joined(separator: " ")
        progress("→ ssh: \(command)")

        let result: RemoteExecutor.RunResult
        do {
            result = try executor.run(command, timeoutSeconds: spec.timeoutSeconds)
        } catch let error as RemoteExecutor.Error {
            throw DetectionError.inferenceFailed(error.errorDescription ?? "remote detection failed")
        }
        if !result.stderr.isEmpty {
            progress(result.stderr)
        }
        guard result.exitCode == 0 else {
            throw DetectionError.inferenceFailed(
                "remote detector exited \(result.exitCode): \(result.stderr.isEmpty ? "<no stderr>" : result.stderr)"
            )
        }

        let wire: DetectionWireFormat
        do {
            wire = try JSONDecoder().decode(DetectionWireFormat.self, from: result.stdout)
        } catch {
            let preview = String(data: result.stdout.prefix(400), encoding: .utf8) ?? "<binary>"
            throw DetectionError.malformedOutput(
                "couldn't parse JSON from remote detector: \(error.localizedDescription) — first 400 bytes: \(preview)"
            )
        }
        let detections = wire.toDetections(detectorID: id, volume: volume)
        progress("✓ Detection complete · \(detections.count) findings")
        return detections
    }
}
