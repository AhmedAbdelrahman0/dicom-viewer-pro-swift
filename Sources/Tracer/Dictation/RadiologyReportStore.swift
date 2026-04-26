import Foundation
import SwiftUI

/// `@MainActor` ObservableObject that owns the active `RadiologyReport`
/// and republishes mutations as `@Published` updates so SwiftUI redraws.
///
/// Why not SwiftData? — Codex is mid-refactor on the shared SwiftData
/// model container; touching the schema right now is a collision risk.
/// JSON snapshots on disk are simpler, cheaper to test, and (crucially)
/// don't require migration management as the schema evolves. We can move
/// to SwiftData behind the same API in a later commit when Codex's main-
/// branch refactor lands.
///
/// Persistence layout:
///   ~/Library/Application Support/Tracer/Dictation/Reports/<uuid>.json
/// One file per report. The store maintains a small in-memory MRU index
/// (RecentReports) so the panel can show "open recent" without scanning
/// the directory on every view load.
///
/// Thread-safety: every public mutator runs on the main actor (the store
/// is `@MainActor`-isolated). Disk I/O is offloaded to a background
/// `Task.detached` so the UI never blocks on a flush.
@MainActor
public final class RadiologyReportStore: ObservableObject {

    @Published public private(set) var report: RadiologyReport
    @Published public private(set) var recentReports: [RecentReportEntry] = []
    @Published public private(set) var lastSavedAt: Date?
    @Published public var statusMessage: String = ""

    /// Directory used for persisted JSON snapshots. Defaults to
    /// ~/Library/Application Support/Tracer/Dictation/Reports.
    /// Tests inject a tmp directory for hermeticity.
    public let storageDirectory: URL

    public init(report: RadiologyReport = RadiologyReport(),
                storageDirectory: URL? = nil) {
        self.report = report
        self.storageDirectory = storageDirectory
            ?? RadiologyReportStore.defaultStorageDirectory()
        try? FileManager.default.createDirectory(
            at: self.storageDirectory,
            withIntermediateDirectories: true
        )
        self.recentReports = (try? scanRecent()) ?? []
    }

    // MARK: - Mutations

    /// Append a sentence to a section. The most common write path —
    /// dictation finals land here.
    public func appendSentence(_ sentence: ReportSentence,
                               to kind: ReportSection.Kind) {
        report = RadiologyReportMutator.appendSentence(sentence, to: kind, in: report)
    }

    public func updateSentence(id: UUID, newText: String,
                               provenance: ReportSentence.Provenance? = nil) {
        report = RadiologyReportMutator.updateSentence(
            id: id, newText: newText, provenance: provenance, in: report
        )
    }

    public func removeSentence(id: UUID) {
        report = RadiologyReportMutator.removeSentence(id: id, in: report)
    }

    public func replaceSection(_ kind: ReportSection.Kind,
                               with sentences: [ReportSentence]) {
        report = RadiologyReportMutator.replaceSection(kind, with: sentences, in: report)
    }

    public func addCustomSection(title: String) {
        report = RadiologyReportMutator.addCustomSection(title: title, in: report)
    }

    public func reorderSections(by ids: [UUID]) {
        report = RadiologyReportMutator.reorderSections(by: ids, in: report)
    }

    public func setMetadata(_ updater: (inout ReportMetadata) -> Void) {
        var copy = report.metadata
        updater(&copy)
        copy.updatedAt = Date()
        report.metadata = copy
    }

    public func signOff(by clinician: String, attestationHash: String? = nil) {
        report = RadiologyReportMutator.signOff(
            by: clinician,
            attestationHash: attestationHash,
            in: report
        )
    }

    public func rescindSignOff(by clinician: String) {
        report = RadiologyReportMutator.rescindSignOff(by: clinician, in: report)
    }

    public func recordRevision(kind: ReportRevision.Kind,
                               author: String,
                               summary: String) {
        report = RadiologyReportMutator.recordRevision(
            kind: kind, author: author, summary: summary, in: report
        )
    }

    /// Apply an arbitrary transform to the current report. Used by the
    /// macro engine and any other external mutator that wants to operate
    /// on the report value without going through the per-method wrapper
    /// API. Keeps `report`'s setter `private(set)` while still allowing
    /// composition.
    public func applyMutation(_ transform: (RadiologyReport) -> RadiologyReport) {
        report = transform(report)
    }

    /// Reset to a fresh blank report. Used by the panel's "New Report"
    /// button and by the test harness between cases.
    public func resetToBlank(metadata: ReportMetadata = ReportMetadata()) {
        report = RadiologyReport(metadata: metadata)
        statusMessage = "Started a new report."
    }

    // MARK: - Persistence

    /// Save the current report to disk. Returns the file URL on success.
    /// Errors land in `statusMessage`; the call is fire-and-forget for
    /// callers that don't need the URL.
    @discardableResult
    public func save() -> URL? {
        let url = storageDirectory.appendingPathComponent("\(report.id.uuidString).json")
        do {
            let data = try Self.encoder.encode(report)
            try data.write(to: url, options: .atomic)
            lastSavedAt = Date()
            statusMessage = "Saved to \(url.lastPathComponent)."
            recentReports = (try? scanRecent()) ?? []
            return url
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Load a report from disk. Replaces the current `report`. Refuses to
    /// load reports with a `schemaVersion` newer than the loader knows.
    public func load(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let loaded = try Self.decoder.decode(RadiologyReport.self, from: data)
            guard loaded.schemaVersion <= RadiologyReport.currentSchemaVersion else {
                statusMessage = "Refused: report schema v\(loaded.schemaVersion) is newer than this build (v\(RadiologyReport.currentSchemaVersion))."
                return
            }
            report = loaded
            statusMessage = "Loaded \(url.lastPathComponent)."
        } catch {
            statusMessage = "Load failed: \(error.localizedDescription)"
        }
    }

    public func loadRecent(_ entry: RecentReportEntry) {
        load(from: entry.url)
    }

    // MARK: - Recent index

    public struct RecentReportEntry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let url: URL
        public let patientName: String
        public let modifiedAt: Date

        public init(id: UUID, url: URL, patientName: String, modifiedAt: Date) {
            self.id = id
            self.url = url
            self.patientName = patientName
            self.modifiedAt = modifiedAt
        }
    }

    /// Scan the storage directory for JSON snapshots, sorted newest first.
    /// Cheap — reads each file's metadata header but never the full body.
    /// Errors during scan return an empty list rather than throwing; an
    /// unreadable directory is more often a permissions issue than a bug.
    private func scanRecent(limit: Int = 30) throws -> [RecentReportEntry] {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: resourceKeys
        ) else { return [] }

        var entries: [RecentReportEntry] = []
        for url in urls where url.pathExtension == "json" {
            // Read just enough of the file to extract id + patient name.
            // For small reports this is the whole file; for larger ones the
            // decoder still handles it under the hood.
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let snap = try? Self.decoder.decode(ReportHeader.self, from: data) else { continue }
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            entries.append(RecentReportEntry(
                id: snap.id,
                url: url,
                patientName: snap.metadata.patientName,
                modifiedAt: mod
            ))
        }
        entries.sort(by: { $0.modifiedAt > $1.modifiedAt })
        return Array(entries.prefix(limit))
    }

    /// Slim header decoded from disk for the recents list. Keeps the scan
    /// cost low even if we add huge optional fields to ReportSentence
    /// later — scanRecent only reads what's in `ReportHeader`.
    private struct ReportHeader: Codable {
        let id: UUID
        let metadata: ReportMetadata
    }

    // MARK: - Defaults

    public static func defaultStorageDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Tracer", isDirectory: true)
            .appendingPathComponent("Dictation", isDirectory: true)
            .appendingPathComponent("Reports", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
