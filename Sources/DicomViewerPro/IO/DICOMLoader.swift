import Foundation

public enum DICOMError: Error, LocalizedError {
    case notADICOMFile
    case invalidFile(String)
    case unsupportedTransferSyntax(String)

    public var errorDescription: String? {
        switch self {
        case .notADICOMFile: return "Not a DICOM file (missing DICM signature)"
        case .invalidFile(let m): return "Invalid DICOM file: \(m)"
        case .unsupportedTransferSyntax(let ts): return "Unsupported transfer syntax: \(ts)"
        }
    }
}

/// Minimal DICOM parser — reads Explicit VR Little Endian and Implicit VR
/// Little Endian uncompressed pixel data. Sufficient for CT/MR/PT raw-pixel
/// DICOMs. JPEG-compressed DICOMs are not supported.
public final class DICOMFile {
    public var patientID: String = ""
    public var patientName: String = ""
    public var studyInstanceUID: String = ""
    public var studyDescription: String = ""
    public var studyDate: String = ""
    public var seriesInstanceUID: String = ""
    public var seriesDescription: String = ""
    public var seriesNumber: Int = 0
    public var modality: String = ""
    public var sopInstanceUID: String = ""
    public var instanceNumber: Int = 0
    public var rows: Int = 0
    public var columns: Int = 0
    public var bitsAllocated: Int = 16
    public var bitsStored: Int = 16
    public var pixelRepresentation: Int = 0  // 0 = unsigned, 1 = signed
    public var rescaleSlope: Double = 1.0
    public var rescaleIntercept: Double = 0.0
    public var pixelSpacing: (Double, Double) = (1, 1)
    public var sliceThickness: Double = 1.0
    public var sliceLocation: Double = 0.0
    public var imagePositionPatient: (Double, Double, Double) = (0, 0, 0)
    public var imageOrientationPatient: [Double] = []
    public var bodyPartExamined: String = ""

    public var transferSyntaxUID: String = "1.2.840.10008.1.2"  // Implicit VR LE default
    public var pixelDataOffset: Int = 0
    public var pixelDataLength: Int = 0

    public var filePath: String = ""
}

public enum DICOMLoader {

    public static func parseHeader(at url: URL) throws -> DICOMFile {
        let data = try Data(contentsOf: url)
        let dcm = try parseHeader(data: data)
        dcm.filePath = url.path
        return dcm
    }

    public static func parseHeader(data: Data) throws -> DICOMFile {
        guard data.count > 132 else {
            throw DICOMError.invalidFile("File too small")
        }
        // DICOM preamble: 128 bytes + "DICM"
        let magic = String(data: data[128..<132], encoding: .ascii) ?? ""
        guard magic == "DICM" else {
            throw DICOMError.notADICOMFile
        }

        let dcm = DICOMFile()
        var offset = 132
        var implicitVR = false  // assume explicit VR until we see group 0002

        // Read File Meta Information (group 0002) — always Explicit VR Little Endian
        while offset < data.count - 8 {
            let group = data.readUInt16LE(at: offset)
            let element = data.readUInt16LE(at: offset + 2)

            if group != 0x0002 {
                // Switch to dataset, transfer syntax determines VR
                if dcm.transferSyntaxUID == "1.2.840.10008.1.2" {
                    implicitVR = true
                }
                break
            }

            let (value, nextOffset) = readElement(data: data, offset: offset,
                                                  implicitVR: false)
            if group == 0x0002 && element == 0x0010 {
                dcm.transferSyntaxUID = value.asString().trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
            offset = nextOffset
        }

        // Parse dataset elements
        while offset < data.count - 8 {
            let group = data.readUInt16LE(at: offset)
            let element = data.readUInt16LE(at: offset + 2)

            // Pixel Data (7FE0,0010) — stop here for header-only parse
            if group == 0x7FE0 && element == 0x0010 {
                // Record offset and length, then stop
                let (value, _) = readElement(data: data, offset: offset,
                                             implicitVR: implicitVR, peekOnly: true)
                dcm.pixelDataOffset = value.dataOffset
                dcm.pixelDataLength = value.length
                break
            }

            let (value, nextOffset) = readElement(data: data, offset: offset,
                                                  implicitVR: implicitVR)
            assignTag(dcm: dcm, group: group, element: element, value: value)
            offset = nextOffset
        }

        return dcm
    }

    /// Load pixel data for a series (list of DICOM files sorted by slice).
    public static func loadSeries(_ files: [DICOMFile]) throws -> ImageVolume {
        guard !files.isEmpty else {
            throw DICOMError.invalidFile("Empty series")
        }
        let first = files[0]
        let rows = first.rows, cols = first.columns
        guard rows > 0, cols > 0 else {
            throw DICOMError.invalidFile("Invalid dimensions")
        }

        // Sort by slice location or instance number
        let sorted = files.sorted { a, b in
            if a.imagePositionPatient.2 != b.imagePositionPatient.2 {
                return a.imagePositionPatient.2 < b.imagePositionPatient.2
            }
            if a.sliceLocation != b.sliceLocation {
                return a.sliceLocation < b.sliceLocation
            }
            return a.instanceNumber < b.instanceNumber
        }

        let depth = sorted.count
        var pixels = [Float](repeating: 0, count: depth * rows * cols)

        for (zi, f) in sorted.enumerated() {
            let slice = try loadSlicePixels(f)
            let dst = zi * rows * cols
            for i in 0..<(rows * cols) {
                pixels[dst + i] = slice[i]
            }
        }

        // Z spacing from slice position difference
        var zSpacing = first.sliceThickness
        if sorted.count > 1 {
            let dz = abs(sorted[1].imagePositionPatient.2 - sorted[0].imagePositionPatient.2)
            if dz > 0.001 { zSpacing = dz }
        }

        return ImageVolume(
            pixels: pixels,
            depth: depth,
            height: rows,
            width: cols,
            spacing: (first.pixelSpacing.0, first.pixelSpacing.1, zSpacing),
            origin: first.imagePositionPatient,
            modality: Modality.normalize(first.modality).rawValue,
            seriesUID: first.seriesInstanceUID,
            studyUID: first.studyInstanceUID,
            patientID: first.patientID,
            patientName: first.patientName,
            seriesDescription: first.seriesDescription,
            studyDescription: first.studyDescription
        )
    }

    /// Load a single slice as raw pixel data (rows * cols floats, rescale applied).
    public static func loadSlicePixels(_ dcm: DICOMFile) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: dcm.filePath))
        let n = dcm.rows * dcm.columns
        var out = [Float](repeating: 0, count: n)

        let offset = dcm.pixelDataOffset
        let length = dcm.pixelDataLength

        guard offset + length <= data.count else {
            throw DICOMError.invalidFile("Pixel data out of bounds")
        }

        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: offset)
            if dcm.bitsAllocated == 16 {
                if dcm.pixelRepresentation == 1 {
                    let p = base.assumingMemoryBound(to: Int16.self)
                    for i in 0..<n { out[i] = Float(Double(p[i]) * dcm.rescaleSlope + dcm.rescaleIntercept) }
                } else {
                    let p = base.assumingMemoryBound(to: UInt16.self)
                    for i in 0..<n { out[i] = Float(Double(p[i]) * dcm.rescaleSlope + dcm.rescaleIntercept) }
                }
            } else if dcm.bitsAllocated == 8 {
                let p = base.assumingMemoryBound(to: UInt8.self)
                for i in 0..<n { out[i] = Float(Double(p[i]) * dcm.rescaleSlope + dcm.rescaleIntercept) }
            } else if dcm.bitsAllocated == 32 {
                let p = base.assumingMemoryBound(to: Float.self)
                for i in 0..<n { out[i] = Float(Double(p[i]) * dcm.rescaleSlope + dcm.rescaleIntercept) }
            }
        }
        return out
    }

    // MARK: - DICOM element reader

    private struct ElementValue {
        var bytes: Data
        var dataOffset: Int
        var length: Int

        func asString() -> String {
            return String(data: bytes, encoding: .ascii) ?? ""
        }
        func asInt() -> Int {
            return Int(asString().trimmingCharacters(in: .whitespaces)
                      .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))) ?? 0
        }
        func asDouble() -> Double {
            return Double(asString().trimmingCharacters(in: .whitespaces)
                          .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))) ?? 0
        }
        func asDoubleArray() -> [Double] {
            return asString()
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
                .split(separator: "\\")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
    }

    private static func readElement(data: Data, offset: Int,
                                    implicitVR: Bool,
                                    peekOnly: Bool = false) -> (ElementValue, Int) {
        var pos = offset + 4  // skip group + element
        var length: Int = 0

        if implicitVR {
            length = Int(data.readUInt32LE(at: pos))
            pos += 4
        } else {
            let vr = String(data: data[pos..<pos+2], encoding: .ascii) ?? ""
            pos += 2
            let longVRs: Set<String> = ["OB", "OW", "OF", "SQ", "UT", "UN", "OD", "OL"]
            if longVRs.contains(vr) {
                pos += 2  // reserved
                length = Int(data.readUInt32LE(at: pos))
                pos += 4
            } else {
                length = Int(data.readUInt16LE(at: pos))
                pos += 2
            }
        }

        // Handle undefined length (0xFFFFFFFF) — treat as sequence; skip
        if length == 0xFFFFFFFF {
            length = 0
        }

        let dataStart = pos
        let dataEnd = min(pos + length, data.count)
        let valueBytes = peekOnly ? Data() : data.subdata(in: dataStart..<dataEnd)

        return (ElementValue(bytes: valueBytes, dataOffset: dataStart, length: length),
                dataEnd)
    }

    private static func assignTag(dcm: DICOMFile, group: UInt16, element: UInt16,
                                  value: ElementValue) {
        let tag = (UInt32(group) << 16) | UInt32(element)
        switch tag {
        case 0x00100010: dcm.patientName = value.asString()
        case 0x00100020: dcm.patientID = value.asString()
        case 0x00080020: dcm.studyDate = value.asString()
        case 0x00081030: dcm.studyDescription = value.asString()
        case 0x0020000D: dcm.studyInstanceUID = trim(value.asString())
        case 0x0020000E: dcm.seriesInstanceUID = trim(value.asString())
        case 0x0008103E: dcm.seriesDescription = value.asString()
        case 0x00200011: dcm.seriesNumber = value.asInt()
        case 0x00080060: dcm.modality = trim(value.asString())
        case 0x00080018: dcm.sopInstanceUID = trim(value.asString())
        case 0x00200013: dcm.instanceNumber = value.asInt()
        case 0x00280010: dcm.rows = readUInt16Value(value)
        case 0x00280011: dcm.columns = readUInt16Value(value)
        case 0x00280100: dcm.bitsAllocated = readUInt16Value(value)
        case 0x00280101: dcm.bitsStored = readUInt16Value(value)
        case 0x00280103: dcm.pixelRepresentation = readUInt16Value(value)
        case 0x00281053: dcm.rescaleSlope = value.asDouble()
        case 0x00281052: dcm.rescaleIntercept = value.asDouble()
        case 0x00180050: dcm.sliceThickness = value.asDouble()
        case 0x00201041: dcm.sliceLocation = value.asDouble()
        case 0x00280030:
            let a = value.asDoubleArray()
            if a.count >= 2 { dcm.pixelSpacing = (a[0], a[1]) }
        case 0x00200032:
            let a = value.asDoubleArray()
            if a.count >= 3 { dcm.imagePositionPatient = (a[0], a[1], a[2]) }
        case 0x00200037:
            dcm.imageOrientationPatient = value.asDoubleArray()
        case 0x00180015:
            dcm.bodyPartExamined = trim(value.asString())
        default:
            break
        }
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
         .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private static func readUInt16Value(_ value: ElementValue) -> Int {
        if value.bytes.count >= 2 {
            return Int(value.bytes.withUnsafeBytes { $0.load(as: UInt16.self) })
        }
        return value.asInt()
    }

    // MARK: - Scan a directory for DICOM files

    public static func scanDirectory(_ url: URL,
                                     progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) -> [DICOMSeries] {
        var files: [DICOMFile] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else {
            return []
        }

        var totalFiles = 0
        for case let fileURL as URL in enumerator {
            let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if !isFile { continue }
            totalFiles += 1
        }

        guard let enumerator2 = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles]) else {
            return []
        }

        var scanned = 0
        for case let fileURL as URL in enumerator2 {
            let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if !isFile { continue }
            scanned += 1
            if scanned % 20 == 0 || scanned == totalFiles {
                progress(scanned, totalFiles)
            }
            if let dcm = try? parseHeader(at: fileURL) {
                files.append(dcm)
            }
        }
        progress(totalFiles, totalFiles)

        return groupIntoSeries(files)
    }

    private static func groupIntoSeries(_ files: [DICOMFile]) -> [DICOMSeries] {
        let grouped = Dictionary(grouping: files, by: { $0.seriesInstanceUID })
        var out: [DICOMSeries] = []
        for (uid, fs) in grouped where !uid.isEmpty {
            let first = fs[0]
            let s = DICOMSeries(
                uid: uid,
                modality: Modality.normalize(first.modality).rawValue,
                description: first.seriesDescription,
                patientID: first.patientID,
                patientName: first.patientName,
                studyUID: first.studyInstanceUID,
                studyDescription: first.studyDescription,
                studyDate: first.studyDate,
                files: fs
            )
            out.append(s)
        }
        return out.sorted { $0.description < $1.description }
    }
}

public struct DICOMSeries: Identifiable {
    public var id: String { uid }
    public var uid: String
    public var modality: String
    public var description: String
    public var patientID: String
    public var patientName: String
    public var studyUID: String
    public var studyDescription: String
    public var studyDate: String
    public var files: [DICOMFile]
    public var instanceCount: Int { files.count }

    public var displayName: String {
        "\(modality) - \(description.isEmpty ? "Series" : description) (\(instanceCount))"
    }
}

// MARK: - Data reading helpers

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return self.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
    }
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return self.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
    }
}
