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
}
