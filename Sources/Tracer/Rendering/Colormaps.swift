import Foundation

/// Produces RGBA color lookup tables for medical imaging visualizations.
public enum ColormapLUT {

    public static func generate(_ colormap: Colormap, size: Int = 256) -> [(UInt8, UInt8, UInt8, UInt8)] {
        var lut = [(UInt8, UInt8, UInt8, UInt8)](repeating: (0, 0, 0, 255), count: size)

        for i in 0..<size {
            let t = Double(i) / Double(size - 1)
            let (r, g, b): (Double, Double, Double)

            switch colormap {
            case .hot:
                r = min(1.0, t * 3.0)
                g = max(0.0, min(1.0, (t - 0.333) * 3.0))
                b = max(0.0, min(1.0, (t - 0.666) * 3.0))

            case .petRainbow:
                if t < 0.25 {
                    (r, g, b) = (0, t * 4, 1)
                } else if t < 0.5 {
                    (r, g, b) = (0, 1, 1 - (t - 0.25) * 4)
                } else if t < 0.75 {
                    (r, g, b) = ((t - 0.5) * 4, 1, 0)
                } else {
                    (r, g, b) = (1, 1 - (t - 0.75) * 4, 0)
                }

            case .jet:
                r = max(0, min(1, 1.5 - abs(t - 0.75) * 4))
                g = max(0, min(1, 1.5 - abs(t - 0.5) * 4))
                b = max(0, min(1, 1.5 - abs(t - 0.25) * 4))

            case .bone:
                r = min(1.0, t * 1.1)
                g = min(1.0, t * 1.0)
                b = min(1.0, t * 0.9 + 0.05)

            case .coolWarm:
                if t < 0.5 {
                    let s = t * 2
                    (r, g, b) = (0.2 + 0.8 * s, 0.2 + 0.8 * s, 1.0)
                } else {
                    let s = (t - 0.5) * 2
                    (r, g, b) = (1.0, 1.0 - 0.8 * s, 1.0 - 0.8 * s)
                }

            case .fire:
                r = min(1, t * 2)
                g = max(0, min(1, (t - 0.3) * 2.5))
                b = max(0, min(1, (t - 0.7) * 3.3))

            case .ice:
                if t < 0.3 {
                    (r, g, b) = (0, 0.2 * (t / 0.3), 0.5 * (t / 0.3))
                } else if t < 0.7 {
                    let s = (t - 0.3) / 0.4
                    (r, g, b) = (s * 0.3, 0.2 + s * 0.3, 0.5 + s * 0.5)
                } else {
                    let s = (t - 0.7) / 0.3
                    (r, g, b) = (0.3 + s * 0.7, 0.5 + s * 0.5, 1.0)
                }

            case .grayscale:
                r = t; g = t; b = t

            case .invertedGray:
                r = 1 - t; g = 1 - t; b = 1 - t
            }

            let ri = UInt8(max(0, min(255, r * 255)))
            let gi = UInt8(max(0, min(255, g * 255)))
            let bi = UInt8(max(0, min(255, b * 255)))
            // Alpha tapers near the low end for overlay-friendly colormaps
            let ai: UInt8
            switch colormap {
            case .grayscale, .invertedGray, .bone:
                ai = 255
            default:
                ai = t > 0.02 ? 255 : UInt8(t * 50 * 255)
            }
            lut[i] = (ri, gi, bi, ai)
        }

        return lut
    }
}
