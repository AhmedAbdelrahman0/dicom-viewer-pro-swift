import Foundation
#if canImport(CoreML)
import CoreML
#endif

/// Generic CoreML runner for any `.mlpackage` / `.mlmodelc` that expects a
/// single 3D lesion crop and returns a class-probability vector. Follows
/// the same design as `NNUnetCoreMLRunner.ModelSpec` — users point at a
/// model file, declare the input/output feature names, patch size, and
/// the list of class labels, and the runner does the rest.
///
/// Expected model I/O:
///   • input  (float32, shape `(1, 1, D, H, W)`): cropped-and-resampled VOI
///   • output (float32, shape `(1, C)` or `(C,)`):  per-class logits / probs
///
/// If the output is raw logits (common for PyTorch-exported models), set
/// `applySoftmax = true`; if it's already a softmax, set it false. The
/// runner performs the softmax itself when asked.
public final class CoreMLLesionClassifier: LesionClassifier, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let supportedModalities: [Modality]
    public let supportedBodyRegions: [String]
    public let provenance: String

    public struct Spec: Sendable {
        public var modelURL: URL
        public var inputName: String
        public var outputName: String
        /// Target patch size the model expects (depth, height, width).
        public var patchSize: (d: Int, h: Int, w: Int)
        /// Ordered class labels — `output[i]` maps to `classes[i]`.
        public var classes: [String]
        /// If `true`, apply softmax to the model's output. If `false`, treat
        /// the output as already-normalized probabilities.
        public var applySoftmax: Bool
        /// Intensity preprocessing to apply before inference. Reuses the
        /// `NNUnetCatalog.IntensityPreprocessing` machinery so CT / MR / PET
        /// normalization matches what the trainer used.
        public var preprocessing: NNUnetCatalog.IntensityPreprocessing

        public init(modelURL: URL,
                    classes: [String],
                    patchSize: (d: Int, h: Int, w: Int) = (d: 32, h: 64, w: 64),
                    inputName: String = "input",
                    outputName: String = "probs",
                    applySoftmax: Bool = true,
                    preprocessing: NNUnetCatalog.IntensityPreprocessing = .zScoreNonzero) {
            self.modelURL = modelURL
            self.classes = classes
            self.patchSize = patchSize
            self.inputName = inputName
            self.outputName = outputName
            self.applySoftmax = applySoftmax
            self.preprocessing = preprocessing
        }
    }

    private let spec: Spec

    public init(id: String,
                displayName: String,
                spec: Spec,
                supportedModalities: [Modality] = [],
                supportedBodyRegions: [String] = [],
                provenance: String = "") {
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
        guard bounds.width > 0, bounds.height > 0, bounds.depth > 0 else {
            throw ClassificationError.emptyLesion
        }

        let start = Date()
        // 1. Crop the VOI to the lesion bounding box.
        let crop = MONAITransforms.crop(volume, to: bounds)

        // 2. Apply the intensity preprocessing the trainer used. Reuse the
        //    NNUnet machinery so CT/MR/PET normalization is consistent.
        let preprocessedPixels = NNUnetCoreMLRunner.applyPreprocessing(
            pixels: crop.pixels,
            suvScaleFactor: volume.suvScaleFactor,
            preprocessing: spec.preprocessing
        )
        let preprocessedVolume = ImageVolume(
            pixels: preprocessedPixels,
            depth: crop.depth, height: crop.height, width: crop.width,
            spacing: crop.spacing, origin: crop.origin, direction: crop.direction,
            modality: crop.modality
        )

        // 3. Resample to the model's expected patch size.
        let targetSpacing = (
            x: Double(crop.width)  * crop.spacing.x / Double(spec.patchSize.w),
            y: Double(crop.height) * crop.spacing.y / Double(spec.patchSize.h),
            z: Double(crop.depth)  * crop.spacing.z / Double(spec.patchSize.d)
        )
        let resampled = MONAITransforms.resample(preprocessedVolume, to: targetSpacing)

        // 4. Build the CoreML input tensor.
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model: MLModel
        do {
            model = try MLModel(contentsOf: spec.modelURL, configuration: config)
        } catch {
            throw ClassificationError.modelLoadFailed("\(error)")
        }

        let array = try MLMultiArray(shape: [
            1, 1,
            NSNumber(value: spec.patchSize.d),
            NSNumber(value: spec.patchSize.h),
            NSNumber(value: spec.patchSize.w)
        ], dataType: .float32)
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(array.dataPointer))
        // Copy voxels into the tensor. We fall back to zero when the
        // resample undershoots by one voxel on any axis.
        for z in 0..<spec.patchSize.d {
            for y in 0..<spec.patchSize.h {
                for x in 0..<spec.patchSize.w {
                    let idx = z * array.strides[2].intValue
                            + y * array.strides[3].intValue
                            + x * array.strides[4].intValue
                    let inBounds = z < resampled.depth
                                && y < resampled.height
                                && x < resampled.width
                    let value: Float = inBounds
                        ? resampled.pixels[z * resampled.height * resampled.width
                                           + y * resampled.width
                                           + x]
                        : 0
                    ptr[idx] = value
                }
            }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            spec.inputName: MLFeatureValue(multiArray: array)
        ])

        // 5. Run prediction and read out the logits / probs.
        let prediction: MLFeatureProvider
        do {
            prediction = try await model.prediction(from: provider)
        } catch {
            throw ClassificationError.inferenceFailed("\(error)")
        }
        guard let raw = prediction.featureValue(for: spec.outputName)?.multiArrayValue else {
            throw ClassificationError.unsupportedOutputShape(
                "missing output feature \"\(spec.outputName)\""
            )
        }
        let count = raw.count
        guard count == spec.classes.count else {
            throw ClassificationError.unsupportedOutputShape(
                "output has \(count) elements, expected \(spec.classes.count)"
            )
        }

        let outPtr = UnsafeMutablePointer<Float32>(OpaquePointer(raw.dataPointer))
        var probs = (0..<count).map { Double(outPtr[$0]) }
        if spec.applySoftmax {
            probs = Self.softmax(probs)
        } else {
            let sum = probs.reduce(0, +)
            if abs(sum - 1) > 1e-3 {
                // Treat "not-a-simplex" outputs as logits anyway — safer than
                // returning nonsense probabilities.
                probs = Self.softmax(probs)
            }
        }

        let predictions = zip(spec.classes, probs).map {
            LabelPrediction(label: $0.0, probability: $0.1)
        }
        return ClassificationResult(
            predictions: predictions,
            rationale: nil,
            features: [:],
            durationSeconds: Date().timeIntervalSince(start),
            classifierID: id
        )
        #else
        throw ClassificationError.modelUnavailable(
            "CoreML is unavailable on this platform"
        )
        #endif
    }

    private static func softmax(_ logits: [Double]) -> [Double] {
        guard !logits.isEmpty else { return [] }
        let maxL = logits.max() ?? 0
        let exps = logits.map { exp($0 - maxL) }
        let denom = max(exps.reduce(0, +), 1e-12)
        return exps.map { $0 / denom }
    }
}
