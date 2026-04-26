import Foundation

/// Local Python subprocess that runs a lesion detector.
///
/// I/O contract — the script must accept:
/// ```
/// python3 script.py --input  /path/to/volume.nii.gz \
///                   [--anatomical /path/to/ct_or_mr.nii.gz]
/// ```
/// and write `DetectionWireFormat` JSON on stdout. Exit non-zero
/// indicates failure (stderr is captured + surfaced in the error). See
/// `LesionDetector.swift` for the full JSON schema with a worked
/// example.
///
/// Implementation mirrors `SubprocessPETACCorrector` so users with a
/// working AC pipeline already know the wrapper-script shape — only
/// the output format differs.
public final class SubprocessLesionDetector: LesionDetector, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let supportedModalities: [Modality]
    public let provenance: String
    public let license: String
    public let requiresAnatomicalChannel: Bool

    public struct Spec: Sendable {
        public var executablePath: String          // /usr/bin/env (default) or full python path
        public var scriptPath: String              // .py wrapper
        public var arguments: [String]             // extra args appended after the script
        public var environment: [String: String]   // KEY=VAL exports
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
                supportedModalities: [Modality] = [],
                provenance: String = "User-supplied Python script.",
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

        try DetectionUtilities.validateInputs(volume: volume,
                                              anatomical: anatomical,
                                              requiresAnatomical: requiresAnatomicalChannel)

        let workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-detect-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workdir) }

        let inputURL = workdir.appendingPathComponent("input.nii")
        try NIfTIWriter.write(volume, to: inputURL)
        progress("→ Wrote primary volume (\(volume.depth)×\(volume.height)×\(volume.width) voxels)")

        var args: [String] = spec.arguments
        args.append(contentsOf: ["--input", inputURL.path])
        if let anatomical {
            let anaURL = workdir.appendingPathComponent("anatomical.nii")
            try NIfTIWriter.write(anatomical, to: anaURL)
            args.append(contentsOf: ["--anatomical", anaURL.path])
            progress("→ Wrote anatomical channel (\(anatomical.modality))")
        }

        let launchArguments = Self.composeLaunchArguments(
            executable: spec.executablePath,
            script: spec.scriptPath,
            extraArgs: args
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executablePath)
        process.arguments = launchArguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in spec.environment { env[k] = v }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
        // Stdout is the JSON payload — must NOT be streamed line-by-line
        // to the progress sink (would confuse a user watching the panel).
        // Stderr IS the model's progress chatter (PyTorch loading bars,
        // "running NMS…", etc.).
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutBuffer.append(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrBuffer.append(chunk)
            if let s = String(data: chunk, encoding: .utf8) {
                progress(s.trimmingCharacters(in: .newlines))
            }
        }

        do {
            try process.run()
        } catch {
            throw DetectionError.inferenceFailed("could not launch \(spec.executablePath): \(error.localizedDescription)")
        }

        let timedOut = await ProcessWaiter.wait(for: process,
                                                timeoutSeconds: spec.timeoutSeconds)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let stderr = stderrBuffer.string()
        if timedOut {
            throw DetectionError.inferenceFailed(
                "detector subprocess timed out after \(Int(spec.timeoutSeconds))s\(stderr.isEmpty ? "" : ": \(stderr)")"
            )
        }
        guard process.terminationStatus == 0 else {
            throw DetectionError.inferenceFailed(
                "detector subprocess exited \(process.terminationStatus): \(stderr.isEmpty ? "<no stderr>" : stderr)"
            )
        }

        let stdoutData = stdoutBuffer.data()
        let wire: DetectionWireFormat
        do {
            wire = try JSONDecoder().decode(DetectionWireFormat.self, from: stdoutData)
        } catch {
            let preview = String(data: stdoutData.prefix(400), encoding: .utf8) ?? "<binary>"
            throw DetectionError.malformedOutput(
                "couldn't parse JSON: \(error.localizedDescription) — first 400 bytes of stdout: \(preview)"
            )
        }
        let detections = wire.toDetections(detectorID: id, volume: volume)
        progress("✓ Detection complete · \(detections.count) findings")
        return detections
    }

    /// Same launch-arg composition as `SubprocessPETACCorrector` —
    /// /usr/bin/env, direct python path, or shell wrapper. Tested.
    static func composeLaunchArguments(executable: String,
                                       script: String,
                                       extraArgs: [String]) -> [String] {
        let exeName = (executable as NSString).lastPathComponent
        if exeName == "env" {
            return ["python3", script] + extraArgs
        }
        if exeName.hasPrefix("python") {
            return [script] + extraArgs
        }
        return [script] + extraArgs
    }
}
