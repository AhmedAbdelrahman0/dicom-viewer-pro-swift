import Foundation

/// Builds a `LesionClassifier` from a cohort job + catalog entry, without
/// touching the `@MainActor`-isolated `ClassificationViewModel`. The cohort
/// processor runs on a background actor and needs a Sendable factory that
/// takes plain config values.
///
/// The logic mirrors `ClassificationViewModel.makeClassifier(for:)` —
/// changes there should land here too. We chose duplication over extraction
/// because the single-study code path has a lot of UI-adjacent helpers
/// (`pickModelPath`, @Published fields, etc.) that don't belong in a
/// cohort-processing module.
enum CohortClassifierFactory {

    static func make(job: CohortJob,
                     entry: LesionClassifierCatalog.Entry) throws -> LesionClassifier {
        switch entry.backend {
        case .radiomicsTree:
            guard !job.classifierModelPath.isEmpty else {
                throw ClassificationError.modelUnavailable(
                    "Cohort job's classifier is radiomics, but no TreeModel JSON was supplied."
                )
            }
            let url = URL(fileURLWithPath: (job.classifierModelPath as NSString).expandingTildeInPath)
            let model = try TreeModel.load(contentsOf: url)
            return RadiomicsLesionClassifier(
                id: entry.id,
                displayName: entry.displayName,
                supportedModalities: entry.modality.map { [$0] } ?? [],
                supportedBodyRegions: [entry.bodyRegion],
                provenance: entry.provenance,
                model: model
            )

        case .coreML:
            guard !job.classifierModelPath.isEmpty else {
                throw ClassificationError.modelUnavailable("Cohort job's CoreML classifier needs an .mlpackage path.")
            }
            let url = URL(fileURLWithPath: (job.classifierModelPath as NSString).expandingTildeInPath)
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
            let parts = job.classifierModelPath
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                throw ClassificationError.modelUnavailable(
                    "MedSigLIP needs '<image-encoder>.mlpackage,<text-encoder>.mlpackage'"
                )
            }
            let imageURL = URL(fileURLWithPath: (parts[0] as NSString).expandingTildeInPath)
            let textURL = URL(fileURLWithPath: (parts[1] as NSString).expandingTildeInPath)

            let prompts = splitLines(job.zeroShotPrompts)
            let labels = splitLines(job.zeroShotLabels)
            let tokenRows = try parseTokenIDs(job.zeroShotTokenIDs)
            guard prompts.count == labels.count,
                  tokenRows.count == labels.count,
                  !prompts.isEmpty else {
                throw ClassificationError.modelUnavailable(
                    "MedSigLIP needs matching label, prompt, and tokenizer ID lines."
                )
            }
            let tokenised = zip(zip(labels, prompts), tokenRows).map { pair, ids in
                MedSigLIPClassifier.TokenisedPrompt(label: pair.0, text: pair.1, tokenIDs: ids)
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
            guard !job.classifierBinaryPath.isEmpty else {
                throw ClassificationError.modelUnavailable("Cohort subprocess classifier needs a script path.")
            }
            if job.runClassifierOnDGX {
                let cfg = DGXSparkConfig.load()
                guard cfg.isConfigured else {
                    throw ClassificationError.modelUnavailable(
                        "Remote workstation not configured. Settings -> Remote Workstation."
                    )
                }
                let remoteSpec = RemoteLesionClassifier.Spec(
                    dgx: cfg,
                    remoteScriptPath: job.classifierBinaryPath,
                    activationCommand: job.classifierEnvironment
                        .split(separator: "\n")
                        .first { $0.hasPrefix("activate=") }
                        .map { String($0.dropFirst("activate=".count)) } ?? ""
                )
                return RemoteLesionClassifier(
                    id: entry.id,
                    displayName: "\(entry.displayName) · remote",
                    spec: remoteSpec,
                    supportedModalities: entry.modality.map { [$0] } ?? [],
                    supportedBodyRegions: [entry.bodyRegion]
                )
            }
            var envDict: [String: String] = [:]
            for line in job.classifierEnvironment.split(separator: "\n") {
                let pieces = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if pieces.count == 2 { envDict[pieces[0]] = pieces[1] }
            }
            let spec = SubprocessLesionClassifier.Spec(
                executablePath: (job.classifierBinaryPath as NSString).expandingTildeInPath,
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
            guard !job.classifierBinaryPath.isEmpty, !job.classifierModelPath.isEmpty else {
                throw ClassificationError.modelUnavailable(
                    "Cohort MedGemma classifier needs both a binary and a GGUF model path."
                )
            }
            let spec = MedGemmaClassifier.Spec(
                binaryPath: (job.classifierBinaryPath as NSString).expandingTildeInPath,
                modelPath: (job.classifierModelPath as NSString).expandingTildeInPath,
                projectorPath: job.classifierProjectorPath.isEmpty
                    ? nil
                    : (job.classifierProjectorPath as NSString).expandingTildeInPath,
                candidateLabels: splitLines(job.candidateLabels)
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

    // MARK: - Helpers

    private static func splitLines(_ raw: String) -> [String] {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseTokenIDs(_ raw: String) throws -> [[Int32]] {
        try raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let pieces = line.split { $0 == "," || $0 == " " || $0 == "\t" }
                guard !pieces.isEmpty else {
                    throw ClassificationError.modelUnavailable("MedSigLIP token line empty.")
                }
                return try pieces.map { piece in
                    guard let v = Int32(String(piece)) else {
                        throw ClassificationError.modelUnavailable("Invalid MedSigLIP token ID: \(piece)")
                    }
                    return v
                }
            }
    }
}
