import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// State + orchestration for the "classify lesions" workflow. Given an
/// active label map, enumerates connected components, classifies each via
/// the selected classifier, and publishes per-lesion `ClassificationResult`
/// values that the report / panel can render.
@MainActor
public final class ClassificationViewModel: ObservableObject {

    // MARK: - Published state

    @Published public var selectedEntryID: String = LesionClassifierCatalog.all.first?.id ?? ""
    @Published public var customModelPath: String = ""
    @Published public var customBinaryPath: String = ""
    @Published public var customProjectorPath: String = ""
    @Published public var zeroShotPrompts: String = """
    a CT image of a benign liver hemangioma
    a CT image of hepatocellular carcinoma
    a CT image of a hepatic metastasis
    """
    @Published public var zeroShotPromptLabels: String = "benign\nmalignant\nmetastasis"
    @Published public var customEnvironment: String = ""
    @Published public var candidateLabels: String = "benign\nmalignant"

    /// Latest results keyed by lesion id (= connected-component number).
    @Published public private(set) var lastResults: [LesionResult] = []
    @Published public private(set) var isRunning: Bool = false
    @Published public var statusMessage: String = ""

    public struct LesionResult: Identifiable {
        public let id: Int
        public let lesion: PETQuantification.LesionStats
        public let result: ClassificationResult
    }

    // MARK: - Public API

    public var selectedEntry: LesionClassifierCatalog.Entry? {
        LesionClassifierCatalog.byID(selectedEntryID)
    }

    public init() {}

    /// Run classification over every connected component of the active
    /// label map. `petVolume` supplies intensity values — for non-PET data
    /// the caller should pass the primary volume.
    @discardableResult
    public func classifyAll(volume: ImageVolume,
                            labelMap: LabelMap,
                            classID: UInt16) async -> [LesionResult] {
        guard let entry = selectedEntry else {
            statusMessage = "Pick a classifier first."
            return []
        }

        isRunning = true
        defer { isRunning = false }

        // Enumerate connected components + bounds by piggy-backing on the
        // existing PETQuantification machinery — we already compute those
        // numbers for TMTV reports, so re-using them keeps the report
        // row / classification row aligned by lesion id.
        let report: PETQuantification.Report
        do {
            report = try PETQuantification.compute(
                petVolume: volume,
                labelMap: labelMap,
                classes: [classID],
                connectedComponents: true
            )
        } catch {
            statusMessage = "Could not enumerate lesions: \(error.localizedDescription)"
            lastResults = []
            return []
        }
        guard !report.lesions.isEmpty else {
            statusMessage = "No lesions found for class \(classID)."
            lastResults = []
            return []
        }

        // Build the concrete classifier from the entry + user config.
        let classifier: LesionClassifier
        do {
            classifier = try makeClassifier(for: entry)
        } catch {
            statusMessage = "Classifier unavailable: \(error.localizedDescription)"
            lastResults = []
            return []
        }

        statusMessage = "Classifying \(report.lesions.count) lesions with \(classifier.displayName)…"

        var produced: [LesionResult] = []
        for lesion in report.lesions {
            let bounds = MONAITransforms.VoxelBounds(
                minZ: lesion.bounds.minZ, maxZ: lesion.bounds.maxZ,
                minY: lesion.bounds.minY, maxY: lesion.bounds.maxY,
                minX: lesion.bounds.minX, maxX: lesion.bounds.maxX
            )
            do {
                let result = try await classifier.classify(
                    volume: volume,
                    mask: labelMap,
                    classID: lesion.classID,
                    bounds: bounds
                )
                produced.append(LesionResult(
                    id: produced.count + 1,
                    lesion: lesion,
                    result: result
                ))
            } catch {
                statusMessage = "Lesion \(produced.count + 1) failed: \(error.localizedDescription)"
            }
        }

        lastResults = produced
        statusMessage = "Classified \(produced.count) / \(report.lesions.count) lesions."
        return produced
    }

    // MARK: - Builder

    private func makeClassifier(for entry: LesionClassifierCatalog.Entry) throws -> LesionClassifier {
        switch entry.backend {
        case .radiomicsTree:
            // Demo / placeholder model — two-class benign/malignant with a
            // single stump on the 90th percentile. Users will override with
            // their own trained tree model via `customModelPath`. Keeps the
            // code path exercisable without shipping a real classifier weight.
            let model: TreeModel
            if !customModelPath.isEmpty {
                model = try TreeModel.load(
                    contentsOf: URL(fileURLWithPath: (customModelPath as NSString).expandingTildeInPath)
                )
            } else {
                model = Self.builtInPlaceholderTree(classes: entry.classes.isEmpty
                                                    ? ["benign", "malignant"]
                                                    : entry.classes)
            }
            return RadiomicsLesionClassifier(
                id: entry.id,
                displayName: entry.displayName,
                supportedModalities: entry.modality.map { [$0] } ?? [],
                supportedBodyRegions: [entry.bodyRegion],
                provenance: entry.provenance,
                model: model
            )

        case .coreML:
            guard !customModelPath.isEmpty else {
                throw ClassificationError.modelUnavailable("Point at a .mlpackage first.")
            }
            let url = URL(fileURLWithPath: (customModelPath as NSString).expandingTildeInPath)
            let spec = CoreMLLesionClassifier.Spec(
                modelURL: url,
                classes: entry.classes.isEmpty ? ["class0", "class1"] : entry.classes
            )
            return CoreMLLesionClassifier(
                id: entry.id,
                displayName: entry.displayName,
                spec: spec,
                supportedModalities: entry.modality.map { [$0] } ?? [],
                supportedBodyRegions: [entry.bodyRegion],
                provenance: entry.provenance
            )

        case .medSigLIPZeroShot:
            // Comma-separated "image-encoder,text-encoder" in customModelPath.
            let parts = customModelPath
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                throw ClassificationError.modelUnavailable(
                    "MedSigLIP needs '<image-encoder>.mlpackage,<text-encoder>.mlpackage'"
                )
            }
            let imageURL = URL(fileURLWithPath: (parts[0] as NSString).expandingTildeInPath)
            let textURL = URL(fileURLWithPath: (parts[1] as NSString).expandingTildeInPath)

            let prompts = zeroShotPromptLines(zeroShotPrompts)
            let labels = zeroShotPromptLines(zeroShotPromptLabels)
            guard prompts.count == labels.count, !prompts.isEmpty else {
                throw ClassificationError.modelUnavailable(
                    "Zero-shot needs matching prompt + label lines"
                )
            }
            let tokenised = zip(labels, prompts).map { label, text in
                MedSigLIPClassifier.TokenisedPrompt(
                    label: label,
                    text: text,
                    tokenIDs: Self.simpleByteTokens(text: text, maxLen: 77)
                )
            }
            let spec = MedSigLIPClassifier.Spec(
                imageEncoderURL: imageURL,
                textEncoderURL: textURL,
                imageSize: 384,
                tokenisedPrompts: tokenised
            )
            return MedSigLIPClassifier(
                id: entry.id,
                displayName: entry.displayName,
                spec: spec,
                supportedModalities: entry.modality.map { [$0] } ?? [],
                supportedBodyRegions: [entry.bodyRegion]
            )

        case .subprocess:
            guard !customBinaryPath.isEmpty else {
                throw ClassificationError.modelUnavailable("Point at a Python script first.")
            }
            let envDict: [String: String] = customEnvironment
                .split(separator: "\n")
                .reduce(into: [:]) { acc, line in
                    let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if pair.count == 2 { acc[pair[0]] = pair[1] }
                }
            let spec = SubprocessLesionClassifier.Spec(
                executablePath: (customBinaryPath as NSString).expandingTildeInPath,
                environment: envDict
            )
            return SubprocessLesionClassifier(
                id: entry.id,
                displayName: entry.displayName,
                spec: spec,
                supportedModalities: entry.modality.map { [$0] } ?? [],
                supportedBodyRegions: [entry.bodyRegion]
            )

        case .medGemma:
            guard !customBinaryPath.isEmpty, !customModelPath.isEmpty else {
                throw ClassificationError.modelUnavailable(
                    "Point at llama-cli + a GGUF model first."
                )
            }
            let spec = MedGemmaClassifier.Spec(
                binaryPath: (customBinaryPath as NSString).expandingTildeInPath,
                modelPath: (customModelPath as NSString).expandingTildeInPath,
                projectorPath: customProjectorPath.isEmpty
                    ? nil
                    : (customProjectorPath as NSString).expandingTildeInPath,
                candidateLabels: candidateLabels
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
            return MedGemmaClassifier(
                id: entry.id,
                displayName: entry.displayName,
                spec: spec,
                supportedModalities: entry.modality.map { [$0] } ?? [],
                supportedBodyRegions: [entry.bodyRegion]
            )
        }
    }

    private func zeroShotPromptLines(_ raw: String) -> [String] {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Extremely simple placeholder "tokeniser" — UTF-8 byte codes padded to
    /// `maxLen`. MedSigLIP in the real world uses SentencePiece; users who
    /// need real tokenisation should pre-build token ids in Python and pass
    /// them through `tokenisedPrompts` directly on the Spec. This stub keeps
    /// the code path exercisable without a bundled tokenizer.
    private static func simpleByteTokens(text: String, maxLen: Int) -> [Int32] {
        var ids: [Int32] = text.utf8.prefix(maxLen).map { Int32($0) }
        while ids.count < maxLen { ids.append(0) }
        return ids
    }

    /// A degenerate 2-class radiomics tree model used when the user hasn't
    /// supplied their own JSON. Single feature, single split — it exists
    /// so the "radiomics" path is exercisable end-to-end in tests and demos
    /// without shipping real clinical weights.
    private static func builtInPlaceholderTree(classes: [String]) -> TreeModel {
        let leafA = Array(repeating: 0.0, count: classes.count).enumerated().map { i, _ in
            i == 0 ? 0.8 : (i == 1 ? 0.2 : 0)
        }
        let leafB = Array(repeating: 0.0, count: classes.count).enumerated().map { i, _ in
            i == 1 ? 0.8 : (i == 0 ? 0.2 : 0)
        }
        let normA = leafA.map { $0 / max(leafA.reduce(0, +), 1e-12) }
        let normB = leafB.map { $0 / max(leafB.reduce(0, +), 1e-12) }
        return TreeModel(
            features: ["original_firstorder_90Percentile"],
            classes: classes,
            aggregation: .mean,
            trees: [
                TreeModel.Tree(nodes: [
                    TreeModel.Node(feature: 0, threshold: 150, left: 1, right: 2,
                                   leaf: nil),
                    TreeModel.Node(feature: nil, threshold: nil, left: nil, right: nil,
                                   leaf: normA),
                    TreeModel.Node(feature: nil, threshold: nil, left: nil, right: nil,
                                   leaf: normB)
                ])
            ]
        )
    }

    #if canImport(AppKit)
    public func pickModelPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Pick a classifier model file"
        if panel.runModal() == .OK, let url = panel.url {
            customModelPath = url.path
        }
    }

    public func pickBinaryPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.message = "Pick the classifier binary / Python script"
        if panel.runModal() == .OK, let url = panel.url {
            customBinaryPath = url.path
        }
    }
    #endif
}
