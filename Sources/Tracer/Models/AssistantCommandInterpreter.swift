import Foundation

public enum AssistantAction: Equatable {
    case applyWindowPreset(String)
    case autoWindowLevel
    case setViewerTool(ViewerTool)
    case setLabelingTool(LabelingTool)
    case createLabelMap(String?)
    case applyLabelPreset(String)
    case selectLabel(String)
    case planSegmentation(SegmentationRAGPlan)
    case centerSlices
    case setSlice(axis: Int, index: Int)
    case setOverlayOpacity(Double)
    case setInvert(Bool?)
    case removeOverlay
    case threshold(Double)
    case setPercentOfMax(Double)
    case setGradientMinimumSUV(Double)
    case setGradientEdgeFraction(Double)
    case setSUVMode(SUVCalculationMode)
    case setSUVActivityUnit(PETActivityUnit)
    case setSUVManualScale(Double)
    case setSUVPatientWeight(Double)
    case setSUVPatientHeight(Double)
    case setSUVInjectedDose(Double)
    case setSUVResidualDose(Double)
    /// Run the per-lesion classifier on every connected component of the
    /// active label map. Honours the current `ClassificationViewModel`
    /// selection (classifier entry + paths).
    case classifyAllLesions
    /// Write the current classification report to `~/Downloads/…` as CSV
    /// or JSON. No-op if no classification has run yet.
    case exportClassificationReport(ClassificationExportFormat)
    /// Open the Cohort Batch inspector. Shortcut for "let me set up a
    /// 2000-study run without touching the menu."
    case openCohortPanel
    /// Run the configured lesion detector on the current volume. Mirrors
    /// `.classifyAllLesions` — posts a notification that ContentView
    /// routes to the LesionDetectorViewModel.
    case detectLesions
    /// Open the Lesion Detection inspector. Lets the user configure a
    /// detector without leaving the chat.
    case openLesionDetectorPanel
    /// Run the configured PET attenuation-correction model on the current
    /// (or fused-overlay) PET volume. Mirrors `.classifyAllLesions` —
    /// posts a notification that ContentView routes to the AC view model.
    case attenuationCorrectPET
    /// Open the PET Attenuation Correction inspector. Lets the user
    /// configure the AC method without leaving the chat.
    case openPETACPanel

    public enum ClassificationExportFormat: String, Equatable, Sendable {
        case csv
        case json
    }
}

public extension Notification.Name {
    /// Fired by `ViewerAssistant` when the chat interpreter matches a
    /// "classify lesions" intent. `ContentView` observes this and calls
    /// `ClassificationViewModel.classifyAll(...)` on the active label map.
    /// Decoupling via NotificationCenter keeps the `ViewerViewModel`
    /// extension free of a direct dependency on the classification VM.
    static let assistantDidRequestClassification = Notification.Name("Tracer.assistantDidRequestClassification")
    /// Fired when the chat says "export report as CSV/JSON". `userInfo`
    /// carries `"format"` with value `"csv"` or `"json"`.
    static let assistantDidRequestClassificationExport = Notification.Name("Tracer.assistantDidRequestClassificationExport")
    /// Fired by the chat when the user asks for the cohort panel or a
    /// cohort run.
    static let assistantDidRequestCohortPanel = Notification.Name("Tracer.assistantDidRequestCohortPanel")
    /// Fired for "detect lesions" intents. ContentView observes and
    /// runs the LesionDetectorViewModel on the active volume.
    static let assistantDidRequestLesionDetection = Notification.Name("Tracer.assistantDidRequestLesionDetection")
    /// Fired for "open the detection panel" intents.
    static let assistantDidRequestLesionDetectorPanel = Notification.Name("Tracer.assistantDidRequestLesionDetectorPanel")
    /// Fired by the chat for "attenuation correct this PET" intents.
    /// ContentView observes and calls `petAC.run(...)` on the active PET.
    static let assistantDidRequestPETAttenuationCorrection = Notification.Name("Tracer.assistantDidRequestPETAttenuationCorrection")
    /// Fired by the chat for "open the AC panel" intents.
    static let assistantDidRequestPETACPanel = Notification.Name("Tracer.assistantDidRequestPETACPanel")
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
        actions.append(contentsOf: classificationActions(in: text))
        actions.append(contentsOf: cohortActions(in: text))
        actions.append(contentsOf: detectionActions(in: text))
        actions.append(contentsOf: petACActions(in: text))

        return actions.removingAdjacentDuplicates()
    }

    /// Matches "classify (all) lesions", "run classifier", "classify
    /// findings" — anything that clearly names the classification phase.
    /// Also picks up "export report as csv / json".
    private func classificationActions(in text: String) -> [AssistantAction] {
        var actions: [AssistantAction] = []
        let triggerPhrases = [
            "classify lesions",
            "classify all lesions",
            "classify the lesions",
            "run classifier",
            "run classification",
            "classify findings",
            "classify the findings",
            "classify every lesion"
        ]
        if text.containsAny(triggerPhrases) {
            actions.append(.classifyAllLesions)
        }
        // "classify this lesion" or bare "classify" without "select / pick"
        // nearby — users saying just "classify" after they've segmented.
        if text.contains("classify"),
           !text.containsAny(["window", "select", "pick", "dont", "don't"]),
           !actions.contains(.classifyAllLesions) {
            actions.append(.classifyAllLesions)
        }

        if text.containsAny(["export", "save report", "save results", "save findings",
                             "download report", "download results"]) {
            if text.contains("csv") {
                actions.append(.exportClassificationReport(.csv))
            } else if text.contains("json") {
                actions.append(.exportClassificationReport(.json))
            } else if text.containsAny(["report", "findings", "results"]) {
                // No format specified — default to CSV because most users
                // who say "export the report" want a spreadsheet.
                actions.append(.exportClassificationReport(.csv))
            }
        }
        return actions
    }

    /// Cohort-batch intents. Kept deliberately permissive because the
    /// user's language for "do this on all 2000 studies" is highly varied.
    private func cohortActions(in text: String) -> [AssistantAction] {
        var actions: [AssistantAction] = []
        let cohortTriggers = [
            "cohort",
            "batch run",
            "batch process",
            "all studies",
            "every study",
            "every scan",
            "run on all",
            "process the cohort",
            "run the batch",
            "open cohort",
            "cohort panel",
            "batch segmentation",
            "batch classification"
        ]
        if text.containsAny(cohortTriggers) {
            actions.append(.openCohortPanel)
        }
        return actions
    }

    /// Lesion-detection intents. "Detect lesions" / "find lesions" /
    /// "run nndetection" → run; "open the detection panel" → open.
    /// We avoid bare `text.contains("detect")` as the only run
    /// trigger because users say "I detected something earlier" or
    /// "what did the model detect?" without wanting to fire an
    /// inference. The trigger list keeps precision high.
    private func detectionActions(in text: String) -> [AssistantAction] {
        var actions: [AssistantAction] = []
        let openTriggers = [
            "detection panel",
            "lesion detector",
            "open detection",
            "open detector",
            "open lesion detection",
            "show detector",
            "show detection panel"
        ]
        let runTriggers = [
            "detect lesions",
            "find lesions",
            "run detection",
            "run detector",
            "run nndetection",
            "run deeplesion",
            "lesion detection on",
            "find every lesion",
            "find all lesions",
            "detect findings"
        ]
        if text.containsAny(openTriggers) {
            actions.append(.openLesionDetectorPanel)
        }
        if text.containsAny(runTriggers) {
            actions.append(.detectLesions)
        }
        return actions
    }

    /// PET attenuation-correction intents. Two distinct shapes:
    ///   • "open the AC panel" / "show me attenuation correction" → just
    ///     opens the inspector
    ///   • "attenuation correct this PET" / "run AC" / "AC the PET" → runs
    ///     immediately on the active PET
    /// We avoid bare `text.contains("ac")` because "ac" matches "back",
    /// "facade", "vacancy", "matter-of-fact" — way too eager. Multi-word
    /// triggers + the explicit acronym paths keep precision high.
    private func petACActions(in text: String) -> [AssistantAction] {
        var actions: [AssistantAction] = []
        let openTriggers = [
            "ac panel",
            "attenuation correction panel",
            "open ac",
            "show ac",
            "show attenuation",
            "open attenuation correction",
            "open attenuation",
            "pet ac panel"
        ]
        let runTriggers = [
            "attenuation correct",
            "attenuation correction",
            "attenuation-correct",
            "run ac",
            "run attenuation",
            "ac correct",
            "ac the pet",
            "produce ac",
            "produce attenuated",
            "produce an attenuated",
            "generate ac",
            "nac to ac",
            "nac->ac",
            "nac → ac"
        ]
        if text.containsAny(openTriggers) {
            actions.append(.openPETACPanel)
        }
        if text.containsAny(runTriggers) {
            actions.append(.attenuationCorrectPET)
        }
        return actions
    }

    private func windowPresetName(in text: String) -> String? {
        // Two-level match: phrases (multi-word) use substring match;
        // single-word aliases use word-boundary match so the assistant
        // doesn't fire "Brain" on "ahead of you" (contains "head") or
        // "Standard" on "petroleum" (contains "pet").
        let phrasePairs: [(String, [String])] = [
            ("Soft Tissue", ["soft tissue", "soft-tissue"]),
        ]
        let wordPairs: [(String, [String])] = [
            ("Lung", ["lung", "lungs", "pulmonary"]),
            ("Bone", ["bone", "bones", "osseous"]),
            ("Brain", ["brain", "head"]),
            ("Liver", ["liver", "hepatic"]),
            ("Abdomen", ["abdomen", "abdominal"]),
            ("Mediastinum", ["mediastinum", "mediastinal"]),
            ("Soft Tissue", ["soft"]),
            ("Angio", ["angio", "angiography", "vessel", "vascular", "artery", "cta"]),
            ("Standard", ["pet", "suv", "fdg"])
        ]
        if let hit = phrasePairs.first(where: { _, aliases in text.containsAny(aliases) }) {
            return hit.0
        }
        return wordPairs.first { _, aliases in text.containsAnyWord(aliases) }?.0
    }

    private func toolActions(in text: String) -> [AssistantAction] {
        var actions: [AssistantAction] = []
        if text.containsAny(["distance", "ruler", "measure length"]) {
            actions.append(.setViewerTool(.distance))
        } else if text.containsAny(["angle", "cobb"]) {
            actions.append(.setViewerTool(.angle))
        } else if text.containsAny(["area", "roi", "region of interest"]) {
            actions.append(.setViewerTool(.area))
        } else if text.containsWord("pan") || text.containsWord("panning") {
            actions.append(.setViewerTool(.pan))
        } else if text.containsWord("zoom") || text.containsWord("zooming") {
            actions.append(.setViewerTool(.zoom))
        } else if text.containsAny(["window level", "windowing", "wl tool"]) {
            actions.append(.setViewerTool(.wl))
        }

        if text.containsAny(["brush", "paint"]) {
            actions.append(.setLabelingTool(.brush))
        }
        if text.containsAnyWord(["erase", "eraser", "erased", "erasing"]) {
            actions.append(.setLabelingTool(.eraser))
        }
        if text.containsAny(["freehand", "lasso", "draw contour", "manual contour"]) {
            actions.append(.setLabelingTool(.freehand))
        }
        if text.contains("threshold") {
            actions.append(.setLabelingTool(.threshold))
        }
        if wantsGradientSegmentation(in: text) {
            actions.append(.setLabelingTool(.suvGradient))
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
        let ragPlan = SegmentationRAG.plan(for: text)
        if let ragPlan {
            actions.append(.planSegmentation(ragPlan))
        }

        if text.containsAny(["create label", "new label", "label map", "segmentation map", "new segmentation"]) {
            let preset = labelPresetName(in: text)
            actions.append(.createLabelMap(preset))
        }

        if ragPlan == nil,
           let preset = labelPresetName(in: text),
           text.containsAny(["preset", "load", "apply", "organ", "anatomy", "segmentation", "segment"]) {
            actions.append(.applyLabelPreset(preset))
        }

        if ragPlan == nil, let target = labelTarget(in: text) {
            actions.append(.selectLabel(target))
        }

        let wantsGradient = wantsGradientSegmentation(in: text)
        if wantsGradient {
            actions.append(.setLabelingTool(.suvGradient))
            if let threshold = thresholdValue(in: text) {
                actions.append(.setGradientMinimumSUV(threshold))
            }
            if let edge = number(afterAny: ["edge stop", "gradient stop", "edge strength"], in: text) {
                actions.append(.setGradientEdgeFraction(max(0.05, min(0.95, edge))))
            }
        } else if let threshold = thresholdValue(in: text) {
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
        if text.containsAny(["threshold", ">=", "greater than", "above"]) {
            return firstNumber(in: text)
        }
        if wantsGradientSegmentation(in: text),
           text.containsAny(["floor", "minimum", "min"]) {
            return firstNumber(in: text)
        }
        return firstCapturedNumber(
            pattern: "\\bsuv\\b\\s*(?:>=|>|at|above|over)?\\s*([-+]?\\d*\\.?\\d+)",
            in: text
        )
    }

    private func wantsGradientSegmentation(in text: String) -> Bool {
        text.containsAny(["pet edge", "suv gradient", "gradient edge"]) ||
        (text.contains("gradient") && text.containsAny(["pet", "suv", "lesion", "contour", "segment"])) ||
        (text.contains("edge") && text.containsAny(["pet", "suv", "lesion", "contour"]))
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
        return firstCapturedNumber(pattern: pattern, in: text)
    }

    private func firstCapturedNumber(pattern: String, in text: String) -> Double? {
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

    /// Word-boundary match — `"help me expand this".containsWord("pan")` is
    /// `false`, while `"pan to the right".containsWord("pan")` is `true`.
    /// Needed because the assistant parser's single-word triggers (`pan`,
    /// `zoom`, `head`, `pet`) were matching unrelated substrings ("expand",
    /// "competitive", "ahead", "petroleum") and firing viewer commands the
    /// user didn't ask for.
    func containsWord(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let lowerNeedle = needle.lowercased()
        // Walk through characters. A word is a maximal run of letters or
        // digits — everything else (whitespace, punctuation, hyphens after
        // normalisation, etc.) is a word boundary.
        var inWord = false
        var wordStart = startIndex
        var i = startIndex
        while i < endIndex {
            let ch = self[i]
            let isWordChar = ch.isLetter || ch.isNumber
            if isWordChar {
                if !inWord {
                    wordStart = i
                    inWord = true
                }
            } else if inWord {
                let word = self[wordStart..<i].lowercased()
                if word == lowerNeedle { return true }
                inWord = false
            }
            i = self.index(after: i)
        }
        if inWord {
            let word = self[wordStart..<endIndex].lowercased()
            if word == lowerNeedle { return true }
        }
        return false
    }

    func containsAnyWord(_ needles: [String]) -> Bool {
        needles.contains { containsWord($0) }
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
