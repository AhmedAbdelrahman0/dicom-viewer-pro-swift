import Foundation

public struct WorkerProcessRequest: Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?
    public var stdinData: Data?
    public var timeoutSeconds: TimeInterval?
    public var streamStdout: Bool
    public var streamStderr: Bool

    public init(executablePath: String,
                arguments: [String] = [],
                environment: [String: String] = [:],
                workingDirectory: URL? = nil,
                stdinData: Data? = nil,
                timeoutSeconds: TimeInterval? = nil,
                streamStdout: Bool = false,
                streamStderr: Bool = true) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.stdinData = stdinData
        self.timeoutSeconds = timeoutSeconds
        self.streamStdout = streamStdout
        self.streamStderr = streamStderr
    }
}

public struct WorkerProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let timedOut: Bool
    public let stdoutData: Data
    public let stderrData: Data

    public var stdout: String { String(data: stdoutData, encoding: .utf8) ?? "" }
    public var stderr: String { String(data: stderrData, encoding: .utf8) ?? "" }
}

public enum WorkerProcessError: Error, LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut(exitCode: Int32, stderr: String)
    case nonZeroExit(exitCode: Int32, stderr: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Worker launch failed: \(message)"
        case .timedOut(let exitCode, let stderr):
            return "Worker timed out with exit \(exitCode): \(stderr)"
        case .nonZeroExit(let exitCode, let stderr):
            return "Worker exited \(exitCode): \(stderr)"
        case .cancelled:
            return "Worker was cancelled."
        }
    }
}

public protocol WorkerProcess: AnyObject, Sendable {
    func run(_ request: WorkerProcessRequest,
             logSink: @escaping @Sendable (String) -> Void) async throws -> WorkerProcessResult
    func cancel()
}

public final class LocalWorkerProcess: WorkerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: Process?
    private var cancelled = false

    public init() {}

    public func run(_ request: WorkerProcessRequest,
                    logSink: @escaping @Sendable (String) -> Void = { _ in }) async throws -> WorkerProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if request.stdinData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutBuffer.append(chunk)
            if request.streamStdout, let text = String(data: chunk, encoding: .utf8) {
                logSink(text.trimmingCharacters(in: .newlines))
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrBuffer.append(chunk)
            if request.streamStderr, let text = String(data: chunk, encoding: .utf8) {
                logSink(text.trimmingCharacters(in: .newlines))
            }
        }

        let canStart = withLock {
            if cancelled { return false }
            activeProcess = process
            return true
        }
        guard canStart else { throw WorkerProcessError.cancelled }

        do {
            try process.run()
        } catch {
            withLock { activeProcess = nil }
            throw WorkerProcessError.launchFailed(error.localizedDescription)
        }

        if let stdinData = request.stdinData, let stdinPipe {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        let timedOut = await ProcessWaiter.wait(for: process,
                                                timeoutSeconds: request.timeoutSeconds)

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let wasCancelled = withLock {
            let value = cancelled
            activeProcess = nil
            return value
        }
        if wasCancelled { throw WorkerProcessError.cancelled }

        let result = WorkerProcessResult(exitCode: process.terminationStatus,
                                         timedOut: timedOut,
                                         stdoutData: stdoutBuffer.data(),
                                         stderrData: stderrBuffer.data())
        if timedOut {
            throw WorkerProcessError.timedOut(exitCode: result.exitCode, stderr: result.stderr)
        }
        if result.exitCode != 0 {
            throw WorkerProcessError.nonZeroExit(exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    public func cancel() {
        withLock {
            cancelled = true
            activeProcess?.interrupt()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

public struct DockerWorkerMount: Equatable, Codable, Sendable {
    public enum Access: String, Codable, Sendable {
        case readOnly
        case readWrite
    }

    public var hostPath: String
    public var containerPath: String
    public var access: Access

    public init(hostPath: String, containerPath: String, access: Access = .readWrite) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.access = access
    }
}

public struct DockerWorkerConfiguration: Equatable, Codable, Sendable {
    public var dockerExecutable: String
    public var image: String
    public var mounts: [DockerWorkerMount]
    public var enableGPU: Bool
    public var removeContainer: Bool
    public var additionalArguments: [String]

    public init(dockerExecutable: String = "/usr/bin/env",
                image: String,
                mounts: [DockerWorkerMount] = [],
                enableGPU: Bool = true,
                removeContainer: Bool = true,
                additionalArguments: [String] = []) {
        self.dockerExecutable = dockerExecutable
        self.image = image
        self.mounts = mounts
        self.enableGPU = enableGPU
        self.removeContainer = removeContainer
        self.additionalArguments = additionalArguments
    }
}

public final class DockerWorkerProcess: WorkerProcess, @unchecked Sendable {
    private let configuration: DockerWorkerConfiguration
    private let local: LocalWorkerProcess

    public init(configuration: DockerWorkerConfiguration,
                local: LocalWorkerProcess = LocalWorkerProcess()) {
        self.configuration = configuration
        self.local = local
    }

    public func run(_ request: WorkerProcessRequest,
                    logSink: @escaping @Sendable (String) -> Void = { _ in }) async throws -> WorkerProcessResult {
        let args = Self.composeDockerRunArguments(configuration: configuration, request: request)
        let dockerRequest = WorkerProcessRequest(
            executablePath: configuration.dockerExecutable,
            arguments: args,
            environment: ProcessInfo.processInfo.environment,
            stdinData: request.stdinData,
            timeoutSeconds: request.timeoutSeconds,
            streamStdout: request.streamStdout,
            streamStderr: request.streamStderr
        )
        return try await local.run(dockerRequest, logSink: logSink)
    }

    public func cancel() {
        local.cancel()
    }

    public static func composeDockerRunArguments(configuration: DockerWorkerConfiguration,
                                                 request: WorkerProcessRequest) -> [String] {
        var args = ["docker", "run"]
        if configuration.removeContainer {
            args.append("--rm")
        }
        if configuration.enableGPU {
            args.append(contentsOf: ["--gpus", "all"])
        }
        for mount in configuration.mounts {
            let mode = mount.access == .readOnly ? ":ro" : ""
            args.append(contentsOf: ["-v", "\(mount.hostPath):\(mount.containerPath)\(mode)"])
        }
        for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        if let workingDirectory = request.workingDirectory {
            args.append(contentsOf: ["-w", workingDirectory.path])
        }
        args.append(contentsOf: configuration.additionalArguments)
        args.append(configuration.image)
        args.append(request.executablePath)
        args.append(contentsOf: request.arguments)
        return args
    }
}
