import Foundation
import simd

public enum Colormap: String, CaseIterable, Identifiable {
    case tracerPET = "tracer_pet", petRainbow = "pet_rainbow", petHotIron = "pet_hot_iron", petMagma = "pet_magma", petViridis = "pet_viridis"
    case hot, jet, bone, coolWarm = "cool_warm"
    case fire, ice, grayscale, invertedGray = "inverted_gray"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tracerPET:    return "Tracer PET"
        case .hot:          return "Hot"
        case .petRainbow:   return "PET Rainbow"
        case .petHotIron:   return "PET Hot Iron"
        case .petMagma:     return "PET Magma"
        case .petViridis:   return "PET Viridis"
        case .jet:          return "Jet"
        case .bone:         return "Bone"
        case .coolWarm:     return "Cool/Warm"
        case .fire:         return "Fire"
        case .ice:          return "Ice"
        case .grayscale:    return "Grayscale"
        case .invertedGray: return "Inverted Gray"
        }
    }
}

/// A paired set of volumes for fusion display (e.g. CT + PET).
public final class FusionPair: ObservableObject {
    @Published public var baseVolume: ImageVolume
    @Published public var overlayVolume: ImageVolume

    @Published public var opacity: Double = 0.5
    @Published public var colormap: Colormap = .tracerPET
    @Published public var overlayWindow: Double = 6
    @Published public var overlayLevel: Double = 3
    @Published public var overlayVisible: Bool = true

    /// Resampled overlay in the base's grid (optional). If nil, overlay is
    /// used directly (assumes matching geometry).
    @Published public var resampledOverlay: ImageVolume?
    /// Overlay resampled by scanner geometry / registration before any
    /// operator-side manual translation is applied.
    @Published public var registrationResampledOverlay: ImageVolume?
    @Published public var isGeometryResampled: Bool = false
    @Published public var registrationNote: String = "Assumes aligned geometry"
    @Published public var registrationDiagnostics: [String] = []
    @Published public var registrationQuality: RegistrationQualityComparison?
    @Published public var manualTranslationMM = SIMD3<Double>(0, 0, 0)
    @Published public var manualRotationDegrees = SIMD3<Double>(0, 0, 0)
    @Published public var manualScale: Double = 1

    public init(base: ImageVolume, overlay: ImageVolume) {
        self.baseVolume = base
        self.overlayVolume = overlay
    }

    public var fusionTypeLabel: String {
        let bm = Modality.normalize(baseVolume.modality).displayName
        let om = Modality.normalize(overlayVolume.modality).displayName
        return "\(om) / \(bm)"
    }

    public var displayedOverlay: ImageVolume { resampledOverlay ?? overlayVolume }

    public var isPETCT: Bool {
        Modality.normalize(baseVolume.modality) == .CT &&
        Modality.normalize(overlayVolume.modality) == .PT
    }

    public var isPETMR: Bool {
        Modality.normalize(baseVolume.modality) == .MR &&
        Modality.normalize(overlayVolume.modality) == .PT
    }

    public var baseGridLabel: String {
        "\(baseVolume.width)x\(baseVolume.height)x\(baseVolume.depth)"
    }

    public var overlayGridLabel: String {
        "\(overlayVolume.width)x\(overlayVolume.height)x\(overlayVolume.depth)"
    }

    public var displayedOverlayGridLabel: String {
        "\(displayedOverlay.width)x\(displayedOverlay.height)x\(displayedOverlay.depth)"
    }

    public var manualTranslationLabel: String {
        String(format: "X %.1f / Y %.1f / Z %.1f mm",
               manualTranslationMM.x,
               manualTranslationMM.y,
               manualTranslationMM.z)
    }

    public var manualRotationLabel: String {
        String(format: "RX %.1f° / RY %.1f° / RZ %.1f°",
               manualRotationDegrees.x,
               manualRotationDegrees.y,
               manualRotationDegrees.z)
    }

    public var manualScaleLabel: String {
        String(format: "%.2fx", manualScale)
    }

    public var hasManualTranslation: Bool {
        simd_length(manualTranslationMM) > 0.001
    }

    public var hasManualTransform: Bool {
        hasManualTranslation ||
        simd_length(manualRotationDegrees) > 0.001 ||
        abs(manualScale - 1) > 0.001
    }
}
