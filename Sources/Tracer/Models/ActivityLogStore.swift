import Foundation

public enum ActivityLogLevel: String, Codable, CaseIterable, Sendable {
    case info
    case success
    case warning
    case error
}

public struct ActivityLogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let source: String
    public let level: ActivityLogLevel
    public let message: String

    public init(id: UUID = UUID(),
                timestamp: Date = Date(),
                source: String,
                level: ActivityLogLevel = .info,
                message: String) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.level = level
        self.message = message
    }
}

@MainActor
public final class ActivityLogStore: ObservableObject {
    public static let shared = ActivityLogStore()

    @Published public private(set) var entries: [ActivityLogEntry] = []
    @Published public private(set) var unreadCount: Int = 0

    private let maximumEntries: Int

    public init(maximumEntries: Int = 600) {
        self.maximumEntries = max(1, maximumEntries)
    }

    public func log(_ message: String,
                    source: String = "Tracer",
                    level: ActivityLogLevel = .info,
                    countAsUnread: Bool = true) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let last = entries.last,
           last.source == source,
           last.level == level,
           last.message == trimmed {
            return
        }

        entries.append(ActivityLogEntry(source: source, level: level, message: trimmed))
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        if countAsUnread {
            unreadCount = min(unreadCount + 1, maximumEntries)
        }
    }

    public func logStatus(_ message: String, source: String) {
        let lower = message.lowercased()
        let level: ActivityLogLevel
        if lower.contains("failed") || lower.contains("error") || lower.contains("could not") {
            level = .error
        } else if lower.contains("warning") || lower.contains("cancel") {
            level = .warning
        } else if lower.contains("✓") || lower.contains("ready") || lower.contains("complete") || lower.contains("downloaded") {
            level = .success
        } else {
            level = .info
        }
        log(message, source: source, level: level)
    }

    public func markRead() {
        unreadCount = 0
    }

    public func clear() {
        entries.removeAll()
        unreadCount = 0
    }
}
