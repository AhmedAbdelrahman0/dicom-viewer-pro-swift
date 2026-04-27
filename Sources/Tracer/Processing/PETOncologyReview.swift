import Foundation

public struct PETOncologyReview: Codable, Equatable, Sendable {
    public struct TargetLesion: Identifiable, Codable, Equatable, Sendable {
        public let id: Int
        public let classID: UInt16
        public let className: String
        public let volumeML: Double
        public let suvMax: Double
        public let suvMean: Double
        public let suvPeak: Double?
        public let tlg: Double
        public let longestAxisMM: Double
        public let boundsDescription: String

        public var compactSummary: String {
            let peak = suvPeak.map { String(format: ", peak %.2f", $0) } ?? ""
            return String(
                format: "%@ %.2f mL, SUVmax %.2f, mean %.2f%@, %.1f mm",
                className,
                volumeML,
                suvMax,
                suvMean,
                peak,
                longestAxisMM
            )
        }
    }

    public struct WorkflowFlag: Identifiable, Codable, Equatable, Sendable {
        public enum Severity: String, Codable, Equatable, Sendable {
            case info
            case review
            case highPriority
        }

        public let id: String
        public let severity: Severity
        public let title: String
        public let detail: String
    }

    public let totalMetabolicTumorVolumeML: Double
    public let totalLesionGlycolysis: Double
    public let maxSUV: Double
    public let weightedMeanSUV: Double
    public let lesionCount: Int
    public let targetLesions: [TargetLesion]
    public let workflowFlags: [WorkflowFlag]

    public var summary: String {
        guard lesionCount > 0 else {
            return "No non-background PET lesions in the active label map."
        }
        return String(
            format: "TMTV %.1f mL, TLG %.1f, SUVmax %.2f, %d lesion%@",
            totalMetabolicTumorVolumeML,
            totalLesionGlycolysis,
            maxSUV,
            lesionCount,
            lesionCount == 1 ? "" : "s"
        )
    }

    public static func build(from report: PETQuantification.Report,
                             petVolume: ImageVolume,
                             targetCount: Int = 5) -> PETOncologyReview {
        let targetLesions = report.lesions
            .sorted { lhs, rhs in
                if lhs.suvMax != rhs.suvMax { return lhs.suvMax > rhs.suvMax }
                return lhs.volumeML > rhs.volumeML
            }
            .prefix(max(1, targetCount))
            .enumerated()
            .map { offset, lesion in
                TargetLesion(
                    id: offset + 1,
                    classID: lesion.classID,
                    className: lesion.className,
                    volumeML: lesion.volumeML,
                    suvMax: lesion.suvMax,
                    suvMean: lesion.suvMean,
                    suvPeak: lesion.suvPeak,
                    tlg: lesion.tlg,
                    longestAxisMM: longestAxisMM(for: lesion, spacing: petVolume.spacing),
                    boundsDescription: boundsDescription(for: lesion)
                )
            }

        return PETOncologyReview(
            totalMetabolicTumorVolumeML: report.totalMetabolicTumorVolumeML,
            totalLesionGlycolysis: report.totalLesionGlycolysis,
            maxSUV: report.maxSUV,
            weightedMeanSUV: report.weightedMeanSUV,
            lesionCount: report.lesionCount,
            targetLesions: Array(targetLesions),
            workflowFlags: workflowFlags(for: report, targetLesions: Array(targetLesions))
        )
    }

    private static func longestAxisMM(for lesion: PETQuantification.LesionStats,
                                      spacing: (x: Double, y: Double, z: Double)) -> Double {
        let x = Double(lesion.bounds.maxX - lesion.bounds.minX + 1) * spacing.x
        let y = Double(lesion.bounds.maxY - lesion.bounds.minY + 1) * spacing.y
        let z = Double(lesion.bounds.maxZ - lesion.bounds.minZ + 1) * spacing.z
        return max(x, y, z)
    }

    private static func boundsDescription(for lesion: PETQuantification.LesionStats) -> String {
        "z\(lesion.bounds.minZ)-\(lesion.bounds.maxZ) y\(lesion.bounds.minY)-\(lesion.bounds.maxY) x\(lesion.bounds.minX)-\(lesion.bounds.maxX)"
    }

    private static func workflowFlags(for report: PETQuantification.Report,
                                      targetLesions: [TargetLesion]) -> [WorkflowFlag] {
        guard report.lesionCount > 0 else {
            return [
                WorkflowFlag(
                    id: "empty-label",
                    severity: .info,
                    title: "No lesion burden",
                    detail: "The current label map has no non-background PET lesions."
                )
            ]
        }

        var flags: [WorkflowFlag] = []
        if report.lesionCount <= 5 {
            flags.append(WorkflowFlag(
                id: "oligometastatic-count",
                severity: .review,
                title: "Oligometastatic-count review",
                detail: "Five or fewer connected PET lesions are present; review target-lesion eligibility."
            ))
        }
        if report.totalMetabolicTumorVolumeML >= 100 || report.lesionCount >= 10 {
            flags.append(WorkflowFlag(
                id: "high-volume",
                severity: .highPriority,
                title: "High-volume disease review",
                detail: "TMTV or lesion count is high enough to warrant careful burden verification."
            ))
        }
        if let bulky = targetLesions.first(where: { $0.longestAxisMM >= 50 }) {
            flags.append(WorkflowFlag(
                id: "bulky-target",
                severity: .review,
                title: "Bulky target review",
                detail: "\(bulky.className) measures \(String(format: "%.1f", bulky.longestAxisMM)) mm on its longest voxel-box axis."
            ))
        }
        if report.maxSUV >= 10 {
            flags.append(WorkflowFlag(
                id: "high-uptake",
                severity: .review,
                title: "High-uptake target review",
                detail: "SUVmax is \(String(format: "%.2f", report.maxSUV)); confirm windowing, SUV scaling, and lesion boundary."
            ))
        }
        return flags
    }
}
