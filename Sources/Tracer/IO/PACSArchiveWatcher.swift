import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct PACSArchiveWatchStore {
    public static let defaultKey = "Tracer.PACSArchiveWatcher.RootIDs.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = PACSArchiveWatchStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    @discardableResult
    public func setWatched(_ watched: Bool, rootID: String) -> Set<String> {
        var ids = load()
        if watched {
            ids.insert(rootID)
        } else {
            ids.remove(rootID)
        }
        save(ids)
        return ids
    }

    @discardableResult
    public func save(_ ids: Set<String>) -> Set<String> {
        defaults.set(Array(ids).sorted(), forKey: key)
        return ids
    }

    @discardableResult
    public func clear() -> Set<String> {
        defaults.removeObject(forKey: key)
        return []
    }
}

public final class PACSArchiveWatcher: @unchecked Sendable {
    public struct Event: Equatable, Sendable {
        public let rootURL: URL
        public let occurredAt: Date
    }

    private let queue = DispatchQueue(label: "Tracer.PACSArchiveWatcher", qos: .utility)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var fileDescriptors: [String: CInt] = [:]
    private var pendingDebounces: [String: DispatchWorkItem] = [:]
    private let lock = NSLock()

    public init() {}

    deinit {
        stopAll()
    }

    public var watchedRootIDs: Set<String> {
        lock.withLock { Set(sources.keys) }
    }

    public func isWatching(rootID: String) -> Bool {
        lock.withLock { sources[rootID] != nil }
    }

    public func startWatching(root: PACSArchiveRoot,
                              debounceSeconds: TimeInterval = 2.0,
                              onChange: @escaping (Event) -> Void) {
        guard root.exists else { return }
        let rootID = root.id
        stopWatching(rootID: rootID)

        #if canImport(Darwin)
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleDebouncedEvent(root: root,
                                         debounceSeconds: debounceSeconds,
                                         onChange: onChange)
        }
        source.setCancelHandler {
            close(fd)
        }
        lock.withLock {
            sources[rootID] = source
            fileDescriptors[rootID] = fd
        }
        source.resume()
        #endif
    }

    public func stopWatching(rootID: String) {
        let source: DispatchSourceFileSystemObject?
        let pending: DispatchWorkItem?
        lock.lock()
        source = sources.removeValue(forKey: rootID)
        _ = fileDescriptors.removeValue(forKey: rootID)
        pending = pendingDebounces.removeValue(forKey: rootID)
        lock.unlock()
        pending?.cancel()
        source?.cancel()
    }

    public func stopAll() {
        let ids = watchedRootIDs
        for id in ids {
            stopWatching(rootID: id)
        }
    }

    private func scheduleDebouncedEvent(root: PACSArchiveRoot,
                                        debounceSeconds: TimeInterval,
                                        onChange: @escaping (Event) -> Void) {
        let rootID = root.id
        let work = DispatchWorkItem {
            onChange(Event(rootURL: root.url, occurredAt: Date()))
        }
        lock.lock()
        pendingDebounces[rootID]?.cancel()
        pendingDebounces[rootID] = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
    }
}
