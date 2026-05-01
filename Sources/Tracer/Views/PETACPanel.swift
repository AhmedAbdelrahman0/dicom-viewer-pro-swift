import SwiftUI

/// Panel for producing an attenuation-corrected PET from a non-attenuation-
/// corrected PET via a deep model (subprocess or DGX). Sits in the AI
/// Engines menu as ⌘⇧K.
///
/// Workflow:
///   1. Pick an entry from `PETACCatalog`
///   2. Point at the model's Python script (and DGX activation, if remote)
///   3. Optional: pick a co-registered CT/MR for MR-AC entries
///   4. Run — the AC volume opens as a new entry in the volume browser
///      and (if there was a CT/PET fusion) becomes the new overlay.
public struct PETACPanel: View {
    @ObservedObject public var viewer: ViewerViewModel
    @ObservedObject public var ac: PETACViewModel

    public init(viewer: ViewerViewModel, ac: PETACViewModel) {
        self.viewer = viewer
        self.ac = ac
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
            logView
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 460)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "wand.and.rays")
                .foregroundColor(.accentColor)
            Text("PET Attenuation Correction")
                .font(.headline)
            Spacer()
            if ac.isRunning {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var entryPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Method")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Picker("Method", selection: $ac.selectedEntryID) {
                ForEach(PETACCatalog.all) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if let entry = ac.selectedEntry {
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
                        Label("Needs a co-registered CT or MR on the PET grid",
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
        if let entry = ac.selectedEntry {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.backend == .dgxRemote
                     ? "Remote script path on DGX"
                     : "Local Python script")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                HStack {
                    TextField(entry.backend == .dgxRemote
                              ? "~/scripts/deep_ac.py"
                              : "path/to/deep_ac.py",
                              text: $ac.scriptPath)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                    #if canImport(AppKit)
                    if entry.backend == .subprocess {
                        Button("Browse…") { ac.pickScriptPath() }
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
                              text: $ac.pythonExecutablePath)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                Text(entry.backend == .dgxRemote
                     ? "Environment / activation (first `activate=…` line is run before the script)"
                     : "Environment overrides (KEY=VALUE per line)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                TextEditor(text: $ac.environment)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3)))

                Text("Extra script arguments (optional, space-separated)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                TextField("--device cuda:0 --batch 1", text: $ac.extraArgs)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)

                HStack {
                    Toggle("Use anatomical channel (resampled CT/MR)",
                           isOn: $ac.useAnatomicalChannel)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(entry.requiresAnatomicalChannel)
                        .help(entry.requiresAnatomicalChannel
                              ? "This model requires an anatomical channel; toggle is forced on."
                              : "Optional. Provide if your model accepts a CT or MR auxiliary input.")
                    Spacer()
                    Stepper("Timeout: \(Int(ac.timeoutSeconds))s",
                            value: $ac.timeoutSeconds,
                            in: 30...3600,
                            step: 30)
                        .controlSize(.small)
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
                Label("Run AC on current PET", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(ac.isRunning || !canRun)

            Spacer()

            if !ac.statusMessage.isEmpty {
                Text(ac.statusMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canRun: Bool {
        currentPETVolume != nil && ac.entryReadinessMessage == nil
    }

    private var currentPETVolume: ImageVolume? {
        // Prefer the active overlay PET (the one that's actually being read
        // in fusion view); fall back to a loaded PET volume; finally the
        // current displayed volume if it's PET.
        if let pair = viewer.fusion,
           Modality.normalize(pair.overlayVolume.modality) == .PT {
            return pair.overlayVolume
        }
        if let pet = viewer.activeSessionVolumes.first(where: { Modality.normalize($0.modality) == .PT }) {
            return pet
        }
        if let cur = viewer.currentVolume,
           Modality.normalize(cur.modality) == .PT {
            return cur
        }
        return nil
    }

    private var anatomicalCandidate: ImageVolume? {
        // Prefer the fusion's base CT; otherwise any loaded CT/MR.
        if let pair = viewer.fusion,
           Modality.normalize(pair.baseVolume.modality) != .PT {
            return pair.baseVolume
        }
        return viewer.activeSessionVolumes.first {
            let m = Modality.normalize($0.modality)
            return m == .CT || m == .MR
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !ac.log.isEmpty {
                    Button("Clear") { ac.log = "" }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            ScrollView {
                Text(ac.log.isEmpty ? "—" : ac.log)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(ac.log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            .background(RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
        }
    }

    private func runFromPanel() {
        guard let pet = currentPETVolume else {
            ac.statusMessage = "Load a PET volume before running AC."
            return
        }
        let anatomical = ac.useAnatomicalChannel ? anatomicalCandidate : nil
        Task {
            _ = await ac.run(nacPET: pet, anatomical: anatomical, viewer: viewer)
        }
    }
}
