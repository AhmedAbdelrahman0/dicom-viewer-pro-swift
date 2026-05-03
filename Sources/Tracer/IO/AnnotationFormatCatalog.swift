import Foundation

public enum AnnotationFormatSupport: String, Sendable {
    case nativeReadWrite = "Read/write"
    case exportOnly = "Export only"
    case sidecar = "Sidecar"
    case guideOnly = "Guide only"
}

public enum AnnotationPayloadFeature: String, CaseIterable, Identifiable, Sendable {
    case voxelMask = "3D voxel mask"
    case contourGeometry = "Editable contours"
    case segmentNames = "Segment names"
    case colors = "Colors"
    case spatialGeometry = "Spacing/origin/orientation"
    case dicomReferences = "DICOM clinical references"
    case measurements = "Measurements and radiomics"
    case annotations = "2D annotations"
    case landmarks = "Registration landmarks"
    case probabilityValues = "Probability/fractional values"
    case hierarchy = "Hierarchy/coded meaning"
    case meshSurface = "Surface mesh"

    public var id: String { rawValue }
}

public struct AnnotationConversionWarning: Identifiable, Equatable, Sendable {
    public enum Severity: String, Sendable {
        case info = "Info"
        case caution = "Caution"
        case dataLoss = "Data loss"
        case unsupported = "Unsupported"
    }

    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public let affectedFeatures: [AnnotationPayloadFeature]

    public init(severity: Severity,
                title: String,
                detail: String,
                affectedFeatures: [AnnotationPayloadFeature]) {
        self.id = "\(severity.rawValue)-\(title)-\(affectedFeatures.map(\.rawValue).joined(separator: ","))"
        self.severity = severity
        self.title = title
        self.detail = detail
        self.affectedFeatures = affectedFeatures
    }
}

public struct AnnotationFormatGuideEntry: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let extensions: [String]
    public let support: AnnotationFormatSupport
    public let usage: String
    public let storedFeatures: [AnnotationPayloadFeature]
    public let conversionNote: String
}

public extension LabelIO.Format {
    var canonicalExtension: String {
        switch self {
        case .dicomSeg:
            return "seg.dcm"
        case .dicomRTStruct:
            return "rtstruct.dcm"
        case .segmentationNRRD:
            return "seg.nrrd"
        case .niftiGz:
            return "nii.gz"
        default:
            return fileExtensions.first ?? "dat"
        }
    }

    var usageDescription: String {
        switch self {
        case .labelPackage:
            return "Tracer's native editable package. Best for saving the whole in-app labeling session."
        case .niftiLabelmap:
            return "Uncompressed research label map. Best for Python, MONAI, PyRadiomics, and quick local exchange."
        case .niftiGz:
            return "Compressed research label map. Best for nnU-Net/MONAI pipelines and dataset archives."
        case .metaImageMHA:
            return "MHA label map. Best for challenge submissions and image-processing pipelines."
        case .nrrdLabelmap:
            return "Simple integer NRRD mask. Best for generic voxel-label readers."
        case .segmentationNRRD:
            return "Segmentation NRRD. Best for preserving segment names and colors with a voxel mask."
        case .dicomSeg:
            return "DICOM segmentation object. Best clinical/PACS format for PET/CT lesion masks."
        case .dicomRTStruct:
            return "Radiotherapy contour object. Best for RT planning systems that expect ROI contours."
        case .labelDescriptor:
            return "NIfTI mask plus label descriptor. Best for editing workflows that use label names/colors."
        case .json:
            return "Tracer annotation/class JSON. Best for 2D measurements, text annotations, and class metadata."
        case .csv:
            return "Landmark table. Best for point-pair registration and simple spreadsheet review."
        }
    }

    var support: AnnotationFormatSupport {
        switch self {
        case .json, .csv:
            return .nativeReadWrite
        case .labelDescriptor:
            return .sidecar
        default:
            return .nativeReadWrite
        }
    }

    var storedFeatures: [AnnotationPayloadFeature] {
        switch self {
        case .labelPackage:
            return [.voxelMask, .segmentNames, .colors, .spatialGeometry, .annotations, .landmarks]
        case .niftiLabelmap, .niftiGz:
            return [.voxelMask, .spatialGeometry]
        case .labelDescriptor:
            return [.voxelMask, .segmentNames, .colors, .spatialGeometry]
        case .metaImageMHA:
            return [.voxelMask, .spatialGeometry]
        case .nrrdLabelmap:
            return [.voxelMask, .spatialGeometry]
        case .segmentationNRRD:
            return [.voxelMask, .segmentNames, .colors, .spatialGeometry]
        case .dicomSeg:
            return [.voxelMask, .segmentNames, .spatialGeometry, .dicomReferences, .hierarchy]
        case .dicomRTStruct:
            return [.contourGeometry, .segmentNames, .colors, .dicomReferences]
        case .json:
            return [.segmentNames, .colors, .annotations]
        case .csv:
            return [.landmarks]
        }
    }

    var conversionNote: String {
        switch self {
        case .labelPackage:
            return "Highest-fidelity Tracer round trip. Use another format only when another system needs it."
        case .dicomSeg:
            return "Good clinical mask exchange. Measurements/radiomics still belong in DICOM SR or label data export."
        case .dicomRTStruct:
            return "Requires voxel-to-contour extraction; small boundary changes are expected."
        case .niftiLabelmap, .niftiGz, .metaImageMHA, .nrrdLabelmap:
            return "Good mask exchange, but clinical DICOM references and in-app annotations are not carried."
        case .segmentationNRRD, .labelDescriptor:
            return "Good editing exchange with labels/colors, but not a clinical DICOM object."
        case .json:
            return "Does not contain the voxel mask. Pair with a mask export when sharing a segmentation."
        case .csv:
            return "Does not contain the voxel mask or annotations. It is for landmarks only."
        }
    }

    func conversionWarnings(hasVoxels: Bool,
                            hasAnnotations: Bool,
                            hasLandmarks: Bool) -> [AnnotationConversionWarning] {
        var warnings: [AnnotationConversionWarning] = []

        switch self {
        case .labelPackage:
            break
        case .dicomSeg:
            if hasAnnotations || hasLandmarks {
                warnings.append(.init(
                    severity: .dataLoss,
                    title: "Only the segmentation mask is exported",
                    detail: "DICOM SEG stores lesion voxels and segment metadata. Tracer annotations and registration landmarks are not written into this object.",
                    affectedFeatures: [.annotations, .landmarks]
                ))
            }
            warnings.append(.init(
                severity: .info,
                title: "Measurements are separate",
                detail: "SUV, HU, volume, and radiomics should be exported as label data or DICOM SR; they are not part of the SEG pixel mask.",
                affectedFeatures: [.measurements]
            ))
        case .dicomRTStruct:
            warnings.append(.init(
                severity: .caution,
                title: "Voxel mask becomes contours",
                detail: "RTSTRUCT is contour-based. Thin structures and jagged voxel edges can shift when converted to planar contours.",
                affectedFeatures: [.voxelMask, .contourGeometry]
            ))
            if hasAnnotations || hasLandmarks {
                warnings.append(.init(
                    severity: .dataLoss,
                    title: "Annotations and landmarks are not exported",
                    detail: "RTSTRUCT carries ROI contours, not Tracer 2D annotations or landmark pairs.",
                    affectedFeatures: [.annotations, .landmarks]
                ))
            }
        case .niftiLabelmap, .niftiGz:
            warnings.append(.init(
                severity: .caution,
                title: "Clinical DICOM context is reduced",
                detail: "The NIfTI affine preserves geometry, but DICOM series references, coded meanings, and PACS metadata are not preserved.",
                affectedFeatures: [.dicomReferences, .hierarchy]
            ))
            if hasAnnotations || hasLandmarks {
                warnings.append(.init(
                    severity: .dataLoss,
                    title: "Only the voxel mask is exported",
                    detail: "Tracer 2D annotations and landmark pairs are not part of the NIfTI mask.",
                    affectedFeatures: [.annotations, .landmarks]
                ))
            }
        case .labelDescriptor:
            warnings.append(.init(
                severity: .caution,
                title: "DICOM context is not preserved",
                detail: "The NIfTI mask and label descriptor do not preserve clinical DICOM references.",
                affectedFeatures: [.dicomReferences, .hierarchy]
            ))
        case .metaImageMHA:
            warnings.append(.init(
                severity: .dataLoss,
                title: "Segment names and colors are not embedded",
                detail: "MHA stores the integer mask and geometry but not Tracer's class table, annotations, or landmarks.",
                affectedFeatures: [.segmentNames, .colors, .annotations, .landmarks]
            ))
        case .nrrdLabelmap:
            warnings.append(.init(
                severity: .dataLoss,
                title: "Simple NRRD loses segment metadata",
                detail: "Use segmentation NRRD if you need names/colors. This plain NRRD stores integer voxels and geometry.",
                affectedFeatures: [.segmentNames, .colors, .annotations, .landmarks]
            ))
        case .segmentationNRRD:
            if hasAnnotations || hasLandmarks {
                warnings.append(.init(
                    severity: .dataLoss,
                    title: "Only segments are exported",
                    detail: "Segmentation NRRD keeps segment names/colors with the mask, but not Tracer annotations or landmarks.",
                    affectedFeatures: [.annotations, .landmarks]
                ))
            }
            warnings.append(.init(
                severity: .caution,
                title: "Not a clinical DICOM object",
                detail: "This is useful for research editing, but PACS/DICOM workflows should use DICOM SEG.",
                affectedFeatures: [.dicomReferences]
            ))
        case .json:
            if hasVoxels {
                warnings.append(.init(
                    severity: .dataLoss,
                    title: "Voxel mask is not exported",
                    detail: "JSON export stores class metadata and 2D annotations. Export DICOM SEG, NIfTI, NRRD, or MHA for the lesion mask.",
                    affectedFeatures: [.voxelMask, .spatialGeometry]
                ))
            }
            if hasLandmarks {
                warnings.append(.init(
                    severity: .dataLoss,
                    title: "Landmarks are not included",
                    detail: "Use CSV or Tracer's native package to preserve landmark pairs.",
                    affectedFeatures: [.landmarks]
                ))
            }
        case .csv:
            if hasVoxels || hasAnnotations {
                warnings.append(.init(
                    severity: .dataLoss,
                    title: "CSV is landmarks only",
                    detail: "Segmentation voxels, classes, colors, and 2D annotations are not written to the landmark table.",
                    affectedFeatures: [.voxelMask, .segmentNames, .colors, .annotations]
                ))
            }
        }

        return warnings
    }
}

public enum AnnotationFormatCatalog {
    public static var supportedEntries: [AnnotationFormatGuideEntry] {
        LabelIO.Format.allCases.map { format in
            AnnotationFormatGuideEntry(
                id: format.id,
                name: format.rawValue,
                extensions: format.fileExtensions,
                support: format.support,
                usage: format.usageDescription,
                storedFeatures: format.storedFeatures,
                conversionNote: format.conversionNote
            )
        }
    }

    public static let guideOnlyEntries: [AnnotationFormatGuideEntry] = [
        AnnotationFormatGuideEntry(
            id: "dicom-sr",
            name: "DICOM SR / TID 1500",
            extensions: ["dcm"],
            support: .guideOnly,
            usage: "Clinical measurement report for SUV, HU, volume, radiomics, tracking identifiers, and method provenance.",
            storedFeatures: [.measurements, .dicomReferences, .hierarchy],
            conversionNote: "Pairs with DICOM SEG; it does not contain the voxel mask itself."
        ),
        AnnotationFormatGuideEntry(
            id: "dicom-gsps",
            name: "DICOM Presentation State / GSPS",
            extensions: ["dcm"],
            support: .guideOnly,
            usage: "Display annotations, shutters, overlays, and presentation intent for DICOM viewers.",
            storedFeatures: [.annotations, .dicomReferences],
            conversionNote: "Useful for display marks, not lesion segmentation masks."
        ),
        AnnotationFormatGuideEntry(
            id: "png-tiff-mask",
            name: "PNG/TIFF mask image or stack",
            extensions: ["png", "tif", "tiff"],
            support: .guideOnly,
            usage: "2D or slice-stack masks used in computer vision and some research pipelines.",
            storedFeatures: [.voxelMask],
            conversionNote: "Needs an external geometry source to become a reliable PET/CT 3D mask."
        ),
        AnnotationFormatGuideEntry(
            id: "coco",
            name: "COCO JSON",
            extensions: ["json"],
            support: .guideOnly,
            usage: "Computer-vision boxes, polygons, keypoints, and mask RLE for natural images.",
            storedFeatures: [.annotations, .hierarchy],
            conversionNote: "COCO masks/polygons do not carry DICOM voxel geometry by themselves."
        ),
        AnnotationFormatGuideEntry(
            id: "yolo",
            name: "YOLO TXT",
            extensions: ["txt"],
            support: .guideOnly,
            usage: "Normalized 2D detection boxes, and in newer variants segmentation polygons or pose points.",
            storedFeatures: [.annotations],
            conversionNote: "Boxes cannot recreate a PET/CT lesion mask."
        ),
        AnnotationFormatGuideEntry(
            id: "pascal-voc",
            name: "Pascal VOC XML",
            extensions: ["xml"],
            support: .guideOnly,
            usage: "2D image object-detection boxes and class labels.",
            storedFeatures: [.annotations, .segmentNames],
            conversionNote: "Good for boxes; not enough for 3D lesion segmentation."
        ),
        AnnotationFormatGuideEntry(
            id: "labelme",
            name: "LabelMe JSON",
            extensions: ["json"],
            support: .guideOnly,
            usage: "2D polygons, points, lines, rectangles, and image-level annotation metadata.",
            storedFeatures: [.annotations, .segmentNames],
            conversionNote: "Polygons need rasterization and image geometry to become masks."
        ),
        AnnotationFormatGuideEntry(
            id: "cvat",
            name: "CVAT XML/JSON",
            extensions: ["xml", "json"],
            support: .guideOnly,
            usage: "2D/Video annotation exchange for boxes, polygons, masks, tracks, and attributes.",
            storedFeatures: [.annotations, .segmentNames, .hierarchy],
            conversionNote: "Video/image coordinates are not enough for PET/CT voxel-space conversion."
        ),
        AnnotationFormatGuideEntry(
            id: "label-studio",
            name: "Label Studio JSON",
            extensions: ["json"],
            support: .guideOnly,
            usage: "General annotation export for images, text, audio, video, and custom tasks.",
            storedFeatures: [.annotations, .hierarchy],
            conversionNote: "Task schema decides what can be converted; medical voxel geometry is usually external."
        ),
        AnnotationFormatGuideEntry(
            id: "geojson",
            name: "GeoJSON",
            extensions: ["geojson", "json"],
            support: .guideOnly,
            usage: "Geospatial points, lines, and polygons.",
            storedFeatures: [.annotations, .hierarchy],
            conversionNote: "World-map coordinates do not map to DICOM patient coordinates without a custom transform."
        ),
        AnnotationFormatGuideEntry(
            id: "surface-mesh",
            name: "Surface Mesh",
            extensions: ["vtk", "vtp", "stl", "obj", "ply"],
            support: .guideOnly,
            usage: "3D surfaces for anatomy, organs, lesions, implants, or printable models.",
            storedFeatures: [.meshSurface, .spatialGeometry],
            conversionNote: "Mesh-to-mask requires rasterization; mask-to-mesh changes voxel boundaries into surfaces."
        ),
        AnnotationFormatGuideEntry(
            id: "freesurfer",
            name: "FreeSurfer labels",
            extensions: ["annot", "label", "mgz", "mgh"],
            support: .guideOnly,
            usage: "Neuroimaging cortical/parcellation labels and surface annotations.",
            storedFeatures: [.voxelMask, .segmentNames, .meshSurface],
            conversionNote: "Best handled with neuroimaging geometry and subject-space transforms."
        ),
        AnnotationFormatGuideEntry(
            id: "array-mask",
            name: "Array masks",
            extensions: ["npy", "npz", "h5", "hdf5", "mat"],
            support: .guideOnly,
            usage: "Raw numeric mask/probability arrays from ML and scientific Python/MATLAB workflows.",
            storedFeatures: [.voxelMask, .probabilityValues],
            conversionNote: "Array shape alone is not enough; spacing/origin/orientation must come from a sidecar or reference image."
        )
    ]

    public static var allEntries: [AnnotationFormatGuideEntry] {
        supportedEntries + guideOnlyEntries
    }
}
