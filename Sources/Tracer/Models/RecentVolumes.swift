import Foundation

public extension Notification.Name {
    static let recentVolumesDidChange = Notification.Name("Tracer.recentVolumesDidChange")
}

/// Lightweight bookmark for a volume the user has opened in a previous
/// (or current) session. Shown as a single chip in the Study Browser's
/// "Recently opened" strip and used to reopen a study with one click.
public struct RecentVolume: Codable, Identifiable, Hashable {
    /// Matches `ImageVolume.sessionIdentity`, so a re-opened study maps
    /// back onto the same loaded instance when already present.
    public let id: String
    public let modality: String
    public let seriesDescription: String
    public let studyDescription: String
    public let patientName: String
    /// Absolute file paths used to load this volume. For DICOM this is the
    /// full set of instance paths; for NIfTI it's a single file URL.
    public let sourceFiles: [String]
    public let kind: Kind
    public let openedAt: Date

    public enum Kind: String, Codable, Sendable {
        case dicom
        case nifti
    }

    public init(id: String,
                modality: String,
                seriesDescription: String,
                studyDescription: String,
                patientName: String,
                sourceFiles: [String],
                kind: Kind,
                openedAt: Date = Date()) {
        self.id = id
        self.modality = modality
        self.seriesDescription = seriesDescription
        self.studyDescription = studyDescription
        self.patientName = patientName
        self.sourceFiles = sourceFiles
        self.kind = kind
        self.openedAt = openedAt
    }

    public init(from volume: ImageVolume) {
        let kind: Kind = volume.sourceFiles
            .first?
            .hasSuffix(".nii") == true
            || volume.sourceFiles.first?.hasSuffix(".nii.gz") == true
            ? .nifti
            : .dicom
        self.init(
            id: volume.sessionIdentity,
            modality: volume.modality,
            seriesDescription: volume.seriesDescription.isEmpty
                ? "Series"
                : volume.seriesDescription,
            studyDescription: volume.studyDescription,
            patientName: volume.patientName,
            sourceFiles: volume.sourceFiles,
            kind: kind
        )
    }

    public var displaySeriesDescription: String {
        let series = Self.meaningfulHeaderTitle(seriesDescription)
        if !series.isEmpty { return series }
        let source = Self.sourceFileTitle(sourceFiles)
        return source.isEmpty ? "Series" : source
    }

    public var displayStudyDescription: String {
        let study = Self.meaningfulHeaderTitle(studyDescription)
        if !study.isEmpty { return study }
        let folder = Self.sourceFolderTitle(sourceFiles)
        if !folder.isEmpty { return folder }
        return displaySeriesDescription
    }

    public var displayPatientName: String {
        Self.meaningfulHeaderTitle(patientName)
    }

    public var displayPatientOrStudyTitle: String {
        let patient = displayPatientName
        return patient.isEmpty ? displayStudyDescription : patient
    }

    private static func sourceFolderTitle(_ sourceFiles: [String]) -> String {
        guard let path = sourceFiles.first, !path.isEmpty else { return "" }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        let candidates = [
            parent.lastPathComponent,
            parent.deletingLastPathComponent().lastPathComponent
        ]
        for candidate in candidates {
            let title = meaningfulHeaderTitle(candidate)
            if !title.isEmpty { return title }
        }
        return ""
    }

    private static func sourceFileTitle(_ sourceFiles: [String]) -> String {
        guard let path = sourceFiles.first, !path.isEmpty else { return "" }
        return meaningfulHeaderTitle(URL(fileURLWithPath: path).lastPathComponent)
    }

    private static func meaningfulHeaderTitle(_ value: String) -> String {
        let trimmed = stripKnownVolumeExtension(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !isGenericHeaderTitle(trimmed) else { return "" }
        return trimmed
    }

    private static func stripKnownVolumeExtension(from value: String) -> String {
        let lower = value.lowercased()
        if lower.hasSuffix(".nii.gz") {
            return String(value.dropLast(7))
        }
        if lower.hasSuffix(".nii") || lower.hasSuffix(".mha") || lower.hasSuffix(".mhd") || lower.hasSuffix(".nrrd") {
            return String(value.dropLast(4))
        }
        return value
    }

    private static func isGenericHeaderTitle(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return true }
        return [
            "nifti",
            "nifti study",
            "nifti import",
            "untitled",
            "untitled study",
            "study",
            "image",
            "images",
            "data",
            "files",
            "ct",
            "pt",
            "pet",
            "mr",
            "mri"
        ].contains(normalized)
    }
}

/// Persists the last N loaded volumes as JSON in `UserDefaults`. Thread-safe
/// for MainActor-only callers (the view model). Uses a capped LRU list —
/// the newest volume is always at index 0.
@MainActor
public final class RecentVolumesStore {
    public nonisolated static let defaultsKey = "Tracer.RecentVolumes"
    public nonisolated static let maximumEntries = 8

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [RecentVolume] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let list = try? decoder.decode([RecentVolume].self, from: data) else {
            return []
        }
        return list
    }

    public func save(_ list: [RecentVolume]) {
        guard let data = try? encoder.encode(list) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .recentVolumesDidChange, object: self)
    }

    /// Insert `entry` at the head of the list, remove any duplicate id, and
    /// trim to `maximumEntries`. Returns the new list.
    @discardableResult
    public func recordOpen(_ entry: RecentVolume) -> [RecentVolume] {
        var list = load()
        list.removeAll { $0.id == entry.id }
        list.insert(entry, at: 0)
        if list.count > Self.maximumEntries {
            list.removeLast(list.count - Self.maximumEntries)
        }
        save(list)
        return list
    }

    public func remove(id: String) -> [RecentVolume] {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
        return list
    }

    public func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .recentVolumesDidChange, object: self)
    }
}
