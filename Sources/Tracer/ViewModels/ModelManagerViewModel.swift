import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// MVVM coordinator for the Model Manager panel. Sits between the
/// persistent `TracerModelStore` and the UI — handles add / remove /
/// import / download + binding orchestration.
@MainActor
public final class ModelManagerViewModel: ObservableObject {

    @Published public var newDisplayName: String = ""
    @Published public var newKind: TracerModel.Kind = .coreML
    @Published public var newSourceURL: String = ""
    @Published public var newLicense: String = ""
    @Published public var newNotes: String = ""
    @Published public var newRemotePath: String = ""
    @Published public var statusMessage: String = ""
    @Published public var showingBindSheet: Bool = false
    @Published public var bindingModelID: String?
    @Published public var bindingCatalogQuery: String = ""

    public let store: TracerModelStore
    public let downloader: ModelDownloadManager

    public init(store: TracerModelStore? = nil,
                downloader: ModelDownloadManager? = nil) {
        self.store = store ?? TracerModelStore.shared
        self.downloader = downloader ?? ModelDownloadManager()
    }

    // MARK: - Adding models

    /// Create a new registry entry from the form fields, without
    /// downloading yet. User clicks "Download" afterwards.
    public func registerFromForm() {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            statusMessage = "Give the model a display name."
            return
        }
        let sourceURL = URL(string: newSourceURL.trimmingCharacters(in: .whitespaces))

        let model: TracerModel
        if newKind == .remoteArtifact {
            let path = newRemotePath.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else {
                statusMessage = "Remote artifacts need a path on the DGX."
                return
            }
            model = TracerModel(
                displayName: trimmed,
                kind: .remoteArtifact,
                sourceURL: nil,
                localPath: path,
                license: newLicense,
                notes: newNotes
            )
        } else {
            // Local kinds — create a record, the file shows up after
            // download() or import completes.
            let dir = store.directory(for: UUID().uuidString)
            model = TracerModel(
                id: dir.lastPathComponent,
                displayName: trimmed,
                kind: newKind,
                sourceURL: sourceURL,
                localPath: dir.appendingPathComponent(sourceURL?.lastPathComponent ?? trimmed).path,
                license: newLicense,
                notes: newNotes
            )
        }
        store.add(model)
        statusMessage = "Added \(trimmed)"
        clearForm()
    }

    #if canImport(AppKit)
    /// Pick an existing file/folder on disk and copy it into the store
    /// under a fresh model id. Used for CoreML packages / GGUFs / tree JSONs
    /// the user already downloaded out-of-band.
    public func importFromDisk() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick a model file to import into Tracer"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let inferredKind = Self.inferKind(from: url)
        let displayName = newDisplayName.isEmpty
            ? url.deletingPathExtension().lastPathComponent
            : newDisplayName

        var model = TracerModel(
            displayName: displayName,
            kind: inferredKind,
            sourceURL: URL(fileURLWithPath: url.path),
            localPath: url.path,
            license: newLicense,
            notes: newNotes
        )
        do {
            model = try store.ingest(fileAt: url, into: model)
            statusMessage = "Imported \(url.lastPathComponent) as \(inferredKind.displayName)"
            clearForm()
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }
    #endif

    /// Start downloading a registered model.
    public func download(_ model: TracerModel) async {
        let result = await downloader.download(model, store: store)
        switch result {
        case .success(let updated):
            statusMessage = "Downloaded \(updated.displayName) — \(Self.formatSize(updated.sizeBytes))"
        case .failure(let error):
            statusMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    public func cancelDownload(_ model: TracerModel) {
        downloader.cancel(modelID: model.id)
    }

    public func remove(_ model: TracerModel, deleteFiles: Bool) {
        store.remove(id: model.id, deleteFiles: deleteFiles)
        statusMessage = "Removed \(model.displayName)"
    }

    // MARK: - Binding

    public func startBinding(for modelID: String) {
        bindingModelID = modelID
        bindingCatalogQuery = ""
        showingBindSheet = true
    }

    public func finishBinding(catalogEntryID: String) {
        guard let id = bindingModelID else { return }
        store.bind(modelID: id, to: catalogEntryID)
        statusMessage = "Bound to \(catalogEntryID)"
        showingBindSheet = false
        bindingModelID = nil
    }

    public func unbind(modelID: String, from catalogEntryID: String) {
        store.unbind(modelID: modelID, from: catalogEntryID)
    }

    /// Catalog entries the current binding flow can target. Unions the
    /// nnU-Net catalog + the lesion-classifier catalog + a "custom id"
    /// fallback row.
    public var bindableEntries: [(id: String, displayName: String)] {
        var out: [(String, String)] = []
        for e in NNUnetCatalog.all {
            out.append((e.id, "nnU-Net · \(e.displayName)"))
        }
        for c in LesionClassifierCatalog.all {
            out.append((c.id, "Classifier · \(c.displayName)"))
        }
        if !bindingCatalogQuery.isEmpty {
            let q = bindingCatalogQuery.lowercased()
            return out.filter { $0.1.lowercased().contains(q) || $0.0.lowercased().contains(q) }
        }
        return out
    }

    // MARK: - Helpers

    public func clearForm() {
        newDisplayName = ""
        newSourceURL = ""
        newRemotePath = ""
        newLicense = ""
        newNotes = ""
    }

    public static func formatSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    public static func inferKind(from url: URL) -> TracerModel.Kind {
        let ext = url.pathExtension.lowercased()
        let lower = url.lastPathComponent.lowercased()
        if ext == "mlpackage" || ext == "mlmodelc" || ext == "mlmodel" {
            return .coreML
        }
        if ext == "gguf" {
            return .gguf
        }
        if ext == "json" {
            return .treeModelJSON
        }
        if ext == "py" {
            return .pythonScript
        }
        if ext == "zip" || lower.contains("monai") {
            return .monaiBundle
        }
        if lower.hasPrefix("dataset") {
            return .nnunetDataset
        }
        return .coreML
    }
}
