import Foundation
import SwiftUI
#if canImport(CoreML)
import CoreML
#endif

/// On-device nnU-Net inference via a pre-converted CoreML model.
///
/// **Why this exists:** if a user has a `.mlpackage` file (either authored
/// themselves or shipped alongside the app), we can run inference directly
/// on Apple Neural Engine / GPU without needing Python or network. This is
/// typically **faster** than the subprocess path and works fully offline
/// even without `nnunetv2` installed.
///
/// **How to produce a CoreML model from nnU-Net:**
/// 1. Train or download an nnU-Net v2 checkpoint.
/// 2. Export the backbone to ONNX via `torch.onnx.export(...)`.
/// 3. Convert ONNX → CoreML with [coremltools]:
///    ```
///    import coremltools as ct
///    ct.converters.onnx.convert("model.onnx",
///                               minimum_ios_deployment_target="16")
///    ```
/// 4. Save as `.mlpackage` and point this runner at its URL.
///
/// The runner uses `MONAITransforms.slidingPatches` to tile volumes larger
/// than the model's input patch size, runs per-patch inference, blends
/// overlapping predictions with a Gaussian window, and argmaxes the
/// accumulated logits to produce the final class-id mask.
public final class NNUnetCoreMLRunner: @unchecked Sendable {

    public struct ModelSpec: Sendable {
        public var modelURL: URL
        /// Expected patch size `(depth, height, width)` in voxels.
        public var patchSize: (d: Int, h: Int, w: Int)
        /// Number of output classes including background. The runner argmaxes
        /// over these to produce class ids in `[0, numClasses - 1]`.
        public var numClasses: Int
        /// Name of the CoreML input feature. Defaults to `"input"` — change
        /// to match whatever name your coremltools conversion chose.
        public var inputName: String
        /// Name of the CoreML output feature. Defaults to `"logits"`.
        public var outputName: String
        /// Sliding-window overlap fraction `[0, 1)`.
        public var overlap: Double
        /// Intensity normalization to apply before inference. Must match
        /// nnU-Net's training-time preprocessing or predictions will be noise.
        public var preprocessing: NNUnetCatalog.IntensityPreprocessing

        public init(modelURL: URL,
                    patchSize: (d: Int, h: Int, w: Int),
                    numClasses: Int,
                    inputName: String = "input",
                    outputName: String = "logits",
                    overlap: Double = 0.25,
                    preprocessing: NNUnetCatalog.IntensityPreprocessing = .zScoreNonzero) {
            self.modelURL = modelURL
            self.patchSize = patchSize
            self.numClasses = numClasses
            self.inputName = inputName
            self.outputName = outputName
            self.overlap = overlap
            self.preprocessing = preprocessing
        }

        /// Build a `ModelSpec` from a catalog entry + a `.mlpackage` URL.
        /// Uses the entry's published preprocessing + CoreML preset so callers
        /// don't have to know the patch size or channel count.
        public static func fromCatalog(_ entry: NNUnetCatalog.Entry,
                                       modelURL: URL) -> ModelSpec {
            ModelSpec(
                modelURL: modelURL,
                patchSize: entry.coreML.patchSize,
                numClasses: entry.coreML.numClasses,
                inputName: entry.coreML.inputName,
                outputName: entry.coreML.outputName,
                overlap: entry.coreML.overlap,
                preprocessing: entry.preprocessing
            )
        }
    }

    public enum RunError: Error, LocalizedError {
        case coreMLUnavailable
        case modelLoadFailed(String)
        case inferenceFailed(String)
        case unsupportedOutputShape(String)

        public var errorDescription: String? {
            switch self {
            case .coreMLUnavailable:
                return "CoreML is unavailable on this platform; use the subprocess runner instead."
            case .modelLoadFailed(let m): return "Failed to load CoreML model: \(m)"
            case .inferenceFailed(let m): return "CoreML inference failed: \(m)"
            case .unsupportedOutputShape(let s): return "Unexpected output shape from CoreML model: \(s)"
            }
        }
    }

    public struct Result {
        public let labelMap: LabelMap
        public let durationSeconds: TimeInterval
        public let patchCount: Int
    }

    public init() {}

    /// Run segmentation on `volume` and produce a `LabelMap` matching the
    /// volume's grid. Class names come from the `classes` dictionary
    /// (e.g. taken from `NNUnetCatalog.Entry.classes`).
    ///
    /// Applies the `spec.preprocessing` intensity normalization internally so
    /// inputs match what nnU-Net saw during training. This is critical —
    /// without it the model sees a totally different distribution.
    public func runInference(volume: ImageVolume,
                             spec: ModelSpec,
                             classes: [UInt16: String] = [:]) async throws -> Result {
        #if canImport(CoreML)
        let started = Date()
        let config = MLModelConfiguration()
        config.computeUnits = .all

        let model: MLModel
        do {
            model = try MLModel(contentsOf: spec.modelURL, configuration: config)
        } catch {
            throw RunError.modelLoadFailed("\(error)")
        }

        // Preprocess intensities in a cheap working buffer (copy the volume's
        // pixel array only once, not per patch).
        let normalizedPixels = Self.applyPreprocessing(
            pixels: volume.pixels,
            suvScaleFactor: volume.suvScaleFactor,
            preprocessing: spec.preprocessing
        )

        let patches = MONAITransforms.slidingPatches(
            volumeWidth: volume.width,
            volumeHeight: volume.height,
            volumeDepth: volume.depth,
            patchSize: (w: spec.patchSize.w,
                        h: spec.patchSize.h,
                        d: spec.patchSize.d),
            overlap: spec.overlap
        )

        // Accumulators: logits per voxel per class + blend weights.
        let voxelCount = volume.width * volume.height * volume.depth
        var logits = [[Float]](repeating: [Float](repeating: 0, count: voxelCount),
                                count: spec.numClasses)
        var weights = [Float](repeating: 0, count: voxelCount)

        let gaussian = gaussianWindow(d: spec.patchSize.d,
                                      h: spec.patchSize.h,
                                      w: spec.patchSize.w)

        for bounds in patches {
            let input = try makeInput(pixels: normalizedPixels,
                                       volumeWidth: volume.width,
                                       volumeHeight: volume.height,
                                       volumeDepth: volume.depth,
                                       bounds: bounds, spec: spec)
            let prediction: MLFeatureProvider
            do {
                // CoreML adds an async overload on macOS 14+; the synchronous
                // entry point still exists and is preferable here because we
                // run these sequentially on our own task.
                prediction = try await model.prediction(from: input)
            } catch {
                throw RunError.inferenceFailed("\(error)")
            }
            guard let multi = prediction.featureValue(for: spec.outputName)?.multiArrayValue else {
                throw RunError.unsupportedOutputShape("output \"\(spec.outputName)\" is not a multi-array")
            }
            try accumulate(logits: &logits,
                           weights: &weights,
                           multiArray: multi,
                           gaussian: gaussian,
                           bounds: bounds,
                           volume: volume,
                           spec: spec)
        }

        let label = LabelMap(parentSeriesUID: volume.seriesUID,
                             depth: volume.depth,
                             height: volume.height,
                             width: volume.width,
                             name: "nnU-Net CoreML")
        var voxels = [UInt16](repeating: 0, count: voxelCount)
        for i in 0..<voxelCount where weights[i] > 0 {
            var bestIdx = 0
            var bestVal: Float = -.infinity
            for c in 0..<spec.numClasses {
                let v = logits[c][i] / max(weights[i], 1e-6)
                if v > bestVal {
                    bestVal = v
                    bestIdx = c
                }
            }
            voxels[i] = UInt16(bestIdx)
        }
        label.voxels = voxels

        // Populate class names.
        var seen = Set<UInt16>()
        for v in voxels where v != 0 { seen.insert(v) }
        for id in seen.sorted() {
            let name = classes[id] ?? "class_\(id)"
            label.classes.append(
                LabelClass(labelID: id, name: name, category: .custom,
                           color: paletteColor(index: Int(id)))
            )
        }

        return Result(labelMap: label,
                      durationSeconds: Date().timeIntervalSince(started),
                      patchCount: patches.count)
        #else
        throw RunError.coreMLUnavailable
        #endif
    }

    // MARK: - CoreML helpers

    #if canImport(CoreML)
    private func makeInput(pixels: [Float],
                           volumeWidth: Int,
                           volumeHeight: Int,
                           volumeDepth: Int,
                           bounds: MONAITransforms.VoxelBounds,
                           spec: ModelSpec) throws -> MLFeatureProvider {
        // Shape: (1, 1, D, H, W) float32 — the common nnU-Net 3D input layout.
        let shape: [NSNumber] = [1, 1,
                                  NSNumber(value: spec.patchSize.d),
                                  NSNumber(value: spec.patchSize.h),
                                  NSNumber(value: spec.patchSize.w)]
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        let stride = array.strides.map { $0.intValue }
        let pointer = UnsafeMutablePointer<Float32>(OpaquePointer(array.dataPointer))

        // Voxel-by-voxel copy from the already-preprocessed pixel buffer.
        for z in 0..<spec.patchSize.d {
            for y in 0..<spec.patchSize.h {
                for x in 0..<spec.patchSize.w {
                    let sz = bounds.minZ + z
                    let sy = bounds.minY + y
                    let sx = bounds.minX + x
                    let inside = sz < volumeDepth && sy < volumeHeight && sx < volumeWidth
                    let v: Float = inside
                        ? pixels[sz * volumeHeight * volumeWidth + sy * volumeWidth + sx]
                        : 0
                    let linear = z * stride[2] + y * stride[3] + x * stride[4]
                    pointer[linear] = v
                }
            }
        }

        return try MLDictionaryFeatureProvider(
            dictionary: [spec.inputName: MLFeatureValue(multiArray: array)]
        )
    }
    #endif

    /// Apply the intensity preprocessing specified by the catalog entry.
    /// Kept `internal` so tests can verify the normalization matches nnU-Net.
    static func applyPreprocessing(pixels: [Float],
                                    suvScaleFactor: Double?,
                                    preprocessing: NNUnetCatalog.IntensityPreprocessing) -> [Float] {
        switch preprocessing {
        case .identity:
            return pixels

        case .ctClipAndZScore(let lower, let upper, let mean, let std):
            let divisor = max(std, 1e-6)
            return pixels.map { raw in
                var v = raw
                if v < lower { v = lower }
                if v > upper { v = upper }
                return (v - mean) / divisor
            }

        case .zScoreNonzero:
            return MONAITransforms.normalizeIntensity(pixels, nonzero: true)

        case .petSUV(let cap):
            let scale = Float(suvScaleFactor ?? 1.0)
            var scaled = pixels.map { v -> Float in
                let s = v * scale
                return max(0, min(cap, s))
            }
            // Z-score over non-zero foreground.
            scaled = MONAITransforms.normalizeIntensity(scaled, nonzero: true)
            return scaled
        }
    }
    #if canImport(CoreML)

    private func accumulate(logits: inout [[Float]],
                            weights: inout [Float],
                            multiArray: MLMultiArray,
                            gaussian: [Float],
                            bounds: MONAITransforms.VoxelBounds,
                            volume: ImageVolume,
                            spec: ModelSpec) throws {
        // Expect shape (1, C, D, H, W).
        let dims = multiArray.shape.map { $0.intValue }
        guard dims.count == 5,
              dims[1] == spec.numClasses,
              dims[2] == spec.patchSize.d,
              dims[3] == spec.patchSize.h,
              dims[4] == spec.patchSize.w else {
            throw RunError.unsupportedOutputShape(
                "got \(dims), expected (1, \(spec.numClasses), \(spec.patchSize.d), \(spec.patchSize.h), \(spec.patchSize.w))"
            )
        }

        let strides = multiArray.strides.map { $0.intValue }
        let pointer = UnsafeMutablePointer<Float32>(OpaquePointer(multiArray.dataPointer))

        let H = volume.height, W = volume.width
        for z in 0..<spec.patchSize.d {
            let sz = bounds.minZ + z
            if sz < 0 || sz >= volume.depth { continue }
            for y in 0..<spec.patchSize.h {
                let sy = bounds.minY + y
                if sy < 0 || sy >= volume.height { continue }
                for x in 0..<spec.patchSize.w {
                    let sx = bounds.minX + x
                    if sx < 0 || sx >= volume.width { continue }
                    let outIndex = sz * H * W + sy * W + sx
                    let gidx = (z * spec.patchSize.h + y) * spec.patchSize.w + x
                    let wgt = gaussian[gidx]
                    weights[outIndex] += wgt
                    for c in 0..<spec.numClasses {
                        let src = c * strides[1] + z * strides[2] + y * strides[3] + x * strides[4]
                        logits[c][outIndex] += pointer[src] * wgt
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Gaussian blend window

    private func gaussianWindow(d: Int, h: Int, w: Int) -> [Float] {
        var out = [Float](repeating: 0, count: d * h * w)
        let sigmaD = Float(d) / 8 + 1
        let sigmaH = Float(h) / 8 + 1
        let sigmaW = Float(w) / 8 + 1
        let cz = Float(d - 1) * 0.5
        let cy = Float(h - 1) * 0.5
        let cx = Float(w - 1) * 0.5
        for z in 0..<d {
            for y in 0..<h {
                for x in 0..<w {
                    let dz = (Float(z) - cz) / sigmaD
                    let dy = (Float(y) - cy) / sigmaH
                    let dx = (Float(x) - cx) / sigmaW
                    out[(z * h + y) * w + x] = expf(-0.5 * (dz * dz + dy * dy + dx * dx))
                }
            }
        }
        return out
    }

    private func paletteColor(index: Int) -> Color {
        let palette: [(Int, Int, Int)] = [
            (255, 105,  97), (139,  69,  19), ( 95, 158, 160), (139,  26,  26),
            (218, 165,  32), (173, 216, 230), (255, 160, 122), (255, 215,   0),
            ( 50, 150, 220), (255,  99,  71), ( 64, 224, 208), (255,  20, 147),
        ]
        let (r, g, b) = palette[index % palette.count]
        return Color(r: r, g: g, b: b)
    }
}
