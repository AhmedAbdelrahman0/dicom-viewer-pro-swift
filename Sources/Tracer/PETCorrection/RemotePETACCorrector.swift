import Foundation

/// DGX-Spark-backed attenuation correction. Mirrors `RemoteNNUnetRunner` and
/// `SubprocessPETACCorrector` — same NIfTI in/out contract, same script
/// argv shape, but the script lives on the DGX and runs over SSH.
///
/// Why this exists: a 192³ deep-AC inference on Apple Silicon takes 20-60s;
/// on a 2000-case cohort that's a wall-clock day. On the user's DGX Spark
/// (single H100) it's ~2s per case + transfer, and the cohort runner can
/// keep multiple workers in flight.
///
/// Flow:
///   1. Write NAC (and optional anatomical) as NIfTI locally
///   2. scp the NIfTIs to `<remoteWorkdir>/ac-<uuid>/`
///   3. ssh `python3 script --input … --output … [--anatomical …]`
///   4. scp the AC output back
///   5. Load it as a fresh `ImageVolume` and return
///   6. Best-effort cleanup of the remote scratch dir
public final class RemotePETACCorrector: PETAttenuationCorrector, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let provenance: String
    public let license: String
    public let requiresAnatomicalChannel: Bool

    public struct Spec: Sendable {
        public var dgx: DGXSparkConfig
        /// Absolute path to the AC script on the DGX.
        public var remoteScriptPath: String
        /// Optional shell command to activate a conda / venv before running
        /// the script — `"conda activate ac"` or
        /// `"source ~/envs/deepac/bin/activate"`.
        public var activationCommand: String
        /// Extra args appended after the script path, before the
        /// `--input` / `--output` flags Tracer fills in.
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
                provenance: String = "User-supplied script on the DGX Spark.",
                license: String = "Depends on the user's model.") {
        self.id = id
        self.displayName = displayName
        self.spec = spec
        self.provenance = provenance
        self.license = license
        self.requiresAnatomicalChannel = spec.requiresAnatomicalChannel
    }

    public func attenuationCorrect(nacPET: ImageVolume,
                                   anatomical: ImageVolume?,
                                   progress: @escaping @Sendable (String) -> Void) async throws -> PETACResult {
        guard spec.dgx.isConfigured else {
            throw PETACError.modelUnavailable("DGX Spark not configured. Settings → DGX Spark.")
        }
        try PETACUtilities.validateInputs(nacPET: nacPET,
                                          anatomical: anatomical,
                                          requiresAnatomical: requiresAnatomicalChannel)

        let started = Date()
        let executor = RemoteExecutor(config: spec.dgx)

        // 1. Local staging — write the NIfTIs into a per-call temp dir.
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-ac-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }

        let localNAC = localRoot.appendingPathComponent("nac.nii")
        let localAnatomical = localRoot.appendingPathComponent("anatomical.nii")
        try NIfTIWriter.write(nacPET, to: localNAC)
        if let anatomical {
            try NIfTIWriter.write(anatomical, to: localAnatomical)
        }
        progress("→ Wrote NAC PET\(anatomical == nil ? "" : " + anatomical channel") locally")

        // 2. Remote staging dir + uploads.
        let remoteBase = "\(spec.dgx.remoteWorkdir)/ac-\(UUID().uuidString.prefix(8))"
        let remoteNAC = "\(remoteBase)/nac.nii"
        let remoteAnatomical = "\(remoteBase)/anatomical.nii"
        let remoteAC = "\(remoteBase)/ac.nii"
        defer { executor.remove(remoteBase) }
        try executor.ensureRemoteDirectory(remoteBase)
        try executor.uploadFile(localNAC, toRemote: remoteNAC)
        if anatomical != nil {
            try executor.uploadFile(localAnatomical, toRemote: remoteAnatomical)
        }
        progress("→ Uploaded to \(spec.dgx.sshDestination):\(remoteBase)")

        // 3. Build + run the command.
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
        parts.append(RemoteExecutor.shellEscape(remoteNAC))
        parts.append("--output")
        parts.append(RemoteExecutor.shellEscape(remoteAC))
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
            throw PETACError.inferenceFailed(error.errorDescription ?? "remote AC command failed")
        }
        if !result.stderr.isEmpty {
            progress(result.stderr)
        }
        guard result.exitCode == 0 else {
            throw PETACError.inferenceFailed(
                "remote AC exited \(result.exitCode): \(result.stderr.isEmpty ? "<no stderr>" : result.stderr)"
            )
        }

        // 4. Pull AC PET back. Direct scp — let scp's exit code signal a
        // missing output rather than a separate `test -f` probe.
        let localAC = localRoot.appendingPathComponent("ac.nii")
        do {
            try executor.downloadFile(remoteAC, toLocal: localAC)
        } catch {
            throw PETACError.inferenceFailed(
                "AC output not retrievable from \(remoteAC): \(error.localizedDescription)"
            )
        }

        // 5. Load + verify geometry.
        let acVolume: ImageVolume
        do {
            acVolume = try NIfTILoader.load(localAC, modalityHint: "PT")
        } catch {
            throw PETACError.inferenceFailed("could not read AC output NIfTI: \(error.localizedDescription)")
        }
        guard acVolume.width == nacPET.width,
              acVolume.height == nacPET.height,
              acVolume.depth == nacPET.depth else {
            throw PETACError.outputGridMismatch(
                "model returned \(acVolume.width)x\(acVolume.height)x\(acVolume.depth), expected \(nacPET.width)x\(nacPET.height)x\(nacPET.depth)"
            )
        }

        let outVolume = PETACUtilities.makeACVolume(
            from: acVolume.pixels,
            sourceNAC: nacPET,
            correctorID: id
        )
        progress("✓ AC complete · \(outVolume.depth)x\(outVolume.height)x\(outVolume.width) voxels")
        return PETACResult(
            acPET: outVolume,
            durationSeconds: Date().timeIntervalSince(started),
            correctorID: id,
            logSnippet: result.stderr.isEmpty ? nil : String(result.stderr.suffix(800))
        )
    }
}
