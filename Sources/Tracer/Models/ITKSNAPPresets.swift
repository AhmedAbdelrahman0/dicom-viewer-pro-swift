import Foundation
import SwiftUI

/// A set of anatomical label presets matching the layout and intent of
/// ITK-SNAP's default label descriptors (the `.label` files shipped
/// alongside the application). Names and colors here are **re-authored**
/// for this project so that nothing is copied from the ITK-SNAP repository
/// (which is GPL-3.0). They're inspired by the same anatomical taxonomy
/// that ITK-SNAP ships with.
///
/// These presets round out `LabelPresets.all` — register them through
/// `ITKSNAPPresets.register(into:)` or consume them à la carte.
public enum ITKSNAPPresets {

    /// All re-authored "ITK-SNAP-style" anatomical presets.
    public static var all: [LabelPresetSet] {
        [
            brainMRIClassic,
            cardiacCineMRI,
            hipHamstringMuscles,
            kneeCartilage,
            liverSegments,
            lungLobesAirway,
            spineMulti,
            breastMRI,
            headCTBones,
            prostateZonalMRI,
        ]
    }

    /// Append the ITK-SNAP-style presets to the existing preset list.
    /// Filters out any name that already exists in `existing` so apps that
    /// call this at startup can call it safely multiple times.
    public static func register(into existing: inout [LabelPresetSet]) {
        let present = Set(existing.map(\.name))
        for preset in all where !present.contains(preset.name) {
            existing.append(preset)
        }
    }

    // MARK: - Brain MRI (T1 / T1c / FLAIR segmentation)

    public static let brainMRIClassic = LabelPresetSet(
        name: "Brain MRI (ITK-SNAP style)",
        description: "Cortical + deep-gray + CSF structures",
        classes: [
            LabelClass(labelID: 1,  name: "cortical_gm",       category: .brain, color: Color(r: 200,  80,  80)),
            LabelClass(labelID: 2,  name: "white_matter",      category: .brain, color: Color(r: 240, 240, 240)),
            LabelClass(labelID: 3,  name: "csf",               category: .brain, color: Color(r:  80, 140, 255)),
            LabelClass(labelID: 4,  name: "lateral_ventricle", category: .brain, color: Color(r:  50, 100, 220)),
            LabelClass(labelID: 5,  name: "third_ventricle",   category: .brain, color: Color(r:  30,  80, 200)),
            LabelClass(labelID: 6,  name: "fourth_ventricle",  category: .brain, color: Color(r:  30,  60, 180)),
            LabelClass(labelID: 7,  name: "thalamus",          category: .brain, color: Color(r: 180, 100, 200)),
            LabelClass(labelID: 8,  name: "caudate",           category: .brain, color: Color(r: 200, 120, 100)),
            LabelClass(labelID: 9,  name: "putamen",           category: .brain, color: Color(r: 240, 180, 100)),
            LabelClass(labelID: 10, name: "globus_pallidus",   category: .brain, color: Color(r: 210, 140,  80)),
            LabelClass(labelID: 11, name: "hippocampus",       category: .brain, color: Color(r: 240, 200,  90)),
            LabelClass(labelID: 12, name: "amygdala",          category: .brain, color: Color(r: 220, 130,  60)),
            LabelClass(labelID: 13, name: "brainstem",         category: .brain, color: Color(r: 140,  80, 120)),
            LabelClass(labelID: 14, name: "cerebellar_gm",     category: .brain, color: Color(r: 180,  90, 150)),
            LabelClass(labelID: 15, name: "cerebellar_wm",     category: .brain, color: Color(r: 220, 200, 160)),
            LabelClass(labelID: 16, name: "tumor_core",        category: .tumor, color: Color(r: 255,   0,   0)),
            LabelClass(labelID: 17, name: "peritumoral_edema", category: .pathology, color: Color(r: 255, 200,  60)),
        ]
    )

    // MARK: - Cardiac cine MRI (ACDC-style 3-class + LA)

    public static let cardiacCineMRI = LabelPresetSet(
        name: "Cardiac Cine MRI",
        description: "LV / RV / MYO / LA — ACDC-style labels",
        classes: [
            LabelClass(labelID: 1, name: "lv_cavity",      category: .cardiac, color: Color(r: 220,  40,  40)),
            LabelClass(labelID: 2, name: "myocardium",     category: .cardiac, color: Color(r: 180,  80,  80)),
            LabelClass(labelID: 3, name: "rv_cavity",      category: .cardiac, color: Color(r:  40, 120, 220)),
            LabelClass(labelID: 4, name: "left_atrium",    category: .cardiac, color: Color(r: 200, 100, 160)),
            LabelClass(labelID: 5, name: "right_atrium",   category: .cardiac, color: Color(r: 100, 150, 220)),
            LabelClass(labelID: 6, name: "papillary_mm",   category: .cardiac, color: Color(r: 240, 140, 140)),
        ]
    )

    // MARK: - Hip / hamstring muscles (orthopedic MRI)

    public static let hipHamstringMuscles = LabelPresetSet(
        name: "Hip & Hamstring Muscles",
        description: "Gluteals, iliopsoas, hamstrings, adductors",
        classes: [
            LabelClass(labelID: 1,  name: "gluteus_maximus",    category: .muscle, color: Color(r: 200, 100, 100)),
            LabelClass(labelID: 2,  name: "gluteus_medius",     category: .muscle, color: Color(r: 220, 140, 100)),
            LabelClass(labelID: 3,  name: "gluteus_minimus",    category: .muscle, color: Color(r: 240, 180, 110)),
            LabelClass(labelID: 4,  name: "iliopsoas",          category: .muscle, color: Color(r: 220,  80,  60)),
            LabelClass(labelID: 5,  name: "biceps_femoris",     category: .muscle, color: Color(r: 180, 120, 220)),
            LabelClass(labelID: 6,  name: "semitendinosus",     category: .muscle, color: Color(r: 140, 100, 210)),
            LabelClass(labelID: 7,  name: "semimembranosus",    category: .muscle, color: Color(r: 120,  80, 200)),
            LabelClass(labelID: 8,  name: "adductor_magnus",    category: .muscle, color: Color(r: 200, 200, 110)),
            LabelClass(labelID: 9,  name: "adductor_longus",    category: .muscle, color: Color(r: 220, 220, 130)),
            LabelClass(labelID: 10, name: "rectus_femoris",     category: .muscle, color: Color(r: 240, 180, 200)),
        ]
    )

    // MARK: - Knee cartilage & menisci

    public static let kneeCartilage = LabelPresetSet(
        name: "Knee Cartilage & Menisci",
        description: "Osteoarthritis research labels",
        classes: [
            LabelClass(labelID: 1, name: "femoral_cartilage",   category: .organ, color: Color(r: 220, 140,  80)),
            LabelClass(labelID: 2, name: "tibial_cartilage_med",category: .organ, color: Color(r: 200, 200,  80)),
            LabelClass(labelID: 3, name: "tibial_cartilage_lat",category: .organ, color: Color(r: 160, 220,  80)),
            LabelClass(labelID: 4, name: "patellar_cartilage",  category: .organ, color: Color(r: 120, 220, 160)),
            LabelClass(labelID: 5, name: "meniscus_medial",     category: .organ, color: Color(r:  80, 180, 220)),
            LabelClass(labelID: 6, name: "meniscus_lateral",    category: .organ, color: Color(r:  80, 140, 220)),
            LabelClass(labelID: 7, name: "bone_marrow_lesion",  category: .pathology, color: Color(r: 240,  80,  80)),
        ]
    )

    // MARK: - Liver (Couinaud segments)

    public static let liverSegments = LabelPresetSet(
        name: "Liver Couinaud Segments",
        description: "I–VIII liver segments for HCC planning",
        classes: (1...8).map { i in
            LabelClass(labelID: UInt16(i),
                       name: "segment_\(roman(i))",
                       category: .organ,
                       color: Color(r: 120 + i * 15, g: 80 + i * 12, b: 220 - i * 15))
        }
    )

    // MARK: - Lung lobes + airway

    public static let lungLobesAirway = LabelPresetSet(
        name: "Lung Lobes + Airway",
        description: "5 lobes + main airway tree",
        classes: [
            LabelClass(labelID: 1, name: "rul", category: .organ, color: Color(r: 200, 220, 255)),
            LabelClass(labelID: 2, name: "rml", category: .organ, color: Color(r: 160, 200, 255)),
            LabelClass(labelID: 3, name: "rll", category: .organ, color: Color(r: 120, 180, 255)),
            LabelClass(labelID: 4, name: "lul", category: .organ, color: Color(r: 255, 200, 180)),
            LabelClass(labelID: 5, name: "lll", category: .organ, color: Color(r: 255, 150, 130)),
            LabelClass(labelID: 6, name: "trachea", category: .organ, color: Color(r: 250, 230, 140)),
            LabelClass(labelID: 7, name: "main_bronchus_left",  category: .organ, color: Color(r: 220, 180, 110)),
            LabelClass(labelID: 8, name: "main_bronchus_right", category: .organ, color: Color(r: 200, 160,  90)),
        ]
    )

    // MARK: - Spine multi-structure

    public static let spineMulti = LabelPresetSet(
        name: "Spine Multi-structure",
        description: "Vertebrae + discs + spinal cord + canal",
        classes: [
            LabelClass(labelID: 1, name: "vertebral_body",   category: .bone,  color: Color(r: 240, 200, 160)),
            LabelClass(labelID: 2, name: "pedicle",          category: .bone,  color: Color(r: 220, 180, 150)),
            LabelClass(labelID: 3, name: "lamina",           category: .bone,  color: Color(r: 200, 150, 120)),
            LabelClass(labelID: 4, name: "spinous_process",  category: .bone,  color: Color(r: 180, 130, 100)),
            LabelClass(labelID: 5, name: "transverse_proc",  category: .bone,  color: Color(r: 160, 110,  80)),
            LabelClass(labelID: 6, name: "intervertebral_disc", category: .organ, color: Color(r: 200, 220, 255)),
            LabelClass(labelID: 7, name: "spinal_cord",      category: .brain, color: Color(r: 240, 240, 200)),
            LabelClass(labelID: 8, name: "spinal_canal",     category: .organ, color: Color(r: 100, 180, 220)),
        ]
    )

    // MARK: - Breast MRI

    public static let breastMRI = LabelPresetSet(
        name: "Breast MRI",
        description: "FGT, tumor, nipple — ACR BI-RADS inspired",
        classes: [
            LabelClass(labelID: 1, name: "fibroglandular_tissue", category: .organ, color: Color(r: 220, 200, 120)),
            LabelClass(labelID: 2, name: "fat",                   category: .organ, color: Color(r: 255, 230, 180)),
            LabelClass(labelID: 3, name: "nipple",                category: .organ, color: Color(r: 200, 100, 100)),
            LabelClass(labelID: 4, name: "skin",                  category: .organ, color: Color(r: 240, 180, 150)),
            LabelClass(labelID: 5, name: "tumor_enhancing",       category: .tumor, color: Color(r: 255,   0,   0)),
            LabelClass(labelID: 6, name: "tumor_nonenhancing",    category: .tumor, color: Color(r: 220,  80,  80)),
            LabelClass(labelID: 7, name: "axillary_ln",           category: .lesion, color: Color(r: 180,  40, 140)),
        ]
    )

    // MARK: - Head CT bones (fracture review)

    public static let headCTBones = LabelPresetSet(
        name: "Head CT Bones",
        description: "Calvarium, maxilla, mandible, cervical spine",
        classes: [
            LabelClass(labelID: 1, name: "calvarium_frontal",  category: .bone, color: Color(r: 240, 220, 180)),
            LabelClass(labelID: 2, name: "calvarium_parietal", category: .bone, color: Color(r: 220, 200, 160)),
            LabelClass(labelID: 3, name: "calvarium_temporal", category: .bone, color: Color(r: 200, 180, 140)),
            LabelClass(labelID: 4, name: "calvarium_occipital",category: .bone, color: Color(r: 180, 160, 120)),
            LabelClass(labelID: 5, name: "maxilla",            category: .bone, color: Color(r: 220, 180, 100)),
            LabelClass(labelID: 6, name: "mandible",           category: .bone, color: Color(r: 200, 160,  80)),
            LabelClass(labelID: 7, name: "cervical_c1_c2",     category: .bone, color: Color(r: 240, 140,  80)),
            LabelClass(labelID: 8, name: "cervical_c3_c7",     category: .bone, color: Color(r: 220, 120,  60)),
            LabelClass(labelID: 9, name: "fracture",           category: .pathology, color: Color(r: 255,   0,   0)),
        ]
    )

    // MARK: - Prostate zonal MRI

    public static let prostateZonalMRI = LabelPresetSet(
        name: "Prostate Zonal MRI",
        description: "TZ, PZ, CZ, AFS, urethra — for PI-RADS readers",
        classes: [
            LabelClass(labelID: 1, name: "transition_zone",   category: .organ, color: Color(r: 220, 160, 100)),
            LabelClass(labelID: 2, name: "peripheral_zone",   category: .organ, color: Color(r: 240, 200, 140)),
            LabelClass(labelID: 3, name: "central_zone",      category: .organ, color: Color(r: 200, 120,  80)),
            LabelClass(labelID: 4, name: "anterior_fibromuscular", category: .organ, color: Color(r: 180, 180, 120)),
            LabelClass(labelID: 5, name: "urethra",           category: .organ, color: Color(r: 120, 180, 240)),
            LabelClass(labelID: 6, name: "seminal_vesicles",  category: .organ, color: Color(r: 200, 180, 220)),
            LabelClass(labelID: 7, name: "tumor_pirads3",     category: .tumor, color: Color(r: 255, 230,   0)),
            LabelClass(labelID: 8, name: "tumor_pirads4",     category: .tumor, color: Color(r: 255, 150,   0)),
            LabelClass(labelID: 9, name: "tumor_pirads5",     category: .tumor, color: Color(r: 255,   0,   0)),
        ]
    )

    private static func roman(_ n: Int) -> String {
        switch n {
        case 1: return "I"
        case 2: return "II"
        case 3: return "III"
        case 4: return "IVa"
        case 5: return "IVb"
        case 6: return "VI"
        case 7: return "VII"
        case 8: return "VIII"
        default: return "\(n)"
        }
    }
}
