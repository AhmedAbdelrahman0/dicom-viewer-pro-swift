import Foundation
import SwiftUI
import Compression
import simd

/// Read and write segmentation/annotation files in the major medical imaging
/// formats:
///
///   • **NIfTI labelmap** (`.nii` / `.nii.gz`) — integer mask
///   • **MetaImage** (`.mha`) — Grand Challenge / SimpleITK-compatible mask
///   • **ITK-SNAP label descriptor** (`.label.txt`) — name/color sidecar
///   • **3D Slicer segmentation** (`.seg.nrrd`) — NRRD with segment metadata
///   • **NRRD** labelmap (`.nrrd`) — simple integer NRRD
///   • **DICOM SEG** — binary DICOM segmentation object
///   • **DICOM RTSTRUCT** — contour-based RT structures
///   • **JSON annotations** (COCO, CVAT-style, plain points/boxes)
///   • **BIDS derivatives** (NIfTI + JSON sidecar)
public enum LabelIO {
    public enum LabelIOError: Error, LocalizedError {
        case compressionFailed(String)
        case unsupportedNRRD(String)
        case invalidLabelPackage(String)
        case geometryMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .compressionFailed(let message): return "Label compression failed: \(message)"
            case .unsupportedNRRD(let message): return "Unsupported NRRD labelmap: \(message)"
            case .invalidLabelPackage(let message): return "Invalid label package: \(message)"
            case .geometryMismatch(let message): return "Label geometry mismatch: \(message)"
            }
        }
    }

    // Recognized file types
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case labelPackage = "DICOM Viewer Labels"
        case niftiLabelmap = "NIfTI Labelmap"
        case niftiGz = "NIfTI (.nii.gz)"
        case metaImageMHA = "MetaImage MHA"
        case nrrdLabelmap = "NRRD Labelmap"
        case slicerSeg = "3D Slicer .seg.nrrd"
        case dicomSeg = "DICOM SEG"
        case dicomRTStruct = "DICOM RTSTRUCT"
        case itkSnap = "ITK-SNAP (.nii + .label.txt)"
        case json = "JSON Annotations"
        case csv = "CSV Landmarks"

        public var id: String { rawValue }

        public var fileExtensions: [String] {
            switch self {
            case .labelPackage:  return ["dvlabels"]
            case .niftiLabelmap: return ["nii"]
            case .niftiGz:       return ["nii.gz"]
            case .metaImageMHA:  return ["mha"]
            case .nrrdLabelmap:  return ["nrrd"]
            case .slicerSeg:     return ["seg.nrrd"]
            case .dicomSeg:      return ["dcm"]
            case .dicomRTStruct: return ["dcm"]
            case .itkSnap:       return ["nii", "nii.gz"]
            case .json:          return ["json"]
            case .csv:           return ["csv"]
            }
        }
    }

    public struct LabelPackageLoadResult {
        public let labelMap: LabelMap
        public let annotations: [Annotation]
        public let landmarks: [LandmarkPair]
    }

    // MARK: - NIfTI labelmap save

    /// Save a `LabelMap` as a NIfTI-1 single-file `.nii` (uncompressed) with
    /// an ITK-SNAP-compatible label descriptor sidecar.
    public static func saveNIfTI(_ label: LabelMap,
                                  to url: URL,
                                  parentVolume: ImageVolume,
                                  writeLabelDescriptor: Bool = true) throws {
        try niftiLabelData(label, parentVolume: parentVolume).write(to: url, options: [.atomic])

        if writeLabelDescriptor {
            try saveITKSnapDescriptor(label, to: url.deletingPathExtension().appendingPathExtension("label.txt"))
        }
    }

    /// Save a label map as a valid gzip-compressed NIfTI-1 file (`.nii.gz`).
    public static func saveNIfTIGz(_ label: LabelMap,
                                   to url: URL,
                                   parentVolume: ImageVolume,
                                   writeLabelDescriptor: Bool = true) throws {
        let nifti = niftiLabelData(label, parentVolume: parentVolume)
        let compressed = try gzip(nifti)
        // Atomic so cohort runs (which write + immediately read each study's
        // labels.nii.gz) never see a half-written gz that blows up gunzip.
        try compressed.write(to: url, options: [.atomic])

        if writeLabelDescriptor {
            try saveITKSnapDescriptor(label, to: url.deletingPathExtension().appendingPathExtension("label.txt"))
        }
    }

    // MARK: - NIfTI labelmap load

    public static func loadNIfTILabelmap(from url: URL,
                                          parentVolume: ImageVolume? = nil) throws -> LabelMap {
        let volume = try NIfTILoader.load(url, modalityHint: "SEG")

        // Convert float pixels back to UInt16 label values
        var voxels = [UInt16](repeating: 0, count: volume.pixels.count)
        for i in 0..<volume.pixels.count {
            let v = volume.pixels[i]
            if v > 0 && v < 65535 {
                voxels[i] = UInt16(v.rounded())
            }
        }

        let label = LabelMap(
            parentSeriesUID: parentVolume?.seriesUID ?? "",
            depth: volume.depth,
            height: volume.height,
            width: volume.width,
            name: url.deletingPathExtension().lastPathComponent
        )
        label.voxels = voxels

        // Try to load matching ITK-SNAP descriptor
        let descURL = url.deletingPathExtension().appendingPathExtension("label.txt")
        if FileManager.default.fileExists(atPath: descURL.path) {
            if let classes = try? loadITKSnapDescriptor(from: descURL) {
                label.classes = classes
            }
        }

        // If no classes found, auto-generate from unique values
        if label.classes.isEmpty {
            let unique = Set(voxels.filter { $0 != 0 })
            let colors: [Color] = [.red, .green, .blue, .yellow, .orange, .purple, .pink,
                                     .cyan, .mint, .indigo, .teal, .brown]
            for (i, v) in unique.sorted().enumerated() {
                label.classes.append(LabelClass(
                    labelID: v,
                    name: "Label \(v)",
                    category: .custom,
                    color: colors[i % colors.count]
                ))
            }
        }

        return label
    }

    // MARK: - Native package

    public static func saveLabelPackage(labelMap: LabelMap,
                                        annotations: [Annotation],
                                        landmarks: [LandmarkPair],
                                        parentVolume: ImageVolume,
                                        to url: URL) throws {
        let package = LabelPackageDTO(
            version: 1,
            generator: "Tracer",
            parentSeriesUID: labelMap.parentSeriesUID,
            name: labelMap.name,
            dimensions: DimensionsDTO(width: labelMap.width, height: labelMap.height, depth: labelMap.depth),
            spacing: Vector3DTO(parentVolume.spacing.x, parentVolume.spacing.y, parentVolume.spacing.z),
            origin: Vector3DTO(parentVolume.origin.x, parentVolume.origin.y, parentVolume.origin.z),
            directionColumns: [
                Vector3DTO(parentVolume.direction[0].x, parentVolume.direction[0].y, parentVolume.direction[0].z),
                Vector3DTO(parentVolume.direction[1].x, parentVolume.direction[1].y, parentVolume.direction[1].z),
                Vector3DTO(parentVolume.direction[2].x, parentVolume.direction[2].y, parentVolume.direction[2].z)
            ],
            classes: labelMap.classes.map(LabelClassDTO.init),
            voxelsRLE: encodeRLE(labelMap.voxels),
            annotations: annotations.map(AnnotationDTO.init),
            landmarks: landmarks.map(LandmarkDTO.init)
        )
        let data = try JSONEncoder.prettySorted.encode(package)
        try data.write(to: url, options: [.atomic])
    }

    public static func loadLabelPackage(from url: URL,
                                        parentVolume: ImageVolume? = nil) throws -> LabelPackageLoadResult {
        let data = try Data(contentsOf: url)
        let package = try JSONDecoder().decode(LabelPackageDTO.self, from: data)
        let expectedCount = package.dimensions.width * package.dimensions.height * package.dimensions.depth
        let voxels = try decodeRLE(package.voxelsRLE, expectedCount: expectedCount)

        if let parentVolume {
            guard parentVolume.width == package.dimensions.width,
                  parentVolume.height == package.dimensions.height,
                  parentVolume.depth == package.dimensions.depth else {
                throw LabelIOError.geometryMismatch(
                    "package \(package.dimensions.width)x\(package.dimensions.height)x\(package.dimensions.depth), current volume \(parentVolume.width)x\(parentVolume.height)x\(parentVolume.depth)"
                )
            }
        }

        let labelMap = LabelMap(
            parentSeriesUID: parentVolume?.seriesUID ?? package.parentSeriesUID,
            depth: package.dimensions.depth,
            height: package.dimensions.height,
            width: package.dimensions.width,
            name: package.name,
            classes: package.classes.map { $0.labelClass }
        )
        labelMap.voxels = voxels

        return LabelPackageLoadResult(
            labelMap: labelMap,
            annotations: package.annotations.map(\.annotation),
            landmarks: package.landmarks.map(\.landmark)
        )
    }

    // MARK: - ITK-SNAP descriptor (.label.txt)

    /// Save ITK-SNAP-compatible label descriptor:
    ///     IDX   R   G   B   A  VIS  MSH  LABEL
    public static func saveITKSnapDescriptor(_ label: LabelMap, to url: URL) throws {
        var txt = "################################################\n"
        txt += "# ITK-SnAP Label Description File\n"
        txt += "# Generated by Tracer\n"
        txt += "# Format: IDX R G B A VIS MSH LABEL\n"
        txt += "################################################\n"
        txt += "    0     0    0    0        0  0  0    \"Clear Label\"\n"

        for cls in label.classes {
            let (r, g, b) = cls.color.rgbBytes()
            let vis = cls.visible ? 1 : 0
            let alpha = Int(cls.opacity * 255)
            txt += String(format: "%5d %5d %5d %5d %8d %d %d    \"%@\"\n",
                          Int(cls.labelID), Int(r), Int(g), Int(b), alpha,
                          vis, 1, cls.name)
        }

        try txt.data(using: .utf8)?.write(to: url, options: [.atomic])
    }

    /// Load ITK-SNAP label descriptor.
    public static func loadITKSnapDescriptor(from url: URL) throws -> [LabelClass] {
        let txt = try String(contentsOf: url, encoding: .utf8)
        var classes: [LabelClass] = []
        for raw in txt.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Tokens: IDX R G B A VIS MSH "LABEL"
            guard let firstQuote = line.firstIndex(of: "\"") else { continue }
            let numberPart = String(line[..<firstQuote])
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard numberPart.count >= 7 else { continue }

            let idx = Int(numberPart[0]) ?? 0
            if idx == 0 { continue }
            let r = Int(numberPart[1]) ?? 255
            let g = Int(numberPart[2]) ?? 255
            let b = Int(numberPart[3]) ?? 255
            let alpha = Int(numberPart[4]) ?? 255
            let vis = (Int(numberPart[5]) ?? 1) != 0

            // Label = text between quotes
            let after = String(line[line.index(after: firstQuote)...])
            let labelName = after.replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)

            classes.append(LabelClass(
                labelID: UInt16(idx),
                name: labelName.isEmpty ? "Label \(idx)" : labelName,
                category: inferCategory(from: labelName),
                color: Color(r: r, g: g, b: b),
                opacity: Double(alpha) / 255.0,
                visible: vis
            ))
        }
        return classes
    }

    // MARK: - NRRD (simple integer labelmap)

    /// Save as NRRD — compatible with 3D Slicer import.
    public static func saveNRRD(_ label: LabelMap,
                                 to url: URL,
                                 parentVolume: ImageVolume) throws {
        let ox = parentVolume.origin.x
        let oy = parentVolume.origin.y
        let oz = parentVolume.origin.z

        var header = "NRRD0004\n"
        header += "# Generated by Tracer\n"
        header += "type: ushort\n"
        header += "dimension: 3\n"
        header += "space: left-posterior-superior\n"
        header += "sizes: \(label.width) \(label.height) \(label.depth)\n"
        header += "space directions: \(nrrdSpaceDirections(for: parentVolume))\n"
        header += "kinds: domain domain domain\n"
        header += "endian: little\n"
        header += "encoding: raw\n"
        header += "space origin: (\(ox),\(oy),\(oz))\n"
        header += "\n"  // blank line terminates header

        var data = header.data(using: .ascii) ?? Data()
        label.voxels.withUnsafeBufferPointer { buf in
            data.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        try data.write(to: url, options: [.atomic])
    }

    public static func loadNRRDLabelmap(from url: URL,
                                        parentVolume: ImageVolume? = nil) throws -> LabelMap {
        let data = try Data(contentsOf: url)
        let split = try splitNRRDHeader(data)
        guard let headerText = String(data: split.header, encoding: .ascii) else {
            throw LabelIOError.unsupportedNRRD("header is not ASCII")
        }
        let fields = parseNRRDHeader(headerText)

        let dimension = Int(fields["dimension"] ?? "3") ?? 3
        guard dimension == 3 else {
            throw LabelIOError.unsupportedNRRD("only 3D integer labelmaps are supported; got dimension \(dimension)")
        }
        guard let sizes = fields["sizes"]?.split(separator: " ").compactMap({ Int($0) }),
              sizes.count >= 3 else {
            throw LabelIOError.unsupportedNRRD("missing sizes")
        }
        let width = sizes[0]
        let height = sizes[1]
        let depth = sizes[2]
        let total = width * height * depth

        if let parentVolume {
            guard parentVolume.width == width,
                  parentVolume.height == height,
                  parentVolume.depth == depth else {
                throw LabelIOError.geometryMismatch(
                    "labelmap \(width)x\(height)x\(depth), current volume \(parentVolume.width)x\(parentVolume.height)x\(parentVolume.depth)"
                )
            }
        }

        let encoding = fields["encoding"]?.lowercased() ?? "raw"
        guard encoding == "raw" else {
            throw LabelIOError.unsupportedNRRD("encoding \(encoding)")
        }

        let type = fields["type"]?.lowercased() ?? "ushort"
        let endian = fields["endian"]?.lowercased() ?? "little"
        var voxels = [UInt16](repeating: 0, count: total)
        switch type {
        case "ushort", "uint16", "unsigned short":
            guard data.count >= split.dataOffset + total * 2 else {
                throw LabelIOError.unsupportedNRRD("raw payload is shorter than declared size")
            }
            for i in 0..<total {
                let offset = split.dataOffset + i * 2
                voxels[i] = endian == "big" ? data.readUInt16BE(at: offset) : data.readUInt16LE(at: offset)
            }
        case "uchar", "uint8", "unsigned char":
            guard data.count >= split.dataOffset + total else {
                throw LabelIOError.unsupportedNRRD("raw payload is shorter than declared size")
            }
            for i in 0..<total {
                voxels[i] = UInt16(data[split.dataOffset + i])
            }
        default:
            throw LabelIOError.unsupportedNRRD("type \(type)")
        }

        let label = LabelMap(
            parentSeriesUID: parentVolume?.seriesUID ?? "",
            depth: depth,
            height: height,
            width: width,
            name: url.deletingPathExtension().lastPathComponent
        )
        label.voxels = voxels
        label.classes = classesFromNRRD(fields: fields, voxels: voxels)
        if label.classes.isEmpty {
            label.classes = autogeneratedClasses(from: voxels)
        }
        return label
    }

    // MARK: - 3D Slicer .seg.nrrd

    /// Save a 3D Slicer-compatible segmentation NRRD with segment metadata.
    public static func saveSlicerSeg(_ label: LabelMap,
                                      to url: URL,
                                      parentVolume: ImageVolume) throws {
        var header = "NRRD0004\n"
        header += "# Generated by Tracer\n"
        header += "type: ushort\n"
        header += "dimension: 3\n"
        header += "space: left-posterior-superior\n"
        header += "sizes: \(label.width) \(label.height) \(label.depth)\n"
        header += "space directions: \(nrrdSpaceDirections(for: parentVolume))\n"
        header += "kinds: domain domain domain\n"
        header += "endian: little\n"
        header += "encoding: raw\n"
        header += "space origin: (\(parentVolume.origin.x),\(parentVolume.origin.y),\(parentVolume.origin.z))\n"

        // Segment metadata
        for (i, cls) in label.classes.enumerated() {
            let (r, g, b) = cls.color.rgbBytes()
            let cr = Double(r) / 255, cg = Double(g) / 255, cb = Double(b) / 255
            header += "Segment\(i)_ID:=\(cls.name)_\(cls.labelID)\n"
            header += "Segment\(i)_Name:=\(cls.name)\n"
            header += "Segment\(i)_Color:=\(cr) \(cg) \(cb)\n"
            header += "Segment\(i)_LabelValue:=\(cls.labelID)\n"
            header += "Segment\(i)_Layer:=0\n"
            header += "Segment\(i)_Extent:=0 \(label.width - 1) 0 \(label.height - 1) 0 \(label.depth - 1)\n"
            header += "Segment\(i)_Tags:=Segmentation.Status:inprogress|\n"
        }

        header += "\n"

        var data = header.data(using: .ascii) ?? Data()
        label.voxels.withUnsafeBufferPointer { buf in
            data.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - JSON annotations

    /// Export annotations (measurements, points, classes) as JSON.
    /// Schema is compatible with a subset of COCO / CVAT / VGG formats.
    public static func saveJSON(labelMap: LabelMap,
                                 annotations: [Annotation],
                                 to url: URL) throws {
        var root: [String: Any] = [
            "version": "1.0",
            "generator": "Tracer",
            "seriesUID": labelMap.parentSeriesUID,
            "dimensions": [labelMap.width, labelMap.height, labelMap.depth],
        ]

        var classList: [[String: Any]] = []
        for cls in labelMap.classes {
            let (r, g, b) = cls.color.rgbBytes()
            classList.append([
                "id": Int(cls.labelID),
                "name": cls.name,
                "category": cls.category.rawValue,
                "color": ["r": r, "g": g, "b": b],
                "opacity": cls.opacity,
                "notes": cls.notes,
                "dicomCode": cls.dicomCode ?? "",
                "fmaID": cls.fmaID ?? "",
            ])
        }
        root["classes"] = classList

        var annList: [[String: Any]] = []
        for a in annotations {
            annList.append([
                "id": a.id.uuidString,
                "type": a.type.rawValue,
                "axis": a.axis,
                "sliceIndex": a.sliceIndex,
                "points": a.points.map { ["x": $0.x, "y": $0.y] },
                "label": a.label,
                "value": a.value ?? 0,
                "unit": a.unit,
            ])
        }
        root["annotations"] = annList

        let data = try JSONSerialization.data(withJSONObject: root,
                                                options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }

    public static func loadJSONAnnotations(from url: URL,
                                           parentVolume: ImageVolume) throws -> LabelPackageLoadResult {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw LabelIOError.invalidLabelPackage("JSON annotation root must be an object")
        }

        let labelMap = LabelMap(
            parentSeriesUID: parentVolume.seriesUID,
            depth: parentVolume.depth,
            height: parentVolume.height,
            width: parentVolume.width,
            name: url.deletingPathExtension().lastPathComponent,
            classes: jsonClasses(from: root["classes"])
        )
        let annotations = jsonAnnotations(from: root["annotations"])
        return LabelPackageLoadResult(labelMap: labelMap,
                                      annotations: annotations,
                                      landmarks: [])
    }

    // MARK: - CSV landmarks

    /// Export landmark pairs as CSV (one row per landmark).
    public static func saveLandmarks(_ landmarks: [LandmarkPair], to url: URL) throws {
        var csv = "label,fixed_x,fixed_y,fixed_z,moving_x,moving_y,moving_z\n"
        for lm in landmarks {
            csv += "\(lm.label),\(lm.fixed.x),\(lm.fixed.y),\(lm.fixed.z),"
            csv += "\(lm.moving.x),\(lm.moving.y),\(lm.moving.z)\n"
        }
        try csv.data(using: .utf8)?.write(to: url, options: [.atomic])
    }

    public static func loadLandmarks(from url: URL) throws -> [LandmarkPair] {
        let txt = try String(contentsOf: url, encoding: .utf8)
        var result: [LandmarkPair] = []
        for (i, line) in txt.components(separatedBy: .newlines).enumerated() {
            if i == 0 || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let parts = line.components(separatedBy: ",")
            if parts.count < 7 { continue }
            let label = parts[0]
            guard let fx = Double(parts[1]), let fy = Double(parts[2]),
                  let fz = Double(parts[3]), let mx = Double(parts[4]),
                  let my = Double(parts[5]), let mz = Double(parts[6])
            else { continue }
            result.append(LandmarkPair(
                fixed: SIMD3(fx, fy, fz),
                moving: SIMD3(mx, my, mz),
                label: label
            ))
        }
        return result
    }

    // MARK: - Helpers

    private static func niftiLabelData(_ label: LabelMap,
                                       parentVolume: ImageVolume) -> Data {
        let hdr = buildNIfTIHeader(
            width: label.width,
            height: label.height,
            depth: label.depth,
            spacing: parentVolume.spacing,
            origin: parentVolume.origin,
            direction: parentVolume.direction,
            datatype: 512  // UINT16
        )

        var bytes = Data()
        bytes.append(hdr)

        // Pixel data — UINT16 voxels
        label.voxels.withUnsafeBufferPointer { buf in
            bytes.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        return bytes
    }

    private static func nrrdSpaceDirections(for volume: ImageVolume) -> String {
        let xAxis = volume.direction[0] * volume.spacing.x
        let yAxis = volume.direction[1] * volume.spacing.y
        let zAxis = volume.direction[2] * volume.spacing.z
        return "\(nrrdVector(xAxis)) \(nrrdVector(yAxis)) \(nrrdVector(zAxis))"
    }

    private static func nrrdVector(_ vector: SIMD3<Double>) -> String {
        "(\(formatNRRDNumber(vector.x)),\(formatNRRDNumber(vector.y)),\(formatNRRDNumber(vector.z)))"
    }

    private static func formatNRRDNumber(_ value: Double) -> String {
        String(format: "%.12g", value)
    }

    /// Gzip-compress a payload. Used by `saveNIfTIGz` for label maps and
    /// (since the cohort AC step) by `CohortBatchProcessor` to compress
    /// AC PET sidecars to `ac.nii.gz`. Raised to internal access so the
    /// cohort module can reuse the same compression path.
    static func gzip(_ data: Data) throws -> Data {
        var capacity = max(64, data.count + data.count / 16 + 64)
        while capacity < Int(Int32.max) {
            var compressed = Data(count: capacity)
            let compressedCount = compressed.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_encode_buffer(
                        dst.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        capacity,
                        src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if compressedCount > 0 {
                var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
                out.append(compressed.prefix(compressedCount))
                out.appendUInt32LE(crc32(data))
                out.appendUInt32LE(UInt32(truncatingIfNeeded: data.count))
                return out
            }
            capacity *= 2
        }
        throw LabelIOError.compressionFailed("could not encode \(data.count) bytes as gzip")
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let tableIndex = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ crc32Table[tableIndex]
        }
        return crc ^ 0xffffffff
    }

    private static let crc32Table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func buildNIfTIHeader(width: Int, height: Int, depth: Int,
                                          spacing: (Double, Double, Double),
                                          origin: (Double, Double, Double),
                                          direction: simd_double3x3,
                                          datatype: Int16) -> Data {
        var hdr = Data(count: 352)

        hdr.writeInt32(348, at: 0)                  // sizeof_hdr

        hdr.writeInt16(3, at: 40)                   // dim[0] = 3
        hdr.writeInt16(Int16(width), at: 42)        // dim[1]
        hdr.writeInt16(Int16(height), at: 44)       // dim[2]
        hdr.writeInt16(Int16(depth), at: 46)        // dim[3]
        hdr.writeInt16(1, at: 48)                   // dim[4]
        hdr.writeInt16(1, at: 50)                   // dim[5]
        hdr.writeInt16(1, at: 52)                   // dim[6]
        hdr.writeInt16(1, at: 54)                   // dim[7]

        hdr.writeInt16(datatype, at: 70)            // datatype
        let bitpix: Int16 = datatype == 16 ? 32 : (datatype == 64 ? 64 : 16)
        hdr.writeInt16(bitpix, at: 72)              // bitpix

        // pixdim[0..7]
        hdr.writeFloat32(1.0, at: 76)               // qfac
        hdr.writeFloat32(Float(spacing.0), at: 80)
        hdr.writeFloat32(Float(spacing.1), at: 84)
        hdr.writeFloat32(Float(spacing.2), at: 88)

        hdr.writeFloat32(352, at: 108)              // vox_offset
        hdr.writeFloat32(1.0, at: 112)              // scl_slope
        hdr.writeFloat32(0.0, at: 116)              // scl_inter

        // NIfTI stores scanner coordinates as RAS. App geometry is LPS, so X/Y
        // axes and origin are negated when writing the affine.
        let xAxisLPS = direction[0] * spacing.0
        let yAxisLPS = direction[1] * spacing.1
        let zAxisLPS = direction[2] * spacing.2
        let originLPS = SIMD3<Double>(origin.0, origin.1, origin.2)
        let xAxisRAS = lpsVectorToRAS(xAxisLPS)
        let yAxisRAS = lpsVectorToRAS(yAxisLPS)
        let zAxisRAS = lpsVectorToRAS(zAxisLPS)
        let originRAS = lpsVectorToRAS(originLPS)

        // sform: full voxel-to-world affine.
        hdr.writeInt16(0, at: 252)                  // qform_code
        hdr.writeInt16(2, at: 254)                  // sform_code = 2 (aligned)
        hdr.writeFloat32(Float(xAxisRAS.x), at: 280)
        hdr.writeFloat32(Float(yAxisRAS.x), at: 284)
        hdr.writeFloat32(Float(zAxisRAS.x), at: 288)
        hdr.writeFloat32(Float(originRAS.x), at: 292)
        hdr.writeFloat32(Float(xAxisRAS.y), at: 296)
        hdr.writeFloat32(Float(yAxisRAS.y), at: 300)
        hdr.writeFloat32(Float(zAxisRAS.y), at: 304)
        hdr.writeFloat32(Float(originRAS.y), at: 308)
        hdr.writeFloat32(Float(xAxisRAS.z), at: 312)
        hdr.writeFloat32(Float(yAxisRAS.z), at: 316)
        hdr.writeFloat32(Float(zAxisRAS.z), at: 320)
        hdr.writeFloat32(Float(originRAS.z), at: 324)

        // Magic "n+1\0"
        hdr[344] = 0x6E  // n
        hdr[345] = 0x2B  // +
        hdr[346] = 0x31  // 1
        hdr[347] = 0x00

        return hdr
    }

    private static func inferCategory(from name: String) -> LabelCategory {
        let n = name.lowercased()
        if n.contains("gtv") || n.contains("ctv") || n.contains("ptv")
            || n.contains("itv") { return .rtTarget }
        if n.contains("oar") || n.contains("kidney") || n.contains("liver")
            || n.contains("heart") { return .rtOAR }
        if n.contains("tumor") || n.contains("mass") { return .tumor }
        if n.contains("lesion") || n.contains("met") { return .lesion }
        if n.contains("artery") || n.contains("vein") || n.contains("aorta") { return .vessel }
        if n.contains("rib") || n.contains("spine") || n.contains("vertebra")
            || n.contains("bone") { return .bone }
        if n.contains("brain") || n.contains("cortex") { return .brain }
        if n.contains("muscle") { return .muscle }
        if n.contains("fdg") || n.contains("suv") || n.contains("uptake") { return .petHotspot }
        return .organ
    }

    private static func lpsVectorToRAS(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(-v.x, -v.y, v.z)
    }

    private static func splitNRRDHeader(_ data: Data) throws -> (header: Data, dataOffset: Int) {
        let lf = Data([0x0A, 0x0A])
        let crlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        if let range = data.range(of: crlf) {
            return (data.subdata(in: 0..<range.lowerBound), range.upperBound)
        }
        if let range = data.range(of: lf) {
            return (data.subdata(in: 0..<range.lowerBound), range.upperBound)
        }
        throw LabelIOError.unsupportedNRRD("missing blank line after header")
    }

    private static func parseNRRDHeader(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("NRRD") else { continue }
            let separator = line.range(of: ":=") ?? line.range(of: ":")
            guard let separator else { continue }
            let key = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return fields
    }

    private static func classesFromNRRD(fields: [String: String], voxels: [UInt16]) -> [LabelClass] {
        let unique = Set(voxels.filter { $0 != 0 })
        let segmentIndices = fields.keys.compactMap { key -> Int? in
            guard key.hasPrefix("Segment") else { return nil }
            let digits = key.dropFirst("Segment".count).prefix { $0.isNumber }
            return Int(digits)
        }
        let uniqueSegmentIndices = Array(Set(segmentIndices)).sorted()
        var classes: [LabelClass] = []

        for segmentIndex in uniqueSegmentIndices {
            let prefix = "Segment\(segmentIndex)_"
            guard let labelValueText = fields["\(prefix)LabelValue"],
                  let labelValue = UInt16(labelValueText),
                  labelValue != 0,
                  unique.contains(labelValue) || unique.isEmpty else { continue }
            let name = fields["\(prefix)Name"] ?? "Label \(labelValue)"
            let color = colorFromSlicerString(fields["\(prefix)Color"]) ?? autogeneratedColor(index: classes.count)
            classes.append(LabelClass(
                labelID: labelValue,
                name: name,
                category: inferCategory(from: name),
                color: color
            ))
        }

        return classes
    }

    private static func autogeneratedClasses(from voxels: [UInt16]) -> [LabelClass] {
        Set(voxels.filter { $0 != 0 }).sorted().enumerated().map { index, value in
            LabelClass(
                labelID: value,
                name: "Label \(value)",
                category: .custom,
                color: autogeneratedColor(index: index)
            )
        }
    }

    private static func autogeneratedColor(index: Int) -> Color {
        let colors: [Color] = [.red, .green, .blue, .yellow, .orange, .purple, .pink,
                               .cyan, .mint, .indigo, .teal, .brown]
        return colors[index % colors.count]
    }

    private static func colorFromSlicerString(_ value: String?) -> Color? {
        guard let value else { return nil }
        let parts = value.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return Color(
            .displayP3,
            red: max(0, min(1, parts[0])),
            green: max(0, min(1, parts[1])),
            blue: max(0, min(1, parts[2])),
            opacity: 1
        )
    }

    private static func jsonClasses(from object: Any?) -> [LabelClass] {
        guard let items = object as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let labelID = UInt16(jsonInt(item["id"]) ?? jsonInt(item["labelID"]) ?? 0)
            guard labelID != 0 else { return nil }
            let name = jsonString(item["name"]) ?? "Label \(labelID)"
            let category = LabelCategory(rawValue: jsonString(item["category"]) ?? "") ?? inferCategory(from: name)
            let color = jsonColor(item["color"]) ?? autogeneratedColor(index: Int(labelID))
            return LabelClass(labelID: labelID,
                              name: name,
                              category: category,
                              color: color)
        }
    }

    private static func jsonAnnotations(from object: Any?) -> [Annotation] {
        guard let items = object as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let typeText = jsonString(item["type"]) ?? AnnotationType.text.rawValue
            let type = AnnotationType(rawValue: typeText) ?? .text
            let points = (item["points"] as? [[String: Any]])?.compactMap { point -> CGPoint? in
                guard let x = jsonDouble(point["x"]),
                      let y = jsonDouble(point["y"]) else { return nil }
                return CGPoint(x: x, y: y)
            } ?? []
            var annotation = Annotation(
                id: UUID(uuidString: jsonString(item["id"]) ?? "") ?? UUID(),
                type: type,
                points: points,
                axis: jsonInt(item["axis"]) ?? 2,
                sliceIndex: jsonInt(item["sliceIndex"]) ?? 0
            )
            annotation.label = jsonString(item["label"]) ?? ""
            annotation.value = jsonDouble(item["value"])
            annotation.unit = jsonString(item["unit"]) ?? annotation.unit
            return annotation
        }
    }

    private static func jsonColor(_ object: Any?) -> Color? {
        guard let dict = object as? [String: Any],
              let r = jsonInt(dict["r"]),
              let g = jsonInt(dict["g"]),
              let b = jsonInt(dict["b"]) else { return nil }
        return Color(r: r, g: g, b: b)
    }

    private static func jsonString(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func jsonInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func jsonDouble(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func encodeRLE(_ voxels: [UInt16]) -> [RLEEntryDTO] {
        guard let first = voxels.first else { return [] }
        var result: [RLEEntryDTO] = []
        var current = first
        var count = 0
        for voxel in voxels {
            if voxel == current {
                count += 1
            } else {
                result.append(RLEEntryDTO(value: current, count: count))
                current = voxel
                count = 1
            }
        }
        result.append(RLEEntryDTO(value: current, count: count))
        return result
    }

    /// Decode a run-length-encoded voxel stream.
    ///
    /// Validates each run against the declared `expectedCount` *before*
    /// allocating memory. A corrupted package with an impossibly large run —
    /// e.g. `count == Int.max` — would otherwise trigger an unrecoverable
    /// out-of-memory crash inside `repeatElement(_:count:)`.
    fileprivate static func decodeRLE(_ entries: [RLEEntryDTO], expectedCount: Int) throws -> [UInt16] {
        guard expectedCount >= 0 else {
            throw LabelIOError.invalidLabelPackage("negative expected voxel count \(expectedCount)")
        }
        var voxels: [UInt16] = []
        voxels.reserveCapacity(expectedCount)
        var runningTotal = 0
        for (index, entry) in entries.enumerated() {
            guard entry.count >= 0 else {
                throw LabelIOError.invalidLabelPackage(
                    "negative RLE count \(entry.count) at entry \(index)"
                )
            }
            let remaining = expectedCount - runningTotal
            guard entry.count <= remaining else {
                throw LabelIOError.invalidLabelPackage(
                    "RLE run of \(entry.count) at entry \(index) exceeds remaining \(remaining) voxels (expected total \(expectedCount))"
                )
            }
            voxels.append(contentsOf: repeatElement(entry.value, count: entry.count))
            runningTotal += entry.count
        }
        guard runningTotal == expectedCount else {
            throw LabelIOError.invalidLabelPackage(
                "RLE voxel count \(runningTotal) does not match declared \(expectedCount)"
            )
        }
        return voxels
    }
}

private struct LabelPackageDTO: Codable {
    let version: Int
    let generator: String
    let parentSeriesUID: String
    let name: String
    let dimensions: DimensionsDTO
    let spacing: Vector3DTO
    let origin: Vector3DTO
    let directionColumns: [Vector3DTO]
    let classes: [LabelClassDTO]
    let voxelsRLE: [RLEEntryDTO]
    let annotations: [AnnotationDTO]
    let landmarks: [LandmarkDTO]
}

private struct DimensionsDTO: Codable {
    let width: Int
    let height: Int
    let depth: Int
}

private struct Vector3DTO: Codable {
    let x: Double
    let y: Double
    let z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

private struct RLEEntryDTO: Codable {
    let value: UInt16
    let count: Int
}

private struct LabelClassDTO: Codable {
    let labelID: UInt16
    let name: String
    let category: String
    let color: RGBDTO
    let dicomCode: String?
    let fmaID: String?
    let notes: String
    let opacity: Double
    let visible: Bool

    init(_ labelClass: LabelClass) {
        let (r, g, b) = labelClass.color.rgbBytes()
        self.labelID = labelClass.labelID
        self.name = labelClass.name
        self.category = labelClass.category.rawValue
        self.color = RGBDTO(r: r, g: g, b: b)
        self.dicomCode = labelClass.dicomCode
        self.fmaID = labelClass.fmaID
        self.notes = labelClass.notes
        self.opacity = labelClass.opacity
        self.visible = labelClass.visible
    }

    var labelClass: LabelClass {
        LabelClass(
            labelID: labelID,
            name: name,
            category: LabelCategory(rawValue: category) ?? .custom,
            color: Color(r: Int(color.r), g: Int(color.g), b: Int(color.b)),
            dicomCode: dicomCode,
            fmaID: fmaID,
            notes: notes,
            opacity: opacity,
            visible: visible
        )
    }
}

private struct RGBDTO: Codable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

private struct AnnotationDTO: Codable {
    let type: String
    let points: [PointDTO]
    let axis: Int
    let sliceIndex: Int
    let value: Double?
    let unit: String
    let label: String

    init(_ annotation: Annotation) {
        self.type = annotation.type.rawValue
        self.points = annotation.points.map { PointDTO(x: Double($0.x), y: Double($0.y)) }
        self.axis = annotation.axis
        self.sliceIndex = annotation.sliceIndex
        self.value = annotation.value
        self.unit = annotation.unit
        self.label = annotation.label
    }

    var annotation: Annotation {
        var annotation = Annotation(
            type: AnnotationType(rawValue: type) ?? .text,
            points: points.map { CGPoint(x: $0.x, y: $0.y) },
            axis: axis,
            sliceIndex: sliceIndex
        )
        annotation.value = value
        annotation.unit = unit
        annotation.label = label
        return annotation
    }
}

private struct PointDTO: Codable {
    let x: Double
    let y: Double
}

private struct LandmarkDTO: Codable {
    let label: String
    let fixed: Vector3DTO
    let moving: Vector3DTO

    init(_ landmark: LandmarkPair) {
        self.label = landmark.label
        self.fixed = Vector3DTO(landmark.fixed.x, landmark.fixed.y, landmark.fixed.z)
        self.moving = Vector3DTO(landmark.moving.x, landmark.moving.y, landmark.moving.z)
    }

    var landmark: LandmarkPair {
        LandmarkPair(
            fixed: SIMD3(fixed.x, fixed.y, fixed.z),
            moving: SIMD3(moving.x, moving.y, moving.z),
            label: label
        )
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

// MARK: - Data write helpers

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func writeInt16(_ value: Int16, at offset: Int) {
        var v = value
        Swift.withUnsafeBytes(of: &v) { src in
            self.replaceSubrange(offset..<offset+2, with: src)
        }
    }
    mutating func writeInt32(_ value: Int32, at offset: Int) {
        var v = value
        Swift.withUnsafeBytes(of: &v) { src in
            self.replaceSubrange(offset..<offset+4, with: src)
        }
    }
    mutating func writeFloat32(_ value: Float, at offset: Int) {
        var v = value
        Swift.withUnsafeBytes(of: &v) { src in
            self.replaceSubrange(offset..<offset+4, with: src)
        }
    }
}
