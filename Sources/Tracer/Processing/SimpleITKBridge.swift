import Foundation

public enum SimpleITKBridgeOperation: String, CaseIterable, Identifiable, Sendable, Codable {
    case n4BiasCorrection = "n4-bias-correction"
    case curvatureFlow = "curvature-flow"
    case histogramMatch = "histogram-match"
    case resampleToReference = "resample-to-reference"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .n4BiasCorrection:
            return "N4 Bias Correction"
        case .curvatureFlow:
            return "Curvature Flow Denoise"
        case .histogramMatch:
            return "Histogram Match"
        case .resampleToReference:
            return "Resample to Reference"
        }
    }
}

public enum SimpleITKInterpolator: String, CaseIterable, Identifiable, Sendable, Codable {
    case linear
    case nearest
    case bspline

    public var id: String { rawValue }
}

public struct SimpleITKBridgeConfiguration: Equatable, Codable, Sendable {
    public var pythonExecutablePath: String
    public var scriptPath: String?
    public var timeoutSeconds: TimeInterval
    public var environment: [String: String]

    public init(pythonExecutablePath: String = "/usr/bin/env",
                scriptPath: String? = nil,
                timeoutSeconds: TimeInterval = 900,
                environment: [String: String] = [:]) {
        self.pythonExecutablePath = pythonExecutablePath
        self.scriptPath = scriptPath
        self.timeoutSeconds = timeoutSeconds
        self.environment = environment
    }

    public func workerArguments(scriptPath: String,
                                request: SimpleITKBridgeRequest,
                                outputJSONPath: String? = nil) -> [String] {
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
            "--operation", request.operation.rawValue,
            "--input", request.inputURL.path,
            "--output", request.outputURL.path,
            "--iterations", "\(request.iterations)",
            "--time-step", "\(request.timeStep)",
            "--conductance", "\(request.conductance)",
            "--interpolator", request.interpolator.rawValue
        ])
        if let referenceURL = request.referenceURL {
            args.append(contentsOf: ["--reference", referenceURL.path])
        }
        if let spacing = request.spacing {
            args.append(contentsOf: ["--spacing", "\(spacing.x),\(spacing.y),\(spacing.z)"])
        }
        if let outputJSONPath {
            args.append(contentsOf: ["--output-json", outputJSONPath])
        }
        return args
    }

    public static func defaultScriptCandidates() -> [String] {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["TRACER_SIMPLEITK_SCRIPT"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append((env as NSString).expandingTildeInPath)
        }
        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(URL(fileURLWithPath: cwd)
            .appendingPathComponent("workers/simpleitk/bridge.py").path)
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL
                .appendingPathComponent("Workers/simpleitk/bridge.py").path)
            candidates.append(resourceURL
                .appendingPathComponent("simpleitk/bridge.py").path)
        }
        return candidates
    }
}

public struct SimpleITKBridgeRequest: Sendable {
    public var operation: SimpleITKBridgeOperation
    public var inputURL: URL
    public var outputURL: URL
    public var referenceURL: URL?
    public var spacing: (x: Double, y: Double, z: Double)?
    public var iterations: Int
    public var timeStep: Double
    public var conductance: Double
    public var interpolator: SimpleITKInterpolator

    public init(operation: SimpleITKBridgeOperation,
                inputURL: URL,
                outputURL: URL,
                referenceURL: URL? = nil,
                spacing: (x: Double, y: Double, z: Double)? = nil,
                iterations: Int = 50,
                timeStep: Double = 0.0625,
                conductance: Double = 3.0,
                interpolator: SimpleITKInterpolator = .linear) {
        self.operation = operation
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.referenceURL = referenceURL
        self.spacing = spacing
        self.iterations = iterations
        self.timeStep = timeStep
        self.conductance = conductance
        self.interpolator = interpolator
    }
}

public struct SimpleITKBridgeResult: Codable, Equatable, Sendable {
    public var operation: String
    public var output: String
    public var size: [Int]
    public var spacing: [Double]
}

public enum SimpleITKBridgeError: Error, LocalizedError, Equatable {
    case scriptNotFound
    case noOutput

    public var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return "SimpleITK worker script not found. Set TRACER_SIMPLEITK_SCRIPT or keep workers/simpleitk/bridge.py beside Tracer."
        case .noOutput:
            return "SimpleITK worker produced no result JSON."
        }
    }
}

public final class SimpleITKBridge: @unchecked Sendable {
    public var configuration: SimpleITKBridgeConfiguration
    private let makeWorker: @Sendable () -> WorkerProcess

    public init(configuration: SimpleITKBridgeConfiguration = SimpleITKBridgeConfiguration(),
                workerFactory: @escaping @Sendable () -> WorkerProcess = { LocalWorkerProcess() }) {
        self.configuration = configuration
        self.makeWorker = workerFactory
    }

    public func run(_ request: SimpleITKBridgeRequest,
                    logSink: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SimpleITKBridgeResult {
        guard let scriptPath = resolvedScriptPath() else {
            throw SimpleITKBridgeError.scriptNotFound
        }

        let outputJSON = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-simpleitk-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputJSON) }

        var env = ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment)
        env.merge(configuration.environment) { _, new in new }

        let processRequest = WorkerProcessRequest(
            executablePath: configuration.pythonExecutablePath,
            arguments: configuration.workerArguments(scriptPath: scriptPath,
                                                      request: request,
                                                      outputJSONPath: outputJSON.path),
            environment: env,
            timeoutSeconds: configuration.timeoutSeconds,
            streamStdout: false,
            streamStderr: true
        )
        let result = try await makeWorker().run(processRequest, logSink: logSink)
        let data: Data
        if FileManager.default.fileExists(atPath: outputJSON.path) {
            data = try Data(contentsOf: outputJSON)
        } else if !result.stdoutData.isEmpty {
            data = result.stdoutData
        } else {
            throw SimpleITKBridgeError.noOutput
        }
        return try JSONDecoder().decode(SimpleITKBridgeResult.self, from: data)
    }

    private func resolvedScriptPath() -> String? {
        if let configured = configuration.scriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
        }
        return SimpleITKBridgeConfiguration.defaultScriptCandidates()
            .first { FileManager.default.fileExists(atPath: $0) }
    }
}
