import Foundation

public final class RemoteGAAINReferenceBuilder: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var dgx: DGXSparkConfig
        public var remoteDataRoot: String
        public var timeoutSeconds: TimeInterval
        public var uploadArchivesIfMissing: Bool
        public var removeRemoteScratch: Bool

        public init(dgx: DGXSparkConfig,
                    remoteDataRoot: String? = nil,
                    timeoutSeconds: TimeInterval = 24 * 60 * 60,
                    uploadArchivesIfMissing: Bool = true,
                    removeRemoteScratch: Bool = false) {
            self.dgx = dgx
            self.remoteDataRoot = remoteDataRoot ?? "\(dgx.remoteWorkdir)/gaain-centiloid-data"
            self.timeoutSeconds = timeoutSeconds
            self.uploadArchivesIfMissing = uploadArchivesIfMissing
            self.removeRemoteScratch = removeRemoteScratch
        }
    }

    public struct Result: Equatable, Sendable {
        public let localOutputRoot: URL
        public let remoteOutputRoot: String
        public let remoteDataRoot: String
        public let durationSeconds: TimeInterval
        public let artifactPaths: [String]
        public let stderr: String
    }

    public enum Error: Swift.Error, LocalizedError {
        case notConfigured
        case missingLocalFile(String)
        case remoteFailed(String)
        case missingResultsArchive(String)
        case extractionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "DGX Spark is not configured. Configure Settings -> DGX Spark first."
            case .missingLocalFile(let path):
                return "Local GAAIN file is missing: \(path)."
            case .remoteFailed(let message):
                return "GAAIN Spark build failed: \(message)"
            case .missingResultsArchive(let path):
                return "GAAIN Spark build did not produce results archive: \(path)."
            case .extractionFailed(let message):
                return "Could not unpack GAAIN Spark results: \(message)"
            }
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func run(package: GAAINReferenceBuildPackage,
                    logSink: @escaping @Sendable (String) -> Void = { _ in }) throws -> Result {
        guard configuration.dgx.isConfigured else { throw Error.notConfigured }

        let executor = RemoteExecutor(config: configuration.dgx)
        let runID = "gaain-reference-\(UUID().uuidString.prefix(8))"
        let remoteBase = "\(configuration.dgx.remoteWorkdir)/\(runID)"
        let remotePackage = "\(remoteBase)/package"
        let remoteOutput = "\(remoteBase)/output"
        let remoteResultsTGZ = "\(remoteBase)/results.tgz"
        let started = Date()

        defer {
            if configuration.removeRemoteScratch {
                executor.remove(remoteBase)
            }
        }

        logSink("Preparing GAAIN Spark build at \(configuration.dgx.sshDestination):\(remoteBase)\n")
        try executor.ensureRemoteDirectory(remotePackage)
        try executor.ensureRemoteDirectory(remoteOutput)
        try executor.ensureRemoteDirectory(configuration.remoteDataRoot)

        let remotePlan = GAAINReferencePipeline.remoteExecutionPlan(
            from: package.plan,
            sourceRoot: configuration.remoteDataRoot,
            outputRoot: remoteOutput
        )
        let localRemotePackage = try makeRemotePackage(package: package, plan: remotePlan)
        defer { try? FileManager.default.removeItem(at: localRemotePackage) }

        try uploadPackage(localRemotePackage,
                          remotePackage: remotePackage,
                          executor: executor,
                          logSink: logSink)

        if configuration.uploadArchivesIfMissing {
            try syncGAAINArchives(summary: package.summary,
                                  remoteDataRoot: configuration.remoteDataRoot,
                                  executor: executor,
                                  logSink: logSink)
        } else {
            logSink("Archive upload disabled; expecting data at \(configuration.remoteDataRoot)\n")
        }

        let remotePlanPath = "\(remotePackage)/gaain_reference_build_plan.json"
        let remoteWorkerPath = "\(remotePackage)/gaain_reference_build.py"
        let command = [
            "chmod +x \(RemoteExecutor.shellPath(remoteWorkerPath))",
            "python3 \(RemoteExecutor.shellPath(remoteWorkerPath)) --plan \(RemoteExecutor.shellPath(remotePlanPath)) --output \(RemoteExecutor.shellPath(remoteOutput)) --extract",
            "tar -C \(RemoteExecutor.shellPath(remoteOutput)) -czf \(RemoteExecutor.shellPath(remoteResultsTGZ)) ."
        ].joined(separator: " && ")

        logSink("Launching GAAIN reference build on Spark\n")
        let result = try executor.run(command,
                                      timeoutSeconds: configuration.timeoutSeconds,
                                      logSink: logSink)
        guard result.exitCode == 0 else {
            throw Error.remoteFailed(result.stderr)
        }

        let localOutputRoot = package.rootURL
            .appendingPathComponent("remote-results", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: localOutputRoot, withIntermediateDirectories: true)
        let localTGZ = localOutputRoot.appendingPathComponent("results.tgz")
        do {
            try executor.downloadFile(remoteResultsTGZ, toLocal: localTGZ)
        } catch {
            throw Error.missingResultsArchive(remoteResultsTGZ)
        }
        try extractTarGzip(localTGZ, into: localOutputRoot)
        let artifactPaths = try collectArtifacts(localOutputRoot)
        logSink("Pulled \(artifactPaths.count) GAAIN result artifact(s) to \(localOutputRoot.path)\n")

        return Result(localOutputRoot: localOutputRoot,
                      remoteOutputRoot: remoteOutput,
                      remoteDataRoot: configuration.remoteDataRoot,
                      durationSeconds: Date().timeIntervalSince(started),
                      artifactPaths: artifactPaths,
                      stderr: result.stderr)
    }

    private func makeRemotePackage(package: GAAINReferenceBuildPackage,
                                   plan: GAAINReferenceBuildPlan) throws -> URL {
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracer-gaain-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(plan)
            .write(to: localRoot.appendingPathComponent("gaain_reference_build_plan.json"), options: .atomic)
        try FileManager.default.copyItem(at: package.workerScriptURL,
                                         to: localRoot.appendingPathComponent("gaain_reference_build.py"))
        try FileManager.default.copyItem(at: package.readmeURL,
                                         to: localRoot.appendingPathComponent("README.md"))
        let runScript = """
        #!/usr/bin/env bash
        set -euo pipefail
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        python3 "$SCRIPT_DIR/gaain_reference_build.py" --plan "$SCRIPT_DIR/gaain_reference_build_plan.json" --extract
        """
        try Data(runScript.utf8)
            .write(to: localRoot.appendingPathComponent("run_gaain_reference_build.sh"), options: .atomic)
        return localRoot
    }

    private func uploadPackage(_ localPackage: URL,
                               remotePackage: String,
                               executor: RemoteExecutor,
                               logSink: @escaping @Sendable (String) -> Void) throws {
        let files = [
            "gaain_reference_build_plan.json",
            "gaain_reference_build.py",
            "run_gaain_reference_build.sh",
            "README.md"
        ]
        for filename in files {
            let local = localPackage.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: local.path) else {
                throw Error.missingLocalFile(local.path)
            }
            logSink("Uploading package file \(filename)\n")
            try executor.uploadFile(local, toRemote: "\(remotePackage)/\(filename)")
        }
    }

    private func syncGAAINArchives(summary: GAAINReferenceDatasetSummary,
                                   remoteDataRoot: String,
                                   executor: RemoteExecutor,
                                   logSink: @escaping @Sendable (String) -> Void) throws {
        let completeFiles = summary.files
            .filter(\.isComplete)
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }

        for (index, file) in completeFiles.enumerated() {
            guard let expected = file.actualByteCount else { continue }
            let remotePath = "\(remoteDataRoot)/\(file.filename)"
            if try remoteFileSize(remotePath, executor: executor) == expected {
                logSink("Spark data \(index + 1)/\(completeFiles.count): \(file.filename) already present\n")
                continue
            }
            guard FileManager.default.fileExists(atPath: file.localPath) else {
                throw Error.missingLocalFile(file.localPath)
            }
            logSink("Uploading GAAIN \(index + 1)/\(completeFiles.count): \(file.filename) (\(formatBytes(expected)))\n")
            try executor.uploadFile(URL(fileURLWithPath: file.localPath), toRemote: remotePath)
        }
    }

    private func remoteFileSize(_ remotePath: String,
                                executor: RemoteExecutor) throws -> Int64? {
        let command = "if [ -f \(RemoteExecutor.shellPath(remotePath)) ]; then stat -c%s \(RemoteExecutor.shellPath(remotePath)); else echo MISSING; fi"
        let result = try executor.run(command, timeoutSeconds: 30)
        guard result.exitCode == 0,
              let text = String(data: result.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              text != "MISSING" else {
            return nil
        }
        return Int64(text)
    }

    private func extractTarGzip(_ archive: URL, into outputRoot: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", outputRoot.path]
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw Error.extractionFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Error.extractionFailed(message)
        }
    }

    private func collectArtifacts(_ root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else {
            return []
        }
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true,
                  url.lastPathComponent != "results.tgz" else { continue }
            paths.append(url.path)
        }
        return paths.sorted()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }
}
