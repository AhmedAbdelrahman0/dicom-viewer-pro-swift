import Foundation

public enum MRSequenceRole: String, CaseIterable, Identifiable, Codable, Sendable {
    case t1
    case t2
    case flair
    case dwi
    case adc
    case postContrast
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .t1: return "T1"
        case .t2: return "T2"
        case .flair: return "FLAIR"
        case .dwi: return "DWI"
        case .adc: return "ADC"
        case .postContrast: return "Post-contrast"
        case .other: return "Other MR"
        }
    }

    public var shortName: String {
        switch self {
        case .postContrast: return "POST"
        case .other: return "MR"
        default: return displayName.uppercased()
        }
    }

    public static func role(for volume: ImageVolume) -> MRSequenceRole {
        let candidates = allCases.filter { $0 != .other }
        return candidates.max { lhs, rhs in
            lhs.score(seriesDescription: volume.seriesDescription,
                      modality: volume.modality) <
                rhs.score(seriesDescription: volume.seriesDescription,
                          modality: volume.modality)
        }.flatMap { role in
            role.score(seriesDescription: volume.seriesDescription,
                       modality: volume.modality) > 0 ? role : nil
        } ?? .other
    }

    public func score(volume: ImageVolume) -> Int {
        score(seriesDescription: volume.seriesDescription, modality: volume.modality)
    }

    public func score(seriesDescription: String, modality: String) -> Int {
        guard Modality.normalize(modality) == .MR else { return Int.min }
        let text = Self.normalized(seriesDescription)
        let tokens = Set(text.components(separatedBy: " ").filter { !$0.isEmpty })

        func has(_ words: [String]) -> Bool {
            words.contains { word in
                tokens.contains(word) || text.contains(word)
            }
        }

        func exact(_ words: [String]) -> Bool {
            words.contains { tokens.contains($0) }
        }

        switch self {
        case .adc:
            return has(["adc", "apparent diffusion"]) ? 180 : 0

        case .dwi:
            var score = 0
            if has(["dwi", "diffusion", "trace", "b1000", "b900", "b800"]) { score += 150 }
            if has(["adc"]) { score -= 120 }
            return max(0, score)

        case .flair:
            return has(["flair", "tirm"]) ? 170 : 0

        case .postContrast:
            var score = 0
            if has(["post", "postcontrast", "post contrast", "gd", "gadolinium", "contrast", "ce", "c+"]) { score += 150 }
            if has(["t1", "mprage", "spgr", "bravo", "tfe", "vibe"]) { score += 25 }
            if has(["subtract", "subtraction"]) { score += 20 }
            return score

        case .t2:
            var score = 0
            if exact(["t2"]) || has(["t2w", "t2 weighted", "tse", "fse", "stir"]) { score += 130 }
            if has(["flair", "adc", "dwi"]) { score -= 100 }
            return max(0, score)

        case .t1:
            var score = 0
            if exact(["t1"]) || has(["t1w", "t1 weighted", "mprage", "spgr", "bravo", "tfe", "vibe"]) { score += 130 }
            if has(["post", "contrast", "gd", "ce", "c+"]) { score -= 50 }
            if has(["t2", "flair", "adc", "dwi"]) { score -= 100 }
            return max(0, score)

        case .other:
            return 1
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "+", with: " + ")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
