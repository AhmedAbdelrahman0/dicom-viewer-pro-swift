import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Multimodal classification via a **MedGemma-compatible** model running
/// locally through `llama.cpp` with GGUF-quantised
/// weights. Accepts a lesion image + an open-ended text prompt and
/// returns a structured list of class probabilities plus the model's
/// free-text rationale.
///
/// This gives Tracer a true "write me a differential diagnosis for this
/// lesion" path — the model's output is natural language, and we parse
/// the structured portion back into `ClassificationResult`.
///
/// ### Runtime requirements
/// The user must have `llama.cpp` installed (`llama-cli` binary or
/// `llama-mtmd-cli` for the multimodal variant) and the MedGemma weights
/// downloaded. Tracer itself doesn't bundle weights or the binary.
///
/// ### Prompt contract
/// We send a prompt like:
/// ```
/// The image is a {modality} slice of a suspected {region} lesion.
/// Classify the most likely diagnosis from this list:
///   - benign hemangioma
///   - hepatocellular carcinoma
///   - metastasis
///
/// Respond with a JSON object:
///   { "label": "<one label>", "confidence": <0..1>, "rationale": "<one sentence>" }
/// ```
///
/// The runner searches the model's output for the first `{ ... }` block,
/// tolerates leading/trailing text, and refuses to return a result if
/// the JSON is malformed.
///
/// Licensing: model/provider terms apply. Review before shipping in a
/// regulated setting.
public final class MedGemmaClassifier: LesionClassifier, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let supportedModalities: [Modality]
    public let supportedBodyRegions: [String]
    public let provenance: String

    public struct Spec: Sendable {
        /// Path to `llama-cli` / `llama-mtmd-cli` / similar.
        public var binaryPath: String
        /// Path to the MedGemma GGUF model file.
        public var modelPath: String
        /// Path to the vision-projector GGUF (mmproj), required by
        /// `llama-mtmd-cli` for multimodal prompts. Nil = text-only.
        public var projectorPath: String?
        /// Extra arguments appended to the binary invocation — e.g.
        /// `"-ngl"`, `"999"` to offload to Metal.
        public var extraArguments: [String]
        /// Possible diagnoses for the classifier to pick from. Order is
        /// meaningful — we reuse it as the canonical class list when the
        /// model's JSON response only includes the top label.
        public var candidateLabels: [String]
        /// Temperature for the sampling. 0.0 = deterministic. For
        /// classification we default to low temperature.
        public var temperature: Double
        public var timeoutSeconds: TimeInterval

        public init(binaryPath: String,
                    modelPath: String,
                    projectorPath: String? = nil,
                    extraArguments: [String] = ["-ngl", "999", "--jinja"],
                    candidateLabels: [String] = ["benign", "malignant"],
                    temperature: Double = 0.2,
                    timeoutSeconds: TimeInterval = 300) {
            self.binaryPath = binaryPath
            self.modelPath = modelPath
            self.projectorPath = projectorPath
            self.extraArguments = extraArguments
            self.candidateLabels = candidateLabels
            self.temperature = temperature
            self.timeoutSeconds = timeoutSeconds
        }
    }

    private let spec: Spec

    public init(id: String,
                displayName: String,
                spec: Spec,
                supportedModalities: [Modality] = [],
                supportedBodyRegions: [String] = [],
                provenance: String = "MedGemma-compatible local runner via llama.cpp") {
        self.id = id
        self.displayName = displayName
        self.spec = spec
        self.supportedModalities = supportedModalities
        self.supportedBodyRegions = supportedBodyRegions
        self.provenance = provenance
    }

    public func classify(volume: ImageVolume,
                         mask: LabelMap,
                         classID: UInt16,
                         bounds: MONAITransforms.VoxelBounds) async throws -> ClassificationResult {
        guard FileManager.default.isExecutableFile(atPath: spec.binaryPath) else {
            throw ClassificationError.modelUnavailable(
                "llama-cli binary missing at \(spec.binaryPath)"
            )
        }
        guard FileManager.default.fileExists(atPath: spec.modelPath) else {
            throw ClassificationError.modelUnavailable(
                "GGUF model missing at \(spec.modelPath)"
            )
        }

        let start = Date()

        // 1. Build a single PNG of the lesion's representative slice and
        //    ship it to llama-cli via the `-image` flag (multimodal mode).
        let sliceRGB = try MedSigLIPClassifier.makeRGBSlice(
            volume: volume, mask: mask,
            classID: classID, bounds: bounds,
            side: 512
        )
        let pngURL = try writePNGSlice(sliceRGB, side: 512)
        defer { try? FileManager.default.removeItem(at: pngURL) }

        // 2. Assemble the prompt.
        let prompt = Self.buildPrompt(
            modality: Modality.normalize(volume.modality).displayName,
            labels: spec.candidateLabels
        )

        // 3. Spawn llama-cli.
        var args: [String] = [
            "-m", spec.modelPath,
            "--temp", String(format: "%.3f", spec.temperature),
            "-p", prompt,
            "--image", pngURL.path,
            "-n", "256"
        ]
        if let proj = spec.projectorPath, !proj.isEmpty {
            args.append(contentsOf: ["--mmproj", proj])
        }
        args.append(contentsOf: spec.extraArguments)

        let result: WorkerProcessResult
        do {
            result = try await LocalWorkerProcess().run(WorkerProcessRequest(
                executablePath: spec.binaryPath,
                arguments: args,
                environment: ResourcePolicy.load().applyingSubprocessDefaults(to: ProcessInfo.processInfo.environment),
                timeoutSeconds: spec.timeoutSeconds,
                streamStdout: false,
                streamStderr: false
            ))
        } catch WorkerProcessError.timedOut(_, let stderr) {
            throw ClassificationError.inferenceFailed(
                "llama-cli timed out after \(Int(spec.timeoutSeconds))s\(stderr.isEmpty ? "" : ": \(stderr)")"
            )
        } catch WorkerProcessError.nonZeroExit(let exitCode, let stderr) {
            throw ClassificationError.inferenceFailed(
                "llama-cli exited \(exitCode): \(stderr)"
            )
        } catch {
            throw ClassificationError.inferenceFailed("launch failed: \(error)")
        }
        let raw = result.stdout

        // 4. Parse the JSON.
        let parsed = try Self.parseJSON(in: raw, expectedLabels: spec.candidateLabels)
        return ClassificationResult(
            predictions: parsed.predictions,
            rationale: parsed.rationale,
            features: [:],
            durationSeconds: Date().timeIntervalSince(start),
            classifierID: id
        )
    }

    // MARK: - Prompt / parsing

    private static func buildPrompt(modality: String, labels: [String]) -> String {
        let list = labels.map { "- \($0)" }.joined(separator: "\n")
        return """
        You are a radiology AI assistant. The attached image is a \(modality) slice showing a lesion. Classify the most likely diagnosis from:
        \(list)

        Respond with a single JSON object, no extra prose:
        {
          "label": "<one of the candidates>",
          "confidence": <0.0 to 1.0>,
          "rationale": "<one sentence explanation>"
        }
        """
    }

    struct Parsed {
        let predictions: [LabelPrediction]
        let rationale: String?
    }

    static func parseJSON(in raw: String,
                          expectedLabels: [String]) throws -> Parsed {
        // Find the first { ... } block. llama.cpp often emits extra prose
        // around the JSON even when asked not to.
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}") else {
            throw ClassificationError.inferenceFailed("no JSON in model output")
        }
        let jsonSlice = String(raw[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw ClassificationError.inferenceFailed("malformed JSON: \(jsonSlice)")
        }
        guard let topLabel = dict["label"] as? String else {
            throw ClassificationError.inferenceFailed("missing 'label' in output")
        }
        let confidence: Double
        if let v = dict["confidence"] as? Double {
            confidence = min(1, max(0, v))
        } else if let v = dict["confidence"] as? Int {
            confidence = min(1, max(0, Double(v)))
        } else {
            confidence = 0.5    // fallback if the model forgot to include it
        }

        // Distribute (1 - confidence) evenly across the remaining labels so
        // the result is always a proper distribution. Users who need
        // per-label probabilities should instruct MedGemma to emit a full
        // map — our parser accepts that too when the key is `"probabilities"`.
        if let all = dict["probabilities"] as? [String: Double] {
            let preds = all.map { LabelPrediction(label: $0.key, probability: $0.value) }
            return Parsed(predictions: preds, rationale: dict["rationale"] as? String)
        }

        let others = expectedLabels.filter { $0 != topLabel }
        let share = others.isEmpty ? 0 : (1 - confidence) / Double(others.count)
        var preds = [LabelPrediction(label: topLabel, probability: confidence)]
        for label in others {
            preds.append(LabelPrediction(label: label, probability: share))
        }
        return Parsed(predictions: preds, rationale: dict["rationale"] as? String)
    }

    // MARK: - PNG writer

    private func writePNGSlice(_ rgb: [Float], side: Int) throws -> URL {
        // rgb is `(3, side, side)`, float [0,1]. Convert to 8-bit
        // interleaved RGBA so we can go through CGImage / ImageIO.
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                let r = UInt8(max(0, min(255, rgb[i] * 255)))
                let g = UInt8(max(0, min(255, rgb[side * side + i] * 255)))
                let b = UInt8(max(0, min(255, rgb[2 * side * side + i] * 255)))
                let di = i * 4
                bytes[di] = r
                bytes[di + 1] = g
                bytes[di + 2] = b
                bytes[di + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let colorspace = CGColorSpaceCreateDeviceRGB()
        guard let cg = CGImage(
            width: side, height: side,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: colorspace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw ClassificationError.inferenceFailed("could not build CGImage for MedGemma slice")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("medgemma-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ClassificationError.inferenceFailed("could not create PNG destination")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ClassificationError.inferenceFailed("could not finalise PNG")
        }
        return url
    }
}
