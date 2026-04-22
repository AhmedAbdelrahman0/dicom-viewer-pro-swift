import Foundation

/// Curated registry of classifier presets — the classification-side analogue
/// of `NNUnetCatalog`. Each entry describes *what* is being classified,
/// which backend it uses, and whatever auxiliary configuration the user has
/// to provide (model path for CoreML, script path for subprocess, prompt
/// list for zero-shot, etc.) before the runner can actually execute.
///
/// Entries are deliberately metadata-only — they do **not** instantiate a
/// classifier at startup. `makeClassifier(for:)` produces the concrete
/// classifier when the user picks an entry + fills in the required paths.
public enum LesionClassifierCatalog {
    public static let all: [Entry] = [
        lungNoduleRadiomics,
        liverLesionRadiomics,
        petLesionRadiomics,
        lungNoduleCoreML,
        liverLesionCoreML,
        prostatePIRADSCoreML,
        medSigLIPZeroShot,
        subprocessPyradiomicsXGBoost,
        medGemma4B,
    ]

    public static func byID(_ id: String) -> Entry? {
        all.first { $0.id == id }
    }

    // MARK: - Types

    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: String
        public let displayName: String
        public let backend: Backend
        public let modality: Modality?
        public let bodyRegion: String
        public let classes: [String]
        public let description: String
        public let provenance: String
        public let notes: String
        /// Human-readable licence summary — shown in the UI so users never
        /// mistake a research-only model for an FDA-cleared product.
        public let license: String
        /// Whether the entry can be instantiated from built-in defaults
        /// alone. `false` means the user must supply at least one path
        /// (CoreML model, subprocess binary, etc.) before the classifier
        /// can run — the panel surfaces a missing-config warning.
        public let requiresConfiguration: Bool
    }

    public enum Backend: String, Hashable, Sendable {
        case radiomicsTree       // RadiomicsLesionClassifier + bundled JSON
        case coreML              // CoreMLLesionClassifier (.mlpackage)
        case medSigLIPZeroShot   // MedSigLIPClassifier (vision + text)
        case subprocess          // SubprocessLesionClassifier (Python)
        case medGemma            // MedGemmaClassifier (llama.cpp)

        public var displayName: String {
            switch self {
            case .radiomicsTree:     return "Radiomics + tree model"
            case .coreML:            return "CoreML .mlpackage"
            case .medSigLIPZeroShot: return "MedSigLIP zero-shot"
            case .subprocess:        return "Python subprocess"
            case .medGemma:          return "MedGemma multimodal"
            }
        }
    }

    // MARK: - Curated entries

    // --- Radiomics (ships with a default tree model JSON bundled in
    //     Resources; entries are self-sufficient). ---

    public static let lungNoduleRadiomics = Entry(
        id: "lung-nodule-radiomics",
        displayName: "Lung nodule — radiomics (pyradiomics features + RF)",
        backend: .radiomicsTree,
        modality: .CT,
        bodyRegion: "Thorax",
        classes: ["benign", "malignant"],
        description: "Classic 30-feature radiomics signature feeding a small RandomForest trained on LIDC-IDRI. Runs entirely on CPU, no external dependencies.",
        provenance: "Trained on LIDC-IDRI — public research dataset.",
        notes: "Sub-second per lesion. Apache-2.0 (pyradiomics port).",
        license: "Apache-2.0 (code)",
        requiresConfiguration: false
    )

    public static let liverLesionRadiomics = Entry(
        id: "liver-lesion-radiomics",
        displayName: "Liver lesion — radiomics (pyradiomics features + XGBoost)",
        backend: .radiomicsTree,
        modality: .CT,
        bodyRegion: "Abdomen",
        classes: ["benign", "HCC", "metastasis"],
        description: "Radiomics signature from the LiTS challenge, distilled into an XGBoost tree ensemble. Three-way HCC / mets / benign discrimination.",
        provenance: "LiTS + in-house curation.",
        notes: "Drop a volume + liver-lesion mask in; get predictions in <1 s.",
        license: "Apache-2.0 (code), data references LiTS CC-BY-SA",
        requiresConfiguration: false
    )

    public static let petLesionRadiomics = Entry(
        id: "pet-lesion-radiomics",
        displayName: "PET lesion — radiomics (SUV-scaled features + XGBoost)",
        backend: .radiomicsTree,
        modality: .PT,
        bodyRegion: "Whole Body",
        classes: ["physiologic", "inflammatory", "malignant"],
        description: "AutoPET-inspired radiomics signature — SUV-centric first-order features + shape compactness + texture.",
        provenance: "AutoPET II training set (FDG-PET/CT).",
        notes: "Intended as a triage tool after a lesion segmentation step.",
        license: "Apache-2.0 (code)",
        requiresConfiguration: false
    )

    // --- CoreML task-specific. User supplies the .mlpackage path. ---

    public static let lungNoduleCoreML = Entry(
        id: "lung-nodule-coreml",
        displayName: "Lung nodule CNN — Nodule-CLIP / LIDC EfficientNet",
        backend: .coreML,
        modality: .CT,
        bodyRegion: "Thorax",
        classes: ["benign", "malignant"],
        description: "Drop in a LIDC-IDRI-trained EfficientNet-B0 or Nodule-CLIP `.mlpackage` (convert from PyTorch via `coremltools`).",
        provenance: "LIDC-IDRI; convert your PyTorch checkpoint to CoreML.",
        notes: "~90–97% accuracy reported on LIDC in published literature. Ships no weights — research-only if you use published checkpoints.",
        license: "Varies per model — most research-only",
        requiresConfiguration: true
    )

    public static let liverLesionCoreML = Entry(
        id: "liver-lesion-coreml",
        displayName: "Liver lesion CNN — LiLNet",
        backend: .coreML,
        modality: .CT,
        bodyRegion: "Abdomen",
        classes: ["benign", "HCC", "metastasis"],
        description: "LiLNet 3D DenseNet variant (Nature Comms 2024). Convert the published checkpoint to CoreML.",
        provenance: "LiLNet weights (research request) → CoreML.",
        notes: "0.97 AUC on its benchmark.",
        license: "Research-only",
        requiresConfiguration: true
    )

    public static let prostatePIRADSCoreML = Entry(
        id: "prostate-pirads-coreml",
        displayName: "Prostate PI-RADS — PI-CAI nnDetection ensemble",
        backend: .coreML,
        modality: .MR,
        bodyRegion: "Pelvis",
        classes: ["PI-RADS 2", "PI-RADS 3", "PI-RADS 4", "PI-RADS 5"],
        description: "PI-CAI 2022 winning ensemble — export to CoreML for on-device prostate PI-RADS scoring.",
        provenance: "PI-CAI Grand Challenge winners, Apache-2.0.",
        notes: "Needs multi-parametric MRI (T2 + DWI + ADC); upstream must provide resampled channels.",
        license: "Apache-2.0",
        requiresConfiguration: true
    )

    // --- Zero-shot. ---

    public static let medSigLIPZeroShot = Entry(
        id: "medsiglip-zero-shot",
        displayName: "MedSigLIP zero-shot (any prompt list)",
        backend: .medSigLIPZeroShot,
        modality: nil,
        bodyRegion: "Any",
        classes: [],    // user-defined
        description: "Google MedSigLIP — convert the image + text encoders to CoreML, supply a prompt list, and Tracer returns softmax-scored class probabilities without any training.",
        provenance: "Google HAI-DEF MedSigLIP.",
        notes: "Flexible — any modality, any class list. Expect 70-85% of a fine-tuned model's accuracy.",
        license: "Google HAI-DEF (research + commercial with terms)",
        requiresConfiguration: true
    )

    // --- Subprocess (Python). ---

    public static let subprocessPyradiomicsXGBoost = Entry(
        id: "subprocess-pyradiomics",
        displayName: "Python subprocess — pyradiomics + scikit-learn / XGBoost",
        backend: .subprocess,
        modality: nil,
        bodyRegion: "Any",
        classes: [],
        description: "Shell out to a Python script that reads VOI + mask from stdin and returns JSON probabilities. Keeps Tracer decoupled from specific Python dependencies.",
        provenance: "Whatever the user's environment provides.",
        notes: "Ideal for teams with existing pyradiomics / sklearn pipelines.",
        license: "Depends on the user's model",
        requiresConfiguration: true
    )

    // --- Multimodal LLM. ---

    public static let medGemma4B = Entry(
        id: "medgemma-4b",
        displayName: "MedGemma 4B multimodal (llama.cpp / GGUF)",
        backend: .medGemma,
        modality: nil,
        bodyRegion: "Any",
        classes: [],
        description: "MedGemma 4B instruction-tuned (2024–2025) running through llama.cpp with a GGUF-quantised weights file. Produces a JSON diagnosis + free-text rationale per lesion.",
        provenance: "Google MedGemma — distributed via HuggingFace GGUFs (bartowski, unsloth, etc.).",
        notes: "~3 GB on disk for the 4B Q4_K_M. Expect 1–3 s per lesion on an M-series Mac.",
        license: "Google Health AI Developer Foundations (research + commercial with terms)",
        requiresConfiguration: true
    )
}
