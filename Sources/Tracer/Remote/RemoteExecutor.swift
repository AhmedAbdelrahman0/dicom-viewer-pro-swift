import Foundation

/// Generic SSH / scp wrapper used by every remote runner (nnU-Net,
/// classifier, MedGemma). Shells out to the user's `/usr/bin/ssh` and
/// `/usr/bin/scp` binaries rather than linking libssh — that buys us zero
/// extra dependencies and honours the user's `~/.ssh/config`, agent,
/// known_hosts, and Touch ID-protected keys for free.
///
/// The executor is purpose-built for Tracer's upload → run → download
/// pattern:
///
///   1. `uploadFile(_:toRemote:)` — scp a single file up
///   2. `uploadDirectory(_:toRemote:)` — scp a directory tree up
///   3. `run(_:)` — ssh a command, capture stdout/stderr
///   4. `downloadFile(_:toLocal:)` — scp a result file back
///   5. `remove(_:)` — clean up a remote path
public final class RemoteExecutor: @unchecked Sendable {

    public let config: DGXSparkConfig

    public init(config: DGXSparkConfig) {
        self.config = config
    }

    // MARK: - Errors

    public enum Error: Swift.Error, LocalizedError {
        case notConfigured
        case commandFailed(exitCode: Int32, stderr: String)
        case uploadFailed(String)
        case downloadFailed(String)
        case binaryMissing(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "DGX Spark config is missing a host. Configure it in Settings → DGX Spark."
            case .commandFailed(let code, let stderr):
                let clipped = stderr.count > 600 ? String(stderr.suffix(600)) : stderr
                return "SSH command exited \(code): \(clipped)"
            case .uploadFailed(let m):
                return "scp upload failed: \(m)"
            case .downloadFailed(let m):
                return "scp download failed: \(m)"
            case .binaryMissing(let name):
                return "Local binary not found: \(name) (is OpenSSH installed?)"
            }
        }
    }

    public struct RunResult {
        public let exitCode: Int32
        public let stdout: Data
        public let stderr: String
    }

    // MARK: - Commands

    /// Run a command on the remote host.  The command string goes through
    /// `sh -c` on the other end, so redirection / pipes work as written.
    /// Environment variables from `DGXSparkConfig.remoteEnvironment` are
    /// exported before the command.
    @discardableResult
    public func run(_ command: String,
                    timeoutSeconds: TimeInterval? = nil) throws -> RunResult {
        guard config.isConfigured else { throw Error.notConfigured }

        var prefix = ""
        let envs = config.environmentExports()
        if !envs.isEmpty {
            prefix = envs.compactMap(Self.shellExportCommand).joined(separator: " ") + " "
        }
        let full = prefix + command

        var args: [String] = []
        if !config.identityFile.isEmpty {
            args.append(contentsOf: ["-i", (config.identityFile as NSString).expandingTildeInPath])
        }
        args.append(contentsOf: [
            "-p", String(config.port),
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            config.sshDestination,
            full
        ])
        return try runLocalBinary(path: "/usr/bin/ssh",
                                  arguments: args,
                                  timeoutSeconds: timeoutSeconds)
    }

    /// Upload a single file to `remotePath` on the DGX. Creates the
    /// remote parent directory first.
    public func uploadFile(_ localURL: URL, toRemote remotePath: String) throws {
        try ensureRemoteDirectory((remotePath as NSString).deletingLastPathComponent)
        var args: [String] = []
        if !config.identityFile.isEmpty {
            args.append(contentsOf: ["-i", (config.identityFile as NSString).expandingTildeInPath])
        }
        args.append(contentsOf: [
            "-P", String(config.port),
            "-q",
            localURL.path,
            "\(config.sshDestination):\(remotePath)"
        ])
        let result = try runLocalBinary(path: "/usr/bin/scp", arguments: args)
        if result.exitCode != 0 {
            throw Error.uploadFailed("exit \(result.exitCode): \(result.stderr)")
        }
    }

    /// Upload a directory tree recursively.
    public func uploadDirectory(_ localURL: URL, toRemote remotePath: String) throws {
        try ensureRemoteDirectory((remotePath as NSString).deletingLastPathComponent)
        var args: [String] = []
        if !config.identityFile.isEmpty {
            args.append(contentsOf: ["-i", (config.identityFile as NSString).expandingTildeInPath])
        }
        args.append(contentsOf: [
            "-P", String(config.port),
            "-r",
            "-q",
            localURL.path,
            "\(config.sshDestination):\(remotePath)"
        ])
        let result = try runLocalBinary(path: "/usr/bin/scp", arguments: args)
        if result.exitCode != 0 {
            throw Error.uploadFailed("exit \(result.exitCode): \(result.stderr)")
        }
    }

    /// Pull a single remote file down to `localURL`.
    public func downloadFile(_ remotePath: String, toLocal localURL: URL) throws {
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var args: [String] = []
        if !config.identityFile.isEmpty {
            args.append(contentsOf: ["-i", (config.identityFile as NSString).expandingTildeInPath])
        }
        args.append(contentsOf: [
            "-P", String(config.port),
            "-q",
            "\(config.sshDestination):\(remotePath)",
            localURL.path
        ])
        let result = try runLocalBinary(path: "/usr/bin/scp", arguments: args)
        if result.exitCode != 0 {
            throw Error.downloadFailed("exit \(result.exitCode): \(result.stderr)")
        }
    }

    /// Remove a file or directory on the remote host. Swallows "not found"
    /// errors because cleanup is always best-effort.
    public func remove(_ remotePath: String) {
        _ = try? run("rm -rf -- \(Self.shellEscape(remotePath))")
    }

    public func ensureRemoteDirectory(_ path: String) throws {
        let expanded = path.hasPrefix("~") ? "~" + path.dropFirst() : path
        _ = try run("mkdir -p -- \(Self.shellEscape(expanded))")
    }

    // MARK: - SSH health

    /// Quick handshake test — runs `uname -a && nvidia-smi --version | head -1`
    /// so the settings panel can show "connected ✓" with a one-line banner.
    public func probe() throws -> String {
        let result = try run("uname -a && (nvidia-smi --version 2>/dev/null | head -1 || echo 'no nvidia-smi')")
        if result.exitCode != 0 {
            throw Error.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }

    // MARK: - Internals

    private func runLocalBinary(path: String,
                                arguments: [String],
                                timeoutSeconds: TimeInterval? = nil) throws -> RunResult {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw Error.binaryMissing(path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutBuffer.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrBuffer.append(handle.availableData)
        }

        try process.run()

        let timer: DispatchSourceTimer? = timeoutSeconds.map {
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now() + $0)
            t.setEventHandler { [weak process] in process?.terminate() }
            t.resume()
            return t
        }

        process.waitUntilExit()
        timer?.cancel()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let stdout = stdoutBuffer.data()
        let stderr = stderrBuffer.string()
        return RunResult(exitCode: process.terminationStatus,
                         stdout: stdout,
                         stderr: stderr)
    }

    /// Minimal POSIX-shell escape. Single-quotes the input and escapes
    /// internal single quotes with `'\''`. Matches what Python's shlex.quote
    /// does — suitable for anything we're passing to the remote `sh -c`.
    public static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func shellExportCommand(_ assignment: String) -> String? {
        let pieces = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
                        options: .regularExpression) != nil else {
            return nil
        }
        let value = String(pieces[1])
        return "export \(key)=\(shellEscape(value));"
    }
}
