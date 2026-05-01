import Foundation

/// Local Python subprocess that runs an attenuation-correction model.
///
/// I/O contract — the script must accept:
/// ```
/// python3 script.py --input  /path/to/nac.nii.gz \
///                   --output /path/to/ac.nii.gz \
///                   [--anatomical /path/to/ct_or_mr.nii.gz]
/// ```
/// and write the AC PET as a NIfTI on the same voxel grid as the input.
/// Anything written to stdout / stderr is captured and surfaced as the log
/// snippet on the result; non-zero exit means failure.
///
/// We write inputs as `.nii.gz` (handled by `LabelIO.gzip` since
/// `NIfTIWriter` doesn't compress yet) and read the output via
/// `NIfTILoader`. This keeps the contract identical to nnU-Net's pipeline,
/// so users with a working nnU-Net Python environment can drop in an AC
/// model with zero extra plumbing.
public final class SubprocessPETACCorrector: PETAttenuationCorrector, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let provenance: String
    public let license: String
    public let requiresAnatomicalChannel: Bool

    public struct Spec: Sendable {
        public var executablePath: String          // python3 + script wrapper, OR a shell script
        public var scriptPath: String              // .py the wrapper invokes
        public var arguments: [String]             // extra args (e.g. ["--device", "cuda:0"])
        public var environment: [String: String]   // e.g. CUDA_VISIBLE_DEVICES=0
        public var timeoutSeconds: TimeInterval
        public var requiresAnatomicalChannel: Bool

        public init(executablePath: String = "/usr/bin/env",
                    scriptPath: String,
                    arguments: [String] = [],
                    environment: [String: String] = [:],
                    timeoutSeconds: TimeInterval = 600,
                    requiresAnatomicalChannel: Bool = false) {
            self.executablePath = executablePath
            self.scriptPath = scriptPath
            self.arguments = arguments
            self.environment = environment
            self.timeoutSeconds = timeoutSeconds
            self.requiresAnatomicalChannel = requiresAnatomicalChannel
        }
    }

    private let spec: Spec

    public init(id: String,
                displayName: String,
                spec: Spec,
                provenance: String = "User-supplied Python script.",
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
        try PETACUtilities.validateInputs(nacPET: nacPET,
                                          anatomical: anatomical,
                                          requiresAnatomical: requiresAnatomicalChannel)

        let started = Date()
        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-ac-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let nacURL = workdir.appendingPathComponent("nac.nii")
        let acURL  = workdir.appendingPathComponent("ac.nii")
        try NIfTIWriter.write(nacPET, to: nacURL)
        progress("→ Wrote NAC PET (\(nacPET.depth)×\(nacPET.height)×\(nacPET.width) voxels)")

        var args: [String] = spec.arguments
        args.append(contentsOf: ["--input", nacURL.path, "--output", acURL.path])
        if let anatomical {
            let anatomicalURL = workdir.appendingPathComponent("anatomical.nii")
            try NIfTIWriter.write(anatomical, to: anatomicalURL)
            args.append(contentsOf: ["--anatomical", anatomicalURL.path])
            progress("→ Wrote anatomical channel (\(anatomical.modality))")
        }

        // Build the launch arguments. If the user pointed `executablePath`
        // at python3 directly, we prepend the script. If they pointed at
        // `/usr/bin/env`, we add `python3` then the script. Either way the
        // script receives the same --input/--output args.
        let launchArguments = Self.composeLaunchArguments(
            executable: spec.executablePath,
            script: spec.scriptPath,
            extraArgs: args
        )

        var env = ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment)
        for (k, v) in spec.environment { env[k] = v }
        let worker = LocalWorkerProcess()
        let result: WorkerProcessResult
        do {
            result = try await worker.run(WorkerProcessRequest(
                executablePath: spec.executablePath,
                arguments: launchArguments,
                environment: env,
                timeoutSeconds: spec.timeoutSeconds,
                streamStdout: false,
                streamStderr: true
            ), logSink: progress)
        } catch WorkerProcessError.timedOut(_, let stderr) {
            throw PETACError.inferenceFailed(
                "AC subprocess timed out after \(Int(spec.timeoutSeconds))s\(stderr.isEmpty ? "" : ": \(stderr)")"
            )
        } catch WorkerProcessError.nonZeroExit(let exitCode, let stderr) {
            throw PETACError.inferenceFailed(
                "AC subprocess exited \(exitCode): \(stderr.isEmpty ? "<no stderr>" : stderr)"
            )
        } catch {
            throw PETACError.inferenceFailed("could not launch \(spec.executablePath): \(error.localizedDescription)")
        }
        let stderr = result.stderr

        // Load the output NIfTI as a fresh ImageVolume + verify geometry.
        let acVolume: ImageVolume
        do {
            acVolume = try NIfTILoader.load(acURL, modalityHint: "PT")
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

        let acResultVolume = try PETACUtilities.makeACVolume(
            from: acVolume.pixels,
            sourceNAC: nacPET,
            correctorID: id
        )
        progress("✓ AC complete")
        return PETACResult(
            acPET: acResultVolume,
            durationSeconds: Date().timeIntervalSince(started),
            correctorID: id,
            logSnippet: stderr.isEmpty ? nil : String(stderr.suffix(800))
        )
    }

    /// `python3` vs `/usr/bin/env python3` vs a shell wrapper — the user
    /// might point `executablePath` at any of them, so we handle the three
    /// common shapes uniformly. Tested in `testSubprocessACComposesPython3LaunchArguments`.
    static func composeLaunchArguments(executable: String,
                                       script: String,
                                       extraArgs: [String]) -> [String] {
        let exeName = (executable as NSString).lastPathComponent
        if exeName == "env" {
            // `/usr/bin/env python3 script.py …`
            return ["python3", script] + extraArgs
        }
        if exeName.hasPrefix("python") {
            // `python3 script.py …`
            return [script] + extraArgs
        }
        // Shell wrapper or other executable — assume it accepts the script
        // as its first argument.
        return [script] + extraArgs
    }
}
