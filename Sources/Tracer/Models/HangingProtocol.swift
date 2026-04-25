import Foundation

public enum SlicePlane: Int, CaseIterable, Identifiable, Codable, Sendable {
    case sagittal = 0
    case coronal = 1
    case axial = 2

    public var id: Int { rawValue }
    public var axis: Int { rawValue }

    public var displayName: String {
        switch self {
        case .axial: return "Axial"
        case .sagittal: return "Sagittal"
        case .coronal: return "Coronal"
        }
    }

    public var shortName: String {
        switch self {
        case .axial: return "AX"
        case .sagittal: return "SAG"
        case .coronal: return "COR"
        }
    }
}

public enum SliceDisplayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case fused
    case ctOnly
    case petOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fused: return "Fused"
        case .ctOnly: return "CT"
        case .petOnly: return "PET"
        }
    }
}

public enum HangingPaneKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case fused
    case ctOnly
    case petOnly
    case petMIP

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fused: return "Fused"
        case .ctOnly: return "CT only"
        case .petOnly: return "PET only"
        case .petMIP: return "PET MIP"
        }
    }

    public var shortName: String {
        switch self {
        case .fused: return "Fused"
        case .ctOnly: return "CT"
        case .petOnly: return "PET"
        case .petMIP: return "MIP"
        }
    }

    public var systemImage: String {
        switch self {
        case .fused: return "square.2.layers.3d"
        case .ctOnly: return "waveform.path.ecg.rectangle"
        case .petOnly: return "flame"
        case .petMIP: return "cube.transparent"
        }
    }

    public var sliceDisplayMode: SliceDisplayMode? {
        switch self {
        case .fused: return .fused
        case .ctOnly: return .ctOnly
        case .petOnly: return .petOnly
        case .petMIP: return nil
        }
    }
}

public struct HangingPaneConfiguration: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var kind: HangingPaneKind
    public var plane: SlicePlane

    public init(id: UUID = UUID(), kind: HangingPaneKind, plane: SlicePlane) {
        self.id = id
        self.kind = kind
        self.plane = plane
    }

    public static let defaultPETCT: [HangingPaneConfiguration] = [
        HangingPaneConfiguration(kind: .fused, plane: .axial),
        HangingPaneConfiguration(kind: .ctOnly, plane: .axial),
        HangingPaneConfiguration(kind: .petOnly, plane: .axial),
        HangingPaneConfiguration(kind: .petMIP, plane: .coronal)
    ]
}
