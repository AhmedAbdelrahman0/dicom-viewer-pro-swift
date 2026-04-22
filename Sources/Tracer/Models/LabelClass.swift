import Foundation
import SwiftUI

/// A labeled class used inside a `LabelMap`.
public struct LabelClass: Identifiable, Equatable, Hashable, Sendable {
    public var id = UUID()

    /// Integer ID stored in the voxel grid (1–65535).
    public var labelID: UInt16

    /// Display name (e.g., "Liver", "GTV", "Lesion 1").
    public var name: String

    /// SNOMED-like category for grouping ("Organ", "Vessel", "Bone", "Pathology", "RT", …).
    public var category: LabelCategory

    /// Display color (RGBA).
    public var color: Color

    /// Optional DICOM code (for RTSTRUCT export).
    public var dicomCode: String?

    /// Optional FMA anatomy ID.
    public var fmaID: String?

    /// Free-text description.
    public var notes: String = ""

    /// Suggested default opacity when rendered.
    public var opacity: Double = 0.5

    /// Whether this class is visible.
    public var visible: Bool = true

    public init(labelID: UInt16 = 0,
                name: String,
                category: LabelCategory,
                color: Color,
                dicomCode: String? = nil,
                fmaID: String? = nil,
                notes: String = "",
                opacity: Double = 0.5,
                visible: Bool = true) {
        self.labelID = labelID
        self.name = name
        self.category = category
        self.color = color
        self.dicomCode = dicomCode
        self.fmaID = fmaID
        self.notes = notes
        self.opacity = opacity
        self.visible = visible
    }

    public static func == (lhs: LabelClass, rhs: LabelClass) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Top-level categories for organizing labels.
public enum LabelCategory: String, CaseIterable, Identifiable, Sendable {
    case organ = "Organ"
    case vessel = "Vessel"
    case bone = "Bone"
    case brain = "Brain Structure"
    case muscle = "Muscle"
    case cardiac = "Cardiac"
    case pathology = "Pathology"
    case lesion = "Lesion"
    case tumor = "Tumor"
    case rtStructure = "RT Structure"
    case rtTarget = "RT Target"
    case rtOAR = "RT Organ at Risk"
    case petHotspot = "PET Hotspot"
    case nuclearUptake = "Nuclear Uptake"
    case custom = "Custom"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .organ:         return "heart.text.square"
        case .vessel:        return "waveform.path"
        case .bone:          return "figure.walk"
        case .brain:         return "brain.head.profile"
        case .muscle:        return "figure.strengthtraining.traditional"
        case .cardiac:       return "heart.fill"
        case .pathology:     return "exclamationmark.triangle"
        case .lesion:        return "scope"
        case .tumor:         return "circle.circle"
        case .rtStructure:   return "target"
        case .rtTarget:      return "scope"
        case .rtOAR:         return "shield.lefthalf.filled"
        case .petHotspot:    return "flame"
        case .nuclearUptake: return "sparkles"
        case .custom:        return "pencil.tip"
        }
    }
}

// MARK: - Color helpers

public extension Color {
    /// Build a Color from 0–255 RGB triples (matching TotalSegmentator colormap).
    init(r: Int, g: Int = -1, b: Int = -1, _ g2: Int = -1, _ b2: Int = -1) {
        let green = g >= 0 ? g : g2
        let blue  = b >= 0 ? b : b2
        self.init(.displayP3,
                  red: Double(r) / 255.0,
                  green: Double(green) / 255.0,
                  blue: Double(blue) / 255.0,
                  opacity: 1.0)
    }

    /// Convert to 3-byte RGB for rendering to CGImage.
    func rgbBytes() -> (UInt8, UInt8, UInt8) {
        // NB: SwiftUI Color -> raw components is platform-specific; we use
        // CGColor conversion. On macOS we use NSColor; on iOS UIColor.
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.displayP3) ?? NSColor.white
        return (UInt8(max(0, min(255, ns.redComponent * 255))),
                UInt8(max(0, min(255, ns.greenComponent * 255))),
                UInt8(max(0, min(255, ns.blueComponent * 255))))
        #elseif canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt8(max(0, min(255, r * 255))),
                UInt8(max(0, min(255, g * 255))),
                UInt8(max(0, min(255, b * 255))))
        #else
        return (255, 255, 255)
        #endif
    }
}
