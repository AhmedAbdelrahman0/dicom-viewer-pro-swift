import Foundation
import SwiftUI

public enum DICOMSegIO {
    private static let segmentationStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.66.4"

    public static func loadDICOMSEG(from url: URL,
                                    referenceVolume: ImageVolume) throws -> LabelMap {
        let header = try DICOMLoader.parseHeader(at: url)
        guard header.modality.uppercased() == "SEG" else {
            throw DICOMError.invalidFile("Expected DICOM SEG, got modality \(header.modality.isEmpty ? "unknown" : header.modality)")
        }
        guard header.rows == referenceVolume.height,
              header.columns == referenceVolume.width else {
            throw LabelIO.LabelIOError.geometryMismatch(
                "SEG frames \(header.columns)x\(header.rows), current volume \(referenceVolume.width)x\(referenceVolume.height)"
            )
        }
        guard !header.pixelDataUndefinedLength,
              header.pixelDataOffset > 0,
              header.pixelDataLength > 0 else {
            throw DICOMError.invalidFile("DICOM SEG pixel data is missing or encapsulated")
        }

        let data = try Data(contentsOf: url)
        let reader = DICOMSequenceReader(data: data)
        reader.parse()

        let segmentationType = reader
            .stringValue(group: 0x0062, element: 0x0001)?
            .uppercased() ?? (header.bitsAllocated == 1 ? "BINARY" : "LABELMAP")
        switch segmentationType {
        case "BINARY":
            guard header.bitsAllocated == 1 else {
                throw DICOMError.invalidFile("Binary DICOM SEG must use BitsAllocated=1; got \(header.bitsAllocated)")
            }
        case "LABELMAP":
            guard header.bitsAllocated == 8 || header.bitsAllocated == 16 else {
                throw DICOMError.invalidFile("Labelmap DICOM SEG supports 8- or 16-bit pixels; got \(header.bitsAllocated)")
            }
        case "FRACTIONAL":
            throw DICOMError.invalidFile("Fractional/probability DICOM SEG import is not supported as a discrete label mask")
        default:
            throw DICOMError.invalidFile("Unsupported DICOM SEG type \(segmentationType)")
        }

        let segments = segmentDescriptions(from: reader)
        guard !segments.isEmpty else {
            throw DICOMError.invalidFile("DICOM SEG has no Segment Sequence")
        }

        let bitsPerFrame = header.rows * header.columns * max(1, header.bitsAllocated)
        let numberOfFrames = reader.intValue(group: 0x0028, element: 0x0008)
            ?? (header.pixelDataLength * 8) / max(1, bitsPerFrame)
        let frames = frameDescriptions(from: reader,
                                       numberOfFrames: numberOfFrames,
                                       referenceVolume: referenceVolume)

        guard data.count >= header.pixelDataOffset + header.pixelDataLength else {
            throw DICOMError.invalidFile("DICOM SEG pixel data is out of bounds")
        }
        let pixelData = data.subdata(in: header.pixelDataOffset..<(header.pixelDataOffset + header.pixelDataLength))

        let labelMap = LabelMap(
            parentSeriesUID: referenceVolume.seriesUID,
            depth: referenceVolume.depth,
            height: referenceVolume.height,
            width: referenceVolume.width,
            name: header.seriesDescription.isEmpty ? "DICOM SEG" : header.seriesDescription,
            classes: segments.map(\.labelClass)
        )

        let pixelsPerFrame = header.rows * header.columns
        switch segmentationType {
        case "BINARY":
            for (frameIndex, frame) in frames.enumerated() where frameIndex < numberOfFrames {
                guard frame.z >= 0, frame.z < labelMap.depth else { continue }
                for pixelIndex in 0..<pixelsPerFrame where bitIsSet(pixelData, bitIndex: frameIndex * pixelsPerFrame + pixelIndex) {
                    let y = pixelIndex / header.columns
                    let x = pixelIndex % header.columns
                    let dst = labelMap.index(z: frame.z, y: y, x: x)
                    labelMap.voxels[dst] = frame.segmentNumber
                }
            }
        case "LABELMAP":
            let bytesPerVoxel = max(1, header.bitsAllocated / 8)
            for (frameIndex, frame) in frames.enumerated() where frameIndex < numberOfFrames {
                guard frame.z >= 0, frame.z < labelMap.depth else { continue }
                for pixelIndex in 0..<pixelsPerFrame {
                    let src = (frameIndex * pixelsPerFrame + pixelIndex) * bytesPerVoxel
                    guard src + bytesPerVoxel <= pixelData.count else { continue }
                    let value = labelmapValue(pixelData, offset: src, bytesPerVoxel: bytesPerVoxel)
                    guard value != 0 else { continue }
                    let y = pixelIndex / header.columns
                    let x = pixelIndex % header.columns
                    let dst = labelMap.index(z: frame.z, y: y, x: x)
                    labelMap.voxels[dst] = value
                }
            }
        default:
            break
        }

        return labelMap
    }

    public static func saveDICOMSEG(_ labelMap: LabelMap,
                                    parentVolume: ImageVolume,
                                    to url: URL) throws {
        let classes = exportClasses(for: labelMap)
        guard !classes.isEmpty else {
            throw LabelIO.LabelIOError.invalidLabelPackage("DICOM SEG export needs at least one label class")
        }

        let now = DICOMExportWriter.currentDateTime()
        let studyUID = DICOMExportWriter.dicomUID(parentVolume.studyUID)
        let seriesUID = DICOMExportWriter.makeUID()
        let sopUID = DICOMExportWriter.makeUID()
        let frameOfReferenceUID = DICOMExportWriter.makeUID()
        let dimensionOrganizationUID = DICOMExportWriter.makeUID()
        let frames = makeFrames(classes: classes, depth: labelMap.depth)
        let segmentNumberByLabel = Dictionary(uniqueKeysWithValues: classes.enumerated().map { index, labelClass in
            (labelClass.labelID, UInt16(index + 1))
        })

        var dataset = Data()
        dataset.appendDICOMElement(group: 0x0008, element: 0x0008, vr: "CS", strings: ["DERIVED", "PRIMARY"])
        dataset.appendDICOMElement(group: 0x0008, element: 0x0016, vr: "UI", string: segmentationStorageSOPClassUID)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0018, vr: "UI", string: sopUID)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0020, vr: "DA", string: now.date)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0023, vr: "DA", string: now.date)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0030, vr: "TM", string: now.time)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0033, vr: "TM", string: now.time)
        dataset.appendDICOMElement(group: 0x0008, element: 0x0060, vr: "CS", string: "SEG")
        dataset.appendDICOMElement(group: 0x0008, element: 0x0070, vr: "LO", string: "Tracer")
        dataset.appendDICOMElement(group: 0x0008, element: 0x1030, vr: "LO", string: parentVolume.studyDescription)
        dataset.appendDICOMElement(group: 0x0008, element: 0x103E, vr: "LO", string: "\(labelMap.name) DICOM SEG")
        dataset.appendDICOMElement(group: 0x0010, element: 0x0010, vr: "PN", string: patientName(parentVolume))
        dataset.appendDICOMElement(group: 0x0010, element: 0x0020, vr: "LO", string: patientID(parentVolume))
        dataset.appendDICOMElement(group: 0x0020, element: 0x000D, vr: "UI", string: studyUID)
        dataset.appendDICOMElement(group: 0x0020, element: 0x000E, vr: "UI", string: seriesUID)
        dataset.appendDICOMElement(group: 0x0020, element: 0x0011, vr: "IS", string: "900")
        dataset.appendDICOMElement(group: 0x0020, element: 0x0013, vr: "IS", string: "1")
        dataset.appendDICOMElement(group: 0x0020, element: 0x0052, vr: "UI", string: frameOfReferenceUID)
        dataset.appendDICOMElement(group: 0x0028, element: 0x0002, vr: "US", uint16: 1)
        dataset.appendDICOMElement(group: 0x0028, element: 0x0004, vr: "CS", string: "MONOCHROME2")
        dataset.appendDICOMElement(group: 0x0028, element: 0x0008, vr: "IS", string: "\(frames.count)")
        dataset.appendDICOMElement(group: 0x0028, element: 0x0010, vr: "US", uint16: UInt16(labelMap.height))
        dataset.appendDICOMElement(group: 0x0028, element: 0x0011, vr: "US", uint16: UInt16(labelMap.width))
        dataset.appendDICOMElement(group: 0x0028, element: 0x0100, vr: "US", uint16: 1)
        dataset.appendDICOMElement(group: 0x0028, element: 0x0101, vr: "US", uint16: 1)
        dataset.appendDICOMElement(group: 0x0028, element: 0x0102, vr: "US", uint16: 0)
        dataset.appendDICOMElement(group: 0x0028, element: 0x0103, vr: "US", uint16: 0)
        dataset.appendDICOMSequence(group: 0x0020, element: 0x9221, items: [
            dimensionOrganizationItem(uid: dimensionOrganizationUID)
        ])
        dataset.appendDICOMSequence(group: 0x0020, element: 0x9222, items: dimensionIndexItems(dimensionOrganizationUID: dimensionOrganizationUID))
        dataset.appendDICOMElement(group: 0x0062, element: 0x0001, vr: "CS", string: "BINARY")
        dataset.appendDICOMSequence(group: 0x0062, element: 0x0002, items: segmentItems(classes))
        dataset.appendDICOMElement(group: 0x0070, element: 0x0080, vr: "CS", string: "LABEL")
        dataset.appendDICOMElement(group: 0x0070, element: 0x0081, vr: "LO", string: labelMap.name)
        dataset.appendDICOMElement(group: 0x0070, element: 0x0084, vr: "PN", string: "Tracer")
        dataset.appendDICOMSequence(group: 0x5200, element: 0x9229, items: [
            sharedFunctionalGroup(parentVolume)
        ])
        dataset.appendDICOMSequence(group: 0x5200, element: 0x9230, items: perFrameFunctionalGroups(
            frames,
            volume: parentVolume,
            segmentNumberByLabel: segmentNumberByLabel
        ))
        dataset.appendDICOMElement(group: 0x7FE0, element: 0x0010, vr: "OB", bytes: packedPixelData(
            labelMap: labelMap,
            frames: frames
        ))

        let file = DICOMExportWriter.part10File(
            sopClassUID: segmentationStorageSOPClassUID,
            sopInstanceUID: sopUID,
            dataset: dataset
        )
        try file.write(to: url, options: [.atomic])
    }

    private struct SegmentDescription {
        let number: UInt16
        let labelClass: LabelClass
    }

    private struct Frame {
        let labelID: UInt16
        let z: Int
    }

    private struct ImportFrame {
        let segmentNumber: UInt16
        let z: Int
    }

    private static func segmentDescriptions(from reader: DICOMSequenceReader) -> [SegmentDescription] {
        let items = reader.items(group: 0x0062, element: 0x0002)
        let colors: [Color] = [.red, .green, .blue, .yellow, .orange, .purple, .pink,
                               .cyan, .mint, .indigo, .teal, .brown]
        return items.enumerated().compactMap { index, item in
            let number = UInt16(item.intValue(group: 0x0062, element: 0x0004) ?? index + 1)
            guard number != 0 else { return nil }
            let typeMeaning = item
                .subItems(group: 0x0062, element: 0x000F)
                .first?
                .stringValue(group: 0x0008, element: 0x0104)
            let label = item.stringValue(group: 0x0062, element: 0x0005)
                ?? typeMeaning
                ?? "Segment \(number)"
            return SegmentDescription(
                number: number,
                labelClass: LabelClass(
                    labelID: number,
                    name: label,
                    category: categoryForSegment(label),
                    color: colors[index % colors.count]
                )
            )
        }
    }

    private static func frameDescriptions(from reader: DICOMSequenceReader,
                                          numberOfFrames: Int,
                                          referenceVolume: ImageVolume) -> [ImportFrame] {
        let perFrameItems = reader.items(group: 0x5200, element: 0x9230)
        guard !perFrameItems.isEmpty else {
            let segmentNumbers = segmentDescriptions(from: reader).map(\.number)
            if segmentNumbers.isEmpty {
                return (0..<numberOfFrames).map {
                    ImportFrame(segmentNumber: 1, z: min(referenceVolume.depth - 1, $0))
                }
            }
            return segmentNumbers.flatMap { segmentNumber in
                (0..<referenceVolume.depth).map {
                    ImportFrame(segmentNumber: segmentNumber, z: $0)
                }
            }
        }

        return perFrameItems.enumerated().map { frameIndex, item in
            let segmentNumber = item
                .subItems(group: 0x0062, element: 0x000A)
                .first?
                .intValue(group: 0x0062, element: 0x000B)
            let frameContent = item.subItems(group: 0x0020, element: 0x9111).first
            let dimensionValues = frameContent?.uint32Values(group: 0x0020, element: 0x9157) ?? []
            let inStackPosition = frameContent?.intValue(group: 0x0020, element: 0x9057)
            let planePosition = item
                .subItems(group: 0x0020, element: 0x9113)
                .first?
                .doubleArray(group: 0x0020, element: 0x0032)

            let zFromPosition: Int? = {
                guard let planePosition, planePosition.count >= 3 else { return nil }
                let voxel = referenceVolume.voxelCoordinates(from: SIMD3<Double>(
                    planePosition[0],
                    planePosition[1],
                    planePosition[2]
                ))
                return Int(round(voxel.z))
            }()

            let segment = UInt16(segmentNumber ?? Int(dimensionValues.first ?? 1))
            let z = zFromPosition
                ?? (inStackPosition.map { $0 - 1 })
                ?? (dimensionValues.count >= 2 ? Int(dimensionValues[1]) - 1 : frameIndex)
            return ImportFrame(segmentNumber: max(1, segment), z: z)
        }
    }

    private static func bitIsSet(_ data: Data, bitIndex: Int) -> Bool {
        guard bitIndex >= 0 else { return false }
        let byteIndex = bitIndex / 8
        guard byteIndex < data.count else { return false }
        return (data[byteIndex] & UInt8(1 << (bitIndex % 8))) != 0
    }

    private static func labelmapValue(_ data: Data,
                                      offset: Int,
                                      bytesPerVoxel: Int) -> UInt16 {
        if bytesPerVoxel == 1 {
            return UInt16(data[offset])
        }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func categoryForSegment(_ name: String) -> LabelCategory {
        let n = name.lowercased()
        if n.contains("gtv") || n.contains("ctv") || n.contains("ptv") || n.contains("itv") {
            return .rtTarget
        }
        if n.contains("oar") || n.contains("organ") || n.contains("liver") || n.contains("kidney")
            || n.contains("heart") || n.contains("lung") {
            return .rtOAR
        }
        if n.contains("tumor") || n.contains("mass") {
            return .tumor
        }
        if n.contains("lesion") || n.contains("met") || n.contains("node") {
            return .lesion
        }
        if n.contains("suv") || n.contains("fdg") || n.contains("uptake") {
            return .petHotspot
        }
        return .custom
    }

    private static func makeFrames(classes: [LabelClass], depth: Int) -> [Frame] {
        classes.flatMap { labelClass in
            (0..<max(1, depth)).map { Frame(labelID: labelClass.labelID, z: $0) }
        }
    }

    private static func segmentItems(_ classes: [LabelClass]) -> [Data] {
        classes.enumerated().map { index, labelClass in
            var item = Data()
            item.appendDICOMSequence(group: 0x0062, element: 0x0003, items: [
                DICOMExportWriter.codeSequenceItem(codeValue: "T-D0050", scheme: "SRT", meaning: "Tissue")
            ])
            item.appendDICOMElement(group: 0x0062, element: 0x0004, vr: "US", uint16: UInt16(index + 1))
            item.appendDICOMElement(group: 0x0062, element: 0x0005, vr: "LO", string: labelClass.name)
            item.appendDICOMElement(group: 0x0062, element: 0x0008, vr: "CS", string: "MANUAL")
            item.appendDICOMElement(group: 0x0062, element: 0x0009, vr: "LO", string: "Tracer")
            item.appendDICOMSequence(group: 0x0062, element: 0x000F, items: [
                DICOMExportWriter.codeSequenceItem(
                    codeValue: labelClass.dicomCode?.isEmpty == false ? labelClass.dicomCode! : "M-01000",
                    scheme: "SRT",
                    meaning: labelClass.name.isEmpty ? "Lesion" : labelClass.name
                )
            ])
            return item
        }
    }

    private static func sharedFunctionalGroup(_ volume: ImageVolume) -> Data {
        var pixelMeasures = Data()
        pixelMeasures.appendDICOMElement(group: 0x0018, element: 0x0050, vr: "DS", string: DICOMExportWriter.formatDS(volume.spacing.z))
        pixelMeasures.appendDICOMElement(group: 0x0018, element: 0x0088, vr: "DS", string: DICOMExportWriter.formatDS(volume.spacing.z))
        pixelMeasures.appendDICOMElement(group: 0x0028, element: 0x0030, vr: "DS", string: DICOMExportWriter.ds([volume.spacing.y, volume.spacing.x]))

        var planeOrientation = Data()
        planeOrientation.appendDICOMElement(group: 0x0020, element: 0x0037, vr: "DS", string: DICOMExportWriter.orientationDS(for: volume))

        var item = Data()
        item.appendDICOMSequence(group: 0x0028, element: 0x9110, items: [pixelMeasures])
        item.appendDICOMSequence(group: 0x0020, element: 0x9116, items: [planeOrientation])
        return item
    }

    private static func perFrameFunctionalGroups(_ frames: [Frame],
                                                 volume: ImageVolume,
                                                 segmentNumberByLabel: [UInt16: UInt16]) -> [Data] {
        frames.enumerated().map { frameIndex, frame in
            let segmentNumber = segmentNumberByLabel[frame.labelID] ?? 1
            var frameContent = Data()
            frameContent.appendDICOMElement(group: 0x0020, element: 0x9056, vr: "SH", string: "1")
            frameContent.appendDICOMElement(group: 0x0020, element: 0x9057, vr: "UL", uint32: UInt32(frame.z + 1))
            frameContent.appendDICOMElement(group: 0x0020, element: 0x9157, vr: "UL", uint32s: [
                UInt32(segmentNumber),
                UInt32(frame.z + 1)
            ])

            var planePosition = Data()
            planePosition.appendDICOMElement(group: 0x0020, element: 0x0032, vr: "DS", string: DICOMExportWriter.imagePositionDS(for: volume, z: frame.z))

            var segmentID = Data()
            segmentID.appendDICOMElement(group: 0x0062, element: 0x000B, vr: "US", uint16: segmentNumber)

            var item = Data()
            item.appendDICOMSequence(group: 0x0020, element: 0x9111, items: [frameContent])
            item.appendDICOMSequence(group: 0x0020, element: 0x9113, items: [planePosition])
            item.appendDICOMSequence(group: 0x0062, element: 0x000A, items: [segmentID])
            _ = frameIndex
            return item
        }
    }

    private static func dimensionOrganizationItem(uid: String) -> Data {
        var item = Data()
        item.appendDICOMElement(group: 0x0020, element: 0x9164, vr: "UI", string: uid)
        return item
    }

    private static func dimensionIndexItems(dimensionOrganizationUID: String) -> [Data] {
        [
            dimensionIndexItem(uid: dimensionOrganizationUID,
                               pointerGroup: 0x0062,
                               pointerElement: 0x000B,
                               groupPointer: 0x0062,
                               elementPointer: 0x000A,
                               label: "ReferencedSegmentNumber"),
            dimensionIndexItem(uid: dimensionOrganizationUID,
                               pointerGroup: 0x0020,
                               pointerElement: 0x9057,
                               groupPointer: 0x0020,
                               elementPointer: 0x9111,
                               label: "InStackPositionNumber")
        ]
    }

    private static func dimensionIndexItem(uid: String,
                                           pointerGroup: UInt16,
                                           pointerElement: UInt16,
                                           groupPointer: UInt16,
                                           elementPointer: UInt16,
                                           label: String) -> Data {
        var item = Data()
        var dimensionIndexPointer = Data()
        dimensionIndexPointer.appendDICOMUInt16LE(pointerGroup)
        dimensionIndexPointer.appendDICOMUInt16LE(pointerElement)
        var functionalGroupPointer = Data()
        functionalGroupPointer.appendDICOMUInt16LE(groupPointer)
        functionalGroupPointer.appendDICOMUInt16LE(elementPointer)
        item.appendDICOMElement(group: 0x0020, element: 0x9164, vr: "UI", string: uid)
        item.appendDICOMElement(group: 0x0020, element: 0x9165, vr: "AT", bytes: dimensionIndexPointer)
        item.appendDICOMElement(group: 0x0020, element: 0x9167, vr: "AT", bytes: functionalGroupPointer)
        item.appendDICOMElement(group: 0x0020, element: 0x9421, vr: "LO", string: label)
        return item
    }

    private static func packedPixelData(labelMap: LabelMap, frames: [Frame]) -> Data {
        let bitsPerFrame = labelMap.width * labelMap.height
        let bitCount = bitsPerFrame * frames.count
        var packed = Data(repeating: 0, count: (bitCount + 7) / 8)
        var bitIndex = 0
        for frame in frames {
            for y in 0..<labelMap.height {
                for x in 0..<labelMap.width {
                    let voxelIndex = labelMap.index(z: frame.z, y: y, x: x)
                    if labelMap.voxels[voxelIndex] == frame.labelID {
                        packed[bitIndex / 8] |= UInt8(1 << (bitIndex % 8))
                    }
                    bitIndex += 1
                }
            }
        }
        return packed
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
