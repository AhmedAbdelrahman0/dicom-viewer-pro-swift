import SwiftUI

/// Side panel for interacting with a running **MONAI Label** server.
///
/// Layout — three stacked sections:
///   1. **Connection** — server URL + auth token; connect/disconnect buttons.
///   2. **Inference** — model picker + "Run on current volume" action.
///   3. **Active learning & training** — strategy picker, "Next sample",
///      "Submit label", "Start training", and a tail of training logs.
public struct MONAILabelPanel: View {
    @ObservedObject public var viewer: ViewerViewModel
    @ObservedObject public var monai: MONAILabelViewModel
    @ObservedObject public var labeling: LabelingViewModel

    public init(viewer: ViewerViewModel,
                monai: MONAILabelViewModel,
                labeling: LabelingViewModel) {
        self.viewer = viewer
        self.monai = monai
        self.labeling = labeling
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            connectionSection
            Divider()

            if monai.isConnected {
                inferenceSection
                Divider()
                activeLearningSection
                Divider()
                trainingSection
            } else {
                Text("Connect to a MONAI Label server to run model inference.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()
            Text(monai.statusMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(minWidth: 300)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "brain.head.profile")
                .foregroundColor(.accentColor)
            Text("MONAI Label")
                .font(.headline)
            Spacer()
            Circle()
                .fill(monai.isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            TextField("http://127.0.0.1:8000", text: $monai.serverURL)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            SecureField("Bearer token (optional)", text: $monai.authToken)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(monai.isConnected ? "Reconnect" : "Connect") {
                    Task { await monai.connect() }
                }
                .disabled(monai.isBusy || monai.serverURL.isEmpty)

                if monai.isConnected {
                    Button("Disconnect") { monai.disconnect() }
                        .buttonStyle(.borderless)
                }
                Spacer()
                if monai.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var inferenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inference")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if let models = monai.info?.modelNames, !models.isEmpty {
                Picker("Model", selection: $monai.selectedModel) {
                    ForEach(models, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if let model = monai.info?.models?[monai.selectedModel] {
                    if let description = model.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let labels = model.labels, !labels.isEmpty {
                        Text("Classes: \(labels.keys.sorted().joined(separator: ", "))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }
            } else {
                Text("No models reported by the server.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Button {
                Task {
                    guard let vol = viewer.currentVolume else { return }
                    _ = await monai.runInference(on: vol, in: labeling)
                }
            } label: {
                Label("Run on current volume", systemImage: "play.fill")
            }
            .disabled(monai.isBusy
                      || monai.selectedModel.isEmpty
                      || viewer.currentVolume == nil)
        }
    }

    private var activeLearningSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active learning")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            if let strategies = monai.info?.strategyNames, !strategies.isEmpty {
                Picker("Strategy", selection: $monai.selectedStrategy) {
                    ForEach(strategies, id: \.self) { s in Text(s).tag(s) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            HStack {
                Button("Next sample") {
                    Task {
                        guard !monai.selectedStrategy.isEmpty else { return }
                        do {
                            let sample = try await monai.client.nextSample(
                                strategy: monai.selectedStrategy
                            )
                            monai.statusMessage = "Next: \(sample.id ?? "—") · \(sample.path ?? "")"
                        } catch {
                            monai.statusMessage = "Next sample failed: \(error.localizedDescription)"
                        }
                    }
                }
                .disabled(monai.isBusy || monai.selectedStrategy.isEmpty)

                Spacer()

                Button("Submit label") {
                    Task {
                        guard let map = labeling.activeLabelMap,
                              let vol = viewer.currentVolume else { return }
                        let id = vol.seriesUID.isEmpty
                            ? (vol.sourceFiles.first.map { ($0 as NSString).lastPathComponent } ?? "unknown")
                            : vol.seriesUID
                        await monai.submit(labelMap: map, parentVolume: vol, imageID: id)
                    }
                }
                .disabled(monai.isBusy
                          || labeling.activeLabelMap == nil
                          || viewer.currentVolume == nil)
            }
        }
    }

    private var trainingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Training")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack {
                Button("Train \(monai.selectedModel.isEmpty ? "…" : monai.selectedModel)") {
                    Task { await monai.startTraining(task: monai.selectedModel) }
                }
                .disabled(monai.isBusy || monai.selectedModel.isEmpty)

                Button("Refresh log") {
                    Task { await monai.refreshLogs(task: monai.selectedModel) }
                }
                .disabled(monai.isBusy || monai.selectedModel.isEmpty)
                .buttonStyle(.borderless)
            }
            if !monai.trainingLog.isEmpty {
                ScrollView {
                    Text(monai.trainingLog)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
            }
        }
    }
}
