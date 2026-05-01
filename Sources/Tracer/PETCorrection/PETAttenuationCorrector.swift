import Foundation

/// Abstract interface for **attenuation correction (AC)** of a PET volume.
///
/// Tracer treats AC as a "PET → PET" image-to-image transform: a
/// non-attenuation-corrected PET (NAC PET) goes in, an attenuation-corrected
/// PET (AC PET) comes out on the same voxel grid. The transform may use an
/// auxiliary anatomical channel (CT or MR) when the model wants one — most
/// published deep-AC networks are NAC-PET-only, but a handful (e.g. the
/// MR-PET MAC family) condition on co-registered MR.
///
/// Why this matters clinically:
///   • CT-less PET — when the CT is corrupted (motion / metal artifacts) or
///     wasn't acquired (PET-MR scanners without proper µ-map), the PET is
///     un-quantitative until AC is reconstructed by some other route.
///   • Dynamic PET early frames — short frames don't have enough counts to
///     recompute CT-AC; a model-based AC keeps the time-series quantitative.
///   • Cohort harmonization — running a single AC model across 2000 PET/CTs
///     gives every study the same AC convention, removing scanner-specific
///     reconstruction drift.
///
/// Concrete backends live alongside this file:
///   • `SubprocessPETACCorrector` — local Python script (PyTorch / TF). User
///     supplies the script path + an env if needed.
///   • `RemotePETACCorrector`     — same Python script but executed on the
///     user's DGX Spark over SSH.
///
/// Adding a CoreML backend is a follow-up — most public deep-AC models are
/// PyTorch and converting them to CoreML is non-trivial (3D U-Nets with
/// custom blocks). Subprocess + DGX cover the realistic deployment paths.
public protocol PETAttenuationCorrector: Sendable {
    /// Stable id for routing / config / cohort job records.
    var id: String { get }
    var displayName: String { get }
    /// Free-text provenance for the report and the audit trail —
    /// "Hwang et al. 2018 NAC→AC U-Net, research-only Apache-2.0".
    var provenance: String { get }
    /// Human-readable license summary so users can't accidentally treat a
    /// research-only model as an FDA-cleared one.
    var license: String { get }
    /// `true` when the model needs an auxiliary anatomical channel
    /// (typically co-registered CT or MR) in addition to the NAC PET.
    var requiresAnatomicalChannel: Bool { get }

    /// Run AC. `nacPET` is the input non-attenuation-corrected PET.
    /// `anatomical` is an optional CT or MR channel — must already be
    /// resampled onto the PET grid by the caller. The output `ImageVolume`
    /// uses the same dims/spacing/origin as `nacPET`; intensities are in
    /// SUV-scaled units when the model produces them, raw counts otherwise.
    func attenuationCorrect(nacPET: ImageVolume,
                            anatomical: ImageVolume?,
                            progress: @escaping @Sendable (String) -> Void) async throws -> PETACResult
}

/// Output of one AC run.
public struct PETACResult: Sendable {
    /// The corrected PET volume on the same grid as the input NAC PET.
    public let acPET: ImageVolume
    /// Wall-clock duration for the call. Used by the cohort runner + UI.
    public let durationSeconds: TimeInterval
    /// Backend id that produced the result. Echoed into the result volume's
    /// `seriesDescription` so users (and downstream pipelines) can tell at
    /// a glance which AC method was applied.
    public let correctorID: String
    /// Optional log lines from the model (warnings about clipping, the
    /// model's confidence in its own prediction, etc.). Surfaced into the
    /// status panel + the cohort error message field.
    public let logSnippet: String?

    public init(acPET: ImageVolume,
                durationSeconds: TimeInterval = 0,
                correctorID: String,
                logSnippet: String? = nil) {
        self.acPET = acPET
        self.durationSeconds = durationSeconds
        self.correctorID = correctorID
        self.logSnippet = logSnippet
    }
}

public enum PETACError: Swift.Error, LocalizedError, Sendable {
    case nonPETInput(String)
    case anatomicalRequired
    case anatomicalGridMismatch(String)
    case modelUnavailable(String)
    case inferenceFailed(String)
    case outputGridMismatch(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .nonPETInput(let m):
            return "Attenuation correction expects a PET volume; got \(m)."
        case .anatomicalRequired:
            return "This AC model needs a co-registered CT or MR channel — load one before running."
        case .anatomicalGridMismatch(let m):
            return "Anatomical channel grid mismatch: \(m). Resample to the PET grid first."
        case .modelUnavailable(let m):
            return "AC model unavailable: \(m)"
        case .inferenceFailed(let m):
            return "AC inference failed: \(m)"
        case .outputGridMismatch(let m):
            return "AC model produced a volume on the wrong grid: \(m)"
        case .cancelled:
            return "AC was cancelled."
        }
    }
}

/// Helper functions shared across AC backends.
public enum PETACUtilities {
    /// Sanity-check the inputs before we shell out / upload anything. Done
    /// once, in one place, so backend-specific code stays focused.
    public static func validateInputs(nacPET: ImageVolume,
                                      anatomical: ImageVolume?,
                                      requiresAnatomical: Bool) throws {
        if Modality.normalize(nacPET.modality) != .PT {
            throw PETACError.nonPETInput(nacPET.modality.isEmpty ? "<unknown>" : nacPET.modality)
        }
        if requiresAnatomical, anatomical == nil {
            throw PETACError.anatomicalRequired
        }
        if let anatomical {
            guard anatomical.width == nacPET.width,
                  anatomical.height == nacPET.height,
                  anatomical.depth == nacPET.depth else {
                throw PETACError.anatomicalGridMismatch(
                    "PET is \(nacPET.width)x\(nacPET.height)x\(nacPET.depth), anatomical is \(anatomical.width)x\(anatomical.height)x\(anatomical.depth)"
                )
            }
        }
    }

    /// Build the AC PET volume from the model's predicted pixel buffer.
    /// Preserves geometry, patient/study UIDs, and the SUV scale; tags the
    /// `seriesDescription` so downstream code can tell NAC and AC apart in
    /// a fusion picker / volume browser.
    public static func makeACVolume(from pixels: [Float],
                                    sourceNAC: ImageVolume,
                                    correctorID: String) throws -> ImageVolume {
        let expectedVoxelCount = sourceNAC.depth * sourceNAC.height * sourceNAC.width
        guard pixels.count == expectedVoxelCount else {
            throw PETACError.outputGridMismatch(
                "model returned \(pixels.count) voxels, expected \(expectedVoxelCount)"
            )
        }
        let baseDescription = sourceNAC.seriesDescription.isEmpty
            ? "PET (AC)"
            : "\(sourceNAC.seriesDescription) — AC"
        return ImageVolume(
            pixels: pixels,
            depth: sourceNAC.depth,
            height: sourceNAC.height,
            width: sourceNAC.width,
            spacing: sourceNAC.spacing,
            origin: sourceNAC.origin,
            direction: sourceNAC.direction,
            modality: sourceNAC.modality,
            // New seriesUID — this is a derived series, not the original.
            // Downstream code (PACS index, recents, fusion picker) uses
            // the seriesUID as primary key, so collisions would silently
            // hide the AC volume behind the NAC.
            seriesUID: "\(sourceNAC.seriesUID).ac.\(UUID().uuidString.prefix(8))",
            studyUID: sourceNAC.studyUID,
            patientID: sourceNAC.patientID,
            patientName: sourceNAC.patientName,
            seriesDescription: "\(baseDescription) [\(correctorID)]",
            studyDescription: sourceNAC.studyDescription,
            suvScaleFactor: sourceNAC.suvScaleFactor,
            sourceFiles: []
        )
    }
}
