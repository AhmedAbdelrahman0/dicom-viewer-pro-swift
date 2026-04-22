import Foundation

/// Portable JSON tree-ensemble model. The format is designed so users can
/// train a `RandomForestClassifier` or `GradientBoostingClassifier` in
/// scikit-learn / XGBoost / LightGBM and export it with a short script;
/// Tracer then loads it at runtime and runs inference without any Python
/// or CoreML dependency.
///
/// ### Format
/// ```
/// {
///   "features": ["original_firstorder_Mean", ...],   // expected order
///   "classes":  ["benign", "malignant"],             // class labels
///   "aggregation": "mean",                           // "mean" or "softmax"
///   "trees": [
///     {
///       "nodes": [
///         { "feature": 0, "threshold": 10.5, "left": 1, "right": 2 },
///         { "leaf":    [0.9, 0.1] },                 // class probabilities
///         { "leaf":    [0.2, 0.8] }
///       ]
///     },
///     ...
///   ]
/// }
/// ```
///
/// The `aggregation` field chooses how per-tree leaf vectors combine: `mean`
/// for RandomForest-style probability averaging, `softmax` for boosting
/// ensembles whose leaves output logits.
///
/// ### Limits
/// This is deliberately minimal — no categorical splits, no missing-value
/// handling, no tree weights. For anything more complex, export through a
/// subprocess (scikit-learn onnx → CoreML) rather than shoe-horning extra
/// features into the JSON schema.
public struct TreeModel: Codable, Sendable {
    public let features: [String]
    public let classes: [String]
    public let aggregation: Aggregation
    public let trees: [Tree]

    public enum Aggregation: String, Codable, Sendable {
        case mean       // RandomForest / ExtraTrees probability averaging
        case softmax    // XGBoost / LightGBM boosting — leaves are logits
    }

    public struct Tree: Codable, Sendable {
        public let nodes: [Node]
    }

    /// A node is either an internal split (`feature` / `threshold` / `left` /
    /// `right`) or a leaf (`leaf` — one probability per class).
    public struct Node: Codable, Sendable {
        public let feature: Int?
        public let threshold: Double?
        public let left: Int?
        public let right: Int?
        public let leaf: [Double]?
    }

    // MARK: - Loading

    public static func load(contentsOf url: URL) throws -> TreeModel {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TreeModel.self, from: data)
    }

    public static func load(json: String) throws -> TreeModel {
        guard let data = json.data(using: .utf8) else {
            throw ClassificationError.modelLoadFailed("tree-model JSON is not UTF-8")
        }
        return try JSONDecoder().decode(TreeModel.self, from: data)
    }

    // MARK: - Inference

    /// Score a single feature dictionary. Missing features (from an older
    /// export, or a lesion too small for GLCM) are treated as `0`. Returns
    /// probabilities in the same order as `classes`.
    public func score(_ features: [String: Double]) throws -> [Double] {
        let vector = Self.featureVector(for: self.features, dict: features)
        guard !trees.isEmpty, !classes.isEmpty else {
            throw ClassificationError.modelLoadFailed("empty tree ensemble")
        }

        var accumulator = [Double](repeating: 0, count: classes.count)
        for tree in trees {
            let leaf = try traverse(tree: tree, vector: vector)
            guard leaf.count == classes.count else {
                throw ClassificationError.modelLoadFailed(
                    "leaf size \(leaf.count) doesn't match class count \(classes.count)"
                )
            }
            for (i, value) in leaf.enumerated() {
                accumulator[i] += value
            }
        }

        switch aggregation {
        case .mean:
            let inv = 1.0 / Double(trees.count)
            return accumulator.map { $0 * inv }
        case .softmax:
            return Self.softmax(accumulator)
        }
    }

    public func predictions(for features: [String: Double]) throws -> [LabelPrediction] {
        let probs = try score(features)
        return zip(classes, probs).map {
            LabelPrediction(label: $0.0, probability: $0.1)
        }
    }

    // MARK: - Private

    private func traverse(tree: Tree, vector: [Double]) throws -> [Double] {
        guard var cursor = tree.nodes.first else {
            throw ClassificationError.modelLoadFailed("tree has no nodes")
        }
        var cursorIndex = 0
        var hops = 0
        while cursor.leaf == nil {
            guard let featureIdx = cursor.feature,
                  let threshold = cursor.threshold,
                  let left = cursor.left,
                  let right = cursor.right,
                  featureIdx >= 0, featureIdx < vector.count,
                  left >= 0, left < tree.nodes.count,
                  right >= 0, right < tree.nodes.count else {
                throw ClassificationError.modelLoadFailed(
                    "malformed tree node at index \(cursorIndex)"
                )
            }
            let next = vector[featureIdx] <= threshold ? left : right
            cursor = tree.nodes[next]
            cursorIndex = next
            hops += 1
            if hops > 4096 {
                throw ClassificationError.modelLoadFailed("tree traversal exceeded 4096 hops — likely cyclic")
            }
        }
        return cursor.leaf ?? []
    }

    private static func featureVector(for names: [String],
                                      dict: [String: Double]) -> [Double] {
        names.map { dict[$0] ?? 0 }
    }

    private static func softmax(_ logits: [Double]) -> [Double] {
        guard !logits.isEmpty else { return [] }
        let maxL = logits.max() ?? 0
        let exps = logits.map { exp($0 - maxL) }
        let denom = max(exps.reduce(0, +), 1e-12)
        return exps.map { $0 / denom }
    }
}

/// Classifier that extracts radiomics features and scores them through a
/// `TreeModel` ensemble. Completely offline, native Swift, < 10 MB on disk
/// for a typical RandomForest.
public final class RadiomicsLesionClassifier: LesionClassifier, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let supportedModalities: [Modality]
    public let supportedBodyRegions: [String]
    public let provenance: String

    private let model: TreeModel

    public init(id: String,
                displayName: String,
                supportedModalities: [Modality] = [],
                supportedBodyRegions: [String] = [],
                provenance: String = "",
                model: TreeModel) {
        self.id = id
        self.displayName = displayName
        self.supportedModalities = supportedModalities
        self.supportedBodyRegions = supportedBodyRegions
        self.provenance = provenance
        self.model = model
    }

    /// Convenience — load the tree model from a JSON file on disk.
    public convenience init(id: String,
                            displayName: String,
                            modelURL: URL,
                            supportedModalities: [Modality] = [],
                            supportedBodyRegions: [String] = [],
                            provenance: String = "") throws {
        let model = try TreeModel.load(contentsOf: modelURL)
        self.init(
            id: id,
            displayName: displayName,
            supportedModalities: supportedModalities,
            supportedBodyRegions: supportedBodyRegions,
            provenance: provenance,
            model: model
        )
    }

    public func classify(volume: ImageVolume,
                         mask: LabelMap,
                         classID: UInt16,
                         bounds: MONAITransforms.VoxelBounds) async throws -> ClassificationResult {
        let start = Date()
        let features = try RadiomicsExtractor.extract(
            volume: volume,
            mask: mask,
            classID: classID,
            bounds: bounds
        )
        let predictions = try model.predictions(for: features)
        return ClassificationResult(
            predictions: predictions,
            rationale: nil,
            features: features,
            durationSeconds: Date().timeIntervalSince(start),
            classifierID: id
        )
    }
}
