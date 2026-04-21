import Foundation
import CoreGraphics
import ImageIO

/// Converts raw Float slice data into a CGImage using window/level + optional colormap.
public enum PixelRenderer {

    /// Render a grayscale slice with window/level applied.
    public static func makeGrayImage(
        pixels: [Float], width: Int, height: Int,
        window: Double, level: Double,
        invert: Bool = false
    ) -> CGImage? {
        guard pixels.count == width * height else { return nil }

        let minVal = level - window / 2
        let range = max(window, 0.0001)
        var buffer = [UInt8](repeating: 0, count: width * height)

        for i in 0..<pixels.count {
            let v = (Double(pixels[i]) - minVal) / range
            let clamped = max(0, min(1, v))
            let byte = UInt8(clamped * 255)
            buffer[i] = invert ? (255 - byte) : byte
        }

        return makeCGImage(grayBytes: buffer, width: width, height: height)
    }

    /// Render a slice through a colormap LUT (for overlay visualization).
    public static func makeColorImage(
        pixels: [Float], width: Int, height: Int,
        window: Double, level: Double,
        colormap: Colormap,
        baseAlpha: Double = 1.0
    ) -> CGImage? {
        guard pixels.count == width * height else { return nil }

        let lut = ColormapLUT.generate(colormap, size: 256)
        let minVal = level - window / 2
        let range = max(window, 0.0001)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        for i in 0..<pixels.count {
            let v = (Double(pixels[i]) - minVal) / range
            let idx = Int(max(0, min(1, v)) * 255)
            let (r, g, b, a) = lut[idx]
            rgba[i * 4]     = r
            rgba[i * 4 + 1] = g
            rgba[i * 4 + 2] = b
            rgba[i * 4 + 3] = UInt8(Double(a) * baseAlpha)
        }

        return makeCGImage(rgbaBytes: rgba, width: width, height: height)
    }

    // MARK: - CGImage creation helpers

    private static func makeCGImage(grayBytes bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = width
        var data = bytes

        guard let provider = CGDataProvider(data: NSData(bytes: &data, length: data.count)) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func makeCGImage(rgbaBytes bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var data = bytes

        guard let provider = CGDataProvider(data: NSData(bytes: &data, length: data.count)) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// Apply flip/rotation in-place on a flat pixel buffer.
public enum SliceTransform {
    public static func flipVertical(_ pixels: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: pixels.count)
        for row in 0..<height {
            let srcStart = row * width
            let dstStart = (height - 1 - row) * width
            for col in 0..<width {
                out[dstStart + col] = pixels[srcStart + col]
            }
        }
        return out
    }

    public static func flipHorizontal(_ pixels: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: pixels.count)
        for row in 0..<height {
            for col in 0..<width {
                out[row * width + col] = pixels[row * width + (width - 1 - col)]
            }
        }
        return out
    }
}
