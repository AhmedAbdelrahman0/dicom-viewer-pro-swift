import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Centralises every PET-related inference and quantification path the app
/// ships: nnU-Net baselines (AutoPET II), AutoPET III winner (LesionTracer),
/// AutoPET IV interactive (LesionLocator), MedSAM2 prompt refinement, TMTV
/// quantification, and TotalSegmentator-based physiological-uptake
/// subtraction. Each "engine" picks a different path through the same
/// viewer state and produces a label map + status message.
@MainActor
public final class PETEngineViewModel: ObservableObject {

    public enum Engine: String, CaseIterable, Identifiable, Sendable {
        case autoPETII
        case lesionTracer
        case lesionLocator
        case medSAM2
        case tmtv
        case totalSegPrefilter

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .autoPETII:         return "AutoPET II (FDG baseline)"
            case .lesionTracer:      return "LesionTracer (AutoPET III winner)"
            case .lesionLocator:     return "LesionLocator (interactive, experimental)"
            case .medSAM2:           return "MedSAM2 (box-prompt refinement)"
            case .tmtv:              return "TMTV / TLG quantification"
            case .totalSegPrefilter: return "Physiological uptake filter"
            }
        }

        public var systemImage: String {
            switch self {
            case .autoPETII:         return "flame"
            case .lesionTracer:      return "flame.fill"
            case .lesionLocator:     return "hand.tap.fill"
            case .medSAM2:           return "scope"
            case .tmtv:              return "sum"
            case .totalSegPrefilter: return "xmark.square.fill"
            }
        }

        public var description: String {
            switch self {
            case .autoPETII:
                return "Whole-body FDG-PET/CT lesion segmentation via nnU-Net v2 Dataset221_AutoPETII_2023. Apache-2.0. 2-channel (CT + PET)."
            case .lesionTracer:
                return "AutoPET III 2024 winner (MIC-DKFZ). Handles both FDG and PSMA tracers. nnU-Net ResEncL + MultiTalent pretraining. Weights CC-BY-4.0."
            case .lesionLocator:
                return "AutoPET IV 2025 interactive track: refine lesion masks with foreground/background click prompts. Experimental — weights still rolling out."
            case .medSAM2:
                return "Promptable foundation model. Draw a bounding box on any slice and MedSAM2 returns a refined 2D mask. Apache-2.0."
            case .tmtv:
                return "Compute total metabolic tumor volume (TMTV), total lesion glycolysis (TLG), SUV max/mean, and per-lesion stats from the active PET label map."
            case .totalSegPrefilter:
                return "Run TotalSegmentator on the co-registered CT, then subtract brain / bladder / heart / kidney / liver / spleen voxels from the active PET lesion mask."
            }
        }

        public var requiresAuxiliaryChannel: Bool {
            switch self {
            case .autoPETII, .lesionTracer, .lesionLocator, .totalSegPrefilter:
                return true
            case .medSAM2, .tmtv:
                return false
            }
        }
    }

    public enum SegmentationProfile: String, CaseIterable, Identifiable, Sendable {
        case fast
        case accurate
        case maxSensitivity

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .fast: return "Fast"
            case .accurate: return "Accurate"
            case .maxSensitivity: return "Max sensitivity"
            }
        }

        public var systemImage: String {
            switch self {
            case .fast: return "bolt.fill"
            case .accurate: return "target"
            case .maxSensitivity: return "scope"
            }
        }

        public var useFullEnsemble: Bool {
            switch self {
            case .fast, .accurate: return false
            case .maxSensitivity: return true
            }
        }

        public var disableTTA: Bool {
            switch self {
            case .fast: return true
            case .accurate, .maxSensitivity: return false
            }
        }

        public var applySUVAttention: Bool {
            switch self {
            case .fast: return false
            case .accurate, .maxSensitivity: return true
            }
        }
    }

    // MARK: - Published state

    @Published public var selectedEngine: Engine = .autoPETII
    @Published public var segmentationProfile: SegmentationProfile = .fast
    @Published public var suvAttentionThreshold: Double = 2.5
    @Published public var minimumLesionVolumeML: Double = 0.5
    @Published public var auxiliaryVolumeID: String?
    @Published public var medSAMModelPath: String = ""
    @Published public var medSAMBoxString: String = ""  // "x,y,w,h" on the current slice
    @Published public var suppressedOrganNames: [String] =
        PhysiologicalUptakeFilter.defaultSuppressedOrganNames
    @Published public var lastReport: PETQuantification.Report?
    @Published public private(set) var isRunning: Bool = false
    @Published public var statusMessage: String = ""

    // MARK: - Runners

    private let medSAMRunner = MedSAM2Runner()

    public init() {}

    // MARK: - Run

    /// Dispatch to whichever engine is currently selected. `viewer` owns
    /// the volume + fusion overlay state; `nnunet` owns catalog-backed
    /// inference; `labeling` owns the active label map.
    @discardableResult
    public func run(viewer: ViewerViewModel,
                    nnunet: NNUnetViewModel,
                    labeling: LabelingViewModel) async -> String {
        isRunning = true
        defer { isRunning = false }

        switch selectedEngine {
        case .autoPETII, .lesionTracer, .lesionLocator:
            return await runNNUnetPET(viewer: viewer,
                                      nnunet: nnunet,
                                      labeling: labeling)
        case .medSAM2:
            return await runMedSAM(viewer: viewer, labeling: labeling)
        case .tmtv:
            return await runTMTV(viewer: viewer, labeling: labeling)
        case .totalSegPrefilter:
            return await runTotalSegPrefilter(viewer: viewer,
                                              nnunet: nnunet,
                                              labeling: labeling)
        }
    }

    // MARK: - nnU-Net paths

    private func runNNUnetPET(viewer: ViewerViewModel,
                              nnunet: NNUnetViewModel,
                              labeling: LabelingViewModel) async -> String {
        let entryID: String = {
            switch selectedEngine {
            case .autoPETII:       return "AutoPET-II-2023"
            case .lesionTracer:    return "LesionTracer-AutoPETIII"
            case .lesionLocator:   return "LesionLocator-AutoPETIV"
            default:               return ""
            }
        }()
        nnunet.selectedEntryID = entryID

        guard let primaryVolume = viewer.currentVolume else {
            statusMessage = "Load a volume first."
            return statusMessage
        }
        guard let entry = nnunet.selectedEntry else {
            statusMessage = "Catalog entry \(entryID) is not registered."
            return statusMessage
        }

        // Resolve the auxiliary channel: the fusion overlay by default, or
        // the user's explicit pick if they set one.
        let auxiliary = resolveAuxiliaryVolume(
            viewer: viewer,
            preferred: auxiliaryVolumeID
        )

        guard entry.requiredChannels == 1 || auxiliary != nil else {
            statusMessage = "\(entry.displayName) needs \(entry.requiredChannels) channels — load the paired \(entry.channelDescriptions.dropFirst().joined(separator: " + ")) series (e.g. as a fusion overlay) and try again."
            return statusMessage
        }

        statusMessage = "Running \(entry.displayName)…"
        let extraChannels: [ImageVolume] = auxiliary.map { [$0] } ?? []
        // nnU-Net AutoPET expects channel 0 = CT, channel 1 = PET. If the
        // currently-loaded volume is PET, swap so CT goes first.
        let (channel0, restChannels) = orderChannelsForPETCT(
            primary: primaryVolume,
            auxiliary: extraChannels
        )
        let modelChannel0 = makePETModelInputChannel(channel0, viewer: viewer)
        let modelRestChannels = restChannels.map {
            makePETModelInputChannel($0, viewer: viewer)
        }
        guard let labelMap = await nnunet.run(
            on: modelChannel0,
            auxiliaryChannels: modelRestChannels,
            labeling: labeling,
            useFullEnsembleOverride: segmentationProfile.useFullEnsemble,
            disableTTAOverride: segmentationProfile.disableTTA
        ) else {
            statusMessage = nnunet.statusMessage
            return statusMessage
        }

        var postprocessSummary = ""
        if segmentationProfile.applySUVAttention,
           let petSUVChannel = ([modelChannel0] + modelRestChannels).first(where: {
               Modality.normalize($0.modality) == .PT
           }) {
            do {
                let result = try PETLesionPostprocessor.filterComponentsBySUV(
                    labelMap: labelMap,
                    petSUVVolume: petSUVChannel,
                    classID: 1,
                    minimumSUV: suvAttentionThreshold,
                    minimumVolumeML: minimumLesionVolumeML
                )
                postprocessSummary = " · SUV attention kept \(result.keptComponents), removed \(result.removedComponents)"
            } catch {
                postprocessSummary = " · SUV attention skipped: \(error.localizedDescription)"
            }
        }

        statusMessage = "✓ \(entry.displayName): \(labelMap.classes.count) classes produced\(postprocessSummary)."
        return statusMessage
    }

    // MARK: - MedSAM2

    private func runMedSAM(viewer: ViewerViewModel,
                           labeling: LabelingViewModel) async -> String {
        guard let volume = viewer.currentVolume else {
            statusMessage = "Load a volume first."
            return statusMessage
        }
        let trimmed = medSAMModelPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            statusMessage = "Point MedSAM2 at a .mlpackage first."
            return statusMessage
        }
        guard let box = parseBox(medSAMBoxString) else {
            statusMessage = "Box must be \"x,y,w,h\" in slice pixels."
            return statusMessage
        }
        guard let map = labeling.activeLabelMap
              ?? labeling.createLabelMap(for: volume,
                                         name: "MedSAM2 Labels",
                                         presetSet: nil) as LabelMap?
        else {
            statusMessage = "Could not prepare a label map for MedSAM2."
            return statusMessage
        }

        let spec = MedSAM2Runner.Spec(
            modelURL: URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        )
        do {
            let axisIndex = 2 // axial slice
            let sliceIndex = viewer.sliceIndices[axisIndex]
            let result = try await medSAMRunner.refineLesion(
                volume: volume,
                axis: axisIndex,
                sliceIndex: sliceIndex,
                box: box,
                into: map,
                classID: labeling.activeClassID == 0 ? 1 : labeling.activeClassID,
                spec: spec
            )
            statusMessage = "✓ MedSAM2: \(result.voxelsChanged) voxels painted on axial \(sliceIndex)."
        } catch {
            statusMessage = "MedSAM2 error: \(error.localizedDescription)"
        }
        return statusMessage
    }

    // MARK: - TMTV

    private func runTMTV(viewer: ViewerViewModel,
                         labeling: LabelingViewModel) async -> String {
        guard let pet = viewer.activePETQuantificationVolume ?? viewer.currentVolume else {
            statusMessage = "No PET volume is loaded."
            return statusMessage
        }
        guard let map = labeling.activeLabelMap else {
            statusMessage = "No active label map — run a lesion model or paint a mask first."
            return statusMessage
        }
        let snapshot = map.snapshot(name: "\(map.name) TMTV snapshot")
        let settings = viewer.suvSettings
        do {
            let report = try await Task.detached(priority: .userInitiated) {
                try PETQuantification.compute(
                    petVolume: pet,
                    labelMap: snapshot,
                    suvTransform: { raw in settings.suv(forStoredValue: raw, volume: pet) },
                    connectedComponents: true
                )
            }.value
            lastReport = report
            statusMessage = report.summary
        } catch {
            statusMessage = "TMTV failed: \(error.localizedDescription)"
        }
        return statusMessage
    }

    // MARK: - TotalSegmentator prefilter

    private func runTotalSegPrefilter(viewer: ViewerViewModel,
                                      nnunet: NNUnetViewModel,
                                      labeling: LabelingViewModel) async -> String {
        guard let petMask = labeling.activeLabelMap else {
            statusMessage = "No active PET lesion mask to clean up."
            return statusMessage
        }
        // Find the co-registered CT: prefer an explicit auxiliary pick, else
        // the first loaded CT volume.
        guard let ct = resolveAuxiliaryVolume(viewer: viewer,
                                              preferred: auxiliaryVolumeID)
              ?? viewer.loadedCTVolumes.first else {
            statusMessage = "No CT volume is loaded — open one before running the prefilter."
            return statusMessage
        }

        statusMessage = "Running TotalSegmentator on CT for physiological-uptake subtraction…"
        nnunet.selectedEntryID = "TotalSegmentatorCT"
        guard let anatomyMask = await nnunet.run(on: ct, labeling: labeling) else {
            statusMessage = nnunet.statusMessage
            return statusMessage
        }
        do {
            let result = try PhysiologicalUptakeFilter.subtract(
                petLesionMask: petMask,
                anatomyMask: anatomyMask,
                suppressedOrganNames: suppressedOrganNames
            )
            labeling.activeLabelMap = petMask
            if labeling.activeClassID == 0, let firstClass = petMask.classes.first {
                labeling.activeClassID = firstClass.labelID
            }
            statusMessage = "✓ Suppressed \(result.voxelsSuppressed) voxels across \(result.classesSuppressed.count) organs (\(result.classesSuppressed.joined(separator: ", "))"
        } catch {
            labeling.activeLabelMap = petMask
            statusMessage = "Physiological uptake filter failed: \(error.localizedDescription)"
        }
        return statusMessage
    }

    // MARK: - Auxiliary channel resolution

    /// Return the auxiliary `ImageVolume` the user selected, falling back
    /// to the current fusion overlay when no explicit pick is set.
    private func resolveAuxiliaryVolume(viewer: ViewerViewModel,
                                        preferred: String?) -> ImageVolume? {
        if let preferred,
           let match = viewer.loadedVolumes.first(where: { $0.sessionIdentity == preferred }) {
            return match
        }
        if let fusion = viewer.fusion {
            return fusion.resampledOverlay ?? fusion.overlayVolume
        }
        // Last resort: pick a volume with the opposite modality.
        if let currentModality = viewer.currentVolume.map({ Modality.normalize($0.modality) }) {
            let complementary: Modality = currentModality == .PT ? .CT : .PT
            return viewer.loadedVolumes.first(where: {
                Modality.normalize($0.modality) == complementary
            })
        }
        return nil
    }

    /// Ensure the CT volume is channel 0 and PET is channel 1, regardless
    /// of which one the user has currently loaded as the primary. nnU-Net
    /// AutoPET and LesionTracer both follow this ordering.
    private func orderChannelsForPETCT(primary: ImageVolume,
                                       auxiliary: [ImageVolume]) -> (ImageVolume, [ImageVolume]) {
        guard let aux = auxiliary.first else {
            return (primary, [])
        }
        let primaryModality = Modality.normalize(primary.modality)
        let auxModality = Modality.normalize(aux.modality)

        if primaryModality == .PT, auxModality == .CT {
            return (aux, [primary] + Array(auxiliary.dropFirst()))
        }
        return (primary, auxiliary)
    }

    /// Produce the PET channel that should be handed to an nnU-Net model
    /// trained on SUV-calibrated inputs (AutoPET II / LesionTracer / etc.).
    ///
    /// Single source of truth: delegates to the viewer's volume-aware SUV
    /// lookup, which in turn routes through `SUVCalculationSettings.suv(
    /// forStoredValue:volume:)`. No scaling logic is duplicated here.
    func makePETModelInputChannel(_ volume: ImageVolume,
                                  viewer: ViewerViewModel) -> ImageVolume {
        guard Modality.normalize(volume.modality) == .PT else { return volume }

        let scaledPixels = volume.pixels.map { raw -> Float in
            Float(viewer.suvValue(rawStoredValue: Double(raw), volume: volume))
        }

        return ImageVolume(
            pixels: scaledPixels,
            depth: volume.depth,
            height: volume.height,
            width: volume.width,
            spacing: volume.spacing,
            origin: volume.origin,
            direction: volume.direction,
            modality: volume.modality,
            seriesUID: volume.seriesUID,
            studyUID: volume.studyUID,
            patientID: volume.patientID,
            patientName: volume.patientName,
            seriesDescription: volume.seriesDescription.isEmpty
                ? "PET SUV input"
                : "\(volume.seriesDescription) (SUV input)",
            studyDescription: volume.studyDescription,
            suvScaleFactor: nil,
            sourceFiles: volume.sourceFiles
        )
    }

    private func parseBox(_ text: String) -> CGRect? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let w = Double(parts[2]),
              let h = Double(parts[3]),
              w > 0, h > 0 else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - File pickers

    #if canImport(AppKit)
    public func pickMedSAMModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Pick a MedSAM2 .mlpackage"
        if panel.runModal() == .OK, let url = panel.url {
            medSAMModelPath = url.path
        }
    }
    #endif
}
