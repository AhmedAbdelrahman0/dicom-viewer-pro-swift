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
    case primary
    case fused
    case ctOnly
    case petOnly
    case mrT1
    case mrT2
    case mrFLAIR
    case mrDWI
    case mrADC
    case mrPost
    case mrOther

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .primary: return "Primary"
        case .fused: return "Fused"
        case .ctOnly: return "CT"
        case .petOnly: return "PET"
        case .mrT1: return "MR T1"
        case .mrT2: return "MR T2"
        case .mrFLAIR: return "MR FLAIR"
        case .mrDWI: return "MR DWI"
        case .mrADC: return "MR ADC"
        case .mrPost: return "MR Post"
        case .mrOther: return "MR"
        }
    }
}

public enum HangingPaneKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case primary
    case fused
    case ctOnly
    case petOnly
    case petMIP
    case mrT1
    case mrT2
    case mrFLAIR
    case mrDWI
    case mrADC
    case mrPost
    case mrOther

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .primary: return "Primary"
        case .fused: return "Fused"
        case .ctOnly: return "CT only"
        case .petOnly: return "PET only"
        case .petMIP: return "PET MIP"
        case .mrT1: return "MR T1"
        case .mrT2: return "MR T2"
        case .mrFLAIR: return "MR FLAIR"
        case .mrDWI: return "MR DWI"
        case .mrADC: return "MR ADC"
        case .mrPost: return "MR Post"
        case .mrOther: return "MR other"
        }
    }

    public var shortName: String {
        switch self {
        case .primary: return "Pri"
        case .fused: return "Fused"
        case .ctOnly: return "CT"
        case .petOnly: return "PET"
        case .petMIP: return "MIP"
        case .mrT1: return "T1"
        case .mrT2: return "T2"
        case .mrFLAIR: return "FLAIR"
        case .mrDWI: return "DWI"
        case .mrADC: return "ADC"
        case .mrPost: return "POST"
        case .mrOther: return "MR"
        }
    }

    public var systemImage: String {
        switch self {
        case .primary: return "viewfinder"
        case .fused: return "square.2.layers.3d"
        case .ctOnly: return "waveform.path.ecg.rectangle"
        case .petOnly: return "flame"
        case .petMIP: return "cube.transparent"
        case .mrT1: return "brain.head.profile"
        case .mrT2: return "brain"
        case .mrFLAIR: return "sparkles.rectangle.stack"
        case .mrDWI: return "waveform.path"
        case .mrADC: return "map"
        case .mrPost: return "drop.triangle"
        case .mrOther: return "rectangle.stack"
        }
    }

    public var sliceDisplayMode: SliceDisplayMode? {
        switch self {
        case .primary: return .primary
        case .fused: return .fused
        case .ctOnly: return .ctOnly
        case .petOnly: return .petOnly
        case .petMIP: return nil
        case .mrT1: return .mrT1
        case .mrT2: return .mrT2
        case .mrFLAIR: return .mrFLAIR
        case .mrDWI: return .mrDWI
        case .mrADC: return .mrADC
        case .mrPost: return .mrPost
        case .mrOther: return .mrOther
        }
    }
}

/// Workstation viewport grid. Stored as columns × rows because that is how
/// radiology hanging protocols are usually described: 2×1, 2×2, 4×4, etc.
public struct HangingGridLayout: Equatable, Codable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, min(8, columns))
        self.rows = max(1, min(8, rows))
    }

    public var paneCount: Int {
        rows * columns
    }

    public var displayName: String {
        paneCount == 1 ? "1 viewport" : "\(columns)x\(rows)"
    }

    public static let one = HangingGridLayout(columns: 1, rows: 1)
    public static let twoByOne = HangingGridLayout(columns: 2, rows: 1)
    public static let oneByTwo = HangingGridLayout(columns: 1, rows: 2)
    public static let twoByTwo = HangingGridLayout(columns: 2, rows: 2)
    public static let threeByTwo = HangingGridLayout(columns: 3, rows: 2)
    public static let fourByFour = HangingGridLayout(columns: 4, rows: 4)
    public static let eightByEight = HangingGridLayout(columns: 8, rows: 8)

    public static let defaultPETCT = twoByTwo

    public static let presets: [HangingGridLayout] = [
        .one,
        .twoByOne,
        .oneByTwo,
        .twoByTwo,
        .threeByTwo,
        .fourByFour,
        .eightByEight
    ]
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

    public static let defaultMRI: [HangingPaneConfiguration] = [
        HangingPaneConfiguration(kind: .mrT1, plane: .axial),
        HangingPaneConfiguration(kind: .mrT2, plane: .axial),
        HangingPaneConfiguration(kind: .mrFLAIR, plane: .axial),
        HangingPaneConfiguration(kind: .mrDWI, plane: .axial),
        HangingPaneConfiguration(kind: .mrADC, plane: .axial),
        HangingPaneConfiguration(kind: .mrPost, plane: .coronal)
    ]

    public static let defaultPETMR: [HangingPaneConfiguration] = [
        HangingPaneConfiguration(kind: .fused, plane: .axial),
        HangingPaneConfiguration(kind: .mrT1, plane: .axial),
        HangingPaneConfiguration(kind: .mrT2, plane: .axial),
        HangingPaneConfiguration(kind: .petOnly, plane: .axial),
        HangingPaneConfiguration(kind: .petMIP, plane: .coronal),
        HangingPaneConfiguration(kind: .mrFLAIR, plane: .axial)
    ]

    public static let defaultUnified: [HangingPaneConfiguration] = [
        HangingPaneConfiguration(kind: .fused, plane: .axial),
        HangingPaneConfiguration(kind: .ctOnly, plane: .axial),
        HangingPaneConfiguration(kind: .petOnly, plane: .axial),
        HangingPaneConfiguration(kind: .petMIP, plane: .coronal),
        HangingPaneConfiguration(kind: .mrT1, plane: .axial),
        HangingPaneConfiguration(kind: .mrT2, plane: .axial),
        HangingPaneConfiguration(kind: .mrFLAIR, plane: .axial),
        HangingPaneConfiguration(kind: .primary, plane: .sagittal)
    ]

    public static func defaultPane(at index: Int) -> HangingPaneConfiguration {
        let defaults = defaultPETCT
        if defaults.indices.contains(index) {
            return defaults[index]
        }
        let planes = SlicePlane.allCases
        return HangingPaneConfiguration(
            kind: .primary,
            plane: planes[index % planes.count]
        )
    }
}
