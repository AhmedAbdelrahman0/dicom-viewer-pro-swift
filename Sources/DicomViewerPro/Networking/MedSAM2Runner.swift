import Foundation
import SwiftUI
#if canImport(CoreML)
import CoreML
#endif

/// Thin adapter for **MedSAM2** (Ma et al., *Nat Comms* 2024; MedSAM2 Apr
/// 2025) — a promptable foundation model for medical image segmentation.
/// Apache-2.0 license (medsam2.github.io, bowang-lab/MedSAM2).
///
/// MedSAM2 takes a 2D slice + a bounding box prompt and returns a refined
/// segmentation mask for whatever anatomy or lesion sits inside the box.
/// It's the ideal companion to a full-volume nnU-Net run: catch a missed
/// lesion with a single click-and-drag, or tighten up a sloppy contour.
///
/// This runner is structured so callers don't need to know MedSAM's
/// image-encoder / prompt-encoder / mask-decoder internals — they hand in
/// a slice and a box, and get a refined mask back.
///
/// Usage:
/// ```
/// let runner = MedSAM2Runner()
/// let spec = MedSAM2Runner.Spec(
///     modelURL: URL(fileURLWithPath: "~/Models/MedSAM2.mlpackage"),
///     targetSize: 256
/// )
/// let refined = try await runner.refineLesion(
///     volume: pet,
///     axis: 2, sliceIndex: 120,
///     box: CGRect(x: 120, y: 140, width: 60, height: 60),
///     into: labelMap, classID: activeClassID, spec: spec
/// )
/// ```
///
/// Deliberately kept narrow in scope: no encoder-prompt-caching, no
/// multi-slice propagation, no interactive click-refine loop yet. Those
/// come next (LesionLocator-style) once we have weights in hand.
public final class MedSAM2Runner: @unchecked Sendable {

    public struct Spec: Sendable {
        public var modelURL: URL
        /// Square input size MedSAM expects (typically 256 for MedSAM2
        /// 3D-base, 1024 for MedSAM1). The slice is resized to this.
        public var targetSize: Int
        /// Name of the CoreML input feature holding the image tensor.
        public var imageInputName: String
        /// Name of the CoreML input feature holding the box prompt
        /// (`[1, 4]` in xmin, ymin, xmax, ymax order, normalized to
        /// `[0, targetSize]`).
        public var boxInputName: String
        /// Name of the CoreML output feature holding the predicted mask.
        public var outputName: String

        public init(modelURL: URL,
                    targetSize: Int = 256,
                    imageInputName: String = "image",
                    boxInputName: String = "box",
                    outputName: String = "mask") {
            self.modelURL = modelURL
            self.targetSize = targetSize
            self.imageInputName = imageInputName
            self.boxInputName = boxInputName
            self.outputName = outputName
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case coreMLUnavailable
        case modelLoadFailed(String)
        case unsupportedShape(String)
        case sliceOutOfBounds(axis: Int, index: Int)
        case invalidBox(String)

        public var errorDescription: String? {
            switch self {
            case .coreMLUnavailable: return "CoreML is unavailable on this platform."
            case .modelLoadFailed(let m): return "MedSAM2 model load failed: \(m)"
            case .unsupportedShape(let m): return "MedSAM2 returned unexpected shape: \(m)"
            case .sliceOutOfBounds(let a, let i): return "Slice index \(i) out of bounds for axis \(a)."
            case .invalidBox(let m): return "Invalid box prompt: \(m)"
            }
        }
    }

    public struct Result {
        public let voxelsChanged: Int
        public let sliceBounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)
    }

    public init() {}

    /// Refine the label map on a single slice around the user's bounding
    /// box. `box` is in the slice's pixel coordinates (not normalized).
    ///
    /// Paints the returned mask into `labelMap` under `classID`. Mutating
    /// only the voxels on the given slice keeps the action local and
    /// undo-friendly.
    @discardableResult
    public func refineLesion(volume: ImageVolume,
                             axis: Int,
                             sliceIndex: Int,
                             box: CGRect,
                             into labelMap: LabelMap,
                             classID: UInt16,
                             spec: Spec) async throws -> Result {
        #if canImport(CoreML)
        try ensureSliceInBounds(volume: volume, axis: axis, index: sliceIndex)
        try validateBox(box, slice: sliceDimensions(volume: volume, axis: axis))

        let modelConfig = MLModelConfiguration()
        modelConfig.computeUnits = .all
        let model: MLModel
        do {
            model = try MLModel(contentsOf: spec.modelURL, configuration: modelConfig)
        } catch {
            throw Error.modelLoadFailed("\(error)")
        }

        // 1. Extract + resize the slice to (spec.targetSize × targetSize).
        let sliceBuf = extractSlice(volume: volume, axis: axis, sliceIndex: sliceIndex)
        let resized = resize(buffer: sliceBuf.values,
                             fromWidth: sliceBuf.width,
                             fromHeight: sliceBuf.height,
                             toSize: spec.targetSize)

        // 2. Build CoreML inputs.
        let imageArray = try MLMultiArray(shape: [1, 1,
                                                  NSNumber(value: spec.targetSize),
                                                  NSNumber(value: spec.targetSize)],
                                          dataType: .float32)
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(imageArray.dataPointer))
        for i in 0..<resized.count { ptr[i] = resized[i] }

        let boxArray = try MLMultiArray(shape: [1, 4], dataType: .float32)
        let bptr = UnsafeMutablePointer<Float32>(OpaquePointer(boxArray.dataPointer))
        let scaleX = Float(spec.targetSize) / Float(sliceBuf.width)
        let scaleY = Float(spec.targetSize) / Float(sliceBuf.height)
        bptr[0] = Float(box.minX) * scaleX
        bptr[1] = Float(box.minY) * scaleY
        bptr[2] = Float(box.maxX) * scaleX
        bptr[3] = Float(box.maxY) * scaleY

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            spec.imageInputName: MLFeatureValue(multiArray: imageArray),
            spec.boxInputName:   MLFeatureValue(multiArray: boxArray)
        ])

        // 3. Run inference.
        let prediction: MLFeatureProvider
        do {
            prediction = try await model.prediction(from: provider)
        } catch {
            throw Error.modelLoadFailed("prediction: \(error)")
        }
        guard let raw = prediction.featureValue(for: spec.outputName)?.multiArrayValue else {
            throw Error.unsupportedShape("no multi-array at \"\(spec.outputName)\"")
        }
        let rawMask = Self.flattenMask(raw, targetSize: spec.targetSize)

        // 4. Resize the predicted mask back to the slice's native resolution
        //    and thread it into the label map. Threshold at 0.5 (sigmoid
        //    output); for "pre-sigmoid logits" outputs, callers should wrap
        //    a sigmoid closure — left as an extension point.
        let resizedMask = resize(buffer: rawMask,
                                 fromWidth: spec.targetSize,
                                 fromHeight: spec.targetSize,
                                 toSize: max(sliceBuf.width, sliceBuf.height))
        return paint(mask: resizedMask,
                     maskSize: max(sliceBuf.width, sliceBuf.height),
                     sliceWidth: sliceBuf.width,
                     sliceHeight: sliceBuf.height,
                     axis: axis,
                     sliceIndex: sliceIndex,
                     labelMap: labelMap,
                     classID: classID)
        #else
        throw Error.coreMLUnavailable
        #endif
    }

    // MARK: - Slice / mask plumbing

    private struct SliceBuffer {
        let values: [Float]
        let width: Int
        let height: Int
    }

    private func sliceDimensions(volume: ImageVolume, axis: Int) -> (w: Int, h: Int) {
        switch axis {
        case 0: return (volume.height, volume.depth)
        case 1: return (volume.width, volume.depth)
        default: return (volume.width, volume.height)
        }
    }

    private func extractSlice(volume: ImageVolume,
                              axis: Int,
                              sliceIndex: Int) -> SliceBuffer {
        switch axis {
        case 0:
            let x = sliceIndex
            var out = [Float](repeating: 0, count: volume.depth * volume.height)
            for z in 0..<volume.depth {
                for y in 0..<volume.height {
                    out[z * volume.height + y] =
                        volume.pixels[z * volume.height * volume.width + y * volume.width + x]
                }
            }
            return SliceBuffer(values: out, width: volume.height, height: volume.depth)
        case 1:
            let y = sliceIndex
            var out = [Float](repeating: 0, count: volume.depth * volume.width)
            for z in 0..<volume.depth {
                let rowStart = z * volume.height * volume.width + y * volume.width
                for x in 0..<volume.width {
                    out[z * volume.width + x] = volume.pixels[rowStart + x]
                }
            }
            return SliceBuffer(values: out, width: volume.width, height: volume.depth)
        default:
            let z = sliceIndex
            let start = z * volume.height * volume.width
            let end = start + volume.height * volume.width
            return SliceBuffer(
                values: Array(volume.pixels[start..<end]),
                width: volume.width,
                height: volume.height
            )
        }
    }

    /// Nearest-neighbour resize — purpose-built, not a general bilinear.
    /// MedSAM uses a square input so the output is square too; we downsize
    /// back to the slice's native aspect using two-pass linear scaling.
    private func resize(buffer: [Float],
                        fromWidth sw: Int,
                        fromHeight sh: Int,
                        toSize dst: Int) -> [Float] {
        var out = [Float](repeating: 0, count: dst * dst)
        guard sw > 0, sh > 0 else { return out }
        for y in 0..<dst {
            let sy = min(sh - 1, Int(Double(y) * Double(sh) / Double(dst)))
            for x in 0..<dst {
                let sx = min(sw - 1, Int(Double(x) * Double(sw) / Double(dst)))
                out[y * dst + x] = buffer[sy * sw + sx]
            }
        }
        return out
    }

    #if canImport(CoreML)
    private static func flattenMask(_ array: MLMultiArray, targetSize: Int) -> [Float] {
        let count = targetSize * targetSize
        var out = [Float](repeating: 0, count: count)
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(array.dataPointer))
        // Shape is typically (1, 1, H, W) or (1, H, W) — flatten the trailing 2D.
        for i in 0..<count {
            out[i] = ptr[i]
        }
        return out
    }
    #endif

    private func paint(mask: [Float],
                       maskSize: Int,
                       sliceWidth: Int,
                       sliceHeight: Int,
                       axis: Int,
                       sliceIndex: Int,
                       labelMap: LabelMap,
                       classID: UInt16) -> Result {
        var changed = 0
        var minX = sliceWidth, maxX = -1, minY = sliceHeight, maxY = -1

        for y in 0..<sliceHeight {
            // Map into the mask's resolution.
            let my = min(maskSize - 1, Int(Double(y) * Double(maskSize) / Double(sliceHeight)))
            for x in 0..<sliceWidth {
                let mx = min(maskSize - 1, Int(Double(x) * Double(maskSize) / Double(sliceWidth)))
                let v = mask[my * maskSize + mx]
                if v >= 0.5 {
                    writeVoxel(x: x, y: y, sliceIndex: sliceIndex,
                               axis: axis, value: classID, labelMap: labelMap)
                    changed += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        labelMap.objectWillChange.send()
        return Result(voxelsChanged: changed,
                      sliceBounds: (minX, maxX, minY, maxY))
    }

    private func writeVoxel(x: Int, y: Int, sliceIndex: Int, axis: Int,
                            value: UInt16, labelMap: LabelMap) {
        switch axis {
        case 0: labelMap.setValue(value, z: y, y: x, x: sliceIndex)
        case 1: labelMap.setValue(value, z: y, y: sliceIndex, x: x)
        default: labelMap.setValue(value, z: sliceIndex, y: y, x: x)
        }
    }

    private func ensureSliceInBounds(volume: ImageVolume,
                                     axis: Int,
                                     index: Int) throws {
        let extent: Int = {
            switch axis {
            case 0: return volume.width
            case 1: return volume.height
            default: return volume.depth
            }
        }()
        guard index >= 0, index < extent else {
            throw Error.sliceOutOfBounds(axis: axis, index: index)
        }
    }

    private func validateBox(_ box: CGRect, slice: (w: Int, h: Int)) throws {
        guard box.width > 0, box.height > 0 else {
            throw Error.invalidBox("zero-area box")
        }
        guard box.minX >= 0, box.minY >= 0,
              box.maxX <= CGFloat(slice.w),
              box.maxY <= CGFloat(slice.h) else {
            throw Error.invalidBox("out of slice bounds")
        }
    }
}
