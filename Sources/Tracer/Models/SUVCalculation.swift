import Foundation

public enum SUVCalculationMode: String, CaseIterable, Identifiable {
    case storedSUV
    case manualScale
    case bodyWeight
    case leanBodyMass
    case bodySurfaceArea

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .storedSUV: return "Stored SUV"
        case .manualScale: return "Manual Factor"
        case .bodyWeight: return "SUVbw"
        case .leanBodyMass: return "SUL"
        case .bodySurfaceArea: return "SUVbsa"
        }
    }
}

public enum PETActivityUnit: String, CaseIterable, Identifiable {
    case bqml
    case kbqml
    case mbqml
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bqml: return "Bq/mL"
        case .kbqml: return "kBq/mL"
        case .mbqml: return "MBq/mL"
        case .custom: return "Custom"
        }
    }
}

public enum BiologicalSexForSUV: String, CaseIterable, Identifiable {
    case male
    case female

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        }
    }
}

public struct SUVCalculationSettings: Equatable {
    public var mode: SUVCalculationMode = .storedSUV
    public var activityUnit: PETActivityUnit = .bqml
    public var customBqPerMLPerStoredUnit: Double = 1
    public var manualScaleFactor: Double = 1
    public var patientWeightKg: Double = 70
    public var patientHeightCm: Double = 170
    public var injectedDoseMBq: Double = 370
    public var residualDoseMBq: Double = 0
    public var sex: BiologicalSexForSUV = .male

    public init() {}

    public var effectiveInjectedDoseMBq: Double {
        max(0.000001, injectedDoseMBq - residualDoseMBq)
    }

    public func suv(forStoredValue rawValue: Double) -> Double {
        switch mode {
        case .storedSUV:
            return rawValue
        case .manualScale:
            return rawValue * manualScaleFactor
        case .bodyWeight:
            return activityBqPerML(rawValue) * patientWeightKg * 1_000 / effectiveInjectedDoseBq
        case .leanBodyMass:
            return activityBqPerML(rawValue) * leanBodyMassKg * 1_000 / effectiveInjectedDoseBq
        case .bodySurfaceArea:
            return activityBqPerML(rawValue) * bodySurfaceAreaM2 * 10_000 / effectiveInjectedDoseBq
        }
    }

    /// Volume-aware SUV transform.
    ///
    /// The global settings can't know which specific volume a caller wants
    /// to quantify — and in `.storedSUV` mode the raw pixel values are only
    /// meaningful when the volume itself carries a DICOM-baked
    /// `suvScaleFactor`. This overload honours that per-volume scale when
    /// present so the PET Engine, the TMTV report, and the viewer probe can
    /// all pull SUV numbers through a single code path without each
    /// reimplementing the "stored + scale factor" fallback.
    ///
    /// Precedence for `.storedSUV`:
    ///   1. If `volume.suvScaleFactor` is set, use `raw × scale`.
    ///   2. Otherwise, fall through to the mode-based formula (raw counts).
    ///
    /// All other modes ignore the volume's stored scale — the user has
    /// explicitly asked for a derived SUV (bodyWeight / SUL / BSA / manual).
    public func suv(forStoredValue rawValue: Double, volume: ImageVolume) -> Double {
        if mode == .storedSUV, let scale = volume.suvScaleFactor {
            return rawValue * scale
        }
        return suv(forStoredValue: rawValue)
    }

    public var scaleDescription: String {
        switch mode {
        case .storedSUV:
            return "Stored pixel values are treated as SUV."
        case .manualScale:
            return "SUV = stored value x \(format(manualScaleFactor))."
        case .bodyWeight:
            return "SUVbw from activity concentration, weight, and injected dose."
        case .leanBodyMass:
            return "SUL from activity concentration, lean body mass, and injected dose."
        case .bodySurfaceArea:
            return "SUVbsa from activity concentration, BSA, and injected dose."
        }
    }

    public var leanBodyMassKg: Double {
        let weight = max(patientWeightKg, 0.001)
        let height = max(patientHeightCm, 0.001)
        switch sex {
        case .male:
            return max(0, 1.10 * weight - 128 * pow(weight / height, 2))
        case .female:
            return max(0, 1.07 * weight - 148 * pow(weight / height, 2))
        }
    }

    public var bodySurfaceAreaM2: Double {
        0.007184 * pow(max(patientHeightCm, 0.001), 0.725) * pow(max(patientWeightKg, 0.001), 0.425)
    }

    private var effectiveInjectedDoseBq: Double {
        effectiveInjectedDoseMBq * 1_000_000
    }

    private func activityBqPerML(_ rawValue: Double) -> Double {
        switch activityUnit {
        case .bqml:
            return rawValue
        case .kbqml:
            return rawValue * 1_000
        case .mbqml:
            return rawValue * 1_000_000
        case .custom:
            return rawValue * customBqPerMLPerStoredUnit
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4g", value)
    }
}

public struct SUVProbe: Equatable {
    public let voxel: (z: Int, y: Int, x: Int)
    public let rawValue: Double
    public let suv: Double

    public static func == (lhs: SUVProbe, rhs: SUVProbe) -> Bool {
        lhs.voxel.z == rhs.voxel.z &&
        lhs.voxel.y == rhs.voxel.y &&
        lhs.voxel.x == rhs.voxel.x &&
        lhs.rawValue == rhs.rawValue &&
        lhs.suv == rhs.suv
    }
}
