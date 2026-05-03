import Foundation

/// Lightweight PET-specific cleanup for AI lesion masks.
///
/// This ports the useful part of a prior "SUV attention" workflow:
/// keep connected lesion components only when they contain enough SUV signal
/// and enough physical volume. Anatomy-based suppression remains separate
/// because it requires a CT organ map.
public enum PETLesionPostprocessor {

    public enum PostprocessError: Error, LocalizedError {
        case gridMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .gridMismatch(let message):
                return "PET lesion postprocess grid mismatch: \(message)"
            }
        }
    }

    public struct Result: Hashable, Sendable {
        public let keptComponents: Int
        public let removedComponents: Int
        public let keptVoxels: Int
        public let removedVoxels: Int
        public let minimumSUV: Double
        public let minimumVolumeML: Double
    }

    @discardableResult
    public static func filterComponentsBySUV(labelMap: LabelMap,
                                             petSUVVolume: ImageVolume,
                                             classID: UInt16 = 1,
                                             minimumSUV: Double = 2.5,
                                             minimumVolumeML: Double = 0.5) throws -> Result {
        guard labelMap.width == petSUVVolume.width,
              labelMap.height == petSUVVolume.height,
              labelMap.depth == petSUVVolume.depth,
              labelMap.voxels.count == petSUVVolume.pixels.count else {
            throw PostprocessError.gridMismatch(
                "label map is \(labelMap.width)x\(labelMap.height)x\(labelMap.depth), PET SUV volume is \(petSUVVolume.width)x\(petSUVVolume.height)x\(petSUVVolume.depth)."
            )
        }

        let width = labelMap.width
        let height = labelMap.height
        let depth = labelMap.depth
        let plane = width * height
        let voxelVolumeML = petSUVVolume.spacing.x * petSUVVolume.spacing.y * petSUVVolume.spacing.z / 1000.0
        let totalCount = labelMap.voxels.count

        var output = labelMap.voxels
        var visited = [Bool](repeating: false, count: totalCount)
        var queue: [Int] = []
        var component: [Int] = []
        queue.reserveCapacity(4096)
        component.reserveCapacity(4096)

        var keptComponents = 0
        var removedComponents = 0
        var keptVoxels = 0
        var removedVoxels = 0

        for seed in 0..<totalCount where output[seed] == classID && !visited[seed] {
            queue.removeAll(keepingCapacity: true)
            component.removeAll(keepingCapacity: true)
            visited[seed] = true
            queue.append(seed)
            var head = 0
            var maxSUV = -Double.greatestFiniteMagnitude

            while head < queue.count {
                let idx = queue[head]
                head += 1
                component.append(idx)
                maxSUV = max(maxSUV, Double(petSUVVolume.pixels[idx]))

                let z = idx / plane
                let remainder = idx - z * plane
                let y = remainder / width
                let x = remainder - y * width

                appendNeighbor(idx - 1, enabled: x > 0, output: output, visited: &visited, classID: classID, queue: &queue)
                appendNeighbor(idx + 1, enabled: x < width - 1, output: output, visited: &visited, classID: classID, queue: &queue)
                appendNeighbor(idx - width, enabled: y > 0, output: output, visited: &visited, classID: classID, queue: &queue)
                appendNeighbor(idx + width, enabled: y < height - 1, output: output, visited: &visited, classID: classID, queue: &queue)
                appendNeighbor(idx - plane, enabled: z > 0, output: output, visited: &visited, classID: classID, queue: &queue)
                appendNeighbor(idx + plane, enabled: z < depth - 1, output: output, visited: &visited, classID: classID, queue: &queue)
            }

            let volumeML = Double(component.count) * voxelVolumeML
            let keep = maxSUV >= minimumSUV && volumeML >= minimumVolumeML
            if keep {
                keptComponents += 1
                keptVoxels += component.count
            } else {
                removedComponents += 1
                removedVoxels += component.count
                for idx in component {
                    output[idx] = 0
                }
            }
        }

        if output != labelMap.voxels {
            labelMap.voxels = output
            labelMap.objectWillChange.send()
        }

        return Result(
            keptComponents: keptComponents,
            removedComponents: removedComponents,
            keptVoxels: keptVoxels,
            removedVoxels: removedVoxels,
            minimumSUV: minimumSUV,
            minimumVolumeML: minimumVolumeML
        )
    }

    private static func appendNeighbor(_ idx: Int,
                                       enabled: Bool,
                                       output: [UInt16],
                                       visited: inout [Bool],
                                       classID: UInt16,
                                       queue: inout [Int]) {
        guard enabled, !visited[idx], output[idx] == classID else { return }
        visited[idx] = true
        queue.append(idx)
    }
}
