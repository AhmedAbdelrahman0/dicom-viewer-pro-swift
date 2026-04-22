import Foundation
import CryptoKit

/// Single registered model in Tracer's local weight store.  The registry is
/// intentionally backend-agnostic — nnU-Net checkpoint archives, CoreML
/// `.mlpackage`s, GGUF files for MedGemma, pyradiomics tree JSON, and MONAI
/// bundles all fit the same shape.  The type of the artifact is encoded in
/// `kind`; binders translate that into the backend-specific Spec at runtime.
public struct TracerModel: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var displayName: String
    public var kind: Kind
    /// Where the artifact was fetched from — the HuggingFace URL, the
    /// Zenodo record, a file:// URL when the user imported from disk, or
    /// `ssh://dgx:~/nnUNet_results/...` for a DGX-hosted artifact.
    public var sourceURL: URL?
    /// Absolute path on disk. For `.kind == .remoteArtifact` this points at
    /// the path *on* the DGX; otherwise it's a path under Tracer's
    /// Application Support models directory.
    public var localPath: String
    /// Raw SHA-256 of the artifact (hex). Optional — user-imported or
    /// DGX-hosted artifacts may not have one. Download verification uses
    /// this when present.
    public var sha256: String?
    /// Size on disk in bytes (local) or declared size (remote).  Shown as
    /// MB / GB in the UI; used by the downloader for progress.
    public var sizeBytes: Int
    public var addedAt: Date
    public var license: String
    public var notes: String
    /// Catalog entry ids this model is bound to. A single file can back
    /// more than one catalog entry — e.g. the same MedGemma GGUF underlies
    /// both the liver-lesion and lung-nodule MedGemma catalog slots.
    public var boundCatalogEntryIDs: [String]

    public enum Kind: String, Codable, Hashable, Sendable {
        /// CoreML `.mlpackage` or `.mlmodelc` — used by
        /// `NNUnetCoreMLRunner`, `CoreMLLesionClassifier`, `MedSigLIPClassifier`.
        case coreML
        /// nnU-Net v2 dataset archive (unpacked under `$nnUNet_results`).
        case nnunetDataset
        /// GGUF-quantised LLM weights for llama.cpp / `MedGemmaClassifier`.
        case gguf
        /// Tree-ensemble JSON for `RadiomicsLesionClassifier`.
        case treeModelJSON
        /// MONAI model-zoo bundle (`.zip` or directory).
        case monaiBundle
        /// A Python entry point (script) for `SubprocessLesionClassifier`
        /// — the artifact isn't a weight file per se, but bundling the
        /// path with the rest of the registry keeps one pane of glass.
        case pythonScript
        /// Artifact lives on a remote host (typically the user's DGX
        /// Spark) and is referenced by remote path only. The runner must
        /// execute via SSH; nothing local is stored.
        case remoteArtifact

        public var displayName: String {
            switch self {
            case .coreML:         return "CoreML"
            case .nnunetDataset:  return "nnU-Net dataset"
            case .gguf:           return "GGUF weights"
            case .treeModelJSON:  return "Tree JSON"
            case .monaiBundle:    return "MONAI bundle"
            case .pythonScript:   return "Python script"
            case .remoteArtifact: return "Remote (DGX)"
            }
        }
    }

    public init(id: String = UUID().uuidString,
                displayName: String,
                kind: Kind,
                sourceURL: URL? = nil,
                localPath: String,
                sha256: String? = nil,
                sizeBytes: Int = 0,
                addedAt: Date = Date(),
                license: String = "",
                notes: String = "",
                boundCatalogEntryIDs: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.sourceURL = sourceURL
        self.localPath = localPath
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
        self.license = license
        self.notes = notes
        self.boundCatalogEntryIDs = boundCatalogEntryIDs
    }

    /// Convenience: returns `true` if the local artifact exists on disk.
    /// Remote artifacts always return `false` here — callers must
    /// probe the SSH host separately.
    public var existsLocally: Bool {
        kind != .remoteArtifact
            && FileManager.default.fileExists(atPath: localPath)
    }

    public var sizeMB: Double {
        Double(sizeBytes) / (1024 * 1024)
    }

    public var sizeGB: Double {
        Double(sizeBytes) / (1024 * 1024 * 1024)
    }
}

/// SHA-256 helper — produced as lowercase hex, matching HuggingFace + Zenodo.
public enum SHA256Hex {
    public static func hash(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)   // 1 MB
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
