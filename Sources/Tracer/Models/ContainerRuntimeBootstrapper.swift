import Foundation

public struct ContainerRuntimeBootstrapOptions: Equatable, Sendable {
    public var healthCheckTimeoutSeconds: TimeInterval
    public var startTimeoutSeconds: TimeInterval
    public var colimaStartArguments: [String]

    public init(healthCheckTimeoutSeconds: TimeInterval = 8,
                startTimeoutSeconds: TimeInterval = 180,
                colimaStartArguments: [String] = ["start", "--runtime", "docker"]) {
        self.healthCheckTimeoutSeconds = healthCheckTimeoutSeconds
        self.startTimeoutSeconds = startTimeoutSeconds
        self.colimaStartArguments = colimaStartArguments
    }
}

public enum ContainerRuntimeBootstrapResult: Equatable, Sendable {
    case disabled
    case ready(containerCommand: String)
    case started(containerCommand: String)
    case unavailable(reason: String)
    case failed(reason: String)
}

public struct ContainerRuntimeSetupPlan: Equatable, Sendable {
    public var homebrewPath: String?
    public var dockerPath: String?
    public var colimaPath: String?

    public var missingTools: [String] {
        var tools: [String] = []
        if dockerPath == nil { tools.append("Docker CLI") }
        if colimaPath == nil { tools.append("Colima") }
        return tools
    }

    public var isComplete: Bool {
        dockerPath != nil && colimaPath != nil
    }

    public var canInstallWithHomebrew: Bool {
        homebrewPath != nil
    }

    public var summary: String {
        if isComplete {
            return "Docker and Colima are installed."
        }
        let missing = missingTools.joined(separator: ", ")
        if canInstallWithHomebrew {
            return "\(missing) missing. Tracer can install them with Homebrew."
        }
        return "\(missing) missing. Install Homebrew first, then install Docker and Colima."
    }

    public init(homebrewPath: String?, dockerPath: String?, colimaPath: String?) {
        self.homebrewPath = homebrewPath
        self.dockerPath = dockerPath
        self.colimaPath = colimaPath
    }

    public static func assess(environment: [String: String] = ProcessInfo.processInfo.environment,
                              fileManager: FileManager = .default,
                              additionalSearchDirectories: [String] = ContainerRuntimeBootstrapper.defaultSearchDirectories) -> ContainerRuntimeSetupPlan {
        ContainerRuntimeSetupPlan(
            homebrewPath: ContainerRuntimeBootstrapper.executablePath(
                named: "brew",
                environment: environment,
                fileManager: fileManager,
                additionalSearchDirectories: additionalSearchDirectories
            ),
            dockerPath: ContainerRuntimeBootstrapper.executablePath(
                named: "docker",
                environment: environment,
                fileManager: fileManager,
                additionalSearchDirectories: additionalSearchDirectories
            ),
            colimaPath: ContainerRuntimeBootstrapper.executablePath(
                named: "colima",
                environment: environment,
                fileManager: fileManager,
                additionalSearchDirectories: additionalSearchDirectories
            )
        )
    }
}

@MainActor
public final class ContainerRuntimeSetupStore: ObservableObject {
    public enum Status: Equatable, Sendable {
        case idle
        case checking
        case ready(String)
        case setupRequired(ContainerRuntimeSetupPlan)
        case installing(String)
        case failed(String)
    }

    public static let shared = ContainerRuntimeSetupStore()

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var plan: ContainerRuntimeSetupPlan = .assess()

    private let process: WorkerProcess
    private let options: ContainerRuntimeBootstrapOptions

    public init(process: WorkerProcess = LocalWorkerProcess(),
                options: ContainerRuntimeBootstrapOptions = ContainerRuntimeBootstrapOptions()) {
        self.process = process
        self.options = options
    }

    public var requiresSetup: Bool {
        if case .setupRequired = status { return true }
        return false
    }

    public var isInstalling: Bool {
        if case .installing = status { return true }
        return false
    }

    @discardableResult
    public func refresh(environment: [String: String] = ProcessInfo.processInfo.environment,
                        fileManager: FileManager = .default) async -> Status {
        status = .checking
        let assessed = ContainerRuntimeSetupPlan.assess(environment: environment, fileManager: fileManager)
        plan = assessed
        if assessed.isComplete {
            status = .ready("Local runtime tools are installed.")
        } else {
            status = .setupRequired(assessed)
        }
        return status
    }

    public func installAndStart(environment: [String: String] = ProcessInfo.processInfo.environment,
                                fileManager: FileManager = .default) async {
        let assessed = ContainerRuntimeSetupPlan.assess(environment: environment, fileManager: fileManager)
        plan = assessed
        guard let homebrewPath = assessed.homebrewPath else {
            let message = "Homebrew is required before Tracer can install Docker and Colima."
            status = .failed(message)
            ActivityLogStore.shared.log(message, source: "Containers", level: .warning)
            return
        }

        status = .installing("Installing Docker and Colima with Homebrew.")
        do {
            _ = try await process.run(Self.homebrewInstallRequest(homebrewPath: homebrewPath,
                                                                  environment: environment),
                                      logSink: { _ in })
        } catch {
            let message = "Homebrew install failed: \(error.localizedDescription)"
            status = .failed(message)
            ActivityLogStore.shared.log(message, source: "Containers", level: .error)
            return
        }

        status = .installing("Starting and verifying the local runtime.")
        let bootstrapper = ContainerRuntimeBootstrapper(process: process, options: options)
        let result = await bootstrapper.bootstrapAtLaunch(environment: environment, userPreference: true, fileManager: fileManager)
        switch result {
        case .ready, .started:
            _ = await refresh(environment: environment, fileManager: fileManager)
            ActivityLogStore.shared.log("Local runtime setup complete.", source: "Containers", level: .success)
        case .disabled:
            let message = "Local runtime setup was disabled by environment."
            status = .failed(message)
            ActivityLogStore.shared.log(message, source: "Containers", level: .warning)
        case .unavailable(let reason), .failed(let reason):
            status = .failed(reason)
        }
    }

    nonisolated static func homebrewInstallRequest(homebrewPath: String,
                                                   environment: [String: String]) -> WorkerProcessRequest {
        WorkerProcessRequest(
            executablePath: "/usr/bin/env",
            arguments: [homebrewPath, "install", "docker", "colima"],
            environment: environment,
            timeoutSeconds: 1_200,
            streamStdout: false,
            streamStderr: false
        )
    }
}

public final class ContainerRuntimeBootstrapper: @unchecked Sendable {
    public static let shared = ContainerRuntimeBootstrapper()
    public static let autoStartDefaultsKey = "Tracer.ContainerRuntime.AutoStartOnLaunch"
    public static let disabledEnvironmentKey = "TRACER_DISABLE_CONTAINER_AUTOSTART"
    public static let defaultSearchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    private let process: WorkerProcess
    private let options: ContainerRuntimeBootstrapOptions
    private let lock = NSLock()
    private var launchStarted = false

    public init(process: WorkerProcess = LocalWorkerProcess(),
                options: ContainerRuntimeBootstrapOptions = ContainerRuntimeBootstrapOptions()) {
        self.process = process
        self.options = options
    }

    public func startOnAppLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard markLaunchStarted() else { return }
        let preference = Self.standardAutoStartPreference()
        Task.detached(priority: .utility) { [self] in
            await bootstrapAtLaunch(environment: environment, userPreference: preference)
        }
    }

    @discardableResult
    public func bootstrapAtLaunch(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  userPreference: Bool? = nil,
                                  fileManager: FileManager = .default) async -> ContainerRuntimeBootstrapResult {
        guard Self.isLaunchAutomationEnabled(environment: environment, userPreference: userPreference) else {
            await log("Local container runtime auto-start is disabled.", level: .info)
            return .disabled
        }

        let containerCommand = DockerWorkerConfiguration.defaultContainerCommand(
            environment: environment,
            fileManager: fileManager
        )
        let healthEnvironment = DockerWorkerConfiguration.runtimeEnvironment(
            base: environment,
            containerCommand: containerCommand,
            fileManager: fileManager
        )

        if await runtimeIsReady(containerCommand: containerCommand, environment: healthEnvironment) {
            await log("Local container runtime ready.", level: .success)
            return .ready(containerCommand: containerCommand)
        }

        guard Self.isDockerCommand(containerCommand) else {
            let reason = "Automatic startup is only available for Docker/Colima runtimes."
            await log(reason, level: .warning)
            return .unavailable(reason: reason)
        }

        guard let colimaPath = Self.executablePath(named: "colima",
                                                   environment: environment,
                                                   fileManager: fileManager) else {
            let reason = "Docker is installed, but Colima was not found for automatic startup."
            await log(reason, level: .warning)
            return .unavailable(reason: reason)
        }

        await log("Starting local container runtime with Colima.", level: .info)
        do {
            let startRequest = Self.colimaStartRequest(colimaPath: colimaPath,
                                                       environment: healthEnvironment,
                                                       options: options)
            _ = try await process.run(startRequest, logSink: { _ in })
        } catch {
            let reason = "Could not start Colima: \(error.localizedDescription)"
            await log(reason, level: .error)
            return .failed(reason: reason)
        }

        let refreshedEnvironment = DockerWorkerConfiguration.runtimeEnvironment(
            base: environment,
            containerCommand: containerCommand,
            fileManager: fileManager
        )
        if await runtimeIsReady(containerCommand: containerCommand, environment: refreshedEnvironment) {
            await log("Local container runtime ready after Colima start.", level: .success)
            return .started(containerCommand: containerCommand)
        }

        let reason = "Colima started, but Docker did not become ready before the startup check timed out."
        await log(reason, level: .warning)
        return .failed(reason: reason)
    }

    static func isLaunchAutomationEnabled(environment: [String: String],
                                          userPreference: Bool?) -> Bool {
        if let rawValue = environment[disabledEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           ["1", "true", "yes", "on"].contains(rawValue.lowercased()) {
            return false
        }
        return userPreference ?? true
    }

    static func executablePath(named name: String,
                               environment: [String: String],
                               fileManager: FileManager,
                               additionalSearchDirectories: [String] = defaultSearchDirectories) -> String? {
        DockerWorkerConfiguration.firstRuntimeExecutable(
            named: name,
            environment: environment,
            fileManager: fileManager,
            additionalSearchDirectories: additionalSearchDirectories
        )
    }

    static func healthCheckRequest(containerCommand: String,
                                   environment: [String: String],
                                   options: ContainerRuntimeBootstrapOptions) -> WorkerProcessRequest {
        WorkerProcessRequest(
            executablePath: "/usr/bin/env",
            arguments: [containerCommand, "version"],
            environment: environment,
            timeoutSeconds: options.healthCheckTimeoutSeconds,
            streamStdout: false,
            streamStderr: false
        )
    }

    static func colimaStartRequest(colimaPath: String,
                                   environment: [String: String],
                                   options: ContainerRuntimeBootstrapOptions) -> WorkerProcessRequest {
        WorkerProcessRequest(
            executablePath: "/usr/bin/env",
            arguments: [colimaPath] + options.colimaStartArguments,
            environment: environment,
            timeoutSeconds: options.startTimeoutSeconds,
            streamStdout: false,
            streamStderr: false
        )
    }

    private func runtimeIsReady(containerCommand: String,
                                environment: [String: String]) async -> Bool {
        do {
            let request = Self.healthCheckRequest(containerCommand: containerCommand,
                                                  environment: environment,
                                                  options: options)
            _ = try await process.run(request, logSink: { _ in })
            return true
        } catch {
            return false
        }
    }

    private static func standardAutoStartPreference() -> Bool? {
        guard UserDefaults.standard.object(forKey: autoStartDefaultsKey) != nil else {
            return nil
        }
        return UserDefaults.standard.bool(forKey: autoStartDefaultsKey)
    }

    private static func isDockerCommand(_ command: String) -> Bool {
        URL(fileURLWithPath: command).lastPathComponent.lowercased() == "docker"
    }

    private func markLaunchStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !launchStarted else { return false }
        launchStarted = true
        return true
    }

    private func log(_ message: String, level: ActivityLogLevel) async {
        await MainActor.run {
            ActivityLogStore.shared.log(message,
                                        source: "Containers",
                                        level: level,
                                        countAsUnread: level == .warning || level == .error)
        }
    }
}
