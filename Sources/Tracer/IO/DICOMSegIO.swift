import Foundation
import SwiftUI

public enum DICOMSegIO {
    private static let segmentationStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.66.4"

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

    private struct Frame {
        let labelID: UInt16
        let z: Int
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
