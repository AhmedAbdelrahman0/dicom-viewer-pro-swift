import Foundation
import Compression
import simd

private enum NIfTIByteOrder {
    case littleEndian
    case bigEndian
}

/// Native NIfTI-1 loader. Supports .nii and .nii.gz, uncompressed data types.
public enum NIfTILoaderError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidHeader(String)
    case unsupportedDataType(Int)
    case decompressionFailed
    case dimensionMismatch

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "File not found: \(p)"
        case .invalidHeader(let m): return "Invalid NIfTI header: \(m)"
        case .unsupportedDataType(let t): return "Unsupported NIfTI datatype code: \(t)"
        case .decompressionFailed: return "Failed to decompress .gz file"
        case .dimensionMismatch: return "Dimension mismatch in NIfTI file"
        }
    }
}

public enum NIfTILoader {

    /// Recognized volume file extensions.
    public static let extensions = ["nii", "nii.gz", "mha", "mhd", "nrrd", "hdr", "img"]

    public static func isVolumeFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return extensions.contains(where: { name.hasSuffix(".\($0)") })
    }

    // MARK: - Main entry point

    public static func load(_ url: URL, modalityHint: String = "") throws -> ImageVolume {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NIfTILoaderError.fileNotFound(url.path)
        }

        var data = try Data(contentsOf: url)
        let ext = url.lastPathComponent.lowercased()

        // Decompress .gz if needed
        if ext.hasSuffix(".nii.gz") || ext.hasSuffix(".gz") {
            data = try gunzip(data)
        }

        return try parseNIfTI(data: data, filename: url.lastPathComponent,
                              modalityHint: modalityHint, sourcePath: url.path)
    }

    // MARK: - NIfTI parser

    private static func parseNIfTI(data: Data,
                                   filename: String,
                                   modalityHint: String,
                                   sourcePath: String) throws -> ImageVolume {
        guard data.count >= 348 else {
            throw NIfTILoaderError.invalidHeader("File too small for NIfTI header")
        }

        // Read header values and detect endian-ness.
        let littleEndianHeader = data.readInt32(at: 0, byteOrder: .littleEndian)
        let bigEndianHeader = data.readInt32(at: 0, byteOrder: .bigEndian)
        let byteOrder: NIfTIByteOrder
        let sizeofHdr: Int32
        if littleEndianHeader == 348 {
            byteOrder = .littleEndian
            sizeofHdr = littleEndianHeader
        } else if bigEndianHeader == 348 {
            byteOrder = .bigEndian
            sizeofHdr = bigEndianHeader
        } else {
            byteOrder = .littleEndian
            sizeofHdr = littleEndianHeader
        }
        guard sizeofHdr == 348 else {
            throw NIfTILoaderError.invalidHeader("sizeof_hdr != 348 (got \(sizeofHdr))")
        }

        // Magic at offset 344: "n+1\0" means single-file NIfTI-1
        let magic = String(data: data[344..<348], encoding: .ascii) ?? ""
        guard magic.hasPrefix("n+1") || magic.hasPrefix("ni1") else {
            throw NIfTILoaderError.invalidHeader("Bad magic: \(magic)")
        }

        // dim[0..7]: dim[0] = number of dimensions, dim[1..3] = x,y,z size
        _ = Int(data.readInt16(at: 40, byteOrder: byteOrder))  // dim0 (num dimensions)
        let nx = Int(data.readInt16(at: 42, byteOrder: byteOrder))
        let ny = Int(data.readInt16(at: 44, byteOrder: byteOrder))
        let nz = Int(data.readInt16(at: 46, byteOrder: byteOrder))
        _ = Int(data.readInt16(at: 48, byteOrder: byteOrder))

        guard nx > 0, ny > 0 else {
            throw NIfTILoaderError.invalidHeader("Invalid dimensions: nx=\(nx), ny=\(ny)")
        }
        let depth = max(1, nz)
        let height = ny
        let width = nx

        // datatype at offset 70
        let datatype = Int(data.readInt16(at: 70, byteOrder: byteOrder))
        // bitpix at offset 72
        _ = Int(data.readInt16(at: 72, byteOrder: byteOrder))

        // pixdim[0..7] at offset 76 (float32 each, 8 values)
        let pdx = sanitizedSpacing(Double(data.readFloat32(at: 80, byteOrder: byteOrder)))
        let pdy = sanitizedSpacing(Double(data.readFloat32(at: 84, byteOrder: byteOrder)))
        let pdz = sanitizedSpacing(Double(data.readFloat32(at: 88, byteOrder: byteOrder)))
        let geometry = affineGeometry(data: data, byteOrder: byteOrder,
                                      fallbackSpacing: (pdx, pdy, pdz))

        // scl_slope, scl_inter at offsets 112 and 116
        let sclSlope = data.readFloat32(at: 112, byteOrder: byteOrder)
        let sclInter = data.readFloat32(at: 116, byteOrder: byteOrder)
        let slope = sclSlope != 0 ? Double(sclSlope) : 1.0
        let inter = Double(sclInter)

        // vox_offset at offset 108
        let voxOffset = Int(data.readFloat32(at: 108, byteOrder: byteOrder))
        let dataOffset = max(voxOffset, 352)

        // Parse pixel data
        let totalVoxels = depth * height * width
        guard data.count >= dataOffset + totalVoxels * bytesPerVoxel(for: datatype) else {
            throw NIfTILoaderError.invalidHeader("Data too short for declared dimensions")
        }

        return try parse3DVolume(data: data, dataOffset: dataOffset,
                                 datatype: datatype, depth: depth, height: height,
                                 width: width, slope: slope, inter: inter,
                                 byteOrder: byteOrder,
                                 spacing: geometry.spacing,
                                 origin: geometry.origin,
                                 direction: geometry.direction,
                                 filename: filename, modalityHint: modalityHint,
                                 sourcePath: sourcePath)
    }

    private static func parse3DVolume(data: Data,
                                       dataOffset: Int,
                                       datatype: Int,
                                       depth: Int,
                                       height: Int,
                                       width: Int,
                                       slope: Double,
                                       inter: Double,
                                       byteOrder: NIfTIByteOrder,
                                       spacing: (Double, Double, Double),
                                       origin: (Double, Double, Double),
                                       direction: simd_double3x3,
                                       filename: String,
                                       modalityHint: String,
                                       sourcePath: String) throws -> ImageVolume {
        let total = depth * height * width
        var pixels = [Float](repeating: 0, count: total)

        let bpp = bytesPerVoxel(for: datatype)
        for i in 0..<total {
            let offset = dataOffset + i * bpp
            let rawValue: Double
            switch datatype {
            case 2:   // UINT8
                rawValue = Double(data[offset])
            case 4:   // INT16
                rawValue = Double(data.readInt16(at: offset, byteOrder: byteOrder))
            case 8:   // INT32
                rawValue = Double(data.readInt32(at: offset, byteOrder: byteOrder))
            case 16:  // FLOAT32
                rawValue = Double(data.readFloat32(at: offset, byteOrder: byteOrder))
            case 64:  // FLOAT64
                rawValue = data.readFloat64(at: offset, byteOrder: byteOrder)
            case 256: // INT8
                rawValue = Double(Int8(bitPattern: data[offset]))
            case 512: // UINT16
                rawValue = Double(data.readUInt16(at: offset, byteOrder: byteOrder))
            case 768: // UINT32
                rawValue = Double(data.readUInt32(at: offset, byteOrder: byteOrder))
            default:
                throw NIfTILoaderError.unsupportedDataType(datatype)
            }
            pixels[i] = Float(rawValue * slope + inter)
        }

        let modality = inferModality(filename: filename, parentDir: (sourcePath as NSString).deletingLastPathComponent,
                                     hint: modalityHint)
        let desc = stripExtension(filename)

        return ImageVolume(
            pixels: pixels,
            depth: depth,
            height: height,
            width: width,
            spacing: spacing,
            origin: origin,
            direction: direction,
            modality: modality,
            seriesUID: "NIFTI_\(abs(filename.hashValue))",
            studyUID: "NIFTI_STUDY",
            patientID: "NIFTI_Import",
            patientName: "NIfTI Import",
            seriesDescription: desc,
            studyDescription: "NIfTI"
        )
    }

    private static func bytesPerVoxel(for datatype: Int) -> Int {
        switch datatype {
        case 2, 256:        return 1
        case 4, 512:        return 2
        case 8, 16, 768:    return 4
        case 64:            return 8
        default:            return 4
        }
    }

    private static func affineGeometry(data: Data,
                                       byteOrder: NIfTIByteOrder,
                                       fallbackSpacing: (Double, Double, Double))
        -> (spacing: (Double, Double, Double),
            origin: (Double, Double, Double),
            direction: simd_double3x3) {
        let qformCode = Int(data.readInt16(at: 252, byteOrder: byteOrder))
        let sformCode = Int(data.readInt16(at: 254, byteOrder: byteOrder))

        if sformCode > 0 {
            let srowX = SIMD4<Double>(
                Double(data.readFloat32(at: 280, byteOrder: byteOrder)),
                Double(data.readFloat32(at: 284, byteOrder: byteOrder)),
                Double(data.readFloat32(at: 288, byteOrder: byteOrder)),
                Double(data.readFloat32(at: 292, byteOrder: byteOrder))
            )
            let srowY = SIMD4<Double>(
                Double(data.readFloat32(at: 296, byteOrder: byteOrder)),
                Double(data.readFloat32(at: 300, byteOrder: byteOrder)),
                Double(data.readFloat32(at: 304, byteOrder: byteOrder)),
                Double(data.readFloat32(at: 308, byteOrder: byteOrder))
            )
            let srowZ = SIMD4<Double>(
                Double(data.readFloat32(at: 312, byteOrder: byteOrder)),
                Double(data.readFloat32(at: 316, byteOrder: byteOrder)),
                Double(data.readFloat32(at: 320, byteOrder: byteOrder)),
                Double(data.readFloat32(at: 324, byteOrder: byteOrder))
            )
            return decomposeRASAffine(
                xAxis: SIMD3<Double>(srowX.x, srowY.x, srowZ.x),
                yAxis: SIMD3<Double>(srowX.y, srowY.y, srowZ.y),
                zAxis: SIMD3<Double>(srowX.z, srowY.z, srowZ.z),
                origin: SIMD3<Double>(srowX.w, srowY.w, srowZ.w),
                fallbackSpacing: fallbackSpacing
            )
        }

        if qformCode > 0 {
            let b = Double(data.readFloat32(at: 256, byteOrder: byteOrder))
            let c = Double(data.readFloat32(at: 260, byteOrder: byteOrder))
            let d = Double(data.readFloat32(at: 264, byteOrder: byteOrder))
            let xyz = SIMD3<Double>(
                Double(data.readFloat32(at: 268, byteOrder: byteOrder)),
                Double(data.readFloat32(at: 272, byteOrder: byteOrder)),
                Double(data.readFloat32(at: 276, byteOrder: byteOrder))
            )
            let qfac = data.readFloat32(at: 76, byteOrder: byteOrder) < 0 ? -1.0 : 1.0
            let a = sqrt(max(0, 1.0 - (b*b + c*c + d*d)))

            let r11 = a*a + b*b - c*c - d*d
            let r12 = 2*b*c - 2*a*d
            let r13 = 2*b*d + 2*a*c
            let r21 = 2*b*c + 2*a*d
            let r22 = a*a + c*c - b*b - d*d
            let r23 = 2*c*d - 2*a*b
            let r31 = 2*b*d - 2*a*c
            let r32 = 2*c*d + 2*a*b
            let r33 = a*a + d*d - c*c - b*b

            return decomposeRASAffine(
                xAxis: SIMD3<Double>(r11, r21, r31) * fallbackSpacing.0,
                yAxis: SIMD3<Double>(r12, r22, r32) * fallbackSpacing.1,
                zAxis: SIMD3<Double>(r13, r23, r33) * fallbackSpacing.2 * qfac,
                origin: xyz,
                fallbackSpacing: fallbackSpacing
            )
        }

        return (
            fallbackSpacing,
            (0, 0, 0),
            matrix_identity_double3x3
        )
    }

    private static func decomposeRASAffine(xAxis: SIMD3<Double>,
                                           yAxis: SIMD3<Double>,
                                           zAxis: SIMD3<Double>,
                                           origin: SIMD3<Double>,
                                           fallbackSpacing: (Double, Double, Double))
        -> (spacing: (Double, Double, Double),
            origin: (Double, Double, Double),
            direction: simd_double3x3) {
        let xLPS = rasVectorToLPS(xAxis)
        let yLPS = rasVectorToLPS(yAxis)
        let zLPS = rasVectorToLPS(zAxis)
        let originLPS = rasVectorToLPS(origin)

        let sx = vectorSpacing(xLPS, fallback: fallbackSpacing.0)
        let sy = vectorSpacing(yLPS, fallback: fallbackSpacing.1)
        let sz = vectorSpacing(zLPS, fallback: fallbackSpacing.2)

        return (
            (sx, sy, sz),
            (originLPS.x, originLPS.y, originLPS.z),
            simd_double3x3(
                normalized(xLPS, fallback: SIMD3<Double>(1, 0, 0)),
                normalized(yLPS, fallback: SIMD3<Double>(0, 1, 0)),
                normalized(zLPS, fallback: SIMD3<Double>(0, 0, 1))
            )
        )
    }

    private static func rasVectorToLPS(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(-v.x, -v.y, v.z)
    }

    private static func vectorSpacing(_ v: SIMD3<Double>, fallback: Double) -> Double {
        let len = simd_length(v)
        return len > 1e-12 ? len : fallback
    }

    private static func normalized(_ v: SIMD3<Double>,
                                   fallback: SIMD3<Double>) -> SIMD3<Double> {
        let len = simd_length(v)
        guard len > 1e-12 else { return fallback }
        return v / len
    }

    private static func sanitizedSpacing(_ value: Double) -> Double {
        let v = abs(value)
        return v > 1e-12 ? v : 1
    }

    // MARK: - Gzip decompression (using Compression framework)

    private static func gunzip(_ data: Data) throws -> Data {
        // The gzip format has a 10-byte header; the compressed payload uses raw DEFLATE.
        // Compression framework's COMPRESSION_ZLIB expects zlib wrapper, not gzip.
        // We'll strip the gzip header manually and use COMPRESSION_ZLIB raw.
        guard data.count > 18 else { throw NIfTILoaderError.decompressionFailed }
        // gzip header: 1F 8B
        guard data[0] == 0x1F, data[1] == 0x8B else {
            throw NIfTILoaderError.decompressionFailed
        }

        let flg = data[3]
        var headerEnd = 10

        // FEXTRA
        if flg & 0x04 != 0 {
            let xlen = Int(data[headerEnd]) | (Int(data[headerEnd + 1]) << 8)
            headerEnd += 2 + xlen
        }
        // FNAME
        if flg & 0x08 != 0 {
            while headerEnd < data.count && data[headerEnd] != 0 { headerEnd += 1 }
            headerEnd += 1
        }
        // FCOMMENT
        if flg & 0x10 != 0 {
            while headerEnd < data.count && data[headerEnd] != 0 { headerEnd += 1 }
            headerEnd += 1
        }
        // FHCRC
        if flg & 0x02 != 0 { headerEnd += 2 }

        // Strip 8-byte trailer (CRC32 + ISIZE)
        let payloadEnd = data.count - 8
        guard payloadEnd > headerEnd else { throw NIfTILoaderError.decompressionFailed }

        let payload = data.subdata(in: headerEnd..<payloadEnd)

        // Use raw DEFLATE via Apple's Compression framework
        let bufferSize = max(payload.count * 8, 1 << 20)
        var dstBuffer = Data(count: bufferSize)

        let decompressed = dstBuffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            payload.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(
                    dst.baseAddress!.assumingMemoryBound(to: UInt8.self), bufferSize,
                    src.baseAddress!.assumingMemoryBound(to: UInt8.self), payload.count,
                    nil, COMPRESSION_ZLIB)
            }
        }

        guard decompressed > 0 else {
            // Retry with a larger buffer if needed (double until we succeed or give up)
            var sz = bufferSize * 2
            while sz < (1 << 30) {
                var buf = Data(count: sz)
                let n = buf.withUnsafeMutableBytes { dst in
                    payload.withUnsafeBytes { src in
                        compression_decode_buffer(
                            dst.baseAddress!.assumingMemoryBound(to: UInt8.self), sz,
                            src.baseAddress!.assumingMemoryBound(to: UInt8.self), payload.count,
                            nil, COMPRESSION_ZLIB)
                    }
                }
                if n > 0 {
                    return buf.prefix(n)
                }
                sz *= 2
            }
            throw NIfTILoaderError.decompressionFailed
        }
        return dstBuffer.prefix(decompressed)
    }

    // MARK: - Modality inference from filename

    static func inferModality(filename: String, parentDir: String, hint: String) -> String {
        if !hint.isEmpty { return Modality.normalize(hint).rawValue }

        let stem = stripExtension(filename).lowercased()
        let parent = (parentDir as NSString).lastPathComponent.lowercased()

        // Filename tokens take priority
        if let m = matchModality(in: stem) { return m }
        if let m = matchModality(in: parent) { return m }
        return "OT"
    }

    private static func matchModality(in text: String) -> String? {
        let tokens = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let tokenSet = Set(tokens)

        // Priority order
        let patterns: [(String, [String])] = [
            ("PT",  ["pet", "fdg", "suv", "pib", "psma", "dotatate", "fbb"]),
            ("SEG", ["seg", "segmentation", "mask", "label", "labelmap"]),
            ("CT",  ["ct", "cbct"]),
            ("MR",  ["mri", "mprage", "flair", "dwi", "adc", "swi", "bold", "mr", "t1", "t2"]),
            ("US",  ["us", "ultrasound"]),
            ("NM",  ["nm", "spect"]),
        ]

        // Exact token match first
        for (modality, keywords) in patterns {
            for kw in keywords where tokenSet.contains(kw) {
                return modality
            }
        }
        // Prefix match (e.g. "ctres" -> CT)
        for (modality, keywords) in patterns {
            for kw in keywords {
                for tok in tokens where tok.hasPrefix(kw) && tok.count <= kw.count + 6 {
                    return modality
                }
            }
        }
        return nil
    }

    private static func stripExtension(_ name: String) -> String {
        var n = name
        for ext in extensions.sorted(by: { $0.count > $1.count }) {
            let suffix = "." + ext
            if n.lowercased().hasSuffix(suffix) {
                n = String(n.dropLast(suffix.count))
                break
            }
        }
        return n
    }
}

// MARK: - Data reading helpers

private extension Data {
    func readUInt16(at offset: Int, byteOrder: NIfTIByteOrder) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1])
        switch byteOrder {
        case .littleEndian:
            return b0 | (b1 << 8)
        case .bigEndian:
            return (b0 << 8) | b1
        }
    }

    func readInt16(at offset: Int, byteOrder: NIfTIByteOrder) -> Int16 {
        Int16(bitPattern: readUInt16(at: offset, byteOrder: byteOrder))
    }

    func readUInt32(at offset: Int, byteOrder: NIfTIByteOrder) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        switch byteOrder {
        case .littleEndian:
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        case .bigEndian:
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
    }

    func readInt32(at offset: Int, byteOrder: NIfTIByteOrder) -> Int32 {
        Int32(bitPattern: readUInt32(at: offset, byteOrder: byteOrder))
    }

    func readUInt64(at offset: Int, byteOrder: NIfTIByteOrder) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        let hi = UInt64(readUInt32(at: offset, byteOrder: byteOrder))
        let lo = UInt64(readUInt32(at: offset + 4, byteOrder: byteOrder))
        switch byteOrder {
        case .littleEndian:
            return hi | (lo << 32)
        case .bigEndian:
            return (hi << 32) | lo
        }
    }

    func readFloat32(at offset: Int, byteOrder: NIfTIByteOrder) -> Float {
        Float(bitPattern: readUInt32(at: offset, byteOrder: byteOrder))
    }

    func readFloat64(at offset: Int, byteOrder: NIfTIByteOrder) -> Double {
        Double(bitPattern: readUInt64(at: offset, byteOrder: byteOrder))
    }
}
