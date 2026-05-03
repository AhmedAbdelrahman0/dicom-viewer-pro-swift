import Foundation

/// Downloads a remote model artifact into a `TracerModel`'s per-model
/// directory, with progress reporting, SHA-256 verification, and a
/// cancellation flag.
///
/// Supports ordinary HTTPS URLs (Zenodo, direct file links) and
/// HuggingFace-style URLs; the latter get rewritten to the LFS resolve
/// path so large files stream rather than serve the preview HTML.
@MainActor
public final class ModelDownloadManager: ObservableObject {

    public enum DownloadStatus: Equatable {
        case idle
        case downloading(bytesReceived: Int64, totalBytes: Int64)
        case verifying
        case completed(sizeBytes: Int)
        case failed(String)
        case cancelled
    }

    @Published public private(set) var statusByModelID: [String: DownloadStatus] = [:]

    private var tasks: [String: URLSessionDownloadTask] = [:]

    public init() {}

    // MARK: - Public API

    /// Start / resume a download. Safe to call repeatedly — already-running
    /// downloads are returned as-is.
    public func download(_ model: TracerModel,
                         store: TracerModelStore,
                         expectedSHA: String? = nil) async -> Result<TracerModel, Error> {
        guard model.kind != .remoteArtifact else {
            return .failure(ModelDownloadError.remoteArtifact)
        }
        guard let source = model.sourceURL else {
            return .failure(ModelDownloadError.noSourceURL)
        }

        // Rewrite HuggingFace blob URLs to LFS resolve URLs so big files
        // download directly. No-op for other hosts.
        let effectiveURL = Self.rewriteHuggingFace(source)

        statusByModelID[model.id] = .downloading(bytesReceived: 0, totalBytes: -1)

        let dstDir = store.directory(for: model.id)
        let filename = effectiveURL.lastPathComponent
        let dst = dstDir.appendingPathComponent(filename)

        do {
            let (tempURL, response) = try await urlSessionDownload(from: effectiveURL,
                                                                   modelID: model.id)
            tasks[model.id] = nil
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                Self.removeOrLog(tempURL, context: "HTTP \(http.statusCode) temp cleanup")
                throw ModelDownloadError.httpStatus(http.statusCode)
            }
            // Move the tempfile into the model directory, replacing any prior.
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.moveItem(at: tempURL, to: dst)

            statusByModelID[model.id] = .verifying
            let actualSize = (try? FileManager.default.attributesOfItem(atPath: dst.path))?[.size] as? Int ?? 0

            var updated = model
            updated.localPath = dst.path
            updated.sizeBytes = actualSize

            // Hash + verify.
            let hash = try SHA256Hex.hash(of: dst)
            updated.sha256 = hash
            if let expected = expectedSHA?.lowercased(), expected != hash {
                statusByModelID[model.id] = .failed(
                    "SHA-256 mismatch. Expected \(expected), got \(hash)."
                )
                Self.removeOrLog(dst, context: "SHA-256 mismatch cleanup")
                return .failure(ModelDownloadError.hashMismatch(expected: expected, actual: hash))
            }

            // Mention a couple of response details in notes so the registry
            // records where it came from.
            if updated.notes.isEmpty, let http = response as? HTTPURLResponse {
                updated.notes = "Downloaded \(Date().formatted(date: .abbreviated, time: .shortened)) — HTTP \(http.statusCode)"
            }

            let persisted = store.add(updated)
            statusByModelID[model.id] = .completed(sizeBytes: actualSize)
            return .success(persisted)
        } catch {
            tasks[model.id] = nil
            if (error as? URLError)?.code == .cancelled {
                statusByModelID[model.id] = .cancelled
                return .failure(ModelDownloadError.cancelled)
            }
            statusByModelID[model.id] = .failed(error.localizedDescription)
            return .failure(error)
        }
    }

    public func cancel(modelID: String) {
        tasks[modelID]?.cancel()
        tasks[modelID] = nil
        statusByModelID[modelID] = .cancelled
    }

    public func status(for modelID: String) -> DownloadStatus {
        statusByModelID[modelID] ?? .idle
    }

    // MARK: - Private

    private func urlSessionDownload(from url: URL,
                                    modelID: String) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            // Throttle progress updates to ~10 Hz. URLSession's progress
            // delegate fires per-chunk (often 100+ Hz on fast links); without
            // throttling we were spawning a Task { @MainActor } for every
            // packet, which piles up MainActor work and can stall the UI on
            // a large download. 100 ms is below the human perception
            // threshold for a progress bar, well above the per-chunk rate.
            // Reference type so the var capture is Sendable; delegateQueue
            // is .main so the mutation is single-threaded regardless.
            let throttle = ProgressThrottle()
            let delegate = DownloadProgressDelegate { [weak self] received, total in
                guard throttle.shouldPublish(received: received, total: total) else { return }
                Task { @MainActor in
                    self?.statusByModelID[modelID] =
                        .downloading(bytesReceived: received, totalBytes: total)
                }
            }
            let progressSession = URLSession(
                configuration: .default,
                delegate: delegate,
                // Pin the delegate queue to main so we don't need a
                // separate actor hop for every callback. Progress updates
                // are idempotent scalar writes — main is fine.
                delegateQueue: OperationQueue.main
            )
            let task = progressSession.downloadTask(with: url) { url, response, error in
                defer { progressSession.finishTasksAndInvalidate() }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url, let response {
                    // We have to copy off the tempfile BEFORE returning —
                    // URLSession deletes it as soon as the completion handler
                    // returns.
                    let tempCopy = FileManager.default.temporaryDirectory
                        .appendingPathComponent("tracer-download-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: url, to: tempCopy)
                        continuation.resume(returning: (tempCopy, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(throwing: ModelDownloadError.noResponse)
            }
            tasks[modelID] = task
            task.resume()
        }
    }

    /// Best-effort filesystem cleanup that logs failures instead of silently
    /// swallowing them. Silent `try?` was making it easy to miss a locked /
    /// permission-denied file leftover after a failed download — the next
    /// retry would hit a stale corrupt artifact and get a confusing error.
    /// We still don't throw (cleanup is best-effort) but at least NSLog gives
    /// us a breadcrumb when a user reports "download is broken, can't retry."
    static func removeOrLog(_ url: URL, context: String) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            NSLog("ModelDownloadManager: \(context) failed for \(url.path) — \(error.localizedDescription)")
        }
    }

    /// HuggingFace's web UI link is `https://huggingface.co/<repo>/blob/main/<file>`;
    /// LFS resolve is `https://huggingface.co/<repo>/resolve/main/<file>`.
    /// Rewriting keeps users from pasting the web URL and getting a 1-KB
    /// HTML preview instead of the 3-GB weights.
    static func rewriteHuggingFace(_ url: URL) -> URL {
        let absolute = url.absoluteString
        guard absolute.contains("huggingface.co") else { return url }
        let rewritten = absolute.replacingOccurrences(of: "/blob/", with: "/resolve/")
        return URL(string: rewritten) ?? url
    }
}

public enum ModelDownloadError: Error, LocalizedError {
    case noSourceURL
    case noResponse
    case remoteArtifact
    case cancelled
    case hashMismatch(expected: String, actual: String)
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .noSourceURL: return "Model has no source URL."
        case .noResponse:  return "Download produced no response."
        case .remoteArtifact: return "Remote artifacts don't download locally."
        case .cancelled:   return "Download cancelled."
        case .hashMismatch(let expected, let actual):
            return "SHA-256 mismatch: expected \(expected), got \(actual)."
        case .httpStatus(let status):
            return "Model download failed with HTTP \(status)."
        }
    }
}

// MARK: - Progress throttle

/// Rate-limits progress callbacks to ~10 Hz. `final` reference so closure
/// captures are Sendable; `delegateQueue = .main` guarantees serial access,
/// so no lock is needed.
private final class ProgressThrottle: @unchecked Sendable {
    private var lastPublished = Date.distantPast

    func shouldPublish(received: Int64, total: Int64) -> Bool {
        // Always publish the final "100%" update even if under the debounce.
        if total > 0 && received >= total {
            lastPublished = Date()
            return true
        }
        let now = Date()
        if now.timeIntervalSince(lastPublished) >= 0.1 {
            lastPublished = now
            return true
        }
        return false
    }
}

// MARK: - URLSession progress delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    // Required but handled by the completion-handler-based API above.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
