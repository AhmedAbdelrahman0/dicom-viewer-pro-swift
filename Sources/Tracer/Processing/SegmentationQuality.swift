import Foundation

public struct SegmentationQualityReport: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case pass
        case warning
        case fail

        public var displayName: String {
            switch self {
            case .pass: return "Pass"
            case .warning: return "Warning"
            case .fail: return "Fail"
            }
        }
    }

    public let status: Status
    public let totalVoxelCount: Int
    public let nonzeroVoxelCount: Int
    public let occupiedPercent: Double
    public let classCount: Int
    public let componentCount: Int
    public let largestComponentVoxelCount: Int
    public let largestComponentML: Double
    public let tinyComponentCount: Int
    public let edgeTouchingComponentCount: Int
    public let missingClassIDs: [UInt16]
    public let undeclaredClassIDs: [UInt16]
    public let warnings: [String]

    public var compactSummary: String {
        let percent = String(format: "%.2f%%", occupiedPercent)
        return "\(status.displayName): \(nonzeroVoxelCount) voxels, \(componentCount) component(s), \(percent) occupied"
    }

    public func metadata(prefix: String = "qa") -> [String: String] {
        [
            "\(prefix).status": status.rawValue,
            "\(prefix).summary": compactSummary,
            "\(prefix).nonzeroVoxelCount": "\(nonzeroVoxelCount)",
            "\(prefix).occupiedPercent": String(format: "%.4f", occupiedPercent),
            "\(prefix).classCount": "\(classCount)",
            "\(prefix).componentCount": "\(componentCount)",
            "\(prefix).largestComponentML": String(format: "%.4f", largestComponentML),
            "\(prefix).tinyComponentCount": "\(tinyComponentCount)",
            "\(prefix).edgeTouchingComponentCount": "\(edgeTouchingComponentCount)",
            "\(prefix).missingClassIDs": missingClassIDs.map(String.init).joined(separator: ","),
            "\(prefix).undeclaredClassIDs": undeclaredClassIDs.map(String.init).joined(separator: ","),
            "\(prefix).warnings": warnings.joined(separator: " | ")
        ]
    }
}

public enum SegmentationQuality {
    public static func analyze(labelMap: LabelMap,
                               referenceVolume: ImageVolume? = nil,
                               tinyVoxelThreshold: Int = 3,
                               tinyVolumeMLThreshold: Double = 0.01) -> SegmentationQualityReport {
        let total = labelMap.width * labelMap.height * labelMap.depth
        let declaredIDs = Set(labelMap.classes.map(\.labelID).filter { $0 != 0 })
        let counts = labelMap.voxelCounts()
        let classIDs = Set(counts.keys)
        let nonzero = counts.values.reduce(0, +)
        let occupied = total > 0 ? 100.0 * Double(nonzero) / Double(total) : 0
        let voxelVolumeMM3 = referenceVolume.map {
            $0.spacing.x * $0.spacing.y * $0.spacing.z
        } ?? 1
        let tinyByVolume = tinyVolumeMLThreshold > 0 && voxelVolumeMM3 > 0
            ? Int(ceil((tinyVolumeMLThreshold * 1000.0) / voxelVolumeMM3))
            : 0
        let tinyLimit = max(tinyVoxelThreshold, tinyByVolume)
        let componentSummary = connectedComponentSummary(labelMap: labelMap,
                                                         tinyLimit: tinyLimit)

        let missing = declaredIDs.subtracting(classIDs).sorted()
        let undeclared = classIDs.subtracting(declaredIDs).sorted()
        var warnings: [String] = []
        var status: SegmentationQualityReport.Status = .pass

        if let referenceVolume,
           referenceVolume.width != labelMap.width ||
            referenceVolume.height != labelMap.height ||
            referenceVolume.depth != labelMap.depth {
            warnings.append("Reference image and label map dimensions differ.")
            status = .fail
        }
        if nonzero == 0 {
            warnings.append("Label map is empty.")
            status = .fail
        }
        if !missing.isEmpty {
            warnings.append("Declared classes with no voxels: \(missing.map(String.init).joined(separator: ", ")).")
            if status != .fail { status = .warning }
        }
        if !undeclared.isEmpty {
            warnings.append("Voxels use class IDs missing from the class table: \(undeclared.map(String.init).joined(separator: ", ")).")
            if status != .fail { status = .warning }
        }
        if componentSummary.tinyComponentCount > 0 {
            warnings.append("\(componentSummary.tinyComponentCount) tiny component(s) may be islands or brush debris.")
            if status != .fail { status = .warning }
        }
        if componentSummary.edgeTouchingComponentCount > 0 {
            warnings.append("\(componentSummary.edgeTouchingComponentCount) component(s) touch the volume edge.")
            if status != .fail { status = .warning }
        }
        if occupied > 80 {
            warnings.append("More than 80% of the image is labeled; confirm this is not an inverted mask.")
            if status != .fail { status = .warning }
        }

        return SegmentationQualityReport(
            status: status,
            totalVoxelCount: total,
            nonzeroVoxelCount: nonzero,
            occupiedPercent: occupied,
            classCount: declaredIDs.count,
            componentCount: componentSummary.componentCount,
            largestComponentVoxelCount: componentSummary.largestComponentVoxelCount,
            largestComponentML: Double(componentSummary.largestComponentVoxelCount) * voxelVolumeMM3 / 1000.0,
            tinyComponentCount: componentSummary.tinyComponentCount,
            edgeTouchingComponentCount: componentSummary.edgeTouchingComponentCount,
            missingClassIDs: missing,
            undeclaredClassIDs: undeclared,
            warnings: warnings
        )
    }

    private struct ComponentSummary {
        var componentCount = 0
        var largestComponentVoxelCount = 0
        var tinyComponentCount = 0
        var edgeTouchingComponentCount = 0
    }

    private static func connectedComponentSummary(labelMap: LabelMap,
                                                  tinyLimit: Int) -> ComponentSummary {
        let w = labelMap.width
        let h = labelMap.height
        let d = labelMap.depth
        let total = w * h * d
        guard total == labelMap.voxels.count, total > 0 else { return ComponentSummary() }

        var visited = [UInt8](repeating: 0, count: total)
        var queue: [Int] = []
        queue.reserveCapacity(1024)
        var summary = ComponentSummary()

        for start in 0..<total {
            let classID = labelMap.voxels[start]
            guard classID != 0, visited[start] == 0 else { continue }

            visited[start] = 1
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var readIndex = 0
            var voxels = 0
            var touchesEdge = false

            while readIndex < queue.count {
                let idx = queue[readIndex]
                readIndex += 1
                voxels += 1

                let x = idx % w
                let y = (idx / w) % h
                let z = idx / (w * h)
                if x == 0 || x == w - 1 || y == 0 || y == h - 1 || z == 0 || z == d - 1 {
                    touchesEdge = true
                }

                visitNeighbor(idx - 1, classID: classID, enabled: x > 0, labelMap: labelMap, visited: &visited, queue: &queue)
                visitNeighbor(idx + 1, classID: classID, enabled: x + 1 < w, labelMap: labelMap, visited: &visited, queue: &queue)
                visitNeighbor(idx - w, classID: classID, enabled: y > 0, labelMap: labelMap, visited: &visited, queue: &queue)
                visitNeighbor(idx + w, classID: classID, enabled: y + 1 < h, labelMap: labelMap, visited: &visited, queue: &queue)
                visitNeighbor(idx - w * h, classID: classID, enabled: z > 0, labelMap: labelMap, visited: &visited, queue: &queue)
                visitNeighbor(idx + w * h, classID: classID, enabled: z + 1 < d, labelMap: labelMap, visited: &visited, queue: &queue)
            }

            summary.componentCount += 1
            summary.largestComponentVoxelCount = max(summary.largestComponentVoxelCount, voxels)
            if voxels < tinyLimit {
                summary.tinyComponentCount += 1
            }
            if touchesEdge {
                summary.edgeTouchingComponentCount += 1
            }
        }

        return summary
    }

    private static func visitNeighbor(_ idx: Int,
                                      classID: UInt16,
                                      enabled: Bool,
                                      labelMap: LabelMap,
                                      visited: inout [UInt8],
                                      queue: inout [Int]) {
        guard enabled,
              visited[idx] == 0,
              labelMap.voxels[idx] == classID else { return }
        visited[idx] = 1
        queue.append(idx)
    }
}
