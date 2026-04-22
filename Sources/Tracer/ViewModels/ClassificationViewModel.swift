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
    @Published public var zeroShotTokenIDs: String = ""
    @Published public var customEnvironment: String = ""
    @Published public var candidateLabels: String = "benign\nmalignant"

    /// When `true`, subprocess / radiomics classifiers run on the user's
    /// DGX Spark over SSH instead of locally. Settings → DGX Spark must be
    /// configured + enabled for this to take effect.
    @Published public var runOnDGX: Bool = false

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
        let classifierMask = labelMap.snapshot(name: "\(labelMap.name) classification snapshot")

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
                    mask: classifierMask,
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
            guard !customModelPath.isEmpty else {
                throw ClassificationError.modelUnavailable(
                    "Provide a trained TreeModel JSON exported from your training pipeline."
                )
            }
            let model = try TreeModel.load(
                contentsOf: URL(fileURLWithPath: (customModelPath as NSString).expandingTildeInPath)
            )
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
            let tokenRows = try Self.parseZeroShotTokenIDs(zeroShotTokenIDs)
            guard prompts.count == labels.count,
                  tokenRows.count == labels.count,
                  !prompts.isEmpty else {
                throw ClassificationError.modelUnavailable(
                    "MedSigLIP needs matching label, prompt, and tokenizer ID lines."
                )
            }
            let tokenised = zip(zip(labels, prompts), tokenRows).map { pair, tokenIDs in
                MedSigLIPClassifier.TokenisedPrompt(
                    label: pair.0,
                    text: pair.1,
                    tokenIDs: tokenIDs
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
            // Remote path — run the classifier on the DGX if the user has
            // flipped "Run on DGX Spark" in the panel + configured the host.
            if runOnDGX {
                let cfg = DGXSparkConfig.load()
                guard cfg.isConfigured else {
                    throw ClassificationError.modelUnavailable(
                        "DGX Spark not configured. Settings → DGX Spark."
                    )
                }
                let remoteSpec = RemoteLesionClassifier.Spec(
                    dgx: cfg,
                    remoteScriptPath: customBinaryPath,
                    activationCommand: customEnvironment
                        .split(separator: "\n")
                        .first { $0.hasPrefix("activate=") }
                        .map { String($0.dropFirst("activate=".count)) } ?? ""
                )
                return RemoteLesionClassifier(
                    id: entry.id,
                    displayName: "\(entry.displayName) · DGX",
                    spec: remoteSpec,
                    supportedModalities: entry.modality.map { [$0] } ?? [],
                    supportedBodyRegions: [entry.bodyRegion]
                )
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

    static func parseZeroShotTokenIDs(_ raw: String) throws -> [[Int32]] {
        try raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let pieces = line.split { ch in
                    ch == "," || ch == " " || ch == "\t"
                }
                guard !pieces.isEmpty else {
                    throw ClassificationError.modelUnavailable("MedSigLIP token ID line is empty.")
                }
                return try pieces.map { piece -> Int32 in
                    guard let value = Int32(String(piece)) else {
                        throw ClassificationError.modelUnavailable(
                            "Invalid MedSigLIP token ID: \(piece)"
                        )
                    }
                    return value
                }
            }
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
