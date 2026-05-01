import Foundation
import SwiftUI

enum DICOMExportWriter {
    static let explicitVRLittleEndian = "1.2.840.10008.1.2.1"
    static let implementationClassUID = "2.25.316719632603597235625970308584440289001"

    static func part10File(sopClassUID: String,
                           sopInstanceUID: String,
                           dataset: Data) -> Data {
        var meta = Data()
        meta.appendDICOMElement(group: 0x0002, element: 0x0001, vr: "OB", bytes: Data([0x00, 0x01]))
        meta.appendDICOMElement(group: 0x0002, element: 0x0002, vr: "UI", string: sopClassUID)
        meta.appendDICOMElement(group: 0x0002, element: 0x0003, vr: "UI", string: sopInstanceUID)
        meta.appendDICOMElement(group: 0x0002, element: 0x0010, vr: "UI", string: explicitVRLittleEndian)
        meta.appendDICOMElement(group: 0x0002, element: 0x0012, vr: "UI", string: implementationClassUID)
        meta.appendDICOMElement(group: 0x0002, element: 0x0013, vr: "SH", string: "Tracer")

        var file = Data(count: 128)
        file.append("DICM".data(using: .ascii)!)
        file.appendDICOMElement(group: 0x0002, element: 0x0000, vr: "UL", uint32: UInt32(meta.count))
        file.append(meta)
        file.append(dataset)
        return file
    }

    static func makeUID() -> String {
        var uuid = UUID().uuid
        let bytes = withUnsafeBytes(of: &uuid) { Array($0) }
        var digits = [0]
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices {
                let value = digits[index] * 256 + carry
                digits[index] = value % 10
                carry = value / 10
            }
            while carry > 0 {
                digits.append(carry % 10)
                carry /= 10
            }
        }
        return "2.25.\(digits.reversed().map(String.init).joined())"
    }

    static func dicomUID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let validCharacters = CharacterSet(charactersIn: "0123456789.")
        let hasOnlyUIDCharacters = trimmed.unicodeScalars.allSatisfy { validCharacters.contains($0) }
        let hasRepeatedDots = trimmed.contains("..")
        if !trimmed.isEmpty,
           trimmed.count <= 64,
           hasOnlyUIDCharacters,
           !trimmed.hasPrefix("."),
           !trimmed.hasSuffix("."),
           !hasRepeatedDots {
            return trimmed
        }
        return makeUID()
    }

    static func currentDateTime() -> (date: String, time: String) {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyyMMdd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HHmmss"
        return (dateFormatter.string(from: now), timeFormatter.string(from: now))
    }

    static func orientationDS(for volume: ImageVolume) -> String {
        ds([
            volume.direction[0].x, volume.direction[0].y, volume.direction[0].z,
            volume.direction[1].x, volume.direction[1].y, volume.direction[1].z
        ])
    }

    static func imagePositionDS(for volume: ImageVolume, z: Int) -> String {
        let point = volume.worldPoint(voxel: SIMD3<Double>(0, 0, Double(z)))
        return ds([point.x, point.y, point.z])
    }

    static func ds(_ values: [Double]) -> String {
        values.map(formatDS).joined(separator: "\\")
    }

    static func formatDS(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.contains(".") && text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        if text == "-0" { text = "0" }
        if text.count > 16 {
            text = String(format: "%.8g", value)
        }
        return text
    }

    static func rgbComponents(_ color: Color) -> (UInt8, UInt8, UInt8) {
        color.rgbBytes()
    }

    static func codeSequenceItem(codeValue: String,
                                 scheme: String,
                                 meaning: String) -> Data {
        var item = Data()
        item.appendDICOMElement(group: 0x0008, element: 0x0100, vr: "SH", string: codeValue)
        item.appendDICOMElement(group: 0x0008, element: 0x0102, vr: "SH", string: scheme)
        item.appendDICOMElement(group: 0x0008, element: 0x0104, vr: "LO", string: meaning)
        return item
    }
}

extension Data {
    mutating func appendDICOMElement(group: UInt16,
                                     element: UInt16,
                                     vr: String,
                                     string: String) {
        appendDICOMElement(group: group, element: element, vr: vr, bytes: paddedDICOMText(string, vr: vr))
    }

    mutating func appendDICOMElement(group: UInt16,
                                     element: UInt16,
                                     vr: String,
                                     strings: [String]) {
        appendDICOMElement(group: group, element: element, vr: vr, string: strings.joined(separator: "\\"))
    }

    mutating func appendDICOMElement(group: UInt16,
                                     element: UInt16,
                                     vr: String,
                                     uint16: UInt16) {
        var value = Data()
        value.appendDICOMUInt16LE(uint16)
        appendDICOMElement(group: group, element: element, vr: vr, bytes: value)
    }

    mutating func appendDICOMElement(group: UInt16,
                                     element: UInt16,
                                     vr: String,
                                     uint16s: [UInt16]) {
        var value = Data()
        for item in uint16s {
            value.appendDICOMUInt16LE(item)
        }
        appendDICOMElement(group: group, element: element, vr: vr, bytes: value)
    }

    mutating func appendDICOMElement(group: UInt16,
                                     element: UInt16,
                                     vr: String,
                                     uint32: UInt32) {
        var value = Data()
        value.appendDICOMUInt32LE(uint32)
        appendDICOMElement(group: group, element: element, vr: vr, bytes: value)
    }

    mutating func appendDICOMElement(group: UInt16,
                                     element: UInt16,
                                     vr: String,
                                     uint32s: [UInt32]) {
        var value = Data()
        for item in uint32s {
            value.appendDICOMUInt32LE(item)
        }
        appendDICOMElement(group: group, element: element, vr: vr, bytes: value)
    }

    mutating func appendDICOMElement(group: UInt16,
                                     element: UInt16,
                                     vr: String,
                                     bytes: Data) {
        var value = bytes
        if value.count % 2 != 0 {
            value.append(0)
        }

        appendDICOMUInt16LE(group)
        appendDICOMUInt16LE(element)
        append(vr.data(using: .ascii)!)
        if longDICOMVRs.contains(vr) {
            appendDICOMUInt16LE(0)
            appendDICOMUInt32LE(UInt32(value.count))
        } else {
            appendDICOMUInt16LE(UInt16(value.count))
        }
        append(value)
    }

    mutating func appendDICOMSequence(group: UInt16,
                                      element: UInt16,
                                      items: [Data]) {
        var value = Data()
        for item in items {
            value.appendDICOMUInt16LE(0xFFFE)
            value.appendDICOMUInt16LE(0xE000)
            value.appendDICOMUInt32LE(UInt32(item.count))
            value.append(item)
        }
        appendDICOMElement(group: group, element: element, vr: "SQ", bytes: value)
    }

    mutating func appendDICOMUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendDICOMUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

private let longDICOMVRs: Set<String> = ["OB", "OD", "OF", "OL", "OW", "SQ", "UC", "UN", "UR", "UT"]

private func paddedDICOMText(_ text: String, vr: String) -> Data {
    var value = text.data(using: .ascii, allowLossyConversion: true) ?? Data()
    if value.count % 2 != 0 {
        value.append(vr == "UI" ? 0 : 0x20)
    }
    return value
}
