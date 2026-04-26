import Foundation

public enum PETMRDeformableBackend: String, CaseIterable, Identifiable, Codable, Sendable {
    case internalBodyEnvelope
    case antsSyN
    case synthMorph
    case voxelMorph
    case customScript

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .internalBodyEnvelope: return "Internal body warp"
        case .antsSyN: return "ANTs SyN"
        case .synthMorph: return "SynthMorph"
        case .voxelMorph: return "VoxelMorph"
        case .customScript: return "Custom script"
        }
    }

    public var needsExternalRunner: Bool {
        self != .internalBodyEnvelope
    }

    public var defaultExecutableName: String {
        switch self {
        case .internalBodyEnvelope: return ""
        case .antsSyN: return "antsRegistration"
        case .synthMorph: return "mri_synthmorph"
        case .voxelMorph: return "python3"
        case .customScript: return ""
        }
    }

    public var adapterHelp: String {
        switch self {
        case .internalBodyEnvelope:
            return "Uses Tracer's built-in body-envelope alignment. No external tools required."
        case .antsSyN:
            return "Runs antsRegistration with rigid/affine/SyN stages and reads the warped PET NIfTI output."
        case .synthMorph:
            return "Runs a SynthMorph-compatible wrapper. The app passes --fixed, --moving, --output, --transform, and optional --model."
        case .voxelMorph:
            return "Runs a VoxelMorph-compatible Python wrapper. The app passes --fixed, --moving, --output, --transform, and optional --model."
        case .customScript:
            return "Runs any executable that accepts --fixed, --moving, --output, --transform, and optional --model."
        }
    }
}

public enum PETMRRegistrationMetricPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case multimodalMI
    case sameContrastCC
    case hybridMIAndCC

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .multimodalMI: return "Multimodal MI"
        case .sameContrastCC: return "Same-contrast CC"
        case .hybridMIAndCC: return "Hybrid MI + CC"
        }
    }

    public var helpText: String {
        switch self {
        case .multimodalMI:
            return "Mutual information for PET/MR, CT/MR, and other cross-modality registration."
        case .sameContrastCC:
            return "Local cross-correlation for same-modality or similar-contrast images."
        case .hybridMIAndCC:
            return "Uses mutual information plus cross-correlation when the modalities share enough anatomy."
        }
    }
}

public struct PETMRDeformableRegistrationConfiguration: Equatable, Sendable {
    public var backend: PETMRDeformableBackend
    public var executablePath: String
    public var modelPath: String
    public var extraArguments: String
    public var timeoutSeconds: Double
    public var metricPreset: PETMRRegistrationMetricPreset

    public init(backend: PETMRDeformableBackend = .internalBodyEnvelope,
                executablePath: String = "",
                modelPath: String = "",
                extraArguments: String = "",
                timeoutSeconds: Double = 900,
                metricPreset: PETMRRegistrationMetricPreset = .multimodalMI) {
        self.backend = backend
        self.executablePath = executablePath
        self.modelPath = modelPath
        self.extraArguments = extraArguments
        self.timeoutSeconds = timeoutSeconds
        self.metricPreset = metricPreset
    }

    public var isExternalConfigured: Bool {
        guard backend.needsExternalRunner else { return false }
        return !resolvedExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var resolvedExecutable: String {
        let trimmed = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? backend.defaultExecutableName : trimmed
    }

    public var readinessMessage: String {
        if !backend.needsExternalRunner {
            return "Internal body-envelope fallback is ready."
        }
        let exe = resolvedExecutable
        guard !exe.isEmpty else {
            return "\(backend.displayName) needs an executable or wrapper path."
        }
        if exe.contains("/") && !FileManager.default.isExecutableFile(atPath: exe) {
            return "\(backend.displayName) executable is not runnable: \(exe)"
        }
        return "\(backend.displayName) will run via \(exe)."
    }
}

public struct PETMRDeformableRegistrationResult: Sendable {
    public let warpedMoving: ImageVolume
    public let backend: PETMRDeformableBackend
    public let note: String
    public let stdout: String
    public let stderr: String
    public let durationSeconds: Double
    public let deformationQuality: DeformationFieldQuality?
}

public enum PETMRDeformableRegistrationError: Error, LocalizedError {
    case notConfigured(String)
    case launchFailed(String)
    case timedOut(Double, String)
    case failed(exitCode: Int32, stderr: String)
    case cancelled
    case outputMissing(String)
    case outputLoadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let message):
            return message
        case .launchFailed(let message):
            return "Could not launch deformable registration: \(message)"
        case .timedOut(let timeout, let stderr):
            return "Deformable registration timed out after \(Int(timeout))s\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .failed(let exitCode, let stderr):
            return "Deformable registration exited \(exitCode): \(stderr.isEmpty ? "<no stderr>" : stderr)"
        case .cancelled:
            return "Deformable registration was cancelled."
        case .outputMissing(let path):
            return "Deformable registration did not produce output: \(path)"
        case .outputLoadFailed(let message):
            return "Could not load deformable output: \(message)"
        }
    }
}

public enum PETMRDeformableRegistrationRunner {

    public static func register(fixed: ImageVolume,
                                movingPrealigned: ImageVolume,
                                configuration: PETMRDeformableRegistrationConfiguration) async throws -> PETMRDeformableRegistrationResult {
        guard configuration.backend.needsExternalRunner else {
            throw PETMRDeformableRegistrationError.notConfigured("Internal body-envelope mode does not launch an external runner.")
        }
        guard configuration.isExternalConfigured else {
            throw PETMRDeformableRegistrationError.notConfigured(configuration.readinessMessage)
        }

        let start = Date()
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("TracerPETMRRegistration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let fixedURL = workDir.appendingPathComponent("fixed_mr.nii")
        let movingURL = workDir.appendingPathComponent("moving_pet_prealigned.nii")
        let warpedURL = workDir.appendingPathComponent("warped_pet.nii")
        let transformURL = workDir.appendingPathComponent("deformable_transform.nii")
        let qaURL = workDir.appendingPathComponent("registration_qa.json")

        try NIfTIWriter.writeFloat32(fixed, to: fixedURL)
        try NIfTIWriter.writeFloat32(movingPrealigned, to: movingURL)

        let command = commandLine(configuration: configuration,
                                  fixedURL: fixedURL,
                                  movingURL: movingURL,
                                  warpedURL: warpedURL,
                                  transformURL: transformURL,
                                  workDir: workDir)
        let output = try await run(command: command,
                                   workDir: workDir,
                                   timeoutSeconds: configuration.timeoutSeconds)

        guard fm.fileExists(atPath: warpedURL.path) else {
            throw PETMRDeformableRegistrationError.outputMissing(warpedURL.path)
        }

        let warped: ImageVolume
        do {
            warped = try NIfTILoader.load(warpedURL, modalityHint: movingPrealigned.modality)
        } catch {
            throw PETMRDeformableRegistrationError.outputLoadFailed(error.localizedDescription)
        }
        let warpedOnFixedGrid: ImageVolume
        let gridNote: String
        if ImageVolumeGeometry.gridsMatch(fixed, warped) {
            warpedOnFixedGrid = warped
            gridNote = ""
        } else {
            warpedOnFixedGrid = VolumeResampler.resample(overlay: warped, toMatch: fixed, mode: .linear)
            gridNote = "; output grid was resampled to fixed MR geometry"
        }
        let deformationQuality = RegistrationQualityAssurance.loadDeformationQualitySidecar(from: qaURL)

        return PETMRDeformableRegistrationResult(
            warpedMoving: warpedOnFixedGrid,
            backend: configuration.backend,
            note: "\(configuration.backend.displayName) deformable registration finished in \(String(format: "%.1f", Date().timeIntervalSince(start)))s\(gridNote)",
            stdout: output.stdout,
            stderr: output.stderr,
            durationSeconds: Date().timeIntervalSince(start),
            deformationQuality: deformationQuality
        )
    }

    private struct CommandLine {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    private static func commandLine(configuration: PETMRDeformableRegistrationConfiguration,
                                    fixedURL: URL,
                                    movingURL: URL,
                                    warpedURL: URL,
                                    transformURL: URL,
                                    workDir: URL) -> CommandLine {
        let exe = configuration.resolvedExecutable
        let fixed = fixedURL.path
        let moving = movingURL.path
        let warped = warpedURL.path
        let transform = transformURL.path
        let extra = shellLikeSplit(configuration.extraArguments)

        switch configuration.backend {
        case .antsSyN:
            let prefix = workDir.appendingPathComponent("ants_").path
            let synMetric = antsSyNMetricArguments(configuration.metricPreset, fixed: fixed, moving: moving)
            return CommandLine(
                executable: exe,
                arguments: [
                    "--dimensionality", "3",
                    "--float", "1",
                    "--interpolation", "Linear",
                    "--output", "[\(prefix),\(warped)]",
                    "--initial-moving-transform", "[\(fixed),\(moving),1]",
                    "--transform", "Rigid[0.1]",
                    "--metric", "MI[\(fixed),\(moving),1,32,Regular,0.25]",
                    "--convergence", "[100x50x20,1e-6,10]",
                    "--shrink-factors", "4x2x1",
                    "--smoothing-sigmas", "2x1x0vox",
                    "--transform", "Affine[0.1]",
                    "--metric", "MI[\(fixed),\(moving),1,32,Regular,0.25]",
                    "--convergence", "[100x50x20,1e-6,10]",
                    "--shrink-factors", "4x2x1",
                    "--smoothing-sigmas", "2x1x0vox",
                    "--transform", "SyN[0.08,3,0]",
                ] + synMetric + [
                    "--convergence", "[60x40x20,1e-6,10]",
                    "--shrink-factors", "4x2x1",
                    "--smoothing-sigmas", "2x1x0vox"
                ] + extra,
                environment: ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment)
            )

        case .synthMorph, .voxelMorph, .customScript:
            var args = [
                "--fixed", fixed,
                "--moving", moving,
                "--output", warped,
                "--transform", transform
            ]
            let model = configuration.modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty {
                args += ["--model", model]
            }
            args += extra
            return CommandLine(
                executable: exe,
                arguments: args,
                environment: ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment)
            )

        case .internalBodyEnvelope:
            return CommandLine(executable: "", arguments: [], environment: [:])
        }
    }

    private static func antsSyNMetricArguments(_ preset: PETMRRegistrationMetricPreset,
                                               fixed: String,
                                               moving: String) -> [String] {
        switch preset {
        case .multimodalMI:
            return ["--metric", "MI[\(fixed),\(moving),1,32,Regular,0.25]"]
        case .sameContrastCC:
            return ["--metric", "CC[\(fixed),\(moving),1,4]"]
        case .hybridMIAndCC:
            return [
                "--metric", "MI[\(fixed),\(moving),0.7,32,Regular,0.25]",
                "--metric", "CC[\(fixed),\(moving),0.3,4]"
            ]
        }
    }

    private static func run(command: CommandLine,
                            workDir: URL,
                            timeoutSeconds: Double) async throws -> (stdout: String, stderr: String) {
        let executablePath: String
        let arguments: [String]
        if command.executable.contains("/") {
            executablePath = command.executable
            arguments = command.arguments
        } else {
            executablePath = "/usr/bin/env"
            arguments = [command.executable] + command.arguments
        }

        do {
            let result = try await LocalWorkerProcess().run(WorkerProcessRequest(
                executablePath: executablePath,
                arguments: arguments,
                environment: command.environment,
                workingDirectory: workDir,
                timeoutSeconds: max(1, timeoutSeconds),
                streamStdout: false,
                streamStderr: true
            ))
            return (result.stdout, result.stderr)
        } catch WorkerProcessError.cancelled {
            throw PETMRDeformableRegistrationError.cancelled
        } catch WorkerProcessError.launchFailed(let message) {
            throw PETMRDeformableRegistrationError.launchFailed(message)
        } catch WorkerProcessError.timedOut(_, let stderr) {
            throw PETMRDeformableRegistrationError.timedOut(timeoutSeconds, stderr)
        } catch WorkerProcessError.nonZeroExit(let exitCode, let stderr) {
            throw PETMRDeformableRegistrationError.failed(exitCode: exitCode, stderr: stderr)
        }
    }

    private static func shellLikeSplit(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(character)
            }
        }

        if escaping {
            current.append("\\")
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
