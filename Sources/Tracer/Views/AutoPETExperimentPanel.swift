import SwiftUI

public struct AutoPETExperimentPanel: View {
    @ObservedObject public var viewer: ViewerViewModel
    @ObservedObject public var autoPET: AutoPETVExperimentViewModel

    public init(viewer: ViewerViewModel,
                autoPET: AutoPETVExperimentViewModel) {
        self.viewer = viewer
        self.autoPET = autoPET
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            experimentSection
            Divider()
            caseSection
            Divider()
            actionRow
            statusLine
        }
        .padding(14)
        .frame(minWidth: 560)
        .onAppear {
            if autoPET.drafts.isEmpty {
                autoPET.refresh(from: viewer)
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "rectangle.3.group.bubble.left")
                .foregroundColor(.accentColor)
            Text("AutoPET V Experiments")
                .font(.headline)
            Spacer()
            if autoPET.isRunning {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var experimentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Experiment name", text: $autoPET.experiment.name)
                    .textFieldStyle(.roundedBorder)
                TextField("Dataset ID", text: $autoPET.experiment.datasetID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
            }

            HStack {
                Picker("Prompt", selection: $autoPET.experiment.promptEncoding) {
                    ForEach(AutoPETVExperimentConfig.PromptEncoding.allCases, id: \.self) { encoding in
                        Text(encoding.rawValue.uppercased()).tag(encoding)
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 6) {
                    Text("Distance")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Slider(value: $autoPET.experiment.promptDistanceMM, in: 5...80, step: 5)
                    Text("\(Int(autoPET.experiment.promptDistanceMM)) mm")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
            }

            HStack {
                Stepper("Steps \(autoPET.experiment.maxInteractionSteps)",
                        value: $autoPET.experiment.maxInteractionSteps,
                        in: 1...8)
                Stepper("FG \(autoPET.experiment.maxForegroundScribblesPerStep)",
                        value: $autoPET.experiment.maxForegroundScribblesPerStep,
                        in: 0...12)
                Stepper("BG \(autoPET.experiment.maxBackgroundScribblesPerStep)",
                        value: $autoPET.experiment.maxBackgroundScribblesPerStep,
                        in: 0...12)
            }
            .font(.system(size: 11))

            HStack {
                TextField("Config", text: $autoPET.experiment.nnunetConfiguration)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("Folds", text: foldsBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("Remote root", text: $autoPET.experiment.remoteExperimentRoot)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Use remote dataset root instead of staging local viewer cases",
                   isOn: $autoPET.experiment.useSparkDatasetRoot)
                .font(.system(size: 11, weight: .medium))

            if autoPET.experiment.useSparkDatasetRoot {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Remote dataset root", text: $autoPET.experiment.sparkDatasetRoot)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model env file", text: $autoPET.experiment.sparkModelEnvironmentFile)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Container mount", text: $autoPET.experiment.sparkContainerDatasetMount)
                            .textFieldStyle(.roundedBorder)
                        Stepper("Limit \(autoPET.experiment.sparkCaseLimit == 0 ? "all" : "\(autoPET.experiment.sparkCaseLimit)")",
                                value: $autoPET.experiment.sparkCaseLimit,
                                in: 0...10_000,
                                step: 10)
                            .font(.system(size: 11))
                    }
                    HStack(spacing: 6) {
                        Text("Validation")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Slider(value: $autoPET.experiment.sparkValidationFraction, in: 0.05...0.5, step: 0.05)
                        Text("\(Int(autoPET.experiment.sparkValidationFraction * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var caseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cases")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(caseCountSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                if !autoPET.experiment.useSparkDatasetRoot {
                    Button {
                        autoPET.refresh(from: viewer)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if autoPET.experiment.useSparkDatasetRoot {
                ContentUnavailableView("Remote dataset mode", systemImage: "bolt.horizontal")
                    .frame(minHeight: 160)
            } else if autoPET.drafts.isEmpty {
                ContentUnavailableView("No PET/CT cases", systemImage: "tray")
                    .frame(minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(autoPET.drafts) { draft in
                            caseRow(draft)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(minHeight: 220, maxHeight: 360)
            }
        }
    }

    private func caseRow(_ draft: AutoPETVManifestBuilder.DraftCase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Toggle("", isOn: Binding(
                    get: { draft.include },
                    set: { autoPET.setIncluded(draft.id, include: $0) }
                ))
                .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.caseID)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(caseSubtitle(draft))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { draft.split },
                    set: { autoPET.setSplit(draft.id, split: $0) }
                )) {
                    ForEach(AutoPETVCaseManifestEntry.Split.allCases, id: \.self) { split in
                        Text(split.rawValue).tag(split)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            HStack {
                TextField("Tracer", text: Binding(
                    get: { draft.tracer },
                    set: { autoPET.setTracer(draft.id, tracer: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                TextField("Center", text: Binding(
                    get: { draft.center },
                    set: { autoPET.setCenter(draft.id, center: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                Label(draft.labelDescription, systemImage: draft.labelMapID == nil ? "tag.slash" : "tag.fill")
                    .font(.system(size: 10))
                    .foregroundColor(draft.labelMapID == nil ? .orange : .secondary)
                Spacer()
            }

            if !draft.warnings.isEmpty {
                Text(draft.warnings.joined(separator: "  |  "))
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var actionRow: some View {
        HStack {
            Button {
                Task { await autoPET.buildPackage(from: viewer) }
            } label: {
                Label("Build Package", systemImage: "shippingbox")
            }
            .disabled(autoPET.isRunning || !autoPET.canBuildOrRun)

            Button {
                Task { await autoPET.prepareOnDGX(from: viewer) }
            } label: {
                Label("Prepare Only", systemImage: "checklist")
            }
            .disabled(autoPET.isRunning || !autoPET.canBuildOrRun)

            Button {
                Task { await autoPET.launchTraining(from: viewer) }
            } label: {
                Label("Train Remotely", systemImage: "bolt.fill")
            }
            .disabled(autoPET.isRunning || !autoPET.canBuildOrRun)

            Button {
                Task { await autoPET.launchValidation(from: viewer) }
            } label: {
                Label("Validate Remotely", systemImage: "checkmark.seal")
            }
            .disabled(autoPET.isRunning || !autoPET.canBuildOrRun)

            Spacer()
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(autoPET.statusMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let package = autoPET.lastPackage {
                Text(package.localURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            } else if let run = autoPET.lastRun, !run.localPackagePath.isEmpty {
                Text(run.localPackagePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var foldsBinding: Binding<String> {
        Binding(
            get: { autoPET.experiment.folds.joined(separator: ",") },
            set: { value in
                let folds = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                autoPET.experiment.folds = folds.isEmpty ? ["0"] : folds
            }
        )
    }

    private var caseCountSummary: String {
        if autoPET.experiment.useSparkDatasetRoot {
            let limit = autoPET.experiment.sparkCaseLimit == 0
                ? "all"
                : "\(autoPET.experiment.sparkCaseLimit)"
            return "Remote dataset  |  cases \(limit)  |  validation \(Int(autoPET.experiment.sparkValidationFraction * 100))%"
        }
        return "\(autoPET.selectedCaseCount) selected  |  train \(autoPET.selectedTrainingCount)  |  validation \(autoPET.selectedValidationCount)"
    }

    private func caseSubtitle(_ draft: AutoPETVManifestBuilder.DraftCase) -> String {
        [
            draft.patientID.isEmpty ? nil : draft.patientID,
            draft.studyDescription.isEmpty ? nil : draft.studyDescription,
            draft.ctDescription,
            draft.petDescription
        ]
        .compactMap { $0 }
        .joined(separator: "  |  ")
    }
}
