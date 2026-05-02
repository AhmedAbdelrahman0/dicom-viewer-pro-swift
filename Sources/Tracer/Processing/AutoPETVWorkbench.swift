import Foundation

/// Research workbench utilities for building an AutoPET V winning pipeline.
///
/// The challenge runtime is intentionally small (`AutoPETVChallengeRunner`),
/// but model development needs more: official-style metrics, interaction AUC,
/// prompt-channel experiments, simulated corrective scribbles, and compact
/// failure summaries that a chatbot or reviewer can act on.
public enum AutoPETVWorkbench {
    public enum Error: Swift.Error, LocalizedError {
        case gridMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .gridMismatch(let message):
                return "AutoPET V workbench grid mismatch: \(message)"
            }
        }
    }

    public enum Connectivity: Sendable, Equatable {
        case six
        case eighteen
        case twentySix
    }

    public enum FailureTag: String, CaseIterable, Sendable {
        case missedLesions = "missed_lesions"
        case falsePositiveBurden = "false_positive_burden"
        case weakDetection = "weak_detection"
        case diceRegressionAfterScribble = "dice_regression_after_scribble"
        case dmmRegressionAfterScribble = "dmm_regression_after_scribble"
        case emptyPredictionWithLesions = "empty_prediction_with_lesions"
        case emptyGroundTruthFalsePositive = "empty_ground_truth_false_positive"
    }

    public struct TriageThresholds: Sendable, Equatable {
        public var highFalsePositiveVolumeML: Double
        public var highFalseNegativeVolumeML: Double
        public var lowDMM: Double
        public var regressionTolerance: Double

        public init(highFalsePositiveVolumeML: Double = 10,
                    highFalseNegativeVolumeML: Double = 10,
                    lowDMM: Double = 0.5,
                    regressionTolerance: Double = 0.01) {
            self.highFalsePositiveVolumeML = highFalsePositiveVolumeML
            self.highFalseNegativeVolumeML = highFalseNegativeVolumeML
            self.lowDMM = lowDMM
            self.regressionTolerance = regressionTolerance
        }
    }

    public struct StepMetrics: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let stepIndex: Int
        public let dice: Double?
        public let dmm: Double?
        public let truePositiveLesions: Int
        public let falsePositiveLesions: Int
        public let falseNegativeLesions: Int
        public let falsePositiveVolumeML: Double
        public let falseNegativeVolumeML: Double
        public let predictionLesions: Int
        public let referenceLesions: Int

        public var compactSummary: String {
            let diceText = dice.map { String(format: "%.3f", $0) } ?? "n/a"
            let dmmText = dmm.map { String(format: "%.3f", $0) } ?? "n/a"
            return "step \(stepIndex): Dice \(diceText), DMM \(dmmText), TP \(truePositiveLesions), FP \(falsePositiveLesions), FN \(falseNegativeLesions), FPV \(String(format: "%.1f", falsePositiveVolumeML)) mL, FNV \(String(format: "%.1f", falseNegativeVolumeML)) mL"
        }

        public static func == (lhs: StepMetrics, rhs: StepMetrics) -> Bool {
            lhs.stepIndex == rhs.stepIndex
            && lhs.dice == rhs.dice
            && lhs.dmm == rhs.dmm
            && lhs.truePositiveLesions == rhs.truePositiveLesions
            && lhs.falsePositiveLesions == rhs.falsePositiveLesions
            && lhs.falseNegativeLesions == rhs.falseNegativeLesions
            && lhs.falsePositiveVolumeML == rhs.falsePositiveVolumeML
            && lhs.falseNegativeVolumeML == rhs.falseNegativeVolumeML
            && lhs.predictionLesions == rhs.predictionLesions
            && lhs.referenceLesions == rhs.referenceLesions
        }
    }

    public struct InteractionReport: Equatable, Sendable {
        public let caseID: String
        public let steps: [StepMetrics]
        public let aucDice: Double?
        public let aucDMM: Double?
        public let failureTags: [FailureTag]
        public let assistantBrief: String
    }

    public struct ScribbleSimulationOptions: Sendable, Equatable {
        public var maximumForegroundScribbles: Int
        public var maximumBackgroundScribbles: Int
        public var preferHighestSUVVoxel: Bool

        public init(maximumForegroundScribbles: Int = 3,
                    maximumBackgroundScribbles: Int = 3,
                    preferHighestSUVVoxel: Bool = true) {
            self.maximumForegroundScribbles = maximumForegroundScribbles
            self.maximumBackgroundScribbles = maximumBackgroundScribbles
            self.preferHighestSUVVoxel = preferHighestSUVVoxel
        }
    }

    public static func evaluate(prediction: LabelMap,
                                groundTruth: LabelMap,
                                spacing: (x: Double, y: Double, z: Double),
                                stepIndex: Int = 0,
                                overlapThreshold: Double = 0.1,
                                connectivity: Connectivity = .eighteen) throws -> StepMetrics {
        try ensureMatchingGrid(prediction, groundTruth)
        let voxelVolumeML = spacing.x * spacing.y * spacing.z / 1000.0
        let predLabels = labelConnectedComponents(
            width: prediction.width,
            height: prediction.height,
            depth: prediction.depth,
            connectivity: connectivity
        ) { prediction.voxels[$0] != 0 }
        let gtLabels = labelConnectedComponents(
            width: groundTruth.width,
            height: groundTruth.height,
            depth: groundTruth.depth,
            connectivity: connectivity
        ) { groundTruth.voxels[$0] != 0 }

        var predVoxelCount = 0
        var gtVoxelCount = 0
        var intersection = 0
        var overlaps: [ComponentPair: Int] = [:]

        for i in prediction.voxels.indices {
            let inPrediction = prediction.voxels[i] != 0
            let inGroundTruth = groundTruth.voxels[i] != 0
            if inPrediction { predVoxelCount += 1 }
            if inGroundTruth { gtVoxelCount += 1 }
            if inPrediction && inGroundTruth { intersection += 1 }

            let predComponent = predLabels.labels[i]
            let gtComponent = gtLabels.labels[i]
            if predComponent > 0, gtComponent > 0 {
                overlaps[ComponentPair(gt: gtComponent, pred: predComponent), default: 0] += 1
            }
        }

        let dice: Double?
        if gtVoxelCount == 0 {
            dice = nil
        } else {
            dice = predVoxelCount + gtVoxelCount > 0
                ? 2.0 * Double(intersection) / Double(predVoxelCount + gtVoxelCount)
                : 0
        }

        var matchedGT = Set<Int>()
        var matchedPred = Set<Int>()
        var overlappingGT = Set<Int>()
        var overlappingPred = Set<Int>()

        for (pair, overlap) in overlaps {
            overlappingGT.insert(pair.gt)
            overlappingPred.insert(pair.pred)
            let gtCount = gtLabels.components[pair.gt - 1].voxelCount
            let predCount = predLabels.components[pair.pred - 1].voxelCount
            let union = gtCount + predCount - overlap
            guard union > 0 else { continue }
            let iou = Double(overlap) / Double(union)
            if iou >= overlapThreshold {
                matchedGT.insert(pair.gt)
                matchedPred.insert(pair.pred)
            }
        }

        let tp = matchedGT.count
        let fp = predLabels.components.count - matchedPred.count
        let fn = gtLabels.components.count - tp
        let dmm: Double?
        if tp + fn == 0 {
            dmm = nil
        } else if tp == 0 {
            dmm = 0
        } else {
            dmm = 2.0 * Double(tp) / Double(2 * tp + fp + fn)
        }

        let fpv = predLabels.components
            .filter { !overlappingPred.contains($0.id) }
            .reduce(0) { $0 + Double($1.voxelCount) * voxelVolumeML }
        let fnv = gtLabels.components
            .filter { !overlappingGT.contains($0.id) }
            .reduce(0) { $0 + Double($1.voxelCount) * voxelVolumeML }

        return StepMetrics(
            stepIndex: stepIndex,
            dice: dice,
            dmm: dmm,
            truePositiveLesions: tp,
            falsePositiveLesions: fp,
            falseNegativeLesions: fn,
            falsePositiveVolumeML: fpv,
            falseNegativeVolumeML: fnv,
            predictionLesions: predLabels.components.count,
            referenceLesions: gtLabels.components.count
        )
    }

    public static func interactionReport(caseID: String,
                                         predictions: [LabelMap],
                                         groundTruth: LabelMap,
                                         spacing: (x: Double, y: Double, z: Double),
                                         overlapThreshold: Double = 0.1,
                                         connectivity: Connectivity = .eighteen,
                                         triageThresholds: TriageThresholds = TriageThresholds()) throws -> InteractionReport {
        var steps: [StepMetrics] = []
        for (index, prediction) in predictions.enumerated() {
            steps.append(try evaluate(
                prediction: prediction,
                groundTruth: groundTruth,
                spacing: spacing,
                stepIndex: index,
                overlapThreshold: overlapThreshold,
                connectivity: connectivity
            ))
        }

        let tags = failureTags(for: steps, thresholds: triageThresholds)
        let report = InteractionReport(
            caseID: caseID,
            steps: steps,
            aucDice: normalizedAUC(steps.map(\.dice)),
            aucDMM: normalizedAUC(steps.map(\.dmm)),
            failureTags: tags,
            assistantBrief: assistantBrief(caseID: caseID, steps: steps, tags: tags)
        )
        return report
    }

    /// Build a clipped EDT-style prompt channel. Values are 1.0 at scribble
    /// voxels and decay linearly to 0.0 at `maxDistanceMM`.
    public static func makeEDTPromptChannel(reference: ImageVolume,
                                            points: [AutoPETVChallenge.VoxelPoint],
                                            name: String,
                                            maxDistanceMM: Double = 40) -> ImageVolume {
        guard !points.isEmpty, maxDistanceMM > 0 else {
            return AutoPETVChallenge.makeScribbleHeatmap(reference: reference, points: [], name: name)
        }

        let width = reference.width
        let height = reference.height
        let depth = reference.depth
        let spacing = reference.spacing
        let clampedPoints = points.compactMap { $0.clamped(to: reference) }
        var pixels = [Float](repeating: 0, count: reference.pixels.count)

        for z in 0..<depth {
            for y in 0..<height {
                let rowStart = z * height * width + y * width
                for x in 0..<width {
                    var best = Double.greatestFiniteMagnitude
                    for point in clampedPoints {
                        let dx = Double(x - point.x) * spacing.x
                        let dy = Double(y - point.y) * spacing.y
                        let dz = Double(z - point.z) * spacing.z
                        let distance = (dx * dx + dy * dy + dz * dz).squareRoot()
                        if distance < best { best = distance }
                    }
                    let value = max(0, 1.0 - best / maxDistanceMM)
                    pixels[rowStart + x] = Float(value)
                }
            }
        }

        return ImageVolume(
            pixels: pixels,
            depth: reference.depth,
            height: reference.height,
            width: reference.width,
            spacing: reference.spacing,
            origin: reference.origin,
            direction: reference.direction,
            modality: "OT",
            seriesUID: "autopetv:edt:\(name):\(UUID().uuidString)",
            studyUID: reference.studyUID,
            patientID: reference.patientID,
            patientName: reference.patientName,
            seriesDescription: name,
            studyDescription: reference.studyDescription
        )
    }

    public static func simulateCorrectiveScribbles(prediction: LabelMap,
                                                   groundTruth: LabelMap,
                                                   petSUVVolume: ImageVolume? = nil,
                                                   options: ScribbleSimulationOptions = ScribbleSimulationOptions(),
                                                   connectivity: Connectivity = .eighteen) throws -> AutoPETVChallenge.ScribbleSet {
        try ensureMatchingGrid(prediction, groundTruth)
        if let petSUVVolume {
            guard petSUVVolume.width == prediction.width,
                  petSUVVolume.height == prediction.height,
                  petSUVVolume.depth == prediction.depth,
                  petSUVVolume.pixels.count == prediction.voxels.count else {
                throw Error.gridMismatch(
                    "PET is \(petSUVVolume.width)x\(petSUVVolume.height)x\(petSUVVolume.depth), labels are \(prediction.width)x\(prediction.height)x\(prediction.depth)."
                )
            }
        }

        let foregroundErrors = collectComponents(
            width: prediction.width,
            height: prediction.height,
            depth: prediction.depth,
            connectivity: connectivity,
            petSUVVolume: petSUVVolume,
            preferHighestSUVVoxel: options.preferHighestSUVVoxel
        ) { idx in
            groundTruth.voxels[idx] != 0 && prediction.voxels[idx] == 0
        }
        let backgroundErrors = collectComponents(
            width: prediction.width,
            height: prediction.height,
            depth: prediction.depth,
            connectivity: connectivity,
            petSUVVolume: petSUVVolume,
            preferHighestSUVVoxel: options.preferHighestSUVVoxel
        ) { idx in
            prediction.voxels[idx] != 0 && groundTruth.voxels[idx] == 0
        }

        return AutoPETVChallenge.ScribbleSet(
            foreground: foregroundErrors
                .sorted(by: componentPriority)
                .prefix(max(0, options.maximumForegroundScribbles))
                .map(\.representative),
            background: backgroundErrors
                .sorted(by: componentPriority)
                .prefix(max(0, options.maximumBackgroundScribbles))
                .map(\.representative)
        )
    }

    public static func assistantBrief(caseID: String,
                                      steps: [StepMetrics],
                                      tags: [FailureTag]) -> String {
        guard let last = steps.last else {
            return "AutoPET V review for \(caseID): no interaction steps available."
        }

        let aucDice = normalizedAUC(steps.map(\.dice)).map { String(format: "%.3f", $0) } ?? "n/a"
        let aucDMM = normalizedAUC(steps.map(\.dmm)).map { String(format: "%.3f", $0) } ?? "n/a"
        let tagsText = tags.isEmpty ? "none" : tags.map(\.rawValue).joined(separator: ", ")
        let nextAction: String
        if tags.contains(.emptyPredictionWithLesions) || tags.contains(.missedLesions) {
            nextAction = "prioritize foreground scribbles on the largest/highest-SUV missed lesions and inspect small nodal/bone lesions."
        } else if tags.contains(.falsePositiveBurden) || tags.contains(.emptyGroundTruthFalsePositive) {
            nextAction = "prioritize background scribbles over physiologic uptake and review organ-suppression rules."
        } else if tags.contains(.diceRegressionAfterScribble) || tags.contains(.dmmRegressionAfterScribble) {
            nextAction = "debug prompt handling because a correction step worsened the interaction curve."
        } else {
            nextAction = "review boundary quality and preserve the current prompt strategy."
        }

        return """
        AutoPET V review for \(caseID)
        AUC-Dice: \(aucDice), AUC-DMM: \(aucDMM)
        Final: \(last.compactSummary)
        Tags: \(tagsText)
        Suggested next action: \(nextAction)
        """
    }

    public static func normalizedAUC(_ values: [Double?]) -> Double? {
        let points = values.enumerated().compactMap { index, value -> (x: Double, y: Double)? in
            guard let value, value.isFinite else { return nil }
            return (Double(index), value)
        }
        guard let first = points.first else { return nil }
        guard points.count > 1, let last = points.last, last.x > first.x else {
            return first.y
        }

        var area = 0.0
        for i in 1..<points.count {
            let previous = points[i - 1]
            let current = points[i]
            area += (current.x - previous.x) * (previous.y + current.y) / 2.0
        }
        return area / (last.x - first.x)
    }

    public static func failureTags(for steps: [StepMetrics],
                                   thresholds: TriageThresholds = TriageThresholds()) -> [FailureTag] {
        var tags = Set<FailureTag>()
        guard !steps.isEmpty else { return [] }

        for step in steps {
            if step.referenceLesions > 0, step.predictionLesions == 0 {
                tags.insert(.emptyPredictionWithLesions)
            }
            if step.referenceLesions == 0, step.predictionLesions > 0 {
                tags.insert(.emptyGroundTruthFalsePositive)
            }
            if step.falseNegativeLesions > 0 || step.falseNegativeVolumeML >= thresholds.highFalseNegativeVolumeML {
                tags.insert(.missedLesions)
            }
            if step.falsePositiveVolumeML >= thresholds.highFalsePositiveVolumeML || step.falsePositiveLesions > 0 {
                tags.insert(.falsePositiveBurden)
            }
            if let dmm = step.dmm, dmm < thresholds.lowDMM {
                tags.insert(.weakDetection)
            }
        }

        for i in 1..<steps.count {
            if let previous = steps[i - 1].dice,
               let current = steps[i].dice,
               current + thresholds.regressionTolerance < previous {
                tags.insert(.diceRegressionAfterScribble)
            }
            if let previous = steps[i - 1].dmm,
               let current = steps[i].dmm,
               current + thresholds.regressionTolerance < previous {
                tags.insert(.dmmRegressionAfterScribble)
            }
        }

        return FailureTag.allCases.filter { tags.contains($0) }
    }

    // MARK: - Private component helpers

    private struct ComponentPair: Hashable {
        let gt: Int
        let pred: Int
    }

    private struct ComponentStats: Equatable {
        let id: Int
        var voxelCount: Int
        var minZ: Int
        var maxZ: Int
        var minY: Int
        var maxY: Int
        var minX: Int
        var maxX: Int
    }

    private struct ComponentLabeling {
        var labels: [Int]
        var components: [ComponentStats]
    }

    private struct ScribbleComponent: Equatable {
        var voxelCount: Int
        var representative: AutoPETVChallenge.VoxelPoint
        var maxSUV: Double?
    }

    private static func ensureMatchingGrid(_ lhs: LabelMap, _ rhs: LabelMap) throws {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.depth == rhs.depth,
              lhs.voxels.count == rhs.voxels.count else {
            throw Error.gridMismatch(
                "prediction is \(lhs.width)x\(lhs.height)x\(lhs.depth), reference is \(rhs.width)x\(rhs.height)x\(rhs.depth)."
            )
        }
    }

    private static func labelConnectedComponents(width: Int,
                                                 height: Int,
                                                 depth: Int,
                                                 connectivity: Connectivity,
                                                 isForeground: (Int) -> Bool) -> ComponentLabeling {
        let total = width * height * depth
        let plane = width * height
        var labels = [Int](repeating: 0, count: total)
        var components: [ComponentStats] = []
        var queue: [Int] = []
        let offsets = neighborOffsets(connectivity)

        for seed in 0..<total where labels[seed] == 0 && isForeground(seed) {
            let componentID = components.count + 1
            let z = seed / plane
            let remainder = seed - z * plane
            let y = remainder / width
            let x = remainder - y * width
            var stats = ComponentStats(id: componentID,
                                       voxelCount: 0,
                                       minZ: z, maxZ: z,
                                       minY: y, maxY: y,
                                       minX: x, maxX: x)
            queue.removeAll(keepingCapacity: true)
            queue.append(seed)
            labels[seed] = componentID
            var head = 0

            while head < queue.count {
                let idx = queue[head]
                head += 1
                let cz = idx / plane
                let rem = idx - cz * plane
                let cy = rem / width
                let cx = rem - cy * width

                stats.voxelCount += 1
                stats.minZ = min(stats.minZ, cz); stats.maxZ = max(stats.maxZ, cz)
                stats.minY = min(stats.minY, cy); stats.maxY = max(stats.maxY, cy)
                stats.minX = min(stats.minX, cx); stats.maxX = max(stats.maxX, cx)

                for (dz, dy, dx) in offsets {
                    let nz = cz + dz
                    let ny = cy + dy
                    let nx = cx + dx
                    guard nz >= 0, nz < depth,
                          ny >= 0, ny < height,
                          nx >= 0, nx < width else { continue }
                    let nIdx = nz * plane + ny * width + nx
                    guard labels[nIdx] == 0, isForeground(nIdx) else { continue }
                    labels[nIdx] = componentID
                    queue.append(nIdx)
                }
            }

            components.append(stats)
        }

        return ComponentLabeling(labels: labels, components: components)
    }

    private static func collectComponents(width: Int,
                                          height: Int,
                                          depth: Int,
                                          connectivity: Connectivity,
                                          petSUVVolume: ImageVolume?,
                                          preferHighestSUVVoxel: Bool,
                                          isForeground: (Int) -> Bool) -> [ScribbleComponent] {
        let total = width * height * depth
        let plane = width * height
        var visited = [Bool](repeating: false, count: total)
        var queue: [Int] = []
        var components: [ScribbleComponent] = []
        let offsets = neighborOffsets(connectivity)

        for seed in 0..<total where !visited[seed] && isForeground(seed) {
            queue.removeAll(keepingCapacity: true)
            queue.append(seed)
            visited[seed] = true
            var head = 0
            var voxelCount = 0
            var sumX = 0
            var sumY = 0
            var sumZ = 0
            var indices: [Int] = []
            indices.reserveCapacity(256)
            var representativeIndex = seed
            var maxSUV: Double?

            while head < queue.count {
                let idx = queue[head]
                head += 1
                indices.append(idx)
                voxelCount += 1

                let z = idx / plane
                let remainder = idx - z * plane
                let y = remainder / width
                let x = remainder - y * width
                sumX += x; sumY += y; sumZ += z

                if preferHighestSUVVoxel, let petSUVVolume {
                    let suv = Double(petSUVVolume.pixels[idx])
                    if maxSUV == nil || suv > maxSUV! {
                        maxSUV = suv
                        representativeIndex = idx
                    }
                }

                for (dz, dy, dx) in offsets {
                    let nz = z + dz
                    let ny = y + dy
                    let nx = x + dx
                    guard nz >= 0, nz < depth,
                          ny >= 0, ny < height,
                          nx >= 0, nx < width else { continue }
                    let nIdx = nz * plane + ny * width + nx
                    guard !visited[nIdx], isForeground(nIdx) else { continue }
                    visited[nIdx] = true
                    queue.append(nIdx)
                }
            }

            if !preferHighestSUVVoxel || petSUVVolume == nil {
                let centroidX = Double(sumX) / Double(max(1, voxelCount))
                let centroidY = Double(sumY) / Double(max(1, voxelCount))
                let centroidZ = Double(sumZ) / Double(max(1, voxelCount))
                representativeIndex = indices.min { lhs, rhs in
                    squaredDistance(index: lhs, width: width, height: height,
                                    x: centroidX, y: centroidY, z: centroidZ)
                    < squaredDistance(index: rhs, width: width, height: height,
                                      x: centroidX, y: centroidY, z: centroidZ)
                } ?? seed
            }

            let point = pointForIndex(representativeIndex, width: width, height: height)
            components.append(ScribbleComponent(voxelCount: voxelCount,
                                                representative: point,
                                                maxSUV: maxSUV))
        }

        return components
    }

    private static func componentPriority(_ lhs: ScribbleComponent,
                                          _ rhs: ScribbleComponent) -> Bool {
        switch (lhs.maxSUV, rhs.maxSUV) {
        case let (l?, r?) where l != r:
            return l > r
        default:
            return lhs.voxelCount > rhs.voxelCount
        }
    }

    private static func pointForIndex(_ index: Int,
                                      width: Int,
                                      height: Int) -> AutoPETVChallenge.VoxelPoint {
        let plane = width * height
        let z = index / plane
        let remainder = index - z * plane
        let y = remainder / width
        let x = remainder - y * width
        return AutoPETVChallenge.VoxelPoint(x: x, y: y, z: z)
    }

    private static func squaredDistance(index: Int,
                                        width: Int,
                                        height: Int,
                                        x: Double,
                                        y: Double,
                                        z: Double) -> Double {
        let point = pointForIndex(index, width: width, height: height)
        let dx = Double(point.x) - x
        let dy = Double(point.y) - y
        let dz = Double(point.z) - z
        return dx * dx + dy * dy + dz * dz
    }

    private static func neighborOffsets(_ connectivity: Connectivity) -> [(Int, Int, Int)] {
        var offsets: [(Int, Int, Int)] = []
        for dz in -1...1 {
            for dy in -1...1 {
                for dx in -1...1 {
                    let manhattan = abs(dx) + abs(dy) + abs(dz)
                    guard manhattan > 0 else { continue }
                    switch connectivity {
                    case .six where manhattan == 1:
                        offsets.append((dz, dy, dx))
                    case .eighteen where manhattan <= 2:
                        offsets.append((dz, dy, dx))
                    case .twentySix:
                        offsets.append((dz, dy, dx))
                    default:
                        continue
                    }
                }
            }
        }
        return offsets
    }
}
