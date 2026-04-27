import SwiftUI

struct WindowingControlsView: View {
    @EnvironmentObject var vm: ViewerViewModel
    var showTitle: Bool = true
    var compact: Bool = false
    @State private var petTarget: WindowingPETTarget = .fused

    private let ctLevelRange: ClosedRange<Double> = -1200...3000
    private let petMinRange: ClosedRange<Double> = 0...60
    private let petMaxRange: ClosedRange<Double> = 0.1...80

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showTitle {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(TracerTheme.accentBright)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Image Windowing")
                            .font(.system(size: 15, weight: .semibold))
                        Text("CT / MR base, PET fusion, PET-only, and MIP")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }

            summaryStrip
            baseWindowSection
            petWindowSection
        }
    }

    private var summaryStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { summaryPills }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) { summaryPills }
        }
    }

    @ViewBuilder
    private var summaryPills: some View {
        WindowingSummaryPill(title: "Base", value: "W \(Int(vm.window)) / L \(Int(vm.level))", tint: TracerTheme.accentBright)
        WindowingSummaryPill(title: "Fused PET", value: suvRangeText(min: vm.petOverlayRangeMin, max: vm.petOverlayRangeMax), tint: TracerTheme.pet)
        WindowingSummaryPill(title: "PET-only", value: suvRangeText(min: vm.petOnlyRangeMin, max: vm.petOnlyRangeMax), tint: TracerTheme.pet)
        WindowingSummaryPill(title: "MIP", value: suvRangeText(min: vm.petMIPRangeMin, max: vm.petMIPRangeMax), tint: TracerTheme.pet)
    }

    private var baseWindowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("CT / MR Base Window", systemImage: "circle.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    vm.autoWLHistogram(preset: .balanced)
                } label: {
                    Label("Auto", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }

            presetGrid(basePresets) { preset in
                vm.applyPreset(preset)
            }

            VStack(alignment: .leading, spacing: 8) {
                WindowingSliderRow(
                    title: "Window",
                    valueText: "\(Int(vm.window))",
                    value: Binding(get: { vm.window }, set: { vm.setWindow($0) }),
                    range: 1...5000,
                    step: 1
                )
                WindowingSliderRow(
                    title: "Level",
                    valueText: "\(Int(vm.level))",
                    value: Binding(get: { vm.level }, set: { vm.setLevel($0) }),
                    range: ctLevelRange,
                    step: 1
                )
            }

            Toggle("Invert CT / base grayscale", isOn: Binding(
                get: { vm.invertCTImages },
                set: { vm.setInvertCTImages($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .windowingSection()
    }

    private var petWindowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("PET Display", systemImage: "flame.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(TracerTheme.pet)
                Spacer()
                Text(suvRangeText(min: activePETRange.min, max: activePETRange.max))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(TracerTheme.pet)
            }

            Picker("PET target", selection: $petTarget) {
                ForEach(WindowingPETTarget.allCases) { target in
                    Text(target.title).tag(target)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Picker("Palette", selection: Binding(
                    get: { activePETColormap },
                    set: { setPETColormap($0) }
                )) {
                    ForEach(Colormap.allCases) { color in
                        Text(color.displayName).tag(color)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 120)

                Toggle(activeInvertTitle, isOn: Binding(
                    get: { activePETInvert },
                    set: { setPETInvert($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            paletteShortcuts

            presetGrid(petPresets) { preset in
                setPETRange(min: preset.min, max: preset.max)
            }

            HStack(spacing: 8) {
                Button {
                    applyAutoPETRange()
                } label: {
                    Label("Auto SUV", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(vm.activePETQuantificationVolume == nil)

                if petTarget == .mip {
                    Button {
                        vm.adjustPETMIPIntensity(brighter: false)
                    } label: {
                        Label("Less", systemImage: "minus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        vm.adjustPETMIPIntensity(brighter: true)
                    } label: {
                        Label("More", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            WindowingSliderRow(
                title: "SUV Min",
                valueText: String(format: "%.1f", activePETRange.min),
                value: Binding(
                    get: { max(petMinRange.lowerBound, activePETRange.min) },
                    set: { setPETRange(min: $0, max: activePETRange.max) }
                ),
                range: petMinRange,
                step: 0.1
            )

            WindowingSliderRow(
                title: "SUV Max",
                valueText: String(format: "%.1f", activePETRange.max),
                value: Binding(
                    get: { min(petMaxRange.upperBound, max(petMaxRange.lowerBound, activePETRange.max)) },
                    set: { setPETRange(min: activePETRange.min, max: $0) }
                ),
                range: petMaxRange,
                step: 0.1
            )

            if petTarget == .fused {
                WindowingSliderRow(
                    title: "PET Blend",
                    valueText: "\(Int(vm.overlayOpacity * 100)) / \(100 - Int(vm.overlayOpacity * 100))",
                    value: Binding(
                        get: { vm.overlayOpacity },
                        set: { vm.setFusionOpacity($0) }
                    ),
                    range: 0...1,
                    step: 0.01
                )
            }
        }
        .windowingSection()
    }

    private var paletteShortcuts: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 76 : 86), spacing: 6)], spacing: 6) {
            ForEach(petPaletteShortlist) { color in
                Button {
                    setPETColormap(color)
                } label: {
                    HStack(spacing: 6) {
                        WindowingPaletteSwatch(colormap: color)
                        Text(shortPaletteName(color))
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }

    private func presetGrid<T: Identifiable>(_ presets: [T], action: @escaping (T) -> Void) -> some View where T: WindowingPresetDisplay {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 74 : 86), spacing: 6)], spacing: 6) {
            ForEach(presets) { preset in
                Button {
                    action(preset)
                } label: {
                    Text(preset.windowingTitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(preset.windowingHelp)
            }
        }
    }

    private var activePETRange: (min: Double, max: Double) {
        switch petTarget {
        case .fused:
            return (vm.petOverlayRangeMin, vm.petOverlayRangeMax)
        case .petOnly:
            return (vm.petOnlyRangeMin, vm.petOnlyRangeMax)
        case .mip:
            return (vm.petMIPRangeMin, vm.petMIPRangeMax)
        }
    }

    private var activePETColormap: Colormap {
        switch petTarget {
        case .fused: return vm.overlayColormap
        case .petOnly: return vm.petOnlyColormap
        case .mip: return vm.mipColormap
        }
    }

    private var activePETInvert: Bool {
        switch petTarget {
        case .fused: return vm.invertPETImages
        case .petOnly: return vm.invertPETOnlyImages
        case .mip: return vm.invertPETMIP
        }
    }

    private var activeInvertTitle: String {
        switch petTarget {
        case .fused: return "Invert fused PET"
        case .petOnly: return "Invert PET-only"
        case .mip: return "Invert MIP"
        }
    }

    private var petPresets: [PETWindowPreset] {
        [
            PETWindowPreset(title: "0-5", min: 0, max: 5),
            PETWindowPreset(title: "0-10", min: 0, max: 10),
            PETWindowPreset(title: "0-15", min: 0, max: 15),
            PETWindowPreset(title: "2.5-15", min: 2.5, max: 15),
            PETWindowPreset(title: "0-20", min: 0, max: 20)
        ]
    }

    private var petPaletteShortlist: [Colormap] {
        [.tracerPET, .petRainbow, .petHotIron, .petMagma, .petViridis, .hot]
    }

    private var basePresets: [WindowLevel] {
        guard let volume = vm.currentVolume else { return WLPresets.CT }
        let modality = Modality.normalize(volume.modality)
        return modality == .MR ? WLPresets.MR : WLPresets.CT
    }

    private func setPETRange(min: Double, max: Double) {
        switch petTarget {
        case .fused:
            vm.setPETOverlayRange(min: min, max: max)
        case .petOnly:
            vm.setPETOnlyRange(min: min, max: max)
        case .mip:
            vm.setPETMIPRange(min: min, max: max)
        }
    }

    private func setPETColormap(_ colormap: Colormap) {
        switch petTarget {
        case .fused:
            vm.setFusionColormap(colormap)
        case .petOnly:
            vm.setPETOnlyColormap(colormap)
        case .mip:
            vm.setPETMIPColormap(colormap)
        }
    }

    private func setPETInvert(_ enabled: Bool) {
        switch petTarget {
        case .fused:
            vm.setInvertPETImages(enabled)
        case .petOnly:
            vm.setInvertPETOnlyImages(enabled)
        case .mip:
            vm.setInvertPETMIP(enabled)
        }
    }

    private func applyAutoPETRange() {
        guard let pet = vm.activePETQuantificationVolume else { return }
        let range = vm.petSUVDisplayRange(for: pet)
        setPETRange(min: max(0, range.min), max: max(1, range.max))
    }

    private func suvRangeText(min: Double, max: Double) -> String {
        String(format: "%.1f-%.1f", min, max)
    }

    private func shortPaletteName(_ colormap: Colormap) -> String {
        switch colormap {
        case .tracerPET: return "Tracer"
        case .petRainbow: return "Rainbow"
        case .petHotIron: return "Hot Iron"
        case .petMagma: return "Magma"
        case .petViridis: return "Viridis"
        default: return colormap.displayName
        }
    }
}

private enum WindowingPETTarget: String, CaseIterable, Identifiable {
    case fused
    case petOnly
    case mip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fused: return "Fused PET"
        case .petOnly: return "PET-only"
        case .mip: return "MIP"
        }
    }
}

private protocol WindowingPresetDisplay {
    var windowingTitle: String { get }
    var windowingHelp: String { get }
}

extension WindowLevel: WindowingPresetDisplay {
    fileprivate var windowingTitle: String { name }
    fileprivate var windowingHelp: String {
        "W \(Int(window)) / L \(Int(level))"
    }
}

private struct PETWindowPreset: Identifiable, WindowingPresetDisplay {
    let title: String
    let min: Double
    let max: Double

    var id: String { title }
    var windowingTitle: String { title }
    var windowingHelp: String {
        String(format: "SUV %.1f-%.1f", min, max)
    }
}

private struct WindowingSummaryPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TracerTheme.panelPressed.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(TracerTheme.hairline, lineWidth: 1)
        )
    }
}

private struct WindowingSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(valueText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
        }
    }
}

private struct WindowingPaletteSwatch: View {
    let colormap: Colormap

    var body: some View {
        LinearGradient(colors: colors,
                       startPoint: .leading,
                       endPoint: .trailing)
            .frame(width: 28, height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
    }

    private var colors: [Color] {
        switch colormap {
        case .tracerPET:
            return [.black, .purple, .red, .orange, .white]
        case .petRainbow:
            return [.black, .blue, .green, .yellow, .red]
        case .petHotIron:
            return [.black, .red, .orange, .yellow, .white]
        case .petMagma:
            return [.black, .purple, .pink, .orange, .white]
        case .petViridis:
            return [.purple, .blue, .green, .yellow]
        case .grayscale:
            return [.black, .white]
        case .hot:
            return [.black, .red, .yellow, .white]
        case .jet:
            return [.blue, .cyan, .green, .yellow, .red]
        case .bone:
            return [.black, .gray, .white]
        case .coolWarm:
            return [.blue, .white, .red]
        case .fire:
            return [.black, .orange, .red, .white]
        case .ice:
            return [.black, .cyan, .white]
        case .invertedGray:
            return [.white, .black]
        }
    }
}

private extension View {
    func windowingSection() -> some View {
        self
            .padding(12)
            .background(TracerTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(TracerTheme.hairline, lineWidth: 1)
            )
    }
}
