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
                remoteEnvironment: String = "",
                enabled: Bool = false) {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.remoteWorkdir = remoteWorkdir
        self.remoteNNUnetBinary = remoteNNUnetBinary
        self.remoteLlamaBinary = remoteLlamaBinary
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
}

public extension Notification.Name {
    static let dgxSparkConfigDidChange = Notification.Name("Tracer.dgxSparkConfigDidChange")
}
