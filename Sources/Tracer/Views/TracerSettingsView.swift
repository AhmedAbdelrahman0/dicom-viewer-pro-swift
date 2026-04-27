import Foundation
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
    @AppStorage(TracerSettings.Keys.resourceProfile) private var resourceProfileRaw: String = ResourcePolicy.Profile.balanced.rawValue
    @AppStorage(TracerSettings.Keys.resourceCPULimit) private var cpuWorkerLimit: Int = ResourcePolicy.balancedPreset.cpuWorkerLimit
    @AppStorage(TracerSettings.Keys.resourceIndexingLimit) private var indexingWorkerLimit: Int = ResourcePolicy.balancedPreset.indexingWorkerLimit
    @AppStorage(TracerSettings.Keys.resourceCohortLimit) private var cohortWorkerLimit: Int = ResourcePolicy.balancedPreset.cohortWorkerLimit
    @AppStorage(TracerSettings.Keys.resourceGPULimit) private var gpuWorkerLimit: Int = ResourcePolicy.balancedPreset.gpuWorkerLimit
    @AppStorage(TracerSettings.Keys.resourceMIPLimit) private var mipWorkerLimit: Int = ResourcePolicy.balancedPreset.mipWorkerLimit
    @AppStorage(TracerSettings.Keys.resourceMemoryBudgetGB) private var memoryBudgetGB: Double = ResourcePolicy.balancedPreset.memoryBudgetGB
    @AppStorage(TracerSettings.Keys.resourceUndoBudgetMB) private var undoHistoryBudgetMB: Int = ResourcePolicy.balancedPreset.undoHistoryBudgetMB
    @AppStorage(TracerSettings.Keys.resourceSliceCacheEntries) private var sliceCacheEntries: Int = ResourcePolicy.balancedPreset.sliceCacheEntries
    @AppStorage(TracerSettings.Keys.resourcePETMIPCacheEntries) private var petMIPCacheEntries: Int = ResourcePolicy.balancedPreset.petMIPCacheEntries
    @AppStorage(TracerSettings.Keys.resourceVolumeTextureMaxDimension) private var volumeRenderTextureMaxDimension: Int = ResourcePolicy.balancedPreset.volumeRenderTextureMaxDimension
    @AppStorage(TracerSettings.Keys.resourceVolumeSampleLimit) private var volumeRenderSampleLimit: Int = ResourcePolicy.balancedPreset.volumeRenderSampleLimit
    @AppStorage(TracerSettings.Keys.resourceResponsivePriority) private var preferResponsiveBackgroundPriority: Bool = ResourcePolicy.balancedPreset.preferResponsiveBackgroundPriority

    public init() {}

    public var body: some View {
        TabView {
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            enginesTab
                .tabItem { Label("Engines", systemImage: "cpu") }
            performanceTab
                .tabItem { Label("Performance", systemImage: "gauge.with.dots.needle.bottom.50percent") }
            DGXSparkSettingsTab()
                .tabItem { Label("DGX Spark", systemImage: "bolt.horizontal.fill") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "sparkles") }
        }
        .frame(width: 680, height: 560)
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

    // MARK: - Performance tab

    private var performanceTab: some View {
        let snapshot = ResourceSystemSnapshot.current()
        let policy = ResourcePolicy.load()
        return Form {
            Section("Resource policy") {
                Picker("Profile", selection: Binding(
                    get: { resourceProfileRaw },
                    set: { raw in
                        let profile = ResourcePolicy.Profile(rawValue: raw) ?? .balanced
                        applyResourceProfile(profile)
                    }
                )) {
                    ForEach(ResourcePolicy.Profile.allCases) { profile in
                        Text(profile.displayName).tag(profile.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text((ResourcePolicy.Profile(rawValue: resourceProfileRaw) ?? .balanced).description)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("CPU")
                        Text("\(snapshot.activeProcessorCount) active / \(snapshot.processorCount) logical")
                            .foregroundColor(.secondary)
                    }
                    GridRow {
                        Text("Memory")
                        Text(byteString(snapshot.physicalMemoryBytes))
                            .foregroundColor(.secondary)
                    }
                    GridRow {
                        Text("GPU")
                        Text(snapshot.gpuName ?? "Unavailable")
                            .foregroundColor(.secondary)
                    }
                    if let workingSet = snapshot.gpuRecommendedWorkingSetBytes {
                        GridRow {
                            Text("GPU working set")
                            Text(byteString(workingSet))
                                .foregroundColor(.secondary)
                        }
                    }
                    GridRow {
                        Text("Thermal")
                        Text(snapshot.thermalStateDescription + (snapshot.lowPowerModeEnabled ? " · Low Power" : ""))
                            .foregroundColor(.secondary)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }

            Section("CPU and batch work") {
                Stepper("CPU threads per local worker: \(cpuWorkerLimit)",
                        value: Binding(
                            get: { cpuWorkerLimit },
                            set: { cpuWorkerLimit = $0; markResourceCustom() }
                        ),
                        in: 1...max(1, ResourcePolicy.processorCount))
                Stepper("PACS indexing workers: \(indexingWorkerLimit)",
                        value: Binding(
                            get: { indexingWorkerLimit },
                            set: { indexingWorkerLimit = $0; markResourceCustom() }
                        ),
                        in: 1...32)
                Stepper("Cohort workers: \(cohortWorkerLimit)",
                        value: Binding(
                            get: { cohortWorkerLimit },
                            set: { cohortWorkerLimit = $0; markResourceCustom() }
                        ),
                        in: 1...32)
                Toggle("Keep background jobs at responsive priority",
                       isOn: Binding(
                           get: { preferResponsiveBackgroundPriority },
                           set: { preferResponsiveBackgroundPriority = $0; markResourceCustom() }
                       ))
                Text("Python/ANTs/nnU-Net subprocesses receive BLAS/OpenMP thread caps from this policy unless the model-specific environment overrides them.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Section("GPU and 3D rendering") {
                Stepper("GPU-heavy jobs at once: \(gpuWorkerLimit)",
                        value: Binding(
                            get: { gpuWorkerLimit },
                            set: { gpuWorkerLimit = $0; markResourceCustom() }
                        ),
                        in: 1...8)
                Stepper("PET MIP projections at once: \(mipWorkerLimit)",
                        value: Binding(
                            get: { mipWorkerLimit },
                            set: { mipWorkerLimit = $0; markResourceCustom() }
                        ),
                        in: 1...8)
                Stepper("3D texture max dimension: \(volumeRenderTextureMaxDimension)",
                        value: Binding(
                            get: { volumeRenderTextureMaxDimension },
                            set: { volumeRenderTextureMaxDimension = $0; markResourceCustom() }
                        ),
                        in: 96...1024,
                        step: 32)
                Stepper("3D ray samples: \(volumeRenderSampleLimit)",
                        value: Binding(
                            get: { volumeRenderSampleLimit },
                            set: { volumeRenderSampleLimit = $0; markResourceCustom() }
                        ),
                        in: 64...1024,
                        step: 32)
                Text("Effective 3D budget: \(policy.volumeRenderTextureMaxDimension)³ texture cap, \(policy.volumeRenderSampleLimit) samples.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Section("Memory and caches") {
                Stepper("App memory budget: \(String(format: "%.1f", memoryBudgetGB)) GB",
                        value: Binding(
                            get: { memoryBudgetGB },
                            set: { memoryBudgetGB = $0; markResourceCustom() }
                        ),
                        in: 1...max(2, ResourcePolicy.physicalMemoryGB),
                        step: 0.5)
                Stepper("Undo history: \(undoHistoryBudgetMB) MB",
                        value: Binding(
                            get: { undoHistoryBudgetMB },
                            set: { undoHistoryBudgetMB = $0; markResourceCustom() }
                        ),
                        in: 64...4096,
                        step: 64)
                Stepper("Slice cache entries: \(sliceCacheEntries)",
                        value: Binding(
                            get: { sliceCacheEntries },
                            set: { sliceCacheEntries = $0; markResourceCustom() }
                        ),
                        in: 12...512)
                Stepper("PET MIP cache entries: \(petMIPCacheEntries)",
                        value: Binding(
                            get: { petMIPCacheEntries },
                            set: { petMIPCacheEntries = $0; markResourceCustom() }
                        ),
                        in: 2...64)
                HStack {
                    Spacer()
                    Button("Reset Balanced") { applyResourceProfile(.balanced) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if resourceProfileRaw != ResourcePolicy.Profile.custom.rawValue,
               let profile = ResourcePolicy.Profile(rawValue: resourceProfileRaw) {
                applyResourceProfile(profile)
            }
        }
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
        public static let resourceProfile = ResourcePolicy.Keys.profile
        public static let resourceCPULimit = ResourcePolicy.Keys.cpuWorkerLimit
        public static let resourceIndexingLimit = ResourcePolicy.Keys.indexingWorkerLimit
        public static let resourceCohortLimit = ResourcePolicy.Keys.cohortWorkerLimit
        public static let resourceGPULimit = ResourcePolicy.Keys.gpuWorkerLimit
        public static let resourceMIPLimit = ResourcePolicy.Keys.mipWorkerLimit
        public static let resourceMemoryBudgetGB = ResourcePolicy.Keys.memoryBudgetGB
        public static let resourceUndoBudgetMB = ResourcePolicy.Keys.undoHistoryBudgetMB
        public static let resourceSliceCacheEntries = ResourcePolicy.Keys.sliceCacheEntries
        public static let resourcePETMIPCacheEntries = ResourcePolicy.Keys.petMIPCacheEntries
        public static let resourceVolumeTextureMaxDimension = ResourcePolicy.Keys.volumeRenderTextureMaxDimension
        public static let resourceVolumeSampleLimit = ResourcePolicy.Keys.volumeRenderSampleLimit
        public static let resourceResponsivePriority = ResourcePolicy.Keys.preferResponsiveBackgroundPriority
    }

    /// All W/L presets available as rebind targets, built once from the
    /// union of CT + MR + PT presets. De-duplicated and sorted.
    public static let wlPresetNames: [String] = {
        let all = WLPresets.CT + WLPresets.MR + WLPresets.PT
        return Array(Set(all.map(\.name))).sorted()
    }()
}

private extension TracerSettingsView {
    func markResourceCustom() {
        resourceProfileRaw = ResourcePolicy.Profile.custom.rawValue
    }

    func applyResourceProfile(_ profile: ResourcePolicy.Profile) {
        resourceProfileRaw = profile.rawValue
        guard profile != .custom else { return }
        let policy = ResourcePolicy.preset(profile)
        cpuWorkerLimit = policy.cpuWorkerLimit
        indexingWorkerLimit = policy.indexingWorkerLimit
        cohortWorkerLimit = policy.cohortWorkerLimit
        gpuWorkerLimit = policy.gpuWorkerLimit
        mipWorkerLimit = policy.mipWorkerLimit
        memoryBudgetGB = policy.memoryBudgetGB
        undoHistoryBudgetMB = policy.undoHistoryBudgetMB
        sliceCacheEntries = policy.sliceCacheEntries
        petMIPCacheEntries = policy.petMIPCacheEntries
        volumeRenderTextureMaxDimension = policy.volumeRenderTextureMaxDimension
        volumeRenderSampleLimit = policy.volumeRenderSampleLimit
        preferResponsiveBackgroundPriority = policy.preferResponsiveBackgroundPriority
    }

    func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
                                  countStyle: .memory)
    }
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

            Section("Legacy Segmentator / LesionTracer") {
                TextField("nnU-Net source path",
                          text: optionalTextBinding(\.remoteSegmentatorSourcePath),
                          prompt: Text(RemoteLesionTracerRunner.Configuration.defaultSourcePath))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                TextField("Model folder",
                          text: optionalTextBinding(\.remoteSegmentatorModelFolder),
                          prompt: Text(RemoteLesionTracerRunner.Configuration.defaultModelFolder))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                TextField("Worker image tag",
                          text: optionalTextBinding(\.remoteSegmentatorWorkerImage),
                          prompt: Text(RemoteLesionTracerRunner.Configuration.defaultWorkerImage))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                TextField("Base image",
                          text: optionalTextBinding(\.remoteSegmentatorBaseImage),
                          prompt: Text(RemoteLesionTracerRunner.Configuration.defaultBaseImage))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                Text("Tracer builds the worker image on Spark only if it is missing, so LesionTracer dependencies are reused instead of installed every inference.")
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

    private func optionalTextBinding(_ keyPath: WritableKeyPath<DGXSparkConfig, String?>) -> Binding<String> {
        Binding(
            get: { config[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                config[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
            }
        )
    }
}

#endif
