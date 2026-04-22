import Foundation

/// Curated catalog of public **nnU-Net v2** datasets and model shortcuts.
///
/// These map to pre-trained checkpoints users can download from the nnU-Net
/// Model Zoo and install under `$nnUNet_results`:
///
/// ```
/// nnUNetv2_download_pretrained_model_by_name Dataset003_Liver
/// ```
///
/// Selecting an entry here preconfigures the runner with the right
/// `datasetID`, preferred configuration (e.g. `3d_fullres` vs `2d`), and a
/// hint about the expected modality/body region so the UI can warn when
/// the currently-open volume looks like the wrong modality for the model.
public enum NNUnetCatalog {

    /// How a model expects its input intensities to be normalized. nnU-Net's
    /// preprocessing step performs this before inference; when running our
    /// own CoreML path we have to match it or the outputs will be garbage.
    public enum IntensityPreprocessing: Hashable, Sendable {
        /// CT-style: clip to (lower, upper) HU, then Z-score with dataset
        /// mean and std. Typical values: lower=-1000, upper=400.
        case ctClipAndZScore(lower: Float, upper: Float, mean: Float, std: Float)
        /// MR-style: Z-score over non-zero foreground voxels.
        case zScoreNonzero
        /// PET-style: scale by SUV factor (if present), clip to (0, cap), Z-score.
        case petSUV(cap: Float)
        /// No preprocessing — user's volume is already in the right range.
        case identity
    }

    /// CoreML runtime defaults for a given dataset. Used when the user picks
    /// a `.mlpackage` exported from this model so the UI/runner don't have to
    /// ask for patch-size + num-classes manually.
    public struct CoreMLPreset: Hashable, Sendable {
        public var patchSize: (d: Int, h: Int, w: Int)
        public var numClasses: Int
        public var inputName: String
        public var outputName: String
        public var overlap: Double

        public init(patchSize: (d: Int, h: Int, w: Int),
                    numClasses: Int,
                    inputName: String = "input",
                    outputName: String = "logits",
                    overlap: Double = 0.25) {
            self.patchSize = patchSize
            self.numClasses = numClasses
            self.inputName = inputName
            self.outputName = outputName
            self.overlap = overlap
        }

        public static func == (lhs: CoreMLPreset, rhs: CoreMLPreset) -> Bool {
            lhs.patchSize == rhs.patchSize
                && lhs.numClasses == rhs.numClasses
                && lhs.inputName == rhs.inputName
                && lhs.outputName == rhs.outputName
                && lhs.overlap == rhs.overlap
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(patchSize.d); hasher.combine(patchSize.h); hasher.combine(patchSize.w)
            hasher.combine(numClasses); hasher.combine(inputName)
            hasher.combine(outputName); hasher.combine(overlap)
        }
    }

    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: String
        public let datasetID: String
        public let displayName: String
        public let modality: Modality
        public let bodyRegion: String
        public let description: String
        public let configuration: String
        public let folds: [String]
        public let classes: [UInt16: String]
        /// True = expects multiple input channels (e.g. PET + CT, or multi-
        /// sequence MRI). The subprocess runner handles multi-channel input
        /// when the caller supplies `auxiliaryChannels`; the CoreML runner is
        /// single-channel only.
        public let multiChannel: Bool
        /// Total number of input channels the model expects (including
        /// channel 0). Ignored when `multiChannel` is false.
        public let requiredChannels: Int
        /// Human-readable hint per channel index — e.g.
        /// `["CT", "PET SUV"]` for AutoPET II. Displayed in the channel
        /// picker so users know which series to route where.
        public let channelDescriptions: [String]
        /// Notes shown in the UI — modality expectations, checkpoint cost, etc.
        public let notes: String
        /// Intensity normalization that matches nnU-Net's published preprocessing
        /// for this dataset. Applied automatically before CoreML inference.
        public var preprocessing: IntensityPreprocessing = .zScoreNonzero
        /// CoreML runtime parameters for a `.mlpackage` exported from this model.
        /// Used to skip manual patch-size entry when picking a CoreML file.
        public var coreML: CoreMLPreset = CoreMLPreset(
            patchSize: (d: 96, h: 160, w: 160),
            numClasses: 2
        )

        public init(id: String, datasetID: String, displayName: String,
                    modality: Modality, bodyRegion: String, description: String,
                    configuration: String, folds: [String],
                    classes: [UInt16: String], multiChannel: Bool, notes: String,
                    preprocessing: IntensityPreprocessing = .zScoreNonzero,
                    coreML: CoreMLPreset? = nil,
                    requiredChannels: Int = 1,
                    channelDescriptions: [String] = []) {
            self.id = id
            self.datasetID = datasetID
            self.displayName = displayName
            self.modality = modality
            self.bodyRegion = bodyRegion
            self.description = description
            self.configuration = configuration
            self.folds = folds
            self.classes = classes
            self.multiChannel = multiChannel
            self.notes = notes
            self.preprocessing = preprocessing
            let coreMLClasses = (classes.keys.max().map(Int.init) ?? 0) + 1
            self.coreML = coreML ?? CoreMLPreset(
                patchSize: (d: 96, h: 160, w: 160),
                numClasses: max(2, coreMLClasses)
            )
            self.requiredChannels = max(1, multiChannel ? requiredChannels : 1)
            self.channelDescriptions = channelDescriptions
        }
    }

    public static let all: [Entry] = [
        msdLiver,
        msdPancreas,
        msdLung,
        msdProstate,
        msdColon,
        msdHeart,
        msdHepaticVessel,
        msdSpleen,
        kits23Kidney,
        amos22Abdomen,
        totalSegmentatorCT,
        bratsGlioma,
        autoPETII,
        lesionTracer,
        lesionLocator,
    ]

    public static func byID(_ id: String) -> Entry? {
        all.first { $0.id == id || $0.datasetID == id }
    }

    // MARK: - Medical Segmentation Decathlon

    public static let msdLiver = Entry(
        id: "MSD-Liver",
        datasetID: "Dataset003_Liver",
        displayName: "Liver + Tumor (MSD Task03)",
        modality: .CT,
        bodyRegion: "Abdomen",
        description: "Binary liver + liver-tumor segmentation on portal-venous CT.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "liver", 2: "liver_tumor"],
        multiChannel: false,
        notes: "Portal-venous CT expected. Full 5-fold ensemble gives best Dice but is ~5× slower.",
        preprocessing: .ctClipAndZScore(lower: -17, upper: 201, mean: 99.4, std: 39.4),
        coreML: CoreMLPreset(patchSize: (d: 128, h: 128, w: 128), numClasses: 3)
    )

    public static let msdPancreas = Entry(
        id: "MSD-Pancreas",
        datasetID: "Dataset007_Pancreas",
        displayName: "Pancreas + Mass (MSD Task07)",
        modality: .CT,
        bodyRegion: "Abdomen",
        description: "Pancreas and pancreatic cystic/solid mass segmentation on portal-venous CT.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "pancreas", 2: "pancreatic_mass"],
        multiChannel: false,
        notes: "Challenging small-organ task; use 3d_fullres for best accuracy.",
        preprocessing: .ctClipAndZScore(lower: -96, upper: 215, mean: 77.99, std: 75.40),
        coreML: CoreMLPreset(patchSize: (d: 64, h: 192, w: 192), numClasses: 3)
    )

    public static let msdLung = Entry(
        id: "MSD-Lung",
        datasetID: "Dataset006_Lung",
        displayName: "Lung Nodules (MSD Task06)",
        modality: .CT,
        bodyRegion: "Thorax",
        description: "Primary lung tumor/nodule segmentation on contrast-enhanced CT.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "lung_tumor"],
        multiChannel: false,
        notes: "Binary mask only — class 1 = nodule.",
        preprocessing: .ctClipAndZScore(lower: -1024, upper: 325, mean: -158.58, std: 324.7),
        coreML: CoreMLPreset(patchSize: (d: 80, h: 192, w: 160), numClasses: 2)
    )

    public static let msdProstate = Entry(
        id: "MSD-Prostate",
        datasetID: "Dataset005_Prostate",
        displayName: "Prostate Zones (MSD Task05)",
        modality: .MR,
        bodyRegion: "Pelvis",
        description: "Prostate peripheral and central gland segmentation on T2 + ADC MRI.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "peripheral_zone", 2: "central_gland"],
        multiChannel: true,
        notes: "Requires T2 + ADC as two channels — multi-channel export not yet wired; use single T2 at your own risk.",
        preprocessing: .zScoreNonzero,
        coreML: CoreMLPreset(patchSize: (d: 20, h: 320, w: 256), numClasses: 3)
    )

    public static let msdColon = Entry(
        id: "MSD-Colon",
        datasetID: "Dataset010_Colon",
        displayName: "Colon Cancer (MSD Task10)",
        modality: .CT,
        bodyRegion: "Abdomen",
        description: "Primary colon tumor segmentation on portal-venous CT.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "colon_cancer"],
        multiChannel: false,
        notes: "Binary colon-cancer mask.",
        preprocessing: .ctClipAndZScore(lower: -30, upper: 165.8, mean: 62.18, std: 32.54),
        coreML: CoreMLPreset(patchSize: (d: 56, h: 192, w: 160), numClasses: 2)
    )

    public static let msdHeart = Entry(
        id: "MSD-Heart",
        datasetID: "Dataset002_Heart",
        displayName: "Left Atrium (MSD Task02)",
        modality: .MR,
        bodyRegion: "Thorax",
        description: "Left atrium segmentation on cine MRI.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "left_atrium"],
        multiChannel: false,
        notes: "Cine-MRI single-phase volume.",
        preprocessing: .zScoreNonzero,
        coreML: CoreMLPreset(patchSize: (d: 80, h: 192, w: 160), numClasses: 2)
    )

    public static let msdHepaticVessel = Entry(
        id: "MSD-HepaticVessel",
        datasetID: "Dataset008_HepaticVessel",
        displayName: "Hepatic Vessels + Tumors (MSD Task08)",
        modality: .CT,
        bodyRegion: "Abdomen",
        description: "Portal vessels and liver tumors on CT.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "hepatic_vessel", 2: "liver_tumor"],
        multiChannel: false,
        notes: "Portal-venous phase CT.",
        preprocessing: .ctClipAndZScore(lower: -3, upper: 243, mean: 104.4, std: 52.6),
        coreML: CoreMLPreset(patchSize: (d: 64, h: 192, w: 192), numClasses: 3)
    )

    public static let msdSpleen = Entry(
        id: "MSD-Spleen",
        datasetID: "Dataset009_Spleen",
        displayName: "Spleen (MSD Task09)",
        modality: .CT,
        bodyRegion: "Abdomen",
        description: "Spleen segmentation on portal-venous CT.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "spleen"],
        multiChannel: false,
        notes: "Small dataset; single fold usually sufficient.",
        preprocessing: .ctClipAndZScore(lower: -41, upper: 176, mean: 99.3, std: 39.5),
        coreML: CoreMLPreset(patchSize: (d: 64, h: 192, w: 160), numClasses: 2)
    )

    // MARK: - KiTS 2023

    public static let kits23Kidney = Entry(
        id: "KiTS23",
        datasetID: "Dataset220_KiTS2023",
        displayName: "Kidney + Tumor + Cyst (KiTS23)",
        modality: .CT,
        bodyRegion: "Abdomen",
        description: "Kidney, kidney tumor, and cyst segmentation — KiTS23 challenge winner.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "kidney", 2: "tumor", 3: "cyst"],
        multiChannel: false,
        notes: "Arterial or portal-venous CT expected.",
        preprocessing: .ctClipAndZScore(lower: -54, upper: 258, mean: 100.0, std: 57.4),
        coreML: CoreMLPreset(patchSize: (d: 128, h: 128, w: 128), numClasses: 4)
    )

    // MARK: - AMOS 2022

    public static let amos22Abdomen = Entry(
        id: "AMOS22",
        datasetID: "Dataset218_Amos2022_task1",
        displayName: "AMOS22 — 15 Abdominal Organs",
        modality: .CT,
        bodyRegion: "Abdomen",
        description: "Joint segmentation of 15 abdominal organs on multi-center CT.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [
            1: "spleen", 2: "right_kidney", 3: "left_kidney", 4: "gallbladder",
            5: "esophagus", 6: "liver", 7: "stomach", 8: "aorta",
            9: "inferior_vena_cava", 10: "pancreas", 11: "right_adrenal_gland",
            12: "left_adrenal_gland", 13: "duodenum", 14: "bladder",
            15: "prostate_or_uterus",
        ],
        multiChannel: false,
        notes: "Use 3d_fullres; good target for whole-abdomen QA.",
        preprocessing: .ctClipAndZScore(lower: -991, upper: 362, mean: 50.0, std: 141.0),
        coreML: CoreMLPreset(patchSize: (d: 128, h: 128, w: 128), numClasses: 16)
    )

    // MARK: - TotalSegmentator (nnU-Net backbone)

    public static let totalSegmentatorCT = Entry(
        id: "TotalSegmentatorCT",
        datasetID: "Dataset291_TotalSegmentator_part1_organs",
        displayName: "TotalSegmentator CT — Organs",
        modality: .CT,
        bodyRegion: "Whole Body",
        description: "Subset of TotalSegmentator's 104-class body model (organs portion).",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: LabelPresets.totalSegmentator.classes
            .reduce(into: [UInt16: String]()) { acc, cls in
                acc[cls.labelID] = cls.name
            },
        multiChannel: false,
        notes: "TotalSegmentator ships multiple dataset partitions (organs / bones / ribs …) — run them in sequence and merge label maps.",
        preprocessing: .ctClipAndZScore(lower: -1024, upper: 1024, mean: -350.0, std: 500.0),
        coreML: CoreMLPreset(patchSize: (d: 112, h: 160, w: 128),
                             numClasses: 25)
    )

    // MARK: - BraTS

    // MARK: - PET / PET-CT (autoPET family)

    /// **AutoPET II (2023) — Isensee et al.** Apache-2.0.
    /// Baseline nnU-Net v2 checkpoint for whole-body FDG-PET/CT lesion
    /// segmentation. Two channels: CT (channel 0, HU) and PET (channel 1,
    /// SUV-scaled). Weights on Zenodo 8362371.
    ///
    /// Source: https://github.com/MIC-DKFZ/nnUNet/blob/master/documentation/competitions/AutoPETII.md
    public static let autoPETII = Entry(
        id: "AutoPET-II-2023",
        datasetID: "Dataset221_AutoPETII_2023",
        displayName: "AutoPET II FDG Lesions (2-ch CT+PET)",
        modality: .PT,
        bodyRegion: "Whole Body",
        description: "Binary FDG-avid lesion segmentation on whole-body PET/CT; nnU-Net v2 ResEnc, Apache-2.0.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "fdg_avid_lesion"],
        multiChannel: true,
        notes: "Channel 0 = CT (HU). Channel 1 = PET (SUV-scaled). Both volumes must share a common grid — resample before running.",
        preprocessing: .petSUV(cap: 25),
        coreML: CoreMLPreset(patchSize: (d: 112, h: 160, w: 128), numClasses: 2),
        requiredChannels: 2,
        channelDescriptions: ["CT (HU)", "PET (SUV)"]
    )

    /// **LesionTracer — AutoPET III 2024 winner (MIC-DKFZ).**
    /// Multi-tracer (FDG + PSMA) whole-body lesion segmentation. Dice 0.6840
    /// on the AutoPET III leaderboard vs. 0.5761 baseline. Code Apache-2.0,
    /// weights CC-BY-4.0 (commercial OK with attribution). 26.7 GB.
    ///
    /// Paper: https://arxiv.org/abs/2409.09478
    /// Repo:  https://github.com/MIC-DKFZ/autopet-3-submission
    /// Weights: https://zenodo.org/records/13786235 + 14007247
    public static let lesionTracer = Entry(
        id: "LesionTracer-AutoPETIII",
        datasetID: "Dataset200_autoPET3_lesions",
        displayName: "LesionTracer — AutoPET III Winner (FDG + PSMA)",
        modality: .PT,
        bodyRegion: "Whole Body",
        description: "Multi-tracer whole-body PET/CT lesion segmentation — AutoPET III 2024 winner; nnU-Net ResEncL with MultiTalent pretraining.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "pet_lesion"],
        multiChannel: true,
        notes: "Handles both FDG and PSMA tracers. Large checkpoint (~26.7 GB). Weights CC-BY-4.0 — cite Isensee et al. 2024 when publishing results.",
        preprocessing: .petSUV(cap: 30),
        coreML: CoreMLPreset(patchSize: (d: 192, h: 192, w: 192), numClasses: 2),
        requiredChannels: 2,
        channelDescriptions: ["CT (HU)", "PET (SUV)"]
    )

    /// **LesionLocator — AutoPET IV 2025 (interactive).** Apache-2.0.
    /// Click-prompted refinement of LesionTracer: user provides foreground
    /// and background clicks; the model updates the lesion mask. Wired as a
    /// catalog entry for discovery; Swift-side click prompting is stubbed
    /// via the panel's "interactive" mode and will route the subprocess
    /// through the autopet-interactive CLI once weights are public.
    ///
    /// Repo: https://github.com/MIC-DKFZ/autoPET-interactive
    public static let lesionLocator = Entry(
        id: "LesionLocator-AutoPETIV",
        datasetID: "Dataset210_autoPET4_interactive",
        displayName: "LesionLocator — AutoPET IV Interactive (experimental)",
        modality: .PT,
        bodyRegion: "Whole Body",
        description: "Interactive click-prompt refinement of PET/CT lesion masks. Still early; route through the nnU-Net subprocess runner with click tensors when weights ship.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "pet_lesion"],
        multiChannel: true,
        notes: "Experimental: AutoPET IV interactive track. Needs the user to mark foreground / background points on a slice; integration via the PET Engine panel's interactive mode.",
        preprocessing: .petSUV(cap: 30),
        coreML: CoreMLPreset(patchSize: (d: 192, h: 192, w: 192), numClasses: 2),
        requiredChannels: 2,
        channelDescriptions: ["CT (HU)", "PET (SUV)"]
    )

    public static let bratsGlioma = Entry(
        id: "BraTS-GLI",
        datasetID: "Dataset137_BraTS2021",
        displayName: "BraTS Glioma (T1+T1c+T2+FLAIR)",
        modality: .MR,
        bodyRegion: "Brain",
        description: "Multi-parametric MRI glioma segmentation: edema, non-enhancing core, enhancing tumor.",
        configuration: "3d_fullres",
        folds: ["0"],
        classes: [1: "edema", 2: "non_enhancing_core", 3: "enhancing_tumor"],
        multiChannel: true,
        notes: "Requires 4 channels (T1, T1c, T2, FLAIR). Multi-channel export not yet wired.",
        preprocessing: .zScoreNonzero,
        coreML: CoreMLPreset(patchSize: (d: 128, h: 128, w: 128), numClasses: 4)
    )
}
