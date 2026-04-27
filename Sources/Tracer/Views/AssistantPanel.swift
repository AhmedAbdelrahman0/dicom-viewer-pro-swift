import SwiftUI

struct AssistantPanel: View {
    @EnvironmentObject var vm: ViewerViewModel
    @EnvironmentObject var monai: MONAILabelViewModel
    @EnvironmentObject var nnunet: NNUnetViewModel
    @EnvironmentObject var pet: PETEngineViewModel
    @StateObject private var voice = DictationSession()
    @State private var provider: AssistantCLIProvider = .local
    @State private var draft: String = ""
    @State private var messages: [AssistantChatMessage] = [
        AssistantChatMessage(role: .assistant, text: "Ready for workstation commands.")
    ]
    @State private var activeAssistantTasks = 0
    @State private var isSubmittingRequest = false
    @AppStorage("Tracer.Dictation.EngineKind") private var selectedVoiceEngineID: String = DictationEngineKind.appleSpeech.rawValue
    @AppStorage("Tracer.Dictation.MedASR.PythonExecutable") private var medASRPythonExecutable: String = "/usr/bin/env"
    @AppStorage("Tracer.Dictation.MedASR.ScriptPath") private var medASRScriptPath: String = ""
    @AppStorage("Tracer.Dictation.MedASR.ModelIdentifier") private var medASRModelIdentifier: String = GoogleMedASRDictationEngine.defaultModelIdentifier
    @AppStorage("Tracer.Dictation.MedASR.Device") private var medASRDevice: String = GoogleMedASRDictationEngine.defaultDevice
    @AppStorage("Tracer.Dictation.MedASR.Environment") private var medASREnvironment: String = ""

    private let runner = AssistantCLIRunner()
    private var isRunning: Bool { isSubmittingRequest || activeAssistantTasks > 0 }

    var body: some View {
        VStack(spacing: 0) {
            providerStrip
            Rectangle().fill(TracerTheme.hairline).frame(height: 1)
            quickCommands
            Rectangle().fill(TracerTheme.hairline).frame(height: 1)
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(TracerTheme.hairline).frame(height: 1)
            composer
                .background(TracerTheme.panelRaised)
        }
        .background(TracerTheme.panelBackground)
        .tint(TracerTheme.accent)
        .onAppear {
            configureVoiceEngineFromSettings()
            voice.finalUtteranceHandler = { text, confidence in
                handleVoiceCommand(text, confidence: confidence)
                return true
            }
        }
        .onDisappear {
            voice.finalUtteranceHandler = nil
            Task { await voice.cancel() }
        }
        .onChange(of: selectedVoiceEngineID) { _, _ in
            configureVoiceEngineFromSettings()
        }
        .onChange(of: medASRPythonExecutable) { _, _ in
            configureVoiceEngineFromSettingsIfMedASR()
        }
        .onChange(of: medASRScriptPath) { _, _ in
            configureVoiceEngineFromSettingsIfMedASR()
        }
        .onChange(of: medASRModelIdentifier) { _, _ in
            configureVoiceEngineFromSettingsIfMedASR()
        }
        .onChange(of: medASRDevice) { _, _ in
            configureVoiceEngineFromSettingsIfMedASR()
        }
        .onChange(of: medASREnvironment) { _, _ in
            configureVoiceEngineFromSettingsIfMedASR()
        }
    }

    private var providerStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Assistant", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(TracerTheme.accentBright, .primary)
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ResponsivePicker("Provider", selection: $provider, menuBreakpoint: 340) {
                ForEach(AssistantCLIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            Text(runner.availabilityText(for: provider))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(runner.isAvailable(provider) ? TracerTheme.mutedText : TracerTheme.warning)
                .lineLimit(1)
        }
        .padding(12)
        .background(TracerTheme.headerBackground)
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
                .foregroundColor(TracerTheme.mutedText)

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
                QuickCommandButton(title: "Anatomy", icon: "list.bullet.rectangle", color: TracerTheme.label) {
                    submit("Create label map and load TotalSegmentator full anatomy preset")
                }
                QuickCommandButton(title: "SUV 2.5", icon: "flame", color: TracerTheme.pet) {
                    submit("Threshold SUV 2.5")
                }
                QuickCommandButton(title: "PET Lesion", icon: "flame.fill", color: TracerTheme.pet) {
                    submit("Segment FDG avid disease on PET/CT with the best lesion model")
                }
                QuickCommandButton(title: "RT GTV", icon: "scope", color: TracerTheme.label) {
                    submit("Contour gross tumor volume for radiotherapy")
                }
                QuickCommandButton(title: "Liver", icon: "target", color: TracerTheme.label) {
                    submit("Select and view liver")
                }
                QuickCommandButton(title: "Measure", icon: "ruler") {
                    submit("Use distance measurement tool")
                }
            }
        }
        .padding(12)
        .background(TracerTheme.panelBackground)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if shouldShowVoiceStatus {
                voiceStatus
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    toggleVoiceCommand()
                } label: {
                    Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .tint(voice.isRecording ? .red : TracerTheme.accent)
                .disabled(!voice.isRecording && (isRunning || voice.isFinishing))
                .help("Voice command with \(voice.engineDescription). Speak a viewer command, then press Stop.")

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
        }
        .padding(12)
    }

    private var shouldShowVoiceStatus: Bool {
        voice.isRecording ||
        voice.isFinishing ||
        !voice.partialTranscript.isEmpty ||
        !voice.statusMessage.isEmpty
    }

    private var voiceStatus: some View {
        HStack(spacing: 7) {
            Image(systemName: voice.isRecording ? "waveform" : "mic")
                .foregroundColor(voice.isRecording ? .red : TracerTheme.accent)
            Text(voiceStatusText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(voice.statusMessage.lowercased().contains("denied") ? .red : TracerTheme.mutedText)
                .lineLimit(2)
            Spacer(minLength: 4)
            if voice.isRecording || voice.isFinishing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var voiceStatusText: String {
        if !voice.partialTranscript.isEmpty {
            return voice.partialTranscript
        }
        if !voice.statusMessage.isEmpty {
            return voice.statusMessage
        }
        if voice.isFinishing {
            return "Finishing voice command..."
        }
        if voice.isRecording {
            return "Listening for assistant command..."
        }
        return "Voice ready"
    }

    private func submit(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isRunning else { return }
        isSubmittingRequest = true
        defer { isSubmittingRequest = false }

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
        var kickOffPETEngine = false
        if let plan, plan.preferredEngine == .nnUNet {
            if let entry = nnunet.selectBestEntry(for: plan) {
                summary += "\nSelected nnU-Net model \(entry.displayName) (\(entry.datasetID))."
                if let engine = petEngine(for: entry) {
                    pet.selectedEngine = engine
                    summary += "\nRouting through PET Engine so CT + SUV PET channels are paired correctly."
                    kickOffPETEngine = true
                } else if let readinessMessage = nnunet.assistantReadinessMessage(for: entry) {
                    nnunet.statusMessage = readinessMessage
                    summary += "\n\(readinessMessage)"
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
        if kickOffPETEngine {
            runPETEngineFromAssistant()
        } else if kickOffNNUnet {
            runNNUnetFromAssistant()
        } else if kickOffMONAI {
            runMONAIFromAssistant()
        }

        guard provider != .local else { return }

        beginAssistantTask()
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
                    finishAssistantTask()
                }
            } catch {
                await MainActor.run {
                    messages.append(AssistantChatMessage(role: .assistant, text: "CLI unavailable: \(error.localizedDescription)"))
                    finishAssistantTask()
                }
            }
        }
    }

    private func beginAssistantTask() {
        activeAssistantTasks += 1
    }

    private func finishAssistantTask() {
        activeAssistantTasks = max(0, activeAssistantTasks - 1)
    }

    /// Kick off the nnU-Net runner selected by the RAG planner on the current
    /// volume. Reports success / failure / unavailability back into the chat
    /// transcript so the user has closure on what happened.
    private func runNNUnetFromAssistant() {
        guard let entry = nnunet.selectedEntry else {
            messages.append(AssistantChatMessage(
                role: .assistant,
                text: "Pick an nnU-Net model first."
            ))
            return
        }
        if let readinessMessage = nnunet.assistantReadinessMessage(for: entry) {
            nnunet.statusMessage = readinessMessage
            messages.append(AssistantChatMessage(
                role: .assistant,
                text: readinessMessage
            ))
            return
        }
        guard let volume = vm.currentVolume else {
            messages.append(AssistantChatMessage(
                role: .assistant,
                text: "No volume is loaded; cannot run nnU-Net."
            ))
            return
        }
        let entryName = entry.displayName
        messages.append(AssistantChatMessage(
            role: .assistant,
            text: "Running \(entryName) on the current volume…"
        ))
        beginAssistantTask()
        Task { @MainActor in
            defer { finishAssistantTask() }
            if let labelMap = await nnunet.run(on: volume, labeling: vm.labeling) {
                vm.recordSegmentationRun(
                    labelMap: labelMap,
                    name: entryName,
                    engine: "Assistant nnU-Net",
                    backend: nnunet.mode.displayName,
                    modelID: entry.datasetID,
                    metadata: ["assistant": "true"]
                )
                vm.saveCurrentStudySession(named: "Assistant nnU-Net")
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
        beginAssistantTask()
        Task { @MainActor in
            defer { finishAssistantTask() }
            if let labelMap = await monai.runInference(on: volume, in: vm.labeling) {
                vm.recordSegmentationRun(
                    labelMap: labelMap,
                    name: "MONAI · \(modelName)",
                    engine: "Assistant MONAI Label",
                    backend: monai.serverURL,
                    modelID: modelName,
                    metadata: ["assistant": "true"]
                )
                vm.saveCurrentStudySession(named: "Assistant MONAI")
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

    /// PET/CT lesion models need channel pairing, SUV scaling, and optional
    /// DGX Segmentator routing. The PET Engine owns that clinical plumbing,
    /// so chat commands use it instead of launching raw nnU-Net directly.
    private func runPETEngineFromAssistant() {
        let engineName = pet.selectedEngine.displayName
        messages.append(AssistantChatMessage(
            role: .assistant,
            text: "Running \(engineName) through PET Engine..."
        ))
        beginAssistantTask()
        Task { @MainActor in
            defer { finishAssistantTask() }
            let summary = await pet.run(viewer: vm,
                                        nnunet: nnunet,
                                        labeling: vm.labeling)
            messages.append(AssistantChatMessage(
                role: .assistant,
                text: summary
            ))
        }
    }

    private func petEngine(for entry: NNUnetCatalog.Entry) -> PETEngineViewModel.Engine? {
        switch entry.id {
        case "AutoPET-II-2023":
            return .autoPETII
        case "LesionTracer-AutoPETIII":
            return .lesionTracer
        case "LesionLocator-AutoPETIV":
            return .lesionLocator
        default:
            return nil
        }
    }

    private var selectedVoiceEngineKind: DictationEngineKind {
        DictationEngineKind(rawValue: selectedVoiceEngineID) ?? .appleSpeech
    }

    private var medASRConfiguration: GoogleMedASRConfiguration {
        let model = medASRModelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = medASRScriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let python = medASRPythonExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = medASRDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        return GoogleMedASRConfiguration(
            pythonExecutablePath: python.isEmpty ? "/usr/bin/env" : python,
            scriptPath: script.isEmpty ? nil : script,
            modelIdentifier: model.isEmpty ? GoogleMedASRDictationEngine.defaultModelIdentifier : model,
            device: device.isEmpty ? GoogleMedASRDictationEngine.defaultDevice : device,
            environment: GoogleMedASRConfiguration.parseEnvironmentLines(medASREnvironment)
        )
    }

    private func configureVoiceEngineFromSettingsIfMedASR() {
        guard selectedVoiceEngineKind == .googleMedASR else { return }
        configureVoiceEngineFromSettings()
    }

    private func configureVoiceEngineFromSettings() {
        guard !voice.isRecording && !voice.isFinishing else { return }
        switch selectedVoiceEngineKind {
        case .appleSpeech:
            voice.setEngine(AppleSpeechDictationEngine())
        case .googleMedASR:
            voice.setEngine(GoogleMedASRDictationEngine(configuration: medASRConfiguration))
        case .whisperKit, .remoteDGXWhisper:
            voice.setEngine(AppleSpeechDictationEngine())
        }
    }

    private func toggleVoiceCommand() {
        Task {
            if voice.isRecording {
                await voice.stop()
            } else {
                await voice.start()
            }
        }
    }

    private func handleVoiceCommand(_ text: String, confidence: Double?) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        guard !isRunning else {
            messages.append(AssistantChatMessage(
                role: .assistant,
                text: "Voice command captured, but another assistant task is still running: \(request)"
            ))
            return
        }
        submit(request)
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
                .foregroundColor(message.role == .user ? .black.opacity(0.86) : .primary)
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
        message.role == .user
            ? AnyShapeStyle(TracerTheme.activeGradient)
            : AnyShapeStyle(TracerTheme.panelRaised)
    }
}

private struct QuickCommandButton: View {
    let title: String
    let icon: String
    var color: Color = TracerTheme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color, .primary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color.opacity(0.075))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(color.opacity(0.16), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .controlSize(.small)
    }
}
