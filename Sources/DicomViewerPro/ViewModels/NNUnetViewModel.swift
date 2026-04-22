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
    @discardableResult
    public func run(on volume: ImageVolume,
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
        if entry.multiChannel {
            statusMessage = "Model \(entry.datasetID) expects multiple input channels. Multi-series channel selection is not wired yet."
            return nil
        }

        isRunning = true
        log = ""
        defer { isRunning = false }

        let start = Date()
        switch mode {
        case .subprocess:
            return await runSubprocess(entry: entry, volume: volume, labeling: labeling, start: start)
        case .coreML:
            return await runCoreML(entry: entry, volume: volume, labeling: labeling, start: start)
        }
    }

    private func runSubprocess(entry: NNUnetCatalog.Entry,
                               volume: ImageVolume,
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

        statusMessage = "Running \(entry.datasetID)…"
        do {
            let result = try await subprocessRunner.runInference(
                volume: volume,
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
        let trimmed = coreMLModelPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            statusMessage = "Point the CoreML path at a .mlpackage first."
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
