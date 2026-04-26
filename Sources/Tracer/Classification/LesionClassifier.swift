import Foundation

/// Abstract interface for per-lesion classification. Classifiers take a
/// cropped lesion (volume + mask restricted to a single class id inside a
/// bounding box) and return one or more class predictions with softmax
/// confidences, plus optional explanatory rationale and a dump of
/// engineered features for report inclusion.
///
/// Concrete runners live alongside this file:
///   • `RadiomicsLesionClassifier`  — pyradiomics-style features + tree model
///   • `CoreMLLesionClassifier`     — generic `.mlpackage` runner
///   • `MedSigLIPClassifier`        — zero-shot CLIP-style vision-text
///   • `SubprocessLesionClassifier` — shell out to a user's Python model
///   • `MedGemmaClassifier`         — llama.cpp / GGUF multimodal reasoning
public protocol LesionClassifier: Sendable {
    /// Stable id used for config / routing / logging.
    var id: String { get }
    var displayName: String { get }
    /// Modalities the classifier is known to work for — used by the UI to
    /// warn the user when they run a classifier on an off-spec volume.
    /// Empty = "any".
    var supportedModalities: [Modality] { get }
    /// Body regions (e.g. "Abdomen", "Thorax", "Brain") the classifier was
    /// trained on. Empty = "any".
    var supportedBodyRegions: [String] { get }
    /// Human-readable provenance line for the report — "trained on LIDC-IDRI
    /// 2022 fold 0, research-only license, Apache-2.0".
    var provenance: String { get }

    /// Classify one lesion. `bounds` is the pre-computed bounding box of the
    /// connected component; the classifier may choose to honour it (crop to
    /// the box) or recompute it internally. Implementations must be
    /// thread-safe off-main — the ViewModel may dispatch to a detached
    /// task when looping across many lesions.
    func classify(volume: ImageVolume,
                  mask: LabelMap,
                  classID: UInt16,
                  bounds: MONAITransforms.VoxelBounds) async throws -> ClassificationResult
}

/// One prediction — a class label with its softmax probability.
public struct LabelPrediction: Equatable, Hashable, Codable, Sendable {
    public let label: String
    public let probability: Double

    public init(label: String, probability: Double) {
        self.label = label
        self.probability = probability
    }
}

/// Full result of classifying a single lesion.
public struct ClassificationResult: Sendable {
    /// Predictions sorted by `probability` descending. The first entry is
    /// the model's top pick.
    public let predictions: [LabelPrediction]
    /// Optional free-text rationale — populated by language models
    /// (MedGemma) or zero-shot scorers. Nil for pure tree / CoreML output.
    public let rationale: String?
    /// Feature dump for the report. Radiomics classifiers populate ~30
    /// features here; CoreML / zero-shot classifiers may leave it empty.
    public let features: [String: Double]
    /// Wall-clock duration for the classification call. Useful for the UI
    /// to display "Classified N lesions in 1.2 s".
    public let durationSeconds: TimeInterval
    /// Classifier id that produced this result — echoed back so report
    /// output can attribute each prediction to a named model.
    public let classifierID: String

    public init(predictions: [LabelPrediction],
                rationale: String? = nil,
                features: [String: Double] = [:],
                durationSeconds: TimeInterval = 0,
                classifierID: String = "unknown") {
        self.predictions = predictions
            .sorted { $0.probability > $1.probability }
        self.rationale = rationale
        self.features = features
        self.durationSeconds = durationSeconds
        self.classifierID = classifierID
    }

    public var topLabel: String? { predictions.first?.label }
    public var topProbability: Double { predictions.first?.probability ?? 0 }
}

/// Errors that every classifier shares.
public enum ClassificationError: Error, LocalizedError {
    case emptyLesion
    case gridMismatch(String)
    case modelLoadFailed(String)
    case modelUnavailable(String)
    case inferenceFailed(String)
    case unsupportedOutputShape(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyLesion:               return "The lesion bounding box is empty."
        case .gridMismatch(let m):       return "Classifier grid mismatch: \(m)"
        case .modelLoadFailed(let m):    return "Could not load classifier model: \(m)"
        case .modelUnavailable(let m):   return "Classifier model unavailable: \(m)"
        case .inferenceFailed(let m):    return "Classifier inference failed: \(m)"
        case .unsupportedOutputShape(let m): return "Unexpected classifier output shape: \(m)"
        case .cancelled:                 return "Classification was cancelled."
        }
    }
}

/// Reuses the bounds struct already defined in `MONAITransforms`. Classifiers
/// often need to resolve a non-empty bounds before calling the backbone —
/// `PETQuantification.compute(...)` already returns per-lesion bounds in the
/// same coordinate system; the classifier pipeline just threads those
/// through.
public typealias LesionBounds = MONAITransforms.VoxelBounds
