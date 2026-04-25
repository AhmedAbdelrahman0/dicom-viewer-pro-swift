import Foundation

/// Curated registry of attenuation-correction backends. Modeled on
/// `LesionClassifierCatalog` and `NNUnetCatalog` — entries describe what
/// the model does + which backend runs it; the AC view model instantiates
/// the concrete `PETAttenuationCorrector` from the entry plus the user's
/// supplied paths.
///
/// Entries are deliberately metadata-only — they don't load weights at
/// startup. The first call to `makeCorrector(...)` boots the backend.
public enum PETACCatalog {
    public static let all: [Entry] = [
        deepACSubprocess,
        deepACDGX,
        pseudoCTSubprocess,
        mrACSubprocess
    ]

    public static func byID(_ id: String) -> Entry? {
        all.first { $0.id == id }
    }

    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: String
        public let displayName: String
        public let backend: Backend
        public let description: String
        public let provenance: String
        public let license: String
        /// Whether the backend reads an auxiliary CT or MR volume in
        /// addition to the NAC PET. Surfaced in the UI so the user knows
        /// to load + register an anatomical channel before running.
        public let requiresAnatomicalChannel: Bool
        /// Whether the entry can be instantiated from built-in defaults
        /// alone. `false` here means the user must point at a Python
        /// script + (for DGX) configure SSH first.
        public let requiresConfiguration: Bool
    }

    public enum Backend: String, Hashable, Sendable {
        case subprocess     // SubprocessPETACCorrector — local Python
        case dgxRemote      // RemotePETACCorrector — over SSH

        public var displayName: String {
            switch self {
            case .subprocess: return "Python subprocess"
            case .dgxRemote:  return "DGX Spark (remote)"
            }
        }
    }

    // MARK: - Curated entries

    /// Most common deployment shape: a user-supplied PyTorch / TF script
    /// that takes NAC PET as a NIfTI on stdin (file path passed on argv)
    /// and writes the AC PET as a NIfTI on stdout. Tracer wires the I/O.
    public static let deepACSubprocess = Entry(
        id: "deep-ac-subprocess",
        displayName: "Deep AC — local Python (NAC → AC)",
        backend: .subprocess,
        description: "Runs your trained NAC→AC PyTorch / TF model as a Python subprocess. Input/output as NIfTI files; the script reads `--input <path>` and `--output <path>` and produces an AC PET on the same grid.",
        provenance: "Bring your own trained checkpoint (e.g. Hwang 2018, Liu 2018, Spuhler 2020 architectures). No weights bundled.",
        license: "Depends on the user's model (research-only is typical).",
        requiresAnatomicalChannel: false,
        requiresConfiguration: true
    )

    /// Same script, executed on the user's DGX Spark over SSH. The script
    /// is expected to live on the DGX. PET volumes are scp'd up + back.
    /// Useful for cohort runs where local CPU/GPU isn't enough.
    public static let deepACDGX = Entry(
        id: "deep-ac-dgx",
        displayName: "Deep AC — DGX Spark (NAC → AC over SSH)",
        backend: .dgxRemote,
        description: "Runs the same NAC→AC script on your DGX Spark. Tracer scp's the NAC PET up, runs `python3 script --input … --output …`, and pulls the AC PET back.",
        provenance: "Bring your own trained checkpoint hosted on the DGX. Tracer doesn't ship weights.",
        license: "Depends on the user's model.",
        requiresAnatomicalChannel: false,
        requiresConfiguration: true
    )

    /// Two-stage approach: model generates a pseudo-CT from the NAC PET,
    /// then a standard CT-AC reconstruction is applied on the DGX (or
    /// locally if the user has the Siemens / Philips reconstruction
    /// toolchain installed). The user's script is responsible for both
    /// stages — Tracer just hands it the NAC PET and waits for the AC PET.
    public static let pseudoCTSubprocess = Entry(
        id: "pseudo-ct-ac-subprocess",
        displayName: "Pseudo-CT AC — local Python (PET → pseudo-CT → CT-AC PET)",
        backend: .subprocess,
        description: "Two-stage pipeline: a CycleGAN / U-Net generates a pseudo-CT from the NAC PET, then your reconstruction toolchain runs CT-AC. Tracer treats it as a single PET → PET transform; your wrapper script does the orchestration.",
        provenance: "Liu et al. 2018 / Armanious 2020 / Burgos 2014 — research workflow.",
        license: "Depends on the user's model + reconstruction software.",
        requiresAnatomicalChannel: false,
        requiresConfiguration: true
    )

    /// MR-PET hybrid scanners — model takes NAC PET + co-registered MR
    /// (T1 typical) and outputs the AC PET. Common on Siemens mMR and GE
    /// SIGNA PET/MR systems where CT-AC isn't available at all.
    public static let mrACSubprocess = Entry(
        id: "mr-ac-subprocess",
        displayName: "MR-AC PET — local Python (NAC PET + MR → AC PET)",
        backend: .subprocess,
        description: "MR-conditioned AC for PET-MR studies. Loads a co-registered MR (T1 typical) as channel 1 and the NAC PET as channel 0, returns the AC PET.",
        provenance: "Han 2017 / Hwang 2019 / Leynes 2018 MR-AC architectures.",
        license: "Depends on the user's model.",
        requiresAnatomicalChannel: true,
        requiresConfiguration: true
    )
}
