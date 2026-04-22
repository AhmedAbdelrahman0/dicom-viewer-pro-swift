import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

public struct AssistantCommandReport: Equatable {
    public let applied: [String]
    public let warnings: [String]

    public var didApplyActions: Bool { !applied.isEmpty }

    public var summary: String {
        let parts = applied + warnings
        if parts.isEmpty {
            return "I did not find a direct viewer command in that request."
        }
        return parts.joined(separator: "\n")
    }
}

@MainActor
public extension ViewerViewModel {
    @discardableResult
    func performAssistantCommand(_ prompt: String) -> AssistantCommandReport {
        let actions = AssistantCommandInterpreter().actions(for: prompt)
        guard !actions.isEmpty else {
            return AssistantCommandReport(applied: [], warnings: [])
        }

        var applied: [String] = []
        var warnings: [String] = []

        for action in actions {
            switch action {
            case .applyWindowPreset(let name):
                if let preset = windowPreset(named: name) {
                    applyPreset(preset)
                    applied.append("Applied \(preset.name) window/level (\(Int(preset.window))/\(Int(preset.level))).")
                } else {
                    warnings.append("No \(name) window preset is available for this modality.")
                }

            case .autoWindowLevel:
                if currentVolume == nil {
                    warnings.append("Load a volume before auto window/level.")
                } else {
                    autoWL()
                    applied.append("Auto window/level recalculated from the current volume.")
                }

            case .setViewerTool(let tool):
                labeling.labelingTool = .none
                activeTool = tool
                applied.append("Viewer tool set to \(tool.displayName).")

            case .setLabelingTool(let tool):
                if tool != .none {
                    ensureLabelMapForAssistant(defaultPreset: nil, warnings: &warnings)
                }
                activeTool = .wl
                labeling.labelingTool = tool
                applied.append("Segmentation tool set to \(tool.displayName).")

            case .createLabelMap(let presetName):
                if let map = ensureLabelMapForAssistant(defaultPreset: presetName, warnings: &warnings) {
                    applied.append("Created/selected label map: \(map.name).")
                }

            case .applyLabelPreset(let presetName):
                if let preset = LabelPresets.byName(presetName) {
                    if ensureLabelMapForAssistant(defaultPreset: nil, warnings: &warnings) != nil {
                        labeling.applyPreset(preset)
                        applied.append("Loaded \(preset.name) label preset (\(preset.classes.count) classes).")
                    }
                } else {
                    warnings.append("I could not find the \(presetName) label preset.")
                }

            case .selectLabel(let labelName):
                selectAssistantLabel(labelName, applied: &applied, warnings: &warnings)

            case .planSegmentation(let plan):
                applySegmentationPlan(plan, applied: &applied, warnings: &warnings)

            case .centerSlices:
                if let v = currentVolume {
                    sliceIndices = [v.width / 2, v.height / 2, v.depth / 2]
                    applied.append("Centered sagittal, coronal, and axial slices.")
                } else {
                    warnings.append("Load a volume before centering slices.")
                }

            case .setSlice(let axis, let index):
                if currentVolume != nil {
                    setSlice(axis: axis, index: index)
                    applied.append("\(axisName(axis)) slice set to \(sliceIndices[axis]).")
                } else {
                    warnings.append("Load a volume before changing slices.")
                }

            case .setOverlayOpacity(let opacity):
                overlayOpacity = opacity
                fusion?.opacity = opacity
                applied.append("Overlay opacity set to \(Int(opacity * 100))%.")

            case .setInvert(let requested):
                invertColors = requested ?? !invertColors
                applied.append(invertColors ? "Image inversion enabled." : "Image inversion disabled.")

            case .removeOverlay:
                removeOverlay()
                applied.append("Fusion overlay removed.")

            case .threshold(let threshold):
                guard let volume = currentVolume else {
                    warnings.append("Load a volume before threshold segmentation.")
                    break
                }
                ensureLabelMapForAssistant(defaultPreset: defaultPresetFor(volume: volume), warnings: &warnings)
                labeling.thresholdValue = threshold
                labeling.labelingTool = .threshold
                thresholdActiveLabel(atOrAbove: threshold)
                applied.append("Segmented voxels at or above \(String(format: "%.2f", threshold)) using the active SUV/intensity calculation.")

            case .setPercentOfMax(let percent):
                labeling.percentOfMax = percent
                labeling.labelingTool = .threshold
                applied.append("Set seed segmentation to \(Int(percent * 100))% of SUVmax/intensity max.")

            case .setGradientMinimumSUV(let value):
                labeling.thresholdValue = value
                labeling.labelingTool = .suvGradient
                applied.append("Set SUV gradient floor to \(String(format: "%.2f", value)).")

            case .setGradientEdgeFraction(let value):
                labeling.gradientCutoffFraction = value
                labeling.labelingTool = .suvGradient
                applied.append("Set SUV gradient edge stop to \(String(format: "%.2f", value)).")

            case .setSUVMode(let mode):
                suvSettings.mode = mode
                applied.append("SUV calculation set to \(mode.displayName).")

            case .setSUVActivityUnit(let unit):
                suvSettings.activityUnit = unit
                applied.append("PET input activity unit set to \(unit.displayName).")

            case .setSUVManualScale(let factor):
                suvSettings.mode = .manualScale
                suvSettings.manualScaleFactor = factor
                applied.append("Manual SUV scale factor set to \(String(format: "%.4g", factor)).")

            case .setSUVPatientWeight(let weight):
                suvSettings.patientWeightKg = weight
                applied.append("Patient weight set to \(String(format: "%.1f", weight)) kg for SUV.")

            case .setSUVPatientHeight(let height):
                suvSettings.patientHeightCm = height
                applied.append("Patient height set to \(String(format: "%.1f", height)) cm for SUV.")

            case .setSUVInjectedDose(let dose):
                suvSettings.injectedDoseMBq = dose
                applied.append("Injected dose set to \(String(format: "%.1f", dose)) MBq.")

            case .setSUVResidualDose(let dose):
                suvSettings.residualDoseMBq = dose
                applied.append("Residual dose set to \(String(format: "%.1f", dose)) MBq.")
            }
        }

        if !applied.isEmpty || !warnings.isEmpty {
            statusMessage = (applied.last ?? warnings.last) ?? statusMessage
        }
        return AssistantCommandReport(applied: applied, warnings: warnings)
    }

    var assistantContextSummary: String {
        var lines: [String] = []
        if let v = currentVolume {
            lines.append("Current volume: \(v.patientName.isEmpty ? "Unknown patient" : v.patientName), \(Modality.normalize(v.modality).displayName), \(v.seriesDescription.isEmpty ? "Untitled series" : v.seriesDescription).")
            lines.append("Study: \(v.studyDescription.isEmpty ? "Untitled study" : v.studyDescription). Dimensions: \(v.width)x\(v.height)x\(v.depth). Spacing: \(String(format: "%.2f", v.spacing.x)) x \(String(format: "%.2f", v.spacing.y)) x \(String(format: "%.2f", v.spacing.z)) mm.")
            lines.append("Window/level: \(String(format: "%.0f", window))/\(String(format: "%.0f", level)). Slices: sagittal \(sliceIndices[0]), coronal \(sliceIndices[1]), axial \(sliceIndices[2]).")
        } else {
            lines.append("No image volume is currently loaded.")
        }

        if let fusion {
            lines.append("Fusion overlay: \(fusion.overlayVolume.seriesDescription), opacity \(Int(fusion.opacity * 100))%, colormap \(fusion.colormap.displayName).")
        }

        if activePETQuantificationVolume != nil {
            lines.append("SUV calculation: \(suvSettings.mode.displayName). \(suvSettings.scaleDescription)")
        }

        if let map = labeling.activeLabelMap {
            let activeClass = map.classInfo(id: labeling.activeClassID)?.name ?? "none"
            lines.append("Active label map: \(map.name), \(map.classes.count) classes, active class \(activeClass).")
        } else {
            lines.append("No active label map.")
        }

        lines.append("Viewer tool: \(activeTool.displayName). Segmentation tool: \(labeling.labelingTool.displayName).")
        return lines.joined(separator: "\n")
    }

    func exportAssistantViewportSnapshots() -> [URL] {
        guard currentVolume != nil else { return [] }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DicomViewerProAssistant", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return []
        }

        return [
            (axis: 2, name: "axial"),
            (axis: 0, name: "sagittal"),
            (axis: 1, name: "coronal")
        ].compactMap { item in
            guard let image = makeImage(for: item.axis) else { return nil }
            let url = directory.appendingPathComponent("\(item.name).png")
            return writePNG(image, to: url) ? url : nil
        }
    }

    private func windowPreset(named name: String) -> WindowLevel? {
        let modality = currentVolume.map { Modality.normalize($0.modality) } ?? .CT
        let modalityPresets = WLPresets.presets(for: modality)
        if let exact = modalityPresets.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        return (WLPresets.CT + WLPresets.MR + WLPresets.PT)
            .first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    @discardableResult
    private func ensureLabelMapForAssistant(defaultPreset presetName: String?,
                                            warnings: inout [String]) -> LabelMap? {
        if let map = labeling.activeLabelMap {
            if let presetName, map.classes.isEmpty, let preset = LabelPresets.byName(presetName) {
                labeling.applyPreset(preset)
            }
            return map
        }

        guard let volume = currentVolume else {
            warnings.append("Load a volume before creating a label map.")
            return nil
        }

        let preset = presetName.flatMap(LabelPresets.byName)
        let map = labeling.createLabelMap(
            for: volume,
            name: preset.map { "\($0.name) Labels" } ?? "AI Labels",
            presetSet: preset
        )
        return map
    }

    private func selectAssistantLabel(_ labelName: String,
                                      applied: inout [String],
                                      warnings: inout [String],
                                      defaultPreset presetName: String? = nil,
                                      centerOnExistingMask: Bool = true,
                                      createIfMissing: Bool = false,
                                      categoryHint: LabelCategory? = nil) {
        let presetName = presetName ?? defaultPresetForCurrentVolume(labelName: labelName)
        guard let map = ensureLabelMapForAssistant(defaultPreset: presetName,
                                                   warnings: &warnings) else {
            return
        }

        if map.classes.isEmpty || !map.classes.contains(where: { classMatches($0.name, labelName) }) {
            if let preset = LabelPresets.byName(presetName) {
                labeling.applyPreset(preset)
            }
        }

        guard let cls = map.classes.first(where: { classMatches($0.name, labelName) }) else {
            if createIfMissing {
                let labelID = nextAssistantLabelID(in: map)
                // Prefer the category the planner/preset knows, then fall back
                // to a heuristic on the label name. This keeps synthetic
                // classes (e.g. "liver_tumor") filed under .tumor instead of
                // drifting into .custom the way the heuristic alone would.
                let category = categoryHint
                    ?? preferredCategory(for: labelName, presetName: presetName)
                    ?? inferredCategory(for: labelName)
                let cls = LabelClass(
                    labelID: labelID,
                    name: labelName,
                    category: category,
                    color: assistantLabelColor(index: Int(labelID))
                )
                map.classes.append(cls)
                labeling.activeClassID = cls.labelID
                map.visible = true
                map.objectWillChange.send()
                applied.append("Added and selected label class \(cls.name) (\(category.rawValue)).")
                return
            }
            warnings.append("No label class matched \(labelName).")
            return
        }

        labeling.activeClassID = cls.labelID
        map.visible = true
        applied.append("Selected label class \(cls.name).")

        if let box = map.boundingBox(classID: cls.labelID) {
            setSlice(axis: 0, index: (box.minX + box.maxX) / 2)
            setSlice(axis: 1, index: (box.minY + box.maxY) / 2)
            setSlice(axis: 2, index: (box.minZ + box.maxZ) / 2)
            applied.append("Centered slices on the existing \(cls.name) mask.")
        } else if centerOnExistingMask {
            warnings.append("\(cls.name) is selected, but it has no labeled voxels yet.")
        }
    }

    private func applySegmentationPlan(_ plan: SegmentationRAGPlan,
                                       applied: inout [String],
                                       warnings: inout [String]) {
        guard currentVolume != nil else {
            warnings.append("Load a volume before applying a segmentation plan.")
            return
        }

        guard LabelPresets.byName(plan.presetName) != nil else {
            warnings.append("Segmentation RAG selected \(plan.presetName), but that preset is not installed.")
            return
        }

        if ensureLabelMapForAssistant(defaultPreset: plan.presetName, warnings: &warnings) != nil {
            // Pull the intended category directly from the preset the planner
            // selected — this avoids the heuristic fallback creating
            // e.g. `.custom` for "pancreatic lesion" when the preset knows it's
            // a `.lesion` / `.tumor`.
            let categoryHint = LabelPresets.byName(plan.presetName)?
                .classes
                .first(where: { classMatches($0.name, plan.labelName) })?
                .category
            selectAssistantLabel(
                plan.labelName,
                applied: &applied,
                warnings: &warnings,
                defaultPreset: plan.presetName,
                centerOnExistingMask: false,
                createIfMissing: true,
                categoryHint: categoryHint
            )
            activeTool = .wl
            labeling.labelingTool = plan.tool
            applied.append("Segmentation RAG selected \(plan.modelName): \(plan.labelName) using \(plan.tool.displayName).")
            applied.append("Rationale: \(plan.rationale)")
            if plan.confidence < 0.55 {
                warnings.append("Segmentation RAG confidence is modest; verify the label/model before batch work.")
            }
        }
    }

    /// Best-effort category lookup: ask the named preset whether any of its
    /// classes matches `labelName`; if so, return that class's category.
    /// Returns `nil` when the preset doesn't recognise the label so the
    /// caller can fall through to the heuristic.
    private func preferredCategory(for labelName: String,
                                   presetName: String) -> LabelCategory? {
        guard let preset = LabelPresets.byName(presetName) else { return nil }
        return preset.classes.first(where: { classMatches($0.name, labelName) })?.category
    }

    private func classMatches(_ className: String, _ query: String) -> Bool {
        let normalizedClass = normalizeLabelText(className)
        let normalizedQuery = normalizeLabelText(query)
        return normalizedClass.contains(normalizedQuery) || normalizedQuery.contains(normalizedClass)
    }

    private func normalizeLabelText(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func nextAssistantLabelID(in map: LabelMap) -> UInt16 {
        // Optimistic O(n): the next id is almost always max-used + 1 when the
        // label set grows monotonically. Fall back to a linear scan only when
        // the dense range is saturated (extremely rare — >65k classes).
        let used = Set(map.classes.map(\.labelID))
        let maxUsed = used.max() ?? 0
        if maxUsed < UInt16.max {
            let candidate = maxUsed &+ 1
            if !used.contains(candidate) { return candidate }
        }
        for id in UInt16(1)..<UInt16.max where !used.contains(id) {
            return id
        }
        return UInt16.max
    }

    private func inferredCategory(for labelName: String) -> LabelCategory {
        let q = normalizeLabelText(labelName)
        if q.contains("tumor") || q.contains("tumour") || q.contains("mass") || q.contains("cancer") {
            return .tumor
        }
        if q.contains("lesion") || q.contains("metast") || q.contains("nodule") || q.contains("cyst") {
            return .lesion
        }
        if q.contains("vessel") || q.contains("vein") || q.contains("artery") {
            return .vessel
        }
        if q.contains("heart") || q.contains("atrium") || q.contains("ventricle") {
            return .cardiac
        }
        return .custom
    }

    private func assistantLabelColor(index: Int) -> Color {
        let palette: [(Int, Int, Int)] = [
            (255, 80, 80), (255, 150, 40), (220, 90, 180), (140, 90, 220),
            (70, 160, 240), (70, 210, 190), (120, 210, 90), (240, 220, 80)
        ]
        let (r, g, b) = palette[index % palette.count]
        return Color(r: r, g: g, b: b)
    }

    private func defaultPresetForCurrentVolume(labelName: String) -> String {
        let q = labelName.lowercased()
        if q.contains("fdg") || q.contains("lesion") || q.contains("tumor") || q.contains("metast") {
            return Modality.normalize(currentVolume?.modality ?? "") == .PT ? "AutoPET" : "Oncology (Clinical)"
        }
        if q.contains("gtv") || q.contains("ctv") || q.contains("ptv") {
            return "RT Standard"
        }
        return "TotalSegmentator"
    }

    private func defaultPresetFor(volume: ImageVolume) -> String {
        Modality.normalize(volume.modality) == .PT ? "AutoPET" : "Oncology (Clinical)"
    }

    private func axisName(_ axis: Int) -> String {
        switch axis {
        case 0: return "Sagittal"
        case 1: return "Coronal"
        default: return "Axial"
        }
    }

    private func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
