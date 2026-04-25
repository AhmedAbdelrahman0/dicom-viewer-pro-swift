import Foundation

public enum VolumeMeasurementSource: String, Sendable {
    case petSUV = "PET SUV"
    case ctHU = "CT HU"
    case intensity = "Intensity"
}

public enum VolumeMeasurementMethod: String, CaseIterable, Identifiable, Sendable {
    case activeLabel = "Active label"
    case fixedThreshold = "Fixed threshold"
    case percentOfMax = "% of max"
    case gradientEdge = "Gradient edge"
    case huRange = "HU range"
    case regionGrow = "Region grow"

    public var id: String { rawValue }
}

public struct HUThresholdPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let lower: Double
    public let upper: Double
    public let note: String

    public init(name: String, lower: Double, upper: Double, note: String) {
        self.id = name
        self.name = name
        self.lower = lower
        self.upper = upper
        self.note = note
    }

    public static let presets: [HUThresholdPreset] = [
        HUThresholdPreset(name: "Air / gas", lower: -1024, upper: -700, note: "Gas-filled structures"),
        HUThresholdPreset(name: "Lung", lower: -1000, upper: -400, note: "Aerated lung mask starter"),
        HUThresholdPreset(name: "Fat", lower: -190, upper: -30, note: "Adipose tissue range"),
        HUThresholdPreset(name: "Soft tissue", lower: -50, upper: 150, note: "General soft-tissue starter"),
        HUThresholdPreset(name: "Muscle", lower: -29, upper: 150, note: "Common body-composition range"),
        HUThresholdPreset(name: "Contrast / vessel", lower: 120, upper: 500, note: "Enhanced vessel or contrast-filled region"),
        HUThresholdPreset(name: "Bone", lower: 150, upper: 3000, note: "Cortical/trabecular bone starter")
    ]
}

public struct VolumeMeasurementReport: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let source: VolumeMeasurementSource
    public let method: VolumeMeasurementMethod
    public let className: String
    public let voxelCount: Int
    public let volumeMM3: Double
    public let mean: Double
    public let min: Double
    public let max: Double
    public let std: Double
    public let suvMax: Double?
    public let suvMean: Double?
    public let suvPeak: Double?
    public let tlg: Double?
    public let thresholdSummary: String

    public var volumeML: Double { volumeMM3 / 1000.0 }

    public static func empty(
        source: VolumeMeasurementSource,
        method: VolumeMeasurementMethod,
        className: String,
        thresholdSummary: String
    ) -> VolumeMeasurementReport {
        VolumeMeasurementReport(
            source: source,
            method: method,
            className: className,
            voxelCount: 0,
            volumeMM3: 0,
            mean: 0,
            min: 0,
            max: 0,
            std: 0,
            suvMax: nil,
            suvMean: nil,
            suvPeak: nil,
            tlg: nil,
            thresholdSummary: thresholdSummary
        )
    }

    public static func compute(
        volume: ImageVolume,
        labelMap: LabelMap,
        classID: UInt16,
        source: VolumeMeasurementSource,
        method: VolumeMeasurementMethod,
        thresholdSummary: String,
        valueTransform: ((Double) -> Double)? = nil
    ) -> VolumeMeasurementReport {
        let className = labelMap.classInfo(id: classID)?.name ?? "class_\(classID)"
        let stats = RegionStats.compute(
            volume,
            labelMap,
            classID: classID,
            suvTransform: source == .petSUV ? valueTransform : nil
        )
        guard stats.count > 0 else {
            return .empty(
                source: source,
                method: method,
                className: className,
                thresholdSummary: thresholdSummary
            )
        }
        return VolumeMeasurementReport(
            source: source,
            method: method,
            className: className,
            voxelCount: stats.count,
            volumeMM3: stats.volumeMM3,
            mean: stats.mean,
            min: stats.min,
            max: stats.max,
            std: stats.std,
            suvMax: stats.suvMax,
            suvMean: stats.suvMean,
            suvPeak: stats.suvPeak,
            tlg: stats.tlg,
            thresholdSummary: thresholdSummary
        )
    }
}
