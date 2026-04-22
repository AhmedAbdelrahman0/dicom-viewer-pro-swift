import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Orchestration for nnU-Net inference — picks a catalog entry, drives the
/// subprocess or CoreML runner, publishes live stderr logs and status.
@MainActor
public final class NNUnetViewModel: ObservableObject {

    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        /// Shell out to a local `nnUNetv2_predict` Python install.
        case subprocess
        /// Run a pre-converted CoreML `.mlpackage` on-device.
        case coreML

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .subprocess: return "Python (nnUNetv2)"
            case .coreML:     return "CoreML on-device"
            }
        }
    }

    /// Per-dataset auxiliary-channel pick. Users set this when a model needs
    /// multiple input channels (e.g. AutoPET wants CT as channel 0 and PET
    /// as channel 1). Stored as the `ImageVolume.sessionIdentity` so it
    /// survives re-loads in the session.
    @Published public var channelAssignments: [String: String] = [:]

    // MARK: - Published state

    @Published public var mode: Mode = .subprocess
    @Published public var selectedEntryID: String = NNUnetCatalog.all.first?.id ?? ""
    @Published public var customBinaryPath: String = ""
    @Published public var resultsDirPath: String = ""
    @Published public var coreMLModelPath: String = ""
    @Published public var useFullEnsemble: Bool = false
    @Published public var disableTTA: Bool = true
    @Published public var log: String = ""
    @Published public private(set) var isRunning: Bool = false
    @Published public var statusMessage: String = ""

    // MARK: - Runners

    private let subprocessRunner = NNUnetRunner()
    private let coreMLRunner = NNUnetCoreMLRunner()

    public init() {}

    public var selectedEntry: NNUnetCatalog.Entry? {
        NNUnetCatalog.byID(selectedEntryID)
    }

    public var isSubprocessAvailable: Bool {
        NNUnetRunner.locatePredictBinary(override:
            customBinaryPath.isEmpty ? nil : customBinaryPath
        ) != nil
    }

    public var coreMLReadinessMessage: String? {
        let trimmed = coreMLModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Point the CoreML path at a .mlpackage or .mlmodelc first."
        }

        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        let allowedExtensions: Set<String> = ["mlpackage", "mlmodelc"]
        guard allowedExtensions.contains(url.pathExtension.lowercased()) else {
            return "CoreML model path must end in .mlpackage or .mlmodelc."
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return "CoreML model package not found at \(url.path)."
        }
        guard isDirectory.boolValue else {
            return "CoreML model path must point to a package directory."
        }

        return nil
    }

    public func cancel() {
        subprocessRunner.cancel()
    }

    @discardableResult
    public func selectBestEntry(for plan: SegmentationRAGPlan) -> NNUnetCatalog.Entry? {
        guard let entryID = plan.nnunetEntryID,
              let entry = NNUnetCatalog.byID(entryID) else {
            return nil
        }
        selectedEntryID = entry.id
        statusMessage = "Segmentation RAG selected nnU-Net \(entry.displayName)."
        return entry
    }

    // MARK: - Run

    /// Run inference on `volume` and install the result into `labeling`.
    /// When the entry is `multiChannel`, provide the auxiliary channels in
    /// `auxiliaryChannels` (ordered so `auxiliaryChannels[i]` becomes
    /// nnU-Net channel `i + 1`; `volume` is always channel 0).
    @discardableResult
    public func run(on volume: ImageVolume,
                    auxiliaryChannels: [ImageVolume] = [],
                    labeling: LabelingViewModel) async -> LabelMap? {
        guard let entry = selectedEntry else {
            statusMessage = "Pick a model first."
            return nil
        }

        // Modality sanity check.
        let vmModality = Modality.normalize(volume.modality)
        if vmModality != entry.modality, vmModality != .OT {
            statusMessage = "Warning: model expects \(entry.modality.displayName), volume is \(vmModality.displayName). Running anyway."
        }
        if entry.multiChannel, auxiliaryChannels.isEmpty {
            statusMessage = "Model \(entry.datasetID) needs \(entry.requiredChannels) channels. Pick the auxiliary volume(s) in the panel before running."
            return nil
        }

        isRunning = true
        log = ""
        defer { isRunning = false }

        let start = Date()
        switch mode {
        case .subprocess:
            return await runSubprocess(entry: entry,
                                       volume: volume,
                                       auxiliaryChannels: auxiliaryChannels,
                                       labeling: labeling,
                                       start: start)
        case .coreML:
            if !auxiliaryChannels.isEmpty {
                statusMessage = "CoreML path is single-channel only; use the subprocess runner for multi-channel models."
                return nil
            }
            return await runCoreML(entry: entry, volume: volume, labeling: labeling, start: start)
        }
    }

    private func runSubprocess(entry: NNUnetCatalog.Entry,
                               volume: ImageVolume,
                               auxiliaryChannels: [ImageVolume],
                               labeling: LabelingViewModel,
                               start: Date) async -> LabelMap? {
        let cfg = NNUnetRunner.Configuration(
            predictBinaryPath: customBinaryPath.isEmpty ? nil : customBinaryPath,
            resultsDir: resultsDirPath.isEmpty
                ? nil
                : URL(fileURLWithPath: (resultsDirPath as NSString).expandingTildeInPath),
            configuration: entry.configuration,
            folds: useFullEnsemble
                ? ["0", "1", "2", "3", "4"]
                : entry.folds,
            disableTestTimeAugmentation: disableTTA
        )
        subprocessRunner.update(configuration: cfg)

        guard subprocessRunner.isAvailable() else {
            statusMessage = "nnUNetv2_predict not found. Set a custom path or install nnunetv2."
            return nil
        }

        statusMessage = auxiliaryChannels.isEmpty
            ? "Running \(entry.datasetID)…"
            : "Running \(entry.datasetID) with \(auxiliaryChannels.count + 1) channels…"
        do {
            // Primary volume becomes channel 0; auxiliaries fill 1..n in order.
            let channels = [volume] + auxiliaryChannels
            let result = try await subprocessRunner.runInference(
                channels: channels,
                referenceVolume: volume,
                datasetID: entry.datasetID
            ) { [weak self] line in
                Task { @MainActor in
                    self?.log.append(line)
                    self?.log.append("\n")
                }
            }

            applyClassNames(from: entry, to: result.labelMap)
            labeling.labelMaps.append(result.labelMap)
            labeling.activeLabelMap = result.labelMap
            if let first = result.labelMap.classes.first {
                labeling.activeClassID = first.labelID
            }
            let elapsed = String(format: "%.1f", result.durationSeconds)
            statusMessage = "✓ \(entry.displayName) finished in \(elapsed)s · \(result.labelMap.classes.count) classes"
            return result.labelMap
        } catch let err as NNUnetRunner.RunError {
            statusMessage = err.localizedDescription
            return nil
        } catch {
            statusMessage = "nnU-Net error: \(error.localizedDescription)"
            return nil
        }
    }

    private func runCoreML(entry: NNUnetCatalog.Entry,
                           volume: ImageVolume,
                           labeling: LabelingViewModel,
                           start: Date) async -> LabelMap? {
        let trimmed = coreMLModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let readinessMessage = coreMLReadinessMessage {
            statusMessage = readinessMessage
            return nil
        }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        // `fromCatalog` uses the per-dataset patch size, channel count,
        // I/O names, and intensity preprocessing published by nnU-Net — so
        // a user only has to pick the right model in the dropdown; patch
        // configuration is done for them.
        let spec = NNUnetCoreMLRunner.ModelSpec.fromCatalog(entry, modelURL: url)

        statusMessage = "Running CoreML · patch \(spec.patchSize.d)×\(spec.patchSize.h)×\(spec.patchSize.w) · \(spec.numClasses) classes…"
        do {
            let result = try await coreMLRunner.runInference(
                volume: volume,
                spec: spec,
                classes: entry.classes
            )
            labeling.labelMaps.append(result.labelMap)
            labeling.activeLabelMap = result.labelMap
            if let first = result.labelMap.classes.first {
                labeling.activeClassID = first.labelID
            }
            let elapsed = String(format: "%.1f", result.durationSeconds)
            statusMessage = "✓ CoreML · \(result.patchCount) patches · \(elapsed)s"
            return result.labelMap
        } catch {
            statusMessage = "CoreML error: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - File picker for .mlpackage

    /// Open a macOS file picker and assign the chosen `.mlpackage` directory
    /// to `coreMLModelPath`. Runs on the main thread; safe to call from the UI.
    #if canImport(AppKit)
    public func pickCoreMLModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Pick an .mlpackage (or .mlmodelc) exported from nnU-Net"
        if panel.runModal() == .OK, let url = panel.url {
            coreMLModelPath = url.path
        }
    }
    #endif

    private func applyClassNames(from entry: NNUnetCatalog.Entry, to labelMap: LabelMap) {
        for (idx, cls) in labelMap.classes.enumerated() {
            if let name = entry.classes[cls.labelID] {
                labelMap.classes[idx].name = name
            }
        }
    }
}
