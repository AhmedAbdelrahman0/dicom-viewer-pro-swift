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

public enum LabelSmoothingMode: String, CaseIterable, Identifiable {
    case median
    case opening
    case closing

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .median: return "Median"
        case .opening: return "Opening"
        case .closing: return "Closing"
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

    @discardableResult
    public static func fillHoles(label: LabelMap, classID: UInt16) -> Int {
        guard classID != 0 else { return 0 }
        let original = label.voxels
        guard original.contains(classID) else { return 0 }
        var outside = [Bool](repeating: false, count: original.count)
        var queue: [Int] = []

        for idx in original.indices where isBorder(index: idx, in: label) && original[idx] == 0 {
            outside[idx] = true
            queue.append(idx)
        }

        while let current = queue.popLast() {
            for neighbor in neighbors(of: current, in: label) {
                guard !outside[neighbor], original[neighbor] == 0 else { continue }
                outside[neighbor] = true
                queue.append(neighbor)
            }
        }

        var changed = 0
        var voxels = original
        for idx in original.indices where original[idx] == 0 && !outside[idx] {
            voxels[idx] = classID
            changed += 1
        }
        label.voxels = voxels
        return changed
    }

    @discardableResult
    public static func hollow(label: LabelMap,
                              classID: UInt16,
                              thickness: Int = 1) -> Int {
        guard classID != 0 else { return 0 }
        let original = label.voxels
        var eroded = original
        for _ in 0..<max(1, thickness) {
            eroded = erodedOnce(eroded, label: label, classID: classID)
        }

        var voxels = original
        var removed = 0
        for idx in original.indices where original[idx] == classID && eroded[idx] == classID {
            voxels[idx] = 0
            removed += 1
        }
        label.voxels = voxels
        return removed
    }

    @discardableResult
    public static func smooth(label: LabelMap,
                              classID: UInt16,
                              mode: LabelSmoothingMode,
                              iterations: Int = 1) -> Int {
        guard classID != 0 else { return 0 }
        let original = label.voxels
        var voxels = original
        let passes = max(1, iterations)

        switch mode {
        case .median:
            for _ in 0..<passes {
                voxels = medianOnce(voxels, label: label, classID: classID)
            }
        case .opening:
            for _ in 0..<passes {
                voxels = erodedOnce(voxels, label: label, classID: classID)
            }
            for _ in 0..<passes {
                voxels = dilatedOnce(voxels, label: label, classID: classID)
            }
        case .closing:
            for _ in 0..<passes {
                voxels = dilatedOnce(voxels, label: label, classID: classID)
            }
            for _ in 0..<passes {
                voxels = erodedOnce(voxels, label: label, classID: classID)
            }
        }

        let changed = zip(original, voxels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        label.voxels = voxels
        return changed
    }

    @discardableResult
    public static func fillBetweenSlices(label: LabelMap,
                                         classID: UInt16,
                                         axis: Int = 2) -> Int {
        guard classID != 0 else { return 0 }
        let normalizedAxis = min(2, max(0, axis))
        let count = sliceCount(axis: normalizedAxis, label: label)
        guard count >= 3 else { return 0 }

        let labeledSlices = (0..<count).filter {
            sliceContainsClass(label: label,
                               classID: classID,
                               axis: normalizedAxis,
                               sliceIndex: $0)
        }
        guard labeledSlices.count >= 2 else { return 0 }

        var changed = 0
        for pair in zip(labeledSlices.dropLast(), labeledSlices.dropFirst()) {
            let start = pair.0
            let end = pair.1
            guard end - start > 1 else { continue }

            let first = sliceMask(label: label,
                                  classID: classID,
                                  axis: normalizedAxis,
                                  sliceIndex: start)
            let second = sliceMask(label: label,
                                   classID: classID,
                                   axis: normalizedAxis,
                                   sliceIndex: end)
            let firstPhi = signedDistance(mask: first.values,
                                          width: first.width,
                                          height: first.height)
            let secondPhi = signedDistance(mask: second.values,
                                           width: second.width,
                                           height: second.height)

            for slice in (start + 1)..<end {
                let t = Double(slice - start) / Double(end - start)
                var interpolated = [Bool](repeating: false, count: first.values.count)
                for idx in interpolated.indices {
                    let phi = firstPhi[idx] * (1 - t) + secondPhi[idx] * t
                    interpolated[idx] = phi <= 0
                }
                changed += paintSlice(mask: interpolated,
                                      width: first.width,
                                      height: first.height,
                                      label: label,
                                      classID: classID,
                                      axis: normalizedAxis,
                                      sliceIndex: slice)
            }
        }
        return changed
    }

    public static func connectedComponents(label: LabelMap, classID: UInt16) -> [[Int]] {
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

    private static func erodedOnce(_ input: [UInt16],
                                   label: LabelMap,
                                   classID: UInt16) -> [UInt16] {
        var voxels = input
        for idx in input.indices where input[idx] == classID {
            let neighbors = neighbors(of: idx, in: label)
            if neighbors.count < 6 || neighbors.contains(where: { input[$0] != classID }) {
                voxels[idx] = 0
            }
        }
        return voxels
    }

    private static func dilatedOnce(_ input: [UInt16],
                                    label: LabelMap,
                                    classID: UInt16) -> [UInt16] {
        var voxels = input
        for idx in input.indices where input[idx] == 0 {
            if neighbors(of: idx, in: label).contains(where: { input[$0] == classID }) {
                voxels[idx] = classID
            }
        }
        return voxels
    }

    private static func medianOnce(_ input: [UInt16],
                                   label: LabelMap,
                                   classID: UInt16) -> [UInt16] {
        var voxels = input
        for z in 0..<label.depth {
            for y in 0..<label.height {
                for x in 0..<label.width {
                    let idx = label.index(z: z, y: y, x: x)
                    guard input[idx] == 0 || input[idx] == classID else { continue }
                    var total = 0
                    var active = 0
                    for dz in -1...1 {
                        for dy in -1...1 {
                            for dx in -1...1 {
                                let nz = z + dz
                                let ny = y + dy
                                let nx = x + dx
                                guard nz >= 0, nz < label.depth,
                                      ny >= 0, ny < label.height,
                                      nx >= 0, nx < label.width else { continue }
                                total += 1
                                if input[label.index(z: nz, y: ny, x: nx)] == classID {
                                    active += 1
                                }
                            }
                        }
                    }
                    voxels[idx] = active * 2 >= total ? classID : 0
                }
            }
        }
        return voxels
    }

    private static func signedDistance(mask: [Bool],
                                       width: Int,
                                       height: Int) -> [Double] {
        let insideDistance = distanceMap(target: true, mask: mask, width: width, height: height)
        let outsideDistance = distanceMap(target: false, mask: mask, width: width, height: height)
        return mask.indices.map { idx in
            mask[idx] ? -outsideDistance[idx] : insideDistance[idx]
        }
    }

    private static func distanceMap(target: Bool,
                                    mask: [Bool],
                                    width: Int,
                                    height: Int) -> [Double] {
        let inf = Double(width * width + height * height + 1)
        var distance = mask.map { $0 == target ? 0.0 : inf }
        guard width > 0, height > 0 else { return distance }
        let diagonal = sqrt(2.0)

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if x > 0 {
                    distance[idx] = min(distance[idx], distance[idx - 1] + 1)
                }
                if y > 0 {
                    distance[idx] = min(distance[idx], distance[idx - width] + 1)
                    if x > 0 {
                        distance[idx] = min(distance[idx], distance[idx - width - 1] + diagonal)
                    }
                    if x + 1 < width {
                        distance[idx] = min(distance[idx], distance[idx - width + 1] + diagonal)
                    }
                }
            }
        }

        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) {
                let idx = y * width + x
                if x + 1 < width {
                    distance[idx] = min(distance[idx], distance[idx + 1] + 1)
                }
                if y + 1 < height {
                    distance[idx] = min(distance[idx], distance[idx + width] + 1)
                    if x + 1 < width {
                        distance[idx] = min(distance[idx], distance[idx + width + 1] + diagonal)
                    }
                    if x > 0 {
                        distance[idx] = min(distance[idx], distance[idx + width - 1] + diagonal)
                    }
                }
            }
        }

        return distance
    }

    private static func sliceCount(axis: Int, label: LabelMap) -> Int {
        switch axis {
        case 0: return label.width
        case 1: return label.height
        default: return label.depth
        }
    }

    private static func sliceContainsClass(label: LabelMap,
                                           classID: UInt16,
                                           axis: Int,
                                           sliceIndex: Int) -> Bool {
        sliceMask(label: label, classID: classID, axis: axis, sliceIndex: sliceIndex)
            .values
            .contains(true)
    }

    private static func sliceMask(label: LabelMap,
                                  classID: UInt16,
                                  axis: Int,
                                  sliceIndex: Int) -> (values: [Bool], width: Int, height: Int) {
        switch axis {
        case 0:
            var values = [Bool](repeating: false, count: label.height * label.depth)
            for z in 0..<label.depth {
                for y in 0..<label.height {
                    values[z * label.height + y] = label.value(z: z, y: y, x: sliceIndex) == classID
                }
            }
            return (values, label.height, label.depth)
        case 1:
            var values = [Bool](repeating: false, count: label.width * label.depth)
            for z in 0..<label.depth {
                for x in 0..<label.width {
                    values[z * label.width + x] = label.value(z: z, y: sliceIndex, x: x) == classID
                }
            }
            return (values, label.width, label.depth)
        default:
            var values = [Bool](repeating: false, count: label.width * label.height)
            for y in 0..<label.height {
                for x in 0..<label.width {
                    values[y * label.width + x] = label.value(z: sliceIndex, y: y, x: x) == classID
                }
            }
            return (values, label.width, label.height)
        }
    }

    private static func paintSlice(mask: [Bool],
                                   width: Int,
                                   height: Int,
                                   label: LabelMap,
                                   classID: UInt16,
                                   axis: Int,
                                   sliceIndex: Int) -> Int {
        var changed = 0
        func paint(z: Int, y: Int, x: Int) {
            guard z >= 0, z < label.depth,
                  y >= 0, y < label.height,
                  x >= 0, x < label.width else { return }
            let index = label.index(z: z, y: y, x: x)
            guard label.voxels[index] == 0 || label.voxels[index] == classID else { return }
            if label.voxels[index] != classID {
                label.voxels[index] = classID
                changed += 1
            }
        }

        for row in 0..<height {
            for col in 0..<width where mask[row * width + col] {
                switch axis {
                case 0: paint(z: row, y: col, x: sliceIndex)
                case 1: paint(z: row, y: sliceIndex, x: col)
                default: paint(z: sliceIndex, y: row, x: col)
                }
            }
        }
        return changed
    }

    private static func isBorder(index: Int, in label: LabelMap) -> Bool {
        let plane = label.width * label.height
        let z = index / plane
        let rem = index % plane
        let y = rem / label.width
        let x = rem % label.width
        let zBorder = label.depth > 1 && (z == 0 || z + 1 == label.depth)
        let yBorder = label.height > 1 && (y == 0 || y + 1 == label.height)
        let xBorder = label.width > 1 && (x == 0 || x + 1 == label.width)
        return zBorder || yBorder || xBorder
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
