import Foundation

/// Thread-safe byte accumulator for subprocess stdout/stderr handlers.
final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func string(encoding: String.Encoding = .utf8) -> String {
        String(data: data(), encoding: encoding) ?? ""
    }
}
