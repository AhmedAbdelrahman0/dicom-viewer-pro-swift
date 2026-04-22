import Foundation

/// Histogram-based automatic window/level selection, inspired by ITK-SNAP's
/// *Intensity Curve* auto-adjust. Re-implemented here independently.
///
/// Given an intensity volume, this picks a `(window, level)` pair that keeps
/// the requested percentile range of the histogram inside the contrast
/// window. The common clinical choices are surfaced as presets:
///
///   - `.tight`      — 2 % / 98 % clip, good default for CT
///   - `.balanced`   — 1 % / 99 % clip, default for MRI / general imaging
///   - `.loose`      — 0.5 % / 99.5 %, preserves outliers
///   - `.petSUV`     — 0 / 98 % on positive-only values, centered on PET
///   - `.percentiles(Double, Double)` — bring your own
public enum HistogramAutoWindow {

    public enum Preset: Sendable {
        case tight
        case balanced
        case loose
        case petSUV
        case percentiles(lower: Double, upper: Double)

        fileprivate var range: (Double, Double) {
            switch self {
            case .tight:                     return (0.02, 0.98)
            case .balanced:                  return (0.01, 0.99)
            case .loose:                     return (0.005, 0.995)
            case .petSUV:                    return (0.00, 0.98)
            case .percentiles(let l, let u): return (l, u)
            }
        }
    }

    public struct WindowLevelResult: Sendable, Equatable {
        public let window: Double
        public let level: Double
        public let lowerValue: Double
        public let upperValue: Double
        public let totalSamples: Int
    }

    /// Compute a `(window, level)` pair from the volume's histogram.
    public static func compute(_ volume: ImageVolume,
                               preset: Preset = .balanced,
                               binCount: Int = 512,
                               ignoreZeros: Bool = false) -> WindowLevelResult {
        compute(pixels: volume.pixels,
                preset: preset,
                binCount: binCount,
                ignoreZeros: ignoreZeros)
    }

    public static func compute(pixels: [Float],
                               preset: Preset = .balanced,
                               binCount: Int = 512,
                               ignoreZeros: Bool = false) -> WindowLevelResult {
        guard !pixels.isEmpty else {
            return WindowLevelResult(window: 1, level: 0.5,
                                     lowerValue: 0, upperValue: 1,
                                     totalSamples: 0)
        }

        // Collect min/max from filtered stream.
        var minV: Float = .infinity
        var maxV: Float = -.infinity
        var filteredCount = 0
        for v in pixels {
            if ignoreZeros, v == 0 { continue }
            if v < minV { minV = v }
            if v > maxV { maxV = v }
            filteredCount += 1
        }
        guard filteredCount > 0, maxV > minV else {
            let m = Double(pixels.first ?? 0)
            return WindowLevelResult(window: 1, level: m,
                                     lowerValue: m, upperValue: m + 1,
                                     totalSamples: filteredCount)
        }

        // Build histogram.
        let bins = max(16, binCount)
        var hist = [Int](repeating: 0, count: bins)
        let range = maxV - minV
        let scale = Float(bins - 1) / range
        for v in pixels {
            if ignoreZeros, v == 0 { continue }
            var idx = Int((v - minV) * scale)
            if idx < 0 { idx = 0 }
            if idx >= bins { idx = bins - 1 }
            hist[idx] += 1
        }

        // Cumulative histogram → percentile lookup.
        var cumulative = [Int](repeating: 0, count: bins)
        var running = 0
        for i in 0..<bins {
            running += hist[i]
            cumulative[i] = running
        }
        let total = cumulative.last ?? 0
        guard total > 0 else {
            return WindowLevelResult(window: 1, level: 0.5,
                                     lowerValue: 0, upperValue: 1,
                                     totalSamples: filteredCount)
        }

        let (lowerPct, upperPct) = preset.range
        let lowerTarget = Int(Double(total) * lowerPct)
        let upperTarget = Int(Double(total) * upperPct)

        var lowerBin = 0
        for i in 0..<bins where cumulative[i] >= lowerTarget {
            lowerBin = i
            break
        }
        var upperBin = bins - 1
        for i in 0..<bins where cumulative[i] >= upperTarget {
            upperBin = i
            break
        }
        if upperBin <= lowerBin { upperBin = min(bins - 1, lowerBin + 1) }

        let lowerValue = Double(minV + Float(lowerBin) / scale)
        let upperValue = Double(minV + Float(upperBin) / scale)
        let window = max(upperValue - lowerValue, 1)
        let level = (upperValue + lowerValue) * 0.5

        return WindowLevelResult(window: window,
                                 level: level,
                                 lowerValue: lowerValue,
                                 upperValue: upperValue,
                                 totalSamples: filteredCount)
    }
}
