import Foundation

/// Connection details for the user's DGX Spark workstation. One struct
/// instance is persisted under `@AppStorage("Tracer.Prefs.DGXSpark")` and
/// shared across every remote runner.
public struct DGXSparkConfig: Codable, Equatable, Sendable {
    /// e.g. `"192.168.1.42"` or `"dgx-spark.local"`. Required.
    public var host: String
    /// SSH username on the DGX. Default `"ahmed"`.
    public var user: String
    /// SSH port. Default 22.
    public var port: Int
    /// Path to the SSH private key to use (usually `~/.ssh/id_ed25519`).
    /// Empty = use the user's default SSH agent / config.
    public var identityFile: String
    /// Remote working directory where Tracer stages NIfTI uploads and
    /// downloads results. Cleared between runs by the remote runner.
    public var remoteWorkdir: String
    /// Path to `nnUNetv2_predict` on the DGX. Empty = assume it's on `PATH`.
    public var remoteNNUnetBinary: String
    /// Path to `llama-cli` / `llama-mtmd-cli` on the DGX. Empty = PATH.
    public var remoteLlamaBinary: String
    /// Optional override for the absorbed PET Segmentator / LesionTracer
    /// nnU-Net source tree on the DGX. Empty/nil uses Tracer's known default.
    public var remoteSegmentatorSourcePath: String?
    /// Optional override for the legacy LesionTracer trained-model folder.
    /// Empty/nil uses Tracer's known default.
    public var remoteSegmentatorModelFolder: String?
    /// Reusable Docker image tag on the DGX for the LesionTracer worker.
    /// Empty/nil falls back to `tracer-lesiontracer:latest`.
    public var remoteSegmentatorWorkerImage: String?
    /// Base image used the first time Tracer bootstraps the worker image.
    /// Empty/nil falls back to NVIDIA's PyTorch 25.03 image.
    public var remoteSegmentatorBaseImage: String?
    /// Optional extra env vars to export before the remote command. KEY=VAL
    /// pairs separated by newlines. Typical use:
    /// `nnUNet_results=/home/ahmed/nnUNet_results`.
    public var remoteEnvironment: String
    /// Enable the "Use DGX Spark" toggle globally. Panels honour it
    /// per-entry, but this is the master switch.
    public var enabled: Bool

    public init(host: String = "",
                user: String = NSUserName(),
                port: Int = 22,
                identityFile: String = "",
                remoteWorkdir: String = "~/tracer-remote",
                remoteNNUnetBinary: String = "",
                remoteLlamaBinary: String = "",
                remoteSegmentatorSourcePath: String? = nil,
                remoteSegmentatorModelFolder: String? = nil,
                remoteSegmentatorWorkerImage: String? = nil,
                remoteSegmentatorBaseImage: String? = nil,
                remoteEnvironment: String = "",
                enabled: Bool = false) {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.remoteWorkdir = remoteWorkdir
        self.remoteNNUnetBinary = remoteNNUnetBinary
        self.remoteLlamaBinary = remoteLlamaBinary
        self.remoteSegmentatorSourcePath = remoteSegmentatorSourcePath
        self.remoteSegmentatorModelFolder = remoteSegmentatorModelFolder
        self.remoteSegmentatorWorkerImage = remoteSegmentatorWorkerImage
        self.remoteSegmentatorBaseImage = remoteSegmentatorBaseImage
        self.remoteEnvironment = remoteEnvironment
        self.enabled = enabled
    }

    // MARK: - Persistence

    public static let storageKey = "Tracer.Prefs.DGXSpark"

    public static func load() -> DGXSparkConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(DGXSparkConfig.self, from: data) else {
            return DGXSparkConfig()
        }
        return decoded
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
            NotificationCenter.default.post(name: .dgxSparkConfigDidChange, object: self)
        }
    }

    // MARK: - Convenience

    /// Host in `user@host` form for ssh / scp commands.
    public var sshDestination: String {
        user.isEmpty ? host : "\(user)@\(host)"
    }

    public var isConfigured: Bool {
        !host.isEmpty
    }

    /// Base environment lines — the map from KEY to VAL. Safe to dump into
    /// an `env KEY=VAL ... command` invocation.
    public func environmentExports() -> [String] {
        remoteEnvironment
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.contains("=") else { return nil }
                return trimmed
            }
    }

    public var readinessMessage: String? {
        if !enabled {
            if let detected = Self.detectedNVIDIASparkProfile(enabled: true) {
                return "DGX Spark is disabled. Detected \(detected.host); enable or apply the detected profile in Settings."
            }
            return "Enable DGX Spark in Settings."
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Set a DGX Spark host in Settings."
        }
        return nil
    }

    public static func detectedNVIDIASparkProfile(enabled: Bool = true) -> DGXSparkConfig? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let identity = "\(home)/Library/Application Support/NVIDIA/Sync/config/nvsync.key"
        let candidateConfigs = [
            "\(home)/.ssh/config",
            "\(home)/Library/Application Support/NVIDIA/Sync/config/ssh_config"
        ]

        let host = candidateConfigs
            .compactMap { try? String(contentsOfFile: $0) }
            .compactMap(firstSparkHostAlias)
            .first

        guard let host else { return nil }
        return DGXSparkConfig(
            host: host,
            user: NSUserName().isEmpty ? "ahmed" : NSUserName(),
            port: 22,
            identityFile: fm.fileExists(atPath: identity) ? identity : "",
            remoteWorkdir: "~/tracer-remote",
            enabled: enabled
        )
    }

    private static func firstSparkHostAlias(in contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            guard lower.hasPrefix("host ") else { continue }
            let aliases = line
                .dropFirst(5)
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.contains("*") && !$0.contains("?") }
            if let alias = aliases.first(where: { $0.lowercased().contains("spark") }) {
                return alias
            }
        }
        return nil
    }
}

public extension Notification.Name {
    static let dgxSparkConfigDidChange = Notification.Name("Tracer.dgxSparkConfigDidChange")
}
