import Foundation
import SwiftUI
import Compression

/// Read and write segmentation/annotation files in the major medical imaging
/// formats:
///
///   • **NIfTI labelmap** (`.nii` / `.nii.gz`) — integer mask
///   • **ITK-SNAP label descriptor** (`.label.txt`) — name/color sidecar
///   • **3D Slicer segmentation** (`.seg.nrrd`) — NRRD with segment metadata
///   • **NRRD** labelmap (`.nrrd`) — simple integer NRRD
///   • **DICOM SEG** (read planned) — binary DICOM segmentation object
///   • **DICOM RTSTRUCT** (read planned) — contour-based RT structures
///   • **JSON annotations** (COCO, CVAT-style, plain points/boxes)
///   • **BIDS derivatives** (NIfTI + JSON sidecar)
public enum LabelIO {

    // Recognized file types
    public enum Format: String, CaseIterable, Identifiable {
        case niftiLabelmap = "NIfTI Labelmap"
        case niftiGz = "NIfTI (.nii.gz)"
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
            case .niftiLabelmap: return ["nii"]
            case .niftiGz:       return ["nii.gz"]
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

    // MARK: - NIfTI labelmap save

    /// Save a `LabelMap` as a NIfTI-1 single-file `.nii` (uncompressed) with
    /// an ITK-SNAP-compatible label descriptor sidecar.
    public static func saveNIfTI(_ label: LabelMap,
                                  to url: URL,
                                  parentVolume: ImageVolume,
                                  writeLabelDescriptor: Bool = true) throws {
        let hdr = buildNIfTIHeader(
            width: label.width, height: label.height, depth: label.depth,
            spacing: parentVolume.spacing, origin: parentVolume.origin,
            datatype: 512  // UINT16
        )

        var bytes = Data()
        bytes.append(hdr)

        // 4-byte extension flag (0x00 = no extension)
        bytes.append(Data([0, 0, 0, 0]))

        // Pixel data — UINT16 voxels
        label.voxels.withUnsafeBufferPointer { buf in
            bytes.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }

        try bytes.write(to: url)

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

    // MARK: - ITK-SNAP descriptor (.label.txt)

    /// Save ITK-SNAP-compatible label descriptor:
    ///     IDX   R   G   B   A  VIS  MSH  LABEL
    public static func saveITKSnapDescriptor(_ label: LabelMap, to url: URL) throws {
        var txt = "################################################\n"
        txt += "# ITK-SnAP Label Description File\n"
        txt += "# Generated by DICOM Viewer Pro\n"
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

        try txt.data(using: .utf8)?.write(to: url)
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
        let sx = parentVolume.spacing.x
        let sy = parentVolume.spacing.y
        let sz = parentVolume.spacing.z
        let ox = parentVolume.origin.x
        let oy = parentVolume.origin.y
        let oz = parentVolume.origin.z

        var header = "NRRD0004\n"
        header += "# Generated by DICOM Viewer Pro\n"
        header += "type: ushort\n"
        header += "dimension: 3\n"
        header += "space: left-posterior-superior\n"
        header += "sizes: \(label.width) \(label.height) \(label.depth)\n"
        header += "space directions: (\(sx),0,0) (0,\(sy),0) (0,0,\(sz))\n"
        header += "kinds: domain domain domain\n"
        header += "endian: little\n"
        header += "encoding: raw\n"
        header += "space origin: (\(ox),\(oy),\(oz))\n"
        header += "\n"  // blank line terminates header

        var data = header.data(using: .ascii) ?? Data()
        label.voxels.withUnsafeBufferPointer { buf in
            data.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        try data.write(to: url)
    }

    // MARK: - 3D Slicer .seg.nrrd

    /// Save a 3D Slicer-compatible segmentation NRRD with segment metadata.
    public static func saveSlicerSeg(_ label: LabelMap,
                                      to url: URL,
                                      parentVolume: ImageVolume) throws {
        let sx = parentVolume.spacing.x
        let sy = parentVolume.spacing.y
        let sz = parentVolume.spacing.z

        var header = "NRRD0004\n"
        header += "# Generated by DICOM Viewer Pro\n"
        header += "type: ushort\n"
        header += "dimension: 3\n"
        header += "space: left-posterior-superior\n"
        header += "sizes: \(label.width) \(label.height) \(label.depth)\n"
        header += "space directions: (\(sx),0,0) (0,\(sy),0) (0,0,\(sz))\n"
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
        try data.write(to: url)
    }

    // MARK: - JSON annotations

    /// Export annotations (measurements, points, classes) as JSON.
    /// Schema is compatible with a subset of COCO / CVAT / VGG formats.
    public static func saveJSON(labelMap: LabelMap,
                                 annotations: [Annotation],
                                 to url: URL) throws {
        var root: [String: Any] = [
            "version": "1.0",
            "generator": "DICOM Viewer Pro",
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
        try data.write(to: url)
    }

    // MARK: - CSV landmarks

    /// Export landmark pairs as CSV (one row per landmark).
    public static func saveLandmarks(_ landmarks: [LandmarkPair], to url: URL) throws {
        var csv = "label,fixed_x,fixed_y,fixed_z,moving_x,moving_y,moving_z\n"
        for lm in landmarks {
            csv += "\(lm.label),\(lm.fixed.x),\(lm.fixed.y),\(lm.fixed.z),"
            csv += "\(lm.moving.x),\(lm.moving.y),\(lm.moving.z)\n"
        }
        try csv.data(using: .utf8)?.write(to: url)
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

    private static func buildNIfTIHeader(width: Int, height: Int, depth: Int,
                                          spacing: (Double, Double, Double),
                                          origin: (Double, Double, Double),
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

        // sform: identity + translation from origin (LPS)
        hdr.writeInt16(0, at: 252)                  // qform_code
        hdr.writeInt16(2, at: 254)                  // sform_code = 2 (aligned)
        hdr.writeFloat32(Float(spacing.0), at: 280) // srow_x[0]
        hdr.writeFloat32(Float(origin.0), at: 292)  // srow_x[3]
        hdr.writeFloat32(Float(spacing.1), at: 300) // srow_y[1]
        hdr.writeFloat32(Float(origin.1), at: 312)  // srow_y[3]
        hdr.writeFloat32(Float(spacing.2), at: 324) // srow_z[2]
        hdr.writeFloat32(Float(origin.2), at: 336)  // srow_z[3]

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
}

// MARK: - Data write helpers

private extension Data {
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
