import SwiftUI

/// Standalone panel for running per-lesion classification. Users pick a
/// classifier from the catalog, configure paths, and press "Classify active
/// lesions" to enumerate connected components of the current label map
/// and run the classifier across them.
public struct ClassificationPanel: View {
    @ObservedObject public var viewer: ViewerViewModel
    @ObservedObject public var classifier: ClassificationViewModel
    @ObservedObject public var labeling: LabelingViewModel

    public init(viewer: ViewerViewModel,
                classifier: ClassificationViewModel,
                labeling: LabelingViewModel) {
        self.viewer = viewer
        self.classifier = classifier
        self.labeling = labeling
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            classifierPicker
            Divider()
            backendConfigSection
            Divider()
            runRow
            if !classifier.lastResults.isEmpty {
                Divider()
                resultsTable
            }
            Spacer()
            statusLine
        }
        .padding(14)
        .frame(minWidth: 460)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "square.stack.3d.forward.dottedline")
                .foregroundColor(.accentColor)
            Text("Lesion Classification")
                .font(.headline)
            Spacer()
            if classifier.isRunning {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var classifierPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Classifier")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Picker("Classifier", selection: $classifier.selectedEntryID) {
                ForEach(LesionClassifierCatalog.all) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if let entry = classifier.selectedEntry {
                VStack(alignment: .leading, spacing: 3) {
                    Label(entry.backend.displayName, systemImage: "cpu")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(entry.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !entry.license.isEmpty {
                        Label(entry.license, systemImage: "doc.text")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    if entry.requiresConfiguration {
                        Label("Configuration required below",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var backendConfigSection: some View {
        if let entry = classifier.selectedEntry {
            switch entry.backend {
            case .radiomicsTree:      radiomicsConfig
            case .coreML:             coreMLConfig
            case .medSigLIPZeroShot:  zeroShotConfig
            case .subprocess:         subprocessConfig
            case .medGemma:           medGemmaConfig
            }
        }
    }

    private var radiomicsConfig: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tree model JSON (optional)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack {
                TextField("path/to/model.json", text: $classifier.customModelPath)
                    .textFieldStyle(.roundedBorder)
                #if canImport(AppKit)
                Button("Browse…") { classifier.pickModelPath() }
                    .buttonStyle(.bordered).controlSize(.small)
                #endif
            }
            Text("Leave blank to use the built-in placeholder model — useful for exercising the pipeline without real weights.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private var coreMLConfig: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(".mlpackage / .mlmodelc path")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack {
                TextField("path/to/classifier.mlpackage", text: $classifier.customModelPath)
                    .textFieldStyle(.roundedBorder)
                #if canImport(AppKit)
                Button("Browse…") { classifier.pickModelPath() }
                    .buttonStyle(.bordered).controlSize(.small)
                #endif
            }
        }
    }

    private var zeroShotConfig: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Encoders (image, text — comma-separated)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            TextField("image-encoder.mlpackage,text-encoder.mlpackage",
                      text: $classifier.customModelPath)
                .textFieldStyle(.roundedBorder)

            Text("Class labels (one per line)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.top, 4)
            TextEditor(text: $classifier.zeroShotPromptLabels)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 60)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

            Text("Text prompts (one per line, same order as labels)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.top, 4)
            TextEditor(text: $classifier.zeroShotPrompts)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        }
    }

    private var subprocessConfig: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Run on DGX Spark (remote Python)", isOn: $classifier.runOnDGX)
                .toggleStyle(.switch)
                .help("Upload the VOI + mask to the DGX, run the Python script there, and pull the JSON result back. Honours Settings → DGX Spark.")

            Text(classifier.runOnDGX
                 ? "Remote script path on DGX"
                 : "Python script")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack {
                TextField(classifier.runOnDGX
                          ? "~/scripts/classify_lesion.py"
                          : "path/to/classifier_cli.py",
                          text: $classifier.customBinaryPath)
                    .textFieldStyle(.roundedBorder)
                #if canImport(AppKit)
                if !classifier.runOnDGX {
                    Button("Browse…") { classifier.pickBinaryPath() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                #endif
            }
            Text(classifier.runOnDGX
                 ? "Environment / activation (first `activate=…` line is run before the script)"
                 : "Environment overrides (KEY=VALUE, one per line)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            TextEditor(text: $classifier.customEnvironment)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 60)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

            if classifier.runOnDGX {
                let cfg = DGXSparkConfig.load()
                HStack(spacing: 6) {
                    Circle()
                        .fill(cfg.isConfigured && cfg.enabled ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(cfg.isConfigured && cfg.enabled
                         ? "Connected to \(cfg.sshDestination):\(cfg.port)"
                         : "Configure Settings → DGX Spark first")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var medGemmaConfig: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("llama-cli binary")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack {
                TextField("path/to/llama-mtmd-cli", text: $classifier.customBinaryPath)
                    .textFieldStyle(.roundedBorder)
                #if canImport(AppKit)
                Button("Browse…") { classifier.pickBinaryPath() }
                    .buttonStyle(.bordered).controlSize(.small)
                #endif
            }
            Text("GGUF model")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack {
                TextField("path/to/medgemma-4b-it-Q4_K_M.gguf",
                          text: $classifier.customModelPath)
                    .textFieldStyle(.roundedBorder)
                #if canImport(AppKit)
                Button("Browse…") { classifier.pickModelPath() }
                    .buttonStyle(.bordered).controlSize(.small)
                #endif
            }
            Text("Vision projector (mmproj) — optional for text-only models")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            TextField("path/to/mmproj-medgemma.gguf",
                      text: $classifier.customProjectorPath)
                .textFieldStyle(.roundedBorder)

            Text("Candidate labels (one per line)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            TextEditor(text: $classifier.candidateLabels)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 60)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        }
    }

    // MARK: - Run

    private var runRow: some View {
        HStack {
            Button {
                Task {
                    guard let volume = viewer.currentVolume,
                          let map = labeling.activeLabelMap else {
                        classifier.statusMessage = "Load a volume + label map first."
                        return
                    }
                    let classID = labeling.activeClassID == 0
                        ? (map.classes.first?.labelID ?? 1)
                        : labeling.activeClassID
                    _ = await classifier.classifyAll(
                        volume: volume,
                        labelMap: map,
                        classID: classID
                    )
                }
            } label: {
                Label("Classify active lesions", systemImage: "play.fill")
            }
            .disabled(classifier.isRunning
                      || viewer.currentVolume == nil
                      || labeling.activeLabelMap == nil)

            Spacer()

            if !classifier.lastResults.isEmpty {
                ShareReportMenu(results: classifier.lastResults)
            }
        }
    }

    // MARK: - Results

    private var resultsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Results")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(classifier.lastResults) { row in
                        resultRow(row)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private func resultRow(_ row: ClassificationViewModel.LesionResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.lesion.className)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(String(format: "%.1f mL · SUVmax %.2f",
                            row.lesion.volumeML, row.lesion.suvMax))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            HStack {
                Text(row.result.topLabel ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(String(format: "%.0f%%", row.result.topProbability * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("by \(row.result.classifierID)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            if let rationale = row.result.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLine: some View {
        Text(classifier.statusMessage)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Inline menu that exports the current batch of classification results to
/// JSON or CSV. Rendered in the run row only when results exist.
private struct ShareReportMenu: View {
    let results: [ClassificationViewModel.LesionResult]

    var body: some View {
        Menu {
            Button("Export JSON…") { export(.json) }
            Button("Export CSV…")  { export(.csv) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private enum Format { case json, csv }

    private func export(_ format: Format) {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "lesion-classification.\(format == .json ? "json" : "csv")"
        panel.allowedContentTypes = [format == .json ? .json : .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            switch format {
            case .json:
                data = try ClassificationReport.jsonData(for: results)
            case .csv:
                data = ClassificationReport.csvData(for: results)
            }
            try data.write(to: url)
        } catch {
            NSLog("Classification export failed: \(error)")
        }
        #endif
    }
}

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif
