import SwiftUI

struct ControlsPanel: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var tab: Tab = .assistant

    enum Tab: String, CaseIterable, Identifiable {
        case assistant = "AI"
        case wl = "W/L"
        case fusion = "Fusion"
        case labels = "Labels"
        case registration = "Reg"
        case display = "Display"
        case info = "Info"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            // The Assistant tab manages its own layout (fixed composer at the
            // bottom, scrollable transcript in the middle). Wrapping it in an
            // outer ScrollView would push the text field below the fold on
            // shorter windows, so we render it directly instead.
            Group {
                switch tab {
                case .assistant:
                    AssistantPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .wl:
                    ScrollView { WLTab().padding(16) }
                case .fusion:
                    ScrollView { FusionTab().padding(16) }
                case .labels:
                    ScrollView { LabelingPanel() }
                case .registration:
                    ScrollView { RegistrationPanel() }
                case .display:
                    ScrollView { DisplayTab().padding(16) }
                case .info:
                    ScrollView { InfoTab().padding(16) }
                }
            }
        }
        .navigationTitle("Controls")
        .environmentObject(vm)
        .onReceive(NotificationCenter.default.publisher(for: .focusAssistantTab)) { _ in
            tab = .assistant
        }
    }
}

extension Notification.Name {
    /// Posted when the user clicks the chatbot icon in the main toolbar —
    /// `ControlsPanel` listens and switches its segmented picker to `.assistant`.
    public static let focusAssistantTab = Notification.Name("DicomViewerPro.focusAssistantTab")
}

// MARK: - W/L Tab

private struct WLTab: View {
    @EnvironmentObject var vm: ViewerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Window / Level")
                .font(.headline)

            HStack {
                Text("W:")
                    .frame(width: 20, alignment: .leading)
                Slider(value: $vm.window, in: 1...5000)
                Text(String(format: "%.0f", vm.window))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 48, alignment: .trailing)
            }

            HStack {
                Text("L:")
                    .frame(width: 20, alignment: .leading)
                Slider(value: $vm.level, in: -1000...3000)
                Text(String(format: "%.0f", vm.level))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 48, alignment: .trailing)
            }

            Divider()

            if let v = vm.currentVolume {
                let modality = Modality.normalize(v.modality)
                Text("\(modality.displayName) Presets")
                    .font(.subheadline)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                          spacing: 4) {
                    ForEach(WLPresets.presets(for: modality)) { p in
                        Button {
                            vm.applyPreset(p)
                        } label: {
                            Text(p.name)
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("W: \(Int(p.window))  L: \(Int(p.level))")
                    }
                }
            }

            Button {
                vm.autoWL()
            } label: {
                Label("Auto Window / Level", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
    }
}

// MARK: - Fusion Tab

private struct FusionTab: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var selectedCTID: UUID?
    @State private var selectedPETID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("PET/CT Fusion")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.autoFusePETCT() }
                } label: {
                    Label("Auto", systemImage: "wand.and.stars")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.loadedCTVolumes.isEmpty || vm.loadedPETVolumes.isEmpty)
            }

            fusionBuilder

            if let pair = vm.fusion {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pair.fusionTypeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.orange)
                    Text(pair.overlayVolume.seriesDescription.isEmpty ? "PET overlay" : pair.overlayVolume.seriesDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(pair.registrationNote)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("CT grid \(pair.baseGridLabel) · PET grid \(pair.overlayGridLabel)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

                Toggle("Show PET overlay", isOn: Binding(
                    get: { pair.overlayVisible },
                    set: { pair.overlayVisible = $0; pair.objectWillChange.send() }
                ))

                // Opacity
                VStack(alignment: .leading) {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text("\(Int(vm.overlayOpacity * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    Slider(value: Binding(
                        get: { vm.overlayOpacity },
                        set: { new in
                            vm.overlayOpacity = new
                            vm.fusion?.opacity = new
                        }
                    ), in: 0...1)
                }

                // Colormap
                HStack {
                    Text("Colormap")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { vm.overlayColormap },
                        set: { new in
                            vm.overlayColormap = new
                            vm.fusion?.colormap = new
                        }
                    )) {
                        ForEach(Colormap.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .labelsHidden()
                }

                // Overlay W/L
                VStack(alignment: .leading) {
                    Text("PET Range")
                        .font(.subheadline)
                    HStack(spacing: 6) {
                        Button("SUV 0-10") {
                            vm.overlayWindow = 10
                            vm.overlayLevel = 5
                            vm.fusion?.overlayWindow = 10
                            vm.fusion?.overlayLevel = 5
                        }
                        Button("SUV 0-15") {
                            vm.overlayWindow = 15
                            vm.overlayLevel = 7.5
                            vm.fusion?.overlayWindow = 15
                            vm.fusion?.overlayLevel = 7.5
                        }
                        Button("Auto") {
                            if let overlay = vm.fusion?.overlayVolume {
                                let maxValue = max(1, Double(overlay.intensityRange.max))
                                vm.overlayWindow = maxValue
                                vm.overlayLevel = maxValue * 0.5
                                vm.fusion?.overlayWindow = vm.overlayWindow
                                vm.fusion?.overlayLevel = vm.overlayLevel
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    HStack {
                        Text("W:")
                        Slider(value: Binding(
                            get: { vm.overlayWindow },
                            set: { new in
                                vm.overlayWindow = new
                                vm.fusion?.overlayWindow = new
                            }
                        ), in: 0.1...40)
                        Text(String(format: "%.1f", vm.overlayWindow))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 40, alignment: .trailing)
                    }
                    HStack {
                        Text("L:")
                        Slider(value: Binding(
                            get: { vm.overlayLevel },
                            set: { new in
                                vm.overlayLevel = new
                                vm.fusion?.overlayLevel = new
                            }
                        ), in: 0...40)
                        Text(String(format: "%.1f", vm.overlayLevel))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Divider()

                suvQuantificationPanel

                Button(role: .destructive) {
                    vm.removeOverlay()
                } label: {
                    Label("Remove Overlay", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Text("No overlay loaded")
                    .foregroundColor(.secondary)
                Text("Load a CT and PET series, then use Auto or choose volumes above. PET is resampled into the CT grid using DICOM/NIfTI world geometry.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if vm.activePETQuantificationVolume != nil {
                    Divider()
                    suvQuantificationPanel
                }
            }

            Spacer()
        }
    }

    private var fusionBuilder: some View {
        VStack(alignment: .leading, spacing: 10) {
            if vm.loadedCTVolumes.isEmpty || vm.loadedPETVolumes.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Open the CT series and the PET series from the worklist first. Loaded CT: \(vm.loadedCTVolumes.count), PET: \(vm.loadedPETVolumes.count).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Picker("CT", selection: ctSelection) {
                    ForEach(vm.loadedCTVolumes) { volume in
                        Text(volumeLabel(volume)).tag(Optional(volume.id))
                    }
                }

                Picker("PET", selection: petSelection) {
                    ForEach(vm.loadedPETVolumes) { volume in
                        Text(volumeLabel(volume)).tag(Optional(volume.id))
                    }
                }

                Button {
                    guard let ct = selectedCTVolume,
                          let pet = selectedPETVolume else { return }
                    Task { await vm.fusePETCT(base: ct, overlay: pet) }
                } label: {
                    Label("Fuse Selected PET/CT", systemImage: "square.2.layers.3d")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCTVolume == nil || selectedPETVolume == nil)
            }
        }
        .onAppear {
            selectedCTID = selectedCTID ?? vm.loadedCTVolumes.first?.id
            selectedPETID = selectedPETID ?? vm.loadedPETVolumes.first?.id
        }
    }

    private var ctSelection: Binding<UUID?> {
        Binding(
            get: { selectedCTID ?? vm.loadedCTVolumes.first?.id },
            set: { selectedCTID = $0 }
        )
    }

    private var petSelection: Binding<UUID?> {
        Binding(
            get: { selectedPETID ?? vm.loadedPETVolumes.first?.id },
            set: { selectedPETID = $0 }
        )
    }

    private var selectedCTVolume: ImageVolume? {
        let id = selectedCTID ?? vm.loadedCTVolumes.first?.id
        return vm.loadedCTVolumes.first { $0.id == id }
    }

    private var selectedPETVolume: ImageVolume? {
        let id = selectedPETID ?? vm.loadedPETVolumes.first?.id
        return vm.loadedPETVolumes.first { $0.id == id }
    }

    private func volumeLabel(_ volume: ImageVolume) -> String {
        let name = volume.seriesDescription.isEmpty
            ? Modality.normalize(volume.modality).displayName
            : volume.seriesDescription
        return "\(name) · \(volume.width)x\(volume.height)x\(volume.depth)"
    }

    private var suvQuantificationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SUV Quantification")
                .font(.subheadline)

            Picker("Mode", selection: $vm.suvSettings.mode) {
                ForEach(SUVCalculationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            if vm.suvSettings.mode != .storedSUV,
               vm.suvSettings.mode != .manualScale {
                Picker("Input", selection: $vm.suvSettings.activityUnit) {
                    ForEach(PETActivityUnit.allCases) { unit in
                        Text(unit.displayName).tag(unit)
                    }
                }
            }

            switch vm.suvSettings.mode {
            case .storedSUV:
                Text("Stored PET values are treated as SUV.")
                    .font(.caption)
                    .foregroundColor(.secondary)

            case .manualScale:
                NumberFieldRow("Factor", value: $vm.suvSettings.manualScaleFactor)

            case .bodyWeight:
                NumberFieldRow("Weight kg", value: $vm.suvSettings.patientWeightKg)
                NumberFieldRow("Injected MBq", value: $vm.suvSettings.injectedDoseMBq)
                NumberFieldRow("Residual MBq", value: $vm.suvSettings.residualDoseMBq)
                if vm.suvSettings.activityUnit == .custom {
                    NumberFieldRow("Bq/mL per unit", value: $vm.suvSettings.customBqPerMLPerStoredUnit)
                }

            case .leanBodyMass:
                Picker("Sex", selection: $vm.suvSettings.sex) {
                    ForEach(BiologicalSexForSUV.allCases) { sex in
                        Text(sex.displayName).tag(sex)
                    }
                }
                NumberFieldRow("Weight kg", value: $vm.suvSettings.patientWeightKg)
                NumberFieldRow("Height cm", value: $vm.suvSettings.patientHeightCm)
                NumberFieldRow("Injected MBq", value: $vm.suvSettings.injectedDoseMBq)
                NumberFieldRow("Residual MBq", value: $vm.suvSettings.residualDoseMBq)
                ControlStatRow("LBM", String(format: "%.1f kg", vm.suvSettings.leanBodyMassKg))
                if vm.suvSettings.activityUnit == .custom {
                    NumberFieldRow("Bq/mL per unit", value: $vm.suvSettings.customBqPerMLPerStoredUnit)
                }

            case .bodySurfaceArea:
                NumberFieldRow("Weight kg", value: $vm.suvSettings.patientWeightKg)
                NumberFieldRow("Height cm", value: $vm.suvSettings.patientHeightCm)
                NumberFieldRow("Injected MBq", value: $vm.suvSettings.injectedDoseMBq)
                NumberFieldRow("Residual MBq", value: $vm.suvSettings.residualDoseMBq)
                ControlStatRow("BSA", String(format: "%.2f m²", vm.suvSettings.bodySurfaceAreaM2))
                if vm.suvSettings.activityUnit == .custom {
                    NumberFieldRow("Bq/mL per unit", value: $vm.suvSettings.customBqPerMLPerStoredUnit)
                }
            }

            Text(vm.suvSettings.scaleDescription)
                .font(.caption)
                .foregroundColor(.secondary)

            if let probe = vm.activePETProbe() {
                ControlStatRow("Voxel", "\(probe.voxel.x), \(probe.voxel.y), \(probe.voxel.z)")
                ControlStatRow("Stored", String(format: "%.3f", probe.rawValue))
                ControlStatRow(vm.suvSettings.mode.displayName, String(format: "%.3f", probe.suv))
            }

            if let map = vm.labeling.activeLabelMap,
               let cls = map.classInfo(id: vm.labeling.activeClassID),
               let stats = vm.activePETRegionStats(for: map, classID: cls.labelID),
               stats.count > 0 {
                Divider()
                Text("Active Label: \(cls.name)")
                    .font(.system(size: 11, weight: .semibold))
                if let suvMax = stats.suvMax {
                    ControlStatRow("SUVmax", String(format: "%.3f", suvMax))
                }
                if let suvMean = stats.suvMean {
                    ControlStatRow("SUVmean", String(format: "%.3f", suvMean))
                }
                if let tlg = stats.tlg {
                    ControlStatRow("TLG", String(format: "%.1f", tlg))
                }
            }
        }
    }
}

// MARK: - Display Tab

private struct DisplayTab: View {
    @EnvironmentObject var vm: ViewerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Display Options")
                .font(.headline)

            Toggle("Invert Colors", isOn: $vm.invertColors)
                .help("Useful for MR or X-ray inversion")

            Divider()

            Text("Active Tool")
                .font(.subheadline)
            Picker("", selection: $vm.activeTool) {
                ForEach(ViewerTool.allCases) { t in
                    Label(t.displayName, systemImage: t.systemImage)
                        .tag(t)
                }
            }
            .pickerStyle(.segmented)

            Text(toolHelpText)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private var toolHelpText: String {
        switch vm.activeTool {
        case .wl: return "Drag left/right for window, up/down for level"
        case .pan: return "Drag to pan the image"
        case .zoom: return "Drag up/down to zoom. Pinch on iPad. Double-tap to reset."
        case .distance: return "Tap two points to measure distance"
        case .angle: return "Tap three points for an angle measurement"
        case .area: return "Tap three+ points, close to measure area"
        }
    }
}

// MARK: - Info Tab

private struct InfoTab: View {
    @EnvironmentObject var vm: ViewerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Study Information")
                .font(.headline)

            if let v = vm.currentVolume {
                InfoRow(label: "Patient", value: v.patientName)
                InfoRow(label: "Patient ID", value: v.patientID)
                InfoRow(label: "Modality", value: Modality.normalize(v.modality).displayName)
                InfoRow(label: "Study", value: v.studyDescription)
                InfoRow(label: "Series", value: v.seriesDescription)
                Divider()
                InfoRow(label: "Dimensions", value: "\(v.width) × \(v.height) × \(v.depth)")
                InfoRow(label: "Spacing", value: String(format: "%.2f × %.2f × %.2f mm",
                                                        v.spacing.x, v.spacing.y, v.spacing.z))
                InfoRow(label: "Size", value: String(format: "%.1f MB", Double(v.sizeBytes) / 1_048_576))
                if let suv = v.suvScaleFactor {
                    InfoRow(label: "SUV factor", value: String(format: "%.4e", suv))
                }
            } else {
                Text("No volume loaded")
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }
}

private struct NumberFieldRow: View {
    let label: String
    @Binding var value: Double

    init(_ label: String, value: Binding<Double>) {
        self.label = label
        self._value = value
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            TextField("", value: $value, formatter: Self.formatter)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 86)
                .textFieldStyle(.roundedBorder)
        }
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        return formatter
    }()
}

private struct ControlStatRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}
