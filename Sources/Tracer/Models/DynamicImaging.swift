import Foundation

public struct DynamicFrame: Identifiable, Sendable {
    public let id: UUID
    public let index: Int
    public let volume: ImageVolume
    public let startSeconds: Double
    public let durationSeconds: Double

    public init(id: UUID = UUID(),
                index: Int,
                volume: ImageVolume,
                startSeconds: Double,
                durationSeconds: Double) {
        self.id = id
        self.index = index
        self.volume = volume
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }

    public var midSeconds: Double {
        startSeconds + durationSeconds / 2
    }

    public var displayName: String {
        let time = DynamicFrame.formatTime(midSeconds)
        return "F\(index + 1)  \(time)"
    }

    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--" }
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%.1fmin", seconds / 60)
    }
}

public struct DynamicImageStudy: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let modality: Modality
    public let frames: [DynamicFrame]

    public init(id: UUID = UUID(),
                name: String,
                modality: Modality,
                frames: [DynamicFrame]) {
        self.id = id
        self.name = name
        self.modality = modality
        self.frames = frames.sorted { $0.startSeconds < $1.startSeconds }
    }

    public var frameCount: Int { frames.count }

    public var totalDurationSeconds: Double {
        guard let last = frames.last else { return 0 }
        return last.startSeconds + last.durationSeconds
    }

    public var durationLabel: String {
        DynamicFrame.formatTime(totalDurationSeconds)
    }

    public func frame(at index: Int) -> DynamicFrame? {
        guard !frames.isEmpty else { return nil }
        return frames[max(0, min(frames.count - 1, index))]
    }
}

public struct DynamicTimeActivityPoint: Identifiable, Equatable, Sendable {
    public let id: Int
    public let frameIndex: Int
    public let midSeconds: Double
    public let durationSeconds: Double
    public let voxelCount: Int
    public let mean: Double
    public let max: Double
    public let min: Double
    public let unit: String

    public init(frameIndex: Int,
                midSeconds: Double,
                durationSeconds: Double,
                voxelCount: Int,
                mean: Double,
                max: Double,
                min: Double,
                unit: String) {
        self.id = frameIndex
        self.frameIndex = frameIndex
        self.midSeconds = midSeconds
        self.durationSeconds = durationSeconds
        self.voxelCount = voxelCount
        self.mean = mean
        self.max = max
        self.min = min
        self.unit = unit
    }
}

public enum DynamicStudyBuilder {
    public static func makeStudy(
        from volumes: [ImageVolume],
        preferredReference: ImageVolume? = nil,
        frameDurationSeconds: Double = 1.0,
        name: String? = nil
    ) -> DynamicImageStudy? {
        let candidates = dynamicCandidates(from: volumes)
        guard candidates.count >= 2 else { return nil }

        let reference = preferredReference.flatMap { preferred in
            candidates.first { $0.id == preferred.id }
        } ?? candidates.first
        guard let reference else { return nil }

        let compatible = candidates
            .filter { hasMatchingDynamicGrid(reference, $0) }
            .sorted(by: sortForDynamicFrames)
        guard compatible.count >= 2 else { return nil }

        let duration = max(frameDurationSeconds, 0.001)
        let frames = compatible.enumerated().map { offset, volume in
            DynamicFrame(
                index: offset,
                volume: volume,
                startSeconds: Double(offset) * duration,
                durationSeconds: duration
            )
        }
        let studyName = name
            ?? reference.studyDescription.nonEmpty
            ?? reference.seriesDescription.nonEmpty
            ?? "\(Modality.normalize(reference.modality).displayName) Dynamic"
        return DynamicImageStudy(
            name: studyName,
            modality: Modality.normalize(reference.modality),
            frames: frames
        )
    }

    public static func dynamicCandidates(from volumes: [ImageVolume]) -> [ImageVolume] {
        let nuclear = volumes.filter {
            let modality = Modality.normalize($0.modality)
            return modality == .PT || modality == .NM
        }
        return nuclear.isEmpty ? volumes : nuclear
    }

    public static func hasMatchingDynamicGrid(_ lhs: ImageVolume, _ rhs: ImageVolume) -> Bool {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.depth == rhs.depth else {
            return false
        }
        let tolerance = 1e-4
        guard abs(lhs.spacing.x - rhs.spacing.x) < tolerance,
              abs(lhs.spacing.y - rhs.spacing.y) < tolerance,
              abs(lhs.spacing.z - rhs.spacing.z) < tolerance,
              abs(lhs.origin.x - rhs.origin.x) < tolerance,
              abs(lhs.origin.y - rhs.origin.y) < tolerance,
              abs(lhs.origin.z - rhs.origin.z) < tolerance else {
            return false
        }
        for column in 0..<3 {
            for row in 0..<3 where abs(lhs.direction[column][row] - rhs.direction[column][row]) >= tolerance {
                return false
            }
        }
        return true
    }

    private static func sortForDynamicFrames(_ lhs: ImageVolume, _ rhs: ImageVolume) -> Bool {
        let lhsKey = [lhs.seriesDescription, lhs.sourceFiles.first ?? "", lhs.sessionIdentity].joined(separator: "|")
        let rhsKey = [rhs.seriesDescription, rhs.sourceFiles.first ?? "", rhs.sessionIdentity].joined(separator: "|")
        return lhsKey.localizedStandardCompare(rhsKey) == .orderedAscending
    }
}

public enum DynamicTimeActivityCalculator {
    public static func compute(
        study: DynamicImageStudy,
        labelVoxels: [UInt16],
        labelDimensions: (depth: Int, height: Int, width: Int),
        classID: UInt16,
        suvSettings: SUVCalculationSettings
    ) -> [DynamicTimeActivityPoint] {
        study.frames.compactMap { frame in
            let volume = frame.volume
            guard volume.depth == labelDimensions.depth,
                  volume.height == labelDimensions.height,
                  volume.width == labelDimensions.width,
                  labelVoxels.count == volume.pixels.count else {
                return nil
            }

            let isPET = Modality.normalize(volume.modality) == .PT
            let unit = isPET ? "SUV" : "counts"
            var count = 0
            var sum = 0.0
            var minValue = Double.greatestFiniteMagnitude
            var maxValue = -Double.greatestFiniteMagnitude

            for i in 0..<labelVoxels.count where labelVoxels[i] == classID {
                let raw = Double(volume.pixels[i])
                let value = isPET
                    ? suvSettings.suv(forStoredValue: raw, volume: volume)
                    : raw
                guard value.isFinite else { continue }
                count += 1
                sum += value
                minValue = Swift.min(minValue, value)
                maxValue = Swift.max(maxValue, value)
            }

            guard count > 0 else {
                return DynamicTimeActivityPoint(
                    frameIndex: frame.index,
                    midSeconds: frame.midSeconds,
                    durationSeconds: frame.durationSeconds,
                    voxelCount: 0,
                    mean: 0,
                    max: 0,
                    min: 0,
                    unit: unit
                )
            }

            return DynamicTimeActivityPoint(
                frameIndex: frame.index,
                midSeconds: frame.midSeconds,
                durationSeconds: frame.durationSeconds,
                voxelCount: count,
                mean: sum / Double(count),
                max: maxValue,
                min: minValue,
                unit: unit
            )
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
