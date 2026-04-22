import Foundation

/// PET-specific quantification over a segmentation label map.
///
/// Provides the three numbers an oncologist wants out of a PET/CT lesion
/// mask:
///
///   • **TMTV** (total metabolic tumor volume) — sum of every lesion's
///     volume in mL. The #1 prognostic biomarker in lymphoma and a
///     secondary endpoint in most PERCIST-era trials.
///   • **TLG** (total lesion glycolysis) — `TMTV × mean SUV` across all
///     lesions, expressed in g·mL·SUV units. Captures both burden and
///     metabolic intensity.
///   • Per-lesion stats — SUV max/mean/peak, volume, bounding box — so a
///     reader can rank lesions and spot the "hottest" one.
///
/// This is a native Swift implementation, no external dependency. It
/// assumes the PET volume supplies either an `suvScaleFactor` on
/// `ImageVolume` or that the caller passes a `suvTransform` closure.
public enum PETQuantification {

    public enum QuantificationError: Swift.Error, LocalizedError {
        case gridMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .gridMismatch(let message):
                return "PET quantification grid mismatch: \(message)"
            }
        }
    }

    public struct LesionStats: Identifiable, Equatable {
        public let id: UInt16
        public let classID: UInt16
        public let className: String
        public let voxelCount: Int
        public let volumeMM3: Double
        public let volumeML: Double
        public let suvMax: Double
        public let suvMean: Double
        public let suvPeak: Double?
        public let tlg: Double   // volume (mL) × mean SUV
        public let bounds: (minZ: Int, maxZ: Int,
                            minY: Int, maxY: Int,
                            minX: Int, maxX: Int)

        public static func == (lhs: LesionStats, rhs: LesionStats) -> Bool {
            lhs.classID == rhs.classID
            && lhs.voxelCount == rhs.voxelCount
            && lhs.volumeMM3 == rhs.volumeMM3
            && lhs.suvMax == rhs.suvMax
            && lhs.suvMean == rhs.suvMean
            && lhs.tlg == rhs.tlg
        }
    }

    public struct Report {
        public let totalMetabolicTumorVolumeML: Double
        public let totalLesionGlycolysis: Double
        public let maxSUV: Double
        public let weightedMeanSUV: Double
        public let lesionCount: Int
        public let lesions: [LesionStats]

        /// Human-readable summary for a chat reply or clinical report.
        public var summary: String {
            guard lesionCount > 0 else {
                return "PET quantification: no lesions in the provided label map."
            }
            return """
            TMTV:  \(String(format: "%.1f", totalMetabolicTumorVolumeML)) mL
            TLG:   \(String(format: "%.1f", totalLesionGlycolysis)) mL·SUV
            SUVmax:       \(String(format: "%.2f", maxSUV))
            SUV mean (weighted by lesion volume): \(String(format: "%.2f", weightedMeanSUV))
            Lesions: \(lesionCount)
            """
        }
    }

    /// Compute TMTV/TLG and per-lesion stats.
    ///
    /// - Parameters:
    ///   - petVolume: the PET intensity volume. If it has an `suvScaleFactor`,
    ///     raw voxel values are converted to SUV automatically.
    ///   - labelMap: a segmentation mask whose voxel values are class IDs.
    ///     The same grid as `petVolume` is required.
    ///   - classes: which label IDs count as "lesion". Defaults to every
    ///     non-background class in `labelMap`.
    ///   - suvTransform: optional override for raw → SUV conversion. Wins
    ///     over `petVolume.suvScaleFactor` when supplied.
    ///   - connectedComponents: when true, every separate connected
    ///     component is treated as its own lesion and reported individually.
    ///     When false, each class id is reported as a single merged lesion.
    public static func compute(petVolume: ImageVolume,
                               labelMap: LabelMap,
                               classes: [UInt16]? = nil,
                               suvTransform: ((Double) -> Double)? = nil,
                               connectedComponents: Bool = true) throws -> Report {
        guard petVolume.width == labelMap.width,
              petVolume.height == labelMap.height,
              petVolume.depth == labelMap.depth else {
            throw QuantificationError.gridMismatch(
                "PET is \(petVolume.width)x\(petVolume.height)x\(petVolume.depth), label map is \(labelMap.width)x\(labelMap.height)x\(labelMap.depth). Load or resample the matching PET/label pair."
            )
        }

        let targets: Set<UInt16> = {
            if let classes { return Set(classes) }
            return Set(labelMap.classes.map(\.labelID))
        }()

        // Build the raw → SUV transform once.
        let transform: (Double) -> Double = {
            if let suvTransform { return suvTransform }
            if let scale = petVolume.suvScaleFactor { return { $0 * scale } }
            return { $0 }
        }()

        let voxelVolumeMM3 = petVolume.spacing.x * petVolume.spacing.y * petVolume.spacing.z

        var lesions: [LesionStats] = []
        if connectedComponents {
            lesions = computeConnectedComponents(
                petVolume: petVolume,
                labelMap: labelMap,
                targets: targets,
                voxelVolumeMM3: voxelVolumeMM3,
                transform: transform
            )
        } else {
            lesions = computeWholeClasses(
                petVolume: petVolume,
                labelMap: labelMap,
                targets: targets,
                voxelVolumeMM3: voxelVolumeMM3,
                transform: transform
            )
        }

        let totalVolume = lesions.reduce(0) { $0 + $1.volumeML }
        let tlg = lesions.reduce(0) { $0 + $1.tlg }
        let suvMax = lesions.map(\.suvMax).max() ?? 0
        let weighted = totalVolume > 0
            ? lesions.reduce(0) { $0 + $1.suvMean * $1.volumeML } / totalVolume
            : 0

        return Report(
            totalMetabolicTumorVolumeML: totalVolume,
            totalLesionGlycolysis: tlg,
            maxSUV: suvMax,
            weightedMeanSUV: weighted,
            lesionCount: lesions.count,
            lesions: lesions.sorted { $0.suvMax > $1.suvMax }
        )
    }

    // MARK: - Per-class merged

    private static func computeWholeClasses(petVolume: ImageVolume,
                                            labelMap: LabelMap,
                                            targets: Set<UInt16>,
                                            voxelVolumeMM3: Double,
                                            transform: (Double) -> Double) -> [LesionStats] {
        var perClass: [UInt16: (voxels: Int, suvMax: Double,
                                 suvSum: Double, minZ: Int, maxZ: Int,
                                 minY: Int, maxY: Int, minX: Int, maxX: Int)] = [:]

        let w = labelMap.width, h = labelMap.height, d = labelMap.depth
        for z in 0..<d {
            for y in 0..<h {
                let rowStart = z * h * w + y * w
                for x in 0..<w {
                    let cls = labelMap.voxels[rowStart + x]
                    guard targets.contains(cls), cls != 0 else { continue }
                    let suv = transform(Double(petVolume.pixels[rowStart + x]))
                    var entry = perClass[cls] ?? (0, -Double.infinity, 0,
                                                  d, -1, h, -1, w, -1)
                    entry.voxels += 1
                    entry.suvMax = max(entry.suvMax, suv)
                    entry.suvSum += suv
                    entry.minZ = min(entry.minZ, z); entry.maxZ = max(entry.maxZ, z)
                    entry.minY = min(entry.minY, y); entry.maxY = max(entry.maxY, y)
                    entry.minX = min(entry.minX, x); entry.maxX = max(entry.maxX, x)
                    perClass[cls] = entry
                }
            }
        }

        return perClass.map { (classID, entry) in
            let mm3 = Double(entry.voxels) * voxelVolumeMM3
            let mean = entry.voxels > 0 ? entry.suvSum / Double(entry.voxels) : 0
            let className = labelMap.classInfo(id: classID)?.name ?? "class_\(classID)"
            return LesionStats(
                id: classID,
                classID: classID,
                className: className,
                voxelCount: entry.voxels,
                volumeMM3: mm3,
                volumeML: mm3 / 1000,
                suvMax: entry.suvMax,
                suvMean: mean,
                suvPeak: entry.suvMax,
                tlg: (mm3 / 1000) * mean,
                bounds: (entry.minZ, entry.maxZ,
                         entry.minY, entry.maxY,
                         entry.minX, entry.maxX)
            )
        }
    }

    // MARK: - Connected-component BFS

    private static func computeConnectedComponents(petVolume: ImageVolume,
                                                   labelMap: LabelMap,
                                                   targets: Set<UInt16>,
                                                   voxelVolumeMM3: Double,
                                                   transform: (Double) -> Double) -> [LesionStats] {
        let w = labelMap.width, h = labelMap.height, d = labelMap.depth
        let voxelCount = w * h * d
        var visited = [Bool](repeating: false, count: voxelCount)
        var lesions: [LesionStats] = []
        var lesionID: UInt16 = 1

        for z in 0..<d {
            for y in 0..<h {
                for x in 0..<w {
                    let startIdx = z * h * w + y * w + x
                    let cls = labelMap.voxels[startIdx]
                    guard !visited[startIdx], targets.contains(cls), cls != 0 else { continue }

                    var stack: [(Int, Int, Int)] = [(z, y, x)]
                    visited[startIdx] = true
                    var voxels = 0
                    var suvMax = -Double.infinity
                    var suvSum = 0.0
                    var minZ = z, maxZ = z, minY = y, maxY = y, minX = x, maxX = x

                    while let (cz, cy, cx) = stack.popLast() {
                        voxels += 1
                        let idx = cz * h * w + cy * w + cx
                        let suv = transform(Double(petVolume.pixels[idx]))
                        if suv > suvMax { suvMax = suv }
                        suvSum += suv
                        if cz < minZ { minZ = cz }
                        if cz > maxZ { maxZ = cz }
                        if cy < minY { minY = cy }
                        if cy > maxY { maxY = cy }
                        if cx < minX { minX = cx }
                        if cx > maxX { maxX = cx }

                        // 6-neighborhood; same class id required.
                        let neighbors: [(Int, Int, Int)] = [
                            (cz - 1, cy, cx), (cz + 1, cy, cx),
                            (cz, cy - 1, cx), (cz, cy + 1, cx),
                            (cz, cy, cx - 1), (cz, cy, cx + 1),
                        ]
                        for (nz, ny, nx) in neighbors {
                            guard nz >= 0, nz < d,
                                  ny >= 0, ny < h,
                                  nx >= 0, nx < w else { continue }
                            let nIdx = nz * h * w + ny * w + nx
                            if !visited[nIdx], labelMap.voxels[nIdx] == cls {
                                visited[nIdx] = true
                                stack.append((nz, ny, nx))
                            }
                        }
                    }

                    let mm3 = Double(voxels) * voxelVolumeMM3
                    let mean = voxels > 0 ? suvSum / Double(voxels) : 0
                    let baseName = labelMap.classInfo(id: cls)?.name ?? "lesion"
                    lesions.append(LesionStats(
                        id: lesionID,
                        classID: cls,
                        className: "\(baseName) #\(lesionID)",
                        voxelCount: voxels,
                        volumeMM3: mm3,
                        volumeML: mm3 / 1000,
                        suvMax: suvMax,
                        suvMean: mean,
                        suvPeak: suvMax,
                        tlg: (mm3 / 1000) * mean,
                        bounds: (minZ, maxZ, minY, maxY, minX, maxX)
                    ))
                    lesionID &+= 1
                }
            }
        }
        return lesions
    }
}
