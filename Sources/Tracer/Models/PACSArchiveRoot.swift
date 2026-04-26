import Foundation

public struct PACSArchiveRoot: Identifiable, Codable, Equatable, Hashable, Sendable {
    public static let scopePrefix = "archive-root:"

    public var id: String
    public var path: String
    public var displayName: String
    public var lastOpenedAt: Date
    public var lastIndexedAt: Date?
    public var seriesCount: Int
    public var studyCount: Int

    public init(id: String,
                path: String,
                displayName: String,
                lastOpenedAt: Date,
                lastIndexedAt: Date? = nil,
                seriesCount: Int = 0,
                studyCount: Int = 0) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.lastOpenedAt = lastOpenedAt
        self.lastIndexedAt = lastIndexedAt
        self.seriesCount = seriesCount
        self.studyCount = studyCount
    }

    public var scopeID: String {
        Self.scopeID(forCanonicalPath: id)
    }

    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    public var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func contains(path rawPath: String) -> Bool {
        guard !rawPath.isEmpty else { return false }
        let normalized = Self.canonicalPath(forPath: rawPath)
        return normalized == id || normalized.hasPrefix(id + "/")
    }

    public static func scopeID(forCanonicalPath path: String) -> String {
        scopePrefix + path
    }

    public static func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func canonicalPath(forPath path: String) -> String {
        canonicalPath(for: URL(fileURLWithPath: path))
    }
}

public struct PACSArchiveRootStore {
    public static let defaultKey = "Tracer.PACSArchiveRoots.v1"

    private let defaults: UserDefaults
    private let key: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(defaults: UserDefaults = .standard, key: String = PACSArchiveRootStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [PACSArchiveRoot] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode([PACSArchiveRoot].self, from: data) else {
            return []
        }
        return sorted(uniqued(decoded))
    }

    @discardableResult
    public func rememberDirectory(url: URL,
                                  openedAt: Date = Date(),
                                  seriesCount: Int? = nil,
                                  studyCount: Int? = nil,
                                  indexedAt: Date? = nil) -> [PACSArchiveRoot] {
        let canonicalPath = PACSArchiveRoot.canonicalPath(for: url)
        let displayName = url.lastPathComponent.isEmpty ? canonicalPath : url.lastPathComponent
        var roots = load()

        if let index = roots.firstIndex(where: { $0.id == canonicalPath }) {
            roots[index].path = canonicalPath
            roots[index].displayName = displayName
            roots[index].lastOpenedAt = openedAt
            if let seriesCount {
                roots[index].seriesCount = seriesCount
            }
            if let studyCount {
                roots[index].studyCount = studyCount
            }
            if let indexedAt {
                roots[index].lastIndexedAt = indexedAt
            }
        } else {
            roots.append(
                PACSArchiveRoot(
                    id: canonicalPath,
                    path: canonicalPath,
                    displayName: displayName,
                    lastOpenedAt: openedAt,
                    lastIndexedAt: indexedAt,
                    seriesCount: seriesCount ?? 0,
                    studyCount: studyCount ?? 0
                )
            )
        }

        save(roots)
        return load()
    }

    @discardableResult
    public func rememberIndexedDirectory(url: URL,
                                         records: [PACSIndexedSeriesSnapshot],
                                         indexedAt: Date = Date()) -> [PACSArchiveRoot] {
        let studyIDs = Set(records.map { PACSWorklistStudy.studyKey(for: $0) })
        return rememberDirectory(
            url: url,
            openedAt: indexedAt,
            seriesCount: records.count,
            studyCount: studyIDs.count,
            indexedAt: indexedAt
        )
    }

    @discardableResult
    public func remove(id: String) -> [PACSArchiveRoot] {
        let remaining = load().filter { $0.id != id }
        save(remaining)
        return remaining
    }

    @discardableResult
    public func clear() -> [PACSArchiveRoot] {
        defaults.removeObject(forKey: key)
        return []
    }

    private func save(_ roots: [PACSArchiveRoot]) {
        if let data = try? encoder.encode(sorted(uniqued(roots))) {
            defaults.set(data, forKey: key)
        }
    }

    private func uniqued(_ roots: [PACSArchiveRoot]) -> [PACSArchiveRoot] {
        var seen = Set<String>()
        var output: [PACSArchiveRoot] = []
        for root in roots {
            let id = root.id.isEmpty ? PACSArchiveRoot.canonicalPath(forPath: root.path) : root.id
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            var normalized = root
            normalized.id = id
            normalized.path = id
            output.append(normalized)
        }
        return output
    }

    private func sorted(_ roots: [PACSArchiveRoot]) -> [PACSArchiveRoot] {
        roots.sorted { lhs, rhs in
            let lhsDate = lhs.lastIndexedAt ?? lhs.lastOpenedAt
            let rhsDate = rhs.lastIndexedAt ?? rhs.lastOpenedAt
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}
