import XCTest
@testable import Tracer

final class WorkerProcessTests: XCTestCase {
    func testDockerWorkerComposesGPUEnvMountAndCommand() {
        let config = DockerWorkerConfiguration(
            containerCommand: "docker",
            image: "ghcr.io/example/tracer-nnunet:latest",
            mounts: [
                DockerWorkerMount(hostPath: "/host/data", containerPath: "/data", access: .readOnly),
                DockerWorkerMount(hostPath: "/host/out", containerPath: "/out", access: .readWrite)
            ],
            enableGPU: true,
            additionalArguments: ["--ipc=host"]
        )
        let request = WorkerProcessRequest(
            executablePath: "nnUNetv2_predict",
            arguments: ["-i", "/data/in", "-o", "/out"],
            environment: ["nnUNet_results": "/models"],
            workingDirectory: URL(fileURLWithPath: "/workspace"),
            timeoutSeconds: 60
        )

        let args = DockerWorkerProcess.composeDockerRunArguments(configuration: config,
                                                                 request: request)

        XCTAssertEqual(args.prefix(4), ["docker", "run", "--rm", "--gpus"])
        XCTAssertTrue(args.contains("all"))
        XCTAssertTrue(args.contains("/host/data:/data:ro"))
        XCTAssertTrue(args.contains("/host/out:/out"))
        XCTAssertTrue(args.contains("nnUNet_results=/models"))
        XCTAssertTrue(args.contains("--ipc=host"))
        XCTAssertEqual(args.suffix(5), ["nnUNetv2_predict", "-i", "/data/in", "-o", "/out"])
    }

    func testDockerWorkerCanComposePodmanCommand() {
        let config = DockerWorkerConfiguration(
            dockerExecutable: "/usr/bin/env",
            containerCommand: "podman",
            image: "localhost/tracer-worker:test",
            enableGPU: true
        )
        let request = WorkerProcessRequest(executablePath: "python3", arguments: ["--version"])

        let args = DockerWorkerProcess.composeDockerRunArguments(configuration: config,
                                                                 request: request)

        XCTAssertEqual(args.prefix(3), ["podman", "run", "--rm"])
        XCTAssertFalse(args.contains("--gpus"))
        XCTAssertEqual(args.suffix(2), ["python3", "--version"])
    }

    func testDockerWorkerConfigurationDecodesLegacyPayload() throws {
        let data = Data("""
        {
          "dockerExecutable": "/usr/bin/env",
          "image": "ghcr.io/example/tracer-worker:latest",
          "mounts": [],
          "enableGPU": false,
          "removeContainer": true,
          "additionalArguments": []
        }
        """.utf8)

        let config = try JSONDecoder().decode(DockerWorkerConfiguration.self, from: data)

        XCTAssertEqual(config.dockerExecutable, "/usr/bin/env")
        XCTAssertEqual(config.image, "ghcr.io/example/tracer-worker:latest")
        XCTAssertFalse(config.containerCommand.isEmpty)
    }

    func testDefaultContainerCommandUsesExplicitRuntimeOverride() {
        let command = DockerWorkerConfiguration.defaultContainerCommand(environment: [
            "TRACER_CONTAINER_RUNTIME": "podman",
            "PATH": "/definitely/not/a/runtime/path"
        ])

        XCTAssertEqual(command, "podman")
    }

    func testDefaultContainerCommandFindsDockerBeforePodmanOnPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let docker = directory.appendingPathComponent("docker")
        let podman = directory.appendingPathComponent("podman")
        FileManager.default.createFile(atPath: docker.path, contents: Data())
        FileManager.default.createFile(atPath: podman.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: docker.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: podman.path)

        let command = DockerWorkerConfiguration.defaultContainerCommand(environment: [
            "PATH": directory.path
        ])

        XCTAssertEqual(command, docker.path)
    }

    func testRuntimeExecutableSearchUsesFallbackDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-runtime-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let docker = try makeExecutable(named: "docker", in: directory)

        let command = DockerWorkerConfiguration.firstRuntimeExecutable(
            named: "docker",
            environment: ["PATH": "/usr/bin:/bin"],
            fileManager: .default,
            additionalSearchDirectories: [directory.path]
        )

        XCTAssertEqual(command, docker.path)
    }

    func testContainerRuntimeSetupPlanDetectsInstalledTools() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-runtime-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let brew = try makeExecutable(named: "brew", in: directory)
        let docker = try makeExecutable(named: "docker", in: directory)
        let colima = try makeExecutable(named: "colima", in: directory)

        let plan = ContainerRuntimeSetupPlan.assess(
            environment: ["PATH": directory.path],
            fileManager: .default,
            additionalSearchDirectories: []
        )

        XCTAssertEqual(plan.homebrewPath, brew.path)
        XCTAssertEqual(plan.dockerPath, docker.path)
        XCTAssertEqual(plan.colimaPath, colima.path)
        XCTAssertTrue(plan.isComplete)
        XCTAssertTrue(plan.canInstallWithHomebrew)
        XCTAssertTrue(plan.missingTools.isEmpty)
    }

    func testContainerRuntimeSetupPlanRequiresHomebrewWhenInstallerIsMissing() {
        let plan = ContainerRuntimeSetupPlan.assess(
            environment: ["PATH": "/definitely/not/a/runtime/path"],
            fileManager: .default,
            additionalSearchDirectories: []
        )

        XCTAssertNil(plan.homebrewPath)
        XCTAssertNil(plan.dockerPath)
        XCTAssertNil(plan.colimaPath)
        XCTAssertFalse(plan.isComplete)
        XCTAssertFalse(plan.canInstallWithHomebrew)
        XCTAssertEqual(plan.missingTools, ["Docker CLI", "Colima"])
    }

    func testContainerRuntimeSetupStoreComposesHomebrewInstallRequest() {
        let request = ContainerRuntimeSetupStore.homebrewInstallRequest(
            homebrewPath: "/opt/homebrew/bin/brew",
            environment: ["HOME": "/Users/tester"]
        )

        XCTAssertEqual(request.executablePath, "/usr/bin/env")
        XCTAssertEqual(request.arguments, ["/opt/homebrew/bin/brew", "install", "docker", "colima"])
        XCTAssertEqual(request.environment["HOME"], "/Users/tester")
        XCTAssertEqual(request.timeoutSeconds, 1_200)
        XCTAssertFalse(request.streamStdout)
        XCTAssertFalse(request.streamStderr)
    }

    func testPodmanRuntimeEnvironmentUsesFallbackWhenHomeConfigHasDifferentOwner() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-podman-home-\(UUID().uuidString)")
        let config = home.appendingPathComponent(".config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let environment = DockerWorkerConfiguration.runtimeEnvironment(
            base: ["HOME": home.path],
            containerCommand: "/opt/homebrew/bin/podman",
            currentUserID: UInt32.max
        )

        XCTAssertEqual(environment["XDG_CONFIG_HOME"],
                       home.appendingPathComponent(".tracer-podman-config", isDirectory: true).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment["XDG_CONFIG_HOME"] ?? ""))
    }

    func testDockerRuntimeEnvironmentUsesFallbackConfigAndColimaSocket() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-docker-home-\(UUID().uuidString)")
        let docker = home.appendingPathComponent(".docker", isDirectory: true)
        let colima = home.appendingPathComponent(".colima/default", isDirectory: true)
        let socket = colima.appendingPathComponent("docker.sock")
        try FileManager.default.createDirectory(at: docker, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: colima, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: home) }

        let environment = DockerWorkerConfiguration.runtimeEnvironment(
            base: ["HOME": home.path],
            containerCommand: "/opt/homebrew/bin/docker",
            currentUserID: UInt32.max
        )

        XCTAssertEqual(environment["DOCKER_CONFIG"],
                       home.appendingPathComponent(".tracer-docker-config", isDirectory: true).path)
        XCTAssertEqual(environment["DOCKER_HOST"], "unix://\(socket.path)")
    }

    func testLocalWorkerCapturesStdoutAndStderr() async throws {
        let result = try await LocalWorkerProcess().run(WorkerProcessRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf hello; printf warn 1>&2"],
            timeoutSeconds: 5,
            streamStdout: false,
            streamStderr: false
        ))

        XCTAssertEqual(result.stdout, "hello")
        XCTAssertEqual(result.stderr, "warn")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testContainerRuntimeBootstrapperCanBeDisabledByEnvironment() async {
        let process = RecordingWorkerProcess(outcomes: [])
        let bootstrapper = ContainerRuntimeBootstrapper(process: process)

        let result = await bootstrapper.bootstrapAtLaunch(
            environment: [ContainerRuntimeBootstrapper.disabledEnvironmentKey: "true"],
            userPreference: true
        )

        XCTAssertEqual(result, .disabled)
        XCTAssertTrue(process.recordedRequests().isEmpty)
    }

    func testContainerRuntimeBootstrapperSkipsStartWhenDockerIsReady() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-bootstrap-ready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let docker = try makeExecutable(named: "docker", in: directory)
        let process = RecordingWorkerProcess(outcomes: [
            .success(WorkerProcessResult(exitCode: 0,
                                         timedOut: false,
                                         stdoutData: Data(),
                                         stderrData: Data()))
        ])
        let bootstrapper = ContainerRuntimeBootstrapper(process: process)

        let result = await bootstrapper.bootstrapAtLaunch(
            environment: ["PATH": directory.path],
            userPreference: true
        )

        XCTAssertEqual(result, .ready(containerCommand: docker.path))
        let requests = process.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [[docker.path, "version"]])
    }

    func testContainerRuntimeBootstrapperStartsColimaWhenDockerIsDown() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-bootstrap-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let docker = try makeExecutable(named: "docker", in: directory)
        let colima = try makeExecutable(named: "colima", in: directory)
        let process = RecordingWorkerProcess(outcomes: [
            .failure(WorkerProcessError.nonZeroExit(exitCode: 1, stderr: "daemon down")),
            .success(WorkerProcessResult(exitCode: 0,
                                         timedOut: false,
                                         stdoutData: Data(),
                                         stderrData: Data())),
            .success(WorkerProcessResult(exitCode: 0,
                                         timedOut: false,
                                         stdoutData: Data(),
                                         stderrData: Data()))
        ])
        let bootstrapper = ContainerRuntimeBootstrapper(process: process)

        let result = await bootstrapper.bootstrapAtLaunch(
            environment: ["PATH": directory.path],
            userPreference: true
        )

        XCTAssertEqual(result, .started(containerCommand: docker.path))
        let requests = process.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [
            [docker.path, "version"],
            [colima.path, "start", "--runtime", "docker"],
            [docker.path, "version"]
        ])
    }

    func testContainerRuntimeBootstrapperDoesNotAutostartPodman() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-bootstrap-podman-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let podman = try makeExecutable(named: "podman", in: directory)
        let process = RecordingWorkerProcess(outcomes: [
            .failure(WorkerProcessError.nonZeroExit(exitCode: 1, stderr: "machine down"))
        ])
        let bootstrapper = ContainerRuntimeBootstrapper(process: process)

        let result = await bootstrapper.bootstrapAtLaunch(
            environment: [
                "PATH": directory.path,
                "TRACER_CONTAINER_RUNTIME": podman.path
            ],
            userPreference: true
        )

        if case .unavailable(let reason) = result {
            XCTAssertTrue(reason.contains("Docker/Colima"))
        } else {
            XCTFail("Expected Podman startup to be unavailable, got \(result)")
        }
        XCTAssertEqual(process.recordedRequests().map(\.arguments), [[podman.path, "version"]])
    }

    @discardableResult
    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }
}

private final class RecordingWorkerProcess: WorkerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<WorkerProcessResult, Error>]
    private var requests: [WorkerProcessRequest] = []

    init(outcomes: [Result<WorkerProcessResult, Error>]) {
        self.outcomes = outcomes
    }

    func run(_ request: WorkerProcessRequest,
             logSink: @escaping @Sendable (String) -> Void) async throws -> WorkerProcessResult {
        let outcome: Result<WorkerProcessResult, Error> = withLock {
            requests.append(request)
            guard !outcomes.isEmpty else {
                return .failure(WorkerProcessError.nonZeroExit(exitCode: 1,
                                                               stderr: "missing test outcome"))
            }
            return outcomes.removeFirst()
        }

        switch outcome {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    func cancel() {}

    func recordedRequests() -> [WorkerProcessRequest] {
        withLock { requests }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
