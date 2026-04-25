import Foundation

public struct WindowLevel: Hashable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let window: Double
    public let level: Double

    public init(name: String, window: Double, level: Double) {
        self.name = name
        self.window = window
        self.level = level
    }

    public var minValue: Double { level - window / 2 }
    public var maxValue: Double { level + window / 2 }
}

public enum WLPresets {
    public static let CT: [WindowLevel] = [
        .init(name: "Abdomen",      window: 400,  level: 50),
        .init(name: "Lung",         window: 1500, level: -600),
        .init(name: "Bone",         window: 2500, level: 480),
        .init(name: "Brain",        window: 80,   level: 40),
        .init(name: "Liver",        window: 150,  level: 30),
        .init(name: "Mediastinum",  window: 350,  level: 50),
        .init(name: "Soft Tissue",  window: 400,  level: 40),
        .init(name: "Angio",        window: 600,  level: 170),
        .init(name: "Spine",        window: 300,  level: 40),
    ]

    public static let MR: [WindowLevel] = [
        .init(name: "T1",     window: 600,  level: 300),
        .init(name: "T2",     window: 1200, level: 600),
        .init(name: "FLAIR",  window: 1500, level: 750),
        .init(name: "DWI",    window: 1000, level: 500),
        .init(name: "Brain",  window: 800,  level: 400),
    ]

    public static let PT: [WindowLevel] = [
        .init(name: "Standard", window: 6,  level: 3),
        .init(name: "Hot",      window: 10, level: 5),
        .init(name: "Extended", window: 20, level: 10),
    ]

    public static func presets(for modality: Modality) -> [WindowLevel] {
        switch modality {
        case .CT: return CT
        case .MR: return MR
        case .PT: return PT
        default:  return CT
        }
    }
}

/// Compute a sensible auto window/level from data percentiles.
public func autoWindowLevel(pixels: [Float]) -> (window: Double, level: Double) {
    guard pixels.count > 10 else { return (400, 40) }
    let result = HistogramAutoWindow.compute(
        pixels: pixels,
        preset: .balanced,
        binCount: 512,
        ignoreZeros: false
    )
    return (result.window, result.level)
}
