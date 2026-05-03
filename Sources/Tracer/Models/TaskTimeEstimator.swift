import Foundation

public enum TaskTimeEstimateSource: String, Sendable {
    case measuredProgress
    case predictedFromTaskKind
    case estimating
}

public struct TaskTimeEstimate: Equatable, Sendable {
    public let source: TaskTimeEstimateSource
    public let elapsed: TimeInterval
    public let displayProgress: Double?
    public let estimatedRemaining: TimeInterval?
    public let estimatedTotal: TimeInterval?
    public let expectedRange: ClosedRange<TimeInterval>?

    public var summaryLabel: String {
        switch source {
        case .measuredProgress:
            guard let estimatedRemaining, let estimatedTotal else {
                return "Finishing"
            }
            return "\(TaskTimeEstimator.durationLabel(estimatedRemaining)) left · \(TaskTimeEstimator.durationLabel(estimatedTotal)) total est."
        case .predictedFromTaskKind:
            guard let expectedRange else {
                return "\(TaskTimeEstimator.durationLabel(elapsed)) elapsed"
            }
            if let estimatedRemaining, estimatedRemaining > 1 {
                return "~\(TaskTimeEstimator.durationLabel(estimatedRemaining)) left · expected \(TaskTimeEstimator.rangeLabel(expectedRange))"
            }
            return "Running longer than expected · \(TaskTimeEstimator.durationLabel(elapsed)) elapsed"
        case .estimating:
            return "Estimating · \(TaskTimeEstimator.durationLabel(elapsed)) elapsed"
        }
    }

    public var progressLabel: String {
        guard let displayProgress else { return "…" }
        return "\(Int((displayProgress * 100).rounded()))%"
    }
}

public enum TaskTimeEstimator {
    public static func estimate(kind: JobKind,
                                progress: Double?,
                                startedAt: Date?,
                                now: Date = Date()) -> TaskTimeEstimate {
        let elapsed = max(0, startedAt.map { now.timeIntervalSince($0) } ?? 0)
        let clampedProgress = progress.map { min(max($0, 0), 1) }

        if let clampedProgress, clampedProgress > 0.01, clampedProgress < 1 {
            let estimatedTotal = max(elapsed / clampedProgress, elapsed)
            let remaining = max(0, estimatedTotal - elapsed)
            return TaskTimeEstimate(source: .measuredProgress,
                                    elapsed: elapsed,
                                    displayProgress: clampedProgress,
                                    estimatedRemaining: remaining,
                                    estimatedTotal: estimatedTotal,
                                    expectedRange: nil)
        }

        if let clampedProgress, clampedProgress >= 1 {
            return TaskTimeEstimate(source: .measuredProgress,
                                    elapsed: elapsed,
                                    displayProgress: 1,
                                    estimatedRemaining: 0,
                                    estimatedTotal: elapsed,
                                    expectedRange: nil)
        }

        guard let range = expectedDurationRange(for: kind) else {
            return TaskTimeEstimate(source: .estimating,
                                    elapsed: elapsed,
                                    displayProgress: nil,
                                    estimatedRemaining: nil,
                                    estimatedTotal: nil,
                                    expectedRange: nil)
        }

        let midpoint = (range.lowerBound + range.upperBound) / 2
        let predictedProgress: Double
        if midpoint <= 0 {
            predictedProgress = 0.05
        } else {
            predictedProgress = min(max(elapsed / midpoint, 0.03), 0.94)
        }
        let remaining = max(0, midpoint - elapsed)
        return TaskTimeEstimate(source: .predictedFromTaskKind,
                                elapsed: elapsed,
                                displayProgress: predictedProgress,
                                estimatedRemaining: remaining,
                                estimatedTotal: midpoint,
                                expectedRange: range)
    }

    public static func expectedDurationRange(for kind: JobKind) -> ClosedRange<TimeInterval>? {
        switch kind {
        case .viewer: return 5...45
        case .pacsIndexing: return 60...600
        case .studyLoading: return 10...90
        case .volumeOperation: return 20...240
        case .monai: return 30...300
        case .nnunet: return 120...1_800
        case .petEngine: return 90...1_500
        case .classification: return 10...120
        case .cohort: return 300...3_600
        case .lesionDetection: return 60...480
        case .petAC: return 60...600
        case .reconstruction: return 20...300
        case .syntheticCT: return 60...600
        case .dosimetry: return 30...600
        case .modelDownload: return 60...3_600
        case .modelVerification: return 20...300
        case .brainPETReference: return 30...300
        case .unknown: return 30...300
        }
    }

    public static func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 {
            let remainder = seconds % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    public static func rangeLabel(_ range: ClosedRange<TimeInterval>) -> String {
        "\(durationLabel(range.lowerBound))-\(durationLabel(range.upperBound))"
    }
}
