import Foundation

public struct VoxelEditDiff: Sendable {
    public let indices: [Int]
    public let before: [UInt16]
    public let after: [UInt16]
    public let overflowed: Bool

    public var isEmpty: Bool {
        indices.isEmpty && !overflowed
    }

    public static func compute(before: [UInt16], after: [UInt16], limit: Int) -> VoxelEditDiff {
        guard before.count == after.count else {
            return VoxelEditDiff(indices: [], before: [], after: [], overflowed: true)
        }

        var indices: [Int] = []
        var oldValues: [UInt16] = []
        var newValues: [UInt16] = []
        indices.reserveCapacity(min(before.count, 16_384))
        oldValues.reserveCapacity(min(before.count, 16_384))
        newValues.reserveCapacity(min(before.count, 16_384))

        for i in 0..<before.count where before[i] != after[i] {
            if indices.count >= limit {
                return VoxelEditDiff(indices: [], before: [], after: [], overflowed: true)
            }
            indices.append(i)
            oldValues.append(before[i])
            newValues.append(after[i])
        }

        return VoxelEditDiff(indices: indices, before: oldValues, after: newValues, overflowed: false)
    }
}

enum VolumeLabelOperation: Sendable {
    case petThreshold(threshold: Double)
    case petPercentOfMax(percent: Double)
    case petSeededPercentOfMax(seed: (z: Int, y: Int, x: Int),
                               boxRadius: Int,
                               percent: Double)
    case petGradient(seed: (z: Int, y: Int, x: Int),
                     minimumValue: Double,
                     gradientCutoffFraction: Double,
                     searchRadius: Int)
    case regionGrow(seed: (z: Int, y: Int, x: Int), tolerance: Double)
    case ctRange(lower: Double, upper: Double)

    var title: String {
        switch self {
        case .petThreshold: return "PET SUV threshold"
        case .petPercentOfMax: return "PET percent SUVmax"
        case .petSeededPercentOfMax: return "PET seeded percent SUVmax"
        case .petGradient: return "PET SUV gradient"
        case .regionGrow: return "Region grow"
        case .ctRange: return "CT HU volume"
        }
    }

    var systemImage: String {
        switch self {
        case .petThreshold, .petPercentOfMax, .petSeededPercentOfMax:
            return "flame"
        case .petGradient:
            return "point.3.connected.trianglepath.dotted"
        case .regionGrow:
            return "circle.hexagongrid"
        case .ctRange:
            return "scalemass"
        }
    }

    var method: VolumeMeasurementMethod {
        switch self {
        case .petThreshold: return .fixedThreshold
        case .petPercentOfMax, .petSeededPercentOfMax: return .percentOfMax
        case .petGradient: return .gradientEdge
        case .regionGrow: return .regionGrow
        case .ctRange: return .huRange
        }
    }

    var thresholdSummary: String {
        switch self {
        case .petThreshold(let threshold):
            return "SUV >= \(String(format: "%.2f", threshold))"
        case .petPercentOfMax(let percent):
            return "\(Int(percent * 100))% of SUVmax"
        case .petSeededPercentOfMax(_, _, let percent):
            return "\(Int(percent * 100))% of local SUVmax"
        case .petGradient(_, let minimumValue, _, _):
            return "Gradient edge, floor SUV \(String(format: "%.2f", minimumValue))"
        case .regionGrow(_, let tolerance):
            return "Region grow +/-\(String(format: "%.1f", tolerance))"
        case .ctRange(let lower, let upper):
            return "\(Int(min(lower, upper)))...\(Int(max(lower, upper))) HU"
        }
    }
}

struct VolumeLabelOperationInput: Sendable {
    let mapID: UUID
    let mapName: String
    let classes: [LabelClass]
    let startingVoxels: [UInt16]
    let volume: ImageVolume
    let classID: UInt16
    let usesSUV: Bool
    let suvSettings: SUVCalculationSettings
    let operation: VolumeLabelOperation
    let diffLimit: Int
}

struct VolumeLabelOperationOutput: Sendable {
    let mapID: UUID
    let operation: VolumeLabelOperation
    let voxels: [UInt16]
    let diff: VoxelEditDiff
    let voxelCount: Int
    let report: VolumeMeasurementReport
    let gradient: PETGradientSegmentationResult?
}

struct VolumeMeasurementInput: Sendable {
    let mapID: UUID
    let mapName: String
    let classes: [LabelClass]
    let voxels: [UInt16]
    let volume: ImageVolume
    let classID: UInt16
    let source: VolumeMeasurementSource
    let method: VolumeMeasurementMethod
    let thresholdSummary: String
    let suvSettings: SUVCalculationSettings
}

enum VolumeOperationWorker {
    static func runLabelOperation(_ input: VolumeLabelOperationInput) -> VolumeLabelOperationOutput {
        let label = LabelMap(
            parentSeriesUID: input.volume.seriesUID,
            depth: input.volume.depth,
            height: input.volume.height,
            width: input.volume.width,
            name: input.mapName,
            classes: input.classes
        )
        label.voxels = input.startingVoxels

        let transform: ((Double) -> Double)? = input.usesSUV
            ? { [settings = input.suvSettings, volume = input.volume] raw in
                settings.suv(forStoredValue: raw, volume: volume)
            }
            : nil

        let voxelCount: Int
        let gradient: PETGradientSegmentationResult?
        switch input.operation {
        case .petThreshold(let threshold):
            voxelCount = PETSegmentation.thresholdAbove(
                volume: input.volume,
                label: label,
                threshold: threshold,
                classID: input.classID,
                valueTransform: transform
            )
            gradient = nil

        case .petPercentOfMax(let percent):
            voxelCount = PETSegmentation.percentOfMax(
                volume: input.volume,
                label: label,
                percent: percent,
                classID: input.classID,
                boundingBox: VoxelBox.all(in: input.volume),
                valueTransform: transform
            )
            gradient = nil

        case .petSeededPercentOfMax(let seed, let boxRadius, let percent):
            voxelCount = PETSegmentation.percentOfMax(
                volume: input.volume,
                label: label,
                percent: percent,
                classID: input.classID,
                boundingBox: VoxelBox.around(seed, radius: boxRadius, in: input.volume),
                valueTransform: transform
            )
            gradient = nil

        case .petGradient(let seed, let minimumValue, let gradientCutoffFraction, let searchRadius):
            let result = PETSegmentation.gradientEdge(
                volume: input.volume,
                label: label,
                seed: seed,
                minimumValue: minimumValue,
                gradientCutoffFraction: gradientCutoffFraction,
                classID: input.classID,
                searchRadius: searchRadius,
                valueTransform: transform
            )
            voxelCount = result.voxelCount
            gradient = result

        case .regionGrow(let seed, let tolerance):
            voxelCount = PETSegmentation.regionGrow(
                volume: input.volume,
                label: label,
                seed: seed,
                tolerance: tolerance,
                classID: input.classID
            )
            gradient = nil

        case .ctRange(let lower, let upper):
            voxelCount = PETSegmentation.thresholdRange(
                volume: input.volume,
                label: label,
                lower: lower,
                upper: upper,
                classID: input.classID
            )
            gradient = nil
        }

        let source: VolumeMeasurementSource = input.usesSUV ? .petSUV : .ctHU
        let report = VolumeMeasurementReport.compute(
            volume: input.volume,
            labelMap: label,
            classID: input.classID,
            source: source,
            method: input.operation.method,
            thresholdSummary: input.operation.thresholdSummary,
            valueTransform: source == .petSUV ? transform : nil
        )
        let diff = VoxelEditDiff.compute(
            before: input.startingVoxels,
            after: label.voxels,
            limit: input.diffLimit
        )

        return VolumeLabelOperationOutput(
            mapID: input.mapID,
            operation: input.operation,
            voxels: label.voxels,
            diff: diff,
            voxelCount: voxelCount,
            report: report,
            gradient: gradient
        )
    }

    static func measure(_ input: VolumeMeasurementInput) -> VolumeMeasurementReport {
        let label = LabelMap(
            parentSeriesUID: input.volume.seriesUID,
            depth: input.volume.depth,
            height: input.volume.height,
            width: input.volume.width,
            name: input.mapName,
            classes: input.classes
        )
        label.voxels = input.voxels
        let transform: ((Double) -> Double)? = input.source == .petSUV
            ? { [settings = input.suvSettings, volume = input.volume] raw in
                settings.suv(forStoredValue: raw, volume: volume)
            }
            : nil

        return VolumeMeasurementReport.compute(
            volume: input.volume,
            labelMap: label,
            classID: input.classID,
            source: input.source,
            method: input.method,
            thresholdSummary: input.thresholdSummary,
            valueTransform: transform
        )
    }
}
