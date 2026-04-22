import Foundation
import simd

/// A 3D medical image volume stored as a contiguous Float array in (Z, Y, X) order.
public final class ImageVolume: Identifiable, ObservableObject {
    public let id = UUID()

    /// Pixel data, shape = depth * height * width (Z-major, C-order).
    public let pixels: [Float]
    public let depth: Int    // Z — number of slices
    public let height: Int   // Y — rows in each slice
    public let width: Int    // X — cols in each slice

    /// Spatial metadata (LPS convention after reorientation).
    public let spacing: (x: Double, y: Double, z: Double)
    public let origin: (x: Double, y: Double, z: Double)
    /// Direction cosines in LPS space. Columns are voxel X, Y, and Z axes.
    public let direction: simd_double3x3

    /// Clinical metadata.
    public let modality: String
    public let seriesUID: String
    public let studyUID: String
    public let patientID: String
    public let patientName: String
    public let seriesDescription: String
    public let studyDescription: String

    /// Optional SUV scale factor (for PET).
    public let suvScaleFactor: Double?

    /// Canonical source file paths used to create this volume, when known.
    public let sourceFiles: [String]

    /// Cached intensity range for auto W/L.
    public private(set) lazy var intensityRange: (min: Float, max: Float) = {
        guard !pixels.isEmpty else { return (0, 1) }
        var mn = pixels[0], mx = pixels[0]
        for v in pixels {
            if v < mn { mn = v }
            if v > mx { mx = v }
        }
        return (mn, mx)
    }()

    public init(pixels: [Float],
                depth: Int,
                height: Int,
                width: Int,
                spacing: (Double, Double, Double) = (1, 1, 1),
                origin: (Double, Double, Double) = (0, 0, 0),
                direction: simd_double3x3 = matrix_identity_double3x3,
                modality: String = "OT",
                seriesUID: String = UUID().uuidString,
                studyUID: String = UUID().uuidString,
                patientID: String = "",
                patientName: String = "",
                seriesDescription: String = "",
                studyDescription: String = "",
                suvScaleFactor: Double? = nil,
                sourceFiles: [String] = []) {
        precondition(pixels.count == depth * height * width,
                     "Pixel count (\(pixels.count)) doesn't match dims \(depth)x\(height)x\(width)")
        self.pixels = pixels
        self.depth = depth
        self.height = height
        self.width = width
        self.spacing = spacing
        self.origin = origin
        self.direction = direction
        self.modality = modality
        self.seriesUID = seriesUID
        self.studyUID = studyUID
        self.patientID = patientID
        self.patientName = patientName
        self.seriesDescription = seriesDescription
        self.studyDescription = studyDescription
        self.suvScaleFactor = suvScaleFactor
        self.sourceFiles = sourceFiles.map(Self.canonicalPath).sorted()
    }

    /// Size in bytes.
    public var sizeBytes: Int { pixels.count * MemoryLayout<Float>.stride }

    public var sessionIdentity: String {
        if !seriesUID.isEmpty {
            return "series:\(seriesUID)"
        }
        if !sourceFiles.isEmpty {
            return "files:\(sourceFiles.joined(separator: "|"))"
        }
        return "geometry:\(modality):\(width)x\(height)x\(depth):\(patientID):\(seriesDescription)"
    }

    public var originVector: SIMD3<Double> {
        SIMD3<Double>(origin.x, origin.y, origin.z)
    }

    public func worldPoint(z: Int, y: Int, x: Int) -> SIMD3<Double> {
        worldPoint(voxel: SIMD3<Double>(Double(x), Double(y), Double(z)))
    }

    public func worldPoint(voxel: SIMD3<Double>) -> SIMD3<Double> {
        let scaled = SIMD3<Double>(
            voxel.x * spacing.x,
            voxel.y * spacing.y,
            voxel.z * spacing.z
        )
        return originVector + direction * scaled
    }

    public func voxelCoordinates(from world: SIMD3<Double>) -> SIMD3<Double> {
        let local = direction.inverse * (world - originVector)
        return SIMD3<Double>(
            local.x / spacing.x,
            local.y / spacing.y,
            local.z / spacing.z
        )
    }

    public func voxelIndex(from world: SIMD3<Double>) -> (z: Int, y: Int, x: Int) {
        let v = voxelCoordinates(from: world)
        return (
            clamp(Int(round(v.z)), 0, depth - 1),
            clamp(Int(round(v.y)), 0, height - 1),
            clamp(Int(round(v.x)), 0, width - 1)
        )
    }

    /// Get a 2D slice along the given axis as a raw Float array.
    ///   axis 0 = sagittal (shape: depth x height)
    ///   axis 1 = coronal  (shape: depth x width)
    ///   axis 2 = axial    (shape: height x width)
    public func slice(axis: Int, index: Int) -> (pixels: [Float], width: Int, height: Int) {
        switch axis {
        case 0:
            // Sagittal: fix X=index, output (Z, Y)
            let x = clamp(index, 0, width - 1)
            var out = [Float](repeating: 0, count: depth * height)
            for z in 0..<depth {
                for y in 0..<height {
                    out[z * height + y] = pixels[z * height * width + y * width + x]
                }
            }
            return (out, height, depth)
        case 1:
            // Coronal: fix Y=index, output (Z, X)
            let y = clamp(index, 0, height - 1)
            var out = [Float](repeating: 0, count: depth * width)
            for z in 0..<depth {
                let rowStart = z * height * width + y * width
                for x in 0..<width {
                    out[z * width + x] = pixels[rowStart + x]
                }
            }
            return (out, width, depth)
        default:
            // Axial: fix Z=index, output (Y, X)
            let z = clamp(index, 0, depth - 1)
            let start = z * height * width
            let end = start + height * width
            return (Array(pixels[start..<end]), width, height)
        }
    }

    /// Intensity at voxel (z, y, x); returns 0 if out of bounds.
    public func intensity(z: Int, y: Int, x: Int) -> Float {
        guard z >= 0, z < depth, y >= 0, y < height, x >= 0, x < width else { return 0 }
        return pixels[z * height * width + y * width + x]
    }

    /// SUV at voxel (PET only).
    public func suv(z: Int, y: Int, x: Int) -> Double? {
        guard let s = suvScaleFactor else { return nil }
        return Double(intensity(z: z, y: y, x: x)) * s
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        max(lo, min(hi, v))
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}

public enum Modality: String, CaseIterable, Sendable {
    case CT, MR, PT, SEG, NM, US, CR, OT

    public var displayName: String {
        switch self {
        case .PT: return "PET"
        case .CR: return "X-Ray"
        case .OT: return "Other"
        default:  return rawValue
        }
    }

    public static func normalize(_ raw: String) -> Modality {
        let u = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch u {
        case "CT", "CAT", "CBCT":         return .CT
        case "MR", "MRI", "NMR":          return .MR
        case "PT", "PET", "PETCT", "FDG": return .PT
        case "SEG", "MASK", "LABEL":      return .SEG
        case "NM", "SPECT":               return .NM
        case "US", "ULTRASOUND":          return .US
        case "CR", "DX", "XR":            return .CR
        default:                          return Modality(rawValue: u) ?? .OT
        }
    }
}
