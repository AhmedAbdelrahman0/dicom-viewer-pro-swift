import Foundation

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
    @Published public var isGeometryResampled: Bool = false
    @Published public var registrationNote: String = "Assumes aligned geometry"
    @Published public var registrationQuality: RegistrationQualityComparison?

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
}
