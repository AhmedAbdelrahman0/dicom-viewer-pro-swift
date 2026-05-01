import Foundation
import simd

public enum VolumeMeasurementSource: String, Codable, Sendable {
    case petSUV = "PET SUV"
    case ctHU = "CT HU"
    case intensity = "Intensity"
}

public enum VolumeMeasurementMethod: String, CaseIterable, Identifiable, Codable, Sendable {
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

public struct VolumeMeasurementReport: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
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
    public var ttvML: Double { volumeML }
    public var metabolicTumorVolumeML: Double { volumeML }

    public init(id: UUID = UUID(),
                source: VolumeMeasurementSource,
                method: VolumeMeasurementMethod,
                className: String,
                voxelCount: Int,
                volumeMM3: Double,
                mean: Double,
                min: Double,
                max: Double,
                std: Double,
                suvMax: Double?,
                suvMean: Double?,
                suvPeak: Double?,
                tlg: Double?,
                thresholdSummary: String) {
        self.id = id
        self.source = source
        self.method = method
        self.className = className
        self.voxelCount = voxelCount
        self.volumeMM3 = volumeMM3
        self.mean = mean
        self.min = min
        self.max = max
        self.std = std
        self.suvMax = suvMax
        self.suvMean = suvMean
        self.suvPeak = suvPeak
        self.tlg = tlg
        self.thresholdSummary = thresholdSummary
    }

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

public struct VoxelCoordinate: Equatable, Codable, Sendable {
    public let z: Int
    public let y: Int
    public let x: Int

    public init(z: Int, y: Int, x: Int) {
        self.z = z
        self.y = y
        self.x = x
    }
}

public struct SUVROIMeasurement: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let sourceVolumeIdentity: String
    public let sourceDescription: String
    public let center: VoxelCoordinate
    public let centerWorld: SIMD3<Double>
    public let radiusMM: Double
    public let voxelCount: Int
    public let volumeMM3: Double
    public let sphereVolumeMM3: Double
    public let rawMin: Double
    public let rawMax: Double
    public let rawMean: Double
    public let rawStd: Double
    public let suvMin: Double
    public let suvMax: Double
    public let suvMean: Double
    public let suvStd: Double

    public init(id: UUID = UUID(),
                sourceVolumeIdentity: String,
                sourceDescription: String,
                center: VoxelCoordinate,
                centerWorld: SIMD3<Double>,
                radiusMM: Double,
                voxelCount: Int,
                volumeMM3: Double,
                sphereVolumeMM3: Double,
                rawMin: Double,
                rawMax: Double,
                rawMean: Double,
                rawStd: Double,
                suvMin: Double,
                suvMax: Double,
                suvMean: Double,
                suvStd: Double) {
        self.id = id
        self.sourceVolumeIdentity = sourceVolumeIdentity
        self.sourceDescription = sourceDescription
        self.center = center
        self.centerWorld = centerWorld
        self.radiusMM = radiusMM
        self.voxelCount = voxelCount
        self.volumeMM3 = volumeMM3
        self.sphereVolumeMM3 = sphereVolumeMM3
        self.rawMin = rawMin
        self.rawMax = rawMax
        self.rawMean = rawMean
        self.rawStd = rawStd
        self.suvMin = suvMin
        self.suvMax = suvMax
        self.suvMean = suvMean
        self.suvStd = suvStd
    }

    public var volumeML: Double { volumeMM3 / 1_000 }
    public var sphereVolumeML: Double { sphereVolumeMM3 / 1_000 }

    public var compactSummary: String {
        String(format: "SUVmax %.2f  SUVmean %.2f  %.2f mL", suvMax, suvMean, volumeML)
    }
}

public struct IntensityROIMeasurement: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let sourceVolumeIdentity: String
    public let sourceDescription: String
    public let modality: String
    public let center: VoxelCoordinate
    public let centerWorld: SIMD3<Double>
    public let radiusMM: Double
    public let voxelCount: Int
    public let volumeMM3: Double
    public let sphereVolumeMM3: Double
    public let valueMin: Double
    public let valueMax: Double
    public let valueMean: Double
    public let valueStd: Double

    public init(id: UUID = UUID(),
                sourceVolumeIdentity: String,
                sourceDescription: String,
                modality: String,
                center: VoxelCoordinate,
                centerWorld: SIMD3<Double>,
                radiusMM: Double,
                voxelCount: Int,
                volumeMM3: Double,
                sphereVolumeMM3: Double,
                valueMin: Double,
                valueMax: Double,
                valueMean: Double,
                valueStd: Double) {
        self.id = id
        self.sourceVolumeIdentity = sourceVolumeIdentity
        self.sourceDescription = sourceDescription
        self.modality = modality
        self.center = center
        self.centerWorld = centerWorld
        self.radiusMM = radiusMM
        self.voxelCount = voxelCount
        self.volumeMM3 = volumeMM3
        self.sphereVolumeMM3 = sphereVolumeMM3
        self.valueMin = valueMin
        self.valueMax = valueMax
        self.valueMean = valueMean
        self.valueStd = valueStd
    }

    public var volumeML: Double { volumeMM3 / 1_000 }
    public var sphereVolumeML: Double { sphereVolumeMM3 / 1_000 }
    public var unit: String {
        Modality.normalize(modality) == .CT ? "HU" : "raw"
    }

    public var compactSummary: String {
        if Modality.normalize(modality) == .CT {
            return String(format: "HUmax %.1f  HUmean %.1f  %.2f mL", valueMax, valueMean, volumeML)
        }
        return String(format: "Max %.2f  Mean %.2f  %.2f mL", valueMax, valueMean, volumeML)
    }
}

public enum SUVROICalculator {
    public static func spherical(
        volume: ImageVolume,
        center: VoxelCoordinate,
        radiusMM: Double,
        suvTransform: (Double) -> Double
    ) -> SUVROIMeasurement? {
        guard radiusMM > 0,
              center.x >= 0, center.x < volume.width,
              center.y >= 0, center.y < volume.height,
              center.z >= 0, center.z < volume.depth else {
            return nil
        }

        let centerWorld = volume.worldPoint(z: center.z, y: center.y, x: center.x)
        let rx = Int(ceil(radiusMM / max(volume.spacing.x, 1e-9))) + 1
        let ry = Int(ceil(radiusMM / max(volume.spacing.y, 1e-9))) + 1
        let rz = Int(ceil(radiusMM / max(volume.spacing.z, 1e-9))) + 1
        let box = VoxelBox(
            minZ: max(0, center.z - rz),
            maxZ: min(volume.depth - 1, center.z + rz),
            minY: max(0, center.y - ry),
            maxY: min(volume.height - 1, center.y + ry),
            minX: max(0, center.x - rx),
            maxX: min(volume.width - 1, center.x + rx)
        )

        var count = 0
        var rawMin = Double.greatestFiniteMagnitude
        var rawMax = -Double.greatestFiniteMagnitude
        var rawSum = 0.0
        var rawSquareSum = 0.0
        var suvMin = Double.greatestFiniteMagnitude
        var suvMax = -Double.greatestFiniteMagnitude
        var suvSum = 0.0
        var suvSquareSum = 0.0
        let radiusWithTolerance = radiusMM + 1e-6

        for z in box.minZ...box.maxZ {
            for y in box.minY...box.maxY {
                let rowStart = z * volume.height * volume.width + y * volume.width
                for x in box.minX...box.maxX {
                    let world = volume.worldPoint(z: z, y: y, x: x)
                    guard simd_distance(world, centerWorld) <= radiusWithTolerance else {
                        continue
                    }
                    let raw = Double(volume.pixels[rowStart + x])
                    let suv = suvTransform(raw)
                    guard raw.isFinite, suv.isFinite else { continue }
                    count += 1
                    rawMin = min(rawMin, raw)
                    rawMax = max(rawMax, raw)
                    rawSum += raw
                    rawSquareSum += raw * raw
                    suvMin = min(suvMin, suv)
                    suvMax = max(suvMax, suv)
                    suvSum += suv
                    suvSquareSum += suv * suv
                }
            }
        }

        guard count > 0 else { return nil }
        let n = Double(count)
        let rawMean = rawSum / n
        let suvMean = suvSum / n
        let rawVariance = max(0, rawSquareSum / n - rawMean * rawMean)
        let suvVariance = max(0, suvSquareSum / n - suvMean * suvMean)
        let voxelVolume = volume.spacing.x * volume.spacing.y * volume.spacing.z
        let sphereVolume = 4.0 / 3.0 * Double.pi * pow(radiusMM, 3)
        let description = volume.seriesDescription.isEmpty
            ? Modality.normalize(volume.modality).displayName
            : volume.seriesDescription

        return SUVROIMeasurement(
            sourceVolumeIdentity: volume.sessionIdentity,
            sourceDescription: description,
            center: center,
            centerWorld: centerWorld,
            radiusMM: radiusMM,
            voxelCount: count,
            volumeMM3: n * voxelVolume,
            sphereVolumeMM3: sphereVolume,
            rawMin: rawMin,
            rawMax: rawMax,
            rawMean: rawMean,
            rawStd: sqrt(rawVariance),
            suvMin: suvMin,
            suvMax: suvMax,
            suvMean: suvMean,
            suvStd: sqrt(suvVariance)
        )
    }
}

public enum IntensityROICalculator {
    public static func spherical(
        volume: ImageVolume,
        center: VoxelCoordinate,
        radiusMM: Double
    ) -> IntensityROIMeasurement? {
        guard radiusMM > 0,
              center.x >= 0, center.x < volume.width,
              center.y >= 0, center.y < volume.height,
              center.z >= 0, center.z < volume.depth else {
            return nil
        }

        let centerWorld = volume.worldPoint(z: center.z, y: center.y, x: center.x)
        let rx = Int(ceil(radiusMM / max(volume.spacing.x, 1e-9))) + 1
        let ry = Int(ceil(radiusMM / max(volume.spacing.y, 1e-9))) + 1
        let rz = Int(ceil(radiusMM / max(volume.spacing.z, 1e-9))) + 1
        let box = VoxelBox(
            minZ: max(0, center.z - rz),
            maxZ: min(volume.depth - 1, center.z + rz),
            minY: max(0, center.y - ry),
            maxY: min(volume.height - 1, center.y + ry),
            minX: max(0, center.x - rx),
            maxX: min(volume.width - 1, center.x + rx)
        )

        var count = 0
        var valueMin = Double.greatestFiniteMagnitude
        var valueMax = -Double.greatestFiniteMagnitude
        var valueSum = 0.0
        var valueSquareSum = 0.0
        let radiusWithTolerance = radiusMM + 1e-6

        for z in box.minZ...box.maxZ {
            for y in box.minY...box.maxY {
                let rowStart = z * volume.height * volume.width + y * volume.width
                for x in box.minX...box.maxX {
                    let world = volume.worldPoint(z: z, y: y, x: x)
                    guard simd_distance(world, centerWorld) <= radiusWithTolerance else {
                        continue
                    }
                    let value = Double(volume.pixels[rowStart + x])
                    guard value.isFinite else { continue }
                    count += 1
                    valueMin = min(valueMin, value)
                    valueMax = max(valueMax, value)
                    valueSum += value
                    valueSquareSum += value * value
                }
            }
        }

        guard count > 0 else { return nil }
        let n = Double(count)
        let valueMean = valueSum / n
        let valueVariance = max(0, valueSquareSum / n - valueMean * valueMean)
        let voxelVolume = volume.spacing.x * volume.spacing.y * volume.spacing.z
        let sphereVolume = 4.0 / 3.0 * Double.pi * pow(radiusMM, 3)
        let description = volume.seriesDescription.isEmpty
            ? Modality.normalize(volume.modality).displayName
            : volume.seriesDescription

        return IntensityROIMeasurement(
            sourceVolumeIdentity: volume.sessionIdentity,
            sourceDescription: description,
            modality: volume.modality,
            center: center,
            centerWorld: centerWorld,
            radiusMM: radiusMM,
            voxelCount: count,
            volumeMM3: n * voxelVolume,
            sphereVolumeMM3: sphereVolume,
            valueMin: valueMin,
            valueMax: valueMax,
            valueMean: valueMean,
            valueStd: sqrt(valueVariance)
        )
    }
}
