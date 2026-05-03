import Foundation

public struct SparkArchiveEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let fileSize: Int64?
    public let modifiedAt: Date?

    public var kindLabel: String {
        if isDirectory { return "Folder" }
        let lower = name.lowercased()
        if lower.hasSuffix(".nii") || lower.hasSuffix(".nii.gz") { return "NIfTI" }
        if lower.hasSuffix(".mha") || lower.hasSuffix(".mhd") { return "MetaImage" }
        if lower.hasSuffix(".dcm") || lower.hasSuffix(".ima") || lower.hasSuffix(".dicom") {
            return "DICOM"
        }
        if lower.hasSuffix(".json") { return "JSON" }
        if lower.hasSuffix(".csv") || lower.hasSuffix(".tsv") { return "Table" }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    public var detailText: String {
        if isDirectory { return "Folder" }
        guard let fileSize else { return kindLabel }
        return "\(kindLabel) - \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))"
    }
}

public enum SparkArchiveBrowser {
    public static let defaultRoot = AutoPETVExperimentConfig.defaultSparkDatasetRoot
    public static let storageKey = "Tracer.Prefs.SparkArchiveRoot"

    public enum Error: Swift.Error, LocalizedError {
        case remoteListingFailed(String)
        case invalidListingPayload

        public var errorDescription: String? {
            switch self {
            case .remoteListingFailed(let message):
                return "Remote archive listing failed: \(message)"
            case .invalidListingPayload:
                return "Remote archive listing returned an unreadable response."
            }
        }
    }

    public static func listDirectory(path: String,
                                     config: DGXSparkConfig,
                                     limit: Int = 1_000) throws -> [SparkArchiveEntry] {
        let executor = RemoteExecutor(config: config)
        let command = listCommand(path: path, limit: limit)
        let result = try executor.run(command, timeoutSeconds: 30)
        guard result.exitCode == 0 else {
            throw RemoteExecutor.Error.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        let response = try JSONDecoder().decode(ListingResponse.self, from: result.stdout)
        if let error = response.error, !error.isEmpty {
            throw Error.remoteListingFailed(error)
        }
        return response.entries.map(\.entry)
    }

    public static func stage(path: String,
                             isDirectory: Bool,
                             config: DGXSparkConfig,
                             cacheRoot: URL = defaultCacheRoot()) throws -> URL {
        let localURL = localCacheURL(forRemotePath: path,
                                     host: config.sshDestination,
                                     cacheRoot: cacheRoot)
        let executor = RemoteExecutor(config: config)
        if isDirectory {
            try executor.downloadDirectory(path, toLocal: localURL)
        } else {
            try executor.downloadFile(path, toLocal: localURL)
        }
        return localURL
    }

    public static func defaultCacheRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Tracer", isDirectory: true)
            .appendingPathComponent("SparkArchives", isDirectory: true)
    }

    public static func localCacheURL(forRemotePath remotePath: String,
                                     host: String,
                                     cacheRoot: URL = defaultCacheRoot()) -> URL {
        let name = sanitizedName(lastPathComponent(remotePath))
        let fingerprint = stableHash("\(host)|\(remotePath)")
        return cacheRoot.appendingPathComponent("\(fingerprint)-\(name)")
    }

    private static func listCommand(path: String, limit: Int) -> String {
        """
        TRACER_SPARK_PATH=\(RemoteExecutor.shellPath(path)) TRACER_SPARK_LIMIT=\(max(1, limit)) python3 - <<'PY'
        import json, os, stat, sys

        path = os.path.expanduser(os.environ.get("TRACER_SPARK_PATH", ""))
        limit = int(os.environ.get("TRACER_SPARK_LIMIT", "1000"))

        try:
            entries = []
            with os.scandir(path) as iterator:
                for entry in iterator:
                    try:
                        info = entry.stat(follow_symlinks=False)
                        is_dir = stat.S_ISDIR(info.st_mode)
                        entries.append({
                            "path": entry.path,
                            "name": entry.name,
                            "isDirectory": is_dir,
                            "fileSize": None if is_dir else info.st_size,
                            "modifiedAt": info.st_mtime,
                        })
                    except OSError:
                        continue
            entries.sort(key=lambda item: (not item["isDirectory"], item["name"].lower()))
            print(json.dumps({"entries": entries[:limit]}))
        except Exception as exc:
            print(json.dumps({"error": str(exc)}))
            sys.exit(2)
        PY
        """
    }

    private static func lastPathComponent(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let last = trimmed.split(separator: "/").last.map(String.init)
        return last?.isEmpty == false ? last! : "spark-root"
    }

    private static func sanitizedName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = name.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return value.isEmpty ? "spark-archive" : value
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private struct ListingResponse: Decodable {
    let entries: [RemoteEntryPayload]
    let error: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([RemoteEntryPayload].self, forKey: .entries) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case error
    }
}

private struct RemoteEntryPayload: Decodable {
    let path: String
    let name: String
    let isDirectory: Bool
    let fileSize: Int64?
    let modifiedAt: Double?

    var entry: SparkArchiveEntry {
        SparkArchiveEntry(
            id: path,
            path: path,
            name: name,
            isDirectory: isDirectory,
            fileSize: fileSize,
            modifiedAt: modifiedAt.map(Date.init(timeIntervalSince1970:))
        )
    }
}
