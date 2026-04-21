import SwiftUI

struct ControlsPanel: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var tab: Tab = .wl

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

            ScrollView {
                Group {
                    switch tab {
                    case .assistant:    AssistantPanel()
                    case .wl:            WLTab()
                    case .fusion:        FusionTab()
                    case .labels:        LabelingPanel()
                    case .registration:  RegistrationPanel()
                    case .display:       DisplayTab()
                    case .info:          InfoTab()
                    }
                }
                .padding(tab == .labels || tab == .registration || tab == .assistant ? 0 : 16)
            }
        }
        .navigationTitle("Controls")
        .environmentObject(vm)
    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fusion Overlay")
                .font(.headline)

            if let pair = vm.fusion {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pair.fusionTypeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.orange)
                    Text(pair.overlayVolume.seriesDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

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
                    Text("Overlay Range")
                        .font(.subheadline)
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
                Text("Use the sidebar 'Add Overlay (PET)' button to load a PET or functional volume on top of your current study.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
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
