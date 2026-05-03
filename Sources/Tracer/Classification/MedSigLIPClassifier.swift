import Foundation
import CoreGraphics
#if canImport(CoreML)
import CoreML
#endif

/// Zero-shot lesion classifier built on a CLIP-style medical vision-language
/// model. Designed for **MedSigLIP-compatible** image/text encoders, and
/// works with any `.mlpackage` that exposes a
/// vision-encoder and a text-encoder outputting unit-normalised embeddings.
///
/// How it works:
///   1. Extract the lesion's largest-area axial slice.
///   2. Resize to the model's expected input size (typically 224×224 or
///      384×384), applying the same standardisation the pre-training used.
///   3. Encode the slice → image embedding.
///   4. Pre-compute text embeddings for each class prompt (one-off; cached).
///   5. Cosine similarity × learned temperature → softmax over prompts.
///
/// Users supply text prompts like:
///   `["a CT slice of a benign liver hemangioma",
///     "a CT slice of hepatocellular carcinoma",
///     "a CT slice of a hepatic metastasis"]`
/// …so "classes" are effectively arbitrary — the flexibility is the
/// whole point of a zero-shot classifier.
///
/// Licensing note: model/provider terms apply. Use only for decision-support,
/// not diagnosis.
public final class MedSigLIPClassifier: LesionClassifier, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let supportedModalities: [Modality]
    public let supportedBodyRegions: [String]
    public let provenance: String

    public struct Spec: Sendable {
        /// Path to the image-encoder `.mlpackage`. Expected I/O:
        ///   • input  (float32, shape `(1, 3, H, W)`) — RGB image
        ///   • output (float32, shape `(1, E)`)       — L2-normalised embedding
        public var imageEncoderURL: URL
        /// Path to the text-encoder `.mlpackage`. Expected I/O:
        ///   • input  (int32, shape `(1, T)`)  — tokenised prompt
        ///   • output (float32, shape `(1, E)`) — L2-normalised embedding
        public var textEncoderURL: URL
        /// Input image size the encoder expects. MedSigLIP-base is 224;
        /// MedSigLIP-large is 384.
        public var imageSize: Int
        /// Pre-tokenised prompts, one per class. Tokenisation lives outside
        /// this runner (use `coremltools`' tokenizer during model conversion
        /// or ship a pre-built tokenised prompt table).
        public var tokenisedPrompts: [TokenisedPrompt]
        /// Learned temperature (scale) used by the model to sharpen cosine
        /// similarities. SigLIP defaults to about `log(10)`. Passing 1.0
        /// effectively disables temperature scaling.
        public var logitScale: Double
        /// Image input feature name, e.g. `"pixel_values"` or `"image"`.
        public var imageInputName: String
        public var imageOutputName: String
        public var textInputName: String
        public var textOutputName: String

        public init(imageEncoderURL: URL,
                    textEncoderURL: URL,
                    imageSize: Int,
                    tokenisedPrompts: [TokenisedPrompt],
                    logitScale: Double = log(10),
                    imageInputName: String = "image",
                    imageOutputName: String = "image_features",
                    textInputName: String = "input_ids",
                    textOutputName: String = "text_features") {
            self.imageEncoderURL = imageEncoderURL
            self.textEncoderURL = textEncoderURL
            self.imageSize = imageSize
            self.tokenisedPrompts = tokenisedPrompts
            self.logitScale = logitScale
            self.imageInputName = imageInputName
            self.imageOutputName = imageOutputName
            self.textInputName = textInputName
            self.textOutputName = textOutputName
        }
    }

    /// One prompt with its class label + pre-tokenised id sequence.
    public struct TokenisedPrompt: Sendable {
        public let label: String
        public let text: String
        public let tokenIDs: [Int32]

        public init(label: String, text: String, tokenIDs: [Int32]) {
            self.label = label
            self.text = text
            self.tokenIDs = tokenIDs
        }
    }

    private let spec: Spec
    /// Cached text embeddings, computed on first use and reused across every
    /// subsequent `classify(...)` call. MedSigLIP encodes text once per
    /// prompt — no reason to redo it per lesion.
    private var cachedTextEmbeddings: [[Double]]?

    public init(id: String,
                displayName: String,
                spec: Spec,
                supportedModalities: [Modality] = [],
                supportedBodyRegions: [String] = [],
                provenance: String = "MedSigLIP-compatible local runner, research intent") {
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
        #if canImport(CoreML)
        guard !spec.tokenisedPrompts.isEmpty else {
            throw ClassificationError.modelLoadFailed("no tokenised prompts supplied")
        }

        let start = Date()
        let config = MLModelConfiguration()
        config.computeUnits = .all

        // 1. Build the 2D RGB slice input.
        let sliceImage = try Self.makeRGBSlice(
            volume: volume,
            mask: mask,
            classID: classID,
            bounds: bounds,
            side: spec.imageSize
        )

        // 2. Load encoders + score the image.
        let imageEncoder: MLModel
        let textEncoder: MLModel
        do {
            imageEncoder = try MLModel(contentsOf: spec.imageEncoderURL, configuration: config)
            textEncoder = try MLModel(contentsOf: spec.textEncoderURL, configuration: config)
        } catch {
            throw ClassificationError.modelLoadFailed("\(error)")
        }

        let imageEmbedding = try await Self.encodeImage(
            imageEncoder, image: sliceImage, spec: spec
        )

        // 3. Cache text embeddings on first use.
        if cachedTextEmbeddings == nil {
            var list: [[Double]] = []
            list.reserveCapacity(spec.tokenisedPrompts.count)
            for prompt in spec.tokenisedPrompts {
                let emb = try await Self.encodeText(
                    textEncoder, tokenIDs: prompt.tokenIDs, spec: spec
                )
                list.append(emb)
            }
            cachedTextEmbeddings = list
        }
        guard let textEmbeddings = cachedTextEmbeddings else {
            throw ClassificationError.inferenceFailed("text cache could not be built")
        }

        // 4. Cosine similarity (L2-normalised vectors already) × logitScale,
        //    then softmax → class probabilities.
        let scale = spec.logitScale
        var logits: [Double] = []
        logits.reserveCapacity(textEmbeddings.count)
        for t in textEmbeddings {
            let dot = zip(imageEmbedding, t).reduce(0) { $0 + $1.0 * $1.1 }
            logits.append(dot * scale)
        }
        let probs = Self.softmax(logits)

        let predictions = zip(spec.tokenisedPrompts, probs).map { prompt, p in
            LabelPrediction(label: prompt.label, probability: p)
        }

        // Pick the winning prompt's text as the rationale. Zero-shot models
        // don't have real chain-of-thought — this is the closest thing.
        let rationale: String? = predictions.max(by: { $0.probability < $1.probability })
            .flatMap { best in
                spec.tokenisedPrompts.first { $0.label == best.label }?.text
            }

        return ClassificationResult(
            predictions: predictions,
            rationale: rationale,
            features: [:],
            durationSeconds: Date().timeIntervalSince(start),
            classifierID: id
        )
        #else
        throw ClassificationError.modelUnavailable("CoreML is unavailable on this platform")
        #endif
    }

    // MARK: - Slice + tensor plumbing

    /// Pick the axial slice with the most in-mask voxels, crop to the
    /// lesion bounding box, pad to square, then resize to `side` and
    /// promote to RGB by copying the grayscale channel three times.
    static func makeRGBSlice(volume: ImageVolume,
                             mask: LabelMap,
                             classID: UInt16,
                             bounds: MONAITransforms.VoxelBounds,
                             side: Int) throws -> [Float] {
        // Find the "best" axial slice inside bounds.
        var bestZ = bounds.minZ
        var bestCount = 0
        let w = volume.width, h = volume.height
        for z in bounds.minZ...bounds.maxZ {
            var count = 0
            for y in bounds.minY...bounds.maxY {
                let rowStart = z * h * w + y * w
                for x in bounds.minX...bounds.maxX {
                    if mask.voxels[rowStart + x] == classID { count += 1 }
                }
            }
            if count > bestCount { bestCount = count; bestZ = z }
        }
        guard bestCount > 0 else { throw ClassificationError.emptyLesion }

        let srcW = bounds.maxX - bounds.minX + 1
        let srcH = bounds.maxY - bounds.minY + 1
        var gray = [Float](repeating: 0, count: srcW * srcH)
        for y in 0..<srcH {
            let rowStart = bestZ * h * w + (y + bounds.minY) * w + bounds.minX
            for x in 0..<srcW {
                gray[y * srcW + x] = volume.pixels[rowStart + x]
            }
        }
        let normalized = Self.normalise0to1(gray)
        let resized = Self.bilinearResize(
            values: normalized, srcWidth: srcW, srcHeight: srcH, side: side
        )

        // RGB layout `(3, H, W)` — triple-copy the gray channel.
        var rgb = [Float](repeating: 0, count: 3 * side * side)
        for i in 0..<(side * side) {
            let v = resized[i]
            rgb[i] = v
            rgb[side * side + i] = v
            rgb[2 * side * side + i] = v
        }
        return rgb
    }

    #if canImport(CoreML)
    private static func encodeImage(_ model: MLModel,
                                    image: [Float],
                                    spec: Spec) async throws -> [Double] {
        let side = spec.imageSize
        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
            dataType: .float32
        )
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(array.dataPointer))
        for i in 0..<image.count { ptr[i] = image[i] }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            spec.imageInputName: MLFeatureValue(multiArray: array)
        ])
        let out: MLFeatureProvider
        do {
            out = try await model.prediction(from: provider)
        } catch {
            throw ClassificationError.inferenceFailed("image encode: \(error)")
        }
        return try readEmbedding(provider: out, featureName: spec.imageOutputName)
    }

    private static func encodeText(_ model: MLModel,
                                   tokenIDs: [Int32],
                                   spec: Spec) async throws -> [Double] {
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: tokenIDs.count)],
            dataType: .int32
        )
        let ptr = UnsafeMutablePointer<Int32>(OpaquePointer(array.dataPointer))
        for (i, id) in tokenIDs.enumerated() { ptr[i] = id }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            spec.textInputName: MLFeatureValue(multiArray: array)
        ])
        let out: MLFeatureProvider
        do {
            out = try await model.prediction(from: provider)
        } catch {
            throw ClassificationError.inferenceFailed("text encode: \(error)")
        }
        return try readEmbedding(provider: out, featureName: spec.textOutputName)
    }

    private static func readEmbedding(provider: MLFeatureProvider,
                                      featureName: String) throws -> [Double] {
        guard let array = provider.featureValue(for: featureName)?.multiArrayValue else {
            throw ClassificationError.unsupportedOutputShape("no output \"\(featureName)\"")
        }
        let count = array.count
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(array.dataPointer))
        var embedding = [Double](repeating: 0, count: count)
        for i in 0..<count { embedding[i] = Double(ptr[i]) }

        // Re-normalise defensively — some encoders emit unnormalised outputs.
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        if norm > 1e-9 {
            for i in 0..<count { embedding[i] /= norm }
        }
        return embedding
    }
    #endif

    // MARK: - Static image helpers

    private static func normalise0to1(_ values: [Float]) -> [Float] {
        guard let minV = values.min(), let maxV = values.max(), maxV > minV else {
            return values
        }
        let range = maxV - minV
        return values.map { ($0 - minV) / range }
    }

    private static func bilinearResize(values: [Float],
                                       srcWidth sw: Int, srcHeight sh: Int,
                                       side: Int) -> [Float] {
        var out = [Float](repeating: 0, count: side * side)
        guard sw > 0, sh > 0 else { return out }
        for dy in 0..<side {
            let sy = Double(dy) * Double(sh - 1) / Double(max(1, side - 1))
            let y0 = Int(sy.rounded(.down))
            let y1 = min(sh - 1, y0 + 1)
            let ty = Float(sy - Double(y0))
            for dx in 0..<side {
                let sx = Double(dx) * Double(sw - 1) / Double(max(1, side - 1))
                let x0 = Int(sx.rounded(.down))
                let x1 = min(sw - 1, x0 + 1)
                let tx = Float(sx - Double(x0))
                let v00 = values[y0 * sw + x0]
                let v01 = values[y0 * sw + x1]
                let v10 = values[y1 * sw + x0]
                let v11 = values[y1 * sw + x1]
                let v0 = v00 * (1 - tx) + v01 * tx
                let v1 = v10 * (1 - tx) + v11 * tx
                out[dy * side + dx] = v0 * (1 - ty) + v1 * ty
            }
        }
        return out
    }

    private static func softmax(_ logits: [Double]) -> [Double] {
        guard !logits.isEmpty else { return [] }
        let maxL = logits.max() ?? 0
        let exps = logits.map { exp($0 - maxL) }
        let denom = max(exps.reduce(0, +), 1e-12)
        return exps.map { $0 / denom }
    }
}
