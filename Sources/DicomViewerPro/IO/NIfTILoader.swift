import Foundation
import Compression

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

        // Read header values
        let sizeofHdr = data.readInt32(at: 0)
        guard sizeofHdr == 348 else {
            throw NIfTILoaderError.invalidHeader("sizeof_hdr != 348 (got \(sizeofHdr))")
        }

        // Magic at offset 344: "n+1\0" means single-file NIfTI-1
        let magic = String(data: data[344..<348], encoding: .ascii) ?? ""
        guard magic.hasPrefix("n+1") || magic.hasPrefix("ni1") else {
            throw NIfTILoaderError.invalidHeader("Bad magic: \(magic)")
        }

        // dim[0..7]: dim[0] = number of dimensions, dim[1..3] = x,y,z size
        _ = Int(data.readInt16(at: 40))  // dim0 (num dimensions)
        let nx = Int(data.readInt16(at: 42))
        let ny = Int(data.readInt16(at: 44))
        let nz = Int(data.readInt16(at: 46))
        let nt = Int(data.readInt16(at: 48))

        guard nx > 0, ny > 0 else {
            throw NIfTILoaderError.invalidHeader("Invalid dimensions: nx=\(nx), ny=\(ny)")
        }
        let depth = max(1, nz)
        let height = ny
        let width = nx

        // datatype at offset 70
        let datatype = Int(data.readInt16(at: 70))
        // bitpix at offset 72
        _ = Int(data.readInt16(at: 72))

        // pixdim[0..7] at offset 76 (float32 each, 8 values)
        let pdx = Double(data.readFloat32(at: 80))
        let pdy = Double(data.readFloat32(at: 84))
        let pdz = Double(data.readFloat32(at: 88))

        // scl_slope, scl_inter at offsets 112 and 116
        let sclSlope = data.readFloat32(at: 112)
        let sclInter = data.readFloat32(at: 116)
        let slope = sclSlope != 0 ? Double(sclSlope) : 1.0
        let inter = Double(sclInter)

        // vox_offset at offset 108
        let voxOffset = Int(data.readFloat32(at: 108))
        let dataOffset = max(voxOffset, 352)

        // Parse pixel data
        let totalVoxels = depth * height * width
        guard data.count >= dataOffset + totalVoxels * bytesPerVoxel(for: datatype) else {
            // For 4D data take just the first 3D volume
            if nt > 1 {
                return try parse3DVolume(data: data, dataOffset: dataOffset,
                                         datatype: datatype, depth: depth, height: height,
                                         width: width, slope: slope, inter: inter,
                                         spacing: (pdx, pdy, pdz),
                                         filename: filename, modalityHint: modalityHint,
                                         sourcePath: sourcePath)
            }
            throw NIfTILoaderError.invalidHeader("Data too short for declared dimensions")
        }

        return try parse3DVolume(data: data, dataOffset: dataOffset,
                                 datatype: datatype, depth: depth, height: height,
                                 width: width, slope: slope, inter: inter,
                                 spacing: (pdx, pdy, pdz),
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
                                       spacing: (Double, Double, Double),
                                       filename: String,
                                       modalityHint: String,
                                       sourcePath: String) throws -> ImageVolume {
        let total = depth * height * width
        var pixels = [Float](repeating: 0, count: total)

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: dataOffset)
            switch datatype {
            case 2:   // UINT8
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                for i in 0..<total { pixels[i] = Float(Double(ptr[i]) * slope + inter) }
            case 4:   // INT16
                let ptr = base.assumingMemoryBound(to: Int16.self)
                for i in 0..<total { pixels[i] = Float(Double(ptr[i]) * slope + inter) }
            case 8:   // INT32
                let ptr = base.assumingMemoryBound(to: Int32.self)
                for i in 0..<total { pixels[i] = Float(Double(ptr[i]) * slope + inter) }
            case 16:  // FLOAT32
                let ptr = base.assumingMemoryBound(to: Float.self)
                for i in 0..<total { pixels[i] = Float(Double(ptr[i]) * slope + inter) }
            case 64:  // FLOAT64
                let ptr = base.assumingMemoryBound(to: Double.self)
                for i in 0..<total { pixels[i] = Float(ptr[i] * slope + inter) }
            case 256: // INT8
                let ptr = base.assumingMemoryBound(to: Int8.self)
                for i in 0..<total { pixels[i] = Float(Double(ptr[i]) * slope + inter) }
            case 512: // UINT16
                let ptr = base.assumingMemoryBound(to: UInt16.self)
                for i in 0..<total { pixels[i] = Float(Double(ptr[i]) * slope + inter) }
            case 768: // UINT32
                let ptr = base.assumingMemoryBound(to: UInt32.self)
                for i in 0..<total { pixels[i] = Float(Double(ptr[i]) * slope + inter) }
            default:
                throw NIfTILoaderError.unsupportedDataType(datatype)
            }
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
            origin: (0, 0, 0),
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
    func readInt16(at offset: Int) -> Int16 {
        return self.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: Int16.self) }
    }
    func readInt32(at offset: Int) -> Int32 {
        return self.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Int32.self) }
    }
    func readFloat32(at offset: Int) -> Float {
        return self.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Float.self) }
    }
}
