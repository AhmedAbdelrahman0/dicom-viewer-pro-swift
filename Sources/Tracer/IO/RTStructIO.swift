import Foundation
import SwiftUI
import simd

/// DICOM RTSTRUCT (RT Structure Set) read/write support.
///
/// RTSTRUCT stores anatomical contours as sequences of 3D polygon vertices
/// in patient coordinates. This parser:
///  - Reads ROI metadata (name, color, number)
///  - Reads contour sequence (polygons per slice)
///  - Rasterizes contours to a voxel-grid `LabelMap` aligned with a reference volume
///
/// Writer exports a LabelMap back to RTSTRUCT by extracting slice contours
/// from each class's voxel mask.
public enum RTStructIO {
    private static let rtStructureSetStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.481.3"

    /// Parse a DICOM RTSTRUCT file and rasterize contours onto a voxel grid
    /// aligned with `referenceVolume`.
    public static func loadRTStruct(from url: URL,
                                     referenceVolume: ImageVolume) throws -> LabelMap {
        let data = try Data(contentsOf: url)
        guard data.count > 132 else {
            throw DICOMError.invalidFile("RTSTRUCT too small")
        }
        let magic = String(data: data[128..<132], encoding: .ascii) ?? ""
        guard magic == "DICM" else {
            throw DICOMError.notADICOMFile
        }

        let parser = RTStructParser()
        try parser.parse(data)

        let label = LabelMap(
            parentSeriesUID: referenceVolume.seriesUID,
            depth: referenceVolume.depth,
            height: referenceVolume.height,
            width: referenceVolume.width,
            name: "RT Structures"
        )

        // Convert ROIs to LabelClasses and rasterize each one
        for (index, roi) in parser.rois.enumerated() {
            let classID = UInt16(index + 1)
            let cls = LabelClass(
                labelID: classID,
                name: roi.name,
                category: categoryForRT(roi.name),
                color: roi.color ?? Color(r: 255, g: 100, b: 100),
                opacity: 0.5
            )
            label.classes.append(cls)

            for contour in roi.contours {
                rasterizeContour(contour: contour,
                                 volume: referenceVolume,
                                 label: label,
                                 classID: classID)
            }
        }

        return label
    }

    /// Export a voxel label map as a DICOM RT Structure Set.
    ///
    /// RTSTRUCT is contour-based, so each axial mask slice is converted into
    /// closed planar voxel-edge contours. For lossless voxel exchange, prefer
    /// DICOM SEG; RTSTRUCT is provided for RT planning and PACS workflows that
    /// expect contour objects.
    public static func saveRTStruct(_ labelMap: LabelMap,
                                    parentVolume: ImageVolume,
                                    to url: URL) throws {
        let classes = exportClasses(for: labelMap)
        guard !classes.isEmpty else {
            throw LabelIO.LabelIOError.invalidLabelPackage("RTSTRUCT export needs at least one label class")
        }

        let now = DICOMExportWriter.currentDateTime()
        let studyUID = DICOMExportWriter.dicomUID(parentVolume.studyUID)
        let seriesUID = DICOMExportWriter.makeUID()
        let sopUID = DICOMExportWriter.makeUID()
        let frameOfReferenceUID = DICOMExportWriter.makeUID()
        let contoursByLabel = Dictionary(uniqueKeysWithValues: classes.map { labelClass in
            (labelClass.labelID, contours(for: labelMap,
                                          classID: labelClass.labelID,
                                          volume: parentVolume))
        })

        var dataset = Data()
        dataset.appendDICOMElement(group: 0x0008, element: 0x0008, vr: "CS", strings: ["DERIVED", "PRIMARY"])
        dataset.appendDICOMElement(group: 0x0008, element: 0x0016, vr: "UI", string: rtStructureSetStorageSOPClassUID)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0018, vr: "UI", string: sopUID)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0020, vr: "DA", string: now.date)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0023, vr: "DA", string: now.date)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0030, vr: "TM", string: now.time)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0033, vr: "TM", string: now.time)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0060, vr: "CS", string: "RTSTRUCT")
        dataset.appendDICOMElement(group: 0x0008, element: 0x0070, vr: "LO", string: "Tracer")
        dataset.appendDICOMElement(group: 0x0008, element: 0x1030, vr: "LO", string: parentVolume.studyDescription)
        dataset.appendDICOMElement(group: 0x0008, element: 0x103E, vr: "LO", string: "\(labelMap.name) RTSTRUCT")
        dataset.appendDICOMElement(group: 0x0010, element: 0x0010, vr: "PN", string: patientName(parentVolume))
        dataset.appendDICOMElement(group: 0x0010, element: 0x0020, vr: "LO", string: patientID(parentVolume))
        dataset.appendDICOMElement(group: 0x0020, element: 0x000D, vr: "UI", string: studyUID)
        dataset.appendDICOMElement(group: 0x0020, element: 0x000E, vr: "UI", string: seriesUID)
        dataset.appendDICOMElement(group: 0x0020, element: 0x0011, vr: "IS", string: "901")
        dataset.appendDICOMElement(group: 0x0020, element: 0x0013, vr: "IS", string: "1")
        dataset.appendDICOMElement(group: 0x0020, element: 0x0052, vr: "UI", string: frameOfReferenceUID)
        dataset.appendDICOMElement(group: 0x3006, element: 0x0002, vr: "SH", string: labelMap.name.isEmpty ? "Tracer Labels" : labelMap.name)
        dataset.appendDICOMElement(group: 0x3006, element: 0x0008, vr: "DA", string: now.date)
        dataset.appendDICOMElement(group: 0x3006, element: 0x0009, vr: "TM", string: now.time)
        dataset.appendDICOMSequence(group: 0x3006, element: 0x0010, items: [
            referencedFrameOfReferenceItem(frameOfReferenceUID: frameOfReferenceUID,
                                           studyUID: studyUID,
                                           seriesUID: DICOMExportWriter.dicomUID(parentVolume.seriesUID))
        ])
        dataset.appendDICOMSequence(group: 0x3006, element: 0x0020, items: structureSetROIItems(
            classes,
            frameOfReferenceUID: frameOfReferenceUID
        ))
        dataset.appendDICOMSequence(group: 0x3006, element: 0x0039, items: roiContourItems(
            classes,
            contoursByLabel: contoursByLabel
        ))
        dataset.appendDICOMSequence(group: 0x3006, element: 0x0080, items: rtROIObservationItems(classes))

        let file = DICOMExportWriter.part10File(
            sopClassUID: rtStructureSetStorageSOPClassUID,
            sopInstanceUID: sopUID,
            dataset: dataset
        )
        try file.write(to: url, options: [.atomic])
    }

    /// Rasterize a polygon contour onto an axial slice using point-in-polygon test.
    private static func rasterizeContour(contour: [SIMD3<Double>],
                                          volume: ImageVolume,
                                          label: LabelMap,
                                          classID: UInt16) {
        guard contour.count >= 3 else { return }

        let voxelPoints = contour.map { volume.voxelCoordinates(from: $0) }
        let meanZ = voxelPoints.reduce(0.0) { $0 + $1.z } / Double(voxelPoints.count)
        let sliceIdx = Int(round(meanZ))
        guard sliceIdx >= 0, sliceIdx < volume.depth else { return }

        let points2D: [(Double, Double)] = voxelPoints.map { ($0.x, $0.y) }

        // Compute 2D bounding box
        let minX = max(0, Int(floor(points2D.map(\.0).min() ?? 0)))
        let maxX = min(volume.width - 1, Int(ceil(points2D.map(\.0).max() ?? 0)))
        let minY = max(0, Int(floor(points2D.map(\.1).min() ?? 0)))
        let maxY = min(volume.height - 1, Int(ceil(points2D.map(\.1).max() ?? 0)))

        // Scan-line rasterization (point-in-polygon)
        for yi in minY...maxY {
            for xi in minX...maxX {
                if pointInPolygon(x: Double(xi) + 0.5,
                                  y: Double(yi) + 0.5,
                                  polygon: points2D) {
                    let idx = label.index(z: sliceIdx, y: yi, x: xi)
                    label.voxels[idx] = classID
                }
            }
        }
    }

    private static func pointInPolygon(x: Double, y: Double,
                                        polygon: [(Double, Double)]) -> Bool {
        var inside = false
        let n = polygon.count
        var j = n - 1
        for i in 0..<n {
            let (xi, yi) = polygon[i]
            let (xj, yj) = polygon[j]
            if ((yi > y) != (yj > y)) &&
               (x < (xj - xi) * (y - yi) / ((yj - yi) + 1e-12) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private static func categoryForRT(_ name: String) -> LabelCategory {
        let n = name.uppercased()
        if n.hasPrefix("GTV") || n.hasPrefix("CTV") || n.hasPrefix("ITV") || n.hasPrefix("PTV") {
            return .rtTarget
        }
        return .rtOAR
    }

    private struct ExportContour {
        let points: [SIMD3<Double>]
    }

    private struct GridPoint: Hashable {
        let x: Int
        let y: Int
    }

    private struct GridEdge {
        let start: GridPoint
        let end: GridPoint
    }

    private static func contours(for labelMap: LabelMap,
                                 classID: UInt16,
                                 volume: ImageVolume) -> [ExportContour] {
        var result: [ExportContour] = []
        for z in 0..<labelMap.depth {
            let loops = contourLoops(for: labelMap, classID: classID, z: z)
            for loop in loops where loop.count >= 4 {
                let worldPoints = loop.map { point in
                    volume.worldPoint(voxel: SIMD3<Double>(
                        Double(point.x),
                        Double(point.y),
                        Double(z)
                    ))
                }
                result.append(ExportContour(points: worldPoints))
            }
        }
        return result
    }

    private static func contourLoops(for labelMap: LabelMap,
                                     classID: UInt16,
                                     z: Int) -> [[GridPoint]] {
        var edges: [GridEdge] = []
        func isClass(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < labelMap.width, y >= 0, y < labelMap.height else { return false }
            return labelMap.value(z: z, y: y, x: x) == classID
        }

        for y in 0..<labelMap.height {
            for x in 0..<labelMap.width where isClass(x, y) {
                if !isClass(x, y - 1) {
                    edges.append(GridEdge(start: GridPoint(x: x, y: y),
                                          end: GridPoint(x: x + 1, y: y)))
                }
                if !isClass(x + 1, y) {
                    edges.append(GridEdge(start: GridPoint(x: x + 1, y: y),
                                          end: GridPoint(x: x + 1, y: y + 1)))
                }
                if !isClass(x, y + 1) {
                    edges.append(GridEdge(start: GridPoint(x: x + 1, y: y + 1),
                                          end: GridPoint(x: x, y: y + 1)))
                }
                if !isClass(x - 1, y) {
                    edges.append(GridEdge(start: GridPoint(x: x, y: y + 1),
                                          end: GridPoint(x: x, y: y)))
                }
            }
        }

        var unused = Set(edges.indices)
        var outgoing: [GridPoint: [Int]] = [:]
        for (index, edge) in edges.enumerated() {
            outgoing[edge.start, default: []].append(index)
        }

        var loops: [[GridPoint]] = []
        while let firstIndex = unused.first {
            unused.remove(firstIndex)
            let firstEdge = edges[firstIndex]
            let start = firstEdge.start
            var current = firstEdge.end
            var loop = [start, current]

            while current != start {
                guard let nextIndex = outgoing[current]?.first(where: { unused.contains($0) }) else {
                    break
                }
                unused.remove(nextIndex)
                current = edges[nextIndex].end
                loop.append(current)
            }

            if loop.last == start {
                loop.removeLast()
                loops.append(loop)
            }
        }
        return loops
    }

    private static func referencedFrameOfReferenceItem(frameOfReferenceUID: String,
                                                       studyUID: String,
                                                       seriesUID: String) -> Data {
        var seriesItem = Data()
        seriesItem.appendDICOMElement(group: 0x0020, element: 0x000E, vr: "UI", string: seriesUID)

        var studyItem = Data()
        studyItem.appendDICOMElement(group: 0x0008, element: 0x1150, vr: "UI", string: "1.2.840.10008.3.1.2.3.1")
        studyItem.appendDICOMElement(group: 0x0008, element: 0x1155, vr: "UI", string: studyUID)
        studyItem.appendDICOMSequence(group: 0x3006, element: 0x0014, items: [seriesItem])

        var item = Data()
        item.appendDICOMElement(group: 0x0020, element: 0x0052, vr: "UI", string: frameOfReferenceUID)
        item.appendDICOMSequence(group: 0x3006, element: 0x0012, items: [studyItem])
        return item
    }

    private static func structureSetROIItems(_ classes: [LabelClass],
                                             frameOfReferenceUID: String) -> [Data] {
        classes.enumerated().map { index, labelClass in
            var item = Data()
            item.appendDICOMElement(group: 0x3006, element: 0x0022, vr: "IS", string: "\(index + 1)")
            item.appendDICOMElement(group: 0x3006, element: 0x0024, vr: "UI", string: frameOfReferenceUID)
            item.appendDICOMElement(group: 0x3006, element: 0x0026, vr: "LO", string: labelClass.name)
            item.appendDICOMElement(group: 0x3006, element: 0x0036, vr: "CS", string: "SEMIAUTOMATIC")
            return item
        }
    }

    private static func roiContourItems(_ classes: [LabelClass],
                                        contoursByLabel: [UInt16: [ExportContour]]) -> [Data] {
        classes.enumerated().map { index, labelClass in
            let (r, g, b) = DICOMExportWriter.rgbComponents(labelClass.color)
            var item = Data()
            item.appendDICOMElement(group: 0x3006, element: 0x002A, vr: "IS", string: "\(r)\\\(g)\\\(b)")
            item.appendDICOMSequence(group: 0x3006, element: 0x0040, items: (contoursByLabel[labelClass.labelID] ?? []).map(contourItem))
            item.appendDICOMElement(group: 0x3006, element: 0x0084, vr: "IS", string: "\(index + 1)")
            return item
        }
    }

    private static func contourItem(_ contour: ExportContour) -> Data {
        var item = Data()
        item.appendDICOMElement(group: 0x3006, element: 0x0042, vr: "CS", string: "CLOSED_PLANAR")
        item.appendDICOMElement(group: 0x3006, element: 0x0046, vr: "IS", string: "\(contour.points.count)")
        let values = contour.points.flatMap { [$0.x, $0.y, $0.z] }
        item.appendDICOMElement(group: 0x3006, element: 0x0050, vr: "DS", string: DICOMExportWriter.ds(values))
        return item
    }

    private static func rtROIObservationItems(_ classes: [LabelClass]) -> [Data] {
        classes.enumerated().map { index, labelClass in
            var item = Data()
            item.appendDICOMElement(group: 0x3006, element: 0x0082, vr: "IS", string: "\(index + 1)")
            item.appendDICOMElement(group: 0x3006, element: 0x0084, vr: "IS", string: "\(index + 1)")
            item.appendDICOMElement(group: 0x3006, element: 0x00A4, vr: "CS", string: rtInterpretedType(for: labelClass))
            item.appendDICOMElement(group: 0x3006, element: 0x00A6, vr: "PN", string: "Tracer")
            return item
        }
    }

    private static func rtInterpretedType(for labelClass: LabelClass) -> String {
        switch labelClass.category {
        case .rtTarget, .tumor, .lesion, .petHotspot, .pathology, .nuclearUptake:
            return "GTV"
        case .rtOAR, .rtStructure, .organ, .bone, .brain, .muscle, .vessel, .cardiac:
            return "ORGAN"
        case .custom:
            return "CONTROL"
        }
    }

    private static func exportClasses(for labelMap: LabelMap) -> [LabelClass] {
        if !labelMap.classes.isEmpty {
            return labelMap.classes.sorted { $0.labelID < $1.labelID }
        }
        return Set(labelMap.voxels.filter { $0 != 0 })
            .sorted()
            .enumerated()
            .map { index, labelID in
                LabelClass(labelID: labelID,
                           name: "Label \(labelID)",
                           category: .custom,
                           color: autogeneratedColor(index: index))
            }
    }

    private static func autogeneratedColor(index: Int) -> Color {
        let colors: [Color] = [.red, .green, .blue, .yellow, .orange, .purple, .pink,
                               .cyan, .mint, .indigo, .teal, .brown]
        return colors[index % colors.count]
    }

    private static func patientName(_ volume: ImageVolume) -> String {
        volume.patientName.isEmpty ? "Anonymous" : volume.patientName
    }

    private static func patientID(_ volume: ImageVolume) -> String {
        volume.patientID.isEmpty ? "UNKNOWN" : volume.patientID
    }
}

// MARK: - RTSTRUCT parser (minimal, reads contour sequence)

private final class RTStructParser {

    struct ROI {
        var number: Int = 0
        var name: String = ""
        var color: Color?
        var contours: [[SIMD3<Double>]] = []
    }

    var rois: [ROI] = []

    func parse(_ data: Data) throws {
        // For a lightweight RTSTRUCT parser we walk the top-level Data Set
        // and extract:
        //   (3006,0020) StructureSetROISequence: ROIName, ROINumber
        //   (3006,0039) ROIContourSequence: color, per-ROI contour data
        // Full DICOM SQ parsing is complex; this covers the common cases for
        // Explicit-VR Little-Endian RTSTRUCT files.
        let reader = DICOMSequenceReader(data: data)
        reader.parse()

        // Build ROI entries from StructureSetROISequence
        var roiNameByNumber: [Int: String] = [:]
        for item in reader.items(group: 0x3006, element: 0x0020) {
            let num = Int(item.stringValue(group: 0x3006, element: 0x0022) ?? "0") ?? 0
            let name = item.stringValue(group: 0x3006, element: 0x0026) ?? ""
            roiNameByNumber[num] = name
        }

        // Build contours from ROIContourSequence
        for item in reader.items(group: 0x3006, element: 0x0039) {
            var roi = ROI()
            let refNum = Int(item.stringValue(group: 0x3006, element: 0x0084) ?? "0") ?? 0
            roi.number = refNum
            roi.name = roiNameByNumber[refNum] ?? "ROI \(refNum)"

            // ROI Display Color (3006,002A) - three integers
            if let colorStr = item.stringValue(group: 0x3006, element: 0x002A) {
                let comps = colorStr.split(separator: "\\").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if comps.count >= 3 {
                    roi.color = Color(r: comps[0], g: comps[1], b: comps[2])
                }
            }

            // Contour Sequence (3006,0040)
            for contourItem in item.subItems(group: 0x3006, element: 0x0040) {
                // Contour Data (3006,0050) - list of x\y\z triples
                if let dataStr = contourItem.stringValue(group: 0x3006, element: 0x0050) {
                    let nums = dataStr.split(separator: "\\").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    var pts: [SIMD3<Double>] = []
                    var i = 0
                    while i + 2 < nums.count {
                        pts.append(SIMD3<Double>(nums[i], nums[i+1], nums[i+2]))
                        i += 3
                    }
                    if !pts.isEmpty {
                        roi.contours.append(pts)
                    }
                }
            }

            rois.append(roi)
        }
    }
}

// Minimal DICOM sequence reader — walks the dataset structure
// and exposes items() and subItems() for nested sequences.
private final class DICOMSequenceReader {
    let data: Data

    // Top-level flat list of (group, element, value-range, children)
    class ParsedItem {
        var tag: UInt32
        var valueStart: Int
        var valueEnd: Int
        var vr: String
        var children: [ParsedItem] = []
        weak var reader: DICOMSequenceReader?

        init(tag: UInt32, valueStart: Int, valueEnd: Int, vr: String,
             children: [ParsedItem] = [], reader: DICOMSequenceReader? = nil) {
            self.tag = tag
            self.valueStart = valueStart
            self.valueEnd = valueEnd
            self.vr = vr
            self.children = children
            self.reader = reader
        }

        func stringValue(group: UInt16, element: UInt16) -> String? {
            let targetTag = (UInt32(group) << 16) | UInt32(element)
            for child in children where child.tag == targetTag {
                guard let d = reader?.data else { return nil }
                let bytes = d.subdata(in: child.valueStart..<min(child.valueEnd, d.count))
                return String(data: bytes, encoding: .ascii)?
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
            return nil
        }

        func subItems(group: UInt16, element: UInt16) -> [ParsedItem] {
            let targetTag = (UInt32(group) << 16) | UInt32(element)
            for child in children where child.tag == targetTag {
                return child.children
            }
            return []
        }
    }

    var rootItems: [ParsedItem] = []

    init(data: Data) {
        self.data = data
    }

    func parse() {
        var offset = 132
        let (_, items) = parseDataset(offset: &offset, maxOffset: data.count)
        rootItems = items
    }

    // Returns top-level items belonging to a specific SQ tag
    func items(group: UInt16, element: UInt16) -> [ParsedItem] {
        let target = (UInt32(group) << 16) | UInt32(element)
        for it in rootItems where it.tag == target {
            return it.children
        }
        return []
    }

    private func parseDataset(offset: inout Int, maxOffset: Int) -> (Int, [ParsedItem]) {
        var items: [ParsedItem] = []
        while offset < maxOffset - 8 {
            let group = data.readUInt16LE_private(at: offset)
            let element = data.readUInt16LE_private(at: offset + 2)
            let tag = (UInt32(group) << 16) | UInt32(element)
            offset += 4

            // Sequence delimitation item (FFFE, E0DD)
            if group == 0xFFFE && element == 0xE0DD {
                offset += 4  // zero length
                return (offset, items)
            }
            // Item delimitation (FFFE, E00D)
            if group == 0xFFFE && element == 0xE00D {
                offset += 4
                return (offset, items)
            }
            // Item start (FFFE, E000) — sequence item with explicit length
            if group == 0xFFFE && element == 0xE000 {
                let itemLen = Int(data.readUInt32LE_private(at: offset))
                offset += 4
                if itemLen == -1 || itemLen == Int(bitPattern: UInt(0xFFFFFFFF)) {
                    // Undefined length — parse until delimiter
                    let (next, children) = parseDataset(offset: &offset, maxOffset: maxOffset)
                    items.append(ParsedItem(tag: tag, valueStart: offset, valueEnd: next,
                                            vr: "NA", children: children, reader: self))
                } else {
                    let childMax = offset + itemLen
                    var localOffset = offset
                    let (_, children) = parseDataset(offset: &localOffset, maxOffset: childMax)
                    items.append(ParsedItem(tag: tag, valueStart: offset, valueEnd: childMax,
                                            vr: "NA", children: children, reader: self))
                    offset = childMax
                }
                continue
            }

            // Regular data element: Explicit VR Little Endian assumed for group >= 0x0008
            let vr = String(data: data[offset..<offset+2], encoding: .ascii) ?? ""
            offset += 2

            let longVRs: Set<String> = ["OB", "OW", "OF", "SQ", "UT", "UN", "OD", "OL"]
            var length: Int
            if longVRs.contains(vr) {
                offset += 2  // reserved
                length = Int(data.readUInt32LE_private(at: offset))
                offset += 4
            } else {
                length = Int(data.readUInt16LE_private(at: offset))
                offset += 2
            }

            if length == 0xFFFFFFFF { length = -1 }

            if vr == "SQ" || length == -1 {
                // Parse sequence items
                var localOffset = offset
                let end = length == -1 ? maxOffset : offset + length
                let (next, children) = parseDataset(offset: &localOffset, maxOffset: end)
                items.append(ParsedItem(tag: tag, valueStart: offset, valueEnd: next,
                                        vr: vr, children: children, reader: self))
                offset = next
            } else {
                let valueStart = offset
                let valueEnd = offset + length
                items.append(ParsedItem(tag: tag, valueStart: valueStart, valueEnd: valueEnd,
                                        vr: vr, reader: self))
                offset = valueEnd
            }
        }
        return (offset, items)
    }
}

private extension Data {
    func readUInt16LE_private(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return self.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
    }
    func readUInt32LE_private(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return self.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
    }
}
