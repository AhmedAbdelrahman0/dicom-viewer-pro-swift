import Foundation
import SwiftUI

/// Predefined label sets for common medical imaging tasks.
///
/// Sources:
/// - **TotalSegmentator v2** (104 anatomical structures, Wasserthal et al. 2023)
/// - **BraTS** (Brain Tumor Segmentation Challenge — whole tumor, core, enhancing)
/// - **AutoPET** (FDG-PET/CT lesion segmentation)
/// - **AMOS** (15 abdominal organs)
/// - **MSD** (Medical Segmentation Decathlon — per-task labels)
/// - **RT Structures** (ICRU 50/62/83 target volumes and organs-at-risk)
/// - **FreeSurfer** (Desikan-Killiany cortical parcellation)
public enum LabelPresets {

    // MARK: - Preset library registry

    public static let all: [LabelPresetSet] = {
        var presets: [LabelPresetSet] = [
            totalSegmentator,
            autoPET,
            brats,
            amos,
            msdLiver,
            msdLung,
            msdPancreas,
            msdProstate,
            rtStructures,
            petFocal,
            oncologyClinical,
            freesurferLobes,
            head_neck_OARs,
            thorax_OARs,
            abdominal_OARs,
            pelvic_OARs,
            spineVertebrae,
        ]
        AnatomicalLabelPresets.register(into: &presets)
        return presets
    }()

    public static func byName(_ name: String) -> LabelPresetSet? {
        all.first { $0.name == name }
    }

    // MARK: - TotalSegmentator (104 classes — full anatomy)

    public static let totalSegmentator: LabelPresetSet = {
        // Color palette based on TotalSegmentator's official colormap
        func c(_ r: Int, _ g: Int, _ b: Int) -> Color { Color(r: r, g: g, b: b) }

        let classes: [LabelClass] = [
            // Organs
            LabelClass(labelID: 1,  name: "spleen",                 category: .organ,  color: c(255, 105,  97)),
            LabelClass(labelID: 2,  name: "kidney_right",           category: .organ,  color: c(139,  69,  19)),
            LabelClass(labelID: 3,  name: "kidney_left",            category: .organ,  color: c(160,  82,  45)),
            LabelClass(labelID: 4,  name: "gallbladder",            category: .organ,  color: c( 95, 158, 160)),
            LabelClass(labelID: 5,  name: "liver",                  category: .organ,  color: c(139,  26,  26)),
            LabelClass(labelID: 6,  name: "stomach",                category: .organ,  color: c(255, 182, 193)),
            LabelClass(labelID: 7,  name: "pancreas",               category: .organ,  color: c(218, 165,  32)),
            LabelClass(labelID: 8,  name: "adrenal_gland_right",    category: .organ,  color: c(255, 215,   0)),
            LabelClass(labelID: 9,  name: "adrenal_gland_left",     category: .organ,  color: c(255, 223, 128)),
            LabelClass(labelID: 10, name: "lung_upper_lobe_left",   category: .organ,  color: c(173, 216, 230)),
            LabelClass(labelID: 11, name: "lung_lower_lobe_left",   category: .organ,  color: c(135, 206, 235)),
            LabelClass(labelID: 12, name: "lung_upper_lobe_right",  category: .organ,  color: c(176, 224, 230)),
            LabelClass(labelID: 13, name: "lung_middle_lobe_right", category: .organ,  color: c(135, 206, 250)),
            LabelClass(labelID: 14, name: "lung_lower_lobe_right",  category: .organ,  color: c(100, 149, 237)),
            LabelClass(labelID: 15, name: "esophagus",              category: .organ,  color: c(255, 160, 122)),
            LabelClass(labelID: 16, name: "trachea",                category: .organ,  color: c(255, 255, 224)),
            LabelClass(labelID: 17, name: "thyroid_gland",          category: .organ,  color: c(255, 192, 203)),
            LabelClass(labelID: 18, name: "small_bowel",            category: .organ,  color: c(255, 228, 181)),
            LabelClass(labelID: 19, name: "duodenum",               category: .organ,  color: c(255, 218, 185)),
            LabelClass(labelID: 20, name: "colon",                  category: .organ,  color: c(245, 222, 179)),
            LabelClass(labelID: 21, name: "urinary_bladder",        category: .organ,  color: c(255, 250, 205)),
            LabelClass(labelID: 22, name: "prostate",               category: .organ,  color: c(255, 240, 245)),
            LabelClass(labelID: 23, name: "kidney_cyst_left",       category: .pathology, color: c(152, 251, 152)),
            LabelClass(labelID: 24, name: "kidney_cyst_right",      category: .pathology, color: c(144, 238, 144)),

            // Vertebrae
            LabelClass(labelID: 25, name: "sacrum",                 category: .bone,   color: c(255, 228, 196)),
            LabelClass(labelID: 26, name: "vertebrae_S1",           category: .bone,   color: c(250, 235, 215)),
            LabelClass(labelID: 27, name: "vertebrae_L5",           category: .bone,   color: c(245, 245, 220)),
            LabelClass(labelID: 28, name: "vertebrae_L4",           category: .bone,   color: c(255, 235, 205)),
            LabelClass(labelID: 29, name: "vertebrae_L3",           category: .bone,   color: c(255, 222, 173)),
            LabelClass(labelID: 30, name: "vertebrae_L2",           category: .bone,   color: c(255, 218, 185)),
            LabelClass(labelID: 31, name: "vertebrae_L1",           category: .bone,   color: c(255, 228, 181)),
            LabelClass(labelID: 32, name: "vertebrae_T12",          category: .bone,   color: c(255, 239, 213)),
            LabelClass(labelID: 33, name: "vertebrae_T11",          category: .bone,   color: c(255, 250, 205)),
            LabelClass(labelID: 34, name: "vertebrae_T10",          category: .bone,   color: c(255, 248, 220)),
            LabelClass(labelID: 35, name: "vertebrae_T9",           category: .bone,   color: c(255, 255, 240)),
            LabelClass(labelID: 36, name: "vertebrae_T8",           category: .bone,   color: c(253, 245, 230)),
            LabelClass(labelID: 37, name: "vertebrae_T7",           category: .bone,   color: c(250, 240, 230)),
            LabelClass(labelID: 38, name: "vertebrae_T6",           category: .bone,   color: c(255, 240, 245)),
            LabelClass(labelID: 39, name: "vertebrae_T5",           category: .bone,   color: c(248, 248, 255)),
            LabelClass(labelID: 40, name: "vertebrae_T4",           category: .bone,   color: c(240, 248, 255)),
            LabelClass(labelID: 41, name: "vertebrae_T3",           category: .bone,   color: c(240, 255, 255)),
            LabelClass(labelID: 42, name: "vertebrae_T2",           category: .bone,   color: c(245, 255, 250)),
            LabelClass(labelID: 43, name: "vertebrae_T1",           category: .bone,   color: c(240, 255, 240)),
            LabelClass(labelID: 44, name: "vertebrae_C7",           category: .bone,   color: c(255, 250, 240)),
            LabelClass(labelID: 45, name: "vertebrae_C6",           category: .bone,   color: c(250, 250, 210)),
            LabelClass(labelID: 46, name: "vertebrae_C5",           category: .bone,   color: c(255, 255, 224)),
            LabelClass(labelID: 47, name: "vertebrae_C4",           category: .bone,   color: c(255, 239, 213)),
            LabelClass(labelID: 48, name: "vertebrae_C3",           category: .bone,   color: c(255, 228, 196)),
            LabelClass(labelID: 49, name: "vertebrae_C2",           category: .bone,   color: c(255, 222, 173)),
            LabelClass(labelID: 50, name: "vertebrae_C1",           category: .bone,   color: c(255, 215,   0)),

            // Cardiac
            LabelClass(labelID: 51, name: "heart",                  category: .cardiac, color: c(178,  34,  34)),
            LabelClass(labelID: 52, name: "aorta",                  category: .vessel,  color: c(220,  20,  60)),
            LabelClass(labelID: 53, name: "pulmonary_vein",         category: .vessel,  color: c(205,  92,  92)),
            LabelClass(labelID: 54, name: "brachiocephalic_trunk",  category: .vessel,  color: c(240, 128, 128)),
            LabelClass(labelID: 55, name: "subclavian_artery_right",category: .vessel,  color: c(250, 128, 114)),
            LabelClass(labelID: 56, name: "subclavian_artery_left", category: .vessel,  color: c(233, 150, 122)),
            LabelClass(labelID: 57, name: "common_carotid_artery_right", category: .vessel, color: c(255, 160, 122)),
            LabelClass(labelID: 58, name: "common_carotid_artery_left",  category: .vessel, color: c(255, 127,  80)),
            LabelClass(labelID: 59, name: "brachiocephalic_vein_left",   category: .vessel, color: c(255,  99,  71)),
            LabelClass(labelID: 60, name: "brachiocephalic_vein_right",  category: .vessel, color: c(255,  69,   0)),
            LabelClass(labelID: 61, name: "atrial_appendage_left",  category: .cardiac, color: c(139,   0,   0)),
            LabelClass(labelID: 62, name: "superior_vena_cava",     category: .vessel,  color: c(128,   0,   0)),
            LabelClass(labelID: 63, name: "inferior_vena_cava",     category: .vessel,  color: c(165,  42,  42)),
            LabelClass(labelID: 64, name: "portal_vein_and_splenic_vein", category: .vessel, color: c(184, 134, 11)),
            LabelClass(labelID: 65, name: "iliac_artery_left",      category: .vessel,  color: c(210, 105,  30)),
            LabelClass(labelID: 66, name: "iliac_artery_right",     category: .vessel,  color: c(205, 133,  63)),
            LabelClass(labelID: 67, name: "iliac_vena_left",        category: .vessel,  color: c(139,  69,  19)),
            LabelClass(labelID: 68, name: "iliac_vena_right",       category: .vessel,  color: c(160,  82,  45)),

            // Muscles
            LabelClass(labelID: 69, name: "humerus_left",           category: .bone,    color: c(255, 140,   0)),
            LabelClass(labelID: 70, name: "humerus_right",          category: .bone,    color: c(255, 165,   0)),
            LabelClass(labelID: 71, name: "scapula_left",           category: .bone,    color: c(255, 215,   0)),
            LabelClass(labelID: 72, name: "scapula_right",          category: .bone,    color: c(238, 232, 170)),
            LabelClass(labelID: 73, name: "clavicula_left",         category: .bone,    color: c(240, 230, 140)),
            LabelClass(labelID: 74, name: "clavicula_right",        category: .bone,    color: c(189, 183, 107)),
            LabelClass(labelID: 75, name: "femur_left",             category: .bone,    color: c(128, 128,   0)),
            LabelClass(labelID: 76, name: "femur_right",            category: .bone,    color: c(154, 205,  50)),
            LabelClass(labelID: 77, name: "hip_left",               category: .bone,    color: c(107, 142,  35)),
            LabelClass(labelID: 78, name: "hip_right",              category: .bone,    color: c( 85, 107,  47)),
            LabelClass(labelID: 79, name: "spinal_cord",            category: .brain,   color: c(255, 255, 255)),
            LabelClass(labelID: 80, name: "gluteus_maximus_left",   category: .muscle,  color: c(188, 143, 143)),
            LabelClass(labelID: 81, name: "gluteus_maximus_right",  category: .muscle,  color: c(205, 133, 63)),
            LabelClass(labelID: 82, name: "gluteus_medius_left",    category: .muscle,  color: c(210, 180, 140)),
            LabelClass(labelID: 83, name: "gluteus_medius_right",   category: .muscle,  color: c(222, 184, 135)),
            LabelClass(labelID: 84, name: "gluteus_minimus_left",   category: .muscle,  color: c(244, 164,  96)),
            LabelClass(labelID: 85, name: "gluteus_minimus_right",  category: .muscle,  color: c(210, 105,  30)),
            LabelClass(labelID: 86, name: "autochthon_left",        category: .muscle,  color: c(178,  34,  34)),
            LabelClass(labelID: 87, name: "autochthon_right",       category: .muscle,  color: c(165,  42,  42)),
            LabelClass(labelID: 88, name: "iliopsoas_left",         category: .muscle,  color: c(220,  20,  60)),
            LabelClass(labelID: 89, name: "iliopsoas_right",        category: .muscle,  color: c(199,  21, 133)),
            LabelClass(labelID: 90, name: "brain",                  category: .brain,   color: c(255, 192, 203)),
            LabelClass(labelID: 91, name: "skull",                  category: .bone,    color: c(245, 245, 220)),

            // Ribs
            LabelClass(labelID: 92, name: "rib_left_1",             category: .bone,    color: c(255, 228, 225)),
            LabelClass(labelID: 93, name: "rib_left_2",             category: .bone,    color: c(255, 240, 245)),
            LabelClass(labelID: 94, name: "rib_left_3",             category: .bone,    color: c(255, 182, 193)),
            LabelClass(labelID: 95, name: "rib_left_4",             category: .bone,    color: c(255, 105, 180)),
            LabelClass(labelID: 96, name: "rib_left_5",             category: .bone,    color: c(255,  20, 147)),
            LabelClass(labelID: 97, name: "rib_left_6",             category: .bone,    color: c(219, 112, 147)),
            LabelClass(labelID: 98, name: "rib_left_7",             category: .bone,    color: c(199,  21, 133)),
            LabelClass(labelID: 99, name: "rib_left_8",             category: .bone,    color: c(218, 112, 214)),
            LabelClass(labelID: 100, name: "rib_left_9",            category: .bone,    color: c(221, 160, 221)),
            LabelClass(labelID: 101, name: "rib_left_10",           category: .bone,    color: c(238, 130, 238)),
            LabelClass(labelID: 102, name: "rib_left_11",           category: .bone,    color: c(255,   0, 255)),
            LabelClass(labelID: 103, name: "rib_left_12",           category: .bone,    color: c(186,  85, 211)),
            LabelClass(labelID: 104, name: "rib_right_1",           category: .bone,    color: c(147, 112, 219)),
        ]
        return LabelPresetSet(name: "TotalSegmentator",
                              description: "Full anatomy (104 structures)",
                              classes: classes)
    }()

    // MARK: - AutoPET (PET/CT lesion segmentation)

    public static let autoPET: LabelPresetSet = LabelPresetSet(
        name: "AutoPET",
        description: "FDG-PET/CT lesion labels (binary + multi-lesion)",
        classes: [
            LabelClass(labelID: 1, name: "FDG-avid lesion",  category: .petHotspot, color: Color(r: 255,   0,   0), opacity: 0.6),
            LabelClass(labelID: 2, name: "Physiological uptake", category: .nuclearUptake, color: Color(r:   0, 255, 255), opacity: 0.4),
            LabelClass(labelID: 3, name: "Inflammation",     category: .nuclearUptake, color: Color(r: 255, 200,   0), opacity: 0.4),
            LabelClass(labelID: 4, name: "Brown fat",        category: .nuclearUptake, color: Color(r: 139,  69,  19), opacity: 0.3),
            LabelClass(labelID: 5, name: "Bone marrow uptake", category: .nuclearUptake, color: Color(r: 255, 215,   0), opacity: 0.3),
        ]
    )

    // MARK: - BraTS (Brain Tumor Segmentation)

    public static let brats: LabelPresetSet = LabelPresetSet(
        name: "BraTS",
        description: "Brain tumor multiparametric labels",
        classes: [
            LabelClass(labelID: 1, name: "Edema (non-enhancing)",     category: .tumor, color: Color(r: 255, 255,   0)),
            LabelClass(labelID: 2, name: "Non-enhancing tumor core",   category: .tumor, color: Color(r:   0, 255,   0)),
            LabelClass(labelID: 3, name: "Enhancing tumor",            category: .tumor, color: Color(r: 255,   0,   0)),
            LabelClass(labelID: 4, name: "Necrotic tumor core",        category: .tumor, color: Color(r: 128,   0, 128)),
        ]
    )

    // MARK: - AMOS (Abdominal Multi-Organ)

    public static let amos: LabelPresetSet = LabelPresetSet(
        name: "AMOS",
        description: "15 abdominal organs",
        classes: [
            LabelClass(labelID: 1,  name: "spleen",              category: .organ, color: Color(r: 255, 105,  97)),
            LabelClass(labelID: 2,  name: "right kidney",        category: .organ, color: Color(r: 139,  69,  19)),
            LabelClass(labelID: 3,  name: "left kidney",         category: .organ, color: Color(r: 160,  82,  45)),
            LabelClass(labelID: 4,  name: "gallbladder",         category: .organ, color: Color(r:  95, 158, 160)),
            LabelClass(labelID: 5,  name: "esophagus",           category: .organ, color: Color(r: 255, 160, 122)),
            LabelClass(labelID: 6,  name: "liver",               category: .organ, color: Color(r: 139,  26,  26)),
            LabelClass(labelID: 7,  name: "stomach",             category: .organ, color: Color(r: 255, 182, 193)),
            LabelClass(labelID: 8,  name: "aorta",               category: .vessel, color: Color(r: 220,  20,  60)),
            LabelClass(labelID: 9,  name: "inferior vena cava",  category: .vessel, color: Color(r: 165,  42,  42)),
            LabelClass(labelID: 10, name: "pancreas",            category: .organ, color: Color(r: 218, 165,  32)),
            LabelClass(labelID: 11, name: "right adrenal gland", category: .organ, color: Color(r: 255, 215,   0)),
            LabelClass(labelID: 12, name: "left adrenal gland",  category: .organ, color: Color(r: 255, 223, 128)),
            LabelClass(labelID: 13, name: "duodenum",            category: .organ, color: Color(r: 255, 218, 185)),
            LabelClass(labelID: 14, name: "bladder",             category: .organ, color: Color(r: 255, 250, 205)),
            LabelClass(labelID: 15, name: "prostate/uterus",     category: .organ, color: Color(r: 255, 240, 245)),
        ]
    )

    // MARK: - MSD (Medical Segmentation Decathlon)

    public static let msdLiver: LabelPresetSet = LabelPresetSet(
        name: "MSD Liver",
        description: "Liver + tumor segmentation",
        classes: [
            LabelClass(labelID: 1, name: "liver",       category: .organ, color: Color(r: 139,  26,  26)),
            LabelClass(labelID: 2, name: "liver tumor", category: .tumor, color: Color(r: 255,  20,  20)),
        ]
    )

    public static let msdLung: LabelPresetSet = LabelPresetSet(
        name: "MSD Lung",
        description: "Lung nodule segmentation",
        classes: [
            LabelClass(labelID: 1, name: "lung nodule", category: .lesion, color: Color(r: 255,   0,   0)),
        ]
    )

    public static let msdPancreas: LabelPresetSet = LabelPresetSet(
        name: "MSD Pancreas",
        description: "Pancreas + lesion",
        classes: [
            LabelClass(labelID: 1, name: "pancreas", category: .organ, color: Color(r: 218, 165, 32)),
            LabelClass(labelID: 2, name: "pancreatic lesion", category: .lesion, color: Color(r: 255, 0, 0)),
        ]
    )

    public static let msdProstate: LabelPresetSet = LabelPresetSet(
        name: "MSD Prostate",
        description: "Prostate zonal",
        classes: [
            LabelClass(labelID: 1, name: "peripheral zone",   category: .organ, color: Color(r: 255, 165,   0)),
            LabelClass(labelID: 2, name: "central gland",     category: .organ, color: Color(r: 255, 215,   0)),
        ]
    )

    // MARK: - RT Structures (clinical radiotherapy)

    public static let rtStructures: LabelPresetSet = LabelPresetSet(
        name: "RT Standard",
        description: "ICRU 50/62/83 target volumes",
        classes: [
            LabelClass(labelID: 1, name: "GTV",        category: .rtTarget, color: Color(r: 255,   0,   0), notes: "Gross Tumor Volume"),
            LabelClass(labelID: 2, name: "GTV-N",      category: .rtTarget, color: Color(r: 255,  80,  80), notes: "Gross Tumor Volume - nodal"),
            LabelClass(labelID: 3, name: "CTV",        category: .rtTarget, color: Color(r: 255, 140,   0), notes: "Clinical Target Volume"),
            LabelClass(labelID: 4, name: "CTV-N",      category: .rtTarget, color: Color(r: 255, 170,  80), notes: "CTV - nodal"),
            LabelClass(labelID: 5, name: "ITV",        category: .rtTarget, color: Color(r: 255, 200,   0), notes: "Internal Target Volume"),
            LabelClass(labelID: 6, name: "PTV",        category: .rtTarget, color: Color(r: 255, 255,   0), notes: "Planning Target Volume"),
            LabelClass(labelID: 7, name: "PTV-N",      category: .rtTarget, color: Color(r: 255, 255, 100), notes: "PTV - nodal"),
            LabelClass(labelID: 8, name: "Boost",      category: .rtTarget, color: Color(r: 255,   0, 255), notes: "Boost volume"),
            LabelClass(labelID: 9, name: "External",   category: .rtStructure, color: Color(r:   0, 255, 255), notes: "Patient external contour"),
            LabelClass(labelID: 10, name: "Support",   category: .rtStructure, color: Color(r: 128, 128, 128), notes: "Couch/immobilization"),
        ]
    )

    // MARK: - PET focal uptake

    public static let petFocal: LabelPresetSet = LabelPresetSet(
        name: "PET Focal Uptake",
        description: "Categorize PET hotspots by etiology",
        classes: [
            LabelClass(labelID: 1, name: "Primary tumor",     category: .petHotspot, color: Color(r: 255,   0,   0), opacity: 0.6),
            LabelClass(labelID: 2, name: "Lymph node (N+)",   category: .petHotspot, color: Color(r: 255, 100,   0), opacity: 0.6),
            LabelClass(labelID: 3, name: "Distant metastasis", category: .petHotspot, color: Color(r: 255,   0, 255), opacity: 0.6),
            LabelClass(labelID: 4, name: "Bone metastasis",   category: .petHotspot, color: Color(r: 139,   0, 139), opacity: 0.6),
            LabelClass(labelID: 5, name: "Liver metastasis",  category: .petHotspot, color: Color(r: 205,  92,  92), opacity: 0.6),
            LabelClass(labelID: 6, name: "Pulmonary metastasis", category: .petHotspot, color: Color(r: 255, 140, 105), opacity: 0.6),
            LabelClass(labelID: 7, name: "Equivocal",         category: .petHotspot, color: Color(r: 255, 255,   0), opacity: 0.6),
            LabelClass(labelID: 8, name: "Physiological",     category: .nuclearUptake, color: Color(r:   0, 200, 200), opacity: 0.4),
            LabelClass(labelID: 9, name: "Inflammation",      category: .nuclearUptake, color: Color(r: 100, 100, 255), opacity: 0.4),
            LabelClass(labelID: 10, name: "Brown fat",        category: .nuclearUptake, color: Color(r: 139,  69,  19), opacity: 0.3),
        ]
    )

    // MARK: - Oncology clinical

    public static let oncologyClinical: LabelPresetSet = LabelPresetSet(
        name: "Oncology (Clinical)",
        description: "Primary, nodal, metastatic disease",
        classes: [
            LabelClass(labelID: 1,  name: "Primary tumor",       category: .tumor,     color: Color(r: 255,   0,   0)),
            LabelClass(labelID: 2,  name: "Lymph node - positive", category: .lesion,  color: Color(r: 255, 128,   0)),
            LabelClass(labelID: 3,  name: "Lymph node - reactive", category: .lesion,  color: Color(r: 255, 200, 100)),
            LabelClass(labelID: 4,  name: "Metastasis - osseous",  category: .lesion,  color: Color(r: 139,   0, 139)),
            LabelClass(labelID: 5,  name: "Metastasis - visceral", category: .lesion,  color: Color(r: 199,  21, 133)),
            LabelClass(labelID: 6,  name: "Metastasis - nodal",    category: .lesion,  color: Color(r: 218, 112, 214)),
            LabelClass(labelID: 7,  name: "Recurrence",            category: .tumor,   color: Color(r: 180,   0,   0)),
            LabelClass(labelID: 8,  name: "Residual disease",      category: .tumor,   color: Color(r: 220,  20,  60)),
            LabelClass(labelID: 9,  name: "Post-treatment change", category: .pathology, color: Color(r:   0, 128, 128)),
            LabelClass(labelID: 10, name: "Treatment response",    category: .pathology, color: Color(r:   0, 200,   0)),
        ]
    )

    // MARK: - FreeSurfer lobes (simplified Desikan-Killiany)

    public static let freesurferLobes: LabelPresetSet = LabelPresetSet(
        name: "Brain Lobes",
        description: "Major cerebral lobes",
        classes: [
            LabelClass(labelID: 1,  name: "frontal_left",       category: .brain, color: Color(r: 255,   0,   0)),
            LabelClass(labelID: 2,  name: "frontal_right",      category: .brain, color: Color(r: 255, 100, 100)),
            LabelClass(labelID: 3,  name: "parietal_left",      category: .brain, color: Color(r:   0, 255,   0)),
            LabelClass(labelID: 4,  name: "parietal_right",     category: .brain, color: Color(r: 100, 255, 100)),
            LabelClass(labelID: 5,  name: "temporal_left",      category: .brain, color: Color(r:   0,   0, 255)),
            LabelClass(labelID: 6,  name: "temporal_right",     category: .brain, color: Color(r: 100, 100, 255)),
            LabelClass(labelID: 7,  name: "occipital_left",     category: .brain, color: Color(r: 255, 255,   0)),
            LabelClass(labelID: 8,  name: "occipital_right",    category: .brain, color: Color(r: 255, 255, 100)),
            LabelClass(labelID: 9,  name: "cerebellum",         category: .brain, color: Color(r: 128,   0, 128)),
            LabelClass(labelID: 10, name: "brainstem",          category: .brain, color: Color(r:  64,   0,  64)),
            LabelClass(labelID: 11, name: "hippocampus",        category: .brain, color: Color(r: 255, 140,   0)),
            LabelClass(labelID: 12, name: "amygdala",           category: .brain, color: Color(r: 255, 215,   0)),
            LabelClass(labelID: 13, name: "thalamus",           category: .brain, color: Color(r: 200, 100, 200)),
            LabelClass(labelID: 14, name: "caudate",            category: .brain, color: Color(r: 255,  69,   0)),
            LabelClass(labelID: 15, name: "putamen",            category: .brain, color: Color(r: 218, 112, 214)),
        ]
    )

    // MARK: - Head & Neck OARs

    public static let head_neck_OARs: LabelPresetSet = LabelPresetSet(
        name: "H&N OARs",
        description: "Head & Neck organs at risk",
        classes: [
            LabelClass(labelID: 1,  name: "Brainstem",              category: .rtOAR, color: Color(r: 255,   0,   0)),
            LabelClass(labelID: 2,  name: "Spinal cord",            category: .rtOAR, color: Color(r: 255, 255,   0)),
            LabelClass(labelID: 3,  name: "Parotid left",           category: .rtOAR, color: Color(r:   0, 255,   0)),
            LabelClass(labelID: 4,  name: "Parotid right",          category: .rtOAR, color: Color(r:   0, 200,   0)),
            LabelClass(labelID: 5,  name: "Submandibular left",     category: .rtOAR, color: Color(r:   0,   0, 255)),
            LabelClass(labelID: 6,  name: "Submandibular right",    category: .rtOAR, color: Color(r: 100, 100, 255)),
            LabelClass(labelID: 7,  name: "Oral cavity",            category: .rtOAR, color: Color(r: 255, 192, 203)),
            LabelClass(labelID: 8,  name: "Mandible",               category: .rtOAR, color: Color(r: 245, 245, 220)),
            LabelClass(labelID: 9,  name: "Larynx",                 category: .rtOAR, color: Color(r: 255, 160, 122)),
            LabelClass(labelID: 10, name: "Pharynx constrictors",   category: .rtOAR, color: Color(r: 255, 182, 193)),
            LabelClass(labelID: 11, name: "Esophagus (cervical)",   category: .rtOAR, color: Color(r: 255, 140,   0)),
            LabelClass(labelID: 12, name: "Thyroid",                category: .rtOAR, color: Color(r: 255,   0, 255)),
            LabelClass(labelID: 13, name: "Optic nerve left",       category: .rtOAR, color: Color(r:   0, 255, 255)),
            LabelClass(labelID: 14, name: "Optic nerve right",      category: .rtOAR, color: Color(r: 100, 255, 255)),
            LabelClass(labelID: 15, name: "Optic chiasm",           category: .rtOAR, color: Color(r: 255,  20, 147)),
            LabelClass(labelID: 16, name: "Lens left",              category: .rtOAR, color: Color(r: 255, 105, 180)),
            LabelClass(labelID: 17, name: "Lens right",             category: .rtOAR, color: Color(r: 255, 140, 180)),
            LabelClass(labelID: 18, name: "Eye left",               category: .rtOAR, color: Color(r: 173, 216, 230)),
            LabelClass(labelID: 19, name: "Eye right",              category: .rtOAR, color: Color(r: 135, 206, 235)),
            LabelClass(labelID: 20, name: "Cochlea left",           category: .rtOAR, color: Color(r: 218, 165,  32)),
            LabelClass(labelID: 21, name: "Cochlea right",          category: .rtOAR, color: Color(r: 184, 134,  11)),
        ]
    )

    // MARK: - Thorax OARs

    public static let thorax_OARs: LabelPresetSet = LabelPresetSet(
        name: "Thorax OARs",
        description: "Thoracic organs at risk",
        classes: [
            LabelClass(labelID: 1, name: "Lung left",       category: .rtOAR, color: Color(r:   0, 255, 255)),
            LabelClass(labelID: 2, name: "Lung right",      category: .rtOAR, color: Color(r: 100, 255, 255)),
            LabelClass(labelID: 3, name: "Heart",           category: .rtOAR, color: Color(r: 255,   0,   0)),
            LabelClass(labelID: 4, name: "Esophagus",       category: .rtOAR, color: Color(r: 255, 140,   0)),
            LabelClass(labelID: 5, name: "Spinal cord",     category: .rtOAR, color: Color(r: 255, 255,   0)),
            LabelClass(labelID: 6, name: "Trachea",         category: .rtOAR, color: Color(r: 255, 192, 203)),
            LabelClass(labelID: 7, name: "Brachial plexus", category: .rtOAR, color: Color(r: 255, 165,   0)),
            LabelClass(labelID: 8, name: "Great vessels",   category: .rtOAR, color: Color(r: 220,  20,  60)),
            LabelClass(labelID: 9, name: "LAD",             category: .rtOAR, color: Color(r: 139,   0,   0), notes: "Left anterior descending artery"),
        ]
    )

    // MARK: - Abdominal OARs

    public static let abdominal_OARs: LabelPresetSet = LabelPresetSet(
        name: "Abdominal OARs",
        description: "Abdominal organs at risk",
        classes: [
            LabelClass(labelID: 1, name: "Liver",         category: .rtOAR, color: Color(r: 139,  26,  26)),
            LabelClass(labelID: 2, name: "Kidney left",   category: .rtOAR, color: Color(r: 160,  82,  45)),
            LabelClass(labelID: 3, name: "Kidney right",  category: .rtOAR, color: Color(r: 139,  69,  19)),
            LabelClass(labelID: 4, name: "Spinal cord",   category: .rtOAR, color: Color(r: 255, 255,   0)),
            LabelClass(labelID: 5, name: "Stomach",       category: .rtOAR, color: Color(r: 255, 182, 193)),
            LabelClass(labelID: 6, name: "Duodenum",      category: .rtOAR, color: Color(r: 255, 218, 185)),
            LabelClass(labelID: 7, name: "Small bowel",   category: .rtOAR, color: Color(r: 255, 228, 181)),
            LabelClass(labelID: 8, name: "Large bowel",   category: .rtOAR, color: Color(r: 245, 222, 179)),
            LabelClass(labelID: 9, name: "Pancreas",      category: .rtOAR, color: Color(r: 218, 165,  32)),
            LabelClass(labelID: 10, name: "Spleen",       category: .rtOAR, color: Color(r: 255, 105,  97)),
        ]
    )

    // MARK: - Pelvic OARs

    public static let pelvic_OARs: LabelPresetSet = LabelPresetSet(
        name: "Pelvic OARs",
        description: "Pelvic organs at risk",
        classes: [
            LabelClass(labelID: 1, name: "Bladder",         category: .rtOAR, color: Color(r: 255, 250, 205)),
            LabelClass(labelID: 2, name: "Rectum",          category: .rtOAR, color: Color(r: 255, 140,   0)),
            LabelClass(labelID: 3, name: "Prostate",        category: .rtOAR, color: Color(r: 255, 240, 245)),
            LabelClass(labelID: 4, name: "Seminal vesicles", category: .rtOAR, color: Color(r: 255, 200, 210)),
            LabelClass(labelID: 5, name: "Penile bulb",     category: .rtOAR, color: Color(r: 255, 150, 170)),
            LabelClass(labelID: 6, name: "Femoral head L",  category: .rtOAR, color: Color(r: 128, 128,   0)),
            LabelClass(labelID: 7, name: "Femoral head R",  category: .rtOAR, color: Color(r: 154, 205,  50)),
            LabelClass(labelID: 8, name: "Cervix",          category: .rtOAR, color: Color(r: 255, 192, 203)),
            LabelClass(labelID: 9, name: "Uterus",          category: .rtOAR, color: Color(r: 255, 182, 193)),
            LabelClass(labelID: 10, name: "Vagina",         category: .rtOAR, color: Color(r: 255, 160, 180)),
            LabelClass(labelID: 11, name: "Small bowel",    category: .rtOAR, color: Color(r: 255, 228, 181)),
            LabelClass(labelID: 12, name: "Sigmoid",        category: .rtOAR, color: Color(r: 218, 165,  32)),
            LabelClass(labelID: 13, name: "Cauda equina",   category: .rtOAR, color: Color(r: 255, 255,   0)),
        ]
    )

    // MARK: - Full spine

    public static let spineVertebrae: LabelPresetSet = LabelPresetSet(
        name: "Spine Vertebrae",
        description: "C1–L5 individually labeled",
        classes: (1...7).map { i in
            LabelClass(labelID: UInt16(i), name: "C\(i)", category: .bone,
                       color: Color(r: 255 - i*20, g: 150, b: 150 + i*15))
        } + (1...12).map { i in
            LabelClass(labelID: UInt16(7 + i), name: "T\(i)", category: .bone,
                       color: Color(r: 150, g: 255 - i*15, b: 150 + i*8))
        } + (1...5).map { i in
            LabelClass(labelID: UInt16(19 + i), name: "L\(i)", category: .bone,
                       color: Color(r: 150 + i*20, g: 150, b: 255 - i*30))
        }
    )
}

/// A preset collection of labels for a particular segmentation task.
public struct LabelPresetSet: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let classes: [LabelClass]
}
