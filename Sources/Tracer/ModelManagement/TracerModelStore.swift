import Foundation

/// Persistent registry of `TracerModel`s. Stored as a single JSON file
/// plus per-model files under `~/Library/Application Support/Tracer/Models/`.
///
/// Layout:
/// ```
/// ~/Library/Application Support/Tracer/Models/
/// ├── registry.json
/// ├── <model-id>/
/// │   ├── <original-filename>.mlpackage  (or .gguf, .json, etc.)
/// │   └── meta.json
/// └── ...
/// ```
///
/// The registry is indexed by `TracerModel.id` — binder code looks up a
/// model by its id, opens the file, and hands the path to whatever runner
/// needs it.
@MainActor
public final class TracerModelStore: ObservableObject {
    public static let shared = TracerModelStore()

    @Published public private(set) var models: [TracerModel] = []

    private let rootURL: URL
    private let registryURL: URL
    private let fm = FileManager.default

    public init(rootURL: URL? = nil) {
        let root = rootURL ?? Self.defaultRootURL()
        self.rootURL = root
        self.registryURL = root.appendingPathComponent("registry.json")
        ensureRootExists()
        reload()
    }

    public static func defaultRootURL() -> URL {
        let fm = FileManager.default
        let supportDir = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)
        return (supportDir ?? fm.temporaryDirectory)
            .appendingPathComponent("Tracer/Models", isDirectory: true)
    }

    // MARK: - Registry I/O

    public func reload() {
        guard fm.fileExists(atPath: registryURL.path) else {
            self.models = []
            return
        }
        do {
            let data = try Data(contentsOf: registryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([TracerModel].self, from: data)
            self.models = decoded
        } catch {
            NSLog("TracerModelStore: could not decode registry — \(error)")
            self.models = []
        }
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let data = try encoder.encode(models)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            NSLog("TracerModelStore: save failed — \(error)")
        }
    }

    // MARK: - CRUD

    @discardableResult
    public func add(_ model: TracerModel) -> TracerModel {
        if let idx = models.firstIndex(where: { $0.id == model.id }) {
            models[idx] = model
        } else {
            models.append(model)
        }
        save()
        NotificationCenter.default.post(name: .tracerModelsDidChange, object: self)
        return model
    }

    public func remove(id: String, deleteFiles: Bool = false) {
        guard let idx = models.firstIndex(where: { $0.id == id }) else { return }
        let model = models[idx]
        models.remove(at: idx)
        if deleteFiles, model.kind != .remoteArtifact {
            // Remove the per-model directory if the file is inside ours.
            let dir = directory(for: model.id)
            if fm.fileExists(atPath: dir.path) {
                try? fm.removeItem(at: dir)
            }
        }
        save()
        NotificationCenter.default.post(name: .tracerModelsDidChange, object: self)
    }

    public func model(id: String) -> TracerModel? {
        models.first(where: { $0.id == id })
    }

    /// Models bound to a catalog entry id. Callers look up the binding
    /// that's currently "preferred" by taking the first match.
    public func models(boundTo catalogEntryID: String) -> [TracerModel] {
        models.filter { $0.boundCatalogEntryIDs.contains(catalogEntryID) }
    }

    /// Bind an existing model to a catalog entry. Safe to call repeatedly.
    public func bind(modelID: String, to catalogEntryID: String) {
        guard let idx = models.firstIndex(where: { $0.id == modelID }) else { return }
        if !models[idx].boundCatalogEntryIDs.contains(catalogEntryID) {
            models[idx].boundCatalogEntryIDs.append(catalogEntryID)
            save()
            NotificationCenter.default.post(name: .tracerModelsDidChange, object: self)
        }
    }

    public func unbind(modelID: String, from catalogEntryID: String) {
        guard let idx = models.firstIndex(where: { $0.id == modelID }) else { return }
        models[idx].boundCatalogEntryIDs.removeAll { $0 == catalogEntryID }
        save()
        NotificationCenter.default.post(name: .tracerModelsDidChange, object: self)
    }

    // MARK: - File placement

    /// Per-model directory. Creates it on demand.
    public func directory(for modelID: String) -> URL {
        let dir = rootURL.appendingPathComponent(modelID, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Copy a file into this model's directory and update `localPath`.
    /// Used when the user picks an already-downloaded file.
    @discardableResult
    public func ingest(fileAt source: URL, into model: TracerModel) throws -> TracerModel {
        let dir = directory(for: model.id)
        let dst = dir.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: source, to: dst)
        var updated = model
        updated.localPath = dst.path
        if model.sizeBytes == 0 {
            let attrs = try fm.attributesOfItem(atPath: dst.path)
            if let size = attrs[.size] as? Int { updated.sizeBytes = size }
        }
        if updated.sha256 == nil, updated.kind != .remoteArtifact {
            updated.sha256 = try? SHA256Hex.hash(of: dst)
        }
        return add(updated)
    }

    // MARK: - Private

    private func ensureRootExists() {
        if !fm.fileExists(atPath: rootURL.path) {
            try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
    }
}

public extension Notification.Name {
    /// Posted whenever the model store mutates. Panels that display
    /// download status or bound-model chips listen here.
    static let tracerModelsDidChange = Notification.Name("Tracer.modelsDidChange")
}
