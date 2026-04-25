import SwiftUI

/// Panel for driving nnU-Net inference on the currently-loaded volume.
///
/// Surfaces two execution paths:
///   • **Python (nnUNetv2)** — shells out to `nnUNetv2_predict` on PATH.
///     Requires a working Python install with `nnunetv2` and model weights
///     downloaded under `$nnUNet_results`.
///   • **CoreML on-device** — runs a pre-converted `.mlpackage` via CoreML.
///     Works fully offline, no Python needed.
///
/// The body-region / modality hint next to each model warns if the user
/// picks a model that doesn't match the loaded volume.
public struct NNUnetPanel: View {
    @ObservedObject public var viewer: ViewerViewModel
    @ObservedObject public var nnunet: NNUnetViewModel
    @ObservedObject public var labeling: LabelingViewModel

    public init(viewer: ViewerViewModel,
                nnunet: NNUnetViewModel,
                labeling: LabelingViewModel) {
        self.viewer = viewer
        self.nnunet = nnunet
        self.labeling = labeling
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            modeSection
            Divider()
            modelSection
            Divider()
            switch nnunet.mode {
            case .subprocess: subprocessOptions
            case .coreML:     coreMLOptions
            case .dgxRemote:  dgxOptions
            }
            Divider()
            actionRow
            Divider()
            logView
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minWidth: 380)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundColor(.accentColor)
            Text("nnU-Net Inference")
                .font(.headline)
            Spacer()
            if nnunet.isRunning {
                ProgressView().controlSize(.small)
                Button("Cancel") { nnunet.cancel() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Execution")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Picker("", selection: $nnunet.mode) {
                ForEach(NNUnetViewModel.Mode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Picker("Model", selection: $nnunet.selectedEntryID) {
                ForEach(NNUnetCatalog.all, id: \.id) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if let entry = nnunet.selectedEntry {
                VStack(alignment: .leading, spacing: 3) {
                    Label("\(entry.modality.displayName) · \(entry.bodyRegion)",
                          systemImage: "stethoscope")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(entry.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.multiChannel {
                        Label("Multi-channel model — single-channel upload may fail.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                    }
                    Text("Classes: \(entry.classes.count > 0 ? entry.classes.values.sorted().joined(separator: ", ") : "—")")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    private var subprocessOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Python backend")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            TextField("nnUNetv2_predict path (leave empty to auto-detect)",
                      text: $nnunet.customBinaryPath)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            TextField("$nnUNet_results directory (optional)",
                      text: $nnunet.resultsDirPath)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            Toggle("Full 5-fold ensemble (≈ 5× slower)",
                   isOn: $nnunet.useFullEnsemble)
            Toggle("Disable test-time augmentation (≈ 8× faster)",
                   isOn: $nnunet.disableTTA)

            let subprocessAvailable = nnunet.isSubprocessAvailable
            HStack(spacing: 6) {
                Circle()
                    .fill(subprocessAvailable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(subprocessAvailable
                     ? "nnUNetv2_predict found"
                     : "nnUNetv2_predict not found — install via `pip install nnunetv2`")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var coreMLOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CoreML backend")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                TextField(".mlpackage path", text: $nnunet.coreMLModelPath)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                #if canImport(AppKit)
                Button("Browse…") { nnunet.pickCoreMLModel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                #endif
            }

            if let entry = nnunet.selectedEntry {
                let p = entry.coreML
                VStack(alignment: .leading, spacing: 2) {
                    Label("Patch \(p.patchSize.d)×\(p.patchSize.h)×\(p.patchSize.w)  ·  \(p.numClasses) classes  ·  overlap \(Int(p.overlap * 100))%",
                          systemImage: "square.grid.3x3")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Label("I/O: \"\(p.inputName)\" → \"\(p.outputName)\"",
                          systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Label("Preprocessing: \(preprocessingSummary(entry.preprocessing))",
                          systemImage: "waveform.path")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Text("Exported from an nnU-Net checkpoint via `torch.onnx.export` → `coremltools.converters.onnx.convert`. The runner applies the dataset's intensity normalization automatically.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dgxOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DGX Spark backend")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            let cfg = nnunet.dgxConfig
            HStack(spacing: 6) {
                Circle()
                    .fill(nnunet.isDGXReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(nnunet.isDGXReady
                     ? "Remote execution on \(cfg.sshDestination):\(cfg.port)"
                     : (nnunet.dgxReadinessMessage ?? "DGX Spark not ready"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Uses the settings from **Settings → DGX Spark** — host, SSH key, remote workdir, and any extra env vars. Each run uploads the NIfTI channels, executes `nnUNetv2_predict`, pulls the predicted label map back, and cleans up the remote directory.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Full 5-fold ensemble (≈ 5× slower)",
                   isOn: $nnunet.useFullEnsemble)
            Toggle("Disable test-time augmentation (≈ 8× faster)",
                   isOn: $nnunet.disableTTA)

            if !cfg.remoteNNUnetBinary.isEmpty {
                Label("Remote binary: \(cfg.remoteNNUnetBinary)",
                      systemImage: "terminal")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if !cfg.remoteEnvironment.isEmpty {
                Label("\(cfg.environmentExports().count) env var(s) exported before run",
                      systemImage: "slider.horizontal.3")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func preprocessingSummary(_ p: NNUnetCatalog.IntensityPreprocessing) -> String {
        switch p {
        case .ctClipAndZScore(let l, let u, let m, let s):
            return String(format: "CT clip [%.0f, %.0f] + Z-score (μ=%.1f, σ=%.1f)", l, u, m, s)
        case .zScoreNonzero: return "Z-score over non-zero voxels"
        case .petSUV(let cap): return String(format: "PET SUV clip (≤%.1f) + Z-score", cap)
        case .identity: return "None"
        }
    }

    private var actionRow: some View {
        HStack {
            Button {
                Task {
                    guard let vol = viewer.currentVolume else {
                        nnunet.statusMessage = "No volume loaded."
                        return
                    }
                    _ = await nnunet.run(on: vol, labeling: labeling)
                }
            } label: {
                Label("Run on current volume", systemImage: "play.fill")
            }
            .disabled(nnunet.isRunning || viewer.currentVolume == nil)

            Spacer()

            if !nnunet.statusMessage.isEmpty {
                Text(nnunet.statusMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !nnunet.log.isEmpty {
                    Button("Clear") { nnunet.log = "" }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            ScrollView {
                Text(nnunet.log.isEmpty ? "—" : nnunet.log)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(nnunet.log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
            )
        }
    }
}
