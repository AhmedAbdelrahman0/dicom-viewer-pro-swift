import Foundation

public enum SegmentationExecutionEngine: String, Equatable, Hashable {
    case localTools
    case monaiLabel
    case nnUNet

    public var displayName: String {
        switch self {
        case .localTools: return "Local tools"
        case .monaiLabel: return "MONAI Label"
        case .nnUNet: return "nnU-Net"
        }
    }
}

public struct SegmentationLabelRoute: Equatable, Hashable {
    public let labelName: String
    public let aliases: [String]

    public init(labelName: String, aliases: [String]) {
        self.labelName = labelName
        self.aliases = aliases
    }
}

public struct SegmentationModelCard: Identifiable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let presetName: String
    public let modalities: [Modality]
    public let preferredTool: LabelingTool
    public let aliases: [String]
    public let labels: [SegmentationLabelRoute]
    public let monaiKeywords: [String]
    public let preferredEngine: SegmentationExecutionEngine
    public let nnunetEntryID: String?
    public let rationale: String

    public init(id: String,
                displayName: String,
                presetName: String,
                modalities: [Modality],
                preferredTool: LabelingTool,
                aliases: [String],
                labels: [SegmentationLabelRoute],
                monaiKeywords: [String],
                preferredEngine: SegmentationExecutionEngine = .localTools,
                nnunetEntryID: String? = nil,
                rationale: String) {
        self.id = id
        self.displayName = displayName
        self.presetName = presetName
        self.modalities = modalities
        self.preferredTool = preferredTool
        self.aliases = aliases
        self.labels = labels
        self.monaiKeywords = monaiKeywords
        self.preferredEngine = preferredEngine
        self.nnunetEntryID = nnunetEntryID
        self.rationale = rationale
    }
}

public struct SegmentationRAGPlan: Equatable {
    public let diseaseProcess: String
    public let requestedTarget: String
    public let modelName: String
    public let presetName: String
    public let labelName: String
    public let tool: LabelingTool
    public let confidence: Double
    public let rationale: String
    public let evidence: [String]
    public let monaiModelKeywords: [String]
    public let matchedMONAIModel: String?
    public let preferredEngine: SegmentationExecutionEngine
    public let nnunetEntryID: String?
    public let nnunetDatasetID: String?
    public let nnunetDisplayName: String?
    public let nnunetMultiChannel: Bool

    public var summary: String {
        var parts = [
            "Model route: \(modelName)",
            "Engine: \(preferredEngine.displayName)",
            "Preset: \(presetName)",
            "Label: \(labelName)",
            "Tool: \(tool.displayName)",
            "Confidence: \(Int(confidence * 100))%"
        ]
        if let matchedMONAIModel {
            parts.append("MONAI model: \(matchedMONAIModel)")
        }
        if let nnunetDatasetID {
            parts.append("nnU-Net: \(nnunetDatasetID)")
        }
        return parts.joined(separator: " | ")
    }
}

public enum SegmentationRAG {
    public static let modelCards: [SegmentationModelCard] = [
        SegmentationModelCard(
            id: "autopet-fdg-lesion",
            displayName: "AutoPET FDG PET/CT lesion segmentation",
            presetName: "AutoPET",
            modalities: [.PT],
            preferredTool: .suvGradient,
            aliases: [
                "autopet", "auto pet", "pet lesion", "fdg lesion", "fdg avid",
                "fdg-avid", "lymphoma", "metastasis", "metastases", "melanoma",
                "recurrent disease", "residual disease", "tumor burden",
                "whole body pet", "pet ct oncology", "infection", "inflammation"
            ],
            labels: [
                route("FDG-avid lesion", [
                    "fdg avid lesion", "lesion", "tumor", "tumour", "cancer",
                    "malignancy", "metastasis", "metastases", "lymphoma",
                    "primary", "recurrence", "residual disease", "avid disease"
                ]),
                route("Physiological uptake", [
                    "physiological", "physiologic", "normal uptake", "urine",
                    "brain uptake", "myocardial uptake"
                ]),
                route("Inflammation", ["inflammation", "infection", "sarcoid", "reactive"]),
                route("Brown fat", ["brown fat", "supraclavicular fat"]),
                route("Bone marrow uptake", ["bone marrow", "marrow uptake"])
            ],
            monaiKeywords: ["autopet", "fdg", "pet", "lesion", "tumor", "lymphoma"],
            rationale: "FDG PET/CT disease burden is best routed to a PET lesion model, then refined with SUV gradient or threshold cleanup."
        ),
        SegmentationModelCard(
            id: "pet-focal-uptake-taxonomy",
            displayName: "PET focal uptake classification labels",
            presetName: "PET Focal Uptake",
            modalities: [.PT],
            preferredTool: .suvGradient,
            aliases: [
                "pet hotspot", "hotspot", "uptake classification", "classify uptake",
                "nodal uptake", "distant metastasis", "bone metastasis", "liver metastasis",
                "pulmonary metastasis", "physiologic uptake"
            ],
            labels: [
                route("Primary tumor", ["primary tumor", "primary cancer", "primary lesion"]),
                route("Lymph node (N+)", ["node", "nodal", "lymph node", "adenopathy"]),
                route("Distant metastasis", ["distant metastasis", "metastatic disease", "mets"]),
                route("Bone metastasis", ["bone metastasis", "osseous metastasis", "skeletal metastasis"]),
                route("Liver metastasis", ["liver metastasis", "hepatic metastasis"]),
                route("Pulmonary metastasis", ["lung metastasis", "pulmonary metastasis"]),
                route("Physiological", ["physiological", "physiologic", "normal uptake"]),
                route("Inflammation", ["inflammation", "infection", "reactive"])
            ],
            monaiKeywords: ["pet", "uptake", "lesion", "metastasis", "node"],
            rationale: "Use PET focal uptake labels when the task is lesion classification rather than only binary lesion extraction."
        ),
        SegmentationModelCard(
            id: "totalsegmentator-anatomy",
            displayName: "TotalSegmentator whole-body anatomy",
            presetName: "TotalSegmentator",
            modalities: [.CT, .MR],
            preferredTool: .regionGrow,
            aliases: [
                "total segmentator", "totalsegmentator", "whole body anatomy",
                "full anatomy", "all organs", "organ segmentation", "body composition",
                "ct anatomy", "mr anatomy", "oar anatomy"
            ],
            labels: [
                route("liver", ["liver", "hepatic"]),
                route("spleen", ["spleen", "splenic"]),
                route("pancreas", ["pancreas", "pancreatic"]),
                route("kidney_left", ["left kidney", "kidney left"]),
                route("kidney_right", ["right kidney", "kidney right"]),
                route("lung_upper_lobe_left", ["left upper lobe", "lul"]),
                route("lung_lower_lobe_left", ["left lower lobe", "lll"]),
                route("lung_upper_lobe_right", ["right upper lobe", "rul"]),
                route("lung_middle_lobe_right", ["right middle lobe", "rml"]),
                route("lung_lower_lobe_right", ["right lower lobe", "rll"]),
                route("heart", ["heart", "cardiac"]),
                route("aorta", ["aorta", "aortic"]),
                route("spinal_cord", ["spinal cord", "cord"]),
                route("prostate", ["prostate"]),
                route("urinary_bladder", ["bladder", "urinary bladder"]),
                route("brain", ["brain"]),
                route("skull", ["skull"]),
                route("thyroid_gland", ["thyroid", "thyroid gland"]),
                route("esophagus", ["esophagus", "oesophagus"]),
                route("colon", ["colon", "large bowel"]),
                route("small_bowel", ["small bowel", "small intestine"])
            ],
            monaiKeywords: ["totalsegmentator", "total", "segmentator", "anatomy", "organ"],
            rationale: "Whole-body organ requests should start from a broad anatomy model and then refine the selected class."
        ),
        SegmentationModelCard(
            id: "rt-standard-targets",
            displayName: "Radiotherapy target and structure labels",
            presetName: "RT Standard",
            modalities: [.CT, .MR, .PT],
            preferredTool: .brush,
            aliases: [
                "radiotherapy", "radiation therapy", "rtstruct", "rt structure",
                "treatment planning", "gross tumor volume", "clinical target",
                "planning target", "contour gtv", "contour ctv", "contour ptv"
            ],
            labels: [
                route("GTV", ["gtv", "gross tumor", "gross tumour", "gross disease"]),
                route("GTV-N", ["gtv n", "gtv-n", "nodal gtv", "gross nodal", "node"]),
                route("CTV", ["ctv", "clinical target"]),
                route("CTV-N", ["ctv n", "ctv-n", "nodal ctv"]),
                route("ITV", ["itv", "internal target"]),
                route("PTV", ["ptv", "planning target"]),
                route("PTV-N", ["ptv n", "ptv-n", "nodal ptv"]),
                route("Boost", ["boost", "dose escalation"]),
                route("External", ["external", "body contour", "skin contour"])
            ],
            monaiKeywords: ["rt", "gtv", "ctv", "ptv", "oar", "radiotherapy"],
            rationale: "Radiotherapy contouring should use explicit target-volume semantics instead of generic lesion names."
        ),
        SegmentationModelCard(
            id: "head-neck-oars",
            displayName: "Head and neck organs at risk",
            presetName: "H&N OARs",
            modalities: [.CT, .MR],
            preferredTool: .brush,
            aliases: [
                "head neck oar", "head and neck oar", "hn oar", "parotid",
                "mandible", "larynx", "optic nerve", "optic chiasm", "cochlea",
                "oral cavity", "pharynx", "submandibular"
            ],
            labels: [
                route("Brainstem", ["brainstem", "brain stem"]),
                route("Spinal cord", ["spinal cord", "cord"]),
                route("Parotid left", ["left parotid", "parotid left"]),
                route("Parotid right", ["right parotid", "parotid right"]),
                route("Mandible", ["mandible", "jaw"]),
                route("Oral cavity", ["oral cavity", "mouth"]),
                route("Larynx", ["larynx"]),
                route("Optic chiasm", ["optic chiasm", "chiasm"]),
                route("Cochlea left", ["left cochlea", "cochlea left"]),
                route("Cochlea right", ["right cochlea", "cochlea right"])
            ],
            monaiKeywords: ["head", "neck", "oar", "parotid", "mandible"],
            rationale: "Head and neck OAR contouring needs a dedicated OAR taxonomy rather than generic anatomy labels."
        ),
        SegmentationModelCard(
            id: "brats-brain-tumor",
            displayName: "BraTS brain tumor MRI",
            presetName: "BraTS",
            modalities: [.MR],
            preferredTool: .brush,
            aliases: [
                "brats", "brain tumor", "glioma", "gbm", "glioblastoma",
                "enhancing tumor", "tumor core", "peritumoral edema", "edema"
            ],
            labels: [
                route("Edema (non-enhancing)", ["edema", "oedema", "flare abnormality", "flair"]),
                route("Non-enhancing tumor core", ["non enhancing", "non-enhancing", "tumor core"]),
                route("Enhancing tumor", ["enhancing tumor", "enhancement", "enhancing"]),
                route("Necrotic tumor core", ["necrosis", "necrotic"])
            ],
            monaiKeywords: ["brats", "brain", "glioma", "tumor", "mri"],
            rationale: "Glioma MRI requests should use BraTS-compatible tumor compartment labels."
        ),
        SegmentationModelCard(
            id: "liver-tumor-msd",
            displayName: "MSD liver and liver tumor",
            presetName: "MSD Liver",
            modalities: [.CT, .MR],
            preferredTool: .regionGrow,
            aliases: [
                "liver tumor", "hepatic tumor", "hcc", "hepatocellular",
                "hepatic lesion", "liver lesion", "liver metastasis", "cholangiocarcinoma"
            ],
            labels: [
                route("liver tumor", ["liver tumor", "hepatic tumor", "hcc", "hepatic lesion", "liver lesion", "cholangiocarcinoma"]),
                route("liver", ["liver", "hepatic parenchyma"])
            ],
            monaiKeywords: ["liver", "hepatic", "hcc", "tumor"],
            rationale: "Dedicated liver tumor labels are better when the disease process is hepatic malignancy or focal liver lesion."
        ),
        SegmentationModelCard(
            id: "lung-nodule-msd",
            displayName: "MSD lung nodule",
            presetName: "MSD Lung",
            modalities: [.CT],
            preferredTool: .regionGrow,
            aliases: ["lung nodule", "pulmonary nodule", "solitary pulmonary nodule", "spn"],
            labels: [
                route("lung nodule", ["lung nodule", "pulmonary nodule", "nodule", "spn"])
            ],
            monaiKeywords: ["lung", "nodule", "pulmonary"],
            rationale: "Small pulmonary lesions should use a lung nodule task rather than a whole-lung organ label."
        ),
        SegmentationModelCard(
            id: "pancreas-lesion-msd",
            displayName: "MSD pancreas and pancreatic lesion",
            presetName: "MSD Pancreas",
            modalities: [.CT, .MR],
            preferredTool: .regionGrow,
            aliases: ["pancreatic cancer", "pancreas cancer", "pancreatic lesion", "pancreas lesion"],
            labels: [
                route("pancreatic lesion", ["pancreatic lesion", "pancreas lesion", "pancreatic tumor", "pancreas tumor"]),
                route("pancreas", ["pancreas", "pancreatic parenchyma"])
            ],
            monaiKeywords: ["pancreas", "pancreatic", "lesion", "tumor"],
            rationale: "Pancreatic lesion tasks need both gland and lesion labels for review and correction."
        ),
        SegmentationModelCard(
            id: "prostate-mri",
            displayName: "Prostate zonal MRI",
            presetName: "Prostate Zonal MRI",
            modalities: [.MR],
            preferredTool: .brush,
            aliases: ["prostate mri", "pirads", "pi rads", "prostate cancer", "peripheral zone", "transition zone"],
            labels: [
                route("peripheral_zone", ["peripheral zone", "pz"]),
                route("transition_zone", ["transition zone", "tz"]),
                route("tumor_pirads5", ["pirads 5", "pi rads 5", "high suspicion"]),
                route("tumor_pirads4", ["pirads 4", "pi rads 4"]),
                route("tumor_pirads3", ["pirads 3", "pi rads 3"])
            ],
            monaiKeywords: ["prostate", "pirads", "mri", "zonal"],
            rationale: "Prostate MRI labeling should preserve zonal anatomy and PI-RADS lesion classes."
        ),
        SegmentationModelCard(
            id: "spine-vertebrae",
            displayName: "Spine vertebrae",
            presetName: "Spine Vertebrae",
            modalities: [.CT, .MR],
            preferredTool: .regionGrow,
            aliases: ["vertebra", "vertebrae", "spine", "cervical spine", "thoracic spine", "lumbar spine"],
            labels: [
                route("C1", ["c1", "atlas"]),
                route("C2", ["c2", "axis"]),
                route("T1", ["t1"]),
                route("T12", ["t12"]),
                route("L1", ["l1"]),
                route("L5", ["l5"])
            ],
            monaiKeywords: ["spine", "vertebra", "vertebrae"],
            rationale: "Spine work benefits from vertebra-level labels so later measurements and review stay unambiguous."
        )
    ]

    public static var allModelCards: [SegmentationModelCard] {
        modelCards + nnunetModelCards
    }

    public static var nnunetModelCards: [SegmentationModelCard] {
        NNUnetCatalog.all.map { entry in
            let labels = labelRoutes(for: entry)
            let aliases = nnunetAliases(for: entry, labels: labels)
            return SegmentationModelCard(
                id: "nnunet-\(entry.id)",
                displayName: "nnU-Net · \(entry.displayName)",
                presetName: localPresetName(for: entry),
                modalities: [entry.modality],
                preferredTool: entry.multiChannel ? .brush : .regionGrow,
                aliases: aliases,
                labels: labels,
                monaiKeywords: aliases,
                preferredEngine: .nnUNet,
                nnunetEntryID: entry.id,
                rationale: "Use the executable nnU-Net \(entry.datasetID) model when the request matches \(entry.bodyRegion.lowercased()) \(entry.modality.displayName) labels."
            )
        }
    }

    public static func plan(for prompt: String,
                            currentModality: Modality? = nil,
                            availableMONAIModels: [String] = []) -> SegmentationRAGPlan? {
        let text = normalize(prompt)
        guard hasSegmentationRoutingIntent(text) else { return nil }

        var best: (card: SegmentationModelCard, label: SegmentationLabelRoute, score: Int, evidence: [String])?
        let modelIntent = text.containsAny(["nnunet", "nn u net", "deep learning", "ai model", "model", "inference", "auto segment", "auto-segment", "run segmentation", "best model"])
        let diseaseIntent = text.containsAny(["tumor", "tumour", "lesion", "mass", "nodule", "cancer", "metastasis", "metastases", "glioma", "hcc"])
        let rtIntent = text.containsAny(["radiotherapy", "radiation therapy", "rtstruct", "rt structure", "gtv", "ctv", "ptv", "gross tumor volume", "clinical target", "planning target", "oar"])

        for card in allModelCards {
            var score = 0
            var evidence: [String] = []

            let cardMatches = matchingTerms(in: text, candidates: card.aliases)
            score += cardMatches.count * 4
            evidence.append(contentsOf: cardMatches)

            if let currentModality {
                if card.modalities.contains(currentModality) {
                    score += 2
                    evidence.append(currentModality.displayName)
                } else if currentModality != .OT {
                    score -= 1
                }
            }

            score += modalityTextScore(text: text, card: card, evidence: &evidence)

            var bestLabel = card.labels.first ?? route("Label 1", ["label"])
            var bestLabelScore = 0
            for label in card.labels {
                let labelMatches = matchingTerms(in: text, candidates: [label.labelName] + label.aliases)
                let labelScore = labelMatches.count * 6
                if labelScore > bestLabelScore {
                    bestLabel = label
                    bestLabelScore = labelScore
                }
            }
            score += bestLabelScore
            evidence.append(contentsOf: matchingTerms(in: text, candidates: [bestLabel.labelName] + bestLabel.aliases))

            if bestAvailableMONAIModel(for: card, availableModels: availableMONAIModels) != nil {
                score += 3
                evidence.append("MONAI server model match")
            }

            if card.id == "rt-standard-targets", rtIntent {
                score += 12
                evidence.append("RT contouring semantics")
            }

            if card.preferredEngine == .nnUNet {
                if modelIntent {
                    score += 7
                    evidence.append("model request")
                } else if !diseaseIntent {
                    score -= 5
                }
                if rtIntent {
                    score -= 8
                }
                if card.nnunetEntryID != nil, !card.labels.isEmpty {
                    score += 1
                }
            } else if modelIntent {
                score -= 2
            }

            if score > (best?.score ?? Int.min) {
                best = (card, bestLabel, score, Array(NSOrderedSet(array: evidence)) as? [String] ?? evidence)
            }
        }

        guard let best, best.score >= 6 else { return nil }
        let matchedMONAI = bestAvailableMONAIModel(for: best.card, availableModels: availableMONAIModels)
        let nnunetEntry = best.card.nnunetEntryID.flatMap(NNUnetCatalog.byID)
        let confidence = min(0.98, max(0.35, 0.35 + Double(best.score) / 24.0))

        return SegmentationRAGPlan(
            diseaseProcess: diseaseSummary(from: text, evidence: best.evidence),
            requestedTarget: best.label.labelName,
            modelName: best.card.displayName,
            presetName: best.card.presetName,
            labelName: best.label.labelName,
            tool: best.card.preferredTool,
            confidence: confidence,
            rationale: best.card.rationale,
            evidence: best.evidence,
            monaiModelKeywords: best.card.monaiKeywords,
            matchedMONAIModel: matchedMONAI,
            preferredEngine: best.card.preferredEngine,
            nnunetEntryID: best.card.nnunetEntryID,
            nnunetDatasetID: nnunetEntry?.datasetID,
            nnunetDisplayName: nnunetEntry?.displayName,
            nnunetMultiChannel: nnunetEntry?.multiChannel ?? false
        )
    }

    public static func assistantContext(for prompt: String,
                                        currentModality: Modality?,
                                        availableMONAIModels: [String]) -> String {
        var lines: [String] = ["Segmentation RAG routing:"]
        if let plan = plan(for: prompt,
                           currentModality: currentModality,
                           availableMONAIModels: availableMONAIModels) {
            lines.append(plan.summary)
            lines.append("Rationale: \(plan.rationale)")
            if !plan.evidence.isEmpty {
                lines.append("Matched terms: \(plan.evidence.joined(separator: ", "))")
            }
            if let nnunetDatasetID = plan.nnunetDatasetID {
                lines.append("Selected nnU-Net dataset: \(nnunetDatasetID). Multi-channel: \(plan.nnunetMultiChannel ? "yes" : "no").")
            }
            lines.append("Use this route for labels/model selection. Do not invent unavailable MONAI models or nnU-Net datasets.")
        } else {
            lines.append("No segmentation route was selected for this request.")
        }
        if !availableMONAIModels.isEmpty {
            lines.append("Available MONAI Label models: \(availableMONAIModels.sorted().joined(separator: ", "))")
        }
        lines.append("Executable nnU-Net routes: \(NNUnetCatalog.all.map { "\($0.id)=\($0.datasetID)" }.joined(separator: "; "))")
        lines.append("Local label routes: \(modelCards.map { $0.displayName }.joined(separator: "; "))")
        return lines.joined(separator: "\n")
    }

    public static func bestAvailableMONAIModel(for plan: SegmentationRAGPlan,
                                               availableModels: [String]) -> String? {
        bestAvailableMONAIModel(
            keywords: plan.monaiModelKeywords + [plan.presetName, plan.labelName, plan.modelName],
            availableModels: availableModels
        )
    }

    public static func bestAvailableMONAIModel(for card: SegmentationModelCard,
                                               availableModels: [String]) -> String? {
        bestAvailableMONAIModel(
            keywords: card.monaiKeywords + [card.presetName, card.displayName],
            availableModels: availableModels
        )
    }

    private static func bestAvailableMONAIModel(keywords: [String],
                                                availableModels: [String]) -> String? {
        var bestName: String?
        var bestScore = 0
        let normalizedKeywords = keywords.map(normalize).filter { !$0.isEmpty }

        for name in availableModels {
            let n = normalize(name)
            var score = 0
            for keyword in normalizedKeywords {
                if containsPhrase(n, keyword) || containsPhrase(keyword, n) {
                    score += keyword.count <= 3 ? 1 : 3
                }
            }
            if score > bestScore {
                bestScore = score
                bestName = name
            }
        }
        return bestScore > 0 ? bestName : nil
    }

    private static func route(_ labelName: String, _ aliases: [String]) -> SegmentationLabelRoute {
        SegmentationLabelRoute(labelName: labelName, aliases: aliases)
    }

    private static func labelRoutes(for entry: NNUnetCatalog.Entry) -> [SegmentationLabelRoute] {
        entry.classes
            .sorted { $0.key < $1.key }
            .map { _, rawName in
                let localName = localLabelName(for: rawName, entry: entry)
                return route(localName, Array(NSOrderedSet(array: [
                    rawName,
                    humanized(rawName),
                    localName,
                    humanized(localName)
                ] + labelAliases(for: rawName, entry: entry))) as? [String] ?? [rawName, localName])
            }
    }

    private static func nnunetAliases(for entry: NNUnetCatalog.Entry,
                                      labels: [SegmentationLabelRoute]) -> [String] {
        var aliases = [
            entry.id,
            entry.datasetID,
            entry.displayName,
            entry.description,
            entry.bodyRegion,
            "nnunet",
            "nn u net",
            "nnU-Net",
            "deep learning segmentation",
            "ai segmentation model"
        ]
        aliases.append(contentsOf: entry.displayName.components(separatedBy: CharacterSet(charactersIn: "—()+")).map(humanized))
        aliases.append(contentsOf: labels.flatMap { [$0.labelName] + $0.aliases })
        aliases.append(contentsOf: entry.notes.components(separatedBy: CharacterSet(charactersIn: ".;,/()")).map(humanized))
        return Array(NSOrderedSet(array: aliases.map(normalize).filter { !$0.isEmpty })) as? [String] ?? aliases
    }

    private static func localPresetName(for entry: NNUnetCatalog.Entry) -> String {
        switch entry.id {
        case "MSD-Liver": return "MSD Liver"
        case "MSD-Pancreas": return "MSD Pancreas"
        case "MSD-Lung": return "MSD Lung"
        case "MSD-Prostate": return "MSD Prostate"
        case "MSD-Heart": return "Cardiac Cine MRI"
        case "MSD-Spleen", "TotalSegmentatorCT": return "TotalSegmentator"
        case "AMOS22": return "AMOS"
        case "BraTS-GLI": return "BraTS"
        case "KiTS23": return "TotalSegmentator"
        case "MSD-Colon", "MSD-HepaticVessel": return "Oncology (Clinical)"
        default: return "Oncology (Clinical)"
        }
    }

    private static func localLabelName(for rawName: String,
                                       entry: NNUnetCatalog.Entry) -> String {
        let name = normalize(rawName)
        switch name {
        case "liver tumor": return "liver tumor"
        case "lung tumor": return "lung nodule"
        case "pancreatic mass": return "pancreatic lesion"
        case "colon cancer": return "Primary tumor"
        case "edema": return "Edema (non-enhancing)"
        case "non enhancing core": return "Non-enhancing tumor core"
        case "enhancing tumor": return "Enhancing tumor"
        case "left atrium": return "left_atrium"
        case "peripheral zone": return "peripheral zone"
        case "central gland": return "central gland"
        case "prostate or uterus": return "prostate/uterus"
        default:
            return rawName
        }
    }

    private static func labelAliases(for rawName: String,
                                     entry: NNUnetCatalog.Entry) -> [String] {
        let name = normalize(rawName)
        var aliases: [String] = []
        if name.contains("tumor") || name.contains("cancer") || name.contains("mass") {
            aliases.append(contentsOf: ["tumor", "tumour", "mass", "lesion", "cancer", "malignancy"])
        }
        if name.contains("nodule") || entry.id == "MSD-Lung" {
            aliases.append(contentsOf: ["lung nodule", "pulmonary nodule", "spn"])
        }
        if name.contains("liver") {
            aliases.append(contentsOf: ["liver", "hepatic", "hcc", "hepatocellular"])
        }
        if name.contains("pancre") {
            aliases.append(contentsOf: ["pancreas", "pancreatic", "pancreatic mass", "pancreatic lesion"])
        }
        if name.contains("kidney") || entry.id == "KiTS23" {
            aliases.append(contentsOf: ["kidney", "renal", "renal mass", "kidney tumor", "kidney cyst"])
        }
        if name.contains("edema") {
            aliases.append(contentsOf: ["edema", "oedema", "flair", "peritumoral edema"])
        }
        if entry.id == "BraTS-GLI" {
            aliases.append(contentsOf: ["brats", "glioma", "glioblastoma", "brain tumor", "gbm"])
        }
        return aliases
    }

    private static func humanized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasSegmentationRoutingIntent(_ text: String) -> Bool {
        let words = Set(text.split(separator: " ").map(String.init))
        let strongIntent = words.contains("segment")
            || words.contains("segmentation")
            || words.contains("contour")
            || words.contains("contouring")
            || words.contains("delineate")
            || words.contains("mask")
            || words.contains("model")
            || text.contains("auto segment")
            || text.contains("auto-segment")

        let diseaseTerms = [
            "tumor", "tumour", "lesion", "metastasis", "metastases", "lymphoma",
            "gtv", "ctv", "ptv", "oar", "cancer", "glioma", "nodule", "hcc"
        ]
        let diseaseIntent = text.containsAny(diseaseTerms)
            && text.containsAny(["label", "labels", "choose", "route", "segment", "contour", "model"])

        let organIntent = text.containsAny(["organ", "anatomy", "oar"])
            && text.containsAny(["segment", "contour", "model", "label"])

        return strongIntent || diseaseIntent || organIntent
    }

    private static func modalityTextScore(text: String,
                                          card: SegmentationModelCard,
                                          evidence: inout [String]) -> Int {
        var score = 0
        if text.containsAny(["pet", "fdg", "suv", "pet ct", "pet/ct"]) {
            if card.modalities.contains(.PT) {
                score += 5
                evidence.append("PET")
            } else {
                score -= 2
            }
        }
        if text.containsAny(["ct", "computed tomography"]) && card.modalities.contains(.CT) {
            score += 2
            evidence.append("CT")
        }
        if text.containsAny(["mri", "mr ", "magnetic resonance"]) && card.modalities.contains(.MR) {
            score += 3
            evidence.append("MRI")
        }
        return score
    }

    private static func diseaseSummary(from text: String, evidence: [String]) -> String {
        let diseaseTerms = evidence.filter {
            let n = normalize($0)
            return n.containsAny(["tumor", "tumour", "lesion", "metast", "lymphoma", "cancer", "glioma", "nodule", "hcc", "infection", "inflammation"])
        }
        if let first = diseaseTerms.first {
            return first
        }
        if text.containsAny(["organ", "anatomy"]) {
            return "anatomy"
        }
        return "segmentation target"
    }

    private static func matchingTerms(in text: String, candidates: [String]) -> [String] {
        candidates.filter { containsPhrase(text, $0) }
    }

    private static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        let normalizedPhrase = normalize(phrase)
        guard !normalizedPhrase.isEmpty else { return false }
        if normalizedPhrase.count <= 3 {
            return text.split(separator: " ").contains(Substring(normalizedPhrase))
        }
        return text.contains(normalizedPhrase)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }
}

private extension String {
    func containsAny(_ needles: [String]) -> Bool {
        needles.contains { contains($0) }
    }
}
