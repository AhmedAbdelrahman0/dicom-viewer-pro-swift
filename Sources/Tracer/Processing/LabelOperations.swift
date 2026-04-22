import Foundation

public enum LabelLogicalOperation: String, CaseIterable, Identifiable {
    case union
    case subtract
    case intersect
    case replace

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .union: return "Union"
        case .subtract: return "Subtract"
        case .intersect: return "Intersect"
        case .replace: return "Replace"
        }
    }
}

public enum LabelOperations {
    @discardableResult
    public static func keepLargestIsland(label: LabelMap, classID: UInt16) -> Int {
        let components = connectedComponents(label: label, classID: classID)
        guard let largest = components.max(by: { $0.count < $1.count }) else { return 0 }
        var keep = [Bool](repeating: false, count: label.voxels.count)
        for idx in largest { keep[idx] = true }

        var removed = 0
        for i in 0..<label.voxels.count where label.voxels[i] == classID && !keep[i] {
            label.voxels[i] = 0
            removed += 1
        }
        return removed
    }

    @discardableResult
    public static func removeSmallIslands(label: LabelMap,
                                          classID: UInt16,
                                          minVoxels: Int) -> Int {
        let threshold = max(1, minVoxels)
        let components = connectedComponents(label: label, classID: classID)
        var removed = 0
        for component in components where component.count < threshold {
            for idx in component {
                label.voxels[idx] = 0
                removed += 1
            }
        }
        return removed
    }

    @discardableResult
    public static func logical(label: LabelMap,
                               targetID: UInt16,
                               modifierID: UInt16,
                               operation: LabelLogicalOperation) -> Int {
        guard targetID != 0, modifierID != 0, targetID != modifierID else { return 0 }
        var changed = 0

        switch operation {
        case .union:
            for i in 0..<label.voxels.count where label.voxels[i] == modifierID {
                label.voxels[i] = targetID
                changed += 1
            }

        case .subtract:
            // In the current exclusive-labelmap model two classes cannot occupy
            // the same voxel, so target minus modifier is already unchanged.
            break

        case .intersect:
            for i in 0..<label.voxels.count where label.voxels[i] == targetID {
                label.voxels[i] = 0
                changed += 1
            }

        case .replace:
            for i in 0..<label.voxels.count {
                if label.voxels[i] == targetID {
                    label.voxels[i] = 0
                    changed += 1
                } else if label.voxels[i] == modifierID {
                    label.voxels[i] = targetID
                    changed += 1
                }
            }
        }

        return changed
    }

    private static func connectedComponents(label: LabelMap, classID: UInt16) -> [[Int]] {
        guard classID != 0 else { return [] }
        var visited = [Bool](repeating: false, count: label.voxels.count)
        var components: [[Int]] = []

        for idx in 0..<label.voxels.count {
            guard label.voxels[idx] == classID, !visited[idx] else { continue }
            var component: [Int] = []
            var queue: [Int] = [idx]
            visited[idx] = true

            while let current = queue.popLast() {
                component.append(current)
                for neighbor in neighbors(of: current, in: label) {
                    guard !visited[neighbor], label.voxels[neighbor] == classID else { continue }
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }

            components.append(component)
        }

        return components
    }

    private static func neighbors(of index: Int, in label: LabelMap) -> [Int] {
        let plane = label.width * label.height
        let z = index / plane
        let rem = index % plane
        let y = rem / label.width
        let x = rem % label.width

        var result: [Int] = []
        result.reserveCapacity(6)
        if z > 0 { result.append(index - plane) }
        if z + 1 < label.depth { result.append(index + plane) }
        if y > 0 { result.append(index - label.width) }
        if y + 1 < label.height { result.append(index + label.width) }
        if x > 0 { result.append(index - 1) }
        if x + 1 < label.width { result.append(index + 1) }
        return result
    }
}
