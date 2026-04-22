import SwiftUI

#if os(macOS)

/// The app's Settings window (`⌘,`). Grouped into three tabs that mirror
/// how users think about preferences: shortcuts, engines, appearance.
///
/// Values are persisted via `@AppStorage` so they survive relaunches and
/// can be read from any view that binds the same keys — `ContentView`'s
/// keyboard-shortcut buttons, `MONAILabelViewModel`'s default URL, and so
/// on.
public struct TracerSettingsView: View {

    // Names of the presets bound to ⌘1 … ⌘4. Stored as strings so users
    // can pick any preset available on their modality.
    @AppStorage(TracerSettings.Keys.wlShortcut1) private var wlShortcut1: String = "Lung"
    @AppStorage(TracerSettings.Keys.wlShortcut2) private var wlShortcut2: String = "Bone"
    @AppStorage(TracerSettings.Keys.wlShortcut3) private var wlShortcut3: String = "Brain"

    @AppStorage("focusModeEnabled") private var focusModeEnabled: Bool = false

    // Default backend paths / URLs — pre-populated the first time a user
    // opens MONAI Label / nnU-Net.
    @AppStorage(TracerSettings.Keys.defaultMONAIURL) private var defaultMONAIURL: String = "http://127.0.0.1:8000"
    @AppStorage(TracerSettings.Keys.defaultNNUnetBinary) private var defaultNNUnetBinary: String = ""
    @AppStorage(TracerSettings.Keys.defaultNNUnetResults) private var defaultNNUnetResults: String = ""

    public init() {}

    public var body: some View {
        TabView {
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            enginesTab
                .tabItem { Label("Engines", systemImage: "cpu") }
            DGXSparkSettingsTab()
                .tabItem { Label("DGX Spark", systemImage: "bolt.horizontal.fill") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "sparkles") }
        }
        .frame(width: 620, height: 460)
        .padding(18)
    }

    // MARK: - Shortcuts tab

    private var shortcutsTab: some View {
        Form {
            Section("Window / Level presets") {
                Picker("⌘1", selection: $wlShortcut1) { presetOptions() }
                Picker("⌘2", selection: $wlShortcut2) { presetOptions() }
                Picker("⌘3", selection: $wlShortcut3) { presetOptions() }
                LabeledContent("⌘4", value: "Auto W/L  (histogram-based, not rebindable)")
                    .foregroundColor(.secondary)
            }

            Section("Other shortcuts") {
                LabeledContent("⌘R", value: "Auto W/L")
                LabeledContent("⌘E", value: "Focus Mode (hide side panels)")
                LabeledContent("⌘O", value: "Open DICOM directory")
                LabeledContent("⌘N", value: "Open NIfTI file")
                LabeledContent("⌘.", value: "Close the active engine inspector")
                LabeledContent("⌘⇧A", value: "Focus Assistant Chat tab")
                LabeledContent("⌘⇧M", value: "Open MONAI Label panel")
                LabeledContent("⌘⇧N", value: "Open nnU-Net panel")
                LabeledContent("⌘⇧P", value: "Open PET Engine panel")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func presetOptions() -> some View {
        ForEach(TracerSettings.wlPresetNames, id: \.self) { name in
            Text(name).tag(name)
        }
    }

    // MARK: - Engines tab

    private var enginesTab: some View {
        Form {
            Section("MONAI Label") {
                TextField("Server URL",
                          text: $defaultMONAIURL,
                          prompt: Text("http://127.0.0.1:8000"))
                    .textFieldStyle(.roundedBorder)
                Text("Used as the initial URL when the MONAI Label inspector opens. You can override it per-session in the panel.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Section("nnU-Net v2") {
                TextField("Path to nnUNetv2_predict",
                          text: $defaultNNUnetBinary,
                          prompt: Text("(auto-detect from $PATH)"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                TextField("$nnUNet_results directory",
                          text: $defaultNNUnetResults,
                          prompt: Text("~/nnUNet_results"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                Text("Leave blank to rely on the environment variables / $PATH. Set these if you prefer a specific conda env or an external weights directory.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Appearance tab

    private var appearanceTab: some View {
        Form {
            Section("Layout") {
                Toggle("Launch in Focus Mode (hide side panels)",
                       isOn: $focusModeEnabled)
            }
            Section("Recent volumes") {
                HStack {
                    Text("Clear the Recently-Opened chip strip")
                    Spacer()
                    Button("Clear") { RecentVolumesStore().clear() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Central registry for settings keys + curated preset name list. Lives in
/// its own type so non-settings code can bind to the same `@AppStorage`
/// keys without string drift.
public enum TracerSettings {
    public enum Keys {
        public static let wlShortcut1 = "Tracer.Prefs.WL.Shortcut1"
        public static let wlShortcut2 = "Tracer.Prefs.WL.Shortcut2"
        public static let wlShortcut3 = "Tracer.Prefs.WL.Shortcut3"
        public static let defaultMONAIURL = "Tracer.Prefs.MONAI.DefaultURL"
        public static let defaultNNUnetBinary = "Tracer.Prefs.NNUnet.Binary"
        public static let defaultNNUnetResults = "Tracer.Prefs.NNUnet.Results"
    }

    /// All W/L presets available as rebind targets, built once from the
    /// union of CT + MR + PT presets. De-duplicated and sorted.
    public static let wlPresetNames: [String] = {
        let all = WLPresets.CT + WLPresets.MR + WLPresets.PT
        return Array(Set(all.map(\.name))).sorted()
    }()
}

// MARK: - DGX Spark tab

/// Dedicated settings tab for the user's DGX Spark workstation. Reads and
/// writes `DGXSparkConfig` (persisted under `Tracer.Prefs.DGXSpark`),
/// offers a one-button "Test connection" that runs `uname -a` + probes
/// `nvidia-smi`, and surfaces the remote workdir + optional binary paths.
public struct DGXSparkSettingsTab: View {
    @State private var config: DGXSparkConfig = .load()
    @State private var probeStatus: String = ""
    @State private var probing: Bool = false

    public init() {}

    public var body: some View {
        Form {
            Section("Connection") {
                Toggle("Enable DGX Spark remote execution", isOn: $config.enabled)
                TextField("Host", text: $config.host,
                          prompt: Text("dgx-spark.local or 192.168.1.42"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                HStack {
                    TextField("User", text: $config.user).textFieldStyle(.roundedBorder)
                    Stepper("Port: \(config.port)",
                            value: $config.port,
                            in: 1...65535)
                }
                TextField("Identity file (optional)", text: $config.identityFile,
                          prompt: Text("~/.ssh/id_ed25519"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            Section("Remote paths") {
                TextField("Remote working directory",
                          text: $config.remoteWorkdir,
                          prompt: Text("~/tracer-remote"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                TextField("nnUNetv2_predict path (optional)",
                          text: $config.remoteNNUnetBinary,
                          prompt: Text("(auto-detect from PATH)"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                TextField("llama-cli / llama-mtmd-cli path (optional)",
                          text: $config.remoteLlamaBinary,
                          prompt: Text("(auto-detect from PATH)"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            Section("Remote environment (KEY=VALUE per line)") {
                TextEditor(text: $config.remoteEnvironment)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 80)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                Text("Typical: `nnUNet_results=/home/ahmed/nnUNet_results`, `CUDA_VISIBLE_DEVICES=0`")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Section("Diagnostics") {
                HStack {
                    Button {
                        Task { await probe() }
                    } label: {
                        Label("Test connection", systemImage: "bolt.heart")
                    }
                    .disabled(probing || config.host.isEmpty)
                    if probing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Save") { config.save() }
                        .buttonStyle(.borderedProminent)
                }
                if !probeStatus.isEmpty {
                    Text(probeStatus)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: config) { _, newValue in newValue.save() }
    }

    private func probe() async {
        probing = true
        defer { probing = false }
        config.save()
        let executor = RemoteExecutor(config: config)
        do {
            let out = try executor.probe()
            probeStatus = "✓ " + out.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            probeStatus = "✗ \(error.localizedDescription)"
        }
    }
}

#endif
