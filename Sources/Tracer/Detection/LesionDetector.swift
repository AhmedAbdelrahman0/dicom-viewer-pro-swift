import Foundation

/// Abstract interface for **lesion detection** — finds lesions in a volume
/// and emits per-detection records (bounding box, class label, confidence)
/// in one model call. Sits parallel to `LesionClassifier` but skips the
/// segmentation prerequisite: instead of `(volume, mask, classID, bounds)`
/// → label, you get `volume` → list of `(bounds, label)`.
///
/// Why this exists alongside the segment-then-classify pipeline:
///   • **Faster triage** — modern detectors (nnDetection, DeepLesion) are
///     trained end-to-end and skip the voxel-mask cost entirely.
///   • **No segmentation labels needed** — research datasets that only
///     have bounding-box annotations (DeepLesion, NIH-PE) are usable
///     without first solving the segmentation problem.
///   • **Joint detect+classify in one pass** — most modern detectors
///     output (box, class, confidence) tuples directly; no separate
///     classifier inference step.
///
/// Trade-offs vs segmentation:
///   • No volumetric SUV / TMTV stats (boxes ≠ masks).
///   • Detection misses are silent — easier than a segmentation miss
///     but harder to QA.
///   • Bounding boxes aren't suitable for radiotherapy planning or
///     RECIST volumetric response.
///
/// Concrete backends live alongside this file:
///   • `SubprocessLesionDetector` — local Python wrapper that reads a
///     NIfTI on argv and writes detections as JSON on stdout.
///   • `RemoteLesionDetector`     — same script + JSON contract over SSH
///     on the user's configured remote workstation.
public protocol LesionDetector: Sendable {
    /// Stable id used for cohort job records, chat routing, and the UI.
    var id: String { get }
    var displayName: String { get }
    /// Modalities the model was trained on. Empty = "any". Used by the
    /// panel to warn when the user runs an off-spec model on the
    /// loaded volume's modality.
    var supportedModalities: [Modality] { get }
    var provenance: String { get }
    var license: String { get }
    /// True for models that need a co-registered anatomical channel
    /// (CT or MR) on the same grid as the primary volume — e.g.
    /// PET-conditioned-on-CT detectors.
    var requiresAnatomicalChannel: Bool { get }

    /// Run detection. The caller may pass a co-registered anatomical
    /// channel (already resampled to the primary's grid); detectors
    /// that don't want one ignore it. Returns the full detection set
    /// for the volume — empty array means "no findings", not failure.
    func detect(volume: ImageVolume,
                anatomical: ImageVolume?,
                progress: @escaping @Sendable (String) -> Void)
        async throws -> [LesionDetection]
}

/// One detection record. Self-contained — carries the bounding box, the
/// model's class predictions (softmax across the catalog's classes), the
/// detection-vs-class confidence split (some models report them
/// separately), and an optional rationale for VLM/MedGemma-style
/// detectors that produce free text.
public struct LesionDetection: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Voxel-space bounding box in the same coordinates as the source
    /// volume. Inclusive on both ends (`minZ ≤ z ≤ maxZ`) — matches
    /// `MONAITransforms.VoxelBounds` so the existing classifier code
    /// can consume detections via the same bounds shape.
    public var bounds: MONAITransforms.VoxelBounds
    /// Class predictions sorted by probability descending. First entry
    /// is the model's top label.
    public var predictions: [LabelPrediction]
    /// "How sure am I that something is here at all" — distinct from
    /// the per-class probability. Some models output 1.0 here for any
    /// surviving detection (after NMS). 0–1 range.
    public var detectionConfidence: Double
    /// Optional anatomical region label produced by the model
    /// (e.g. "right lower lobe"). Nil for models that only emit
    /// class + box.
    public var anatomicalRegion: String?
    /// Free-text rationale — populated by VLM-style detectors
    /// (MedGemma, GPT-4V). Nil for traditional CNN detectors.
    public var rationale: String?
    /// Detector id that produced this record. Echoed for cohort report
    /// attribution and so multi-detector ensembles can be reasoned
    /// about per-row.
    public var detectorID: String

    public init(id: UUID = UUID(),
                bounds: MONAITransforms.VoxelBounds,
                predictions: [LabelPrediction] = [],
                detectionConfidence: Double = 1.0,
                anatomicalRegion: String? = nil,
                rationale: String? = nil,
                detectorID: String) {
        self.id = id
        self.bounds = bounds
        self.predictions = predictions.sorted { $0.probability > $1.probability }
        self.detectionConfidence = detectionConfidence
        self.anatomicalRegion = anatomicalRegion
        self.rationale = rationale
        self.detectorID = detectorID
    }

    /// Top class label, if any. Convenience for cohort CSV columns
    /// + UI summaries.
    public var topLabel: String? { predictions.first?.label }
    public var topProbability: Double { predictions.first?.probability ?? 0 }

    /// Voxel-space center of the bounding box. Useful for "click to
    /// jump to this detection's slice" navigation.
    public var centerVoxel: (z: Int, y: Int, x: Int) {
        (z: (bounds.minZ + bounds.maxZ) / 2,
         y: (bounds.minY + bounds.maxY) / 2,
         x: (bounds.minX + bounds.maxX) / 2)
    }

    /// Bounding-box volume in voxels.
    public var voxelCount: Int {
        let dz = bounds.maxZ - bounds.minZ + 1
        let dy = bounds.maxY - bounds.minY + 1
        let dx = bounds.maxX - bounds.minX + 1
        return max(0, dz) * max(0, dy) * max(0, dx)
    }

    /// Bounding-box volume in mm³ given the parent volume's spacing.
    public func volumeMM3(spacing: (x: Double, y: Double, z: Double)) -> Double {
        let dz = max(0, bounds.maxZ - bounds.minZ + 1)
        let dy = max(0, bounds.maxY - bounds.minY + 1)
        let dx = max(0, bounds.maxX - bounds.minX + 1)
        return Double(dx) * spacing.x * Double(dy) * spacing.y * Double(dz) * spacing.z
    }
}

public enum DetectionError: Swift.Error, LocalizedError, Sendable {
    case anatomicalRequired
    case anatomicalGridMismatch(String)
    case modelUnavailable(String)
    case inferenceFailed(String)
    case malformedOutput(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .anatomicalRequired:
            return "This detector needs a co-registered CT or MR channel — load one before running."
        case .anatomicalGridMismatch(let m):
            return "Anatomical channel grid mismatch: \(m). Resample to the primary volume's grid first."
        case .modelUnavailable(let m):
            return "Detector model unavailable: \(m)"
        case .inferenceFailed(let m):
            return "Detector inference failed: \(m)"
        case .malformedOutput(let m):
            return "Detector output couldn't be parsed: \(m)"
        case .cancelled:
            return "Detection was cancelled."
        }
    }
}

/// JSON shape that subprocess + remote backends agree on for the
/// Python wrapper script's stdout. Each detection is one entry in the
/// `detections` array.
///
/// Wrapper script contract (Python side):
/// ```python
/// # Input on argv:  --input /tmp/in.nii.gz [--anatomical /tmp/ct.nii.gz]
/// # Output on stdout (UTF-8 JSON):
/// {
///   "detections": [
///     {
///       "bounds": [minZ, maxZ, minY, maxY, minX, maxX],
///       "predictions": [
///         {"label": "lung_nodule_malignant", "probability": 0.87},
///         {"label": "lung_nodule_benign",    "probability": 0.13}
///       ],
///       "detection_confidence": 0.92,         // optional
///       "anatomical_region": "right_upper_lobe", // optional
///       "rationale": "..."                    // optional
///     },
///     ...
///   ]
/// }
/// ```
///
/// Tracer parses this into `[LesionDetection]` and either drops the
/// boxes onto the viewer or writes them as a cohort sidecar.
public struct DetectionWireFormat: Codable, Sendable {
    public struct WireDetection: Codable, Sendable {
        public var bounds: [Int]   // [minZ, maxZ, minY, maxY, minX, maxX]
        public var predictions: [WirePrediction]
        public var detection_confidence: Double?
        public var anatomical_region: String?
        public var rationale: String?
    }

    public struct WirePrediction: Codable, Sendable {
        public var label: String
        public var probability: Double
    }

    public var detections: [WireDetection]

    public init(detections: [WireDetection] = []) {
        self.detections = detections
    }

    /// Convert wire format into the in-app `LesionDetection` model. Out-of-
    /// range bounds + missing-prediction rows are dropped silently with
    /// a log line rather than throwing — partial detection results are
    /// still useful and we don't want one bad box to kill a whole study.
    public func toDetections(detectorID: String, volume: ImageVolume) -> [LesionDetection] {
        var out: [LesionDetection] = []
        out.reserveCapacity(detections.count)
        for raw in detections {
            guard raw.bounds.count == 6 else {
                NSLog("LesionDetector: dropping detection with malformed bounds: \(raw.bounds)")
                continue
            }
            // Clamp to the volume's voxel range. A model that emits a box
            // running off the volume edge gets clipped rather than rejected.
            let minZ = Swift.max(0, Swift.min(volume.depth - 1, raw.bounds[0]))
            let maxZ = Swift.max(minZ, Swift.min(volume.depth - 1, raw.bounds[1]))
            let minY = Swift.max(0, Swift.min(volume.height - 1, raw.bounds[2]))
            let maxY = Swift.max(minY, Swift.min(volume.height - 1, raw.bounds[3]))
            let minX = Swift.max(0, Swift.min(volume.width - 1, raw.bounds[4]))
            let maxX = Swift.max(minX, Swift.min(volume.width - 1, raw.bounds[5]))
            let bounds = MONAITransforms.VoxelBounds(
                minZ: minZ, maxZ: maxZ,
                minY: minY, maxY: maxY,
                minX: minX, maxX: maxX
            )
            let preds = raw.predictions.map {
                LabelPrediction(label: $0.label, probability: $0.probability)
            }
            out.append(LesionDetection(
                bounds: bounds,
                predictions: preds,
                detectionConfidence: raw.detection_confidence ?? 1.0,
                anatomicalRegion: raw.anatomical_region,
                rationale: raw.rationale,
                detectorID: detectorID
            ))
        }
        return out
    }
}

/// Helper validators shared across detection backends — same role as
/// `PETACUtilities` for the AC family.
public enum DetectionUtilities {
    public static func validateInputs(volume: ImageVolume,
                                      anatomical: ImageVolume?,
                                      requiresAnatomical: Bool) throws {
        if requiresAnatomical, anatomical == nil {
            throw DetectionError.anatomicalRequired
        }
        if let anatomical {
            guard anatomical.width == volume.width,
                  anatomical.height == volume.height,
                  anatomical.depth == volume.depth else {
                throw DetectionError.anatomicalGridMismatch(
                    "primary is \(volume.width)x\(volume.height)x\(volume.depth), anatomical is \(anatomical.width)x\(anatomical.height)x\(anatomical.depth)"
                )
            }
        }
    }
}
