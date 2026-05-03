import Foundation
import SwiftUI

public enum AutoContourStructurePriority: String, CaseIterable, Identifiable, Sendable {
    case required = "Required"
    case recommended = "Recommended"
    case optional = "Optional"

    public var id: String { rawValue }
}

public enum AutoContourReviewState: String, CaseIterable, Identifiable, Sendable {
    case notStarted = "Not started"
    case planned = "Planned"
    case running = "Running"
    case draft = "Draft"
    case needsReview = "Needs review"
    case approved = "Approved"
    case blocked = "Blocked"

    public var id: String { rawValue }
}

public enum AutoContourQAFindingSeverity: String, CaseIterable, Identifiable, Sendable {
    case info = "Info"
    case warning = "Warning"
    case error = "Error"

    public var id: String { rawValue }
}

public struct AutoContourStructureTemplate: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let category: LabelCategory
    public let aliases: [String]
    public let priority: AutoContourStructurePriority
    public let requiresNonEmptyMask: Bool
    public let reviewHint: String
    public let color: Color

    public init(id: String,
                name: String,
                category: LabelCategory,
                aliases: [String] = [],
                priority: AutoContourStructurePriority = .recommended,
                requiresNonEmptyMask: Bool = true,
                reviewHint: String = "",
                color: Color) {
        self.id = id
        self.name = name
        self.category = category
        self.aliases = aliases
        self.priority = priority
        self.requiresNonEmptyMask = requiresNonEmptyMask
        self.reviewHint = reviewHint
        self.color = color
    }
}

public struct AutoContourProtocolTemplate: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let shortName: String
    public let description: String
    public let modalities: [Modality]
    public let presetName: String
    public let preferredRoutePrompt: String
    public let preferredNNUnetEntryID: String?
    public let structures: [AutoContourStructureTemplate]

    public init(id: String,
                displayName: String,
                shortName: String,
                description: String,
                modalities: [Modality],
                presetName: String,
                preferredRoutePrompt: String,
                preferredNNUnetEntryID: String? = nil,
                structures: [AutoContourStructureTemplate]) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.description = description
        self.modalities = modalities
        self.presetName = presetName
        self.preferredRoutePrompt = preferredRoutePrompt
        self.preferredNNUnetEntryID = preferredNNUnetEntryID
        self.structures = structures
    }
}

public struct AutoContourStructurePlan: Identifiable, Sendable {
    public let id: String
    public let template: AutoContourStructureTemplate
    public let route: SegmentationRAGPlan?
    public var state: AutoContourReviewState
    public var notes: [String]

    public var backendLabel: String {
        guard let route else { return "Review only" }
        if let nnunetDatasetID = route.nnunetDatasetID {
            return "nnU-Net \(nnunetDatasetID)"
        }
        if let matchedMONAIModel = route.matchedMONAIModel {
            return "MONAI \(matchedMONAIModel)"
        }
        return route.preferredEngine.displayName
    }
}

public struct AutoContourSession: Identifiable, Sendable {
    public let id: UUID
    public let protocolTemplate: AutoContourProtocolTemplate
    public let volumeIdentity: String
    public let volumeDescription: String
    public let createdAt: Date
    public var status: AutoContourReviewState
    public var primaryRoute: SegmentationRAGPlan?
    public var structurePlans: [AutoContourStructurePlan]
    public var qaReport: AutoContourQAReport?
    public var approvedAt: Date?
    public var generatedRunID: UUID?

    public var preferredNNUnetEntry: NNUnetCatalog.Entry? {
        protocolTemplate.preferredNNUnetEntryID.flatMap(NNUnetCatalog.byID)
    }

    public var routedStructureCount: Int {
        structurePlans.filter { $0.route != nil }.count
    }

    public var blockingFindingCount: Int {
        qaReport?.blockingFindingCount ?? 0
    }
}

public struct AutoContourQAFinding: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let severity: AutoContourQAFindingSeverity
    public let structureName: String?
    public let message: String

    public init(id: UUID = UUID(),
                severity: AutoContourQAFindingSeverity,
                structureName: String? = nil,
                message: String) {
        self.id = id
        self.severity = severity
        self.structureName = structureName
        self.message = message
    }
}

public struct AutoContourQAReport: Equatable, Sendable {
    public let protocolID: String
    public let structureCount: Int
    public let matchedStructureCount: Int
    public let emptyRequiredCount: Int
    public let missingRequiredCount: Int
    public let findings: [AutoContourQAFinding]

    public var blockingFindingCount: Int {
        findings.filter { $0.severity == .error }.count
    }

    public var warningCount: Int {
        findings.filter { $0.severity == .warning }.count
    }

    public var hasBlockingFindings: Bool { blockingFindingCount > 0 }

    public var reviewState: AutoContourReviewState {
        if hasBlockingFindings { return .blocked }
        return warningCount > 0 ? .needsReview : .needsReview
    }

    public var compactSummary: String {
        if findings.isEmpty {
            return "\(matchedStructureCount)/\(structureCount) structures matched"
        }
        return "\(matchedStructureCount)/\(structureCount) matched, \(blockingFindingCount) blocker(s), \(warningCount) warning(s)"
    }
}

public enum AutoContourWorkflow {
    public static let templates: [AutoContourProtocolTemplate] = [
        wholeBodyOAR,
        headNeckOAR,
        thoraxOAR,
        abdomenOAR,
        pelvisProstateOAR,
        neuroBrainTumor,
        petOncologyLesions
    ]

    public static func template(id: String) -> AutoContourProtocolTemplate? {
        templates.first { $0.id == id }
    }

    public static func plan(template: AutoContourProtocolTemplate,
                            volume: ImageVolume,
                            availableMONAIModels: [String] = []) -> AutoContourSession {
        let modality = Modality.normalize(volume.modality)
        let primaryPrompt = "auto contour \(template.displayName) \(template.preferredRoutePrompt) best model"
        let primaryRoute = SegmentationRAG.plan(for: primaryPrompt,
                                                currentModality: modality,
                                                availableMONAIModels: availableMONAIModels)
        let structurePlans = template.structures.map { structure in
            let prompt = "auto contour \(template.displayName) \(structure.name) \(template.preferredRoutePrompt)"
            let route = SegmentationRAG.plan(for: prompt,
                                             currentModality: modality,
                                             availableMONAIModels: availableMONAIModels)
            var notes: [String] = []
            if route == nil {
                notes.append("No executable route matched this structure.")
            } else if let matched = route?.matchedMONAIModel {
                notes.append("Matched MONAI model \(matched).")
            } else if let datasetID = route?.nnunetDatasetID {
                notes.append("Matched nnU-Net \(datasetID).")
            }
            return AutoContourStructurePlan(
                id: structure.id,
                template: structure,
                route: route,
                state: route == nil ? .planned : .planned,
                notes: notes
            )
        }
        let volumeDescription = [
            volume.patientName.isEmpty ? volume.patientID : volume.patientName,
            volume.modality,
            volume.seriesDescription
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " | ")

        return AutoContourSession(
            id: UUID(),
            protocolTemplate: template,
            volumeIdentity: volume.sessionIdentity,
            volumeDescription: volumeDescription.isEmpty ? volume.sessionIdentity : volumeDescription,
            createdAt: Date(),
            status: .planned,
            primaryRoute: primaryRoute,
            structurePlans: structurePlans,
            qaReport: nil,
            approvedAt: nil,
            generatedRunID: nil
        )
    }

    public static func labelPreset(for template: AutoContourProtocolTemplate) -> LabelPresetSet {
        LabelPresetSet(
            name: template.presetName,
            description: template.description,
            classes: template.structures.enumerated().map { offset, structure in
                LabelClass(labelID: UInt16(offset + 1),
                           name: structure.name,
                           category: structure.category,
                           color: structure.color,
                           notes: structure.reviewHint)
            }
        )
    }

    @discardableResult
    public static func installMissingStructures(from template: AutoContourProtocolTemplate,
                                                into labelMap: LabelMap) -> Int {
        var nextID = (labelMap.classes.map(\.labelID).max() ?? 0) + 1
        var added = 0
        for structure in template.structures where matchingClass(in: labelMap, for: structure) == nil {
            while nextID == 0 || labelMap.classes.contains(where: { $0.labelID == nextID }) {
                nextID += 1
            }
            labelMap.addClass(LabelClass(labelID: nextID,
                                         name: structure.name,
                                         category: structure.category,
                                         color: structure.color,
                                         notes: structure.reviewHint))
            nextID += 1
            added += 1
        }
        if added > 0 {
            labelMap.objectWillChange.send()
        }
        return added
    }

    public static func qaReport(labelMap: LabelMap,
                                template: AutoContourProtocolTemplate,
                                referenceVolume: ImageVolume? = nil) -> AutoContourQAReport {
        let counts = labelMap.voxelCounts()
        var findings: [AutoContourQAFinding] = []
        var matched = 0
        var missingRequired = 0
        var emptyRequired = 0

        if let referenceVolume {
            if referenceVolume.depth != labelMap.depth ||
                referenceVolume.height != labelMap.height ||
                referenceVolume.width != labelMap.width {
                findings.append(AutoContourQAFinding(
                    severity: .error,
                    message: "Label map grid does not match the review volume."
                ))
            } else if !labelMap.parentSeriesUID.isEmpty,
                      !referenceVolume.seriesUID.isEmpty,
                      labelMap.parentSeriesUID != referenceVolume.seriesUID {
                findings.append(AutoContourQAFinding(
                    severity: .warning,
                    message: "Label map is dimensionally aligned but references a different source series."
                ))
            }
        }

        if counts.isEmpty {
            findings.append(AutoContourQAFinding(
                severity: .error,
                message: "No contour voxels are present."
            ))
        }

        let duplicateNames = Dictionary(grouping: labelMap.classes.map { normalized($0.name) }, by: { $0 })
            .filter { !$0.key.isEmpty && $0.value.count > 1 }
            .map(\.key)
        if !duplicateNames.isEmpty {
            findings.append(AutoContourQAFinding(
                severity: .warning,
                message: "Duplicate structure names are present in the active label map."
            ))
        }

        for structure in template.structures {
            guard let cls = matchingClass(in: labelMap, for: structure) else {
                if structure.priority == .required {
                    missingRequired += 1
                    findings.append(AutoContourQAFinding(
                        severity: .error,
                        structureName: structure.name,
                        message: "Required structure is missing."
                    ))
                } else if structure.priority == .recommended {
                    findings.append(AutoContourQAFinding(
                        severity: .warning,
                        structureName: structure.name,
                        message: "Recommended structure is missing."
                    ))
                }
                continue
            }

            matched += 1
            let voxelCount = counts[cls.labelID] ?? 0
            guard structure.requiresNonEmptyMask, voxelCount == 0 else { continue }
            if structure.priority == .required {
                emptyRequired += 1
                findings.append(AutoContourQAFinding(
                    severity: .error,
                    structureName: structure.name,
                    message: "Required structure has no contour voxels."
                ))
            } else if structure.priority == .recommended {
                findings.append(AutoContourQAFinding(
                    severity: .warning,
                    structureName: structure.name,
                    message: "Recommended structure has no contour voxels."
                ))
            }
        }

        return AutoContourQAReport(protocolID: template.id,
                                   structureCount: template.structures.count,
                                   matchedStructureCount: matched,
                                   emptyRequiredCount: emptyRequired,
                                   missingRequiredCount: missingRequired,
                                   findings: findings)
    }

    public static func metadata(for session: AutoContourSession,
                                report: AutoContourQAReport?) -> [String: String] {
        var metadata: [String: String] = [
            "autoContour.protocolID": session.protocolTemplate.id,
            "autoContour.protocol": session.protocolTemplate.displayName,
            "autoContour.status": session.status.rawValue,
            "autoContour.expectedStructures": "\(session.protocolTemplate.structures.count)",
            "autoContour.routedStructures": "\(session.routedStructureCount)"
        ]
        if let route = session.primaryRoute {
            metadata["autoContour.primaryRoute"] = route.modelName
            metadata["autoContour.primaryEngine"] = route.preferredEngine.displayName
            metadata["autoContour.primaryLabel"] = route.labelName
            if let datasetID = route.nnunetDatasetID {
                metadata["autoContour.nnunetDataset"] = datasetID
            }
            if let monai = route.matchedMONAIModel {
                metadata["autoContour.monaiModel"] = monai
            }
        }
        if let preferred = session.preferredNNUnetEntry {
            metadata["autoContour.preferredNNUnet"] = preferred.datasetID
        }
        if let report {
            metadata["autoContour.qaSummary"] = report.compactSummary
            metadata["autoContour.blockers"] = "\(report.blockingFindingCount)"
            metadata["autoContour.warnings"] = "\(report.warningCount)"
        }
        return metadata
    }

    public static func matchingClass(in labelMap: LabelMap,
                                     for structure: AutoContourStructureTemplate) -> LabelClass? {
        let candidates = Set(([structure.name] + structure.aliases).map(normalized))
        return labelMap.classes.first { cls in
            let name = normalized(cls.name)
            return candidates.contains(name)
                || candidates.contains(name.replacingOccurrences(of: " ", with: "_"))
                || candidates.contains(name.replacingOccurrences(of: "_", with: " "))
        }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func organ(_ id: String,
                              _ name: String,
                              _ aliases: [String] = [],
                              priority: AutoContourStructurePriority = .recommended,
                              color: Color) -> AutoContourStructureTemplate {
        AutoContourStructureTemplate(id: id,
                                     name: name,
                                     category: .rtOAR,
                                     aliases: aliases,
                                     priority: priority,
                                     reviewHint: "Review organ-at-risk boundary and slice continuity.",
                                     color: color)
    }

    private static func target(_ id: String,
                               _ name: String,
                               _ aliases: [String] = [],
                               priority: AutoContourStructurePriority = .required,
                               color: Color) -> AutoContourStructureTemplate {
        AutoContourStructureTemplate(id: id,
                                     name: name,
                                     category: .rtTarget,
                                     aliases: aliases,
                                     priority: priority,
                                     reviewHint: "Physician review required before treatment-planning export.",
                                     color: color)
    }

    private static let wholeBodyOAR = AutoContourProtocolTemplate(
        id: "whole-body-oar",
        displayName: "Whole Body OAR Autocontour",
        shortName: "Whole Body",
        description: "Whole-body CT organ-at-risk review set with TotalSegmentator-style labels.",
        modalities: [.CT, .MR],
        presetName: "AutoContour Whole Body OAR",
        preferredRoutePrompt: "whole body CT anatomy OAR total segmentator organs",
        preferredNNUnetEntryID: "TotalSegmentatorCT",
        structures: [
            organ("liver", "Liver", ["liver"], priority: .required, color: Color(r: 230, g: 164, b: 72)),
            organ("spleen", "Spleen", ["spleen"], priority: .required, color: Color(r: 180, g: 82, b: 160)),
            organ("heart", "Heart", ["heart"], priority: .required, color: Color(r: 230, g: 75, b: 88)),
            organ("lung-left", "Left lung", ["lung_left", "left lung", "lung_upper_lobe_left", "lung_lower_lobe_left"], priority: .required, color: Color(r: 95, g: 185, b: 230)),
            organ("lung-right", "Right lung", ["lung_right", "right lung", "lung_upper_lobe_right", "lung_middle_lobe_right", "lung_lower_lobe_right"], priority: .required, color: Color(r: 75, g: 205, b: 205)),
            organ("kidney-left", "Left kidney", ["kidney_left", "left kidney"], priority: .required, color: Color(r: 95, g: 140, b: 235)),
            organ("kidney-right", "Right kidney", ["kidney_right", "right kidney"], priority: .required, color: Color(r: 85, g: 120, b: 215)),
            organ("spinal-cord", "Spinal cord", ["spinal_cord", "cord"], priority: .required, color: Color(r: 245, g: 225, b: 95)),
            organ("aorta", "Aorta", ["aorta"], color: Color(r: 220, g: 64, b: 64)),
            organ("esophagus", "Esophagus", ["oesophagus", "esophagus"], color: Color(r: 230, g: 135, b: 90)),
            organ("stomach", "Stomach", ["stomach"], color: Color(r: 230, g: 185, b: 90)),
            organ("bladder", "Bladder", ["urinary_bladder", "bladder"], color: Color(r: 110, g: 170, b: 230))
        ]
    )

    private static let headNeckOAR = AutoContourProtocolTemplate(
        id: "head-neck-oar",
        displayName: "Head and Neck OAR Autocontour",
        shortName: "Head Neck",
        description: "Head and neck radiotherapy organ-at-risk checklist.",
        modalities: [.CT, .MR],
        presetName: "AutoContour Head Neck OAR",
        preferredRoutePrompt: "head neck OAR parotid mandible optic chiasm",
        structures: [
            organ("brainstem", "Brainstem", ["brain stem"], priority: .required, color: Color(r: 255, g: 215, b: 90)),
            organ("spinal-cord", "Spinal cord", ["spinal_cord", "cord"], priority: .required, color: Color(r: 245, g: 225, b: 95)),
            organ("optic-chiasm", "Optic chiasm", ["chiasm"], priority: .required, color: Color(r: 140, g: 210, b: 255)),
            organ("optic-nerve-left", "Left optic nerve", ["optic nerve left", "left optic nerve"], priority: .required, color: Color(r: 120, g: 190, b: 245)),
            organ("optic-nerve-right", "Right optic nerve", ["optic nerve right", "right optic nerve"], priority: .required, color: Color(r: 105, g: 175, b: 235)),
            organ("parotid-left", "Left parotid", ["parotid left", "left parotid"], priority: .required, color: Color(r: 115, g: 215, b: 145)),
            organ("parotid-right", "Right parotid", ["parotid right", "right parotid"], priority: .required, color: Color(r: 90, g: 195, b: 125)),
            organ("submandibular-left", "Left submandibular gland", ["submandibular left", "left submandibular"], color: Color(r: 90, g: 205, b: 170)),
            organ("submandibular-right", "Right submandibular gland", ["submandibular right", "right submandibular"], color: Color(r: 80, g: 185, b: 150)),
            organ("mandible", "Mandible", ["jaw"], priority: .required, color: Color(r: 235, g: 205, b: 150)),
            organ("oral-cavity", "Oral cavity", ["mouth"], color: Color(r: 225, g: 125, b: 175)),
            organ("larynx", "Larynx", ["larynx"], color: Color(r: 215, g: 130, b: 215)),
            organ("cochlea-left", "Left cochlea", ["cochlea left", "left cochlea"], color: Color(r: 180, g: 165, b: 255)),
            organ("cochlea-right", "Right cochlea", ["cochlea right", "right cochlea"], color: Color(r: 160, g: 145, b: 235))
        ]
    )

    private static let thoraxOAR = AutoContourProtocolTemplate(
        id: "thorax-oar",
        displayName: "Thorax OAR Autocontour",
        shortName: "Thorax",
        description: "Thoracic radiotherapy organ-at-risk checklist.",
        modalities: [.CT, .MR],
        presetName: "AutoContour Thorax OAR",
        preferredRoutePrompt: "thorax chest OAR lungs heart esophagus spinal cord total segmentator",
        preferredNNUnetEntryID: "TotalSegmentatorCT",
        structures: [
            organ("lung-left", "Left lung", ["lung_left", "left lung", "lung_upper_lobe_left", "lung_lower_lobe_left"], priority: .required, color: Color(r: 95, g: 185, b: 230)),
            organ("lung-right", "Right lung", ["lung_right", "right lung", "lung_upper_lobe_right", "lung_middle_lobe_right", "lung_lower_lobe_right"], priority: .required, color: Color(r: 75, g: 205, b: 205)),
            organ("heart", "Heart", ["heart"], priority: .required, color: Color(r: 230, g: 75, b: 88)),
            organ("esophagus", "Esophagus", ["oesophagus", "esophagus"], priority: .required, color: Color(r: 230, g: 135, b: 90)),
            organ("spinal-cord", "Spinal cord", ["spinal_cord", "cord"], priority: .required, color: Color(r: 245, g: 225, b: 95)),
            organ("trachea", "Trachea", ["trachea"], color: Color(r: 150, g: 215, b: 215)),
            organ("aorta", "Aorta", ["aorta"], color: Color(r: 220, g: 64, b: 64)),
            organ("brachial-plexus-left", "Left brachial plexus", ["brachial plexus left", "left brachial plexus"], color: Color(r: 170, g: 145, b: 230)),
            organ("brachial-plexus-right", "Right brachial plexus", ["brachial plexus right", "right brachial plexus"], color: Color(r: 150, g: 125, b: 215))
        ]
    )

    private static let abdomenOAR = AutoContourProtocolTemplate(
        id: "abdomen-oar",
        displayName: "Abdomen OAR Autocontour",
        shortName: "Abdomen",
        description: "Abdominal organ-at-risk checklist for CT review.",
        modalities: [.CT, .MR],
        presetName: "AutoContour Abdomen OAR",
        preferredRoutePrompt: "abdomen OAR abdominal organs AMOS liver kidney bowel duodenum",
        preferredNNUnetEntryID: "AMOS22",
        structures: [
            organ("liver", "Liver", ["liver"], priority: .required, color: Color(r: 230, g: 164, b: 72)),
            organ("spleen", "Spleen", ["spleen"], priority: .required, color: Color(r: 180, g: 82, b: 160)),
            organ("kidney-left", "Left kidney", ["left_kidney", "kidney_left", "left kidney"], priority: .required, color: Color(r: 95, g: 140, b: 235)),
            organ("kidney-right", "Right kidney", ["right_kidney", "kidney_right", "right kidney"], priority: .required, color: Color(r: 85, g: 120, b: 215)),
            organ("stomach", "Stomach", ["stomach"], priority: .required, color: Color(r: 230, g: 185, b: 90)),
            organ("duodenum", "Duodenum", ["duodenum"], priority: .required, color: Color(r: 215, g: 150, b: 90)),
            organ("pancreas", "Pancreas", ["pancreas"], priority: .required, color: Color(r: 225, g: 105, b: 150)),
            organ("bowel", "Bowel", ["small_bowel", "small bowel", "colon", "large bowel"], color: Color(r: 210, g: 135, b: 105)),
            organ("aorta", "Aorta", ["aorta"], color: Color(r: 220, g: 64, b: 64)),
            organ("spinal-cord", "Spinal cord", ["spinal_cord", "cord"], color: Color(r: 245, g: 225, b: 95))
        ]
    )

    private static let pelvisProstateOAR = AutoContourProtocolTemplate(
        id: "pelvis-prostate-oar",
        displayName: "Pelvis Prostate OAR Autocontour",
        shortName: "Pelvis",
        description: "Pelvic radiotherapy structures for prostate planning review.",
        modalities: [.CT, .MR],
        presetName: "AutoContour Pelvis Prostate OAR",
        preferredRoutePrompt: "pelvis prostate OAR bladder rectum femoral heads prostate",
        preferredNNUnetEntryID: "TotalSegmentatorCT",
        structures: [
            target("prostate", "Prostate", ["prostate", "prostate_or_uterus"], color: Color(r: 255, g: 120, b: 80)),
            target("seminal-vesicles", "Seminal vesicles", ["seminal vesicles"], priority: .recommended, color: Color(r: 245, g: 145, b: 95)),
            organ("bladder", "Bladder", ["urinary_bladder", "bladder"], priority: .required, color: Color(r: 110, g: 170, b: 230)),
            organ("rectum", "Rectum", ["rectum"], priority: .required, color: Color(r: 220, g: 135, b: 95)),
            organ("femoral-head-left", "Left femoral head", ["femur head left", "left femoral head", "femur_left", "hip_left"], priority: .required, color: Color(r: 205, g: 190, b: 145)),
            organ("femoral-head-right", "Right femoral head", ["femur head right", "right femoral head", "femur_right", "hip_right"], priority: .required, color: Color(r: 190, g: 175, b: 130)),
            organ("bowel-bag", "Bowel bag", ["bowel", "bowel bag", "small_bowel", "colon"], color: Color(r: 210, g: 135, b: 105)),
            organ("penile-bulb", "Penile bulb", ["penile bulb"], priority: .optional, color: Color(r: 220, g: 170, b: 130))
        ]
    )

    private static let neuroBrainTumor = AutoContourProtocolTemplate(
        id: "neuro-brain-tumor",
        displayName: "Brain Tumor Autocontour",
        shortName: "Brain Tumor",
        description: "Brain MRI tumor-compartment review set.",
        modalities: [.MR],
        presetName: "AutoContour Brain Tumor",
        preferredRoutePrompt: "brain tumor glioma BraTS edema enhancing tumor core",
        preferredNNUnetEntryID: "BraTS-GLI",
        structures: [
            target("edema", "Edema", ["edema", "oedema", "flair abnormality"], priority: .required, color: Color(r: 95, g: 185, b: 255)),
            target("non-enhancing-core", "Non-enhancing tumor core", ["non_enhancing_core", "non enhancing core"], priority: .required, color: Color(r: 255, g: 185, b: 75)),
            target("enhancing-tumor", "Enhancing tumor", ["enhancing_tumor", "enhancing tumor"], priority: .required, color: Color(r: 245, g: 80, b: 92)),
            target("necrosis", "Necrotic tumor core", ["necrosis", "necrotic"], priority: .recommended, color: Color(r: 130, g: 100, b: 95))
        ]
    )

    private static let petOncologyLesions = AutoContourProtocolTemplate(
        id: "pet-oncology-lesions",
        displayName: "PET Oncology Lesion Autocontour",
        shortName: "PET Lesions",
        description: "Whole-body PET/CT lesion workflow with uptake classification review labels.",
        modalities: [.PT, .CT],
        presetName: "AutoContour PET Oncology",
        preferredRoutePrompt: "whole body PET CT FDG PSMA lesion tumor burden LesionTracer AutoPET",
        preferredNNUnetEntryID: "LesionTracer-AutoPETIII",
        structures: [
            AutoContourStructureTemplate(id: "fdg-avid-lesion",
                                         name: "FDG-avid lesion",
                                         category: .lesion,
                                         aliases: ["pet_lesion", "fdg_avid_lesion", "tumor", "lesion", "psma lesion"],
                                         priority: .required,
                                         reviewHint: "Confirm physiologic uptake and inflammatory false positives before saving.",
                                         color: Color(r: 255, g: 80, b: 72)),
            AutoContourStructureTemplate(id: "physiologic-uptake",
                                         name: "Physiological uptake",
                                         category: .nuclearUptake,
                                         aliases: ["physiologic uptake", "normal uptake"],
                                         priority: .recommended,
                                         requiresNonEmptyMask: false,
                                         reviewHint: "Use for explicit exclusion labels when needed.",
                                         color: Color(r: 95, g: 180, b: 235)),
            AutoContourStructureTemplate(id: "inflammation",
                                         name: "Inflammation",
                                         category: .nuclearUptake,
                                         aliases: ["infection", "reactive"],
                                         priority: .optional,
                                         requiresNonEmptyMask: false,
                                         reviewHint: "Use for non-malignant uptake patterns.",
                                         color: Color(r: 245, g: 180, b: 70)),
            AutoContourStructureTemplate(id: "brown-fat",
                                         name: "Brown fat",
                                         category: .nuclearUptake,
                                         aliases: ["brown fat"],
                                         priority: .optional,
                                         requiresNonEmptyMask: false,
                                         reviewHint: "Use for symmetric supraclavicular or paraspinal uptake.",
                                         color: Color(r: 170, g: 120, b: 80)),
            AutoContourStructureTemplate(id: "bone-marrow-uptake",
                                         name: "Bone marrow uptake",
                                         category: .nuclearUptake,
                                         aliases: ["marrow uptake", "bone marrow"],
                                         priority: .optional,
                                         requiresNonEmptyMask: false,
                                         reviewHint: "Use for diffuse marrow activation patterns.",
                                         color: Color(r: 210, g: 140, b: 210))
        ]
    )
}
