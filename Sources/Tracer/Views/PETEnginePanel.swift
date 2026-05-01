import SwiftUI

/// Unified entry point for the app's PET-specific AI capabilities. Users
/// pick an engine (AutoPET II, LesionTracer, LesionLocator, MedSAM2, TMTV,
/// or physiological-uptake filter) and the panel reveals only the options
/// relevant to that engine.
public struct PETEnginePanel: View {
    @ObservedObject public var viewer: ViewerViewModel
    @ObservedObject public var nnunet: NNUnetViewModel
    @ObservedObject public var pet: PETEngineViewModel
    @ObservedObject public var labeling: LabelingViewModel

    public init(viewer: ViewerViewModel,
                nnunet: NNUnetViewModel,
                pet: PETEngineViewModel,
                labeling: LabelingViewModel) {
        self.viewer = viewer
        self.nnunet = nnunet
        self.pet = pet
        self.labeling = labeling
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            enginePicker
            Divider()
            engineDetails
            Divider()
            options
            Spacer()
            runRow
            if let report = pet.lastReport {
                Divider()
                tmtvReport(report)
            }
            statusLine
        }
        .padding(14)
        .frame(minWidth: 440)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "flame.fill").foregroundColor(.accentColor)
            Text("PET Engine")
                .font(.headline)
            Spacer()
            if pet.isRunning {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Path")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Picker("", selection: $pet.selectedEngine) {
                ForEach(PETEngineViewModel.Engine.allCases) { engine in
                    Label(engine.displayName, systemImage: engine.systemImage)
                        .tag(engine)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var engineDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pet.selectedEngine.description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var options: some View {
        switch pet.selectedEngine {
        case .autoPETII, .lesionTracer, .lesionLocator:
            nnunetChannelsSection
        case .medSAM2:
            medSAMSection
        case .tmtv:
            tmtvOptions
        case .totalSegPrefilter:
            prefilterOptions
        }
    }

    // MARK: - nnU-Net channels

    private var nnunetChannelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Channels")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Channel 0 = CT  ·  Channel 1 = PET (SUV-scaled)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Picker("Auxiliary volume", selection: Binding(
                get: { pet.auxiliaryVolumeID ?? "" },
                set: { pet.auxiliaryVolumeID = $0.isEmpty ? nil : $0 }
            )) {
                Text("Auto (use fusion overlay / first complementary volume)")
                    .tag("")
                ForEach(auxiliaryCandidates, id: \.sessionIdentity) { volume in
                    Text(formatVolumeOption(volume))
                        .tag(volume.sessionIdentity)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Picker("Profile", selection: $pet.segmentationProfile) {
                ForEach(PETEngineViewModel.SegmentationProfile.allCases) { profile in
                    Label(profile.displayName, systemImage: profile.systemImage)
                        .tag(profile)
                }
            }
            .pickerStyle(.segmented)

            if pet.segmentationProfile.applySUVAttention {
                HStack {
                    Text("SUV floor")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(value: $pet.suvAttentionThreshold, in: 0...20, step: 0.1)
                    Text(String(format: "%.1f", pet.suvAttentionThreshold))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 34, alignment: .trailing)
                }
                HStack {
                    Text("Min mL")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(value: $pet.minimumLesionVolumeML, in: 0...10, step: 0.1)
                    Text(String(format: "%.1f", pet.minimumLesionVolumeML))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 34, alignment: .trailing)
                }
            }

            if let entry = catalogEntry(for: pet.selectedEngine) {
                Text("Model: \(entry.displayName) · \(entry.datasetID)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                if let model = nnunet.boundExternalNNUnetModel(for: entry) {
                    Label("External: \(model.displayName)",
                          systemImage: "link")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if pet.selectedEngine == .lesionTracer, nnunet.mode == .dgxRemote {
                    Label("DGX Segmentator Docker backend active",
                          systemImage: "shippingbox.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Worker image: \(RemoteLesionTracerRunner.Configuration(dgx: nnunet.dgxConfig).workerImage)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if entry.id == "LesionLocator-AutoPETIV" {
                    Label("Experimental — weights from AutoPET IV are still rolling out.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                }
            }
        }
    }

    // MARK: - MedSAM2

    private var medSAMSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MedSAM2 model + box prompt")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack {
                TextField(".mlpackage path", text: $pet.medSAMModelPath)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                #if canImport(AppKit)
                Button("Browse…") { pet.pickMedSAMModel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                #endif
            }
            TextField("Box on current axial slice — \"x,y,w,h\" in pixels",
                      text: $pet.medSAMBoxString)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            Text("Tip: for the cleanest result, keep the box tight around the lesion.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - TMTV

    private var tmtvOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reads the currently-active label map and the loaded PET volume (or the PET overlay when a CT is primary). Connected components are scored separately.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func tmtvReport(_ report: PETQuantification.Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TMTV report")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                metric("TMTV",
                       value: String(format: "%.1f mL", report.totalMetabolicTumorVolumeML))
                metric("TLG",
                       value: String(format: "%.1f", report.totalLesionGlycolysis))
                metric("SUVmax",
                       value: String(format: "%.2f", report.maxSUV))
                metric("Lesions",
                       value: "\(report.lesionCount)")
            }

            if !report.lesions.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(report.lesions.prefix(6))) { lesion in
                            Text(String(format: "%@ · %.1f mL · SUVmax %.2f",
                                        lesion.className,
                                        lesion.volumeML,
                                        lesion.suvMax))
                                .font(.system(size: 10, design: .monospaced))
                        }
                        if report.lesions.count > 6 {
                            Text("… +\(report.lesions.count - 6) more")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
    }

    // MARK: - Prefilter

    private var prefilterOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suppress these organs from the active PET lesion mask:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(pet.suppressedOrganNames.joined(separator: ", "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The CT will be resolved as either the fusion overlay or the first loaded CT volume; TotalSegmentator runs first, then its brain/bladder/heart/kidney/liver mask is subtracted from the active PET label.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var runRow: some View {
        HStack {
            Button {
                Task {
                    _ = await pet.run(viewer: viewer,
                                      nnunet: nnunet,
                                      labeling: labeling)
                }
            } label: {
                Label("Run \(pet.selectedEngine.displayName)",
                      systemImage: "play.fill")
            }
            .disabled(pet.isRunning || !canRun)
            Spacer()
        }
    }

    private var statusLine: some View {
        Text(pet.statusMessage)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Availability

    private var auxiliaryCandidates: [ImageVolume] {
        viewer.activeSessionVolumes
    }

    private var canRun: Bool {
        switch pet.selectedEngine {
        case .autoPETII, .lesionTracer, .lesionLocator:
            return viewer.currentVolume != nil
        case .medSAM2:
            return viewer.currentVolume != nil
                && !pet.medSAMModelPath.isEmpty
                && !pet.medSAMBoxString.isEmpty
        case .tmtv:
            return labeling.activeLabelMap != nil
        case .totalSegPrefilter:
            return labeling.activeLabelMap != nil
                && !viewer.loadedCTVolumes.isEmpty
        }
    }

    private func catalogEntry(for engine: PETEngineViewModel.Engine) -> NNUnetCatalog.Entry? {
        switch engine {
        case .autoPETII:        return NNUnetCatalog.autoPETII
        case .lesionTracer:     return NNUnetCatalog.lesionTracer
        case .lesionLocator:    return NNUnetCatalog.lesionLocator
        default:                return nil
        }
    }

    private func formatVolumeOption(_ volume: ImageVolume) -> String {
        let modality = Modality.normalize(volume.modality).displayName
        let name = volume.seriesDescription.isEmpty ? "Series" : volume.seriesDescription
        return "\(modality) · \(name)"
    }
}
