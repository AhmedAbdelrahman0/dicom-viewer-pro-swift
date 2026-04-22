import SwiftUI

struct AssistantPanel: View {
    @EnvironmentObject var vm: ViewerViewModel
    @EnvironmentObject var monai: MONAILabelViewModel
    @EnvironmentObject var nnunet: NNUnetViewModel
    @State private var provider: AssistantCLIProvider = .local
    @State private var draft: String = ""
    @State private var messages: [AssistantChatMessage] = [
        AssistantChatMessage(role: .assistant, text: "Ready for workstation commands.")
    ]
    @State private var isRunning = false

    private let runner = AssistantCLIRunner()

    var body: some View {
        VStack(spacing: 0) {
            providerStrip
            Divider()
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            quickCommands
            Divider()
            composer
                .background(Color(.displayP3, white: 0.09))
        }
    }

    private var providerStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Assistant", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Picker("Provider", selection: $provider) {
                ForEach(AssistantCLIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            Text(runner.availabilityText(for: provider))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(runner.isAvailable(provider) ? .secondary : .orange)
                .lineLimit(1)
        }
        .padding(12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(minHeight: 180)
    }

    private var quickCommands: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Command Deck")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                QuickCommandButton(title: "Lung", icon: "lungs") {
                    submit("Apply lung window")
                }
                QuickCommandButton(title: "Bone", icon: "figure.walk") {
                    submit("Show bone window")
                }
                QuickCommandButton(title: "Auto W/L", icon: "wand.and.stars") {
                    submit("Auto window level")
                }
                QuickCommandButton(title: "Center", icon: "scope") {
                    submit("Center slices")
                }
                QuickCommandButton(title: "Anatomy", icon: "list.bullet.rectangle") {
                    submit("Create label map and load TotalSegmentator full anatomy preset")
                }
                QuickCommandButton(title: "SUV 2.5", icon: "flame") {
                    submit("Threshold SUV 2.5")
                }
                QuickCommandButton(title: "PET Lesion", icon: "flame.fill") {
                    submit("Segment FDG avid disease on PET/CT with the best lesion model")
                }
                QuickCommandButton(title: "RT GTV", icon: "scope") {
                    submit("Contour gross tumor volume for radiotherapy")
                }
                QuickCommandButton(title: "Liver", icon: "target") {
                    submit("Select and view liver")
                }
                QuickCommandButton(title: "Measure", icon: "ruler") {
                    submit("Use distance measurement tool")
                }
            }
        }
        .padding(12)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask or command the viewer", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit {
                    submit(draft)
                }

            Button {
                submit(draft)
            } label: {
                Image(systemName: "paperplane.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)
        }
        .padding(12)
    }

    private func submit(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isRunning else { return }

        draft = ""
        messages.append(AssistantChatMessage(role: .user, text: request))

        let currentModality = vm.currentVolume.map { Modality.normalize($0.modality) }
        let availableMONAIModels = monai.info?.modelNames ?? []
        let plan = SegmentationRAG.plan(
            for: request,
            currentModality: currentModality,
            availableMONAIModels: availableMONAIModels
        )
        let report = vm.performAssistantCommand(request)
        var summary = report.summary

        // MONAI Label routing — choose a model name on the connected server.
        var kickOffMONAI = false
        if let plan, monai.isConnected {
            if let selectedModel = monai.selectBestModel(for: plan) {
                summary += "\nSelected MONAI Label model \(selectedModel)."
                kickOffMONAI = (plan.preferredEngine != .nnUNet)
            } else if !availableMONAIModels.isEmpty {
                summary += "\nNo connected MONAI model name matched this route; local labels/tool were prepared."
            }
        }

        // nnU-Net routing — resolve the catalog entry and (if possible) run it.
        var kickOffNNUnet = false
        if let plan, plan.preferredEngine == .nnUNet {
            if let entry = nnunet.selectBestEntry(for: plan) {
                summary += "\nSelected nnU-Net model \(entry.displayName) (\(entry.datasetID))."
                if entry.multiChannel {
                    summary += "\nThis model needs multiple input channels; one-click inference is blocked until channel pairing is wired."
                } else if nnunet.mode == .subprocess, !nnunet.isSubprocessAvailable {
                    summary += "\nInstall nnunetv2 or point the nnU-Net panel at a CoreML package before running inference."
                } else {
                    kickOffNNUnet = true
                }
            } else if let entryID = plan.nnunetEntryID {
                // The planner cited an entry id but the catalog couldn't resolve it.
                summary += "\nRouted to nnU-Net \(entryID), but that entry is not in the local catalog — open the nnU-Net panel to pick a model manually."
            }
        }

        if report.didApplyActions || !report.warnings.isEmpty || provider == .local {
            messages.append(AssistantChatMessage(role: .assistant, text: summary))
        }

        // End-to-end execution: kick off the selected engine asynchronously.
        // Skips if both are eligible to avoid running two models against the
        // same volume in parallel; nnU-Net wins when it was explicitly routed.
        if kickOffNNUnet {
            runNNUnetFromAssistant()
        } else if kickOffMONAI {
            runMONAIFromAssistant()
        }

        guard provider != .local else { return }

        isRunning = true
        let context = [
            vm.assistantContextSummary,
            SegmentationRAG.assistantContext(
                for: request,
                currentModality: currentModality,
                availableMONAIModels: availableMONAIModels
            )
        ].joined(separator: "\n\n")
        let imageURLs = vm.exportAssistantViewportSnapshots()
        let selectedProvider = provider

        Task {
            do {
                let reply = try await runner.run(
                    provider: selectedProvider,
                    prompt: request,
                    context: context,
                    imageURLs: imageURLs
                )
                await MainActor.run {
                    messages.append(AssistantChatMessage(role: .assistant, text: reply))
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    messages.append(AssistantChatMessage(role: .assistant, text: "CLI unavailable: \(error.localizedDescription)"))
                    isRunning = false
                }
            }
        }
    }

    /// Kick off the nnU-Net runner selected by the RAG planner on the current
    /// volume. Reports success / failure / unavailability back into the chat
    /// transcript so the user has closure on what happened.
    private func runNNUnetFromAssistant() {
        guard let volume = vm.currentVolume else {
            messages.append(AssistantChatMessage(
                role: .assistant,
                text: "No volume is loaded; cannot run nnU-Net."
            ))
            return
        }
        let entryName = nnunet.selectedEntry?.displayName ?? "nnU-Net model"
        messages.append(AssistantChatMessage(
            role: .assistant,
            text: "Running \(entryName) on the current volume…"
        ))
        Task { @MainActor in
            if let labelMap = await nnunet.run(on: volume, labeling: vm.labeling) {
                messages.append(AssistantChatMessage(
                    role: .assistant,
                    text: "✓ \(entryName): \(labelMap.classes.count) classes produced. Open the Labels tab to edit."
                ))
            } else {
                messages.append(AssistantChatMessage(
                    role: .assistant,
                    text: "nnU-Net didn't produce a label: \(nnunet.statusMessage)"
                ))
            }
        }
    }

    /// Kick off the MONAI Label runner on the current volume. Mirrors
    /// `runNNUnetFromAssistant` so both engines report outcomes the same way.
    private func runMONAIFromAssistant() {
        guard let volume = vm.currentVolume else {
            messages.append(AssistantChatMessage(
                role: .assistant,
                text: "No volume is loaded; cannot run MONAI Label."
            ))
            return
        }
        let modelName = monai.selectedModel.isEmpty ? "MONAI Label model" : monai.selectedModel
        messages.append(AssistantChatMessage(
            role: .assistant,
            text: "Running MONAI Label \(modelName) on the current volume…"
        ))
        Task { @MainActor in
            if let labelMap = await monai.runInference(on: volume, in: vm.labeling) {
                messages.append(AssistantChatMessage(
                    role: .assistant,
                    text: "✓ MONAI Label \(modelName): \(labelMap.classes.count) classes produced."
                ))
            } else {
                messages.append(AssistantChatMessage(
                    role: .assistant,
                    text: "MONAI Label inference didn't return a mask: \(monai.statusMessage)"
                ))
            }
        }
    }
}

private struct AssistantChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
}

private struct MessageRow: View {
    let message: AssistantChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 28)
            }

            Text(message.text)
                .font(.system(size: 12))
                .foregroundColor(message.role == .user ? .white : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 260, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .assistant {
                Spacer(minLength: 28)
            }
        }
    }

    private var background: some ShapeStyle {
        message.role == .user ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.12))
    }
}

private struct QuickCommandButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
