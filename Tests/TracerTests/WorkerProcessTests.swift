import XCTest
@testable import Tracer

final class WorkerProcessTests: XCTestCase {
    func testDockerWorkerComposesGPUEnvMountAndCommand() {
        let config = DockerWorkerConfiguration(
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
