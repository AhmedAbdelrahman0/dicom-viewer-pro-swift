import Foundation

/// Curated registry of detection backends that Tracer ships catalog
/// entries for. Modeled on `LesionClassifierCatalog` and `PETACCatalog` —
/// entries describe what the model does + which backend runs it; the
/// view model instantiates the concrete `LesionDetector` from the
/// entry plus the user's supplied paths.
///
/// Entries are deliberately metadata-only — they don't load weights at
/// startup. The first call to `makeDetector(...)` boots the backend.
public enum LesionDetectorCatalog {
    public static let all: [Entry] = [
        nnDetectionAutoPET,
        nnDetectionLIDC,
        deepLesionCT,
        medSigLIPHeatmap,
        medGemmaDescriber,
        ctFMLesionDetector
    ]

    public static func byID(_ id: String) -> Entry? {
        all.first { $0.id == id }
    }

    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: String
        public let displayName: String
        public let backend: Backend
        public let modality: Modality?
        public let bodyRegion: String
        /// Class labels the model emits. Empty = "model decides" (e.g. VLM
        /// models that can name anything they see).
        public let classes: [String]
        public let description: String
        public let provenance: String
        public let license: String
        /// Whether the model needs an anatomical channel (CT/MR) on the
        /// PET grid in addition to the primary input.
        public let requiresAnatomicalChannel: Bool
        /// `false` when the user must supply at least a script path
        /// before the detector can run.
        public let requiresConfiguration: Bool
    }

    public enum Backend: String, Hashable, Sendable {
        case subprocess
        case dgxRemote

        public var displayName: String {
            switch self {
            case .subprocess: return "Python subprocess"
            case .dgxRemote:  return "Remote Workstation"
            }
        }
    }

    // MARK: - Curated entries

    /// nnDetection is the detection sibling of nnU-Net — same self-
    /// configuring pipeline, but produces 3D bounding boxes instead of
    /// voxel masks. Trained variants exist for AutoPET, KiTS, LIDC, etc.
    /// We list the AutoPET variant separately because PET detection has
    /// a distinct UX (auto-fuse with CT, SUV-aware preprocessing).
    public static let nnDetectionAutoPET = Entry(
        id: "nndetection-autopet",
        displayName: "nnDetection — AutoPET (FDG PET/CT lesion boxes)",
        backend: .subprocess,
        modality: .PT,
        bodyRegion: "Whole Body",
        classes: ["malignant_lesion"],
        description: "MIC-DKFZ nnDetection trained on AutoPET. Reads the NAC/AC PET (and optionally CT) and emits one detection per FDG-avid lesion with a confidence score. Ideal for fast triage when full segmentation is overkill.",
        provenance: "MIC-DKFZ / nnDetection. Bring your own trained checkpoint from the AutoPET data — Tracer ships no weights.",
        license: "Apache-2.0 (code) — model weights vary",
        requiresAnatomicalChannel: false,
        requiresConfiguration: true
    )

    /// nnDetection trained on LIDC-IDRI — single-class lung nodule
    /// detector. Pairs naturally with the existing CoreML lung-nodule
    /// classifier in the lesion classifier catalog.
    public static let nnDetectionLIDC = Entry(
        id: "nndetection-lidc",
        displayName: "nnDetection — LIDC (CT lung nodule boxes)",
        backend: .subprocess,
        modality: .CT,
        bodyRegion: "Thorax",
        classes: ["lung_nodule"],
        description: "Lung-nodule detection on chest CT. Boxes feed the lung-nodule radiomics / CoreML classifiers downstream when you want detection + classification chained.",
        provenance: "LIDC-IDRI (CC BY 3.0 dataset, weights research-only).",
        license: "Apache-2.0 (code), data CC BY 3.0",
        requiresAnatomicalChannel: false,
        requiresConfiguration: true
    )

    /// DeepLesion is NIH's 32k-lesion CT dataset; several public models
    /// trained on it emit per-lesion bounding boxes plus an anatomical-
    /// region tag (lung, liver, mediastinum, …). Best general-purpose
    /// CT lesion detector when modality-specific weights aren't available.
    public static let deepLesionCT = Entry(
        id: "deeplesion-ct",
        displayName: "DeepLesion — universal CT lesion detector",
        backend: .subprocess,
        modality: .CT,
        bodyRegion: "Whole Body",
        classes: ["lesion"],
        description: "Yan et al. (NIH) 32k-lesion CT detector. Produces a 3D box per finding plus an anatomical-region tag (lung, liver, mediastinum, abdomen, soft tissue, bone, kidney). Useful for catalog-wide CT triage.",
        provenance: "NIH Clinical Center DeepLesion dataset (Yan 2018, MICCAI).",
        license: "Research-only",
        requiresAnatomicalChannel: false,
        requiresConfiguration: true
    )

    /// Heatmap-based zero-shot detection: MedSigLIP scores patches
    /// against a prompt list, the wrapper script thresholds the heatmap
    /// to yield bounding boxes per prompt. Slower than dedicated
    /// detectors but flexible — any prompt list, any modality.
    public static let medSigLIPHeatmap = Entry(
        id: "medsiglip-heatmap-detection",
        displayName: "MedSigLIP — zero-shot heatmap detection",
        backend: .subprocess,
        modality: nil,
        bodyRegion: "Any",
        classes: [],
        description: "Sliding-window MedSigLIP scoring against a user-supplied prompt list. Heatmap → threshold → connected components → bounding boxes. Works on any modality; pair with prompt engineering for novel lesion classes.",
        provenance: "MedSigLIP-compatible model; wrapper script supplied by user.",
        license: "Model/provider terms apply",
        requiresAnatomicalChannel: false,
        requiresConfiguration: true
    )

    /// MedGemma multimodal LLM as a detector — give it the volume +
    /// "list every lesion you see with location and likely diagnosis",
    /// parse the structured response. Slowest backend but emits
    /// human-readable rationale per detection.
    public static let medGemmaDescriber = Entry(
        id: "medgemma-describer",
        displayName: "MedGemma 4B — multimodal lesion describer",
        backend: .subprocess,
        modality: nil,
        bodyRegion: "Any",
        classes: [],
        description: "MedGemma 4B prompted to enumerate findings as structured JSON (one entry per lesion with bounding box, label, and free-text rationale). Slowest backend (~10–30 s per study) but yields explanations the radiologist can audit.",
        provenance: "MedGemma-compatible model via llama.cpp / GGUF weights.",
        license: "Model/provider terms apply",
        requiresAnatomicalChannel: false,
        requiresConfiguration: true
    )

    /// CT-FM (foundation model) detection. Heavier infrastructure but
    /// state-of-the-art per-organ accuracy when running on a remote workstation.
    public static let ctFMLesionDetector = Entry(
        id: "ct-fm-detection-dgx",
        displayName: "CT-FM — foundation-model CT lesion detection (remote workstation)",
        backend: .dgxRemote,
        modality: .CT,
        bodyRegion: "Whole Body",
        classes: ["lesion"],
        description: "CT foundation model fine-tuned for lesion detection. Designed for remote workstation execution because the model is too large for typical local hardware. Accepts CT volumes and returns boxes per organ system.",
        provenance: "Bring your own trained checkpoint hosted on the configured remote workstation.",
        license: "Depends on the user's model.",
        requiresAnatomicalChannel: false,
        requiresConfiguration: true
    )
}
