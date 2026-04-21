import Foundation

public enum AssistantAction: Equatable {
    case applyWindowPreset(String)
    case autoWindowLevel
    case setViewerTool(ViewerTool)
    case setLabelingTool(LabelingTool)
    case createLabelMap(String?)
    case applyLabelPreset(String)
    case selectLabel(String)
    case centerSlices
    case setSlice(axis: Int, index: Int)
    case setOverlayOpacity(Double)
    case setInvert(Bool?)
    case removeOverlay
    case threshold(Double)
    case setPercentOfMax(Double)
    case setSUVMode(SUVCalculationMode)
    case setSUVActivityUnit(PETActivityUnit)
    case setSUVManualScale(Double)
    case setSUVPatientWeight(Double)
    case setSUVPatientHeight(Double)
    case setSUVInjectedDose(Double)
    case setSUVResidualDose(Double)
}

public struct AssistantCommandInterpreter {
    public init() {}

    public func actions(for prompt: String) -> [AssistantAction] {
        let text = prompt.normalizedAssistantText
        var actions: [AssistantAction] = []

        if text.containsAny(["auto window", "auto wl", "auto level", "automatic window"]) {
            actions.append(.autoWindowLevel)
        }

        if let preset = windowPresetName(in: text) {
            actions.append(.applyWindowPreset(preset))
        }

        if text.contains("remove overlay") || text.contains("clear overlay") || text.contains("turn off fusion") {
            actions.append(.removeOverlay)
        }

        if text.contains("invert") {
            if text.containsAny(["off", "normal", "disable"]) {
                actions.append(.setInvert(false))
            } else if text.containsAny(["on", "enable"]) {
                actions.append(.setInvert(true))
            } else {
                actions.append(.setInvert(nil))
            }
        }

        if let opacity = overlayOpacity(in: text) {
            actions.append(.setOverlayOpacity(opacity))
        }

        actions.append(contentsOf: toolActions(in: text))
        actions.append(contentsOf: sliceActions(in: text))
        actions.append(contentsOf: suvActions(in: text))
        actions.append(contentsOf: segmentationActions(in: text))

        return actions.removingAdjacentDuplicates()
    }

    private func windowPresetName(in text: String) -> String? {
        let pairs: [(String, [String])] = [
            ("Lung", ["lung", "lungs", "pulmonary"]),
            ("Bone", ["bone", "bones", "osseous"]),
            ("Brain", ["brain", "head"]),
            ("Liver", ["liver", "hepatic"]),
            ("Abdomen", ["abdomen", "abdominal"]),
            ("Mediastinum", ["mediastinum", "mediastinal"]),
            ("Soft Tissue", ["soft tissue", "soft-tissue", "soft"]),
            ("Angio", ["angio", "angiography", "vessel", "vascular", "artery", "cta"]),
            ("Standard", ["pet", "suv", "fdg"])
        ]
        return pairs.first { _, aliases in text.containsAny(aliases) }?.0
    }

    private func toolActions(in text: String) -> [AssistantAction] {
        var actions: [AssistantAction] = []
        if text.containsAny(["distance", "ruler", "measure length"]) {
            actions.append(.setViewerTool(.distance))
        } else if text.containsAny(["angle", "cobb"]) {
            actions.append(.setViewerTool(.angle))
        } else if text.containsAny(["area", "roi", "region of interest"]) {
            actions.append(.setViewerTool(.area))
        } else if text.contains("pan") {
            actions.append(.setViewerTool(.pan))
        } else if text.contains("zoom") {
            actions.append(.setViewerTool(.zoom))
        } else if text.containsAny(["window level", "windowing", "wl tool"]) {
            actions.append(.setViewerTool(.wl))
        }

        if text.containsAny(["brush", "paint"]) {
            actions.append(.setLabelingTool(.brush))
        }
        if text.contains("eraser") || text.contains("erase") {
            actions.append(.setLabelingTool(.eraser))
        }
        if text.contains("threshold") {
            actions.append(.setLabelingTool(.threshold))
        }
        if text.containsAny(["region grow", "region-growing", "grow region", "flood fill"]) {
            actions.append(.setLabelingTool(.regionGrow))
        }
        if text.containsAny(["landmark", "registration point", "fiducial"]) {
            actions.append(.setLabelingTool(.landmark))
        }
        return actions
    }

    private func sliceActions(in text: String) -> [AssistantAction] {
        var actions: [AssistantAction] = []

        if text.containsAny(["center", "middle", "midline", "reset slices"]) {
            actions.append(.centerSlices)
        }

        for (name, axis) in [("sagittal", 0), ("coronal", 1), ("axial", 2)] {
            if let index = integer(after: name, in: text) {
                actions.append(.setSlice(axis: axis, index: index))
            }
        }

        return actions
    }

    private func suvActions(in text: String) -> [AssistantAction] {
        var actions: [AssistantAction] = []

        if text.containsAny(["stored suv", "already suv"]) {
            actions.append(.setSUVMode(.storedSUV))
        } else if text.containsAny(["manual suv", "manual scale", "suv factor", "scale factor"]) {
            actions.append(.setSUVMode(.manualScale))
        } else if text.containsAny(["suvbsa", "suv bsa", "body surface area", "bsa"]) {
            actions.append(.setSUVMode(.bodySurfaceArea))
        } else if text.containsAny(["sul", "lean body mass", "lbm"]) {
            actions.append(.setSUVMode(.leanBodyMass))
        } else if text.containsAny(["suvbw", "suv bw", "body weight suv"]) {
            actions.append(.setSUVMode(.bodyWeight))
        }

        if text.containsAny(["mbq/ml", "mbqml", "mbq per ml"]) {
            actions.append(.setSUVActivityUnit(.mbqml))
        } else if text.containsAny(["kbq/ml", "kbqml", "kbq per ml"]) {
            actions.append(.setSUVActivityUnit(.kbqml))
        } else if text.containsAny(["bq/ml", "bqml", "bq per ml"]) {
            actions.append(.setSUVActivityUnit(.bqml))
        }

        if let factor = number(afterAny: ["suv factor", "manual factor", "scale factor"], in: text) {
            actions.append(.setSUVMode(.manualScale))
            actions.append(.setSUVManualScale(factor))
        }
        if let weight = number(afterAny: ["patient weight", "weight"], in: text) {
            actions.append(.setSUVPatientWeight(weight))
        }
        if let height = number(afterAny: ["patient height", "height"], in: text) {
            actions.append(.setSUVPatientHeight(height))
        }
        if let injected = number(afterAny: ["injected dose", "injection dose", "administered dose", "injected activity"], in: text) {
            actions.append(.setSUVInjectedDose(injected))
        }
        if let residual = number(afterAny: ["residual dose", "residual activity"], in: text) {
            actions.append(.setSUVResidualDose(residual))
        }

        return actions
    }

    private func segmentationActions(in text: String) -> [AssistantAction] {
        var actions: [AssistantAction] = []

        if text.containsAny(["create label", "new label", "label map", "segmentation map", "new segmentation"]) {
            let preset = labelPresetName(in: text)
            actions.append(.createLabelMap(preset))
        }

        if let preset = labelPresetName(in: text),
           text.containsAny(["preset", "load", "apply", "organ", "anatomy", "segmentation", "segment"]) {
            actions.append(.applyLabelPreset(preset))
        }

        if let target = labelTarget(in: text) {
            actions.append(.selectLabel(target))
        }

        if let threshold = thresholdValue(in: text) {
            actions.append(.setLabelingTool(.threshold))
            actions.append(.threshold(threshold))
        }

        if let percent = percentOfMax(in: text) {
            actions.append(.setLabelingTool(.threshold))
            actions.append(.setPercentOfMax(percent))
        }

        return actions
    }

    private func labelPresetName(in text: String) -> String? {
        if text.containsAny(["total segmentator", "totalsegmentator", "full anatomy", "all organs"]) {
            return "TotalSegmentator"
        }
        if text.containsAny(["autopet", "auto pet", "pet lesion", "fdg lesion"]) {
            return "AutoPET"
        }
        if text.containsAny(["brats", "brain tumor"]) {
            return "BraTS"
        }
        if text.containsAny(["amos", "abdominal organs"]) {
            return "AMOS"
        }
        if text.containsAny(["rt standard", "rtstruct", "radiotherapy", "oar"]) {
            return "RT Standard"
        }
        return nil
    }

    private func labelTarget(in text: String) -> String? {
        let targets = [
            "liver", "spleen", "pancreas", "stomach", "colon", "duodenum",
            "kidney", "kidney left", "kidney right", "lung", "heart", "aorta",
            "brain", "skull", "prostate", "bladder", "thyroid", "trachea",
            "esophagus", "spinal cord", "femur", "rib", "lesion", "tumor",
            "gtv", "ctv", "ptv"
        ]
        guard text.containsAny(["show", "view", "focus", "select", "segment", "highlight", "organ"]) else {
            return nil
        }
        return targets.first { text.contains($0) }
    }

    private func overlayOpacity(in text: String) -> Double? {
        guard text.containsAny(["opacity", "overlay alpha", "fusion alpha"]) else { return nil }
        if let percent = firstNumber(in: text), percent > 1 {
            return max(0, min(1, percent / 100))
        }
        if let fraction = firstNumber(in: text) {
            return max(0, min(1, fraction))
        }
        return nil
    }

    private func thresholdValue(in text: String) -> Double? {
        guard text.containsAny(["threshold", "suv", ">="]) else { return nil }
        return firstNumber(in: text)
    }

    private func percentOfMax(in text: String) -> Double? {
        guard text.contains("%") || text.contains("percent") else { return nil }
        guard text.containsAny(["max", "suvmax", "suv max"]) else { return nil }
        guard let number = firstNumber(in: text) else { return nil }
        return max(0.01, min(1, number / 100))
    }

    private func integer(after token: String, in text: String) -> Int? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: token))\\b\\s*(?:slice|image|index)?\\s*(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let numberRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[numberRange])
    }

    private func firstNumber(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "[-+]?\\d*\\.?\\d+") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let numberRange = Range(match.range, in: text) else {
            return nil
        }
        return Double(text[numberRange])
    }

    private func number(afterAny tokens: [String], in text: String) -> Double? {
        for token in tokens {
            if let value = number(after: token, in: text) {
                return value
            }
        }
        return nil
    }

    private func number(after token: String, in text: String) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "\\b\(escaped)\\b\\s*(?:is|=|to|at|of)?\\s*([-+]?\\d*\\.?\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let numberRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[numberRange])
    }
}

private extension String {
    var normalizedAssistantText: String {
        lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    func containsAny(_ needles: [String]) -> Bool {
        needles.contains { contains($0) }
    }
}

private extension Array where Element == AssistantAction {
    func removingAdjacentDuplicates() -> [AssistantAction] {
        var out: [AssistantAction] = []
        for action in self where out.last != action {
            out.append(action)
        }
        return out
    }
}
