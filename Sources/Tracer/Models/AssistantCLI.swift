import Foundation

public enum AssistantCLIProvider: String, CaseIterable, Identifiable, Sendable {
    case local
    case claude
    case chatGPT
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: return "Local"
        case .claude: return "Claude CLI"
        case .chatGPT: return "ChatGPT CLI"
        case .codex: return "Codex CLI"
        }
    }

    public var commandName: String? {
        switch self {
        case .local: return nil
        case .claude: return "claude"
        case .chatGPT: return "chatgpt"
        case .codex: return "codex"
        }
    }
}

public enum AssistantCLIError: LocalizedError, Sendable {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message):
            return message
        }
    }
}

public struct AssistantCLIRunner: Sendable {
    public init() {}

    public func isAvailable(_ provider: AssistantCLIProvider) -> Bool {
        guard provider != .local else { return true }
        return resolvedExecutable(for: provider) != nil
    }

    public func availabilityText(for provider: AssistantCLIProvider) -> String {
        switch provider {
        case .local:
            return "Instant viewer control"
        case .claude, .chatGPT, .codex:
            if let path = resolvedExecutable(for: provider) {
                return path
            }
            return "Not found"
        }
    }

    public func run(provider: AssistantCLIProvider,
                    prompt: String,
                    context: String,
                    imageURLs: [URL],
                    workingDirectory: URL? = nil) async throws -> String {
        guard provider != .local else {
            return "Local mode handled the viewer command directly."
        }

        guard let executable = resolvedExecutable(for: provider) else {
            throw AssistantCLIError.unavailable("\(provider.displayName) is not available on PATH or in known app locations.")
        }

        let fullPrompt = """
        You are a medical imaging workstation assistant. Be concise. Do not diagnose. \
        Help the user operate the viewer, reason about display/segmentation workflow, and suggest safe next steps. \
        If the context includes a Segmentation RAG route, treat it as the app's local label/model routing decision.

        Viewer state:
        \(context)

        Current viewport snapshots:
        \(imageURLs.map(\.path).joined(separator: "\n"))

        User request:
        \(prompt)
        """

        return try await runProcess(
            executable: executable,
            arguments: arguments(for: provider, prompt: fullPrompt, imageURLs: imageURLs),
            workingDirectory: workingDirectory
        )
    }

    private func arguments(for provider: AssistantCLIProvider,
                           prompt: String,
                           imageURLs: [URL]) -> [String] {
        switch provider {
        case .local:
            return []
        case .claude:
            return [
                "--print",
                "--output-format", "text",
                "--tools", "",
                "--no-session-persistence",
                prompt
            ]
        case .chatGPT:
            return [prompt]
        case .codex:
            var args = [
                "exec",
                "--sandbox", "read-only",
                "--skip-git-repo-check",
                "--ephemeral"
            ]
            for url in imageURLs {
                args.append(contentsOf: ["--image", url.path])
            }
            args.append(prompt)
            return args
        }
    }

    private func resolvedExecutable(for provider: AssistantCLIProvider) -> String? {
        guard let command = provider.commandName else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [String]
        switch provider {
        case .local:
            candidates = []
        case .claude:
            candidates = [
                "\(home)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"
            ]
        case .chatGPT:
            candidates = [
                "\(home)/.local/bin/chatgpt",
                "/opt/homebrew/bin/chatgpt",
                "/usr/local/bin/chatgpt"
            ]
        case .codex:
            candidates = [
                "/Applications/Codex.app/Contents/Resources/codex",
                "\(home)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ]
        }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        return findOnPATH(command)
    }

    private func findOnPATH(_ command: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func runProcess(executable: String,
                            arguments: [String],
                            workingDirectory: URL?) async throws -> String {
        #if os(macOS)
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let workingDirectory {
                process.currentDirectoryURL = workingDirectory
            }

            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error

            try process.run()

            let timedOut = await ProcessWaiter.wait(for: process, timeoutSeconds: 45)

            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            if timedOut {
                let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AssistantCLIError.failed(
                    "CLI response timed out after 45 seconds.\(message.isEmpty ? "" : " Last stderr: \(message)")"
                )
            }

            guard process.terminationStatus == 0 else {
                let message = stderr.isEmpty ? stdout : stderr
                throw AssistantCLIError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "CLI returned no text." : trimmed
        }.value
        #else
        throw AssistantCLIError.unavailable("CLI providers are available only on macOS.")
        #endif
    }
}
