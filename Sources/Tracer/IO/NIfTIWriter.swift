import Foundation
import simd

/// Writer for uncompressed NIfTI-1 single-file (`.nii`) volumes.
///
/// Counterpart to `NIfTILoader`. Primarily used when the app needs to hand off
/// an `ImageVolume` to an external tool — e.g. upload to a MONAI Label server
/// for inference, or stage input for a MONAI Deploy application package.
///
/// The written geometry is round-trip compatible with `NIfTILoader`: the
/// in-app `LPS` axes and origin are encoded back to `RAS` in the `sform`
/// so external NIfTI tooling agrees with our coordinate system.
public enum NIfTIWriter {

    public enum Error: Swift.Error, LocalizedError {
        case unsupportedVolumeSize(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVolumeSize(let msg):
                return "NIfTI writer: \(msg)"
            }
        }
    }

    /// Write an `ImageVolume` to `url` as `.nii` (uncompressed, float32).
    public static func write(_ volume: ImageVolume, to url: URL) throws {
        try writeFloat32(volume, to: url)
    }

    /// Write as float32 NIfTI-1. Always safe — matches our internal storage.
    public static func writeFloat32(_ volume: ImageVolume, to url: URL) throws {
        guard volume.width > 0, volume.height > 0, volume.depth > 0 else {
            throw Error.unsupportedVolumeSize(
                "cannot write zero-sized volume \(volume.width)x\(volume.height)x\(volume.depth)"
            )
        }
        // Short-dim field (16-bit signed) caps each axis at 32767 voxels,
        // which is far more than any real medical volume.
        guard volume.width < Int(Int16.max),
              volume.height < Int(Int16.max),
              volume.depth < Int(Int16.max) else {
            throw Error.unsupportedVolumeSize(
                "axis exceeds Int16.max (\(Int16.max)); current \(volume.width)x\(volume.height)x\(volume.depth)"
            )
        }

        var out = Data()
        out.append(buildHeader(volume: volume, datatype: 16 /* DT_FLOAT32 */, bitpix: 32))
        out.append(Data([0, 0, 0, 0])) // no extensions

        volume.pixels.withUnsafeBufferPointer { buf in
            out.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        // Atomic so a crash mid-write never leaves a truncated NIfTI for the
        // next run (or an external Python script) to read as garbage voxels.
        try out.write(to: url, options: [.atomic])
    }

    // MARK: - Private

    private static func buildHeader(volume: ImageVolume,
                                    datatype: Int16,
                                    bitpix: Int16) -> Data {
        var hdr = Data(count: 352)

        writeInt32(348, into: &hdr, at: 0)                      // sizeof_hdr

        writeInt16(3, into: &hdr, at: 40)                       // dim[0] = 3
        writeInt16(Int16(volume.width), into: &hdr, at: 42)     // dim[1] = X
        writeInt16(Int16(volume.height), into: &hdr, at: 44)    // dim[2] = Y
        writeInt16(Int16(volume.depth), into: &hdr, at: 46)     // dim[3] = Z
        writeInt16(1, into: &hdr, at: 48)
        writeInt16(1, into: &hdr, at: 50)
        writeInt16(1, into: &hdr, at: 52)
        writeInt16(1, into: &hdr, at: 54)

        writeInt16(datatype, into: &hdr, at: 70)                // datatype
        writeInt16(bitpix, into: &hdr, at: 72)                  // bitpix

        writeFloat32(1.0, into: &hdr, at: 76)                   // qfac
        writeFloat32(Float(volume.spacing.x), into: &hdr, at: 80)
        writeFloat32(Float(volume.spacing.y), into: &hdr, at: 84)
        writeFloat32(Float(volume.spacing.z), into: &hdr, at: 88)

        writeFloat32(352, into: &hdr, at: 108)                  // vox_offset
        writeFloat32(1.0, into: &hdr, at: 112)                  // scl_slope
        writeFloat32(0.0, into: &hdr, at: 116)                  // scl_inter

        // LPS → RAS for the sform (world space).
        let xAxisLPS = volume.direction[0] * volume.spacing.x
        let yAxisLPS = volume.direction[1] * volume.spacing.y
        let zAxisLPS = volume.direction[2] * volume.spacing.z
        let originLPS = SIMD3<Double>(volume.origin.x, volume.origin.y, volume.origin.z)
        let xAxisRAS = lpsToRAS(xAxisLPS)
        let yAxisRAS = lpsToRAS(yAxisLPS)
        let zAxisRAS = lpsToRAS(zAxisLPS)
        let originRAS = lpsToRAS(originLPS)

        writeInt16(0, into: &hdr, at: 252)                      // qform_code = 0
        writeInt16(2, into: &hdr, at: 254)                      // sform_code = 2 (aligned)
        writeFloat32(Float(xAxisRAS.x),    into: &hdr, at: 280)
        writeFloat32(Float(yAxisRAS.x),    into: &hdr, at: 284)
        writeFloat32(Float(zAxisRAS.x),    into: &hdr, at: 288)
        writeFloat32(Float(originRAS.x),   into: &hdr, at: 292)
        writeFloat32(Float(xAxisRAS.y),    into: &hdr, at: 296)
        writeFloat32(Float(yAxisRAS.y),    into: &hdr, at: 300)
        writeFloat32(Float(zAxisRAS.y),    into: &hdr, at: 304)
        writeFloat32(Float(originRAS.y),   into: &hdr, at: 308)
        writeFloat32(Float(xAxisRAS.z),    into: &hdr, at: 312)
        writeFloat32(Float(yAxisRAS.z),    into: &hdr, at: 316)
        writeFloat32(Float(zAxisRAS.z),    into: &hdr, at: 320)
        writeFloat32(Float(originRAS.z),   into: &hdr, at: 324)

        // Magic "n+1\0" — single-file NIfTI-1.
        hdr[344] = 0x6E
        hdr[345] = 0x2B
        hdr[346] = 0x31
        hdr[347] = 0x00

        return hdr
    }

    private static func lpsToRAS(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(-v.x, -v.y, v.z)
    }

    private static func writeInt16(_ value: Int16, into data: inout Data, at offset: Int) {
        var v = value
        Swift.withUnsafeBytes(of: &v) { src in
            data.replaceSubrange(offset..<offset+2, with: src)
        }
    }

    private static func writeInt32(_ value: Int32, into data: inout Data, at offset: Int) {
        var v = value
        Swift.withUnsafeBytes(of: &v) { src in
            data.replaceSubrange(offset..<offset+4, with: src)
        }
    }

    private static func writeFloat32(_ value: Float, into data: inout Data, at offset: Int) {
        var v = value
        Swift.withUnsafeBytes(of: &v) { src in
            data.replaceSubrange(offset..<offset+4, with: src)
        }
    }
}
