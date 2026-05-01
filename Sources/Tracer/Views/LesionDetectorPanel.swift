import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Panel for running lesion detection — picks a catalog entry, configures
/// the wrapper script, runs detection, shows the per-detection table with
/// click-to-jump-to-slice navigation. Sits in the AI Engines menu as ⌘⇧D.
///
/// Detection results are kept in `LesionDetectorViewModel.lastDetections`;
/// closing the panel doesn't lose them. The user can switch to another
/// engine inspector and come back without re-running.
public struct LesionDetectorPanel: View {
    @ObservedObject public var viewer: ViewerViewModel
    @ObservedObject public var detector: LesionDetectorViewModel

    public init(viewer: ViewerViewModel, detector: LesionDetectorViewModel) {
        self.viewer = viewer
        self.detector = detector
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            entryPicker
            Divider()
            backendConfig
            Divider()
            actionRow
            Divider()
            resultsSection
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 480)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "viewfinder.circle")
                .foregroundColor(.accentColor)
            Text("Lesion Detection")
                .font(.headline)
            Spacer()
            if detector.isRunning {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var entryPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Detector")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Picker("Detector", selection: $detector.selectedEntryID) {
                ForEach(LesionDetectorCatalog.all) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if let entry = detector.selectedEntry {
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
                    if entry.requiresAnatomicalChannel {
                        Label("Needs a co-registered CT or MR on the primary's grid",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var backendConfig: some View {
        if let entry = detector.selectedEntry {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.backend == .dgxRemote
                     ? "Remote script path on DGX"
                     : "Local Python script")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                HStack {
                    TextField(entry.backend == .dgxRemote
                              ? "~/scripts/detect.py"
                              : "path/to/detect.py",
                              text: $detector.scriptPath)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                    #if canImport(AppKit)
                    if entry.backend == .subprocess {
                        Button("Browse…") { detector.pickScriptPath() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    #endif
                }

                if entry.backend == .subprocess {
                    Text("Python interpreter")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextField("/usr/bin/env (default) or full path to python3",
                              text: $detector.pythonExecutablePath)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                Text(entry.backend == .dgxRemote
                     ? "Environment / activation (first `activate=…` line is run before the script)"
                     : "Environment overrides (KEY=VALUE per line)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                TextEditor(text: $detector.environment)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3)))

                Text("Extra script arguments (optional)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                TextField("--device cuda:0", text: $detector.extraArgs)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)

                HStack {
                    Toggle("Use anatomical channel (resampled CT/MR)",
                           isOn: $detector.useAnatomicalChannel)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(entry.requiresAnatomicalChannel)
                    Spacer()
                    Stepper("Timeout: \(Int(detector.timeoutSeconds))s",
                            value: $detector.timeoutSeconds,
                            in: 30...3600,
                            step: 30)
                        .controlSize(.small)
                }

                HStack {
                    Text("Min confidence")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Slider(value: $detector.minConfidence, in: 0...1)
                    Text(String(format: "%.2f", detector.minConfidence))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }

                if entry.backend == .dgxRemote {
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
    }

    private var actionRow: some View {
        HStack {
            Button {
                runFromPanel()
            } label: {
                Label("Detect on current volume", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(detector.isRunning || !canRun)

            #if canImport(AppKit)
            Button {
                exportJSON()
            } label: {
                Label("Export JSON", systemImage: "square.and.arrow.up")
            }
            .disabled(detector.lastDetections.isEmpty)
            #endif

            Button {
                detector.clearResults()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(detector.lastDetections.isEmpty)

            Spacer()

            if !detector.statusMessage.isEmpty {
                Text(detector.statusMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
    }

    private var canRun: Bool {
        viewer.currentVolume != nil && detector.entryReadinessMessage == nil
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Detections")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(detector.visibleDetections.count) shown" +
                     (detector.minConfidence > 0
                      ? " (≥\(String(format: "%.2f", detector.minConfidence)) conf)"
                      : ""))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if detector.lastDetections.isEmpty {
                Text("Run detection to populate this list. Click a row to jump to its slice.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                detectionsTable
            }
        }
    }

    private var detectionsTable: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(detector.visibleDetections.enumerated()),
                        id: \.element.id) { index, det in
                    detectionRow(index: index + 1, detection: det)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 220)
    }

    private func detectionRow(index: Int, detection: LesionDetection) -> some View {
        Button {
            jumpToDetection(detection)
        } label: {
            HStack(spacing: 6) {
                Text("#\(index)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(detection.topLabel ?? "—")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let region = detection.anatomicalRegion {
                            Text(region)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        Text(boxSummary(detection))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if let rationale = detection.rationale, !rationale.isEmpty {
                        Text(rationale)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.0f%%", detection.topProbability * 100))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text(String(format: "conf %.2f", detection.detectionConfidence))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func boxSummary(_ d: LesionDetection) -> String {
        let dz = d.bounds.maxZ - d.bounds.minZ + 1
        let dy = d.bounds.maxY - d.bounds.minY + 1
        let dx = d.bounds.maxX - d.bounds.minX + 1
        let center = d.centerVoxel
        return "(\(center.x),\(center.y),\(center.z))  \(dx)×\(dy)×\(dz)"
    }

    private func jumpToDetection(_ d: LesionDetection) {
        guard viewer.currentVolume != nil else { return }
        let center = d.centerVoxel
        // Center all three orthogonal slices on the detection so the
        // user immediately sees it in axial / sagittal / coronal panes.
        viewer.setSlice(axis: 0, index: center.x)
        viewer.setSlice(axis: 1, index: center.y)
        viewer.setSlice(axis: 2, index: center.z)
        viewer.statusMessage = "Jumped to detection center (\(center.x), \(center.y), \(center.z))"
    }

    // MARK: - Actions

    private func runFromPanel() {
        guard let vol = viewer.currentVolume else {
            detector.statusMessage = "Load a volume before running detection."
            return
        }
        let anatomical: ImageVolume? = {
            guard detector.useAnatomicalChannel
                  || (detector.selectedEntry?.requiresAnatomicalChannel ?? false) else {
                return nil
            }
            // Prefer the fusion's base when present; else any loaded
            // CT/MR that's NOT the primary itself.
            if let pair = viewer.fusion,
               pair.baseVolume.id != vol.id {
                return pair.baseVolume
            }
            return viewer.activeSessionVolumes.first {
                $0.id != vol.id
                && (Modality.normalize($0.modality) == .CT
                    || Modality.normalize($0.modality) == .MR)
            }
        }()
        Task {
            _ = await detector.run(volume: vol, anatomical: anatomical)
        }
    }

    #if canImport(AppKit)
    private func exportJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "detections-\(detector.selectedEntry?.id ?? "tracer").json"
        panel.canCreateDirectories = true
        panel.message = "Export current detection set as JSON"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try detector.exportJSON(to: url)
                detector.statusMessage = "Exported → \(url.lastPathComponent)"
            } catch {
                detector.statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }
    #else
    private func exportJSON() { /* iPad stub */ }
    #endif
}
