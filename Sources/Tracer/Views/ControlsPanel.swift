import SwiftUI

struct ControlsPanel: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var group: Group = .assistant
    @State private var viewingSub: ViewingSub = .wl
    @State private var segSub: SegSub = .labels

    /// Top-level grouping. Radiologists hop between four main activities;
    /// the controls panel now surfaces those as four tabs rather than
    /// seven flat ones. Nested pickers expose the finer-grained sub-tabs
    /// only when the parent group is active.
    enum Group: String, CaseIterable, Identifiable, Hashable {
        case assistant = "AI"
        case viewing = "Viewing"
        case oncology = "Oncology"
        case brain = "Brain"
        case segmentation = "Segmentation"
        case registration = "Reg"
        case info = "Info"
        var id: String { rawValue }
    }

    enum ViewingSub: String, CaseIterable, Identifiable, Hashable {
        case wl = "W/L"
        case fusion = "Fusion"
        case dynamic = "Dynamic"
        case display = "Display"
        var id: String { rawValue }
    }

    enum SegSub: String, CaseIterable, Identifiable, Hashable {
        case labels = "Labels"
        case runs = "Runs"
        case registration = "Landmarks"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            ResponsivePicker("Panel", selection: $group, menuBreakpoint: 330) {
                ForEach(Group.allCases) { g in
                    Text(g.rawValue).tag(g)
                }
            }
            .padding(8)

            // Secondary sub-tab picker, shown only for groups that have
            // sub-tabs (Viewing, Segmentation).
            if group == .viewing {
                ResponsivePicker("Viewing", selection: $viewingSub, menuBreakpoint: 250) {
                    ForEach(ViewingSub.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            } else if group == .segmentation {
                ResponsivePicker("Segmentation", selection: $segSub, menuBreakpoint: 270) {
                    ForEach(SegSub.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }

            Rectangle().fill(TracerTheme.hairline).frame(height: 1)

            // The Assistant tab manages its own layout (fixed composer at the
            // bottom, scrollable transcript in the middle). Wrapping it in an
            // outer ScrollView would push the text field below the fold on
            // shorter windows, so we render it directly instead.
            SwiftUI.Group {
                switch group {
                case .assistant:
                    AssistantPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .viewing:
                    switch viewingSub {
                    case .wl:      ScrollView { WLTab().padding(16) }
                    case .fusion:  ScrollView { FusionTab().padding(16) }
                    case .dynamic: ScrollView { DynamicTab().padding(16) }
                    case .display: ScrollView { DisplayTab().padding(16) }
                    }
                case .oncology:
                    ScrollView { OncologyReviewPanel().padding(16) }
                case .brain:
                    ScrollView { BrainPETPanel().padding(16) }
                case .segmentation:
                    switch segSub {
                    case .labels:       ScrollView { LabelingPanel() }
                    case .runs:         ScrollView { SegmentationRunsPanel().padding(16) }
                    case .registration: ScrollView { RegistrationPanel() }
                    }
                case .registration:
                    ScrollView { RegistrationPanel() }
                case .info:
                    ScrollView { InfoTab().padding(16) }
                }
            }
        }
        .navigationTitle("Controls")
        .tint(TracerTheme.accent)
        .background(TracerTheme.panelBackground)
        .environmentObject(vm)
        .onReceive(NotificationCenter.default.publisher(for: .focusAssistantTab)) { _ in
            group = .assistant
        }
    }
}

extension Notification.Name {
    /// Posted when the user clicks the chatbot icon in the main toolbar —
    /// `ControlsPanel` listens and switches its segmented picker to `.assistant`.
    public static let focusAssistantTab = Notification.Name("Tracer.focusAssistantTab")
}

// MARK: - W/L Tab

private struct WLTab: View {
    @EnvironmentObject var vm: ViewerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WindowingControlsView(showTitle: true, compact: false)

            Divider()
            StudySessionPanel()

            Spacer()
        }
    }
}

// MARK: - Dynamic Tab

private struct DynamicTab: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var frameDurationSeconds: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Dynamic Imaging")
                    .font(.headline)
                Spacer()
                Button {
                    vm.buildDynamicStudyFromLoadedVolumes(frameDurationSeconds: frameDurationSeconds)
                } label: {
                    Label("Build", systemImage: "square.stack.3d.up")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.dynamicCandidateVolumes.count < 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                ControlStatRow("Candidate frames", "\(vm.dynamicCandidateVolumes.count)")
                HStack {
                    Text("Frame dur.")
                    Spacer()
                    Text(String(format: "%.1fs", frameDurationSeconds))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: $frameDurationSeconds, in: 0.25...120, step: 0.25)
                    .help("Temporary frame duration used when source metadata does not provide dynamic timing.")
            }

            if let study = vm.dynamicStudy {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(study.name)
                        .font(.system(size: 12, weight: .semibold))
                    ControlStatRow("Modality", study.modality.displayName)
                    ControlStatRow("Frames", "\(study.frameCount)")
                    ControlStatRow("Duration", study.durationLabel)
                    if let frame = study.frame(at: vm.selectedDynamicFrameIndex) {
                        ControlStatRow("Current", "\(frame.displayName)")
                    }

                    let maxFrame = max(0, study.frameCount - 1)
                    Slider(
                        value: Binding(
                            get: { Double(vm.selectedDynamicFrameIndex) },
                            set: { vm.setDynamicFrame(index: Int($0.rounded())) }
                        ),
                        in: 0...Double(maxFrame),
                        step: 1
                    )

                    HStack(spacing: 6) {
                        Button {
                            vm.stepDynamicFrame(delta: -1)
                        } label: {
                            Image(systemName: "backward.frame")
                        }
                        .help("Previous frame")

                        Button {
                            vm.toggleDynamicPlayback()
                        } label: {
                            Label(vm.isDynamicPlaybackRunning ? "Pause" : "Play",
                                  systemImage: vm.isDynamicPlaybackRunning ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            vm.stepDynamicFrame(delta: 1)
                        } label: {
                            Image(systemName: "forward.frame")
                        }
                        .help("Next frame")

                        Spacer()

                        Button {
                            vm.clearDynamicStudy()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .help("Close dynamic workflow")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    HStack {
                        Text("FPS")
                        Slider(value: $vm.dynamicPlaybackFPS, in: 0.25...12, step: 0.25)
                        Text(String(format: "%.1f", vm.dynamicPlaybackFPS))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Time-Activity Curve")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if vm.isDynamicTACComputing {
                            ProgressView()
                                .scaleEffect(0.65)
                        }
                    }
                    Button {
                        vm.computeDynamicTimeActivityCurveForActiveLabel()
                    } label: {
                        Label("Update From Active Label", systemImage: "chart.xyaxis.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.labeling.activeLabelMap == nil || vm.isDynamicTACComputing)

                    if !vm.dynamicTimeActivityCurve.isEmpty {
                        DynamicTACChart(points: vm.dynamicTimeActivityCurve)
                            .frame(height: 110)
                        dynamicTACRows(points: vm.dynamicTimeActivityCurve)
                    } else {
                        Text("Use a label or lesion ROI to plot frame-by-frame mean and max activity.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("Load two or more PET/NM volumes on the same grid, then build a dynamic study. The current MPR panes become the dynamic frame viewer.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func dynamicTACRows(points: [DynamicTimeActivityPoint]) -> some View {
        VStack(spacing: 4) {
            ForEach(points.prefix(6)) { point in
                HStack {
                    Text("F\(point.frameIndex + 1)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(width: 28, alignment: .leading)
                    Text(DynamicFrame.formatTime(point.midSeconds))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "mean %.3f  max %.3f %@", point.mean, point.max, point.unit))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            if points.count > 6 {
                Text("+ \(points.count - 6) more frames")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct DynamicTACChart: View {
    let points: [DynamicTimeActivityPoint]

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }
            let maxTime = max(points.map(\.midSeconds).max() ?? 1, 1)
            let maxValue = max(points.map(\.max).max() ?? 1, 1)
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 8)

            var axis = Path()
            axis.move(to: CGPoint(x: rect.minX, y: rect.minY))
            axis.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            axis.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            context.stroke(axis, with: .color(TracerTheme.hairline), lineWidth: 1)

            drawLine(points.map { ($0.midSeconds, $0.mean) },
                     maxTime: maxTime,
                     maxValue: maxValue,
                     rect: rect,
                     color: TracerTheme.accentBright,
                     context: &context)
            drawLine(points.map { ($0.midSeconds, $0.max) },
                     maxTime: maxTime,
                     maxValue: maxValue,
                     rect: rect,
                     color: TracerTheme.pet,
                     context: &context)
        }
        .background(Color.secondary.opacity(0.07))
        .cornerRadius(6)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                Label("mean", systemImage: "chart.xyaxis.line")
                    .foregroundColor(TracerTheme.accentBright)
                Label("max", systemImage: "chart.line.uptrend.xyaxis")
                    .foregroundColor(TracerTheme.pet)
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(6)
        }
    }

    private func drawLine(_ values: [(Double, Double)],
                          maxTime: Double,
                          maxValue: Double,
                          rect: CGRect,
                          color: Color,
                          context: inout GraphicsContext) {
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(value.0 / maxTime) * rect.width
            let y = rect.maxY - CGFloat(value.1 / maxValue) * rect.height
            let point = CGPoint(x: x, y: y)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Fusion Tab

private struct FusionTab: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var selectedCTID: UUID?
    @State private var selectedMRID: UUID?
    @State private var selectedPETID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Fusion")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.autoFusePETCT() }
                } label: {
                    Label("PET/CT", systemImage: "wand.and.stars")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.loadedCTVolumes.isEmpty || vm.loadedPETVolumes.isEmpty)

                Button {
                    Task { await vm.autoFusePETMR() }
                } label: {
                    Label("PET/MR", systemImage: "brain.head.profile")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.loadedMRVolumes.isEmpty || vm.loadedPETVolumes.isEmpty)
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
                    Text("Base grid \(pair.baseGridLabel) · overlay grid \(pair.overlayGridLabel)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

                fusionLayerStack(pair)

                if let quality = pair.registrationQuality {
                    registrationQualityCard(quality)
                }

                Toggle("Show PET overlay", isOn: Binding(
                    get: { vm.fusion?.overlayVisible ?? false },
                    set: { vm.setFusionOverlayVisible($0) }
                ))
                .help("Turns the PET layer on/off in fused panes. PET-only and MIP panes stay visible.")

                Toggle("Correct A/P display", isOn: Binding(
                    get: { vm.correctAnteriorPosteriorDisplay },
                    set: { vm.setCorrectAnteriorPosteriorDisplay($0) }
                ))
                    .help("Use this when anterior/posterior anatomy appears swapped in CT/PET panes.")

                // PET/CT blend. At 100% PET the fused pane is PET-only; at
                // 0% PET it is anatomy-only.
                VStack(alignment: .leading) {
                    HStack {
                        Text("PET blend")
                        Spacer()
                        Text("PET \(Int(vm.overlayOpacity * 100)) / CT \(100 - Int(vm.overlayOpacity * 100))")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    Slider(value: Binding(
                        get: { vm.overlayOpacity },
                        set: { vm.setFusionOpacity($0) }
                    ), in: 0...1)
                }

                hangingProtocolPanel

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
                Text("Load PET plus CT or MR, then use Auto or choose volumes above. PET is resampled into the selected anatomical grid using DICOM/NIfTI world geometry plus the selected registration mode.")
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

    private func fusionLayerStack(_ pair: FusionPair) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Layer stack", systemImage: "square.3.layers.3d.down.right")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("top → bottom")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            layerRow(name: "Labels", detail: "contours above fusion", color: .green, opacity: 1.0)
            layerRow(
                name: Modality.normalize(pair.overlayVolume.modality).displayName,
                detail: "\(pair.colormap.displayName) · \(Int(pair.opacity * 100))%",
                color: .orange,
                opacity: pair.overlayVisible ? 1.0 : 0.35
            )
            layerRow(
                name: Modality.normalize(pair.baseVolume.modality).displayName,
                detail: pair.baseVolume.seriesDescription.isEmpty ? "base anatomy" : pair.baseVolume.seriesDescription,
                color: TracerTheme.accent,
                opacity: 1.0
            )
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.18))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(TracerTheme.hairline, lineWidth: 1)
        )
        .cornerRadius(6)
    }

    private func layerRow(name: String, detail: String, color: Color, opacity: Double) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color.opacity(opacity))
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 46, alignment: .leading)
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
    }

    private func registrationQualityCard(_ quality: RegistrationQualityComparison) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Registration QA", systemImage: qaIcon(quality.grade))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(quality.grade.displayName)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(qaColor(quality.grade))
            }

            Text(quality.summary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                qaMetric("NMI Δ", value: signedMetric(quality.nmiDelta, digits: 3))
                qaMetric("Overlap Δ", value: signedMetric(quality.diceDelta, digits: 2))
                qaMetric("Centroid", value: mmMetric(quality.after.centroidResidualMM))
                qaMetric("Samples", value: "\(quality.after.sampleCount)")
            }

            if let deformation = quality.deformation {
                HStack(spacing: 6) {
                    if let jacobianMin = deformation.jacobianMin {
                        qaMetric("Jac min", value: String(format: "%.2f", jacobianMin))
                    }
                    if let folding = deformation.foldingPercent {
                        qaMetric("Folding", value: String(format: "%.2f%%", folding))
                    }
                    if let inverse = deformation.inverseConsistencyRMSEMM {
                        qaMetric("Inv", value: String(format: "%.1f mm", inverse))
                    }
                }
            }

            ForEach(Array(quality.warnings.prefix(3)), id: \.self) { warning in
                Text(warning)
                    .font(.system(size: 10))
                    .foregroundColor(qaColor(quality.grade))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(qaColor(quality.grade).opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(qaColor(quality.grade).opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(6)
        .help("Patient-specific registration QA. Review any warning before using fused PET/MR for labels, measurements, or dose.")
    }

    private func qaMetric(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.16))
        .cornerRadius(4)
    }

    private func signedMetric(_ value: Double?, digits: Int) -> String {
        guard let value else { return "n/a" }
        return String(format: "%+.\(digits)f", value)
    }

    private func mmMetric(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f mm", value)
    }

    private func qaColor(_ grade: RegistrationQualityGrade) -> Color {
        switch grade {
        case .pass: return .green
        case .caution: return .orange
        case .fail: return .red
        case .unknown: return .secondary
        }
    }

    private func qaIcon(_ grade: RegistrationQualityGrade) -> String {
        switch grade {
        case .pass: return "checkmark.seal"
        case .caution: return "exclamationmark.triangle"
        case .fail: return "xmark.octagon"
        case .unknown: return "questionmark.diamond"
        }
    }

    private var hangingProtocolPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hanging Protocol")
                    .font(.subheadline)
                Spacer()
                Menu {
                    Button {
                        vm.resetPETHangingProtocol()
                    } label: {
                        Label("PET/CT", systemImage: "square.2.layers.3d")
                    }
                    Button {
                        vm.resetMRIHangingProtocol()
                    } label: {
                        Label("MRI", systemImage: "brain.head.profile")
                    }
                    Button {
                        vm.resetPETMRHangingProtocol()
                    } label: {
                        Label("PET/MR", systemImage: "brain")
                    }
                    Button {
                        vm.resetUnifiedHangingProtocol()
                    } label: {
                        Label("Unified", systemImage: "rectangle.grid.3x2")
                    }
                } label: {
                    Label("Preset", systemImage: "rectangle.grid.2x2")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.mini)
                .help("Apply a modality-specific hanging protocol.")
            }

            HStack(spacing: 8) {
                Stepper(value: Binding(
                    get: { vm.hangingGrid.columns },
                    set: { vm.setHangingGrid(columns: $0, rows: vm.hangingGrid.rows) }
                ), in: 1...8) {
                    Text("Cols \(vm.hangingGrid.columns)")
                        .font(.system(size: 11, design: .monospaced))
                }
                Stepper(value: Binding(
                    get: { vm.hangingGrid.rows },
                    set: { vm.setHangingGrid(columns: vm.hangingGrid.columns, rows: $0) }
                ), in: 1...8) {
                    Text("Rows \(vm.hangingGrid.rows)")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .controlSize(.small)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                ForEach(HangingGridLayout.presets, id: \.displayName) { layout in
                    Button(layout.displayName) {
                        vm.setHangingGrid(layout)
                    }
                    .buttonStyle(.bordered)
                    .tint(layout == vm.hangingGrid ? TracerTheme.accent : .secondary)
                    .controlSize(.mini)
                }
            }

            ForEach(Array(vm.hangingPanes.enumerated()), id: \.element.id) { index, pane in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    Picker("", selection: Binding(
                        get: { pane.kind },
                        set: { vm.setHangingPaneKind(index: index, kind: $0) }
                    )) {
                        ForEach(HangingPaneKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    Picker("", selection: Binding(
                        get: { pane.plane },
                        set: { vm.setHangingPanePlane(index: index, plane: $0) }
                    )) {
                        ForEach(SlicePlane.allCases) { plane in
                            Text(plane.shortName).tag(plane)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 78)
                }
                .controlSize(.small)
            }
        }
    }

    private var fusionBuilder: some View {
        VStack(alignment: .leading, spacing: 10) {
            if vm.loadedPETVolumes.isEmpty ||
                (vm.loadedCTVolumes.isEmpty && vm.loadedMRVolumes.isEmpty) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Open PET plus CT or MR from the worklist first. Loaded CT: \(vm.loadedCTVolumes.count), MR: \(vm.loadedMRVolumes.count), PET: \(vm.loadedPETVolumes.count).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !vm.loadedCTVolumes.isEmpty && !vm.loadedPETVolumes.isEmpty {
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

            if !vm.loadedMRVolumes.isEmpty && !vm.loadedPETVolumes.isEmpty {
                Divider()

                Picker("MR", selection: mrSelection) {
                    ForEach(vm.loadedMRVolumes.sorted(by: mrSort)) { volume in
                        Text(mrVolumeLabel(volume)).tag(Optional(volume.id))
                    }
                }

                Picker("PET", selection: petSelection) {
                    ForEach(vm.loadedPETVolumes) { volume in
                        Text(volumeLabel(volume)).tag(Optional(volume.id))
                    }
                }

                Picker("PET/MR registration", selection: Binding(
                    get: { vm.petMRRegistrationMode },
                    set: { vm.setPETMRRegistrationMode($0) }
                )) {
                    ForEach(PETMRRegistrationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .help(vm.petMRRegistrationMode.helpText)

                petMRDeformablePanel

                Button {
                    guard let mr = selectedMRVolume,
                          let pet = selectedPETVolume else { return }
                    Task { await vm.fusePETMR(base: mr, overlay: pet) }
                } label: {
                    Label("Fuse Selected PET/MR", systemImage: "brain.head.profile")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedMRVolume == nil || selectedPETVolume == nil)
            }
        }
        .onAppear {
            selectedCTID = selectedCTID ?? vm.loadedCTVolumes.first?.id
            selectedMRID = selectedMRID ?? vm.loadedMRVolumes.sorted(by: mrSort).first?.id
            selectedPETID = selectedPETID ?? vm.loadedPETVolumes.first?.id
        }
    }

    private var petMRDeformablePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Deformable backend")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(vm.petMRDeformableRegistration.backend.needsExternalRunner ? "external" : "built-in")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Picker("Backend", selection: deformableBackendBinding) {
                ForEach(PETMRDeformableBackend.allCases) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .help(vm.petMRDeformableRegistration.backend.adapterHelp)

            if vm.petMRDeformableRegistration.backend.needsExternalRunner {
                Picker("Metric", selection: deformableMetricBinding) {
                    ForEach(PETMRRegistrationMetricPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .help(vm.petMRDeformableRegistration.metricPreset.helpText)

                TextField("Executable / wrapper", text: deformableExecutableBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .help("Absolute path, or a command name available on PATH. ANTs defaults to antsRegistration.")

                if vm.petMRDeformableRegistration.backend != .antsSyN {
                    TextField("Model path", text: deformableModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .help("Optional model weights/path passed to --model for SynthMorph, VoxelMorph, or custom wrappers.")
                }

                TextField("Extra arguments", text: deformableExtraArgumentsBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                HStack {
                    Text("Timeout")
                    Slider(value: deformableTimeoutBinding, in: 60...7200, step: 60)
                    Text("\(Int(vm.petMRDeformableRegistration.timeoutSeconds))s")
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                }
            }

            Text(vm.petMRDeformableRegistration.readinessMessage)
                .font(.caption)
                .foregroundColor(vm.petMRDeformableRegistration.isExternalConfigured ||
                                 !vm.petMRDeformableRegistration.backend.needsExternalRunner ? .secondary : .orange)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(TracerTheme.hairline, lineWidth: 1)
        )
        .cornerRadius(6)
    }

    private var deformableBackendBinding: Binding<PETMRDeformableBackend> {
        Binding(
            get: { vm.petMRDeformableRegistration.backend },
            set: { backend in
                var next = vm.petMRDeformableRegistration
                next.backend = backend
                if next.executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    next.executablePath = backend.defaultExecutableName
                }
                vm.setPETMRDeformableRegistration(next)
            }
        )
    }

    private var deformableExecutableBinding: Binding<String> {
        Binding(
            get: { vm.petMRDeformableRegistration.executablePath },
            set: { value in
                var next = vm.petMRDeformableRegistration
                next.executablePath = value
                vm.setPETMRDeformableRegistration(next)
            }
        )
    }

    private var deformableMetricBinding: Binding<PETMRRegistrationMetricPreset> {
        Binding(
            get: { vm.petMRDeformableRegistration.metricPreset },
            set: { value in
                var next = vm.petMRDeformableRegistration
                next.metricPreset = value
                vm.setPETMRDeformableRegistration(next)
            }
        )
    }

    private var deformableModelBinding: Binding<String> {
        Binding(
            get: { vm.petMRDeformableRegistration.modelPath },
            set: { value in
                var next = vm.petMRDeformableRegistration
                next.modelPath = value
                vm.setPETMRDeformableRegistration(next)
            }
        )
    }

    private var deformableExtraArgumentsBinding: Binding<String> {
        Binding(
            get: { vm.petMRDeformableRegistration.extraArguments },
            set: { value in
                var next = vm.petMRDeformableRegistration
                next.extraArguments = value
                vm.setPETMRDeformableRegistration(next)
            }
        )
    }

    private var deformableTimeoutBinding: Binding<Double> {
        Binding(
            get: { vm.petMRDeformableRegistration.timeoutSeconds },
            set: { value in
                var next = vm.petMRDeformableRegistration
                next.timeoutSeconds = value
                vm.setPETMRDeformableRegistration(next)
            }
        )
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

    private var mrSelection: Binding<UUID?> {
        Binding(
            get: { selectedMRID ?? vm.loadedMRVolumes.sorted(by: mrSort).first?.id },
            set: { selectedMRID = $0 }
        )
    }

    private var selectedCTVolume: ImageVolume? {
        let id = selectedCTID ?? vm.loadedCTVolumes.first?.id
        return vm.loadedCTVolumes.first { $0.id == id }
    }

    private var selectedMRVolume: ImageVolume? {
        let id = selectedMRID ?? vm.loadedMRVolumes.sorted(by: mrSort).first?.id
        return vm.loadedMRVolumes.first { $0.id == id }
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

    private func mrVolumeLabel(_ volume: ImageVolume) -> String {
        "\(MRSequenceRole.role(for: volume).shortName) · \(volumeLabel(volume))"
    }

    private func mrSort(_ lhs: ImageVolume, _ rhs: ImageVolume) -> Bool {
        let lhsRole = MRSequenceRole.role(for: lhs)
        let rhsRole = MRSequenceRole.role(for: rhs)
        let lhsRank = mrRank(lhsRole)
        let rhsRank = mrRank(rhsRole)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.seriesDescription.localizedStandardCompare(rhs.seriesDescription) == .orderedAscending
    }

    private func mrRank(_ role: MRSequenceRole) -> Int {
        switch role {
        case .t1: return 0
        case .t2: return 1
        case .flair: return 2
        case .dwi: return 3
        case .adc: return 4
        case .postContrast: return 5
        case .other: return 10
        }
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

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Spherical ROI")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(String(format: "r %.1f mm", vm.suvSphereRadiusMM))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Slider(value: $vm.suvSphereRadiusMM, in: 2...30, step: 0.5)
                    .help("3D spherical ROI radius. PET/fusion reports SUV; CT reports HU.")

                HStack(spacing: 6) {
                    Button {
                        vm.setSUVSphereRadiusMM(6.2)
                    } label: {
                        Text("1 mL")
                    }
                    .controlSize(.small)
                    .help("Approximate PERCIST-style 1 mL sphere")

                    Button {
                        vm.setActiveViewerTool(.suvSphere)
                    } label: {
                        Label("Place", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        if !vm.suvROIMeasurements.isEmpty {
                            vm.clearSUVROIMeasurements()
                        }
                        if !vm.intensityROIMeasurements.isEmpty {
                            vm.clearIntensityROIMeasurements()
                        }
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(vm.suvROIMeasurements.isEmpty && vm.intensityROIMeasurements.isEmpty)
                }

                if let roi = vm.lastSUVROIMeasurement {
                    ControlStatRow("ROI", roi.sourceDescription)
                    ControlStatRow("Radius", String(format: "%.1f mm", roi.radiusMM))
                    ControlStatRow("Volume", String(format: "%.3f mL", roi.volumeML))
                    ControlStatRow("SUVmax", String(format: "%.3f", roi.suvMax))
                    ControlStatRow("SUVmean", String(format: "%.3f", roi.suvMean))
                    ControlStatRow("SUVsd", String(format: "%.3f", roi.suvStd))
                }

                if let roi = vm.lastIntensityROIMeasurement {
                    ControlStatRow("Intensity ROI", roi.sourceDescription)
                    ControlStatRow("Radius", String(format: "%.1f mm", roi.radiusMM))
                    ControlStatRow("Volume", String(format: "%.3f mL", roi.volumeML))
                    ControlStatRow("\(roi.unit) max", String(format: "%.2f", roi.valueMax))
                    ControlStatRow("\(roi.unit) mean", String(format: "%.2f", roi.valueMean))
                    ControlStatRow("\(roi.unit) sd", String(format: "%.2f", roi.valueStd))
                }
            }

            if let report = vm.lastVolumeMeasurementReport,
               report.source == .petSUV,
               report.voxelCount > 0 {
                Divider()
                Text("Active Label: \(report.className)")
                    .font(.system(size: 11, weight: .semibold))
                ControlStatRow("Volume", String(format: "%.2f mL", report.volumeML))
                if let suvMax = report.suvMax {
                    ControlStatRow("SUVmax", String(format: "%.3f", suvMax))
                }
                if let suvMean = report.suvMean {
                    ControlStatRow("SUVmean", String(format: "%.3f", suvMean))
                }
                if let tlg = report.tlg {
                    ControlStatRow("TLG", String(format: "%.1f", tlg))
                }
            } else if vm.labeling.activeLabelMap != nil {
                Button {
                    vm.startActiveVolumeMeasurement(
                        method: .activeLabel,
                        thresholdSummary: "Active PET label",
                        preferPET: true
                    )
                } label: {
                    Label("Measure Active PET Label", systemImage: "flame")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.isVolumeOperationRunning)
            }

            Divider()
            StudySessionPanel()
        }
    }
}

private struct StudySessionPanel: View {
    @EnvironmentObject var vm: ViewerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Study Sessions")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let active = vm.activeStudySession {
                    Text(active.name)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 6) {
                Button {
                    vm.saveCurrentStudySession()
                } label: {
                    Label("Save", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.currentVolume == nil)

                Button {
                    vm.newStudyMeasurementSession()
                } label: {
                    Label("New", systemImage: "plus.rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.currentVolume == nil)
            }

            if vm.studySessions.isEmpty {
                Text("Save a session to reopen measurements, ROIs, volume reports, and label metadata with this study.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(vm.studySessions) { session in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { session.visible },
                                set: { vm.setStudySessionVisibility(id: session.id, visible: $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .help(session.visible ? "Hide this session overlay" : "Show this session overlay")

                            Button {
                                vm.openStudySession(id: session.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: vm.activeStudySessionID == session.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(vm.activeStudySessionID == session.id ? TracerTheme.accent : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(session.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                        Text(session.summary)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button(role: .destructive) {
                                    vm.deleteStudySession(id: session.id)
                                } label: {
                                    Label("Delete Session", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 24)
                        }
                        .padding(6)
                        .background(vm.activeStudySessionID == session.id ? TracerTheme.accent.opacity(0.10) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
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

            Toggle("Invert Colors", isOn: Binding(
                get: { vm.invertColors },
                set: { vm.setInvertColors($0) }
            ))
                .help("Useful for MR or X-ray inversion")

            Toggle("Invert Fused PET", isOn: Binding(
                get: { vm.invertPETImages },
                set: { vm.setInvertPETImages($0) }
            ))
                .help("Reverses PET color mapping in fused panes without changing PET-only or MIP panes.")

            Toggle("Invert PET-only Images", isOn: Binding(
                get: { vm.invertPETOnlyImages },
                set: { vm.setInvertPETOnlyImages($0) }
            ))
                .help("Reverses PET-only color mapping without changing fused PET or MIP panes.")

            Toggle("Invert CT Images", isOn: Binding(
                get: { vm.invertCTImages },
                set: { vm.setInvertCTImages($0) }
            ))
                .help("Reverses CT-only panes and fused CT base images without changing PET coloring.")

            Toggle("Correct A/P Display Flip", isOn: Binding(
                get: { vm.correctAnteriorPosteriorDisplay },
                set: { vm.setCorrectAnteriorPosteriorDisplay($0) }
            ))
                .help("Swaps the displayed anterior/posterior axis for studies that load reversed. This affects display, hover sampling, measurements, PET overlay, and labels together.")

            Toggle("Correct R/L Display Flip", isOn: Binding(
                get: { vm.correctRightLeftDisplay },
                set: { vm.setCorrectRightLeftDisplay($0) }
            ))
                .help("Swaps the displayed right/left axis globally.")

            Divider()

            Text("Zoom / Pan")
                .font(.subheadline)

            Toggle("Link Zoom + Pan Across Panes", isOn: Binding(
                get: { vm.linkZoomPanAcrossPanes },
                set: { vm.setLinkZoomPanAcrossPanes($0) }
            ))
                .help("When enabled, zooming or panning one viewport applies the same transform to every linked hanging pane.")

            HStack {
                Button {
                    vm.resetAllViewportTransforms()
                } label: {
                    Label("Reset All Views", systemImage: "rectangle.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            Text("Active Tool")
                .font(.subheadline)
            ResponsivePicker("Active Tool", selection: Binding(
                get: { vm.activeTool },
                set: { vm.setActiveViewerTool($0) }
            ), menuBreakpoint: 300) {
                ForEach(ViewerTool.allCases) { t in
                    Label(t.displayName, systemImage: t.systemImage)
                        .tag(t)
                }
            }

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
        case .suvSphere: return "Tap PET/fusion for SUV or CT/MR for intensity ROI"
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
                Divider()
                InfoRow(label: "Slice cache", value: vm.sliceRenderWarmupStatus)
                InfoRow(label: "Cache hits", value: "\(vm.sliceRenderCacheHitCount)")
                InfoRow(label: "Cache misses", value: "\(vm.sliceRenderCacheMissCount)")
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
