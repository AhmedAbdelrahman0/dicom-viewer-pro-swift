import Foundation

public enum NeuroTemplateSpace: String, CaseIterable, Identifiable, Codable, Sendable {
    case nativePET
    case mni152
    case centiloid
    case fdg3DSSP
    case datscanStriatal
    case spectPerfusion

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nativePET: return "Native PET/SPECT"
        case .mni152: return "MNI152"
        case .centiloid: return "Centiloid"
        case .fdg3DSSP: return "FDG 3D-SSP"
        case .datscanStriatal: return "DaTscan striatal"
        case .spectPerfusion: return "SPECT perfusion"
        }
    }
}

public enum NeuroQuantAbnormalityPolarity: String, Codable, Sendable {
    case low
    case high
    case absolute

    public func isAbnormal(_ zScore: Double, threshold: Double) -> Bool {
        switch self {
        case .low: return zScore <= -abs(threshold)
        case .high: return zScore >= abs(threshold)
        case .absolute: return abs(zScore) >= abs(threshold)
        }
    }

    public func betterPeak(_ lhs: Double, _ rhs: Double) -> Bool {
        switch self {
        case .low: return lhs < rhs
        case .high: return lhs > rhs
        case .absolute: return abs(lhs) > abs(rhs)
        }
    }

    public var displayName: String {
        switch self {
        case .low: return "Low z-score"
        case .high: return "High z-score"
        case .absolute: return "Absolute z-score"
        }
    }
}

public enum NeuroQuantWorkflowProtocol: String, CaseIterable, Identifiable, Codable, Sendable {
    case fdgDementia
    case amyloidCentiloid
    case tauBraak
    case datscanStriatal
    case hmpaoPerfusion

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fdgDementia: return "FDG Dementia"
        case .amyloidCentiloid: return "Amyloid Centiloid"
        case .tauBraak: return "Tau Braak-like"
        case .datscanStriatal: return "DaTscan Striatal"
        case .hmpaoPerfusion: return "HMPAO Perfusion"
        }
    }

    public var shortName: String {
        switch self {
        case .fdgDementia: return "FDG"
        case .amyloidCentiloid: return "Amyloid"
        case .tauBraak: return "Tau"
        case .datscanStriatal: return "DaTscan"
        case .hmpaoPerfusion: return "HMPAO"
        }
    }

    public var tracer: BrainPETTracer {
        switch self {
        case .fdgDementia: return .fdg
        case .amyloidCentiloid: return .amyloidFlorbetapir
        case .tauBraak: return .tauFlortaucipir
        case .datscanStriatal: return .spectDaTscan
        case .hmpaoPerfusion: return .spectHMPAO
        }
    }

    public var preferredTemplateSpace: NeuroTemplateSpace {
        switch self {
        case .fdgDementia: return .fdg3DSSP
        case .amyloidCentiloid: return .centiloid
        case .tauBraak: return .mni152
        case .datscanStriatal: return .datscanStriatal
        case .hmpaoPerfusion: return .spectPerfusion
        }
    }

    public var abnormalityPolarity: NeuroQuantAbnormalityPolarity {
        switch self {
        case .fdgDementia, .datscanStriatal, .hmpaoPerfusion:
            return .low
        case .amyloidCentiloid, .tauBraak:
            return .high
        }
    }

    public var zScoreThreshold: Double { 2.0 }

    public var tauSUVRThreshold: Double {
        self == .tauBraak ? 1.34 : 1.34
    }

    public var requiresNormalDatabase: Bool {
        switch self {
        case .fdgDementia, .hmpaoPerfusion:
            return true
        case .amyloidCentiloid, .tauBraak, .datscanStriatal:
            return false
        }
    }

    public var supportsDynamicImaging: Bool {
        switch self {
        case .amyloidCentiloid, .fdgDementia:
            return true
        case .tauBraak, .datscanStriatal, .hmpaoPerfusion:
            return false
        }
    }

    public var referenceKeywords: [String] {
        switch self {
        case .fdgDementia:
            return ["pons", "cerebellum", "cerebellar"]
        case .amyloidCentiloid:
            return ["whole cerebellum", "cerebellum", "cerebellar"]
        case .tauBraak:
            return ["inferior cerebell", "cerebellar gray", "cerebellum"]
        case .datscanStriatal:
            return ["occipital", "background", "cerebellum"]
        case .hmpaoPerfusion:
            return ["whole brain", "global", "cerebellum"]
        }
    }

    public var targetKeywords: [String] {
        switch self {
        case .fdgDementia:
            return ["frontal", "temporal", "parietal", "precuneus", "cingulate", "occipital"]
        case .amyloidCentiloid:
            return ["frontal", "temporal", "parietal", "precuneus", "cingulate", "orbitofrontal"]
        case .tauBraak:
            return ["entorhinal", "hippocampus", "amygdala", "temporal", "fusiform", "frontal", "parietal", "precuneus", "cingulate"]
        case .datscanStriatal:
            return ["caudate", "putamen", "striatum"]
        case .hmpaoPerfusion:
            return ["frontal", "temporal", "parietal", "occipital", "cerebellum", "basal ganglia", "thalamus"]
        }
    }

    public var lockedSummary: String {
        switch self {
        case .fdgDementia:
            return "Locks FDG dementia quantification to cortical/association regions, z-score review, and hypometabolism-focused interpretation."
        case .amyloidCentiloid:
            return "Locks amyloid review to Centiloid/SUVR reporting with cerebellar reference and cortical target regions."
        case .tauBraak:
            return "Locks tau analysis to Braak-like regional staging, tau thresholding, and off-target/QC warnings."
        case .datscanStriatal:
            return "Locks DaTscan review to caudate/putamen binding ratios, occipital/background reference, and asymmetry."
        case .hmpaoPerfusion:
            return "Locks HMPAO perfusion review to regional z-scores, low-perfusion clusters, and SPECT-specific QC."
        }
    }

    public var reportSections: [String] {
        switch self {
        case .fdgDementia:
            return ["Protocol", "Registration QC", "Regional SUVR", "Low-uptake clusters", "Surface projections", "Impression"]
        case .amyloidCentiloid:
            return ["Protocol", "Centiloid", "Regional SUVR", "Z-score table", "Impression"]
        case .tauBraak:
            return ["Protocol", "Tau stage", "Regional SUVR", "High-binding clusters", "Impression"]
        case .datscanStriatal:
            return ["Protocol", "Striatal binding", "Asymmetry", "QC", "Impression"]
        case .hmpaoPerfusion:
            return ["Protocol", "Perfusion z-scores", "Low-perfusion clusters", "Surface projections", "Impression"]
        }
    }

    public func configuration(atlas: LabelMap?,
                              normalDatabase: BrainPETNormalDatabase?,
                              tauSUVRThreshold: Double? = nil) -> BrainPETAnalysisConfiguration {
        let referenceIDs = atlas.map { labelIDs(in: $0, matching: referenceKeywords) } ?? []
        let targetIDs = atlas.map { labelIDs(in: $0, matching: targetKeywords) } ?? []
        return BrainPETAnalysisConfiguration(
            tracer: tracer,
            referenceClassIDs: referenceIDs,
            targetClassIDs: targetIDs,
            tauSUVRThreshold: tauSUVRThreshold ?? self.tauSUVRThreshold,
            normalDatabase: normalDatabase
        )
    }

    public func labelIDs(in atlas: LabelMap, matching keywords: [String]) -> [UInt16] {
        let normalizedKeywords = keywords.map(BrainPETAnalysis.normalizedRegionName)
        let matches = atlas.classes.filter { cls in
            let name = BrainPETAnalysis.normalizedRegionName(cls.name)
            return normalizedKeywords.contains { name.contains($0) }
        }
        return matches.map(\.labelID)
    }
}

public struct NeuroQuantAtlasPack: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let templateSpace: NeuroTemplateSpace
    public let supportedProtocols: [NeuroQuantWorkflowProtocol]
    public let requiredRegionKeywords: [String]
    public let sourceDescription: String

    public init(id: String,
                name: String,
                version: String,
                templateSpace: NeuroTemplateSpace,
                supportedProtocols: [NeuroQuantWorkflowProtocol],
                requiredRegionKeywords: [String],
                sourceDescription: String) {
        self.id = id
        self.name = name
        self.version = version
        self.templateSpace = templateSpace
        self.supportedProtocols = supportedProtocols
        self.requiredRegionKeywords = requiredRegionKeywords
        self.sourceDescription = sourceDescription
    }
}

public struct NeuroQuantAtlasValidation: Codable, Equatable, Sendable {
    public let pack: NeuroQuantAtlasPack
    public let workflow: NeuroQuantWorkflowProtocol
    public let score: Double
    public let matchedRequiredRegions: [String]
    public let missingRequiredRegions: [String]
    public let matchedReferenceIDs: [UInt16]
    public let matchedTargetIDs: [UInt16]
    public let warnings: [String]

    public var isUsable: Bool {
        !matchedReferenceIDs.isEmpty && !matchedTargetIDs.isEmpty
    }
}

public enum NeuroQuantAtlasRegistry {
    public static let defaultPacks: [NeuroQuantAtlasPack] = [
        NeuroQuantAtlasPack(
            id: "clark-centiloid",
            name: "Clark/GAAIN Centiloid VOIs",
            version: "2024.1",
            templateSpace: .centiloid,
            supportedProtocols: [.amyloidCentiloid],
            requiredRegionKeywords: ["frontal", "temporal", "anterior cingulate", "posterior cingulate", "parietal", "precuneus", "cerebellum"],
            sourceDescription: "MIMneuro-style Centiloid cortical and cerebellar VOI contract"
        ),
        NeuroQuantAtlasPack(
            id: "fdg-3d-ssp",
            name: "FDG Dementia 3D-SSP Regions",
            version: "2024.1",
            templateSpace: .fdg3DSSP,
            supportedProtocols: [.fdgDementia],
            requiredRegionKeywords: ["frontal", "temporal", "parietal", "precuneus", "cingulate", "pons"],
            sourceDescription: "FDG hypometabolism z-score and surface projection contract"
        ),
        NeuroQuantAtlasPack(
            id: "tau-braak",
            name: "Tau Braak-like Regions",
            version: "2024.1",
            templateSpace: .mni152,
            supportedProtocols: [.tauBraak],
            requiredRegionKeywords: ["entorhinal", "hippocampus", "temporal", "fusiform", "frontal", "parietal", "cerebellum"],
            sourceDescription: "Tau Braak-like regional staging contract"
        ),
        NeuroQuantAtlasPack(
            id: "datscan-striatal",
            name: "DaTscan Striatal VOIs",
            version: "2024.1",
            templateSpace: .datscanStriatal,
            supportedProtocols: [.datscanStriatal],
            requiredRegionKeywords: ["caudate", "putamen", "occipital"],
            sourceDescription: "Striatal binding ratio and asymmetry contract"
        ),
        NeuroQuantAtlasPack(
            id: "hmpao-perfusion",
            name: "HMPAO Perfusion Regions",
            version: "2024.1",
            templateSpace: .spectPerfusion,
            supportedProtocols: [.hmpaoPerfusion],
            requiredRegionKeywords: ["frontal", "temporal", "parietal", "occipital", "cerebellum"],
            sourceDescription: "Perfusion SPECT z-score and cluster contract"
        )
    ]

    public static func bestValidation(for atlas: LabelMap,
                                      workflow: NeuroQuantWorkflowProtocol) -> NeuroQuantAtlasValidation {
        let compatible = defaultPacks.filter { $0.supportedProtocols.contains(workflow) }
        let packs = compatible.isEmpty ? defaultPacks : compatible
        return packs
            .map { validate(atlas: atlas, workflow: workflow, pack: $0) }
            .max { $0.score < $1.score }
            ?? validate(atlas: atlas, workflow: workflow, pack: defaultPacks[0])
    }

    public static func validate(atlas: LabelMap,
                                workflow: NeuroQuantWorkflowProtocol,
                                pack: NeuroQuantAtlasPack) -> NeuroQuantAtlasValidation {
        let classNames = atlas.classes.map { BrainPETAnalysis.normalizedRegionName($0.name) }
        let required = pack.requiredRegionKeywords.map(BrainPETAnalysis.normalizedRegionName)
        let matched = required.filter { keyword in
            classNames.contains { $0.contains(keyword) }
        }
        let missing = required.filter { !matched.contains($0) }
        let referenceIDs = workflow.labelIDs(in: atlas, matching: workflow.referenceKeywords)
        let targetIDs = workflow.labelIDs(in: atlas, matching: workflow.targetKeywords)
        var warnings: [String] = []
        if referenceIDs.isEmpty {
            warnings.append("No protocol reference region was found in the active atlas.")
        }
        if targetIDs.isEmpty {
            warnings.append("No protocol target regions were found in the active atlas.")
        }
        if !missing.isEmpty {
            warnings.append("Atlas is missing required region keyword(s): \(missing.joined(separator: ", ")).")
        }
        let protocolBonus = pack.supportedProtocols.contains(workflow) ? 0.2 : 0.0
        let requiredScore = required.isEmpty ? 0.6 : Double(matched.count) / Double(required.count)
        let targetScore = targetIDs.isEmpty ? 0.0 : 0.1
        let referenceScore = referenceIDs.isEmpty ? 0.0 : 0.1
        return NeuroQuantAtlasValidation(
            pack: pack,
            workflow: workflow,
            score: min(1.0, requiredScore * 0.6 + protocolBonus + targetScore + referenceScore),
            matchedRequiredRegions: matched,
            missingRequiredRegions: missing,
            matchedReferenceIDs: referenceIDs,
            matchedTargetIDs: targetIDs,
            warnings: warnings
        )
    }
}

public struct NeuroTemplateRegistrationStep: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let required: Bool
}

public struct NeuroTemplateRegistrationPlan: Codable, Equatable, Sendable {
    public let workflow: NeuroQuantWorkflowProtocol
    public let templateSpace: NeuroTemplateSpace
    public let sourceDescription: String
    public let anatomyDescription: String?
    public let steps: [NeuroTemplateRegistrationStep]
    public let qualityGates: [String]
    public let blockers: [String]
    public let warnings: [String]

    public var isReady: Bool { blockers.isEmpty }

    public static func make(volume: ImageVolume,
                            anatomyVolume: ImageVolume?,
                            atlasValidation: NeuroQuantAtlasValidation,
                            workflow: NeuroQuantWorkflowProtocol) -> NeuroTemplateRegistrationPlan {
        var steps = [
            NeuroTemplateRegistrationStep(
                id: "orientation",
                title: "Orientation normalization",
                detail: "Confirm LPS orientation, voxel spacing, and matrix dimensions before template alignment.",
                required: true
            ),
            NeuroTemplateRegistrationStep(
                id: "rigid",
                title: "Rigid brain alignment",
                detail: "Initialize to \(workflow.preferredTemplateSpace.displayName) using center-of-brain and scanner geometry.",
                required: true
            ),
            NeuroTemplateRegistrationStep(
                id: "affine",
                title: "Affine template fit",
                detail: "Correct global brain size and shape before VOI transfer.",
                required: true
            )
        ]
        if anatomyVolume != nil {
            steps.append(
                NeuroTemplateRegistrationStep(
                    id: "anatomy",
                    title: "Anatomy-assisted refinement",
                    detail: "Use paired CT/MRI as registration scaffold and tissue-separation QC.",
                    required: false
                )
            )
        }
        steps.append(
            NeuroTemplateRegistrationStep(
                id: "deformable",
                title: "Landmark deformable refinement",
                detail: "Apply bounded brain landmark deformation with atlas/normal database consistency checks.",
                required: true
            )
        )

        var blockers: [String] = []
        var warnings = atlasValidation.warnings
        if volume.pixels.isEmpty {
            blockers.append("No source voxels are available for template registration.")
        }
        if volume.width < 2 || volume.height < 2 || volume.depth < 1 {
            warnings.append("Image grid is very small; template QA will be limited.")
        }
        if !atlasValidation.isUsable {
            blockers.append("Active atlas does not contain enough reference and target regions for \(workflow.displayName).")
        }
        if workflow.requiresNormalDatabase {
            warnings.append("\(workflow.displayName) needs a matching normal database before z-score interpretation is complete.")
        }

        let qualityGates = [
            "Atlas pack: \(atlasValidation.pack.name) \(atlasValidation.pack.version)",
            String(format: "Atlas compatibility score %.0f%%", atlasValidation.score * 100),
            "Template space: \(workflow.preferredTemplateSpace.displayName)",
            "Reference VOIs: \(atlasValidation.matchedReferenceIDs.count)",
            "Target VOIs: \(atlasValidation.matchedTargetIDs.count)"
        ]

        return NeuroTemplateRegistrationPlan(
            workflow: workflow,
            templateSpace: workflow.preferredTemplateSpace,
            sourceDescription: volume.seriesDescription.isEmpty ? volume.modality : volume.seriesDescription,
            anatomyDescription: anatomyVolume?.seriesDescription,
            steps: steps,
            qualityGates: qualityGates,
            blockers: blockers,
            warnings: warnings
        )
    }
}

public struct NeuroTransformSummary: Codable, Equatable, Sendable {
    public let matrixRows: [[Double]]
    public let translationMM: SIMD3<Double>
    public let isIdentity: Bool

    public static func make(from transform: Transform3D,
                            tolerance: Double = 1e-6) -> NeuroTransformSummary {
        let rows = (0..<4).map { row in
            (0..<4).map { column in
                transform.matrix[column, row]
            }
        }
        var maxDelta = 0.0
        for column in 0..<4 {
            for row in 0..<4 {
                let expected = column == row ? 1.0 : 0.0
                maxDelta = max(maxDelta, abs(transform.matrix[column, row] - expected))
            }
        }
        return NeuroTransformSummary(
            matrixRows: rows,
            translationMM: SIMD3<Double>(
                transform.matrix[3, 0],
                transform.matrix[3, 1],
                transform.matrix[3, 2]
            ),
            isIdentity: maxDelta <= tolerance
        )
    }
}

public struct NeuroRegistrationQASummary: Codable, Equatable, Sendable {
    public let label: String
    public let grade: RegistrationQualityGrade
    public let normalizedMutualInformation: Double?
    public let maskDice: Double?
    public let centroidResidualMM: Double?
    public let edgeAlignment: Double?
    public let sampleCount: Int
    public let warnings: [String]
    public let summary: String

    public static func make(from snapshot: RegistrationQualitySnapshot) -> NeuroRegistrationQASummary {
        var parts: [String] = []
        if let nmi = snapshot.normalizedMutualInformation {
            parts.append(String(format: "NMI %.3f", nmi))
        }
        if let dice = snapshot.maskDice {
            parts.append(String(format: "overlap %.2f", dice))
        }
        if let residual = snapshot.centroidResidualMM {
            parts.append(String(format: "centroid %.1f mm", residual))
        }
        if let edge = snapshot.edgeAlignment {
            parts.append(String(format: "edge %.2f", edge))
        }
        if parts.isEmpty {
            parts.append(snapshot.grade.displayName)
        }
        return NeuroRegistrationQASummary(
            label: snapshot.label,
            grade: snapshot.grade,
            normalizedMutualInformation: snapshot.normalizedMutualInformation,
            maskDice: snapshot.maskDice,
            centroidResidualMM: snapshot.centroidResidualMM,
            edgeAlignment: snapshot.edgeAlignment,
            sampleCount: snapshot.sampleCount,
            warnings: snapshot.warnings,
            summary: parts.joined(separator: ", ")
        )
    }

    public static func make(from comparison: RegistrationQualityComparison) -> NeuroRegistrationQASummary {
        NeuroRegistrationQASummary(
            label: comparison.after.label,
            grade: comparison.grade,
            normalizedMutualInformation: comparison.after.normalizedMutualInformation,
            maskDice: comparison.after.maskDice,
            centroidResidualMM: comparison.after.centroidResidualMM,
            edgeAlignment: comparison.after.edgeAlignment,
            sampleCount: comparison.after.sampleCount,
            warnings: comparison.warnings,
            summary: comparison.summary
        )
    }
}

public enum NeuroRegistrationStageKind: String, Codable, Sendable {
    case geometry
    case rigid
    case deformable
    case templateWarp
    case atlasTransfer
    case qualityControl

    public var displayName: String {
        switch self {
        case .geometry: return "Geometry"
        case .rigid: return "Rigid"
        case .deformable: return "Deformable"
        case .templateWarp: return "Template warp"
        case .atlasTransfer: return "Atlas transfer"
        case .qualityControl: return "Quality control"
        }
    }
}

public struct NeuroRegistrationStage: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: NeuroRegistrationStageKind
    public let title: String
    public let grade: RegistrationQualityGrade
    public let summary: String
    public let warnings: [String]
}

public struct NeuroRegistrationPipelineResult: Codable, Equatable, Sendable {
    public let workflow: NeuroQuantWorkflowProtocol
    public let registrationMode: PETMRRegistrationMode?
    public let fixedSpaceDescription: String
    public let templateSpace: NeuroTemplateSpace
    public let movingToFixed: NeuroTransformSummary
    public let fixedToMoving: NeuroTransformSummary
    public let beforeQA: NeuroRegistrationQASummary?
    public let afterQA: NeuroRegistrationQASummary?
    public let atlasValidation: NeuroQuantAtlasValidation
    public let stages: [NeuroRegistrationStage]
    public let warnings: [String]
    public let reportLines: [String]

    public var summary: String {
        if let afterQA {
            return "\(fixedSpaceDescription): \(afterQA.grade.displayName), \(afterQA.summary)"
        }
        return "\(fixedSpaceDescription): \(templateSpace.displayName) transfer planned"
    }
}

public enum NeuroRegistrationPipeline {
    public static func plan(volume: ImageVolume,
                            anatomyVolume: ImageVolume?,
                            atlasValidation: NeuroQuantAtlasValidation,
                            workflow: NeuroQuantWorkflowProtocol) -> NeuroRegistrationPipelineResult {
        var stages: [NeuroRegistrationStage] = [
            NeuroRegistrationStage(
                id: "native-geometry",
                kind: .geometry,
                title: "Native geometry inspection",
                grade: .pass,
                summary: "\(volume.width)x\(volume.height)x\(volume.depth), spacing \(formatSpacing(volume.spacing))",
                warnings: volume.pixels.isEmpty ? ["No source voxels available."] : []
            )
        ]
        var warnings = atlasValidation.warnings

        guard let anatomyVolume else {
            stages.append(
                NeuroRegistrationStage(
                    id: "template-warp-plan",
                    kind: .templateWarp,
                    title: "Protocol template registration",
                    grade: atlasValidation.isUsable ? .unknown : .fail,
                    summary: "Prepare \(workflow.preferredTemplateSpace.displayName) registration and atlas/normal-database transfer.",
                    warnings: atlasValidation.warnings
                )
            )
            stages.append(
                NeuroRegistrationStage(
                    id: "atlas-transfer",
                    kind: .atlasTransfer,
                    title: "Atlas transfer contract",
                    grade: atlasValidation.isUsable ? .pass : .fail,
                    summary: "Atlas compatibility \(String(format: "%.0f%%", atlasValidation.score * 100)); reference VOIs \(atlasValidation.matchedReferenceIDs.count), target VOIs \(atlasValidation.matchedTargetIDs.count).",
                    warnings: atlasValidation.warnings
                )
            )
            let lines = stages.map { "\($0.kind.displayName): \($0.summary)" } + warnings.map { "Warning: \($0)" }
            return NeuroRegistrationPipelineResult(
                workflow: workflow,
                registrationMode: nil,
                fixedSpaceDescription: workflow.preferredTemplateSpace.displayName,
                templateSpace: workflow.preferredTemplateSpace,
                movingToFixed: .make(from: .identity),
                fixedToMoving: .make(from: .identity),
                beforeQA: nil,
                afterQA: nil,
                atlasValidation: atlasValidation,
                stages: stages,
                warnings: warnings,
                reportLines: lines
            )
        }

        let mode: PETMRRegistrationMode = anatomyVolume.modality.uppercased().contains("MR")
            ? .brainMRIDriven
            : .automaticBestFit
        let registration = PETMRRegistrationEngine.estimatePETToMR(
            pet: volume,
            mr: anatomyVolume,
            mode: mode
        )
        let beforeMoving = VolumeResampler.resample(source: volume, target: anatomyVolume, transform: .identity)
        let afterMoving = VolumeResampler.resample(source: volume, target: anatomyVolume, transform: registration.fixedToMoving)
        let beforeSnapshot = RegistrationQualityAssurance.evaluate(
            fixed: anatomyVolume,
            movingOnFixedGrid: beforeMoving,
            label: "Before neuro PET/anatomy registration"
        )
        let afterSnapshot = RegistrationQualityAssurance.evaluate(
            fixed: anatomyVolume,
            movingOnFixedGrid: afterMoving,
            label: "After neuro PET/anatomy registration"
        )
        let comparison = RegistrationQualityAssurance.compare(
            before: beforeSnapshot,
            after: afterSnapshot,
            allowBrainPETMRFitInside: true
        )
        warnings.append(contentsOf: comparison.warnings)
        stages.append(
            NeuroRegistrationStage(
                id: "brain-rigid-fit",
                kind: .rigid,
                title: "Brain anatomy-driven registration",
                grade: comparison.grade,
                summary: registration.note,
                warnings: comparison.warnings
            )
        )
        stages.append(
            NeuroRegistrationStage(
                id: "atlas-transfer",
                kind: .atlasTransfer,
                title: "Atlas transfer contract",
                grade: atlasValidation.isUsable ? .pass : .fail,
                summary: "Atlas compatibility \(String(format: "%.0f%%", atlasValidation.score * 100)); transfer in \(workflow.preferredTemplateSpace.displayName).",
                warnings: atlasValidation.warnings
            )
        )
        stages.append(
            NeuroRegistrationStage(
                id: "registration-qa",
                kind: .qualityControl,
                title: "Registration QA",
                grade: comparison.grade,
                summary: comparison.summary,
                warnings: comparison.warnings
            )
        )
        let uniqueWarnings = uniqueStrings(warnings)
        let lines = [
            "Fixed space: \(anatomyVolume.seriesDescription.isEmpty ? anatomyVolume.modality : anatomyVolume.seriesDescription)",
            "Mode: \(mode.displayName)",
            "Anchor: \(registration.anchorDescription)",
            "Optimizer: \(registration.optimizerDescription)",
            "QA: \(comparison.grade.displayName) - \(comparison.summary)"
        ] + uniqueWarnings.map { "Warning: \($0)" }
        return NeuroRegistrationPipelineResult(
            workflow: workflow,
            registrationMode: mode,
            fixedSpaceDescription: anatomyVolume.seriesDescription.isEmpty ? anatomyVolume.modality : anatomyVolume.seriesDescription,
            templateSpace: workflow.preferredTemplateSpace,
            movingToFixed: .make(from: registration.movingToFixed),
            fixedToMoving: .make(from: registration.fixedToMoving),
            beforeQA: .make(from: beforeSnapshot),
            afterQA: .make(from: comparison),
            atlasValidation: atlasValidation,
            stages: stages,
            warnings: uniqueWarnings,
            reportLines: lines
        )
    }

    private static func formatSpacing(_ spacing: (x: Double, y: Double, z: Double)) -> String {
        String(format: "%.2f/%.2f/%.2f mm", spacing.x, spacing.y, spacing.z)
    }
}

public struct NeuroZScoreMap: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let depth: Int
    public let values: [Float]
    public let threshold: Double
    public let polarity: NeuroQuantAbnormalityPolarity

    public var finiteValues: [Float] {
        values.filter { $0.isFinite }
    }

    public var peakMagnitude: Double {
        finiteValues.map { abs(Double($0)) }.max() ?? 0
    }

    public func value(z: Int, y: Int, x: Int) -> Double {
        guard z >= 0, z < depth, y >= 0, y < height, x >= 0, x < width else { return 0 }
        return Double(values[z * height * width + y * width + x])
    }
}

public enum NeuroZScoreMapBuilder {
    public static func build(report: BrainPETReport,
                             atlas: LabelMap,
                             workflow: NeuroQuantWorkflowProtocol) -> NeuroZScoreMap {
        var regionZ: [UInt16: Float] = [:]
        for region in report.regions {
            if let z = region.zScore, z.isFinite {
                regionZ[region.labelID] = Float(z)
            }
        }
        let values = atlas.voxels.map { label -> Float in
            guard label != 0 else { return 0 }
            return regionZ[label] ?? 0
        }
        return NeuroZScoreMap(
            width: atlas.width,
            height: atlas.height,
            depth: atlas.depth,
            values: values,
            threshold: workflow.zScoreThreshold,
            polarity: workflow.abnormalityPolarity
        )
    }
}

public struct NeuroQuantCluster: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let voxelCount: Int
    public let meanZScore: Double
    public let peakZScore: Double
    public let centroid: SIMD3<Double>
    public let dominantRegion: String
    public let minVoxel: SIMD3<Int>
    public let maxVoxel: SIMD3<Int>

    public func volumeML(spacing: (Double, Double, Double)) -> Double {
        Double(voxelCount) * spacing.0 * spacing.1 * spacing.2 / 1000.0
    }
}

public enum NeuroClusterAnalyzer {
    public static func findClusters(in map: NeuroZScoreMap,
                                    atlas: LabelMap?,
                                    maxClusters: Int = 12) -> [NeuroQuantCluster] {
        guard map.values.count == map.width * map.height * map.depth else { return [] }
        var visited = [Bool](repeating: false, count: map.values.count)
        var clusters: [NeuroQuantCluster] = []
        var nextID = 1

        for index in map.values.indices where !visited[index] {
            let z = Double(map.values[index])
            guard z.isFinite, map.polarity.isAbnormal(z, threshold: map.threshold) else {
                visited[index] = true
                continue
            }
            var stack = [index]
            visited[index] = true
            var voxels: [Int] = []

            while let current = stack.popLast() {
                voxels.append(current)
                for neighbor in neighbors(of: current, width: map.width, height: map.height, depth: map.depth) where !visited[neighbor] {
                    let nz = Double(map.values[neighbor])
                    if nz.isFinite, map.polarity.isAbnormal(nz, threshold: map.threshold) {
                        visited[neighbor] = true
                        stack.append(neighbor)
                    } else {
                        visited[neighbor] = true
                    }
                }
            }

            if let cluster = makeCluster(id: nextID,
                                         voxelIndices: voxels,
                                         map: map,
                                         atlas: atlas) {
                clusters.append(cluster)
                nextID += 1
            }
        }

        return clusters
            .sorted {
                if $0.voxelCount != $1.voxelCount {
                    return $0.voxelCount > $1.voxelCount
                }
                return abs($0.peakZScore) > abs($1.peakZScore)
            }
            .prefix(maxClusters)
            .map { $0 }
    }

    private static func makeCluster(id: Int,
                                    voxelIndices: [Int],
                                    map: NeuroZScoreMap,
                                    atlas: LabelMap?) -> NeuroQuantCluster? {
        guard !voxelIndices.isEmpty else { return nil }
        var sumZ = 0.0
        var peakZ = Double(map.values[voxelIndices[0]])
        var sumX = 0.0
        var sumY = 0.0
        var sumZCoord = 0.0
        var minX = map.width, minY = map.height, minZ = map.depth
        var maxX = -1, maxY = -1, maxZ = -1
        var labels: [UInt16: Int] = [:]

        for index in voxelIndices {
            let zScore = Double(map.values[index])
            sumZ += zScore
            if map.polarity.betterPeak(zScore, peakZ) {
                peakZ = zScore
            }
            let z = index / (map.height * map.width)
            let rem = index % (map.height * map.width)
            let y = rem / map.width
            let x = rem % map.width
            sumX += Double(x)
            sumY += Double(y)
            sumZCoord += Double(z)
            minX = min(minX, x)
            minY = min(minY, y)
            minZ = min(minZ, z)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
            maxZ = max(maxZ, z)
            if let atlas,
               atlas.voxels.indices.contains(index) {
                let label = atlas.voxels[index]
                if label != 0 {
                    labels[label, default: 0] += 1
                }
            }
        }

        let dominantLabel = labels.max { $0.value < $1.value }?.key
        let dominantRegion: String
        if let dominantLabel,
           let cls = atlas?.classes.first(where: { $0.labelID == dominantLabel }) {
            dominantRegion = cls.name
        } else {
            dominantRegion = "Unlabeled"
        }
        let count = Double(voxelIndices.count)
        return NeuroQuantCluster(
            id: id,
            voxelCount: voxelIndices.count,
            meanZScore: sumZ / count,
            peakZScore: peakZ,
            centroid: SIMD3<Double>(sumX / count, sumY / count, sumZCoord / count),
            dominantRegion: dominantRegion,
            minVoxel: SIMD3<Int>(minX, minY, minZ),
            maxVoxel: SIMD3<Int>(maxX, maxY, maxZ)
        )
    }

    private static func neighbors(of index: Int, width: Int, height: Int, depth: Int) -> [Int] {
        let z = index / (height * width)
        let rem = index % (height * width)
        let y = rem / width
        let x = rem % width
        var out: [Int] = []
        func add(_ nz: Int, _ ny: Int, _ nx: Int) {
            guard nz >= 0, nz < depth, ny >= 0, ny < height, nx >= 0, nx < width else { return }
            out.append(nz * height * width + ny * width + nx)
        }
        add(z - 1, y, x)
        add(z + 1, y, x)
        add(z, y - 1, x)
        add(z, y + 1, x)
        add(z, y, x - 1)
        add(z, y, x + 1)
        return out
    }
}

public enum NeuroSurfaceProjectionView: String, CaseIterable, Identifiable, Codable, Sendable {
    case leftLateral
    case rightLateral
    case superior
    case inferior
    case anterior
    case posterior

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .leftLateral: return "Left lateral"
        case .rightLateral: return "Right lateral"
        case .superior: return "Superior"
        case .inferior: return "Inferior"
        case .anterior: return "Anterior"
        case .posterior: return "Posterior"
        }
    }
}

public struct NeuroSurfaceProjectionImage: Identifiable, Codable, Equatable, Sendable {
    public var id: String { view.rawValue }
    public let view: NeuroSurfaceProjectionView
    public let width: Int
    public let height: Int
    public let values: [Float]

    public var peakMagnitude: Double {
        values.map { abs(Double($0)) }.max() ?? 0
    }
}

public enum NeuroSurfaceProjectionBuilder {
    public static func make(from map: NeuroZScoreMap) -> [NeuroSurfaceProjectionImage] {
        NeuroSurfaceProjectionView.allCases.map { view in
            project(map: map, view: view)
        }
    }

    private static func project(map: NeuroZScoreMap,
                                view: NeuroSurfaceProjectionView) -> NeuroSurfaceProjectionImage {
        let dimensions = outputDimensions(map: map, view: view)
        var values = [Float](repeating: 0, count: dimensions.width * dimensions.height)
        for row in 0..<dimensions.height {
            for col in 0..<dimensions.width {
                values[row * dimensions.width + col] = Float(bestValue(map: map, view: view, row: row, col: col))
            }
        }
        return NeuroSurfaceProjectionImage(view: view, width: dimensions.width, height: dimensions.height, values: values)
    }

    private static func outputDimensions(map: NeuroZScoreMap,
                                         view: NeuroSurfaceProjectionView) -> (width: Int, height: Int) {
        switch view {
        case .leftLateral, .rightLateral:
            return (map.depth, map.height)
        case .superior, .inferior:
            return (map.width, map.depth)
        case .anterior, .posterior:
            return (map.width, map.height)
        }
    }

    private static func bestValue(map: NeuroZScoreMap,
                                  view: NeuroSurfaceProjectionView,
                                  row: Int,
                                  col: Int) -> Double {
        var best = 0.0
        func consider(_ value: Double) {
            if map.polarity.betterPeak(value, best) {
                best = value
            }
        }
        switch view {
        case .leftLateral:
            let z = col
            let y = row
            for x in 0..<map.width { consider(map.value(z: z, y: y, x: x)) }
        case .rightLateral:
            let z = col
            let y = row
            for x in stride(from: map.width - 1, through: 0, by: -1) { consider(map.value(z: z, y: y, x: x)) }
        case .superior:
            let x = col
            let z = row
            for y in stride(from: map.height - 1, through: 0, by: -1) { consider(map.value(z: z, y: y, x: x)) }
        case .inferior:
            let x = col
            let z = row
            for y in 0..<map.height { consider(map.value(z: z, y: y, x: x)) }
        case .anterior:
            let x = col
            let y = row
            for z in stride(from: map.depth - 1, through: 0, by: -1) { consider(map.value(z: z, y: y, x: x)) }
        case .posterior:
            let x = col
            let y = row
            for z in 0..<map.depth { consider(map.value(z: z, y: y, x: x)) }
        }
        return best
    }
}

public struct NeuroStriatalBindingMetrics: Codable, Equatable, Sendable {
    public let leftCaudate: Double?
    public let rightCaudate: Double?
    public let leftPutamen: Double?
    public let rightPutamen: Double?
    public let meanStriatalBindingRatio: Double?
    public let asymmetryPercent: Double?
    public let putamenCaudateRatio: Double?
    public let leftPutamenCaudateRatio: Double?
    public let rightPutamenCaudateRatio: Double?
    public let caudatePutamenDropoffPercent: Double?

    public static func make(from report: BrainPETReport) -> NeuroStriatalBindingMetrics? {
        guard report.family == .dopamineTransporter else { return nil }
        func value(containing keywords: [String]) -> Double? {
            let normalized = keywords.map(sidePreservingName)
            return report.regions.first { region in
                let name = sidePreservingName(region.name)
                return normalized.allSatisfy { name.contains($0) }
            }?.suvr
        }
        let leftCaudate = value(containing: ["left", "caudate"])
        let rightCaudate = value(containing: ["right", "caudate"])
        let leftPutamen = value(containing: ["left", "putamen"])
        let rightPutamen = value(containing: ["right", "putamen"])
        let striatal = [leftCaudate, rightCaudate, leftPutamen, rightPutamen].compactMap { $0 }
        let mean = striatal.isEmpty ? nil : striatal.reduce(0, +) / Double(striatal.count)
        let left = [leftCaudate, leftPutamen].compactMap { $0 }
        let right = [rightCaudate, rightPutamen].compactMap { $0 }
        let leftMean = left.isEmpty ? nil : left.reduce(0, +) / Double(left.count)
        let rightMean = right.isEmpty ? nil : right.reduce(0, +) / Double(right.count)
        let asymmetry: Double?
        if let leftMean, let rightMean, max(leftMean, rightMean) > 0 {
            asymmetry = abs(leftMean - rightMean) / max(leftMean, rightMean) * 100
        } else {
            asymmetry = nil
        }
        let caudate = [leftCaudate, rightCaudate].compactMap { $0 }
        let putamen = [leftPutamen, rightPutamen].compactMap { $0 }
        let caudateMean = caudate.isEmpty ? nil : caudate.reduce(0, +) / Double(caudate.count)
        let putamenMean = putamen.isEmpty ? nil : putamen.reduce(0, +) / Double(putamen.count)
        let ratio: Double?
        if let caudateMean, let putamenMean, caudateMean > 0 {
            ratio = putamenMean / caudateMean
        } else {
            ratio = nil
        }
        let leftRatio: Double?
        if let leftCaudate, let leftPutamen, leftCaudate > 0 {
            leftRatio = leftPutamen / leftCaudate
        } else {
            leftRatio = nil
        }
        let rightRatio: Double?
        if let rightCaudate, let rightPutamen, rightCaudate > 0 {
            rightRatio = rightPutamen / rightCaudate
        } else {
            rightRatio = nil
        }
        let dropoff: Double?
        if let caudateMean, let putamenMean, caudateMean > 0 {
            dropoff = max(0, (caudateMean - putamenMean) / caudateMean * 100)
        } else {
            dropoff = nil
        }
        return NeuroStriatalBindingMetrics(
            leftCaudate: leftCaudate,
            rightCaudate: rightCaudate,
            leftPutamen: leftPutamen,
            rightPutamen: rightPutamen,
            meanStriatalBindingRatio: mean,
            asymmetryPercent: asymmetry,
            putamenCaudateRatio: ratio,
            leftPutamenCaudateRatio: leftRatio,
            rightPutamenCaudateRatio: rightRatio,
            caudatePutamenDropoffPercent: dropoff
        )
    }

    private static func sidePreservingName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct NeuroQuantReportSection: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let lines: [String]
}

public struct NeuroQuantStructuredReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let workflow: NeuroQuantWorkflowProtocol
    public let impression: String
    public let sections: [NeuroQuantReportSection]

    public var plainText: String {
        var lines = ["\(workflow.displayName) Neuroquantification", "", "Impression:", impression, ""]
        for section in sections {
            lines.append(section.title)
            lines.append(contentsOf: section.lines.map { "- \($0)" })
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

public enum NeuroQuantReportBuilder {
    public static func make(workflow: NeuroQuantWorkflowProtocol,
                            report: BrainPETReport,
                            anatomyReport: BrainPETAnatomyAwareReport,
                            atlasValidation: NeuroQuantAtlasValidation,
                            templatePlan: NeuroTemplateRegistrationPlan,
                            clinicalReadiness: NeuroQuantClinicalReadiness,
                            clusters: [NeuroQuantCluster],
                            striatalMetrics: NeuroStriatalBindingMetrics?) -> NeuroQuantStructuredReport {
        let impression = makeImpression(workflow: workflow,
                                        report: report,
                                        clusters: clusters,
                                        striatalMetrics: striatalMetrics)
        var sections: [NeuroQuantReportSection] = [
            NeuroQuantReportSection(
                id: "protocol",
                title: "Protocol",
                lines: [
                    "Workflow: \(workflow.displayName)",
                    "Tracer: \(workflow.tracer.displayName)",
                    "Template: \(workflow.preferredTemplateSpace.displayName)",
                    "Atlas: \(atlasValidation.pack.name) \(atlasValidation.pack.version)"
                ]
            ),
            NeuroQuantReportSection(
                id: "registration",
                title: "Registration and QC",
                lines: templatePlan.qualityGates + anatomyReport.qcMetrics.map { "\($0.title): \($0.value)" } + templatePlan.warnings
            ),
            NeuroQuantReportSection(
                id: "clinical-readiness",
                title: "Clinical Readiness",
                lines: clinicalReadiness.reportLines
            ),
            NeuroQuantReportSection(
                id: "metrics",
                title: "Quantitative Results",
                lines: quantitativeLines(report: report, striatalMetrics: striatalMetrics)
            )
        ]
        if !clusters.isEmpty {
            sections.append(
                NeuroQuantReportSection(
                    id: "clusters",
                    title: "Abnormal Clusters",
                    lines: clusters.prefix(6).map {
                        String(format: "%@: %d voxels, peak z %.2f, mean z %.2f",
                               $0.dominantRegion,
                               $0.voxelCount,
                               $0.peakZScore,
                               $0.meanZScore)
                    }
                )
            )
        }
        sections.append(
            NeuroQuantReportSection(
                id: "audit",
                title: "Reproducibility",
                lines: [
                    "Protocol sections: \(workflow.reportSections.joined(separator: ", "))",
                    "Atlas compatibility: \(String(format: "%.0f%%", atlasValidation.score * 100))",
                    "Normal database required: \(workflow.requiresNormalDatabase ? "yes" : "no")"
                ]
            )
        )
        return NeuroQuantStructuredReport(
            generatedAt: Date(),
            workflow: workflow,
            impression: impression,
            sections: sections
        )
    }

    private static func quantitativeLines(report: BrainPETReport,
                                          striatalMetrics: NeuroStriatalBindingMetrics?) -> [String] {
        var lines: [String] = [
            "Reference: \(report.referenceRegionName)",
            String(format: "Reference mean: %.3f", report.referenceMean)
        ]
        if let target = report.targetSUVR {
            lines.append(String(format: "Target SUVR/SBR: %.3f", target))
        }
        if let centiloid = report.centiloid {
            lines.append(String(format: "Centiloid: %.1f", centiloid))
        }
        if let tau = report.tauGrade {
            lines.append("Tau stage: \(tau.stage)")
        }
        if let striatalMetrics {
            if let mean = striatalMetrics.meanStriatalBindingRatio {
                lines.append(String(format: "Mean striatal binding ratio: %.3f", mean))
            }
            if let asymmetry = striatalMetrics.asymmetryPercent {
                lines.append(String(format: "Striatal asymmetry: %.1f%%", asymmetry))
            }
            if let ratio = striatalMetrics.putamenCaudateRatio {
                lines.append(String(format: "Putamen/caudate ratio: %.3f", ratio))
            }
            if let dropoff = striatalMetrics.caudatePutamenDropoffPercent {
                lines.append(String(format: "Caudate-to-putamen drop-off: %.1f%%", dropoff))
            }
        }
        lines.append(contentsOf: report.regions.prefix(8).map {
            let z = $0.zScore.map { String(format: ", z %.2f", $0) } ?? ""
            return String(format: "%@: SUVR %.3f%@", $0.name, $0.suvr, z)
        })
        return lines
    }

    private static func makeImpression(workflow: NeuroQuantWorkflowProtocol,
                                       report: BrainPETReport,
                                       clusters: [NeuroQuantCluster],
                                       striatalMetrics: NeuroStriatalBindingMetrics?) -> String {
        switch workflow {
        case .amyloidCentiloid:
            if let centiloid = report.centiloid {
                return String(format: "Amyloid PET quantitative analysis demonstrates target SUVR %.3f with Centiloid %.1f.", report.targetSUVR ?? 0, centiloid)
            }
            return report.summary
        case .tauBraak:
            return report.tauGrade.map { "Tau PET pattern is \($0.stage)." } ?? report.summary
        case .datscanStriatal:
            if let mean = striatalMetrics?.meanStriatalBindingRatio {
                return String(format: "DaTscan striatal binding ratio is %.3f; correlate with visual review and local normal database.", mean)
            }
            return report.summary
        case .fdgDementia, .hmpaoPerfusion:
            if let first = clusters.first {
                return String(format: "%@ shows the largest abnormal cluster in %@ (peak z %.2f).", workflow.displayName, first.dominantRegion, first.peakZScore)
            }
            return report.summary
        }
    }
}

public struct NeuroLongitudinalRegionDelta: Identifiable, Codable, Equatable, Sendable {
    public var id: UInt16 { labelID }
    public let labelID: UInt16
    public let name: String
    public let baselineSUVR: Double
    public let currentSUVR: Double
    public let deltaSUVR: Double
    public let baselineZScore: Double?
    public let currentZScore: Double?
}

public struct NeuroLongitudinalComparison: Codable, Equatable, Sendable {
    public let workflow: NeuroQuantWorkflowProtocol
    public let baselineSummary: String
    public let currentSummary: String
    public let deltaTargetSUVR: Double?
    public let deltaCentiloid: Double?
    public let regionDeltas: [NeuroLongitudinalRegionDelta]
    public let progressionFlag: String

    public static func compare(baseline: BrainPETReport,
                               current: BrainPETReport,
                               workflow: NeuroQuantWorkflowProtocol) -> NeuroLongitudinalComparison {
        let currentByID = Dictionary(uniqueKeysWithValues: current.regions.map { ($0.labelID, $0) })
        let deltas = baseline.regions.compactMap { prior -> NeuroLongitudinalRegionDelta? in
            guard let now = currentByID[prior.labelID] else { return nil }
            return NeuroLongitudinalRegionDelta(
                labelID: prior.labelID,
                name: prior.name,
                baselineSUVR: prior.suvr,
                currentSUVR: now.suvr,
                deltaSUVR: now.suvr - prior.suvr,
                baselineZScore: prior.zScore,
                currentZScore: now.zScore
            )
        }.sorted { abs($0.deltaSUVR) > abs($1.deltaSUVR) }
        let deltaSUVR: Double?
        if let prior = baseline.targetSUVR,
           let now = current.targetSUVR {
            deltaSUVR = now - prior
        } else {
            deltaSUVR = nil
        }
        let deltaCL: Double?
        if let prior = baseline.centiloid,
           let now = current.centiloid {
            deltaCL = now - prior
        } else {
            deltaCL = nil
        }
        let flag: String
        switch workflow.abnormalityPolarity {
        case .low:
            flag = (deltaSUVR ?? 0) <= -0.08 ? "Worsening low-uptake pattern" : "No major low-uptake progression"
        case .high:
            flag = (deltaSUVR ?? 0) >= 0.08 || (deltaCL ?? 0) >= 5 ? "Increasing binding" : "No major binding increase"
        case .absolute:
            flag = abs(deltaSUVR ?? 0) >= 0.08 ? "Meaningful quantitative change" : "No major quantitative change"
        }
        return NeuroLongitudinalComparison(
            workflow: workflow,
            baselineSummary: baseline.summary,
            currentSummary: current.summary,
            deltaTargetSUVR: deltaSUVR,
            deltaCentiloid: deltaCL,
            regionDeltas: deltas,
            progressionFlag: flag
        )
    }
}

public enum NeuroBiomarkerStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case unknown
    case negative
    case positive
    case inconclusive

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .negative: return "Negative"
        case .positive: return "Positive"
        case .inconclusive: return "Inconclusive"
        }
    }
}

public enum NeuroClinicalQuestion: String, CaseIterable, Identifiable, Codable, Sendable {
    case cognitiveDecline
    case mildCognitiveImpairment
    case atypicalDementia
    case earlyOnsetDementia
    case antiAmyloidTherapyEligibility
    case priorInconclusiveBiomarkers
    case asymptomaticScreening
    case parkinsonism
    case essentialTremorQuestion
    case seizureFocus
    case cerebrovascularReserve
    case therapyMonitoring

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cognitiveDecline: return "Cognitive decline"
        case .mildCognitiveImpairment: return "MCI"
        case .atypicalDementia: return "Atypical dementia"
        case .earlyOnsetDementia: return "Early onset"
        case .antiAmyloidTherapyEligibility: return "Anti-amyloid eligibility"
        case .priorInconclusiveBiomarkers: return "Prior inconclusive biomarkers"
        case .asymptomaticScreening: return "Asymptomatic screening"
        case .parkinsonism: return "Parkinsonism"
        case .essentialTremorQuestion: return "ET vs parkinsonism"
        case .seizureFocus: return "Seizure focus"
        case .cerebrovascularReserve: return "CVR"
        case .therapyMonitoring: return "Therapy monitoring"
        }
    }
}

public enum NeuroAUCRating: String, Codable, Sendable {
    case appropriate
    case uncertain
    case rarelyAppropriate
    case notApplicable

    public var displayName: String {
        switch self {
        case .appropriate: return "Appropriate"
        case .uncertain: return "Uncertain"
        case .rarelyAppropriate: return "Rarely appropriate"
        case .notApplicable: return "Not applicable"
        }
    }
}

public struct NeuroAUCIntake: Codable, Equatable, Sendable {
    public let age: Double?
    public let symptomDurationMonths: Double?
    public let questions: [NeuroClinicalQuestion]
    public let priorAmyloidStatus: NeuroBiomarkerStatus
    public let priorTauStatus: NeuroBiomarkerStatus
    public let treatmentEligibilityQuestion: Bool
    public let hasRecentMRI: Bool
    public let freeTextIndication: String?

    public init(age: Double? = nil,
                symptomDurationMonths: Double? = nil,
                questions: [NeuroClinicalQuestion],
                priorAmyloidStatus: NeuroBiomarkerStatus = .unknown,
                priorTauStatus: NeuroBiomarkerStatus = .unknown,
                treatmentEligibilityQuestion: Bool = false,
                hasRecentMRI: Bool = false,
                freeTextIndication: String? = nil) {
        self.age = age
        self.symptomDurationMonths = symptomDurationMonths
        self.questions = questions
        self.priorAmyloidStatus = priorAmyloidStatus
        self.priorTauStatus = priorTauStatus
        self.treatmentEligibilityQuestion = treatmentEligibilityQuestion
        self.hasRecentMRI = hasRecentMRI
        self.freeTextIndication = freeTextIndication
    }
}

public struct NeuroAUCDecision: Codable, Equatable, Sendable {
    public let rating: NeuroAUCRating
    public let suggestedWorkflow: NeuroQuantWorkflowProtocol?
    public let rationale: [String]
    public let blockers: [String]
    public let warnings: [String]

    public var reportLines: [String] {
        var lines = ["AUC rating: \(rating.displayName)"]
        if let suggestedWorkflow {
            lines.append("Suggested workflow: \(suggestedWorkflow.displayName)")
        }
        lines.append(contentsOf: rationale)
        lines.append(contentsOf: blockers.map { "Blocker: \($0)" })
        lines.append(contentsOf: warnings.map { "Warning: \($0)" })
        return lines
    }
}

public enum NeuroAUCDecisionSupport {
    public static func evaluate(intake: NeuroAUCIntake,
                                workflow: NeuroQuantWorkflowProtocol) -> NeuroAUCDecision {
        let questions = Set(intake.questions)
        let suggested = suggestedWorkflow(for: questions) ?? workflow
        var rationale: [String] = []
        var blockers: [String] = []
        var warnings: [String] = []

        if workflow != suggested {
            warnings.append("Selected workflow differs from the intake-suggested \(suggested.displayName) protocol.")
        }
        if intake.treatmentEligibilityQuestion && !intake.hasRecentMRI {
            warnings.append("Anti-amyloid eligibility review should be paired with a recent MRI safety screen.")
        }
        if questions.contains(.asymptomaticScreening) && questions.count == 1 {
            blockers.append("Asymptomatic screening without a diagnostic or treatment-selection question is not supported for routine clinical use.")
        }

        let cognitive = questions.contains(.cognitiveDecline)
            || questions.contains(.mildCognitiveImpairment)
            || questions.contains(.atypicalDementia)
            || questions.contains(.earlyOnsetDementia)
        let dementiaEnriched = questions.contains(.atypicalDementia)
            || questions.contains(.earlyOnsetDementia)
            || questions.contains(.priorInconclusiveBiomarkers)
            || questions.contains(.antiAmyloidTherapyEligibility)
            || intake.treatmentEligibilityQuestion

        let rating: NeuroAUCRating
        switch workflow {
        case .amyloidCentiloid:
            if questions.contains(.asymptomaticScreening) && !intake.treatmentEligibilityQuestion {
                rating = .rarelyAppropriate
                rationale.append("Amyloid PET is rarely appropriate for isolated asymptomatic screening.")
            } else if intake.priorAmyloidStatus == .positive && !intake.treatmentEligibilityQuestion {
                rating = .rarelyAppropriate
                rationale.append("Prior amyloid positivity reduces the value of repeat amyloid quantification unless therapy selection or monitoring is being addressed.")
            } else if cognitive && dementiaEnriched {
                rating = .appropriate
                rationale.append("Cognitive symptoms with atypical, early-onset, inconclusive-biomarker, or treatment-selection context support amyloid quantification.")
            } else if cognitive {
                rating = .uncertain
                rationale.append("Cognitive symptoms are present, but the intake lacks a specific amyloid decision point.")
            } else {
                rating = blockers.isEmpty ? .uncertain : .rarelyAppropriate
                rationale.append("No clear amyloid diagnostic or treatment-selection question was captured.")
            }
        case .tauBraak:
            if questions.contains(.asymptomaticScreening) && !intake.treatmentEligibilityQuestion {
                rating = .rarelyAppropriate
                rationale.append("Tau PET is rarely appropriate for isolated asymptomatic screening.")
            } else if cognitive && dementiaEnriched {
                rating = .appropriate
                rationale.append("Tau staging can support atypical dementia, early-onset dementia, or treatment-planning questions.")
            } else if cognitive {
                rating = .uncertain
                rationale.append("Tau staging may help, but the intake lacks a specific staging or therapy question.")
            } else {
                rating = blockers.isEmpty ? .uncertain : .rarelyAppropriate
                rationale.append("No clear tau staging question was captured.")
            }
        case .fdgDementia:
            if cognitive || questions.contains(.seizureFocus) {
                rating = .appropriate
                rationale.append("FDG PET is aligned with dementia-pattern assessment or seizure-focus localization.")
            } else if questions.contains(.asymptomaticScreening) {
                rating = .rarelyAppropriate
                rationale.append("FDG PET is rarely appropriate for isolated asymptomatic screening.")
            } else {
                rating = .uncertain
                rationale.append("FDG PET needs a clearer cognitive, seizure, or therapy-monitoring question.")
            }
        case .datscanStriatal:
            if questions.contains(.parkinsonism) || questions.contains(.essentialTremorQuestion) {
                rating = .appropriate
                rationale.append("DaTscan is aligned with presynaptic dopaminergic-deficit assessment in parkinsonism or ET-vs-parkinsonism questions.")
            } else {
                rating = questions.contains(.asymptomaticScreening) ? .rarelyAppropriate : .uncertain
                rationale.append("DaTscan needs a motor-syndrome question to support clinical use.")
            }
        case .hmpaoPerfusion:
            if questions.contains(.cerebrovascularReserve) || questions.contains(.seizureFocus) || questions.contains(.therapyMonitoring) {
                rating = .appropriate
                rationale.append("Perfusion SPECT is aligned with CVR, seizure, or therapy-response assessment.")
            } else {
                rating = questions.contains(.asymptomaticScreening) ? .rarelyAppropriate : .uncertain
                rationale.append("Perfusion SPECT needs a perfusion, seizure, or treatment-response question.")
            }
        }

        return NeuroAUCDecision(
            rating: blockers.isEmpty ? rating : .rarelyAppropriate,
            suggestedWorkflow: suggested,
            rationale: rationale,
            blockers: blockers,
            warnings: warnings
        )
    }

    private static func suggestedWorkflow(for questions: Set<NeuroClinicalQuestion>) -> NeuroQuantWorkflowProtocol? {
        if questions.contains(.parkinsonism) || questions.contains(.essentialTremorQuestion) {
            return .datscanStriatal
        }
        if questions.contains(.cerebrovascularReserve) {
            return .hmpaoPerfusion
        }
        if questions.contains(.antiAmyloidTherapyEligibility) || questions.contains(.priorInconclusiveBiomarkers) {
            return .amyloidCentiloid
        }
        if questions.contains(.atypicalDementia) || questions.contains(.earlyOnsetDementia) {
            return .fdgDementia
        }
        if questions.contains(.cognitiveDecline) || questions.contains(.mildCognitiveImpairment) {
            return .fdgDementia
        }
        if questions.contains(.seizureFocus) {
            return .fdgDementia
        }
        return nil
    }
}

public enum NeuroDiseasePatternKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case alzheimerLike
    case dementiaWithLewyBodiesLike
    case frontotemporalLike
    case vascularOrMixed
    case autoimmuneInflammatory
    case amyloidPositive
    case tauBraakAdvanced
    case dopaminergicDeficit
    case normalOrNonspecific

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .alzheimerLike: return "Alzheimer-like"
        case .dementiaWithLewyBodiesLike: return "DLB-like"
        case .frontotemporalLike: return "FTD-like"
        case .vascularOrMixed: return "Vascular/mixed"
        case .autoimmuneInflammatory: return "Autoimmune/inflammatory"
        case .amyloidPositive: return "Amyloid-positive"
        case .tauBraakAdvanced: return "Advanced tau"
        case .dopaminergicDeficit: return "Dopaminergic deficit"
        case .normalOrNonspecific: return "Normal/nonspecific"
        }
    }
}

public struct NeuroDiseasePatternFinding: Identifiable, Codable, Equatable, Sendable {
    public var id: String { kind.rawValue }
    public let kind: NeuroDiseasePatternKind
    public let confidence: Double
    public let summary: String
    public let supportingRegions: [String]
    public let cautions: [String]

    public var reportLine: String {
        String(format: "%@ (%.0f%%): %@",
               kind.displayName,
               confidence * 100,
               summary)
    }
}

public enum NeuroDiseasePatternInterpreter {
    public static func interpret(report: BrainPETReport,
                                 clusters: [NeuroQuantCluster],
                                 workflow: NeuroQuantWorkflowProtocol,
                                 striatalMetrics: NeuroStriatalBindingMetrics? = nil) -> [NeuroDiseasePatternFinding] {
        var findings: [NeuroDiseasePatternFinding] = []
        switch workflow {
        case .fdgDementia:
            findings.append(contentsOf: fdgPatterns(report: report, clusters: clusters))
        case .amyloidCentiloid:
            findings.append(contentsOf: amyloidPatterns(report: report))
        case .tauBraak:
            findings.append(contentsOf: tauPatterns(report: report))
        case .datscanStriatal:
            findings.append(contentsOf: datscanPatterns(report: report, metrics: striatalMetrics))
        case .hmpaoPerfusion:
            findings.append(contentsOf: perfusionPatterns(report: report, clusters: clusters))
        }
        if findings.isEmpty {
            findings.append(
                NeuroDiseasePatternFinding(
                    kind: .normalOrNonspecific,
                    confidence: 0.55,
                    summary: "No protocol-specific quantitative disease pattern reached the configured threshold.",
                    supportingRegions: [],
                    cautions: ["Correlate with visual review, clinical course, MRI, and local normal database."]
                )
            )
        }
        return findings.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private static func fdgPatterns(report: BrainPETReport,
                                    clusters: [NeuroQuantCluster]) -> [NeuroDiseasePatternFinding] {
        let posterior = abnormalRegions(report, polarity: .low, keywords: ["precuneus", "posterior cingulate", "parietal"])
        let temporal = abnormalRegions(report, polarity: .low, keywords: ["temporal"])
        let occipital = abnormalRegions(report, polarity: .low, keywords: ["occipital"])
        let frontal = abnormalRegions(report, polarity: .low, keywords: ["frontal"])
        let anteriorTemporal = abnormalRegions(report, polarity: .low, keywords: ["anterior temporal", "temporal pole"])
        let cingulate = abnormalRegions(report, polarity: .low, keywords: ["cingulate"])
        let inflammatory = abnormalRegions(report, polarity: .high, keywords: ["limbic", "cingulate", "temporal"])
        var findings: [NeuroDiseasePatternFinding] = []

        if !posterior.isEmpty && !temporal.isEmpty {
            findings.append(
                NeuroDiseasePatternFinding(
                    kind: .alzheimerLike,
                    confidence: confidence(base: 0.68, regions: posterior + temporal),
                    summary: "Posterior association and temporal hypometabolism support an Alzheimer-type metabolic pattern.",
                    supportingRegions: names(posterior + temporal),
                    cautions: ["FDG pattern is supportive, not pathognomonic; amyloid/tau biomarkers and MRI may refine etiology."]
                )
            )
        }
        if !occipital.isEmpty {
            let cingulateSparing = cingulate.isEmpty
            findings.append(
                NeuroDiseasePatternFinding(
                    kind: .dementiaWithLewyBodiesLike,
                    confidence: cingulateSparing ? 0.72 : 0.58,
                    summary: cingulateSparing
                        ? "Occipital hypometabolism with relative cingulate sparing suggests a Lewy-body-type pattern."
                        : "Occipital hypometabolism raises a Lewy-body-type consideration.",
                    supportingRegions: names(occipital),
                    cautions: ["Assess clinical parkinsonism, REM sleep behavior disorder, and medication effects."]
                )
            )
        }
        if !frontal.isEmpty && !anteriorTemporal.isEmpty {
            findings.append(
                NeuroDiseasePatternFinding(
                    kind: .frontotemporalLike,
                    confidence: confidence(base: 0.66, regions: frontal + anteriorTemporal),
                    summary: "Frontal and anterior temporal hypometabolism supports a frontotemporal-lobar-degeneration-type pattern.",
                    supportingRegions: names(frontal + anteriorTemporal),
                    cautions: ["Language-predominant and behavioral variants require clinical phenotype correlation."]
                )
            )
        }
        if clusters.count >= 3 || report.regions.contains(where: { normalized($0.name).contains("vascular") || normalized($0.name).contains("infarct") }) {
            findings.append(
                NeuroDiseasePatternFinding(
                    kind: .vascularOrMixed,
                    confidence: min(0.86, 0.48 + Double(clusters.count) * 0.08),
                    summary: "Multifocal abnormal clusters suggest a vascular or mixed contribution.",
                    supportingRegions: clusters.prefix(5).map(\.dominantRegion),
                    cautions: ["Confirm with MRI FLAIR, diffusion, susceptibility, and vascular history."]
                )
            )
        }
        if !inflammatory.isEmpty && report.family == .fdg {
            findings.append(
                NeuroDiseasePatternFinding(
                    kind: .autoimmuneInflammatory,
                    confidence: 0.52,
                    summary: "Focal high uptake in limbic or cingulate regions can be seen with inflammatory or seizure-related processes.",
                    supportingRegions: names(inflammatory),
                    cautions: ["Review EEG, MRI, CSF, and timing relative to seizures or therapy."]
                )
            )
        }
        return findings
    }

    private static func amyloidPatterns(report: BrainPETReport) -> [NeuroDiseasePatternFinding] {
        let highRegions = abnormalRegions(report, polarity: .high, keywords: ["frontal", "temporal", "parietal", "precuneus", "cingulate"])
        let positive = (report.centiloid ?? -Double.infinity) >= 20
            || (report.targetSUVR ?? 0) >= 1.10
            || highRegions.count >= 2
        guard positive else { return [] }
        let summary: String
        if let centiloid = report.centiloid {
            summary = String(format: "Centiloid %.1f and cortical uptake support amyloid positivity.", centiloid)
        } else {
            summary = "Cortical amyloid uptake supports amyloid positivity."
        }
        return [
            NeuroDiseasePatternFinding(
                kind: .amyloidPositive,
                confidence: min(0.94, 0.70 + Double(highRegions.count) * 0.04),
                summary: summary,
                supportingRegions: names(highRegions),
                cautions: ["Amyloid positivity does not establish clinical Alzheimer disease by itself."]
            )
        ]
    }

    private static func tauPatterns(report: BrainPETReport) -> [NeuroDiseasePatternFinding] {
        guard let tau = report.tauGrade,
              !tau.stage.localizedCaseInsensitiveContains("negative") else {
            return []
        }
        let positiveGroups = tau.groups.filter(\.positive).map(\.name)
        let advanced = tau.stage.contains("V/VI") || tau.stage.contains("III/IV")
        return [
            NeuroDiseasePatternFinding(
                kind: advanced ? .tauBraakAdvanced : .alzheimerLike,
                confidence: advanced ? 0.82 : 0.68,
                summary: "Tau PET regional staging is \(tau.stage).",
                supportingRegions: positiveGroups,
                cautions: ["Off-target binding, atrophy, and tracer-specific validation should be reviewed."]
            )
        ]
    }

    private static func datscanPatterns(report: BrainPETReport,
                                        metrics: NeuroStriatalBindingMetrics?) -> [NeuroDiseasePatternFinding] {
        let lowStriatum = abnormalRegions(report, polarity: .low, keywords: ["caudate", "putamen", "striatum"])
        let lowMean = (metrics?.meanStriatalBindingRatio ?? Double.infinity) < 2.5
        let lowRatio = (metrics?.putamenCaudateRatio ?? Double.infinity) < 0.70
        guard !lowStriatum.isEmpty || lowMean || lowRatio else { return [] }
        return [
            NeuroDiseasePatternFinding(
                kind: .dopaminergicDeficit,
                confidence: lowRatio ? 0.84 : 0.70,
                summary: "Reduced striatal binding or posterior putamen drop-off supports a presynaptic dopaminergic deficit.",
                supportingRegions: names(lowStriatum),
                cautions: ["Medication interference and acquisition timing should be checked before final interpretation."]
            )
        ]
    }

    private static func perfusionPatterns(report: BrainPETReport,
                                          clusters: [NeuroQuantCluster]) -> [NeuroDiseasePatternFinding] {
        guard clusters.count >= 2 else { return [] }
        return [
            NeuroDiseasePatternFinding(
                kind: .vascularOrMixed,
                confidence: min(0.82, 0.50 + Double(clusters.count) * 0.06),
                summary: "Multiterritory low-perfusion clusters suggest vascular, seizure-related, or mixed perfusion abnormality.",
                supportingRegions: clusters.prefix(6).map(\.dominantRegion),
                cautions: ["Correlate with vascular territory, MRI, symptoms, and any acetazolamide/baseline comparison."]
            )
        ]
    }

    private static func abnormalRegions(_ report: BrainPETReport,
                                        polarity: NeuroQuantAbnormalityPolarity,
                                        keywords: [String]) -> [BrainPETRegionStatistic] {
        report.regions.filter { region in
            let name = normalized(region.name)
            let matches = keywords.contains { name.contains(normalized($0)) }
            guard matches else { return false }
            let z = region.zScore ?? 0
            return polarity.isAbnormal(z, threshold: 2.0)
        }
    }

    private static func confidence(base: Double,
                                   regions: [BrainPETRegionStatistic]) -> Double {
        let peak = regions.compactMap(\.zScore).map(abs).max() ?? 2.0
        return min(0.94, base + min(0.20, (peak - 2.0) * 0.06))
    }

    private static func names(_ regions: [BrainPETRegionStatistic]) -> [String] {
        Array(Set(regions.map(\.name))).sorted()
    }

    private static func normalized(_ name: String) -> String {
        BrainPETAnalysis.normalizedRegionName(name)
    }
}

public enum NeuroVascularBurden: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case mild
    case moderate
    case severe

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .mild: return "Mild"
        case .moderate: return "Moderate"
        case .severe: return "Severe"
        }
    }
}

public enum NeuroMRIRiskLevel: String, Codable, Sendable {
    case incomplete
    case low
    case moderate
    case high

    public var displayName: String {
        switch self {
        case .incomplete: return "Incomplete"
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        }
    }
}

public struct NeuroMRIContextInput: Codable, Equatable, Sendable {
    public let hasT1: Bool
    public let hippocampalAtrophy: Bool
    public let medialTemporalAtrophyScore: Double?
    public let microhemorrhageCount: Int
    public let superficialSiderosis: Bool
    public let ariaE: Bool
    public let vascularBurden: NeuroVascularBurden
    public let infarctPresent: Bool
    public let notes: String?

    public init(hasT1: Bool = false,
                hippocampalAtrophy: Bool = false,
                medialTemporalAtrophyScore: Double? = nil,
                microhemorrhageCount: Int = 0,
                superficialSiderosis: Bool = false,
                ariaE: Bool = false,
                vascularBurden: NeuroVascularBurden = .none,
                infarctPresent: Bool = false,
                notes: String? = nil) {
        self.hasT1 = hasT1
        self.hippocampalAtrophy = hippocampalAtrophy
        self.medialTemporalAtrophyScore = medialTemporalAtrophyScore
        self.microhemorrhageCount = microhemorrhageCount
        self.superficialSiderosis = superficialSiderosis
        self.ariaE = ariaE
        self.vascularBurden = vascularBurden
        self.infarctPresent = infarctPresent
        self.notes = notes
    }
}

public struct NeuroMRIContextAssessment: Codable, Equatable, Sendable {
    public let riskLevel: NeuroMRIRiskLevel
    public let modifiers: [String]
    public let warnings: [String]
    public let reportLines: [String]
}

public enum NeuroMRIContextAnalyzer {
    public static func assess(input: NeuroMRIContextInput,
                              workflow: NeuroQuantWorkflowProtocol,
                              patterns: [NeuroDiseasePatternFinding]) -> NeuroMRIContextAssessment {
        var modifiers: [String] = []
        var warnings: [String] = []
        if !input.hasT1 {
            warnings.append("No T1 MRI context is available for atrophy and registration review.")
        }
        if input.hippocampalAtrophy {
            modifiers.append("Hippocampal atrophy supports neurodegenerative correlation.")
        }
        if let score = input.medialTemporalAtrophyScore {
            modifiers.append(String(format: "Medial temporal atrophy score %.1f.", score))
        }
        if input.vascularBurden != .none {
            modifiers.append("MRI vascular burden: \(input.vascularBurden.displayName).")
        }
        if input.infarctPresent {
            modifiers.append("MRI infarct may explain focal or vascular-territory abnormalities.")
        }
        if input.microhemorrhageCount > 0 {
            warnings.append("Microhemorrhage count: \(input.microhemorrhageCount).")
        }
        if input.superficialSiderosis {
            warnings.append("Superficial siderosis is present.")
        }
        if input.ariaE {
            warnings.append("ARIA-E/edema is present.")
        }
        if patterns.contains(where: { $0.kind == .vascularOrMixed }) && input.vascularBurden == .none {
            warnings.append("Quantitative pattern suggests vascular/mixed contribution; MRI vascular burden was not marked.")
        }
        if workflow == .amyloidCentiloid || workflow == .tauBraak {
            if input.microhemorrhageCount >= 10 || input.superficialSiderosis || input.ariaE {
                warnings.append("Anti-amyloid therapy safety screen is high-risk; review local exclusion criteria.")
            } else if input.microhemorrhageCount >= 1 || input.vascularBurden == .moderate || input.vascularBurden == .severe {
                warnings.append("Anti-amyloid therapy safety screen has moderate MRI risk features.")
            }
        }

        let risk: NeuroMRIRiskLevel
        if !input.hasT1 && input.microhemorrhageCount == 0 && !input.superficialSiderosis && !input.ariaE {
            risk = .incomplete
        } else if input.ariaE || input.superficialSiderosis || input.microhemorrhageCount >= 10 || input.vascularBurden == .severe {
            risk = .high
        } else if input.microhemorrhageCount > 0 || input.vascularBurden == .moderate || input.infarctPresent {
            risk = .moderate
        } else {
            risk = .low
        }

        var lines = ["MRI context risk: \(risk.displayName)"]
        lines.append(contentsOf: modifiers)
        lines.append(contentsOf: warnings.map { "Warning: \($0)" })
        if let notes = input.notes, !notes.isEmpty {
            lines.append("MRI note: \(notes)")
        }
        return NeuroMRIContextAssessment(
            riskLevel: risk,
            modifiers: modifiers,
            warnings: warnings,
            reportLines: lines
        )
    }
}

public enum NeuroDaTscanPattern: String, Codable, Sendable {
    case normalOrSymmetric
    case leftPredominantDeficit
    case rightPredominantDeficit
    case bilateralPosteriorPutamenDeficit
    case indeterminate

    public var displayName: String {
        switch self {
        case .normalOrSymmetric: return "Normal/symmetric"
        case .leftPredominantDeficit: return "Left-predominant deficit"
        case .rightPredominantDeficit: return "Right-predominant deficit"
        case .bilateralPosteriorPutamenDeficit: return "Bilateral posterior putamen deficit"
        case .indeterminate: return "Indeterminate"
        }
    }
}

public struct NeuroDaTscanClinicalAssessment: Codable, Equatable, Sendable {
    public let pattern: NeuroDaTscanPattern
    public let summary: String
    public let warnings: [String]
    public let medicationWarnings: [String]
    public let limitationLines: [String]
    public let visualGrade: NeuroDaTscanVisualGrade?
    public let ageMatchedPercentile: Double?
    public let reportLines: [String]

    public static func make(metrics: NeuroStriatalBindingMetrics,
                            context: NeuroMovementDisorderContext? = nil,
                            normalDatabase: BrainPETNormalDatabase? = nil) -> NeuroDaTscanClinicalAssessment {
        let leftMean = mean([metrics.leftCaudate, metrics.leftPutamen])
        let rightMean = mean([metrics.rightCaudate, metrics.rightPutamen])
        let dropoff = metrics.caudatePutamenDropoffPercent ?? 0
        let asymmetry = metrics.asymmetryPercent ?? 0
        let ratio = metrics.putamenCaudateRatio ?? 1
        let pattern: NeuroDaTscanPattern
        if ratio < 0.65 && dropoff >= 30 {
            pattern = .bilateralPosteriorPutamenDeficit
        } else if let leftMean, let rightMean, asymmetry >= 15 {
            pattern = leftMean < rightMean ? .leftPredominantDeficit : .rightPredominantDeficit
        } else if metrics.meanStriatalBindingRatio == nil {
            pattern = .indeterminate
        } else {
            pattern = .normalOrSymmetric
        }
        var warnings: [String] = []
        if metrics.meanStriatalBindingRatio == nil {
            warnings.append("Mean SBR could not be computed from the available caudate/putamen VOIs.")
        }
        if ratio < 0.65 {
            warnings.append("Putamen/caudate ratio is below the posterior putamen preservation threshold.")
        }
        if asymmetry >= 15 {
            warnings.append(String(format: "Striatal asymmetry %.1f%% exceeds the review threshold.", asymmetry))
        }
        let medicationWarnings = context?.medications.map {
            "\($0.displayName) may interfere with dopamine transporter binding; verify medication handling before final interpretation."
        } ?? []
        let percentile = ageMatchedPercentile(metrics: metrics, context: context, normalDatabase: normalDatabase)
        let limitations = [
            "DaTscan supports presynaptic dopaminergic deficit assessment and does not by itself distinguish PD from MSA, PSP, CBD, or DLB.",
            "A normal scan favors non-degenerative tremor physiology when the clinical question is ET versus parkinsonian syndrome."
        ]
        let summary = String(format: "%@; mean SBR %@, putamen/caudate %@.",
                             pattern.displayName,
                             metrics.meanStriatalBindingRatio.map { String(format: "%.3f", $0) } ?? "--",
                             metrics.putamenCaudateRatio.map { String(format: "%.3f", $0) } ?? "--")
        var lines = [summary]
        if let visualGrade = context?.visualGrade,
           visualGrade != .notAssessed {
            lines.append("Visual grade: \(visualGrade.displayName).")
        }
        if let percentile {
            lines.append(String(format: "Estimated age-matched SBR percentile: %.0f%%.", percentile))
        }
        if let drop = metrics.caudatePutamenDropoffPercent {
            lines.append(String(format: "Caudate-to-putamen drop-off: %.1f%%.", drop))
        }
        lines.append(contentsOf: warnings.map { "Warning: \($0)" })
        lines.append(contentsOf: medicationWarnings.map { "Medication: \($0)" })
        lines.append(contentsOf: limitations.map { "Limitation: \($0)" })
        return NeuroDaTscanClinicalAssessment(
            pattern: pattern,
            summary: summary,
            warnings: warnings,
            medicationWarnings: medicationWarnings,
            limitationLines: limitations,
            visualGrade: context?.visualGrade,
            ageMatchedPercentile: percentile,
            reportLines: lines
        )
    }

    private static func mean(_ values: [Double?]) -> Double? {
        let finite = values.compactMap { $0 }.filter(\.isFinite)
        return finite.isEmpty ? nil : finite.reduce(0, +) / Double(finite.count)
    }

    private static func ageMatchedPercentile(metrics: NeuroStriatalBindingMetrics,
                                             context: NeuroMovementDisorderContext?,
                                             normalDatabase: BrainPETNormalDatabase?) -> Double? {
        guard let meanSBR = metrics.meanStriatalBindingRatio else { return nil }
        let candidate = normalDatabase?.entries.first { entry in
            let name = BrainPETAnalysis.normalizedRegionName(entry.regionName)
            return name.contains("striat") || name.contains("putamen") || name.contains("caudate")
        }
        guard let entry = candidate, entry.sdSUVR > 0 else { return nil }
        if let age = context?.age,
           let ageMin = entry.ageMin,
           age < ageMin {
            return nil
        }
        if let age = context?.age,
           let ageMax = entry.ageMax,
           age > ageMax {
            return nil
        }
        let z = (meanSBR - entry.meanSUVR) / entry.sdSUVR
        return max(0, min(100, 100.0 / (1.0 + exp(-1.702 * z))))
    }
}

public enum NeuroPerfusionTerritory: String, CaseIterable, Identifiable, Codable, Sendable {
    case anteriorCerebral
    case middleCerebral
    case posteriorCerebral
    case cerebellar
    case deepGray
    case global

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anteriorCerebral: return "ACA"
        case .middleCerebral: return "MCA"
        case .posteriorCerebral: return "PCA"
        case .cerebellar: return "Cerebellar"
        case .deepGray: return "Deep gray"
        case .global: return "Global"
        }
    }
}

public struct NeuroPerfusionTerritorySummary: Identifiable, Codable, Equatable, Sendable {
    public var id: String { territory.rawValue }
    public let territory: NeuroPerfusionTerritory
    public let meanZScore: Double?
    public let peakZScore: Double?
    public let abnormalRegionCount: Int
    public let abnormalRegions: [String]
}

public struct NeuroPerfusionAssessment: Codable, Equatable, Sendable {
    public let territorySummaries: [NeuroPerfusionTerritorySummary]
    public let globalSummary: String
    public let warnings: [String]
    public let reportLines: [String]
}

public enum NeuroPerfusionInterpreter {
    public static func assess(report: BrainPETReport,
                              clusters: [NeuroQuantCluster]) -> NeuroPerfusionAssessment {
        var summaries: [NeuroPerfusionTerritorySummary] = []
        for territory in NeuroPerfusionTerritory.allCases {
            let regions = report.regions.filter { territoryForRegion($0.name) == territory }
            let abnormal = regions.filter { ($0.zScore ?? 0) <= -2 }
            let zScores = regions.compactMap(\.zScore)
            let meanZ = zScores.isEmpty ? nil : zScores.reduce(0, +) / Double(zScores.count)
            let peakZ = zScores.min()
            if !regions.isEmpty || territory == .global {
                summaries.append(
                    NeuroPerfusionTerritorySummary(
                        territory: territory,
                        meanZScore: territory == .global ? globalMeanZ(report: report) : meanZ,
                        peakZScore: territory == .global ? globalPeakZ(report: report) : peakZ,
                        abnormalRegionCount: territory == .global ? report.regions.filter { ($0.zScore ?? 0) <= -2 }.count : abnormal.count,
                        abnormalRegions: territory == .global ? clusters.prefix(6).map(\.dominantRegion) : abnormal.map(\.name)
                    )
                )
            }
        }
        let abnormalTerritories = summaries.filter { $0.abnormalRegionCount > 0 && $0.territory != .global }
        let globalSummary: String
        if abnormalTerritories.isEmpty {
            globalSummary = "No territory-level perfusion z-score abnormality reached threshold."
        } else {
            globalSummary = "Low perfusion involves \(abnormalTerritories.map { $0.territory.displayName }.joined(separator: ", "))."
        }
        var warnings: [String] = []
        if clusters.count >= 3 {
            warnings.append("Multiple low-perfusion clusters may indicate multiterritory vascular or mixed physiology.")
        }
        let reportLines = [globalSummary] + summaries.map { summary in
            String(format: "%@: mean z %@, peak z %@, abnormal regions %d",
                   summary.territory.displayName,
                   summary.meanZScore.map { String(format: "%.2f", $0) } ?? "--",
                   summary.peakZScore.map { String(format: "%.2f", $0) } ?? "--",
                   summary.abnormalRegionCount)
        } + warnings.map { "Warning: \($0)" }
        return NeuroPerfusionAssessment(
            territorySummaries: summaries,
            globalSummary: globalSummary,
            warnings: warnings,
            reportLines: reportLines
        )
    }

    fileprivate static func territoryForRegion(_ regionName: String) -> NeuroPerfusionTerritory {
        let name = BrainPETAnalysis.normalizedRegionName(regionName)
        if name.contains("cerebell") { return .cerebellar }
        if name.contains("basal") || name.contains("thalam") || name.contains("caudate") || name.contains("putamen") { return .deepGray }
        if name.contains("occipital") || name.contains("posterior") || name.contains("precuneus") { return .posteriorCerebral }
        if name.contains("frontal") || name.contains("anterior") { return .anteriorCerebral }
        if name.contains("temporal") || name.contains("parietal") { return .middleCerebral }
        return .global
    }

    private static func globalMeanZ(report: BrainPETReport) -> Double? {
        let zScores = report.regions.compactMap(\.zScore)
        return zScores.isEmpty ? nil : zScores.reduce(0, +) / Double(zScores.count)
    }

    private static func globalPeakZ(report: BrainPETReport) -> Double? {
        report.regions.compactMap(\.zScore).min()
    }
}

public struct NeuroCVRTerritoryDelta: Identifiable, Codable, Equatable, Sendable {
    public var id: String { territory.rawValue }
    public let territory: NeuroPerfusionTerritory
    public let baselineMeanSUVR: Double?
    public let challengeMeanSUVR: Double?
    public let reservePercent: Double?
    public let abnormal: Bool
}

public struct NeuroCVRChallengeComparison: Codable, Equatable, Sendable {
    public let deltas: [NeuroCVRTerritoryDelta]
    public let summary: String

    public static func compare(baseline: BrainPETReport,
                               challenge: BrainPETReport,
                               abnormalReserveThresholdPercent: Double = 10) -> NeuroCVRChallengeComparison {
        var deltas: [NeuroCVRTerritoryDelta] = []
        for territory in NeuroPerfusionTerritory.allCases where territory != .global {
            let baselineMean = meanSUVR(report: baseline, territory: territory)
            let challengeMean = meanSUVR(report: challenge, territory: territory)
            let reserve: Double?
            if let baselineMean, let challengeMean, baselineMean > 0 {
                reserve = (challengeMean - baselineMean) / baselineMean * 100
            } else {
                reserve = nil
            }
            deltas.append(
                NeuroCVRTerritoryDelta(
                    territory: territory,
                    baselineMeanSUVR: baselineMean,
                    challengeMeanSUVR: challengeMean,
                    reservePercent: reserve,
                    abnormal: (reserve ?? Double.infinity) < abnormalReserveThresholdPercent
                )
            )
        }
        let abnormal = deltas.filter(\.abnormal)
        let summary = abnormal.isEmpty
            ? "CVR challenge comparison shows no territory below reserve threshold."
            : "Reduced CVR in \(abnormal.map { $0.territory.displayName }.joined(separator: ", "))."
        return NeuroCVRChallengeComparison(deltas: deltas, summary: summary)
    }

    private static func meanSUVR(report: BrainPETReport,
                                 territory: NeuroPerfusionTerritory) -> Double? {
        let values = report.regions
            .filter { NeuroPerfusionInterpreter.territoryForRegion($0.name) == territory }
            .map(\.suvr)
            .filter(\.isFinite)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

public struct NeuroTimelineEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let studyUID: String
    public let workflow: NeuroQuantWorkflowProtocol
    public let targetSUVR: Double?
    public let centiloid: Double?
    public let tauStage: String?
    public let cognitiveScore: Double?
    public let therapyPhase: String?
    public let mriRiskLevel: NeuroMRIRiskLevel?
    public let readinessStatus: NeuroQuantClinicalReadinessStatus?

    public init(id: String = UUID().uuidString,
                date: Date,
                studyUID: String,
                workflow: NeuroQuantWorkflowProtocol,
                targetSUVR: Double?,
                centiloid: Double? = nil,
                tauStage: String? = nil,
                cognitiveScore: Double? = nil,
                therapyPhase: String? = nil,
                mriRiskLevel: NeuroMRIRiskLevel? = nil,
                readinessStatus: NeuroQuantClinicalReadinessStatus? = nil) {
        self.id = id
        self.date = date
        self.studyUID = studyUID
        self.workflow = workflow
        self.targetSUVR = targetSUVR
        self.centiloid = centiloid
        self.tauStage = tauStage
        self.cognitiveScore = cognitiveScore
        self.therapyPhase = therapyPhase
        self.mriRiskLevel = mriRiskLevel
        self.readinessStatus = readinessStatus
    }
}

public struct NeuroLongitudinalTimeline: Codable, Equatable, Sendable {
    public let events: [NeuroTimelineEvent]
    public let latestChange: String?
    public let trendSummary: String
    public let slopeLines: [String]
}

public enum NeuroTimelineBuilder {
    public static func build(events: [NeuroTimelineEvent]) -> NeuroLongitudinalTimeline {
        let sorted = events.sorted { $0.date < $1.date }
        guard let previous = sorted.dropLast().last,
              let latest = sorted.last else {
            return NeuroLongitudinalTimeline(
                events: sorted,
                latestChange: nil,
                trendSummary: sorted.isEmpty ? "No neuroquant timeline events." : "Single neuroquant baseline event.",
                slopeLines: []
            )
        }
        let latestChange: String?
        if let priorCL = previous.centiloid, let currentCL = latest.centiloid {
            latestChange = String(format: "Centiloid %+.1f", currentCL - priorCL)
        } else if let priorSUVR = previous.targetSUVR, let currentSUVR = latest.targetSUVR {
            latestChange = String(format: "Target SUVR %+.3f", currentSUVR - priorSUVR)
        } else if previous.tauStage != latest.tauStage {
            latestChange = "Tau stage \(previous.tauStage ?? "--") to \(latest.tauStage ?? "--")"
        } else {
            latestChange = nil
        }
        let slopeLines = slopes(events: sorted)
        let trend = latestChange.map { "Latest neuroquant change: \($0)." } ?? "No comparable quantitative change between the last two events."
        return NeuroLongitudinalTimeline(
            events: sorted,
            latestChange: latestChange,
            trendSummary: trend,
            slopeLines: slopeLines
        )
    }

    private static func slopes(events: [NeuroTimelineEvent]) -> [String] {
        guard let first = events.first,
              let last = events.last,
              last.date > first.date else { return [] }
        let years = last.date.timeIntervalSince(first.date) / (365.25 * 24 * 60 * 60)
        guard years > 0 else { return [] }
        var lines: [String] = []
        if let firstCL = first.centiloid, let lastCL = last.centiloid {
            lines.append(String(format: "Centiloid slope: %+.1f/year", (lastCL - firstCL) / years))
        }
        if let firstSUVR = first.targetSUVR, let lastSUVR = last.targetSUVR {
            lines.append(String(format: "Target SUVR slope: %+.3f/year", (lastSUVR - firstSUVR) / years))
        }
        if let firstCognitive = first.cognitiveScore, let lastCognitive = last.cognitiveScore {
            lines.append(String(format: "Cognitive score slope: %+.2f/year", (lastCognitive - firstCognitive) / years))
        }
        let therapyEvents = events.compactMap(\.therapyPhase)
        if !therapyEvents.isEmpty {
            lines.append("Therapy phases: \(therapyEvents.joined(separator: " -> "))")
        }
        return lines
    }
}

public enum NeuroClinicalReportComposer {
    public static func compose(base: NeuroQuantStructuredReport,
                               aucDecision: NeuroAUCDecision?,
                               diseasePatterns: [NeuroDiseasePatternFinding],
                               mriAssessment: NeuroMRIContextAssessment?,
                               biomarkerBoard: NeuroDementiaBiomarkerBoard?,
                               antiAmyloidAssessment: NeuroAntiAmyloidTherapyAssessment?,
                               visualReadAssist: NeuroVisualReadAssist?,
                               normalGovernance: NeuroNormalDatabaseGovernance?,
                               datscanAssessment: NeuroDaTscanClinicalAssessment?,
                               perfusionAssessment: NeuroPerfusionAssessment?,
                               seizureComparison: NeuroSeizurePerfusionComparison?,
                               clinicalQA: NeuroClinicalQAResult?,
                               timeline: NeuroLongitudinalTimeline? = nil,
                               registrationPipeline: NeuroRegistrationPipelineResult? = nil,
                               dicomExportManifest: NeuroDICOMExportManifest? = nil,
                               validationDashboard: NeuroValidationWorkbenchDashboard? = nil,
                               comparisonWorkspace: NeuroComparisonWorkspace? = nil,
                               antiAmyloidClinicTracker: NeuroAntiAmyloidClinicTracker? = nil,
                               aiClassifierPrediction: NeuroAIClassifierPrediction? = nil,
                               dicomAuditTrail: NeuroDICOMExportAuditTrail? = nil) -> NeuroQuantStructuredReport {
        var sections = base.sections
        var insertIndex = min(1, sections.count)
        func insert(_ section: NeuroQuantReportSection) {
            sections.insert(section, at: insertIndex)
            insertIndex += 1
        }
        if let registrationPipeline {
            insert(NeuroQuantReportSection(id: "neuro-registration-pipeline", title: "Registration Pipeline", lines: registrationPipeline.reportLines))
        }
        if let aucDecision {
            insert(NeuroQuantReportSection(id: "auc", title: "Appropriateness", lines: aucDecision.reportLines))
        }
        if !diseasePatterns.isEmpty {
            insert(
                NeuroQuantReportSection(
                    id: "disease-pattern",
                    title: "Disease Pattern",
                    lines: diseasePatterns.prefix(4).map { finding in
                        var line = finding.reportLine
                        if !finding.supportingRegions.isEmpty {
                            line += " Regions: \(finding.supportingRegions.prefix(5).joined(separator: ", "))."
                        }
                        return line
                    }
                )
            )
        }
        if let biomarkerBoard {
            insert(NeuroQuantReportSection(id: "atn-board", title: "AT(N) Board", lines: biomarkerBoard.reportLines))
        }
        if let antiAmyloidAssessment {
            insert(NeuroQuantReportSection(id: "anti-amyloid", title: "Anti-Amyloid Therapy", lines: antiAmyloidAssessment.reportLines))
        }
        if let visualReadAssist {
            insert(NeuroQuantReportSection(id: "visual-read", title: "Visual Read Assist", lines: visualReadAssist.reportLines))
        }
        if let normalGovernance {
            insert(NeuroQuantReportSection(id: "normal-governance", title: "Reference Governance", lines: normalGovernance.reportLines))
        }
        if let validationDashboard {
            insert(NeuroQuantReportSection(id: "validation-workbench", title: "Validation Workbench", lines: validationDashboard.reportLines))
        }
        if let mriAssessment {
            insert(NeuroQuantReportSection(id: "mri-context", title: "MRI Context", lines: mriAssessment.reportLines))
        }
        if let datscanAssessment {
            insert(NeuroQuantReportSection(id: "datscan-clinical", title: "DaTscan Assessment", lines: datscanAssessment.reportLines))
        }
        if let perfusionAssessment {
            insert(NeuroQuantReportSection(id: "perfusion-clinical", title: "Perfusion Assessment", lines: perfusionAssessment.reportLines))
        }
        if let seizureComparison {
            insert(NeuroQuantReportSection(id: "seizure-perfusion", title: "Seizure Perfusion", lines: seizureComparison.reportLines))
        }
        if let comparisonWorkspace {
            insert(NeuroQuantReportSection(id: "comparison-workspace", title: "Comparison Workspace", lines: comparisonWorkspace.reportLines))
        }
        if let antiAmyloidClinicTracker {
            insert(NeuroQuantReportSection(id: "anti-amyloid-clinic", title: "Anti-Amyloid Clinic Tracker", lines: antiAmyloidClinicTracker.reportLines))
        }
        if let aiClassifierPrediction {
            insert(NeuroQuantReportSection(id: "ai-classifier", title: "AI Classifier Hook", lines: aiClassifierPrediction.reportLines))
        }
        if let dicomExportManifest {
            insert(NeuroQuantReportSection(id: "dicom-export", title: "DICOM Export", lines: dicomExportManifest.reportLines))
        }
        if let dicomAuditTrail {
            insert(NeuroQuantReportSection(id: "dicom-audit", title: "DICOM Audit Trail", lines: dicomAuditTrail.reportLines))
        }
        if let clinicalQA {
            insert(NeuroQuantReportSection(id: "clinical-qa", title: "Clinical QA", lines: clinicalQA.reportLines))
        }
        if let timeline {
            insert(
                NeuroQuantReportSection(
                    id: "timeline",
                    title: "Longitudinal Timeline",
                    lines: [timeline.trendSummary] + timeline.slopeLines + timeline.events.suffix(4).map { event in
                        let value = event.centiloid.map { String(format: "CL %.1f", $0) }
                            ?? event.targetSUVR.map { String(format: "SUVR %.3f", $0) }
                            ?? event.tauStage
                            ?? "--"
                        return "\(event.workflow.shortName) \(event.studyUID): \(value)"
                    }
                )
            )
        }
        let impression: String
        if let topPattern = diseasePatterns.first, topPattern.kind != .normalOrNonspecific {
            impression = "\(base.impression) Pattern support: \(topPattern.summary)"
        } else if let biomarkerBoard {
            impression = "\(base.impression) \(biomarkerBoard.summary)"
        } else {
            impression = base.impression
        }
        return NeuroQuantStructuredReport(
            generatedAt: base.generatedAt,
            workflow: base.workflow,
            impression: impression,
            sections: sections
        )
    }
}

public enum NeuroATNMarkerState: String, Codable, Sendable {
    case unknown
    case negative
    case equivocal
    case positive

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .negative: return "Negative"
        case .equivocal: return "Equivocal"
        case .positive: return "Positive"
        }
    }

    public var shortName: String {
        switch self {
        case .unknown: return "?"
        case .negative: return "-"
        case .equivocal: return "+/-"
        case .positive: return "+"
        }
    }
}

public struct NeuroDementiaBiomarkerBoard: Codable, Equatable, Sendable {
    public let amyloid: NeuroATNMarkerState
    public let tau: NeuroATNMarkerState
    public let neurodegeneration: NeuroATNMarkerState
    public let vascularBurden: NeuroVascularBurden
    public let phenotype: String
    public let confidence: Double
    public let summary: String
    public let reportLines: [String]

    public static func make(report: BrainPETReport,
                            workflow: NeuroQuantWorkflowProtocol,
                            patterns: [NeuroDiseasePatternFinding],
                            mriAssessment: NeuroMRIContextAssessment?,
                            timeline: NeuroLongitudinalTimeline? = nil) -> NeuroDementiaBiomarkerBoard {
        let amyloid = amyloidState(report: report, workflow: workflow, patterns: patterns)
        let tau = tauState(report: report, workflow: workflow, patterns: patterns)
        let neurodegeneration = neurodegenerationState(report: report, workflow: workflow, patterns: patterns, mriAssessment: mriAssessment)
        let vascular = vascularState(patterns: patterns, mriAssessment: mriAssessment)
        let phenotype = "A\(amyloid.shortName) T\(tau.shortName) N\(neurodegeneration.shortName)"
        let knownCount = [amyloid, tau, neurodegeneration].filter { $0 != .unknown }.count
        var confidence = Double(knownCount) / 3.0
        if vascular == .moderate || vascular == .severe { confidence *= 0.9 }
        let summary: String
        if amyloid == .positive && tau == .positive && neurodegeneration == .positive {
            summary = "AT(N) board supports biologic Alzheimer disease with neurodegeneration."
        } else if amyloid == .positive && tau == .unknown {
            summary = "AT(N) board confirms amyloid positivity; tau status remains unresolved."
        } else if neurodegeneration == .positive && amyloid != .positive {
            summary = "AT(N) board shows neurodegeneration without confirmed amyloid positivity."
        } else {
            summary = "AT(N) board is incomplete or nonspecific with the available studies."
        }
        var lines = [
            "Profile: \(phenotype)",
            "Amyloid: \(amyloid.displayName)",
            "Tau: \(tau.displayName)",
            "Neurodegeneration: \(neurodegeneration.displayName)",
            "Vascular burden: \(vascular.displayName)",
            String(format: "Board confidence: %.0f%%", confidence * 100),
            summary
        ]
        if let timeline {
            lines.append("Timeline: \(timeline.trendSummary)")
        }
        return NeuroDementiaBiomarkerBoard(
            amyloid: amyloid,
            tau: tau,
            neurodegeneration: neurodegeneration,
            vascularBurden: vascular,
            phenotype: phenotype,
            confidence: confidence,
            summary: summary,
            reportLines: lines
        )
    }

    private static func amyloidState(report: BrainPETReport,
                                     workflow: NeuroQuantWorkflowProtocol,
                                     patterns: [NeuroDiseasePatternFinding]) -> NeuroATNMarkerState {
        if patterns.contains(where: { $0.kind == .amyloidPositive }) { return .positive }
        guard workflow == .amyloidCentiloid else { return .unknown }
        if let centiloid = report.centiloid {
            if centiloid >= 25 { return .positive }
            if centiloid >= 15 { return .equivocal }
            return .negative
        }
        if let target = report.targetSUVR {
            if target >= 1.10 { return .positive }
            if target >= 1.00 { return .equivocal }
            return .negative
        }
        return .unknown
    }

    private static func tauState(report: BrainPETReport,
                                 workflow: NeuroQuantWorkflowProtocol,
                                 patterns: [NeuroDiseasePatternFinding]) -> NeuroATNMarkerState {
        if patterns.contains(where: { $0.kind == .tauBraakAdvanced }) { return .positive }
        guard workflow == .tauBraak else { return .unknown }
        guard let tau = report.tauGrade else { return .unknown }
        if tau.stage.localizedCaseInsensitiveContains("negative") { return .negative }
        if tau.stage.contains("I/II") { return .equivocal }
        return .positive
    }

    private static func neurodegenerationState(report: BrainPETReport,
                                               workflow: NeuroQuantWorkflowProtocol,
                                               patterns: [NeuroDiseasePatternFinding],
                                               mriAssessment: NeuroMRIContextAssessment?) -> NeuroATNMarkerState {
        if patterns.contains(where: { [.alzheimerLike, .frontotemporalLike, .dementiaWithLewyBodiesLike].contains($0.kind) }) {
            return .positive
        }
        if mriAssessment?.modifiers.contains(where: { $0.localizedCaseInsensitiveContains("atrophy") }) == true {
            return .positive
        }
        guard workflow == .fdgDementia else { return .unknown }
        return report.hypometabolicRegions.isEmpty ? .negative : .positive
    }

    private static func vascularState(patterns: [NeuroDiseasePatternFinding],
                                      mriAssessment: NeuroMRIContextAssessment?) -> NeuroVascularBurden {
        if let line = mriAssessment?.modifiers.first(where: { $0.localizedCaseInsensitiveContains("vascular burden") }) {
            let lower = line.lowercased()
            if lower.contains("severe") { return .severe }
            if lower.contains("moderate") { return .moderate }
            if lower.contains("mild") { return .mild }
        }
        return patterns.contains(where: { $0.kind == .vascularOrMixed }) ? .moderate : .none
    }
}

public enum NeuroAntiAmyloidAgent: String, CaseIterable, Identifiable, Codable, Sendable {
    case lecanemab
    case donanemab
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lecanemab: return "Lecanemab"
        case .donanemab: return "Donanemab"
        case .other: return "Other anti-amyloid"
        }
    }
}

public enum NeuroApoEStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case unknown
    case nonCarrier
    case heterozygousE4
    case homozygousE4

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unknown: return "ApoE unknown"
        case .nonCarrier: return "ApoE e4 non-carrier"
        case .heterozygousE4: return "ApoE e4 heterozygous"
        case .homozygousE4: return "ApoE e4 homozygous"
        }
    }
}

public enum NeuroAntithromboticStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case antiplatelet
    case anticoagulant
    case recentThrombolytic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .antiplatelet: return "Antiplatelet"
        case .anticoagulant: return "Anticoagulant"
        case .recentThrombolytic: return "Recent thrombolytic"
        }
    }
}

public enum NeuroAntiAmyloidAction: String, Codable, Sendable {
    case notApplicable
    case eligibleWithMonitoring
    case deferForWorkup
    case highRiskReview
    case holdTherapy

    public var displayName: String {
        switch self {
        case .notApplicable: return "Not applicable"
        case .eligibleWithMonitoring: return "Eligible with monitoring"
        case .deferForWorkup: return "Defer for workup"
        case .highRiskReview: return "High-risk review"
        case .holdTherapy: return "Hold therapy"
        }
    }
}

public struct NeuroAntiAmyloidTherapyContext: Codable, Equatable, Sendable {
    public let candidateForTherapy: Bool
    public let agent: NeuroAntiAmyloidAgent
    public let apoEStatus: NeuroApoEStatus
    public let antithromboticStatus: NeuroAntithromboticStatus
    public let infusionNumber: Int?
    public let symptomaticARIA: Bool
    public let therapyStartDate: Date?
    public let lastMRIAt: Date?
    public let amyloidConfirmedOverride: Bool?

    public init(candidateForTherapy: Bool,
                agent: NeuroAntiAmyloidAgent = .lecanemab,
                apoEStatus: NeuroApoEStatus = .unknown,
                antithromboticStatus: NeuroAntithromboticStatus = .none,
                infusionNumber: Int? = nil,
                symptomaticARIA: Bool = false,
                therapyStartDate: Date? = nil,
                lastMRIAt: Date? = nil,
                amyloidConfirmedOverride: Bool? = nil) {
        self.candidateForTherapy = candidateForTherapy
        self.agent = agent
        self.apoEStatus = apoEStatus
        self.antithromboticStatus = antithromboticStatus
        self.infusionNumber = infusionNumber
        self.symptomaticARIA = symptomaticARIA
        self.therapyStartDate = therapyStartDate
        self.lastMRIAt = lastMRIAt
        self.amyloidConfirmedOverride = amyloidConfirmedOverride
    }
}

public struct NeuroAntiAmyloidTherapyAssessment: Codable, Equatable, Sendable {
    public let action: NeuroAntiAmyloidAction
    public let riskLevel: NeuroMRIRiskLevel
    public let blockers: [String]
    public let warnings: [String]
    public let monitoringSchedule: [String]
    public let reportLines: [String]

    public static func assess(context: NeuroAntiAmyloidTherapyContext,
                              biomarkerBoard: NeuroDementiaBiomarkerBoard?,
                              mriAssessment: NeuroMRIContextAssessment?,
                              aucDecision: NeuroAUCDecision?) -> NeuroAntiAmyloidTherapyAssessment {
        guard context.candidateForTherapy else {
            return NeuroAntiAmyloidTherapyAssessment(
                action: .notApplicable,
                riskLevel: .incomplete,
                blockers: [],
                warnings: [],
                monitoringSchedule: [],
                reportLines: ["Anti-amyloid therapy workflow not requested."]
            )
        }
        var blockers: [String] = []
        var warnings: [String] = []
        let amyloidConfirmed = context.amyloidConfirmedOverride
            ?? (biomarkerBoard?.amyloid == .positive)
        if !amyloidConfirmed {
            blockers.append("Amyloid positivity is not confirmed in the active biomarker board.")
        }
        if aucDecision?.rating == .rarelyAppropriate {
            blockers.append("AUC rating is rarely appropriate for the selected PET workflow.")
        }
        let risk = mriAssessment?.riskLevel ?? .incomplete
        if risk == .incomplete {
            blockers.append("Baseline MRI safety context is incomplete.")
        }
        if risk == .high {
            blockers.append("MRI safety screen is high risk for ARIA/hemorrhage review.")
        }
        if context.symptomaticARIA || mriAssessment?.warnings.contains(where: { $0.localizedCaseInsensitiveContains("ARIA-E") }) == true {
            blockers.append("Possible symptomatic or active ARIA requires therapy hold/review.")
        }
        switch context.apoEStatus {
        case .homozygousE4:
            warnings.append("ApoE e4 homozygous status increases ARIA risk; document shared decision-making.")
        case .heterozygousE4:
            warnings.append("ApoE e4 carrier status increases ARIA risk.")
        case .unknown:
            warnings.append("ApoE status is unknown.")
        case .nonCarrier:
            break
        }
        if context.antithromboticStatus == .anticoagulant || context.antithromboticStatus == .recentThrombolytic {
            warnings.append("Antithrombotic status needs therapy-specific risk review.")
        }
        let schedule = monitoringSchedule(agent: context.agent, infusionNumber: context.infusionNumber)
        let action: NeuroAntiAmyloidAction
        if blockers.contains(where: { $0.localizedCaseInsensitiveContains("hold") || $0.localizedCaseInsensitiveContains("ARIA") }) {
            action = .holdTherapy
        } else if !blockers.isEmpty {
            action = .deferForWorkup
        } else if risk == .moderate || context.antithromboticStatus != .none || context.apoEStatus == .homozygousE4 {
            action = .highRiskReview
        } else {
            action = .eligibleWithMonitoring
        }
        var lines = [
            "Agent: \(context.agent.displayName)",
            "Action: \(action.displayName)",
            "MRI risk: \(risk.displayName)"
        ]
        lines.append(contentsOf: schedule)
        lines.append(contentsOf: blockers.map { "Blocker: \($0)" })
        lines.append(contentsOf: warnings.map { "Warning: \($0)" })
        return NeuroAntiAmyloidTherapyAssessment(
            action: action,
            riskLevel: risk,
            blockers: blockers,
            warnings: warnings,
            monitoringSchedule: schedule,
            reportLines: lines
        )
    }

    private static func monitoringSchedule(agent: NeuroAntiAmyloidAgent,
                                           infusionNumber: Int?) -> [String] {
        let next = infusionNumber.map { "Current infusion: \($0)." } ?? "Baseline or infusion number not entered."
        switch agent {
        case .lecanemab:
            return [next, "MRI monitoring: baseline, before 5th, 7th, and 14th infusions, plus symptom-triggered MRI."]
        case .donanemab:
            return [next, "MRI monitoring: baseline, early-treatment scheduled MRIs per local donanemab protocol, plus symptom-triggered MRI."]
        case .other:
            return [next, "MRI monitoring: follow agent-specific label and institutional ARIA pathway."]
        }
    }
}

public enum NeuroVisualReadImpression: String, CaseIterable, Identifiable, Codable, Sendable {
    case notAssessed
    case normal
    case abnormalLowUptake
    case abnormalHighBinding
    case abnormalStriatalDeficit
    case abnormalPerfusion
    case mixed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .notAssessed: return "Not assessed"
        case .normal: return "Normal"
        case .abnormalLowUptake: return "Low uptake"
        case .abnormalHighBinding: return "High binding"
        case .abnormalStriatalDeficit: return "Striatal deficit"
        case .abnormalPerfusion: return "Perfusion deficit"
        case .mixed: return "Mixed"
        }
    }
}

public enum NeuroVisualReadConcordance: String, Codable, Sendable {
    case notAssessed
    case concordant
    case discordant
    case indeterminate

    public var displayName: String {
        switch self {
        case .notAssessed: return "Not assessed"
        case .concordant: return "Concordant"
        case .discordant: return "Discordant"
        case .indeterminate: return "Indeterminate"
        }
    }
}

public struct NeuroVisualReadInput: Codable, Equatable, Sendable {
    public let impression: NeuroVisualReadImpression
    public let confidence: Double
    public let notes: String?

    public init(impression: NeuroVisualReadImpression = .notAssessed,
                confidence: Double = 0,
                notes: String? = nil) {
        self.impression = impression
        self.confidence = confidence
        self.notes = notes
    }
}

public struct NeuroVisualReadChecklistItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let expected: Bool
    public let satisfied: Bool
}

public struct NeuroVisualReadAssist: Codable, Equatable, Sendable {
    public let templateName: String
    public let concordance: NeuroVisualReadConcordance
    public let checklist: [NeuroVisualReadChecklistItem]
    public let warnings: [String]
    public let reportLines: [String]

    public static func make(workflow: NeuroQuantWorkflowProtocol,
                            report: BrainPETReport,
                            patterns: [NeuroDiseasePatternFinding],
                            visualRead: NeuroVisualReadInput?) -> NeuroVisualReadAssist {
        let expected = expectedImpression(workflow: workflow, patterns: patterns, report: report)
        let input = visualRead ?? NeuroVisualReadInput()
        let concordance: NeuroVisualReadConcordance
        if input.impression == .notAssessed {
            concordance = .notAssessed
        } else if input.impression == expected || expected == .mixed {
            concordance = .concordant
        } else if expected == .normal {
            concordance = input.impression == .normal ? .concordant : .discordant
        } else {
            concordance = input.confidence < 0.4 ? .indeterminate : .discordant
        }
        let checklist = checklistItems(workflow: workflow, patterns: patterns, report: report)
        var warnings: [String] = []
        if concordance == .discordant {
            warnings.append("Visual read and quantitative pattern are discordant; adjudication is recommended before sign-off.")
        }
        if input.impression == .notAssessed {
            warnings.append("Visual read has not been documented.")
        }
        var lines = [
            "Template: \(templateName(for: workflow))",
            "Visual impression: \(input.impression.displayName)",
            "Quant expected: \(expected.displayName)",
            "Concordance: \(concordance.displayName)"
        ]
        lines.append(contentsOf: checklist.map { "\($0.satisfied ? "Pass" : "Review"): \($0.label)" })
        lines.append(contentsOf: warnings.map { "Warning: \($0)" })
        if let notes = input.notes, !notes.isEmpty {
            lines.append("Visual note: \(notes)")
        }
        return NeuroVisualReadAssist(
            templateName: templateName(for: workflow),
            concordance: concordance,
            checklist: checklist,
            warnings: warnings,
            reportLines: lines
        )
    }

    private static func expectedImpression(workflow: NeuroQuantWorkflowProtocol,
                                           patterns: [NeuroDiseasePatternFinding],
                                           report: BrainPETReport) -> NeuroVisualReadImpression {
        if patterns.contains(where: { $0.kind == .normalOrNonspecific }) { return .normal }
        switch workflow {
        case .fdgDementia:
            return report.hypometabolicRegions.isEmpty ? .normal : .abnormalLowUptake
        case .amyloidCentiloid, .tauBraak:
            return patterns.contains(where: { $0.kind == .amyloidPositive || $0.kind == .tauBraakAdvanced || $0.kind == .alzheimerLike })
                ? .abnormalHighBinding
                : .normal
        case .datscanStriatal:
            return patterns.contains(where: { $0.kind == .dopaminergicDeficit }) ? .abnormalStriatalDeficit : .normal
        case .hmpaoPerfusion:
            return patterns.contains(where: { $0.kind == .vascularOrMixed }) ? .abnormalPerfusion : .normal
        }
    }

    private static func checklistItems(workflow: NeuroQuantWorkflowProtocol,
                                       patterns: [NeuroDiseasePatternFinding],
                                       report: BrainPETReport) -> [NeuroVisualReadChecklistItem] {
        switch workflow {
        case .fdgDementia:
            return [
                item("posterior-cingulate", "Posterior cingulate/precuneus reviewed", patterns.contains { $0.kind == .alzheimerLike }),
                item("occipital", "Occipital cortex reviewed for DLB-like pattern", patterns.contains { $0.kind == .dementiaWithLewyBodiesLike }),
                item("frontal-temporal", "Frontal/anterior temporal pattern reviewed", patterns.contains { $0.kind == .frontotemporalLike })
            ]
        case .amyloidCentiloid:
            return [
                item("gray-white", "Cortical gray-white contrast reviewed", report.centiloid != nil),
                item("cerebellar-reference", "Cerebellar reference reviewed", !report.referenceRegionName.isEmpty)
            ]
        case .tauBraak:
            return [
                item("medial-temporal", "Medial temporal uptake reviewed", report.tauGrade != nil),
                item("off-target", "Off-target basal ganglia/choroid plexus reviewed", true)
            ]
        case .datscanStriatal:
            return [
                item("comma-dot", "Comma-to-dot striatal morphology reviewed", patterns.contains { $0.kind == .dopaminergicDeficit }),
                item("occipital-background", "Occipital background normalization reviewed", report.referenceRegionName.localizedCaseInsensitiveContains("occipital"))
            ]
        case .hmpaoPerfusion:
            return [
                item("territory", "Vascular territory pattern reviewed", patterns.contains { $0.kind == .vascularOrMixed }),
                item("global", "Global normalization reviewed", !report.referenceRegionName.isEmpty)
            ]
        }
    }

    private static func item(_ id: String, _ label: String, _ expected: Bool) -> NeuroVisualReadChecklistItem {
        NeuroVisualReadChecklistItem(id: id, label: label, expected: expected, satisfied: expected)
    }

    private static func templateName(for workflow: NeuroQuantWorkflowProtocol) -> String {
        switch workflow {
        case .fdgDementia: return "FDG dementia visual template"
        case .amyloidCentiloid: return "Amyloid cortical positivity template"
        case .tauBraak: return "Tau Braak visual template"
        case .datscanStriatal: return "DaTscan striatal comma/dot template"
        case .hmpaoPerfusion: return "HMPAO perfusion territory template"
        }
    }
}

public enum NeuroDaTscanInterferingMedication: String, CaseIterable, Identifiable, Codable, Sendable {
    case amphetamine
    case bupropion
    case methylphenidate
    case cocaine
    case modafinil
    case benztropine
    case sertraline

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .amphetamine: return "Amphetamine"
        case .bupropion: return "Bupropion"
        case .methylphenidate: return "Methylphenidate"
        case .cocaine: return "Cocaine"
        case .modafinil: return "Modafinil"
        case .benztropine: return "Benztropine"
        case .sertraline: return "Sertraline"
        }
    }
}

public enum NeuroDaTscanVisualGrade: String, CaseIterable, Identifiable, Codable, Sendable {
    case notAssessed
    case normal
    case equivocal
    case abnormalMild
    case abnormalModerateSevere

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .notAssessed: return "Not assessed"
        case .normal: return "Normal"
        case .equivocal: return "Equivocal"
        case .abnormalMild: return "Abnormal mild"
        case .abnormalModerateSevere: return "Abnormal moderate/severe"
        }
    }
}

public struct NeuroMovementDisorderContext: Codable, Equatable, Sendable {
    public let age: Double?
    public let medications: [NeuroDaTscanInterferingMedication]
    public let visualGrade: NeuroDaTscanVisualGrade
    public let clinicalQuestion: NeuroClinicalQuestion

    public init(age: Double? = nil,
                medications: [NeuroDaTscanInterferingMedication] = [],
                visualGrade: NeuroDaTscanVisualGrade = .notAssessed,
                clinicalQuestion: NeuroClinicalQuestion = .parkinsonism) {
        self.age = age
        self.medications = medications
        self.visualGrade = visualGrade
        self.clinicalQuestion = clinicalQuestion
    }
}

public struct NeuroSeizureFocusCandidate: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let regionName: String
    public let ictalInterictalRatio: Double?
    public let zDelta: Double?
    public let confidence: Double
}

public struct NeuroSeizurePerfusionComparison: Codable, Equatable, Sendable {
    public let candidates: [NeuroSeizureFocusCandidate]
    public let summary: String
    public let reportLines: [String]

    public static func compare(interictal: BrainPETReport,
                               ictal: BrainPETReport,
                               workflow: NeuroQuantWorkflowProtocol = .hmpaoPerfusion) -> NeuroSeizurePerfusionComparison {
        let ictalByID = Dictionary(uniqueKeysWithValues: ictal.regions.map { ($0.labelID, $0) })
        let candidates = interictal.regions.compactMap { baseline -> NeuroSeizureFocusCandidate? in
            guard let current = ictalByID[baseline.labelID] else { return nil }
            let ratio = baseline.suvr > 0 ? current.suvr / baseline.suvr : nil
            let zDelta: Double?
            if let baseZ = baseline.zScore, let ictalZ = current.zScore {
                zDelta = ictalZ - baseZ
            } else {
                zDelta = nil
            }
            let confidence = min(0.95, max(0, ((ratio ?? 1) - 1) * 0.65 + max(0, zDelta ?? 0) * 0.08))
            guard confidence >= 0.15 else { return nil }
            return NeuroSeizureFocusCandidate(
                id: "\(workflow.rawValue)-\(baseline.labelID)",
                regionName: current.name,
                ictalInterictalRatio: ratio,
                zDelta: zDelta,
                confidence: confidence
            )
        }.sorted { $0.confidence > $1.confidence }
        let summary = candidates.first.map {
            String(format: "Top seizure perfusion candidate: %@ (confidence %.0f%%).", $0.regionName, $0.confidence * 100)
        } ?? "No ictal/interictal perfusion candidate reached ranking threshold."
        let lines = [summary] + candidates.prefix(5).map { candidate in
            String(format: "%@: ratio %@, z delta %@, confidence %.0f%%",
                   candidate.regionName,
                   candidate.ictalInterictalRatio.map { String(format: "%.2f", $0) } ?? "--",
                   candidate.zDelta.map { String(format: "%+.2f", $0) } ?? "--",
                   candidate.confidence * 100)
        }
        return NeuroSeizurePerfusionComparison(candidates: candidates, summary: summary, reportLines: lines)
    }
}

public enum NeuroClinicalQAStatus: String, Codable, Sendable {
    case blocked
    case warning
    case ready
    case signed

    public var displayName: String {
        switch self {
        case .blocked: return "Blocked"
        case .warning: return "Warning"
        case .ready: return "Ready"
        case .signed: return "Signed"
        }
    }
}

public struct NeuroClinicalSignoff: Codable, Equatable, Sendable {
    public let readerName: String
    public let signedAt: Date
    public let attestation: String
    public let thresholdOverrides: [String]
    public let correctedRegions: [String]

    public init(readerName: String,
                signedAt: Date = Date(),
                attestation: String,
                thresholdOverrides: [String] = [],
                correctedRegions: [String] = []) {
        self.readerName = readerName
        self.signedAt = signedAt
        self.attestation = attestation
        self.thresholdOverrides = thresholdOverrides
        self.correctedRegions = correctedRegions
    }
}

public struct NeuroClinicalAuditEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: String
    public let summary: String

    public init(id: UUID = UUID(),
                timestamp: Date = Date(),
                kind: String,
                summary: String) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
    }
}

public struct NeuroClinicalQAResult: Codable, Equatable, Sendable {
    public let status: NeuroClinicalQAStatus
    public let badges: [String]
    public let blockers: [String]
    public let warnings: [String]
    public let auditEvents: [NeuroClinicalAuditEvent]
    public let reportLines: [String]

    public static func evaluate(readiness: NeuroQuantClinicalReadiness,
                                aucDecision: NeuroAUCDecision?,
                                visualReadAssist: NeuroVisualReadAssist?,
                                normalGovernance: NeuroNormalDatabaseGovernance?,
                                antiAmyloidAssessment: NeuroAntiAmyloidTherapyAssessment?,
                                signoff: NeuroClinicalSignoff?) -> NeuroClinicalQAResult {
        var blockers = readiness.blockers
        var warnings = readiness.warnings
        var badges = [
            "Readiness: \(readiness.status.displayName)",
            "Evidence: \(readiness.evidenceLevel.displayName)"
        ]
        if let aucDecision {
            badges.append("AUC: \(aucDecision.rating.displayName)")
            if aucDecision.rating == .rarelyAppropriate {
                blockers.append("AUC rating is rarely appropriate.")
            }
        }
        if let visualReadAssist {
            badges.append("Visual: \(visualReadAssist.concordance.displayName)")
            warnings.append(contentsOf: visualReadAssist.warnings)
        }
        if let normalGovernance {
            badges.append("Reference: \(normalGovernance.status.displayName)")
            blockers.append(contentsOf: normalGovernance.blockers)
            warnings.append(contentsOf: normalGovernance.warnings)
        }
        if let antiAmyloidAssessment {
            badges.append("Therapy: \(antiAmyloidAssessment.action.displayName)")
            blockers.append(contentsOf: antiAmyloidAssessment.blockers)
            warnings.append(contentsOf: antiAmyloidAssessment.warnings)
        }
        var audit: [NeuroClinicalAuditEvent] = []
        if let signoff {
            if signoff.readerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                warnings.append("Sign-off reader name is blank.")
            } else {
                audit.append(NeuroClinicalAuditEvent(kind: "signoff", summary: "Signed by \(signoff.readerName)."))
            }
            audit.append(contentsOf: signoff.thresholdOverrides.map {
                NeuroClinicalAuditEvent(kind: "threshold", summary: "Threshold override: \($0)")
            })
            audit.append(contentsOf: signoff.correctedRegions.map {
                NeuroClinicalAuditEvent(kind: "region-correction", summary: "Corrected region: \($0)")
            })
        } else {
            warnings.append("Reader sign-off is not attached.")
        }
        let status: NeuroClinicalQAStatus
        if !blockers.isEmpty {
            status = .blocked
        } else if signoff != nil && warnings.isEmpty {
            status = .signed
        } else if warnings.isEmpty {
            status = .ready
        } else {
            status = .warning
        }
        var lines = ["QA status: \(status.displayName)"]
        lines.append(contentsOf: badges)
        lines.append(contentsOf: blockers.map { "Blocker: \($0)" })
        lines.append(contentsOf: warnings.map { "Warning: \($0)" })
        lines.append(contentsOf: audit.map { "Audit: \($0.summary)" })
        return NeuroClinicalQAResult(
            status: status,
            badges: badges,
            blockers: Array(Set(blockers)).sorted(),
            warnings: Array(Set(warnings)).sorted(),
            auditEvents: audit,
            reportLines: lines
        )
    }
}

public struct NeuroClinicalAuditStore {
    public static let defaultKey = "Tracer.NeuroQuant.Audit.v1"
    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    public init(defaults: UserDefaults = .standard,
                key: String = NeuroClinicalAuditStore.defaultKey,
                limit: Int = 300) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
    }

    public func load() -> [NeuroClinicalAuditEvent] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NeuroClinicalAuditEvent].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.timestamp > $1.timestamp }
    }

    @discardableResult
    public func append(_ events: [NeuroClinicalAuditEvent]) -> [NeuroClinicalAuditEvent] {
        let output = Array((events + load()).prefix(limit))
        if let data = try? JSONEncoder().encode(output) {
            defaults.set(data, forKey: key)
        }
        return load()
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

public enum NeuroQuantEvidenceLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case researchScaffold
    case localValidation
    case multicenterValidation
    case regulatoryCleared

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .researchScaffold: return "Research scaffold"
        case .localValidation: return "Local validation"
        case .multicenterValidation: return "Multicenter validation"
        case .regulatoryCleared: return "Regulatory-cleared"
        }
    }
}

public struct NeuroQuantReferenceCohortDescriptor: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let tracer: BrainPETTracer
    public let sampleSize: Int
    public let ageMin: Double?
    public let ageMax: Double?
    public let acquisitionWindow: String
    public let reconstructionDescription: String
    public let referenceRegion: String
    public let sourceDescription: String
    public let checksum: String?

    public init(id: String,
                name: String,
                tracer: BrainPETTracer,
                sampleSize: Int,
                ageMin: Double? = nil,
                ageMax: Double? = nil,
                acquisitionWindow: String,
                reconstructionDescription: String,
                referenceRegion: String,
                sourceDescription: String,
                checksum: String? = nil) {
        self.id = id
        self.name = name
        self.tracer = tracer
        self.sampleSize = sampleSize
        self.ageMin = ageMin
        self.ageMax = ageMax
        self.acquisitionWindow = acquisitionWindow
        self.reconstructionDescription = reconstructionDescription
        self.referenceRegion = referenceRegion
        self.sourceDescription = sourceDescription
        self.checksum = checksum
    }
}

public enum NeuroQuantValidationMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case targetSUVR
    case centiloid
    case zScore
    case striatalBindingRatio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .targetSUVR: return "Target SUVR"
        case .centiloid: return "Centiloid"
        case .zScore: return "Z-score"
        case .striatalBindingRatio: return "Striatal binding ratio"
        }
    }
}

public struct NeuroQuantValidationCase: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let expectedValue: Double
    public let observedValue: Double
    public let referenceLabel: String?

    public init(id: String,
                expectedValue: Double,
                observedValue: Double,
                referenceLabel: String? = nil) {
        self.id = id
        self.expectedValue = expectedValue
        self.observedValue = observedValue
        self.referenceLabel = referenceLabel
    }
}

public struct NeuroQuantValidationStatistics: Codable, Equatable, Sendable {
    public let caseCount: Int
    public let slope: Double
    public let intercept: Double
    public let rSquared: Double
    public let meanBias: Double
    public let lowerLimitOfAgreement: Double
    public let upperLimitOfAgreement: Double
    public let meanAbsoluteError: Double

    public static func compute(from cases: [NeuroQuantValidationCase]) -> NeuroQuantValidationStatistics {
        let finite = cases.filter {
            $0.expectedValue.isFinite && $0.observedValue.isFinite
        }
        guard !finite.isEmpty else {
            return NeuroQuantValidationStatistics(
                caseCount: 0,
                slope: 0,
                intercept: 0,
                rSquared: 0,
                meanBias: 0,
                lowerLimitOfAgreement: 0,
                upperLimitOfAgreement: 0,
                meanAbsoluteError: 0
            )
        }
        let n = Double(finite.count)
        let xs = finite.map(\.expectedValue)
        let ys = finite.map(\.observedValue)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var ssXX = 0.0
        var ssYY = 0.0
        var ssXY = 0.0
        var biases: [Double] = []
        var absoluteErrors: [Double] = []
        for index in finite.indices {
            let dx = xs[index] - meanX
            let dy = ys[index] - meanY
            ssXX += dx * dx
            ssYY += dy * dy
            ssXY += dx * dy
            let bias = ys[index] - xs[index]
            biases.append(bias)
            absoluteErrors.append(abs(bias))
        }
        let slope = ssXX > 0 ? ssXY / ssXX : 0
        let intercept = meanY - slope * meanX
        let rSquared = (ssXX > 0 && ssYY > 0) ? (ssXY * ssXY) / (ssXX * ssYY) : 0
        let meanBias = biases.reduce(0, +) / n
        let variance = biases.reduce(0.0) { partial, bias in
            let delta = bias - meanBias
            return partial + delta * delta
        } / max(1, n - 1)
        let sdBias = sqrt(variance)
        return NeuroQuantValidationStatistics(
            caseCount: finite.count,
            slope: slope,
            intercept: intercept,
            rSquared: min(1, max(0, rSquared)),
            meanBias: meanBias,
            lowerLimitOfAgreement: meanBias - 1.96 * sdBias,
            upperLimitOfAgreement: meanBias + 1.96 * sdBias,
            meanAbsoluteError: absoluteErrors.reduce(0, +) / n
        )
    }
}

public struct NeuroQuantAcceptanceCriteria: Codable, Equatable, Sendable {
    public let minimumCaseCount: Int
    public let minimumR2: Double
    public let slopeRange: ClosedRange<Double>
    public let maximumAbsoluteBias: Double
    public let maximumAgreementHalfWidth: Double
    public let minimumAtlasScore: Double
    public let minimumNormalSampleSize: Int

    public init(minimumCaseCount: Int,
                minimumR2: Double,
                slopeRange: ClosedRange<Double>,
                maximumAbsoluteBias: Double,
                maximumAgreementHalfWidth: Double,
                minimumAtlasScore: Double,
                minimumNormalSampleSize: Int) {
        self.minimumCaseCount = minimumCaseCount
        self.minimumR2 = minimumR2
        self.slopeRange = slopeRange
        self.maximumAbsoluteBias = maximumAbsoluteBias
        self.maximumAgreementHalfWidth = maximumAgreementHalfWidth
        self.minimumAtlasScore = minimumAtlasScore
        self.minimumNormalSampleSize = minimumNormalSampleSize
    }

    public static func `default`(for workflow: NeuroQuantWorkflowProtocol,
                                 metric: NeuroQuantValidationMetric? = nil) -> NeuroQuantAcceptanceCriteria {
        switch metric ?? defaultMetric(for: workflow) {
        case .centiloid:
            return NeuroQuantAcceptanceCriteria(
                minimumCaseCount: 20,
                minimumR2: 0.90,
                slopeRange: 0.90...1.10,
                maximumAbsoluteBias: 5.0,
                maximumAgreementHalfWidth: 12.0,
                minimumAtlasScore: 0.75,
                minimumNormalSampleSize: 0
            )
        case .striatalBindingRatio:
            return NeuroQuantAcceptanceCriteria(
                minimumCaseCount: 15,
                minimumR2: 0.85,
                slopeRange: 0.85...1.15,
                maximumAbsoluteBias: 0.15,
                maximumAgreementHalfWidth: 0.35,
                minimumAtlasScore: 0.75,
                minimumNormalSampleSize: 20
            )
        case .zScore:
            return NeuroQuantAcceptanceCriteria(
                minimumCaseCount: 25,
                minimumR2: 0.80,
                slopeRange: 0.80...1.20,
                maximumAbsoluteBias: 0.35,
                maximumAgreementHalfWidth: 0.90,
                minimumAtlasScore: 0.70,
                minimumNormalSampleSize: 30
            )
        case .targetSUVR:
            return NeuroQuantAcceptanceCriteria(
                minimumCaseCount: 20,
                minimumR2: 0.85,
                slopeRange: 0.85...1.15,
                maximumAbsoluteBias: 0.08,
                maximumAgreementHalfWidth: 0.18,
                minimumAtlasScore: 0.70,
                minimumNormalSampleSize: workflow.requiresNormalDatabase ? 30 : 0
            )
        }
    }

    public static func defaultMetric(for workflow: NeuroQuantWorkflowProtocol) -> NeuroQuantValidationMetric {
        switch workflow {
        case .amyloidCentiloid: return .centiloid
        case .datscanStriatal: return .striatalBindingRatio
        case .fdgDementia, .hmpaoPerfusion: return .zScore
        case .tauBraak: return .targetSUVR
        }
    }

    public func evaluate(_ statistics: NeuroQuantValidationStatistics) -> [String] {
        var failures: [String] = []
        if statistics.caseCount < minimumCaseCount {
            failures.append("Validation cohort has \(statistics.caseCount) cases; requires at least \(minimumCaseCount).")
        }
        if statistics.rSquared < minimumR2 {
            failures.append(String(format: "R2 %.3f is below %.3f.", statistics.rSquared, minimumR2))
        }
        if !slopeRange.contains(statistics.slope) {
            failures.append(String(format: "Slope %.3f is outside %.2f-%.2f.", statistics.slope, slopeRange.lowerBound, slopeRange.upperBound))
        }
        if abs(statistics.meanBias) > maximumAbsoluteBias {
            failures.append(String(format: "Mean bias %.3f exceeds %.3f.", statistics.meanBias, maximumAbsoluteBias))
        }
        let halfWidth = (statistics.upperLimitOfAgreement - statistics.lowerLimitOfAgreement) / 2
        if halfWidth > maximumAgreementHalfWidth {
            failures.append(String(format: "Bland-Altman half-width %.3f exceeds %.3f.", halfWidth, maximumAgreementHalfWidth))
        }
        return failures
    }
}

public struct NeuroQuantClinicalValidationResult: Codable, Equatable, Sendable {
    public let workflow: NeuroQuantWorkflowProtocol
    public let metric: NeuroQuantValidationMetric
    public let sourceDescription: String
    public let statistics: NeuroQuantValidationStatistics
    public let acceptanceCriteria: NeuroQuantAcceptanceCriteria
    public let failures: [String]

    public var passed: Bool { failures.isEmpty }

    public static func evaluate(workflow: NeuroQuantWorkflowProtocol,
                                metric: NeuroQuantValidationMetric? = nil,
                                cases: [NeuroQuantValidationCase],
                                sourceDescription: String,
                                criteria: NeuroQuantAcceptanceCriteria? = nil) -> NeuroQuantClinicalValidationResult {
        let resolvedMetric = metric ?? NeuroQuantAcceptanceCriteria.defaultMetric(for: workflow)
        let resolvedCriteria = criteria ?? NeuroQuantAcceptanceCriteria.default(for: workflow, metric: resolvedMetric)
        let statistics = NeuroQuantValidationStatistics.compute(from: cases)
        return NeuroQuantClinicalValidationResult(
            workflow: workflow,
            metric: resolvedMetric,
            sourceDescription: sourceDescription,
            statistics: statistics,
            acceptanceCriteria: resolvedCriteria,
            failures: resolvedCriteria.evaluate(statistics)
        )
    }
}

public struct NeuroQuantReferencePackManifest: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let workflow: NeuroQuantWorkflowProtocol
    public let atlasPackID: String
    public let normalDatabaseID: String?
    public let evidenceLevel: NeuroQuantEvidenceLevel
    public let cohorts: [NeuroQuantReferenceCohortDescriptor]
    public let validationResult: NeuroQuantClinicalValidationResult?
    public let checksum: String?

    public init(id: String,
                name: String,
                version: String,
                workflow: NeuroQuantWorkflowProtocol,
                atlasPackID: String,
                normalDatabaseID: String? = nil,
                evidenceLevel: NeuroQuantEvidenceLevel,
                cohorts: [NeuroQuantReferenceCohortDescriptor],
                validationResult: NeuroQuantClinicalValidationResult? = nil,
                checksum: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.workflow = workflow
        self.atlasPackID = atlasPackID
        self.normalDatabaseID = normalDatabaseID
        self.evidenceLevel = evidenceLevel
        self.cohorts = cohorts
        self.validationResult = validationResult
        self.checksum = checksum
    }
}

public enum NeuroReferencePackManager {
    public static let recommendedManifests: [NeuroQuantReferencePackManifest] = [
        NeuroQuantReferencePackManifest(
            id: "fdg-dementia-reference-pack",
            name: "FDG Dementia Reference Pack",
            version: "2026.1",
            workflow: .fdgDementia,
            atlasPackID: "fdg-3d-ssp",
            normalDatabaseID: "fdg-adult-normal",
            evidenceLevel: .researchScaffold,
            cohorts: [
                NeuroQuantReferenceCohortDescriptor(
                    id: "fdg-adult-controls",
                    name: "Adult FDG controls",
                    tracer: .fdg,
                    sampleSize: 0,
                    ageMin: 50,
                    ageMax: 90,
                    acquisitionWindow: "Site-defined static FDG brain window",
                    reconstructionDescription: "Site-normalized reconstruction contract",
                    referenceRegion: "Pons/cerebellum",
                    sourceDescription: "Placeholder manifest; attach local normal database and validation before clinical use"
                )
            ]
        ),
        NeuroQuantReferencePackManifest(
            id: "amyloid-centiloid-reference-pack",
            name: "Amyloid Centiloid Reference Pack",
            version: "2026.1",
            workflow: .amyloidCentiloid,
            atlasPackID: "clark-centiloid",
            evidenceLevel: .researchScaffold,
            cohorts: [
                NeuroQuantReferenceCohortDescriptor(
                    id: "gaain-centiloid-contract",
                    name: "Centiloid calibration cohort",
                    tracer: .amyloidFlorbetapir,
                    sampleSize: 0,
                    acquisitionWindow: "Tracer-specific Centiloid window",
                    reconstructionDescription: "Centiloid-compatible reconstruction",
                    referenceRegion: "Whole cerebellum",
                    sourceDescription: "Import GAAIN/site calibration and validation statistics"
                )
            ]
        ),
        NeuroQuantReferencePackManifest(
            id: "tau-braak-reference-pack",
            name: "Tau Braak Reference Pack",
            version: "2026.1",
            workflow: .tauBraak,
            atlasPackID: "tau-braak",
            evidenceLevel: .researchScaffold,
            cohorts: [
                NeuroQuantReferenceCohortDescriptor(
                    id: "tau-stage-contract",
                    name: "Tau staging validation cohort",
                    tracer: .tauFlortaucipir,
                    sampleSize: 0,
                    acquisitionWindow: "Tracer-specific tau window",
                    reconstructionDescription: "Site-normalized tau reconstruction",
                    referenceRegion: "Inferior cerebellar gray",
                    sourceDescription: "Attach tracer-specific Braak-stage validation before clinical use"
                )
            ]
        ),
        NeuroQuantReferencePackManifest(
            id: "datscan-striatal-reference-pack",
            name: "DaTscan Striatal Reference Pack",
            version: "2026.1",
            workflow: .datscanStriatal,
            atlasPackID: "datscan-striatal",
            normalDatabaseID: "datscan-striatal-normal",
            evidenceLevel: .researchScaffold,
            cohorts: [
                NeuroQuantReferenceCohortDescriptor(
                    id: "datscan-sbr-controls",
                    name: "DaTscan SBR controls",
                    tracer: .spectDaTscan,
                    sampleSize: 0,
                    acquisitionWindow: "DaTscan static SPECT window",
                    reconstructionDescription: "SPECT reconstruction and attenuation/scatter contract",
                    referenceRegion: "Occipital background",
                    sourceDescription: "Attach site or vendor normal ranges and phantom validation"
                )
            ]
        ),
        NeuroQuantReferencePackManifest(
            id: "hmpao-perfusion-reference-pack",
            name: "HMPAO Perfusion Reference Pack",
            version: "2026.1",
            workflow: .hmpaoPerfusion,
            atlasPackID: "hmpao-perfusion",
            normalDatabaseID: "hmpao-perfusion-normal",
            evidenceLevel: .researchScaffold,
            cohorts: [
                NeuroQuantReferenceCohortDescriptor(
                    id: "hmpao-perfusion-controls",
                    name: "HMPAO perfusion controls",
                    tracer: .spectHMPAO,
                    sampleSize: 0,
                    acquisitionWindow: "Rest/challenge perfusion SPECT window",
                    reconstructionDescription: "SPECT reconstruction and normalization contract",
                    referenceRegion: "Whole brain/cerebellum",
                    sourceDescription: "Attach site normal database and CVR challenge validation"
                )
            ]
        )
    ]

    public static func manifest(for workflow: NeuroQuantWorkflowProtocol) -> NeuroQuantReferencePackManifest? {
        recommendedManifests.first { $0.workflow == workflow }
    }

    public static func compatibilityLines(manifest: NeuroQuantReferencePackManifest,
                                          atlasValidation: NeuroQuantAtlasValidation,
                                          normalDatabase: BrainPETNormalDatabase?) -> [String] {
        var lines = [
            "Pack: \(manifest.name) \(manifest.version)",
            "Evidence: \(manifest.evidenceLevel.displayName)",
            "Atlas pack: \(manifest.atlasPackID == atlasValidation.pack.id ? "matched" : "mismatch")"
        ]
        if let expectedNormal = manifest.normalDatabaseID {
            let loaded = normalDatabase?.id == expectedNormal
            lines.append("Normal database: \(loaded ? "matched" : "expected \(expectedNormal)")")
        }
        if let validation = manifest.validationResult {
            lines.append(String(format: "Validation %@ n=%d R2 %.3f",
                                validation.metric.displayName,
                                validation.statistics.caseCount,
                                validation.statistics.rSquared))
        } else {
            lines.append("Validation: not attached")
        }
        return lines
    }
}

public struct NeuroReferencePackStore {
    public static let defaultKey = "Tracer.NeuroQuant.ReferencePacks.v1"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard,
                key: String = NeuroReferencePackStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [NeuroQuantReferencePackManifest] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NeuroQuantReferencePackManifest].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.name < $1.name }
    }

    @discardableResult
    public func upsert(_ manifest: NeuroQuantReferencePackManifest) -> [NeuroQuantReferencePackManifest] {
        var manifests = load()
        if let index = manifests.firstIndex(where: { $0.id == manifest.id }) {
            manifests[index] = manifest
        } else {
            manifests.append(manifest)
        }
        save(manifests)
        return load()
    }

    @discardableResult
    public func remove(id: String) -> [NeuroQuantReferencePackManifest] {
        let manifests = load().filter { $0.id != id }
        save(manifests)
        return load()
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    private func save(_ manifests: [NeuroQuantReferencePackManifest]) {
        if let data = try? JSONEncoder().encode(manifests) {
            defaults.set(data, forKey: key)
        }
    }
}

public struct NeuroAcquisitionSignature: Codable, Equatable, Sendable {
    public let tracer: BrainPETTracer
    public let scannerManufacturer: String?
    public let scannerModel: String?
    public let reconstructionDescription: String?
    public let acquisitionWindowMinutes: Double?
    public let patientAge: Double?

    public init(tracer: BrainPETTracer,
                scannerManufacturer: String? = nil,
                scannerModel: String? = nil,
                reconstructionDescription: String? = nil,
                acquisitionWindowMinutes: Double? = nil,
                patientAge: Double? = nil) {
        self.tracer = tracer
        self.scannerManufacturer = scannerManufacturer
        self.scannerModel = scannerModel
        self.reconstructionDescription = reconstructionDescription
        self.acquisitionWindowMinutes = acquisitionWindowMinutes
        self.patientAge = patientAge
    }
}

public struct NeuroPhantomCalibrationRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let performedAt: Date
    public let workflow: NeuroQuantWorkflowProtocol
    public let scannerModel: String
    public let recoveryCoefficient: Double
    public let uniformityPercent: Double
    public let checksum: String?

    public init(id: String = UUID().uuidString,
                performedAt: Date = Date(),
                workflow: NeuroQuantWorkflowProtocol,
                scannerModel: String,
                recoveryCoefficient: Double,
                uniformityPercent: Double,
                checksum: String? = nil) {
        self.id = id
        self.performedAt = performedAt
        self.workflow = workflow
        self.scannerModel = scannerModel
        self.recoveryCoefficient = recoveryCoefficient
        self.uniformityPercent = uniformityPercent
        self.checksum = checksum
    }

    public var passed: Bool {
        (0.85...1.15).contains(recoveryCoefficient) && uniformityPercent <= 10
    }
}

public enum NeuroNormalGovernanceStatus: String, Codable, Sendable {
    case missing
    case research
    case compatible
    case locked
    case mismatch

    public var displayName: String {
        switch self {
        case .missing: return "Missing"
        case .research: return "Research"
        case .compatible: return "Compatible"
        case .locked: return "Locked"
        case .mismatch: return "Mismatch"
        }
    }
}

public struct NeuroNormalDatabaseGovernance: Codable, Equatable, Sendable {
    public let status: NeuroNormalGovernanceStatus
    public let blockers: [String]
    public let warnings: [String]
    public let compatibilityLines: [String]
    public let phantomLines: [String]
    public let reportLines: [String]
}

public enum NeuroNormalDatabaseGovernanceEvaluator {
    public static func evaluate(workflow: NeuroQuantWorkflowProtocol,
                                normalDatabase: BrainPETNormalDatabase?,
                                referenceManifest: NeuroQuantReferencePackManifest?,
                                acquisitionSignature: NeuroAcquisitionSignature?,
                                patientAge: Double?,
                                phantomRecords: [NeuroPhantomCalibrationRecord]) -> NeuroNormalDatabaseGovernance {
        var blockers: [String] = []
        var warnings: [String] = []
        var compatibility: [String] = ["Workflow: \(workflow.displayName)"]
        if let normalDatabase {
            compatibility.append("Normal database: \(normalDatabase.name)")
            if normalDatabase.tracer != workflow.tracer {
                blockers.append("Normal database tracer \(normalDatabase.tracer.displayName) does not match \(workflow.tracer.displayName).")
            }
            let maxSample = normalDatabase.entries.map(\.sampleSize).max() ?? 0
            compatibility.append("Normal database max n: \(maxSample)")
            if maxSample < NeuroQuantAcceptanceCriteria.default(for: workflow).minimumNormalSampleSize {
                warnings.append("Normal database sample size is below the workflow recommendation.")
            }
            if let patientAge {
                let matchingAge = normalDatabase.entries.contains { entry in
                    let minOK = entry.ageMin.map { patientAge >= $0 } ?? true
                    let maxOK = entry.ageMax.map { patientAge <= $0 } ?? true
                    return minOK && maxOK
                }
                if !matchingAge, normalDatabase.entries.contains(where: { $0.ageMin != nil || $0.ageMax != nil }) {
                    warnings.append(String(format: "Patient age %.0f is outside the age range of at least one normal cohort.", patientAge))
                }
            }
        } else if workflow.requiresNormalDatabase {
            blockers.append("No normal database is loaded for a workflow that requires z-score reference cohorts.")
        } else {
            warnings.append("No normal database is loaded; output remains protocol/reference dependent.")
        }
        if let acquisitionSignature {
            compatibility.append("Acquisition tracer: \(acquisitionSignature.tracer.displayName)")
            if acquisitionSignature.tracer != workflow.tracer {
                blockers.append("Acquisition tracer does not match the selected workflow tracer.")
            }
            if let reconstruction = acquisitionSignature.reconstructionDescription, !reconstruction.isEmpty {
                compatibility.append("Reconstruction: \(reconstruction)")
                if let cohorts = referenceManifest?.cohorts,
                   !cohorts.isEmpty,
                   !cohorts.contains(where: { reconstruction.localizedCaseInsensitiveContains($0.reconstructionDescription) || $0.reconstructionDescription.localizedCaseInsensitiveContains(reconstruction) }) {
                    warnings.append("Reconstruction description does not explicitly match the reference pack cohort contract.")
                }
            }
        }
        if let referenceManifest {
            compatibility.append("Reference pack: \(referenceManifest.name) \(referenceManifest.version)")
            if referenceManifest.workflow != workflow {
                blockers.append("Reference pack workflow does not match selected workflow.")
            }
            if referenceManifest.checksum == nil {
                warnings.append("Reference pack checksum is missing; version locking is incomplete.")
            }
            if referenceManifest.validationResult?.passed != true {
                warnings.append("Reference pack does not contain a passing validation result.")
            }
        } else {
            warnings.append("No reference pack manifest is attached.")
        }
        let matchingPhantoms = phantomRecords.filter { $0.workflow == workflow }
        let phantomLines: [String]
        if matchingPhantoms.isEmpty {
            phantomLines = ["Phantom calibration: not attached"]
            warnings.append("No phantom calibration record is attached for this workflow.")
        } else {
            phantomLines = matchingPhantoms.prefix(3).map {
                String(format: "Phantom %@: recovery %.2f, uniformity %.1f%%, %@",
                       $0.scannerModel,
                       $0.recoveryCoefficient,
                       $0.uniformityPercent,
                       $0.passed ? "pass" : "review")
            }
            if matchingPhantoms.contains(where: { !$0.passed }) {
                blockers.append("At least one attached phantom calibration record failed acceptance gates.")
            }
        }
        let status: NeuroNormalGovernanceStatus
        if !blockers.isEmpty {
            status = .mismatch
        } else if referenceManifest?.evidenceLevel == .regulatoryCleared && referenceManifest?.validationResult?.passed == true {
            status = .locked
        } else if referenceManifest?.validationResult?.passed == true || normalDatabase != nil {
            status = .compatible
        } else if normalDatabase == nil && workflow.requiresNormalDatabase {
            status = .missing
        } else {
            status = .research
        }
        var lines = ["Reference status: \(status.displayName)"]
        lines.append(contentsOf: compatibility)
        lines.append(contentsOf: phantomLines)
        lines.append(contentsOf: blockers.map { "Blocker: \($0)" })
        lines.append(contentsOf: warnings.map { "Warning: \($0)" })
        return NeuroNormalDatabaseGovernance(
            status: status,
            blockers: Array(Set(blockers)).sorted(),
            warnings: Array(Set(warnings)).sorted(),
            compatibilityLines: compatibility,
            phantomLines: phantomLines,
            reportLines: lines
        )
    }
}

public enum NeuroValidationCaseCSVParser {
    public static func parse(_ text: String) -> [NeuroQuantValidationCase] {
        let rows = text
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let header = rows.first else { return [] }
        let fields = splitCSVLine(header).map { $0.lowercased() }
        let idIndex = fields.firstIndex { $0 == "id" || $0 == "case" || $0 == "caseid" } ?? 0
        let expectedIndex = fields.firstIndex { $0 == "expected" || $0 == "expectedvalue" || $0 == "reference" }
        let observedIndex = fields.firstIndex { $0 == "observed" || $0 == "observedvalue" || $0 == "tracer" || $0 == "measured" }
        guard let expectedIndex, let observedIndex else { return [] }
        return rows.dropFirst().compactMap { row in
            let columns = splitCSVLine(row)
            guard columns.indices.contains(expectedIndex),
                  columns.indices.contains(observedIndex),
                  let expected = Double(columns[expectedIndex]),
                  let observed = Double(columns[observedIndex]) else {
                return nil
            }
            let id = columns.indices.contains(idIndex) && !columns[idIndex].isEmpty
                ? columns[idIndex]
                : UUID().uuidString
            return NeuroQuantValidationCase(id: id, expectedValue: expected, observedValue: observed)
        }
    }

    private static func splitCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return fields
    }
}

public enum NeuroQuantClinicalReadinessStatus: String, Codable, Sendable {
    case researchOnly
    case validationPending
    case locallyValidated
    case clinicalLocked

    public var displayName: String {
        switch self {
        case .researchOnly: return "Research only"
        case .validationPending: return "Validation pending"
        case .locallyValidated: return "Locally validated"
        case .clinicalLocked: return "Clinical locked"
        }
    }
}

public struct NeuroVolumeDimensions: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let depth: Int

    public var voxelCount: Int { width * height * depth }

    public init(width: Int, height: Int, depth: Int) {
        self.width = width
        self.height = height
        self.depth = depth
    }

    public init(volume: ImageVolume) {
        self.init(width: volume.width, height: volume.height, depth: volume.depth)
    }

    public init(map: NeuroZScoreMap) {
        self.init(width: map.width, height: map.height, depth: map.depth)
    }
}

public enum NeuroParametricMapKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case suvr
    case zScore
    case centiloid
    case tauStage
    case striatalBinding
    case perfusionReserve

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .suvr: return "SUVR/SBR map"
        case .zScore: return "Z-score map"
        case .centiloid: return "Centiloid scalar"
        case .tauStage: return "Tau stage scalar"
        case .striatalBinding: return "Striatal binding map"
        case .perfusionReserve: return "Perfusion reserve map"
        }
    }

    public var units: String {
        switch self {
        case .suvr, .striatalBinding: return "ratio"
        case .zScore: return "z-score"
        case .centiloid: return "CL"
        case .tauStage: return "stage"
        case .perfusionReserve: return "percent"
        }
    }
}

public struct NeuroParametricMapDescriptor: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: NeuroParametricMapKind
    public let name: String
    public let dimensions: NeuroVolumeDimensions
    public let units: String
    public let minimumValue: Double?
    public let maximumValue: Double?
    public let sourceSpace: String
    public let dicomSeriesDescription: String
    public let warnings: [String]
}

public struct NeuroDICOMExportManifest: Codable, Equatable, Sendable {
    public let workflow: NeuroQuantWorkflowProtocol
    public let studyUID: String
    public let sourceSeriesUID: String
    public let seriesDescription: String
    public let structuredReportTitle: String
    public let structuredReportSOPClassUID: String
    public let objectTypes: [String]
    public let parametricMaps: [NeuroParametricMapDescriptor]
    public let warnings: [String]
    public let reportLines: [String]
}

public enum NeuroParametricMapExporter {
    public static let basicTextSRSOPClassUID = "1.2.840.10008.5.1.4.1.1.88.11"
    public static let parametricMapSOPClassUID = "1.2.840.10008.5.1.4.1.1.30"

    public static func makeManifest(volume: ImageVolume,
                                    workflow: NeuroQuantWorkflowProtocol,
                                    report: BrainPETReport,
                                    zScoreMap: NeuroZScoreMap,
                                    striatalMetrics: NeuroStriatalBindingMetrics?,
                                    perfusionAssessment: NeuroPerfusionAssessment?) -> NeuroDICOMExportManifest {
        var maps: [NeuroParametricMapDescriptor] = []
        var warnings: [String] = []
        let sourceDimensions = NeuroVolumeDimensions(volume: volume)
        let zDimensions = NeuroVolumeDimensions(map: zScoreMap)
        if sourceDimensions != zDimensions {
            warnings.append("Z-score map is atlas-space; DICOM export should preserve the referenced registration and atlas transform.")
        }
        maps.append(
            descriptor(
                id: "z-score",
                kind: .zScore,
                dimensions: zDimensions,
                values: zScoreMap.finiteValues.map(Double.init),
                sourceSpace: workflow.preferredTemplateSpace.displayName,
                seriesDescription: "\(workflow.shortName) z-score parametric map",
                warnings: sourceDimensions == zDimensions ? [] : ["Atlas-space grid differs from source image grid."]
            )
        )
        if report.targetSUVR != nil {
            maps.append(
                descriptor(
                    id: "suvr",
                    kind: .suvr,
                    dimensions: sourceDimensions,
                    values: report.regions.map(\.suvr),
                    sourceSpace: "Native quantitative regions",
                    seriesDescription: "\(workflow.shortName) SUVR/SBR parametric values"
                )
            )
        }
        if let centiloid = report.centiloid {
            maps.append(
                descriptor(
                    id: "centiloid",
                    kind: .centiloid,
                    dimensions: NeuroVolumeDimensions(width: 1, height: 1, depth: 1),
                    values: [centiloid],
                    sourceSpace: workflow.preferredTemplateSpace.displayName,
                    seriesDescription: "\(workflow.shortName) Centiloid scalar"
                )
            )
        }
        if let tauStage = report.tauGrade?.stage {
            maps.append(
                NeuroParametricMapDescriptor(
                    id: "tau-stage",
                    kind: .tauStage,
                    name: NeuroParametricMapKind.tauStage.displayName,
                    dimensions: NeuroVolumeDimensions(width: 1, height: 1, depth: 1),
                    units: NeuroParametricMapKind.tauStage.units,
                    minimumValue: nil,
                    maximumValue: nil,
                    sourceSpace: workflow.preferredTemplateSpace.displayName,
                    dicomSeriesDescription: "\(workflow.shortName) \(tauStage)",
                    warnings: []
                )
            )
        }
        if let striatalMetrics,
           let mean = striatalMetrics.meanStriatalBindingRatio {
            maps.append(
                descriptor(
                    id: "striatal-binding",
                    kind: .striatalBinding,
                    dimensions: sourceDimensions,
                    values: [
                        striatalMetrics.leftCaudate,
                        striatalMetrics.rightCaudate,
                        striatalMetrics.leftPutamen,
                        striatalMetrics.rightPutamen,
                        mean
                    ].compactMap { $0 },
                    sourceSpace: "Native striatal VOIs",
                    seriesDescription: "\(workflow.shortName) striatal binding values"
                )
            )
        }
        if let perfusionAssessment {
            maps.append(
                descriptor(
                    id: "perfusion-territories",
                    kind: .perfusionReserve,
                    dimensions: sourceDimensions,
                    values: perfusionAssessment.territorySummaries.compactMap(\.meanZScore),
                    sourceSpace: "Perfusion territory summary",
                    seriesDescription: "\(workflow.shortName) perfusion territory values"
                )
            )
        }
        let objectTypes = uniqueStrings(
            ["DICOM Basic Text SR", "DICOM Parametric Map descriptor"] +
            maps.map { "\($0.kind.displayName) (\($0.units))" }
        )
        let lines = [
            "SR title: \(workflow.displayName) quantitative report",
            "SOP class: Basic Text SR",
            "Parametric objects: \(maps.count)",
            "Source series: \(volume.seriesDescription.isEmpty ? volume.seriesUID : volume.seriesDescription)"
        ] + maps.map { "\($0.name): \($0.dicomSeriesDescription)" } + warnings.map { "Warning: \($0)" }
        return NeuroDICOMExportManifest(
            workflow: workflow,
            studyUID: DICOMExportWriter.dicomUID(volume.studyUID),
            sourceSeriesUID: DICOMExportWriter.dicomUID(volume.seriesUID),
            seriesDescription: "\(workflow.shortName) Neuroquant Export",
            structuredReportTitle: "\(workflow.displayName) quantitative report",
            structuredReportSOPClassUID: basicTextSRSOPClassUID,
            objectTypes: objectTypes,
            parametricMaps: maps,
            warnings: warnings,
            reportLines: lines
        )
    }

    public static func makeZScoreVolume(from map: NeuroZScoreMap,
                                        source: ImageVolume,
                                        workflow: NeuroQuantWorkflowProtocol) -> ImageVolume {
        ImageVolume(
            pixels: map.values,
            depth: map.depth,
            height: map.height,
            width: map.width,
            spacing: source.spacing,
            origin: source.origin,
            direction: source.direction,
            modality: "OT",
            studyUID: source.studyUID,
            patientID: source.patientID,
            patientName: source.patientName,
            accessionNumber: source.accessionNumber,
            studyDate: source.studyDate,
            studyTime: source.studyTime,
            bodyPartExamined: source.bodyPartExamined,
            seriesDescription: "\(workflow.shortName) z-score parametric map",
            studyDescription: source.studyDescription,
            seriesNumber: source.seriesNumber + 1000,
            sourceFiles: source.sourceFiles
        )
    }

    private static func descriptor(id: String,
                                   kind: NeuroParametricMapKind,
                                   dimensions: NeuroVolumeDimensions,
                                   values: [Double],
                                   sourceSpace: String,
                                   seriesDescription: String,
                                   warnings: [String] = []) -> NeuroParametricMapDescriptor {
        let finite = values.filter(\.isFinite)
        return NeuroParametricMapDescriptor(
            id: id,
            kind: kind,
            name: kind.displayName,
            dimensions: dimensions,
            units: kind.units,
            minimumValue: finite.min(),
            maximumValue: finite.max(),
            sourceSpace: sourceSpace,
            dicomSeriesDescription: seriesDescription,
            warnings: warnings
        )
    }
}

public enum NeuroDICOMSRExporter {
    public static func makeTextSRPayload(report: NeuroQuantStructuredReport,
                                         manifest: NeuroDICOMExportManifest,
                                         sourceVolume: ImageVolume,
                                         verified: Bool = false) -> Data {
        let sopInstanceUID = DICOMExportWriter.makeUID()
        let seriesUID = DICOMExportWriter.makeUID()
        let now = DICOMExportWriter.currentDateTime()
        var dataset = Data()
        dataset.appendDICOMElement(group: 0x0008, element: 0x0016, vr: "UI", string: manifest.structuredReportSOPClassUID)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0018, vr: "UI", string: sopInstanceUID)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0020, vr: "DA", string: sourceVolume.studyDate.isEmpty ? now.date : sourceVolume.studyDate)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0030, vr: "TM", string: sourceVolume.studyTime.isEmpty ? now.time : sourceVolume.studyTime)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0023, vr: "DA", string: now.date)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0033, vr: "TM", string: now.time)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0050, vr: "SH", string: sourceVolume.accessionNumber)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0060, vr: "CS", string: "SR")
        dataset.appendDICOMElement(group: 0x0008, element: 0x0070, vr: "LO", string: "Tracer")
        dataset.appendDICOMElement(group: 0x0008, element: 0x1030, vr: "LO", string: sourceVolume.studyDescription)
        dataset.appendDICOMElement(group: 0x0008, element: 0x103E, vr: "LO", string: manifest.seriesDescription)
        dataset.appendDICOMElement(group: 0x0010, element: 0x0010, vr: "PN", string: sourceVolume.patientName)
        dataset.appendDICOMElement(group: 0x0010, element: 0x0020, vr: "LO", string: sourceVolume.patientID)
        dataset.appendDICOMElement(group: 0x0020, element: 0x000D, vr: "UI", string: manifest.studyUID)
        dataset.appendDICOMElement(group: 0x0020, element: 0x000E, vr: "UI", string: seriesUID)
        dataset.appendDICOMElement(group: 0x0020, element: 0x0010, vr: "SH", string: "1")
        dataset.appendDICOMElement(group: 0x0020, element: 0x0011, vr: "IS", string: "900")
        dataset.appendDICOMElement(group: 0x0020, element: 0x0013, vr: "IS", string: "1")
        dataset.appendDICOMElement(group: 0x0040, element: 0xA040, vr: "CS", string: "CONTAINER")
        dataset.appendDICOMElement(group: 0x0040, element: 0xA043, vr: "SQ", bytes: sequence(items: [
            DICOMExportWriter.codeSequenceItem(codeValue: "126000", scheme: "DCM", meaning: manifest.structuredReportTitle)
        ]))
        dataset.appendDICOMElement(group: 0x0040, element: 0xA050, vr: "CS", string: "SEPARATE")
        dataset.appendDICOMElement(group: 0x0040, element: 0xA491, vr: "CS", string: "COMPLETE")
        dataset.appendDICOMElement(group: 0x0040, element: 0xA493, vr: "CS", string: verified ? "VERIFIED" : "UNVERIFIED")

        var textItem = Data()
        textItem.appendDICOMElement(group: 0x0040, element: 0xA010, vr: "CS", string: "CONTAINS")
        textItem.appendDICOMElement(group: 0x0040, element: 0xA040, vr: "CS", string: "TEXT")
        textItem.appendDICOMElement(group: 0x0040, element: 0xA043, vr: "SQ", bytes: sequence(items: [
            DICOMExportWriter.codeSequenceItem(codeValue: "121070", scheme: "DCM", meaning: "Findings")
        ]))
        textItem.appendDICOMElement(group: 0x0040, element: 0xA160, vr: "UT", string: report.plainText)
        dataset.appendDICOMSequence(group: 0x0040, element: 0xA730, items: [textItem])
        return DICOMExportWriter.part10File(
            sopClassUID: manifest.structuredReportSOPClassUID,
            sopInstanceUID: sopInstanceUID,
            dataset: dataset
        )
    }

    private static func sequence(items: [Data]) -> Data {
        var value = Data()
        for item in items {
            value.appendDICOMUInt16LE(0xFFFE)
            value.appendDICOMUInt16LE(0xE000)
            value.appendDICOMUInt32LE(UInt32(item.count))
            value.append(item)
        }
        return value
    }
}

public struct NeuroValidationWorkbenchDashboard: Codable, Equatable, Sendable {
    public let workflow: NeuroQuantWorkflowProtocol
    public let metric: NeuroQuantValidationMetric?
    public let status: NeuroQuantClinicalReadinessStatus
    public let cohortSummary: String
    public let regressionLine: String?
    public let blandAltmanLine: String?
    public let gateLines: [String]
    public let lockRecommendation: String
    public let reportLines: [String]
}

public enum NeuroValidationWorkbench {
    public static func make(workflow: NeuroQuantWorkflowProtocol,
                            validation: NeuroQuantClinicalValidationResult?,
                            referenceManifest: NeuroQuantReferencePackManifest?,
                            normalGovernance: NeuroNormalDatabaseGovernance?,
                            readiness: NeuroQuantClinicalReadiness) -> NeuroValidationWorkbenchDashboard {
        let metric = validation?.metric ?? referenceManifest?.validationResult?.metric
        let validationResult = validation ?? referenceManifest?.validationResult
        let cohortSummary: String
        let regressionLine: String?
        let blandAltmanLine: String?
        var gateLines = readiness.evidenceLines
        if let validationResult {
            let stats = validationResult.statistics
            cohortSummary = "\(validationResult.sourceDescription), n=\(stats.caseCount)"
            regressionLine = String(format: "%@ regression: y = %.3fx %+.3f, R2 %.3f",
                                    validationResult.metric.displayName,
                                    stats.slope,
                                    stats.intercept,
                                    stats.rSquared)
            blandAltmanLine = String(format: "Bland-Altman bias %.3f, limits %.3f to %.3f",
                                     stats.meanBias,
                                     stats.lowerLimitOfAgreement,
                                     stats.upperLimitOfAgreement)
            if validationResult.failures.isEmpty {
                gateLines.append("Validation gates passed.")
            } else {
                gateLines.append(contentsOf: validationResult.failures.map { "Gate failed: \($0)" })
            }
        } else {
            cohortSummary = "No validation cohort attached."
            regressionLine = nil
            blandAltmanLine = nil
            gateLines.append("Validation case import is required before clinical locking.")
        }
        if let normalGovernance {
            gateLines.append("Reference governance: \(normalGovernance.status.displayName)")
        }
        let lockRecommendation: String
        switch readiness.status {
        case .clinicalLocked:
            lockRecommendation = "Protocol can be locked for clinical reporting with the attached evidence pack."
        case .locallyValidated:
            lockRecommendation = "Protocol is locally validated; keep versioned reference packs and periodic drift review active."
        case .validationPending:
            lockRecommendation = "Keep as validation-pending until site cases, phantom checks, and reference manifest are complete."
        case .researchOnly:
            lockRecommendation = "Restrict to research/non-diagnostic output until blockers are resolved."
        }
        var lines = [
            "Validation workbench: \(readiness.status.displayName)",
            "Cohort: \(cohortSummary)",
            "Recommendation: \(lockRecommendation)"
        ]
        if let regressionLine { lines.append(regressionLine) }
        if let blandAltmanLine { lines.append(blandAltmanLine) }
        lines.append(contentsOf: gateLines.prefix(8))
        return NeuroValidationWorkbenchDashboard(
            workflow: workflow,
            metric: metric,
            status: readiness.status,
            cohortSummary: cohortSummary,
            regressionLine: regressionLine,
            blandAltmanLine: blandAltmanLine,
            gateLines: uniqueStrings(gateLines),
            lockRecommendation: lockRecommendation,
            reportLines: lines
        )
    }
}

public enum NeuroComparisonViewportKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case currentPET
    case priorPET
    case anatomyMRI
    case zScoreMap
    case surfaceProjection
    case atlasOverlay
    case structuredReport

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .currentPET: return "Current PET/SPECT"
        case .priorPET: return "Prior PET/SPECT"
        case .anatomyMRI: return "Anatomy MRI/CT"
        case .zScoreMap: return "Z-score map"
        case .surfaceProjection: return "Surface projection"
        case .atlasOverlay: return "Atlas overlay"
        case .structuredReport: return "Structured report"
        }
    }
}

public struct NeuroComparisonPane: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: NeuroComparisonViewportKind
    public let title: String
    public let subtitle: String
    public let linkedCrosshair: Bool
    public let overlays: [String]
}

public struct NeuroComparisonWorkspace: Codable, Equatable, Sendable {
    public let layoutName: String
    public let synchronizationMode: String
    public let panes: [NeuroComparisonPane]
    public let primaryFindings: [String]
    public let reportLines: [String]
}

public enum NeuroComparisonWorkspaceBuilder {
    public static func build(workflow: NeuroQuantWorkflowProtocol,
                             report: BrainPETReport,
                             clusters: [NeuroQuantCluster],
                             surfaceProjections: [NeuroSurfaceProjectionImage],
                             timeline: NeuroLongitudinalTimeline?,
                             mriAssessment: NeuroMRIContextAssessment?) -> NeuroComparisonWorkspace {
        var panes: [NeuroComparisonPane] = [
            NeuroComparisonPane(
                id: "current",
                kind: .currentPET,
                title: "Current \(workflow.shortName)",
                subtitle: report.summary,
                linkedCrosshair: true,
                overlays: ["Atlas contours", "Quantitative VOIs"]
            ),
            NeuroComparisonPane(
                id: "z-score",
                kind: .zScoreMap,
                title: "Z-score map",
                subtitle: clusters.first.map { "Peak \($0.dominantRegion) z \(String(format: "%.2f", $0.peakZScore))" } ?? "No abnormal cluster",
                linkedCrosshair: true,
                overlays: ["Threshold \(String(format: "%.1f", workflow.zScoreThreshold))", workflow.abnormalityPolarity.displayName]
            ),
            NeuroComparisonPane(
                id: "atlas",
                kind: .atlasOverlay,
                title: "Atlas/VOI overlay",
                subtitle: "\(workflow.preferredTemplateSpace.displayName) transfer",
                linkedCrosshair: true,
                overlays: workflow.targetKeywords.prefix(5).map { $0 }
            )
        ]
        if timeline != nil {
            panes.insert(
                NeuroComparisonPane(
                    id: "prior",
                    kind: .priorPET,
                    title: "Prior comparison",
                    subtitle: timeline?.trendSummary ?? "No prior trend",
                    linkedCrosshair: true,
                    overlays: ["Delta SUVR", "Delta Centiloid", "Reader adjudication"]
                ),
                at: 1
            )
        }
        if let mriAssessment {
            panes.append(
                NeuroComparisonPane(
                    id: "mri",
                    kind: .anatomyMRI,
                    title: "Anatomy context",
                    subtitle: "MRI risk \(mriAssessment.riskLevel.displayName)",
                    linkedCrosshair: true,
                    overlays: mriAssessment.modifiers.prefix(4).map { $0 }
                )
            )
        }
        if !surfaceProjections.isEmpty {
            panes.append(
                NeuroComparisonPane(
                    id: "surface",
                    kind: .surfaceProjection,
                    title: "Surface projection",
                    subtitle: "\(surfaceProjections.count) protocol views",
                    linkedCrosshair: false,
                    overlays: surfaceProjections.prefix(3).map { $0.view.displayName }
                )
            )
        }
        panes.append(
            NeuroComparisonPane(
                id: "report",
                kind: .structuredReport,
                title: "Report draft",
                subtitle: "Quantitative impression and audit-ready sections",
                linkedCrosshair: false,
                overlays: workflow.reportSections
            )
        )
        let findings = clusters.prefix(3).map {
            String(format: "%@: peak z %.2f, %d voxels", $0.dominantRegion, $0.peakZScore, $0.voxelCount)
        }
        let reportLines = [
            "Layout: Neuro comparison workspace",
            "Synchronization: Crosshair and slab position linked across native/anatomy/atlas panes",
            "Panes: \(panes.count)"
        ] + panes.map { "\($0.kind.displayName): \($0.title)" } + findings
        return NeuroComparisonWorkspace(
            layoutName: "Neuro linked review",
            synchronizationMode: "Linked crosshair, slice, window, and atlas cursor",
            panes: panes,
            primaryFindings: findings,
            reportLines: reportLines
        )
    }
}

public enum NeuroAntiAmyloidClinicMilestoneStatus: String, Codable, Sendable {
    case due
    case scheduled
    case completed
    case hold

    public var displayName: String {
        switch self {
        case .due: return "Due"
        case .scheduled: return "Scheduled"
        case .completed: return "Completed"
        case .hold: return "Hold"
        }
    }
}

public struct NeuroAntiAmyloidClinicMilestone: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: NeuroAntiAmyloidClinicMilestoneStatus
    public let detail: String
}

public struct NeuroAntiAmyloidClinicTracker: Codable, Equatable, Sendable {
    public let agent: NeuroAntiAmyloidAgent
    public let currentInfusion: Int?
    public let action: NeuroAntiAmyloidAction
    public let nextMRIDescription: String
    public let ariaState: String
    public let responseSummary: String
    public let milestones: [NeuroAntiAmyloidClinicMilestone]
    public let reportLines: [String]
}

public enum NeuroAntiAmyloidClinicTrackerBuilder {
    public static func build(context: NeuroAntiAmyloidTherapyContext,
                             assessment: NeuroAntiAmyloidTherapyAssessment,
                             timeline: NeuroLongitudinalTimeline?,
                             mriAssessment: NeuroMRIContextAssessment?) -> NeuroAntiAmyloidClinicTracker {
        let infusion = context.infusionNumber
        let nextMRI = nextMRIDescription(agent: context.agent, infusion: infusion, lastMRIAt: context.lastMRIAt)
        let ariaState: String
        if context.symptomaticARIA || mriAssessment?.riskLevel == .high {
            ariaState = "ARIA/high-risk review active"
        } else if mriAssessment?.riskLevel == .moderate {
            ariaState = "Moderate MRI risk; monitor closely"
        } else if mriAssessment?.riskLevel == .low {
            ariaState = "No high-risk MRI features recorded"
        } else {
            ariaState = "Baseline MRI safety state incomplete"
        }
        let response = timeline?.trendSummary ?? "No prior quantitative therapy trend attached."
        let milestones = milestonesFor(agent: context.agent, infusion: infusion, action: assessment.action, nextMRI: nextMRI)
        let lines = [
            "Agent: \(context.agent.displayName)",
            "Action: \(assessment.action.displayName)",
            "ARIA state: \(ariaState)",
            "Next MRI: \(nextMRI)",
            "Response: \(response)"
        ] + milestones.map { "\($0.status.displayName): \($0.title) - \($0.detail)" }
        return NeuroAntiAmyloidClinicTracker(
            agent: context.agent,
            currentInfusion: infusion,
            action: assessment.action,
            nextMRIDescription: nextMRI,
            ariaState: ariaState,
            responseSummary: response,
            milestones: milestones,
            reportLines: lines
        )
    }

    private static func nextMRIDescription(agent: NeuroAntiAmyloidAgent,
                                           infusion: Int?,
                                           lastMRIAt: Date?) -> String {
        guard let infusion else { return "Baseline safety MRI due before treatment start." }
        switch agent {
        case .lecanemab:
            if infusion < 5 { return "Safety MRI due before infusion 5." }
            if infusion < 7 { return "Safety MRI due before infusion 7." }
            if infusion < 14 { return "Safety MRI due before infusion 14." }
            return "Continue symptom-triggered and local protocol MRI surveillance."
        case .donanemab:
            if infusion < 4 { return "Early-treatment safety MRI due per donanemab protocol." }
            if infusion < 7 { return "Next scheduled early-treatment MRI due per site pathway." }
            return "Continue label/site-specific MRI surveillance."
        case .other:
            return lastMRIAt == nil ? "Baseline safety MRI due before treatment start." : "Follow agent-specific MRI surveillance."
        }
    }

    private static func milestonesFor(agent: NeuroAntiAmyloidAgent,
                                      infusion: Int?,
                                      action: NeuroAntiAmyloidAction,
                                      nextMRI: String) -> [NeuroAntiAmyloidClinicMilestone] {
        if action == .holdTherapy {
            return [
                NeuroAntiAmyloidClinicMilestone(id: "hold", title: "Therapy hold review", status: .hold, detail: "Resolve ARIA/high-risk blocker before next infusion."),
                NeuroAntiAmyloidClinicMilestone(id: "mri", title: "Safety MRI", status: .due, detail: nextMRI)
            ]
        }
        let current = infusion ?? 0
        let scheduledInfusions: [Int]
        switch agent {
        case .lecanemab: scheduledInfusions = [5, 7, 14]
        case .donanemab: scheduledInfusions = [4, 7]
        case .other: scheduledInfusions = []
        }
        var milestones = scheduledInfusions.map { target in
            NeuroAntiAmyloidClinicMilestone(
                id: "mri-\(target)",
                title: "Safety MRI before infusion \(target)",
                status: current >= target ? .completed : .due,
                detail: current >= target ? "Milestone passed; verify MRI report in chart." : nextMRI
            )
        }
        if milestones.isEmpty {
            milestones.append(
                NeuroAntiAmyloidClinicMilestone(id: "agent-specific", title: "Agent-specific MRI surveillance", status: .scheduled, detail: nextMRI)
            )
        }
        return milestones
    }
}

public enum NeuroAIClassifierKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case diseasePattern
    case amyloidVisual
    case tauStage
    case datscanPattern
    case perfusionPattern

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .diseasePattern: return "Disease pattern"
        case .amyloidVisual: return "Amyloid visual"
        case .tauStage: return "Tau stage"
        case .datscanPattern: return "DaTscan pattern"
        case .perfusionPattern: return "Perfusion pattern"
        }
    }
}

public struct NeuroAIClassProbability: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let probability: Double
}

public struct NeuroAIClassifierRequest: Codable, Equatable, Sendable {
    public let workflow: NeuroQuantWorkflowProtocol
    public let kind: NeuroAIClassifierKind
    public let modelIdentifier: String
    public let inputSummary: [String]
}

public struct NeuroAIClassifierPrediction: Codable, Equatable, Sendable {
    public let request: NeuroAIClassifierRequest
    public let predictedLabel: String
    public let confidence: Double
    public let probabilities: [NeuroAIClassProbability]
    public let warnings: [String]
    public let reportLines: [String]
}

public enum NeuroAIVisualClassifier {
    public static func makePrediction(workflow: NeuroQuantWorkflowProtocol,
                                      report: BrainPETReport,
                                      patterns: [NeuroDiseasePatternFinding],
                                      visualReadAssist: NeuroVisualReadAssist?,
                                      zScoreMap: NeuroZScoreMap,
                                      modelIdentifier: String? = nil) -> NeuroAIClassifierPrediction {
        let kind = classifierKind(for: workflow)
        let modelID = modelIdentifier ?? "tracer-neuro-heuristic-v1"
        let topPattern = patterns.first
        let baseLabel = topPattern?.kind.displayName ?? expectedLabel(workflow: workflow, report: report)
        var confidence = topPattern?.confidence ?? min(0.75, 0.45 + zScoreMap.peakMagnitude * 0.08)
        var warnings: [String] = ["Heuristic classifier hook; replace modelIdentifier with a validated external model before diagnostic AI use."]
        if visualReadAssist?.concordance == .concordant {
            confidence += 0.05
        } else if visualReadAssist?.concordance == .discordant {
            confidence -= 0.15
            warnings.append("Visual read discordance lowers classifier confidence.")
        }
        confidence = clampDouble(confidence, to: 0.05...0.98)
        var probabilities = patterns.prefix(4).map {
            NeuroAIClassProbability(
                id: $0.kind.rawValue,
                label: $0.kind.displayName,
                probability: clampDouble($0.confidence, to: 0...1)
            )
        }
        if probabilities.isEmpty {
            probabilities = [
                NeuroAIClassProbability(id: "expected", label: baseLabel, probability: confidence),
                NeuroAIClassProbability(id: "normal", label: NeuroDiseasePatternKind.normalOrNonspecific.displayName, probability: max(0.05, 1.0 - confidence))
            ]
        }
        let inputSummary = [
            "Workflow \(workflow.displayName)",
            String(format: "Target %.3f", report.targetSUVR ?? 0),
            String(format: "Peak z %.2f", zScoreMap.peakMagnitude),
            "Visual \(visualReadAssist?.concordance.displayName ?? "not assessed")"
        ]
        let request = NeuroAIClassifierRequest(
            workflow: workflow,
            kind: kind,
            modelIdentifier: modelID,
            inputSummary: inputSummary
        )
        let lines = [
            "AI hook: \(kind.displayName)",
            "Model: \(modelID)",
            String(format: "Prediction: %@ (%.0f%%)", baseLabel, confidence * 100)
        ] + warnings.map { "Warning: \($0)" }
        return NeuroAIClassifierPrediction(
            request: request,
            predictedLabel: baseLabel,
            confidence: confidence,
            probabilities: probabilities.sorted { $0.probability > $1.probability },
            warnings: warnings,
            reportLines: lines
        )
    }

    private static func classifierKind(for workflow: NeuroQuantWorkflowProtocol) -> NeuroAIClassifierKind {
        switch workflow {
        case .amyloidCentiloid: return .amyloidVisual
        case .tauBraak: return .tauStage
        case .datscanStriatal: return .datscanPattern
        case .hmpaoPerfusion: return .perfusionPattern
        case .fdgDementia: return .diseasePattern
        }
    }

    private static func expectedLabel(workflow: NeuroQuantWorkflowProtocol,
                                      report: BrainPETReport) -> String {
        switch workflow {
        case .amyloidCentiloid:
            return (report.centiloid ?? 0) >= 25 ? "Amyloid-positive" : "Amyloid-negative/equivocal"
        case .tauBraak:
            return report.tauGrade?.stage ?? "Tau stage indeterminate"
        case .datscanStriatal:
            return (report.targetSUVR ?? 0) < 2.5 ? "Reduced striatal binding" : "No dopaminergic deficit"
        case .hmpaoPerfusion:
            return report.hypometabolicRegions.isEmpty ? "No focal perfusion deficit" : "Perfusion deficit"
        case .fdgDementia:
            return report.hypometabolicRegions.isEmpty ? "Normal/nonspecific" : "Neurodegenerative hypometabolism"
        }
    }
}

public struct NeuroDICOMExportAuditEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let summary: String
    public let sopClassUID: String?
    public let seriesDescription: String?
    public let requiresSignoff: Bool
}

public struct NeuroDICOMExportAuditTrail: Codable, Equatable, Sendable {
    public let entries: [NeuroDICOMExportAuditEntry]
    public let signedBy: String?
    public let warnings: [String]
    public let reportLines: [String]
}

public enum NeuroDICOMExportAuditTrailBuilder {
    public static func make(manifest: NeuroDICOMExportManifest,
                            clinicalQA: NeuroClinicalQAResult?,
                            signoff: NeuroClinicalSignoff?) -> NeuroDICOMExportAuditTrail {
        var entries: [NeuroDICOMExportAuditEntry] = [
            NeuroDICOMExportAuditEntry(
                id: "sr",
                kind: "dicom-sr",
                summary: "Basic Text SR prepared for \(manifest.structuredReportTitle).",
                sopClassUID: manifest.structuredReportSOPClassUID,
                seriesDescription: manifest.seriesDescription,
                requiresSignoff: true
            )
        ]
        entries.append(contentsOf: manifest.parametricMaps.map {
            NeuroDICOMExportAuditEntry(
                id: "map-\($0.id)",
                kind: "parametric-map",
                summary: "\($0.name) export descriptor in \($0.sourceSpace).",
                sopClassUID: NeuroParametricMapExporter.parametricMapSOPClassUID,
                seriesDescription: $0.dicomSeriesDescription,
                requiresSignoff: true
            )
        })
        var warnings = manifest.warnings
        if signoff == nil {
            warnings.append("DICOM export is prepared but not verified by reader sign-off.")
        }
        if clinicalQA?.status == .blocked {
            warnings.append("Clinical QA is blocked; exported DICOM objects should be marked non-diagnostic/research.")
        }
        let lines = [
            "DICOM audit objects: \(entries.count)",
            "Signed by: \(signoff?.readerName ?? "not signed")"
        ] + entries.map { "\($0.kind): \($0.summary)" } + uniqueStrings(warnings).map { "Warning: \($0)" }
        return NeuroDICOMExportAuditTrail(
            entries: entries,
            signedBy: signoff?.readerName,
            warnings: uniqueStrings(warnings),
            reportLines: lines
        )
    }
}

public struct NeuroQuantClinicalReadiness: Codable, Equatable, Sendable {
    public let status: NeuroQuantClinicalReadinessStatus
    public let evidenceLevel: NeuroQuantEvidenceLevel
    public let blockers: [String]
    public let warnings: [String]
    public let evidenceLines: [String]

    public var reportLines: [String] {
        var lines = [
            "Status: \(status.displayName)",
            "Evidence level: \(evidenceLevel.displayName)"
        ]
        lines.append(contentsOf: evidenceLines)
        if !blockers.isEmpty {
            lines.append(contentsOf: blockers.map { "Blocker: \($0)" })
        }
        if !warnings.isEmpty {
            lines.append(contentsOf: warnings.map { "Warning: \($0)" })
        }
        return lines
    }

    public static func evaluate(workflow: NeuroQuantWorkflowProtocol,
                                atlasValidation: NeuroQuantAtlasValidation,
                                normalDatabase: BrainPETNormalDatabase?,
                                templatePlan: NeuroTemplateRegistrationPlan,
                                localValidation: NeuroQuantClinicalValidationResult?,
                                referenceManifest: NeuroQuantReferencePackManifest?) -> NeuroQuantClinicalReadiness {
        let criteria = localValidation?.acceptanceCriteria
            ?? NeuroQuantAcceptanceCriteria.default(for: workflow)
        var blockers = templatePlan.blockers
        var warnings = templatePlan.warnings
        var evidenceLines: [String] = [
            String(format: "Atlas compatibility %.0f%%; requires %.0f%%.",
                   atlasValidation.score * 100,
                   criteria.minimumAtlasScore * 100)
        ]

        if atlasValidation.score < criteria.minimumAtlasScore {
            blockers.append(String(format: "Atlas compatibility %.0f%% is below the %.0f%% validation gate.",
                                   atlasValidation.score * 100,
                                   criteria.minimumAtlasScore * 100))
        }

        let normalSampleSize = normalDatabase?.entries.map(\.sampleSize).max() ?? 0
        if criteria.minimumNormalSampleSize > 0 {
            if normalDatabase == nil {
                blockers.append("No matching normal database is loaded for \(workflow.displayName).")
            } else if normalSampleSize < criteria.minimumNormalSampleSize {
                warnings.append("Loaded normal database max regional sample size is \(normalSampleSize); recommended minimum is \(criteria.minimumNormalSampleSize).")
            }
            if let normalDatabase {
                evidenceLines.append("Normal database: \(normalDatabase.name), max n=\(normalSampleSize).")
            }
        }

        let evidenceLevel = referenceManifest?.evidenceLevel
            ?? (localValidation?.passed == true ? .localValidation : .researchScaffold)
        if let referenceManifest {
            evidenceLines.append("Reference manifest: \(referenceManifest.name) \(referenceManifest.version).")
            if referenceManifest.workflow != workflow {
                blockers.append("Reference manifest workflow \(referenceManifest.workflow.displayName) does not match \(workflow.displayName).")
            }
            if referenceManifest.atlasPackID != atlasValidation.pack.id {
                warnings.append("Reference manifest atlas \(referenceManifest.atlasPackID) does not match active atlas pack \(atlasValidation.pack.id).")
            }
        }

        if let localValidation {
            evidenceLines.append(String(format: "Validation %@: n=%d, R2 %.3f, slope %.3f, bias %.3f.",
                                        localValidation.metric.displayName,
                                        localValidation.statistics.caseCount,
                                        localValidation.statistics.rSquared,
                                        localValidation.statistics.slope,
                                        localValidation.statistics.meanBias))
            blockers.append(contentsOf: localValidation.failures)
        } else {
            warnings.append("No local validation result is attached; quantitative output remains research-only until site validation is completed.")
        }

        let status: NeuroQuantClinicalReadinessStatus
        if !blockers.isEmpty {
            status = .researchOnly
        } else if localValidation?.passed == true {
            status = evidenceLevel == .regulatoryCleared ? .clinicalLocked : .locallyValidated
        } else {
            status = .validationPending
        }

        return NeuroQuantClinicalReadiness(
            status: status,
            evidenceLevel: evidenceLevel,
            blockers: blockers,
            warnings: warnings,
            evidenceLines: evidenceLines
        )
    }
}

public struct NeuroQuantWorkbenchResult: Codable, Equatable, Sendable {
    public let workflow: NeuroQuantWorkflowProtocol
    public let report: BrainPETReport
    public let anatomyAwareReport: BrainPETAnatomyAwareReport
    public let atlasValidation: NeuroQuantAtlasValidation
    public let templatePlan: NeuroTemplateRegistrationPlan
    public let registrationPipeline: NeuroRegistrationPipelineResult
    public let clinicalReadiness: NeuroQuantClinicalReadiness
    public let validationDashboard: NeuroValidationWorkbenchDashboard
    public let aucDecision: NeuroAUCDecision?
    public let diseasePatterns: [NeuroDiseasePatternFinding]
    public let mriContextAssessment: NeuroMRIContextAssessment?
    public let biomarkerBoard: NeuroDementiaBiomarkerBoard?
    public let antiAmyloidAssessment: NeuroAntiAmyloidTherapyAssessment?
    public let antiAmyloidClinicTracker: NeuroAntiAmyloidClinicTracker?
    public let visualReadAssist: NeuroVisualReadAssist?
    public let aiClassifierPrediction: NeuroAIClassifierPrediction
    public let normalGovernance: NeuroNormalDatabaseGovernance?
    public let comparisonWorkspace: NeuroComparisonWorkspace
    public let dicomExportManifest: NeuroDICOMExportManifest
    public let dicomAuditTrail: NeuroDICOMExportAuditTrail
    public let zScoreMap: NeuroZScoreMap
    public let clusters: [NeuroQuantCluster]
    public let surfaceProjections: [NeuroSurfaceProjectionImage]
    public let striatalMetrics: NeuroStriatalBindingMetrics?
    public let datscanAssessment: NeuroDaTscanClinicalAssessment?
    public let perfusionAssessment: NeuroPerfusionAssessment?
    public let seizureComparison: NeuroSeizurePerfusionComparison?
    public let longitudinalTimeline: NeuroLongitudinalTimeline?
    public let clinicalQA: NeuroClinicalQAResult?
    public let structuredReport: NeuroQuantStructuredReport
}

public enum NeuroQuantWorkbench {
    public static func run(volume: ImageVolume,
                           atlas: LabelMap,
                           normalDatabase: BrainPETNormalDatabase?,
                           workflow: NeuroQuantWorkflowProtocol,
                           anatomyVolume: ImageVolume?,
                           anatomyMode: BrainPETAnatomyMode = .automatic,
                           tauSUVRThreshold: Double? = nil,
                           localValidation: NeuroQuantClinicalValidationResult? = nil,
                           referenceManifest: NeuroQuantReferencePackManifest? = nil,
                           clinicalIntake: NeuroAUCIntake? = nil,
                           mriContext: NeuroMRIContextInput? = nil,
                           acquisitionSignature: NeuroAcquisitionSignature? = nil,
                           phantomRecords: [NeuroPhantomCalibrationRecord] = [],
                           antiAmyloidContext: NeuroAntiAmyloidTherapyContext? = nil,
                           visualRead: NeuroVisualReadInput? = nil,
                           movementDisorderContext: NeuroMovementDisorderContext? = nil,
                           seizureInterictalReport: BrainPETReport? = nil,
                           timelineEvents: [NeuroTimelineEvent] = [],
                           signoff: NeuroClinicalSignoff? = nil) throws -> NeuroQuantWorkbenchResult {
        let atlasValidation = NeuroQuantAtlasRegistry.bestValidation(for: atlas, workflow: workflow)
        let templatePlan = NeuroTemplateRegistrationPlan.make(
            volume: volume,
            anatomyVolume: anatomyVolume,
            atlasValidation: atlasValidation,
            workflow: workflow
        )
        let registrationPipeline = NeuroRegistrationPipeline.plan(
            volume: volume,
            anatomyVolume: anatomyVolume,
            atlasValidation: atlasValidation,
            workflow: workflow
        )
        if let blocker = templatePlan.blockers.first {
            throw NeuroQuantWorkbenchError.blocked(blocker)
        }
        let configuration = workflow.configuration(
            atlas: atlas,
            normalDatabase: normalDatabase,
            tauSUVRThreshold: tauSUVRThreshold
        )
        let anatomyReport = try BrainPETAnalysis.analyzeAnatomyAware(
            volume: volume,
            atlas: atlas,
            anatomyVolume: anatomyVolume,
            requestedMode: anatomyMode,
            configuration: configuration
        )
        let report = anatomyReport.anatomyAwareReport
        let zMap = NeuroZScoreMapBuilder.build(report: report, atlas: atlas, workflow: workflow)
        let clusters = NeuroClusterAnalyzer.findClusters(in: zMap, atlas: atlas)
        let projections = NeuroSurfaceProjectionBuilder.make(from: zMap)
        let striatal = NeuroStriatalBindingMetrics.make(from: report)
        let aucDecision = clinicalIntake.map {
            NeuroAUCDecisionSupport.evaluate(intake: $0, workflow: workflow)
        }
        let diseasePatterns = NeuroDiseasePatternInterpreter.interpret(
            report: report,
            clusters: clusters,
            workflow: workflow,
            striatalMetrics: striatal
        )
        let mriAssessment = mriContext.map {
            NeuroMRIContextAnalyzer.assess(input: $0, workflow: workflow, patterns: diseasePatterns)
        }
        let currentTimelineEvent = NeuroTimelineEvent(
            date: Date(),
            studyUID: volume.seriesUID,
            workflow: workflow,
            targetSUVR: report.targetSUVR,
            centiloid: report.centiloid,
            tauStage: report.tauGrade?.stage,
            therapyPhase: antiAmyloidContext?.candidateForTherapy == true ? antiAmyloidContext?.agent.displayName : nil,
            mriRiskLevel: mriAssessment?.riskLevel
        )
        let longitudinalTimeline = timelineEvents.isEmpty
            ? nil
            : NeuroTimelineBuilder.build(events: timelineEvents + [currentTimelineEvent])
        let biomarkerBoard = NeuroDementiaBiomarkerBoard.make(
            report: report,
            workflow: workflow,
            patterns: diseasePatterns,
            mriAssessment: mriAssessment,
            timeline: longitudinalTimeline
        )
        let antiAmyloidAssessment = antiAmyloidContext.map {
            NeuroAntiAmyloidTherapyAssessment.assess(
                context: $0,
                biomarkerBoard: biomarkerBoard,
                mriAssessment: mriAssessment,
                aucDecision: aucDecision
            )
        }
        let antiAmyloidClinicTracker: NeuroAntiAmyloidClinicTracker? = {
            guard let antiAmyloidContext, let antiAmyloidAssessment else { return nil }
            return NeuroAntiAmyloidClinicTrackerBuilder.build(
                context: antiAmyloidContext,
                assessment: antiAmyloidAssessment,
                timeline: longitudinalTimeline,
                mriAssessment: mriAssessment
            )
        }()
        let visualAssist = NeuroVisualReadAssist.make(
            workflow: workflow,
            report: report,
            patterns: diseasePatterns,
            visualRead: visualRead
        )
        let resolvedSignature = acquisitionSignature ?? NeuroAcquisitionSignature(
            tracer: workflow.tracer,
            reconstructionDescription: volume.seriesDescription.isEmpty ? volume.modality : volume.seriesDescription,
            patientAge: clinicalIntake?.age ?? movementDisorderContext?.age
        )
        let normalGovernance = NeuroNormalDatabaseGovernanceEvaluator.evaluate(
            workflow: workflow,
            normalDatabase: normalDatabase,
            referenceManifest: referenceManifest,
            acquisitionSignature: resolvedSignature,
            patientAge: clinicalIntake?.age ?? movementDisorderContext?.age,
            phantomRecords: phantomRecords
        )
        let datscanAssessment = striatal.map {
            NeuroDaTscanClinicalAssessment.make(
                metrics: $0,
                context: movementDisorderContext,
                normalDatabase: normalDatabase
            )
        }
        let perfusionAssessment = workflow == .hmpaoPerfusion
            ? NeuroPerfusionInterpreter.assess(report: report, clusters: clusters)
            : nil
        let seizureComparison = seizureInterictalReport.map {
            NeuroSeizurePerfusionComparison.compare(interictal: $0, ictal: report, workflow: workflow)
        }
        let comparisonWorkspace = NeuroComparisonWorkspaceBuilder.build(
            workflow: workflow,
            report: report,
            clusters: clusters,
            surfaceProjections: projections,
            timeline: longitudinalTimeline,
            mriAssessment: mriAssessment
        )
        let aiPrediction = NeuroAIVisualClassifier.makePrediction(
            workflow: workflow,
            report: report,
            patterns: diseasePatterns,
            visualReadAssist: visualAssist,
            zScoreMap: zMap
        )
        let clinicalReadiness = NeuroQuantClinicalReadiness.evaluate(
            workflow: workflow,
            atlasValidation: atlasValidation,
            normalDatabase: normalDatabase,
            templatePlan: templatePlan,
            localValidation: localValidation ?? referenceManifest?.validationResult,
            referenceManifest: referenceManifest
        )
        let clinicalQA = NeuroClinicalQAResult.evaluate(
            readiness: clinicalReadiness,
            aucDecision: aucDecision,
            visualReadAssist: visualAssist,
            normalGovernance: normalGovernance,
            antiAmyloidAssessment: antiAmyloidAssessment,
            signoff: signoff
        )
        let validationDashboard = NeuroValidationWorkbench.make(
            workflow: workflow,
            validation: localValidation,
            referenceManifest: referenceManifest,
            normalGovernance: normalGovernance,
            readiness: clinicalReadiness
        )
        let dicomManifest = NeuroParametricMapExporter.makeManifest(
            volume: volume,
            workflow: workflow,
            report: report,
            zScoreMap: zMap,
            striatalMetrics: striatal,
            perfusionAssessment: perfusionAssessment
        )
        let dicomAuditTrail = NeuroDICOMExportAuditTrailBuilder.make(
            manifest: dicomManifest,
            clinicalQA: clinicalQA,
            signoff: signoff
        )
        let baseStructured = NeuroQuantReportBuilder.make(
            workflow: workflow,
            report: report,
            anatomyReport: anatomyReport,
            atlasValidation: atlasValidation,
            templatePlan: templatePlan,
            clinicalReadiness: clinicalReadiness,
            clusters: clusters,
            striatalMetrics: striatal
        )
        let structured = NeuroClinicalReportComposer.compose(
            base: baseStructured,
            aucDecision: aucDecision,
            diseasePatterns: diseasePatterns,
            mriAssessment: mriAssessment,
            biomarkerBoard: biomarkerBoard,
            antiAmyloidAssessment: antiAmyloidAssessment,
            visualReadAssist: visualAssist,
            normalGovernance: normalGovernance,
            datscanAssessment: datscanAssessment,
            perfusionAssessment: perfusionAssessment,
            seizureComparison: seizureComparison,
            clinicalQA: clinicalQA,
            timeline: longitudinalTimeline,
            registrationPipeline: registrationPipeline,
            dicomExportManifest: dicomManifest,
            validationDashboard: validationDashboard,
            comparisonWorkspace: comparisonWorkspace,
            antiAmyloidClinicTracker: antiAmyloidClinicTracker,
            aiClassifierPrediction: aiPrediction,
            dicomAuditTrail: dicomAuditTrail
        )
        return NeuroQuantWorkbenchResult(
            workflow: workflow,
            report: report,
            anatomyAwareReport: anatomyReport,
            atlasValidation: atlasValidation,
            templatePlan: templatePlan,
            registrationPipeline: registrationPipeline,
            clinicalReadiness: clinicalReadiness,
            validationDashboard: validationDashboard,
            aucDecision: aucDecision,
            diseasePatterns: diseasePatterns,
            mriContextAssessment: mriAssessment,
            biomarkerBoard: biomarkerBoard,
            antiAmyloidAssessment: antiAmyloidAssessment,
            antiAmyloidClinicTracker: antiAmyloidClinicTracker,
            visualReadAssist: visualAssist,
            aiClassifierPrediction: aiPrediction,
            normalGovernance: normalGovernance,
            comparisonWorkspace: comparisonWorkspace,
            dicomExportManifest: dicomManifest,
            dicomAuditTrail: dicomAuditTrail,
            zScoreMap: zMap,
            clusters: clusters,
            surfaceProjections: projections,
            striatalMetrics: striatal,
            datscanAssessment: datscanAssessment,
            perfusionAssessment: perfusionAssessment,
            seizureComparison: seizureComparison,
            longitudinalTimeline: longitudinalTimeline,
            clinicalQA: clinicalQA,
            structuredReport: structured
        )
    }
}

public enum NeuroQuantWorkbenchError: Error, LocalizedError, Equatable {
    case blocked(String)

    public var errorDescription: String? {
        switch self {
        case .blocked(let reason):
            return "Neuroquantification workflow is blocked: \(reason)"
        }
    }
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values where seen.insert(value).inserted {
        result.append(value)
    }
    return result
}

private func clampDouble(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}
