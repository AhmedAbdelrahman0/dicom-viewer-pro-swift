import Foundation
import CoreGraphics
import SwiftUI

/// Converts a 2D label slice into an RGBA CGImage using each class's color.
public enum LabelRenderer {

    /// Render a label slice as RGBA. Transparent where voxel value is 0.
    public static func makeImage(values: [UInt16],
                                  width: Int, height: Int,
                                  classes: [LabelClass],
                                  baseAlpha: Double = 0.5) -> CGImage? {
        guard values.count == width * height else { return nil }

        // Build lookup of color by label ID
        var colorByID: [UInt16: (UInt8, UInt8, UInt8, UInt8)] = [:]
        for cls in classes {
            guard cls.visible else { continue }
            let (r, g, b) = cls.color.rgbBytes()
            let alpha = UInt8(min(255, max(0, Int(cls.opacity * baseAlpha * 255))))
            colorByID[cls.labelID] = (r, g, b, alpha)
        }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        for i in 0..<values.count {
            let id = values[i]
            if id == 0 { continue }
            if let (r, g, b, a) = colorByID[id] {
                rgba[i * 4]     = r
                rgba[i * 4 + 1] = g
                rgba[i * 4 + 2] = b
                rgba[i * 4 + 3] = a
            }
        }

        return makeRGBA(bytes: rgba, width: width, height: height)
    }

    /// Render only the outlines (useful for overlay on thin structures).
    public static func makeOutlineImage(values: [UInt16],
                                         width: Int, height: Int,
                                         classes: [LabelClass],
                                         thickness: Int = 1,
                                         baseAlpha: Double = 0.8) -> CGImage? {
        guard values.count == width * height else { return nil }

        var colorByID: [UInt16: (UInt8, UInt8, UInt8, UInt8)] = [:]
        for cls in classes where cls.visible {
            let (r, g, b) = cls.color.rgbBytes()
            let alpha = UInt8(min(255, max(0, Int(baseAlpha * 255))))
            colorByID[cls.labelID] = (r, g, b, alpha)
        }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let cur = values[idx]
                if cur == 0 { continue }
                // Check if this is a boundary voxel (has different neighbor)
                var isBoundary = false
                for dy in -thickness...thickness {
                    for dx in -thickness...thickness {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx, ny = y + dy
                        if nx < 0 || ny < 0 || nx >= width || ny >= height {
                            isBoundary = true; break
                        }
                        if values[ny * width + nx] != cur {
                            isBoundary = true; break
                        }
                    }
                    if isBoundary { break }
                }
                if isBoundary, let (r, g, b, a) = colorByID[cur] {
                    rgba[idx * 4]     = r
                    rgba[idx * 4 + 1] = g
                    rgba[idx * 4 + 2] = b
                    rgba[idx * 4 + 3] = a
                }
            }
        }

        return makeRGBA(bytes: rgba, width: width, height: height)
    }

    private static func makeRGBA(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        var data = bytes
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: NSData(bytes: &data, length: data.count)) else {
            return nil
        }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
