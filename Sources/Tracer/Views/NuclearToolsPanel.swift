import SwiftUI

public struct NuclearToolsPanel: View {
    @ObservedObject public var viewer: ViewerViewModel
    @ObservedObject public var reconstruction: NuclearReconstructionViewModel
    @ObservedObject public var syntheticCT: SyntheticCTViewModel
    @ObservedObject public var dosimetry: Lu177DosimetryViewModel

    @State private var tab: NuclearToolTab = .reconstruction
    @State private var selectedTimePointIDs: Set<UUID> = []
    @State private var hoursByVolumeID: [UUID: Double] = [:]
    @State private var spectInputUnit: Lu177ActivityInputUnit = .activityConcentrationBqPerML
    @State private var calibrationFactor: Double = 1
    @State private var backgroundCounts: Double = 0
    @State private var tailModel: Lu177TailModel = .monoExponentialFitWithPhysicalFallback
    @State private var doseMethod: Lu177DoseCalculationMethod = .localDeposition
    @State private var physicalHalfLifeHours: Double = 159.53
    @State private var useCTDensity = true
    @State private var useActiveLabel = true
    @State private var historiesPerVoxel: Int = 64
    @State private var maxHistories: Int = 500_000
    @State private var dosimetrySetupError: String?

    public init(viewer: ViewerViewModel,
                reconstruction: NuclearReconstructionViewModel,
                syntheticCT: SyntheticCTViewModel,
                dosimetry: Lu177DosimetryViewModel) {
        self.viewer = viewer
        self.reconstruction = reconstruction
        self.syntheticCT = syntheticCT
        self.dosimetry = dosimetry
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ResponsivePicker("Nuclear tool", selection: $tab, menuBreakpoint: 420) {
                ForEach(NuclearToolTab.allCases) { item in
                    Label(item.title, systemImage: item.systemImage).tag(item)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Rectangle().fill(TracerTheme.hairline).frame(height: 1)

            ScrollView {
                SwiftUI.Group {
                    switch tab {
                    case .reconstruction:
                        reconstructionPanel
                    case .syntheticCT:
                        syntheticCTPanel
                    case .dosimetry:
                        dosimetryPanel
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: 520)
        .background(TracerTheme.panelBackground)
        .onAppear(perform: seedTimePointSelection)
        .onChange(of: viewer.activeSessionVolumes.count) { _, _ in seedTimePointSelection() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "atom")
                .foregroundColor(TracerTheme.accentBright)
            Text("Nuclear Tools")
                .font(.headline)
            Spacer()
            if reconstruction.isRunning || syntheticCT.isRunning || dosimetry.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
    }

    // MARK: - Reconstruction

    private var reconstructionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Raw Sinogram Reconstruction")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    reconstruction.run(viewer: viewer)
                } label: {
                    Label("Reconstruct", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(reconstruction.isRunning || !reconstruction.canRun)
            }

            HStack {
                TextField("Raw Float32 sinogram", text: $reconstruction.rawSinogramPath)
                    .textFieldStyle(.roundedBorder)
                #if canImport(AppKit)
                Button("Browse...") { reconstruction.pickRawSinogram() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                #endif
            }

            LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 10) {
                Picker("Modality", selection: $reconstruction.modality) {
                    ForEach(NuclearReconstructionModality.allCases, id: \.rawValue) {
                        Text($0.rawValue).tag($0)
                    }
                }
                Picker("Algorithm", selection: $reconstruction.algorithm) {
                    ForEach(ReconstructionAlgorithm.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Endian", selection: $reconstruction.endian) {
                    ForEach(RawFloatEndian.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                NuclearStatRow("Expected", byteCount(reconstruction.expectedByteCount))
            }

            Divider()

            Text("Geometry")
                .font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 10) {
                NuclearIntStepper("Detector bins", value: $reconstruction.detectorCount, range: 2...4096, step: 1)
                NuclearIntStepper("Projections", value: $reconstruction.projectionCount, range: 1...4096, step: 1)
                NuclearNumberField("Detector mm", value: $reconstruction.detectorSpacingMM)
                NuclearNumberField("Radial mm", value: $reconstruction.radialOffsetMM)
                NuclearIntStepper("Image W", value: $reconstruction.imageWidth, range: 8...2048, step: 8)
                NuclearIntStepper("Image H", value: $reconstruction.imageHeight, range: 8...2048, step: 8)
                NuclearNumberField("Pixel mm", value: $reconstruction.pixelSpacingMM)
                NuclearNumberField("Slice mm", value: $reconstruction.sliceThicknessMM)
            }

            if reconstruction.algorithm == .mlem {
                Divider()
                Text("MLEM")
                    .font(.system(size: 12, weight: .semibold))
                LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 10) {
                    NuclearIntStepper("Iterations", value: $reconstruction.iterations, range: 1...200, step: 1)
                    NuclearNumberField("Floor", value: $reconstruction.positivityFloor)
                }
            }

            statusBlock(reconstruction.statusMessage, error: reconstruction.errorMessage)
            if let volume = reconstruction.lastVolume {
                resultVolumeRows(volume)
            }
        }
    }

    // MARK: - Synthetic CT

    private var syntheticCTPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Synthetic CT From PET")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    syntheticCT.run(viewer: viewer)
                } label: {
                    Label("Generate", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(syntheticCT.isRunning
                          || viewer.activePETQuantificationVolume == nil
                          || !syntheticCT.canRunConfiguredMethod)
            }

            if let pet = viewer.activePETQuantificationVolume {
                resultVolumeRows(pet, title: "PET source")
            } else {
                statusBlock("No active PET volume", error: nil)
            }

            Picker("Method", selection: $syntheticCT.method) {
                ForEach(SyntheticCTMethod.allCases, id: \.rawValue) {
                    Text($0.displayName).tag($0)
                }
            }

            TextField("Series description", text: $syntheticCT.seriesDescription)
                .textFieldStyle(.roundedBorder)

            LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 10) {
                NuclearNumberField("Body SUV", value: $syntheticCT.bodySUVThreshold)
                NuclearNumberField("High SUV", value: $syntheticCT.intenseUptakeSUV)
                NuclearNumberField("Air HU", value: $syntheticCT.airHU)
                NuclearNumberField("Soft HU", value: $syntheticCT.softTissueHU)
                NuclearNumberField("Hot HU", value: $syntheticCT.highUptakeHU)
                NuclearIntStepper("Smooth vox", value: $syntheticCT.smoothingRadiusVoxels, range: 0...5, step: 1)
                NuclearNumberField("Min HU", value: $syntheticCT.minimumHU)
                NuclearNumberField("Max HU", value: $syntheticCT.maximumHU)
            }

            if !syntheticCT.canRunConfiguredMethod {
                statusBlock("\(syntheticCT.method.displayName) needs a configured runner.", error: nil)
            }
            statusBlock(syntheticCT.statusMessage, error: syntheticCT.errorMessage)

            if let report = syntheticCT.lastResult?.report {
                Divider()
                Text("Report")
                    .font(.system(size: 12, weight: .semibold))
                NuclearStatRow("Body voxels", "\(report.bodyVoxelCount)")
                NuclearStatRow("HU min/mean/max",
                               String(format: "%.0f / %.0f / %.0f", report.minHU, report.meanHU, report.maxHU))
                if let warning = report.warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Lu-177

    private var dosimetryPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Lu-177 Dosimetry")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    runDosimetry()
                } label: {
                    Label("Compute Dose", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(dosimetry.isRunning || selectedSPECTVolumes.isEmpty)
            }

            timePointList

            Divider()

            LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 10) {
                Picker("Input", selection: $spectInputUnit) {
                    ForEach(Lu177ActivityInputUnit.allCases, id: \.rawValue) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Tail", selection: $tailModel) {
                    ForEach(Lu177TailModel.allCases, id: \.rawValue) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Dose", selection: $doseMethod) {
                    ForEach(Lu177DoseCalculationMethod.allCases, id: \.rawValue) {
                        Text($0.displayName).tag($0)
                    }
                }
                NuclearNumberField("Half-life h", value: $physicalHalfLifeHours)
            }

            if spectInputUnit == .counts {
                LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 10) {
                    NuclearNumberField("Bq/mL/count", value: $calibrationFactor)
                    NuclearNumberField("Background", value: $backgroundCounts)
                }
            }

            if doseMethod == .monteCarloBetaTransport {
                LazyVGrid(columns: twoColumns, alignment: .leading, spacing: 10) {
                    NuclearIntStepper("Hist/voxel", value: $historiesPerVoxel, range: 1...512, step: 1)
                    NuclearIntStepper("Max histories", value: $maxHistories, range: 1_000...10_000_000, step: 10_000)
                }
            }

            Toggle("Use matched CT density map", isOn: $useCTDensity)
                .disabled(viewer.loadedCTVolumes.isEmpty)
            Toggle("Use active labels for VOI / DVH", isOn: $useActiveLabel)
                .disabled(viewer.labeling.activeLabelMap == nil)

            statusBlock(dosimetry.statusMessage, error: dosimetry.errorMessage ?? dosimetrySetupError)

            if let report = dosimetry.result?.report {
                Divider()
                Text("Dose Report")
                    .font(.system(size: 12, weight: .semibold))
                NuclearStatRow("Mode", report.acquisitionMode.displayName)
                NuclearStatRow("Mean / max Gy",
                               String(format: "%.3g / %.3g", report.meanDoseGy, report.maxDoseGy))
                NuclearStatRow("TIA", String(format: "%.3g Bq*h", report.totalTimeIntegratedActivityBqHours))
                if !report.voiSummaries.isEmpty {
                    ForEach(report.voiSummaries.prefix(6)) { summary in
                        NuclearStatRow(summary.className,
                                       String(format: "%.2f mL · %.3g Gy mean", summary.volumeML, summary.meanDoseGy))
                    }
                }
                if !report.warnings.isEmpty {
                    ForEach(report.warnings.prefix(4), id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                cumulativeButtons
            }

            if let cumulative = dosimetry.cumulativeResult {
                Divider()
                Text("Cumulative Therapy")
                    .font(.system(size: 12, weight: .semibold))
                NuclearStatRow("Cycles", "\(cumulative.cycleCount)")
                NuclearStatRow("Mean / max Gy",
                               String(format: "%.3g / %.3g", cumulative.meanDoseGy, cumulative.maxDoseGy))
            }
        }
    }

    private var timePointList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SPECT/NM Time Points")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(selectedSPECTVolumes.count) selected")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if spectCandidates.isEmpty {
                statusBlock("No NM/SPECT volumes loaded.", error: nil)
            } else {
                ForEach(Array(spectCandidates.enumerated()), id: \.element.id) { index, volume in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: selectedBinding(for: volume.id)) {
                            Text(volumeName(volume))
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        HStack {
                            NuclearNumberField("Hours", value: hoursBinding(for: volume.id, defaultValue: Double(index) * 24))
                            Spacer()
                            Text("\(volume.width)x\(volume.height)x\(volume.depth)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var cumulativeButtons: some View {
        HStack {
            Button {
                dosimetry.computeCumulativeTherapy(cycleCount: 4, installInto: viewer)
            } label: {
                Label("4 Cycles", systemImage: "4.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                dosimetry.computeCumulativeTherapy(cycleCount: 6, installInto: viewer)
            } label: {
                Label("6 Cycles", systemImage: "6.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Actions

    private func runDosimetry() {
        do {
            dosimetrySetupError = nil
            let calibration: Lu177SPECTCalibration?
            if spectInputUnit == .counts {
                calibration = try Lu177SPECTCalibration(
                    bqPerMLPerCount: calibrationFactor,
                    backgroundCounts: backgroundCounts
                )
            } else {
                calibration = nil
            }

            let timePoints = try selectedSPECTVolumes.map { volume in
                try Lu177DosimetryTimePoint(
                    activityVolume: volume,
                    hoursPostAdministration: hours(for: volume),
                    inputUnit: spectInputUnit,
                    calibration: calibration
                )
            }

            let monteCarlo = doseMethod == .monteCarloBetaTransport
                ? try Lu177MonteCarloOptions(
                    historiesPerSourceVoxel: historiesPerVoxel,
                    maxTotalHistories: maxHistories
                )
                : nil
            let doseModel = try Lu177DoseModel(
                name: doseMethod == .monteCarloBetaTransport
                    ? "Lu-177 native Monte Carlo"
                    : "Lu-177 local deposition",
                calculationMethod: doseMethod,
                monteCarloOptions: monteCarlo
            )
            let options = try Lu177DosimetryOptions(
                physicalHalfLifeHours: physicalHalfLifeHours,
                tailModel: tailModel,
                doseModel: doseModel
            )
            dosimetry.run(
                timePoints: timePoints,
                ctVolume: useCTDensity ? viewer.loadedCTVolumes.first : nil,
                labelMap: useActiveLabel ? viewer.labeling.activeLabelMap : nil,
                options: options,
                installInto: viewer
            )
        } catch {
            dosimetry.clear()
            dosimetrySetupError = error.localizedDescription
            viewer.statusMessage = "Dosimetry setup failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Data

    private var spectCandidates: [ImageVolume] {
        viewer.activeSessionVolumes.filter { Modality.normalize($0.modality) == .NM }
    }

    private var selectedSPECTVolumes: [ImageVolume] {
        spectCandidates
            .filter { selectedTimePointIDs.contains($0.id) }
            .sorted { lhs, rhs in
                (hoursByVolumeID[lhs.id] ?? 0) < (hoursByVolumeID[rhs.id] ?? 0)
            }
    }

    private func seedTimePointSelection() {
        guard selectedTimePointIDs.isEmpty else { return }
        for (index, volume) in spectCandidates.prefix(3).enumerated() {
            selectedTimePointIDs.insert(volume.id)
            hoursByVolumeID[volume.id] = Double(index) * 24
        }
    }

    private func selectedBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedTimePointIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedTimePointIDs.insert(id)
                    if hoursByVolumeID[id] == nil,
                       let index = spectCandidates.firstIndex(where: { $0.id == id }) {
                        hoursByVolumeID[id] = Double(index) * 24
                    }
                } else {
                    selectedTimePointIDs.remove(id)
                }
            }
        )
    }

    private func hoursBinding(for id: UUID, defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { hoursByVolumeID[id] ?? defaultValue },
            set: { hoursByVolumeID[id] = $0 }
        )
    }

    private func hours(for volume: ImageVolume) -> Double {
        if let value = hoursByVolumeID[volume.id] { return value }
        guard let index = spectCandidates.firstIndex(where: { $0.id == volume.id }) else { return 0 }
        return Double(index) * 24
    }

    private var twoColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    private func statusBlock(_ message: String, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(error == nil ? .secondary : .red)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resultVolumeRows(_ volume: ImageVolume, title: String = "Output") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            NuclearStatRow("Series", volumeName(volume))
            NuclearStatRow("Grid", "\(volume.width)x\(volume.height)x\(volume.depth)")
            NuclearStatRow("Spacing",
                           String(format: "%.2f x %.2f x %.2f mm",
                                  volume.spacing.x, volume.spacing.y, volume.spacing.z))
        }
    }

    private func volumeName(_ volume: ImageVolume) -> String {
        volume.seriesDescription.isEmpty
            ? Modality.normalize(volume.modality).displayName
            : volume.seriesDescription
    }

    private func byteCount(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }
}

private enum NuclearToolTab: String, CaseIterable, Identifiable {
    case reconstruction
    case syntheticCT
    case dosimetry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reconstruction: return "Recon"
        case .syntheticCT: return "sCT"
        case .dosimetry: return "Lu-177"
        }
    }

    var systemImage: String {
        switch self {
        case .reconstruction: return "dot.radiowaves.left.and.right"
        case .syntheticCT: return "square.2.layers.3d"
        case .dosimetry: return "atom"
        }
    }
}

private struct NuclearNumberField: View {
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
        formatter.maximumFractionDigits = 4
        formatter.minimumFractionDigits = 0
        return formatter
    }()
}

private struct NuclearIntStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    init(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(value)")
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .controlSize(.small)
    }
}

private struct NuclearStatRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}
