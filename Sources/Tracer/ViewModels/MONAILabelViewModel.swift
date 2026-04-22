import Foundation
import SwiftUI

/// State and workflow glue for MONAI Label integration.
///
/// Owns a `MONAILabelClient`, a published snapshot of the server's `info`
/// response, and async actions that write temporary NIfTI files for upload
/// and read returned segmentation masks back into `LabelMap` objects.
@MainActor
public final class MONAILabelViewModel: ObservableObject {

    // MARK: - Published state

    @Published public var serverURL: String = "http://127.0.0.1:8000"
    @Published public var authToken: String = ""
    @Published public private(set) var info: ServerInfo?
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isBusy: Bool = false
    @Published public var statusMessage: String = "Not connected."
    @Published public var selectedModel: String = ""
    @Published public var selectedStrategy: String = ""
    @Published public private(set) var lastInferenceLabelID: UInt16?
    @Published public private(set) var trainingTasks: [String] = []
    @Published public private(set) var trainingLog: String = ""

    // MARK: - Underlying client

    public private(set) var client: MONAILabelClient

    public init(client: MONAILabelClient = MONAILabelClient()) {
        self.client = client
        // Pull the Settings-configured default URL when present. Keeps the
        // hardcoded localhost fallback for first-run users who haven't
        // touched preferences yet.
        if let stored = UserDefaults.standard.string(
            forKey: "Tracer.Prefs.MONAI.DefaultURL"
        ), !stored.isEmpty {
            self.serverURL = stored
        }
    }

    // MARK: - Connection

    /// Point the client at the current `serverURL` / `authToken` and
    /// refresh the server info cache.
    public func connect() async {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)) else {
            statusMessage = "Invalid server URL."
            return
        }
        let cfg = MONAILabelClient.Configuration(
            baseURL: url,
            authToken: authToken.isEmpty ? nil : authToken
        )
        client.update(configuration: cfg)

        isBusy = true
        statusMessage = "Connecting to \(url.absoluteString)…"
        defer { isBusy = false }

        do {
            let fetched = try await client.fetchInfo()
            info = fetched
            isConnected = true
            if selectedModel.isEmpty, let first = fetched.modelNames.first {
                selectedModel = first
            }
            if selectedStrategy.isEmpty, let firstS = fetched.strategyNames.first {
                selectedStrategy = firstS
            }
            statusMessage = "Connected: \(fetched.name ?? "MONAI Label") · \(fetched.modelNames.count) models"
        } catch {
            isConnected = false
            info = nil
            statusMessage = "Connection failed: \(error.localizedDescription)"
        }
    }

    public func disconnect() {
        isConnected = false
        info = nil
        statusMessage = "Disconnected."
    }

    @discardableResult
    public func selectBestModel(for plan: SegmentationRAGPlan) -> String? {
        guard isConnected, let models = info?.modelNames, !models.isEmpty else {
            return nil
        }
        guard let match = SegmentationRAG.bestAvailableMONAIModel(for: plan, availableModels: models) else {
            return nil
        }
        selectedModel = match
        statusMessage = "Segmentation RAG selected MONAI model \(match) for \(plan.labelName)."
        return match
    }

    // MARK: - Inference

    /// Upload `volume` to the MONAI Label server, run inference with the
    /// currently selected model, and install the returned segmentation into
    /// `labeling` as a new active `LabelMap`.
    @discardableResult
    public func runInference(on volume: ImageVolume,
                             in labeling: LabelingViewModel) async -> LabelMap? {
        guard isConnected else {
            statusMessage = "Not connected to a MONAI Label server."
            return nil
        }
        guard !selectedModel.isEmpty else {
            statusMessage = "Pick a model first."
            return nil
        }

        isBusy = true
        statusMessage = "Preparing \(selectedModel)…"
        defer { isBusy = false }

        let tmpDir = FileManager.default.temporaryDirectory
        let imageURL = tmpDir.appendingPathComponent("monai-in-\(UUID().uuidString).nii")
        let labelURL = tmpDir.appendingPathComponent("monai-out-\(UUID().uuidString).nii")
        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: labelURL)
        }

        do {
            try NIfTIWriter.write(volume, to: imageURL)
            statusMessage = "Uploading \(volume.seriesDescription.isEmpty ? "volume" : volume.seriesDescription) to MONAI Label…"

            let params = try await client.runInference(
                model: selectedModel,
                imageURL: imageURL,
                outputLabelURL: labelURL
            )

            statusMessage = "Loading inference result…"
            let labelMap = try LabelIO.loadNIfTILabelmap(from: labelURL, parentVolume: volume)
            labelMap.name = "MONAI · \(selectedModel)"

            // If MONAI returned label names, rename classes to match.
            if let labelNames = params.labels {
                for (name, id) in labelNames {
                    let idU = UInt16(clamping: id)
                    if let idx = labelMap.classes.firstIndex(where: { $0.labelID == idU }) {
                        labelMap.classes[idx].name = name
                    }
                }
            }

            labeling.labelMaps.append(labelMap)
            labeling.activeLabelMap = labelMap
            if let first = labelMap.classes.first {
                lastInferenceLabelID = first.labelID
                labeling.activeClassID = first.labelID
            }
            statusMessage = "MONAI Label: \(labelMap.classes.count) classes produced by \(selectedModel)."
            return labelMap
        } catch {
            statusMessage = "Inference failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Submit a labeled volume back to the datastore

    public func submit(labelMap: LabelMap,
                       parentVolume: ImageVolume,
                       imageID: String) async {
        guard isConnected else {
            statusMessage = "Not connected."
            return
        }
        isBusy = true
        defer { isBusy = false }

        let labelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monai-final-\(UUID().uuidString).nii")
        defer { try? FileManager.default.removeItem(at: labelURL) }

        do {
            try LabelIO.saveNIfTI(labelMap,
                                  to: labelURL,
                                  parentVolume: parentVolume,
                                  writeLabelDescriptor: false)
            try await client.submitLabel(imageID: imageID, labelURL: labelURL)
            statusMessage = "Submitted label for \(imageID)."
        } catch {
            statusMessage = "Submit failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Training

    public func startTraining(task: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.startTraining(task: task)
            if !trainingTasks.contains(task) { trainingTasks.append(task) }
            statusMessage = "Training task \(task) started."
        } catch {
            statusMessage = "Train start failed: \(error.localizedDescription)"
        }
    }

    public func refreshLogs(task: String) async {
        do {
            trainingLog = try await client.logs(task: task)
        } catch {
            trainingLog = "Error: \(error.localizedDescription)"
        }
    }
}
