import Foundation

public enum Colormap: String, CaseIterable, Identifiable {
    case hot, petRainbow = "pet_rainbow", jet, bone, coolWarm = "cool_warm"
    case fire, ice, grayscale, invertedGray = "inverted_gray"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hot:          return "Hot"
        case .petRainbow:   return "PET Rainbow"
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
    @Published public var colormap: Colormap = .hot
    @Published public var overlayWindow: Double = 6
    @Published public var overlayLevel: Double = 3
    @Published public var overlayVisible: Bool = true

    /// Resampled overlay in the base's grid (optional). If nil, overlay is
    /// used directly (assumes matching geometry).
    @Published public var resampledOverlay: ImageVolume?

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
}
