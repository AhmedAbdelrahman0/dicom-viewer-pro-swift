import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

enum ProcessWaiter {
    /// Wait for a process off the caller's executor. Returns true when the
    /// timeout path had to terminate the process.
    static func wait(for process: Process,
                     timeoutSeconds: TimeInterval?,
                     terminationGraceSeconds: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let timedOut = waitSynchronously(
                    for: process,
                    timeoutSeconds: timeoutSeconds,
                    terminationGraceSeconds: terminationGraceSeconds
                )
                continuation.resume(returning: timedOut)
            }
        }
    }

    static func waitSynchronously(for process: Process,
                                  timeoutSeconds: TimeInterval?,
                                  terminationGraceSeconds: TimeInterval = 5) -> Bool {
        let exited = DispatchSemaphore(value: 0)

        if !process.isRunning {
            return false
        }

        let priorTerminationHandler = process.terminationHandler
        process.terminationHandler = { terminatedProcess in
            priorTerminationHandler?(terminatedProcess)
            exited.signal()
        }

        if !process.isRunning {
            return false
        }

        guard let timeoutSeconds else {
            exited.wait()
            return false
        }

        if exited.wait(timeout: .now() + interval(timeoutSeconds)) == .success {
            return false
        }

        process.terminate()
        if exited.wait(timeout: .now() + interval(terminationGraceSeconds)) == .timedOut {
            killProcess(process)
            exited.wait()
        }
        return true
    }

    private static func interval(_ seconds: TimeInterval) -> DispatchTimeInterval {
        let milliseconds = max(0, min(Int.max, Int((seconds * 1000).rounded(.up))))
        return .milliseconds(milliseconds)
    }

    private static func killProcess(_ process: Process) {
        #if canImport(Darwin) || canImport(Glibc)
        kill(process.processIdentifier, SIGKILL)
        #else
        process.terminate()
        #endif
    }
}
