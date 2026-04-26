import Foundation
import Logging
import Metrics

public enum JobState: String, Codable, CaseIterable, Identifiable, Sendable {
    case queued
    case running
    case cancelling
    case succeeded
    case failed
    case cancelled

    public var id: String { rawValue }

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .queued, .running, .cancelling:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .cancelling: return "Cancelling"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

public enum JobKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case viewer
    case pacsIndexing
    case studyLoading
    case volumeOperation
    case monai
    case nnunet
    case petEngine
    case classification
    case cohort
    case lesionDetection
    case petAC
    case reconstruction
    case syntheticCT
    case dosimetry
    case modelDownload
    case modelVerification
    case unknown

    public var id: String { rawValue }
}

public struct JobUpdate: Equatable, Sendable {
    public let operationID: String
    public let kind: JobKind
    public let title: String
    public let stage: String
    public let detail: String
    public let progress: Double?
    public let systemImage: String
    public let canCancel: Bool

    public init(operationID: String,
                kind: JobKind = .unknown,
                title: String,
                stage: String,
                detail: String,
                progress: Double? = nil,
                systemImage: String = "gearshape.2",
                canCancel: Bool = false) {
        self.operationID = operationID
        self.kind = kind
        self.title = title
        self.stage = stage
        self.detail = detail
        self.progress = progress
        self.systemImage = systemImage
        self.canCancel = canCancel
    }
}

public struct JobErrorInfo: Equatable, Codable, Sendable {
    public let code: String
    public let message: String
    public let recoverySuggestion: String?
    public let underlyingError: String?
    public let isRetryable: Bool

    public init(code: String,
                message: String,
                recoverySuggestion: String? = nil,
                underlyingError: String? = nil,
                isRetryable: Bool = false) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.underlyingError = underlyingError
        self.isRetryable = isRetryable
    }

    public init(_ error: Error,
                code: String = "unhandled_error",
                recoverySuggestion: String? = nil,
                isRetryable: Bool = false) {
        self.init(code: code,
                  message: error.localizedDescription,
                  recoverySuggestion: recoverySuggestion,
                  underlyingError: String(describing: error),
                  isRetryable: isRetryable)
    }
}

public struct JobMetricsSnapshot: Equatable, Codable, Sendable {
    public var started: Int
    public var succeeded: Int
    public var failed: Int
    public var cancelled: Int
    public var heartbeats: Int

    public static let empty = JobMetricsSnapshot(started: 0,
                                                 succeeded: 0,
                                                 failed: 0,
                                                 cancelled: 0,
                                                 heartbeats: 0)
}

public struct JobRecord: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let operationID: String
    public var kind: JobKind
    public var title: String
    public var stage: String
    public var detail: String
    public var progress: Double?
    public var state: JobState
    public var systemImage: String
    public var canCancel: Bool
    public let startedAt: Date
    public var updatedAt: Date
    public var lastHeartbeatAt: Date?
    public var heartbeatCount: Int
    public var completedAt: Date?
    public var structuredError: JobErrorInfo?

    public var isActive: Bool { !state.isTerminal }

    public var duration: TimeInterval {
        (completedAt ?? updatedAt).timeIntervalSince(startedAt)
    }

    public func heartbeatAge(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(lastHeartbeatAt ?? updatedAt)
    }
}

@MainActor
public final class JobCenterStore: ObservableObject {
    public static let shared = JobCenterStore()

    @Published public private(set) var records: [JobRecord] = []
    @Published public private(set) var unreadIssueCount: Int = 0
    @Published public private(set) var metrics: JobMetricsSnapshot = .empty

    private let maximumRecords: Int
    private var activeRecordByOperationID: [String: UUID] = [:]
    private var logger = Logger(label: "tracer.jobs")
    private let startedCounter = Counter(label: "tracer.jobs.started")
    private let succeededCounter = Counter(label: "tracer.jobs.succeeded")
    private let failedCounter = Counter(label: "tracer.jobs.failed")
    private let cancelledCounter = Counter(label: "tracer.jobs.cancelled")
    private let heartbeatCounter = Counter(label: "tracer.jobs.heartbeats")

    public init(maximumRecords: Int = 800) {
        self.maximumRecords = max(25, maximumRecords)
    }

    public var activeRecords: [JobRecord] {
        records
            .filter(\.isActive)
            .sorted { $0.startedAt < $1.startedAt }
    }

    public var recentRecords: [JobRecord] {
        records
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func start(_ update: JobUpdate, now: Date = Date()) -> UUID {
        let operationID = update.operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operationID.isEmpty else { return UUID() }
        if let existingID = activeRecordByOperationID[operationID],
           records.contains(where: { $0.id == existingID && !$0.state.isTerminal }) {
            upsert(update: update, operationID: operationID, now: now)
            return existingID
        }
        upsert(update: update, operationID: operationID, now: now)
        metrics.started += 1
        startedCounter.increment()
        logJobEvent(level: .info,
                    message: "Job started",
                    operationID: operationID,
                    state: .running,
                    kind: update.kind,
                    title: update.title)
        return activeRecordByOperationID[operationID] ?? UUID()
    }

    public func update(operationID: String,
                       stage: String? = nil,
                       detail: String? = nil,
                       progress: Double? = nil,
                       now: Date = Date()) {
        let operationID = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recordID = activeRecordByOperationID[operationID],
              let index = records.firstIndex(where: { $0.id == recordID }),
              !records[index].state.isTerminal else { return }
        if let stage = stage?.trimmingCharacters(in: .whitespacesAndNewlines), !stage.isEmpty {
            records[index].stage = stage
        }
        if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            records[index].detail = detail
        }
        if let progress {
            records[index].progress = min(max(progress, 0), 1)
        }
        if records[index].state != .cancelling {
            records[index].state = .running
        }
        records[index].updatedAt = now
    }

    public func heartbeat(operationID: String,
                          detail: String? = nil,
                          progress: Double? = nil,
                          now: Date = Date()) {
        let operationID = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recordID = activeRecordByOperationID[operationID],
              let index = records.firstIndex(where: { $0.id == recordID }),
              !records[index].state.isTerminal else { return }
        if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            records[index].detail = detail
        }
        if let progress {
            records[index].progress = min(max(progress, 0), 1)
        }
        records[index].lastHeartbeatAt = now
        records[index].heartbeatCount += 1
        records[index].updatedAt = now
        metrics.heartbeats += 1
        heartbeatCounter.increment()
    }

    public func sync(active updates: [JobUpdate], now: Date = Date()) {
        var seenOperationIDs = Set<String>()

        for update in updates {
            let operationID = update.operationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !operationID.isEmpty else { continue }
            seenOperationIDs.insert(operationID)
            let wasActive = activeRecordByOperationID[operationID] != nil
            upsert(update: update, operationID: operationID, now: now)
            if !wasActive {
                metrics.started += 1
                startedCounter.increment()
                logJobEvent(level: .info,
                            message: "Job observed",
                            operationID: operationID,
                            state: .running,
                            kind: update.kind,
                            title: update.title)
            }
        }

        let finishedOperations = activeRecordByOperationID
            .filter { !seenOperationIDs.contains($0.key) }
        for (operationID, recordID) in finishedOperations {
            finish(recordID: recordID, now: now)
            activeRecordByOperationID.removeValue(forKey: operationID)
        }

        trimIfNeeded()
    }

    public func markCancellationRequested(recordID: UUID, now: Date = Date()) {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              !records[index].state.isTerminal else { return }
        records[index].state = .cancelling
        records[index].detail = "Cancellation requested"
        records[index].updatedAt = now
    }

    public func markCancellationRequested(operationID: String, now: Date = Date()) {
        let operationID = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recordID = activeRecordByOperationID[operationID] else { return }
        markCancellationRequested(recordID: recordID, now: now)
    }

    public func complete(operationID: String,
                         state: JobState,
                         detail: String? = nil,
                         error: JobErrorInfo? = nil,
                         now: Date = Date()) {
        guard state.isTerminal else { return }
        let operationID = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let recordID = activeRecordByOperationID.removeValue(forKey: operationID),
              let index = records.firstIndex(where: { $0.id == recordID }),
              !records[index].state.isTerminal else { return }

        records[index].state = state
        if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty {
            records[index].detail = detail
        }
        records[index].completedAt = now
        records[index].updatedAt = now
        records[index].canCancel = false
        records[index].structuredError = error
        if state == .succeeded {
            records[index].progress = 1
            metrics.succeeded += 1
            succeededCounter.increment()
        } else {
            unreadIssueCount = min(unreadIssueCount + 1, maximumRecords)
            if state == .failed {
                metrics.failed += 1
                failedCounter.increment()
            } else if state == .cancelled {
                metrics.cancelled += 1
                cancelledCounter.increment()
            }
        }
        logJobEvent(level: state == .failed ? .error : .info,
                    message: "Job completed",
                    operationID: operationID,
                    state: state,
                    kind: records[index].kind,
                    title: records[index].title,
                    error: error)
        trimIfNeeded()
    }

    public func succeed(operationID: String,
                        detail: String? = nil,
                        now: Date = Date()) {
        complete(operationID: operationID, state: .succeeded, detail: detail, now: now)
    }

    public func fail(operationID: String,
                     error: JobErrorInfo,
                     detail: String? = nil,
                     now: Date = Date()) {
        complete(operationID: operationID,
                 state: .failed,
                 detail: detail ?? error.message,
                 error: error,
                 now: now)
    }

    public func cancel(operationID: String,
                       detail: String? = nil,
                       now: Date = Date()) {
        complete(operationID: operationID,
                 state: .cancelled,
                 detail: detail ?? "Cancelled",
                 now: now)
    }

    public func clearFinished() {
        let activeIDs = Set(activeRecords.map(\.id))
        records.removeAll { !activeIDs.contains($0.id) }
        unreadIssueCount = 0
    }

    public func markRead() {
        unreadIssueCount = 0
    }

    public func reset() {
        records.removeAll()
        activeRecordByOperationID.removeAll()
        unreadIssueCount = 0
        metrics = .empty
    }

    public func staleActiveRecords(now: Date = Date(), threshold: TimeInterval = 120) -> [JobRecord] {
        activeRecords.filter { $0.heartbeatAge(now: now) >= threshold }
    }

    private func upsert(update: JobUpdate, operationID: String, now: Date) {
        let title = update.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stage = update.stage.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = update.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let progress = update.progress.map { min(max($0, 0), 1) }

        if let recordID = activeRecordByOperationID[operationID],
           let index = records.firstIndex(where: { $0.id == recordID }),
           !records[index].state.isTerminal {
            records[index].kind = update.kind
            records[index].title = title.isEmpty ? records[index].title : title
            records[index].stage = stage.isEmpty ? records[index].stage : stage
            records[index].detail = detail.isEmpty ? records[index].detail : detail
            records[index].progress = progress
            records[index].systemImage = update.systemImage
            records[index].canCancel = update.canCancel
            records[index].structuredError = nil
            if records[index].state != .cancelling {
                records[index].state = .running
            }
            records[index].updatedAt = now
            return
        }

        let id = UUID()
        activeRecordByOperationID[operationID] = id
        records.append(JobRecord(
            id: id,
            operationID: operationID,
            kind: update.kind,
            title: title.isEmpty ? "Background job" : title,
            stage: stage.isEmpty ? "Running" : stage,
            detail: detail.isEmpty ? "Running" : detail,
            progress: progress,
            state: .running,
            systemImage: update.systemImage,
            canCancel: update.canCancel,
            startedAt: now,
            updatedAt: now,
            lastHeartbeatAt: now,
            heartbeatCount: 0,
            completedAt: nil,
            structuredError: nil
        ))
    }

    private func finish(recordID: UUID, now: Date) {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              !records[index].state.isTerminal else { return }

        let terminalState = inferredTerminalState(for: records[index])
        records[index].state = terminalState
        records[index].completedAt = now
        records[index].updatedAt = now
        records[index].canCancel = false
        if terminalState == .succeeded {
            records[index].progress = 1
            metrics.succeeded += 1
            succeededCounter.increment()
        } else {
            unreadIssueCount = min(unreadIssueCount + 1, maximumRecords)
            if terminalState == .failed {
                metrics.failed += 1
                failedCounter.increment()
            } else if terminalState == .cancelled {
                metrics.cancelled += 1
                cancelledCounter.increment()
            }
        }
        logJobEvent(level: terminalState == .failed ? .error : .info,
                    message: "Job inferred complete",
                    operationID: records[index].operationID,
                    state: terminalState,
                    kind: records[index].kind,
                    title: records[index].title,
                    error: records[index].structuredError)
    }

    private func inferredTerminalState(for record: JobRecord) -> JobState {
        if record.state == .cancelling {
            return .cancelled
        }

        let text = "\(record.stage) \(record.detail)".lowercased()
        if text.contains("cancel") {
            return .cancelled
        }
        if text.contains("fail")
            || text.contains("error")
            || text.contains("could not")
            || text.contains("denied")
            || text.contains("unavailable")
            || text.contains("missing") {
            return .failed
        }
        return .succeeded
    }

    private func trimIfNeeded() {
        guard records.count > maximumRecords else { return }
        var overflow = records.count - maximumRecords
        let removableIDs = records
            .filter { $0.state.isTerminal }
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(overflow)
            .map(\.id)
        let removableSet = Set(removableIDs)
        records.removeAll { record in
            guard removableSet.contains(record.id), overflow > 0 else { return false }
            overflow -= 1
            return true
        }
    }

    private func logJobEvent(level: Logger.Level,
                             message: Logger.Message,
                             operationID: String,
                             state: JobState,
                             kind: JobKind,
                             title: String,
                             error: JobErrorInfo? = nil) {
        var metadata: Logger.Metadata = [
            "operationID": "\(operationID)",
            "state": "\(state.rawValue)",
            "kind": "\(kind.rawValue)",
            "title": "\(title)"
        ]
        if let error {
            metadata["errorCode"] = "\(error.code)"
            metadata["retryable"] = "\(error.isRetryable)"
        }
        logger.log(level: level, message, metadata: metadata)
    }
}

public typealias JobManager = JobCenterStore
