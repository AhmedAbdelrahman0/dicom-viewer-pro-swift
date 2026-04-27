import SwiftUI

/// Inspector panel for the dictation workflow. Push-to-talk mic button,
/// live transcription stream, structured report editor with provenance
/// badges, and macro-aware section routing. Subsequent commits (C3) add
/// AI features (vibe reporting, pixel-to-text, voice-command routing).
///
/// Opens from AI Engines menu via ⌘⇧V.
public struct DictationPanel: View {
    @ObservedObject public var session: DictationSession
    @ObservedObject public var viewer: ViewerViewModel
    /// Owned by the panel — the same DictationSession can be wired to
    /// different stores across panel-reopens (e.g. opening a different
    /// patient). The panel rebinds the session on appear so the user can
    /// swap reports without recreating the session @StateObject in
    /// ContentView.
    @StateObject private var report = RadiologyReportStore()

    /// Two views over the same session/report: a raw transcript (for
    /// quick triage) and a structured section editor (for the "real"
    /// report workflow). Persisted across panel reopens via @AppStorage.
    @AppStorage("Tracer.Dictation.PanelTab") private var rawTab: String = Tab.transcript.rawValue

    /// True while an AI feature is in flight; disables the buttons so the
    /// user can't fire two drafts at once.
    @State private var aiInFlight: Bool = false
    @AppStorage("Tracer.Dictation.ReportingClinician") private var clinicianName: String = ""
    @AppStorage("Tracer.Dictation.EngineKind") private var selectedEngineID: String = DictationEngineKind.appleSpeech.rawValue
    @AppStorage("Tracer.Dictation.MedASR.PythonExecutable") private var medASRPythonExecutable: String = "/usr/bin/env"
    @AppStorage("Tracer.Dictation.MedASR.ScriptPath") private var medASRScriptPath: String = ""
    @AppStorage("Tracer.Dictation.MedASR.ModelIdentifier") private var medASRModelIdentifier: String = GoogleMedASRDictationEngine.defaultModelIdentifier
    @AppStorage("Tracer.Dictation.MedASR.Device") private var medASRDevice: String = GoogleMedASRDictationEngine.defaultDevice
    @AppStorage("Tracer.Dictation.MedASR.Environment") private var medASREnvironment: String = ""

    enum Tab: String, CaseIterable, Identifiable {
        case transcript
        case report
        var id: String { rawValue }
        var label: String {
            switch self {
            case .transcript: return "Transcript"
            case .report:     return "Report"
            }
        }
        var systemImage: String {
            switch self {
            case .transcript: return "text.alignleft"
            case .report:     return "doc.text"
            }
        }
    }

    public init(session: DictationSession, viewer: ViewerViewModel) {
        self.session = session
        self.viewer = viewer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            controls
            engineControls
            studyWorkflow
            Divider()
            tabPicker
            Group {
                switch Tab(rawValue: rawTab) ?? .transcript {
                case .transcript: transcript
                case .report:     reportEditor
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 460)
        .onAppear {
            // Late-bind so DictationPanel's owner (ContentView) doesn't
            // need to thread a RadiologyReportStore through its
            // initializer. Routes finalised dictation into the report
            // until the panel disappears.
            session.reportStore = report
            syncReportWithActiveStudy(preferExisting: true)
            if clinicianName.isEmpty {
                clinicianName = report.report.metadata.reportingClinician
            }
            applySelectedEngine()
        }
        .onChange(of: activeStudyDigest) { _, _ in
            syncReportWithActiveStudy(preferExisting: true)
        }
        .onChange(of: selectedEngineID) { _, _ in
            applySelectedEngine()
        }
        .onChange(of: medASRPythonExecutable) { _, _ in
            applySelectedEngineIfMedASR()
        }
        .onChange(of: medASRScriptPath) { _, _ in
            applySelectedEngineIfMedASR()
        }
        .onChange(of: medASRModelIdentifier) { _, _ in
            applySelectedEngineIfMedASR()
        }
        .onChange(of: medASRDevice) { _, _ in
            applySelectedEngineIfMedASR()
        }
        .onChange(of: medASREnvironment) { _, _ in
            applySelectedEngineIfMedASR()
        }
    }

    private var tabPicker: some View {
        Picker("View", selection: Binding(
            get: { Tab(rawValue: rawTab) ?? .transcript },
            set: { rawTab = $0.rawValue }
        )) {
            ForEach(Tab.allCases) { t in
                Label(t.label, systemImage: t.systemImage)
                    .tag(t)
            }
        }
        .pickerStyle(.segmented)
    }

    private var activeStudyVolumes: [ImageVolume] {
        viewer.currentStudyVolumes
    }

    private var activeStudyDigest: String {
        activeStudyVolumes
            .map(\.sessionIdentity)
            .sorted()
            .joined(separator: "\u{1f}")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isRecording
                  ? "waveform.circle.fill"
                  : "mic.circle")
                .foregroundColor(session.isRecording ? .red : .accentColor)
                .font(.system(size: 18))
            Text("Dictation")
                .font(.headline)
            Spacer()
            Text(session.engineDescription)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    Task { await toggleRecording() }
                } label: {
                    Label(session.isRecording ? "Stop" : "Record",
                          systemImage: session.isRecording ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(session.isRecording ? .red : .accentColor)
                // No in-panel hotkey: ⌘V is system Paste, and global
                // push-to-talk via NSEvent monitoring lands in C3.
                .help("Click to start / stop dictation. Open the panel with ⌘⇧V.")
                .disabled(report.report.isFinalised)

                Button {
                    Task { await session.cancel() }
                    session.statusMessage = "Cancelled — partial transcript discarded."
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .disabled(!session.isRecording && session.partialTranscript.isEmpty)
                .keyboardShortcut(.escape)
                .controlSize(.small)

                Spacer()

                vuMeter
                    .frame(width: 80, height: 14)
                    .help(String(format: "Input level: %.2f", session.inputLevel))
            }

            if !session.statusMessage.isEmpty {
                Text(session.statusMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(session.statusMessage.lowercased().contains("denied") ? .red : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var studyWorkflow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                reportStatusBadge
                if let current = viewer.currentVolume {
                    Text(current.patientName.isEmpty ? "Unknown patient" : current.patientName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(current.studyDescription.isEmpty ? current.seriesDescription : current.studyDescription)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No active study")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    startNewDraft()
                } label: {
                    Label("New Draft", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(activeStudyVolumes.isEmpty || session.isRecording)

                Button {
                    saveDraft()
                } label: {
                    Label("Save Draft", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(session.isRecording)

                Button {
                    attachReportToStudy()
                } label: {
                    Label("Attach", systemImage: "link")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(activeStudyVolumes.isEmpty || session.isRecording)

                Spacer(minLength: 4)

                TextField("Clinician", text: $clinicianName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(minWidth: 120, idealWidth: 150, maxWidth: 180)
                    .onChange(of: clinicianName) { _, newValue in
                        report.setMetadata { metadata in
                            metadata.reportingClinician = newValue
                        }
                    }

                if report.report.isFinalised {
                    Button {
                        report.reopenFinalReport(by: clinicianName)
                    } label: {
                        Label("Reopen", systemImage: "lock.open")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(session.isRecording)
                } else {
                    Button {
                        finaliseReport()
                    } label: {
                        Label("Finalize", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(session.isRecording || clinicianName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let key = viewer.currentStudyReportKey,
               report.report.metadata.studyKey == key,
               !key.isEmpty {
                Text("Attached study report")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if !activeStudyVolumes.isEmpty {
                Text("Report is not attached to the current study yet.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.orange)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5))
    }

    private var reportStatusBadge: some View {
        let final = report.report.isFinalised
        return Label(final ? "Final" : "Draft",
                     systemImage: final ? "checkmark.seal.fill" : "doc.text")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(final ? .green : .accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill((final ? Color.green : Color.accentColor).opacity(0.14)))
    }

    /// Tiny VU meter — fills from left to right with the live RMS. Uses
    /// a square-rooted scale because spoken-voice RMS rarely exceeds
    /// ~0.2 even at full conversational volume; sqrt makes the bar feel
    /// responsive.
    private var vuMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))
                let scaled = min(1.0, sqrt(Double(session.inputLevel) * 5))
                RoundedRectangle(cornerRadius: 3)
                    .fill(meterColor(forLevel: scaled))
                    .frame(width: geo.size.width * CGFloat(scaled))
            }
        }
    }

    private func meterColor(forLevel level: Double) -> Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .orange }
        return .green
    }

    private var engineControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("Engine", selection: Binding(
                    get: { selectedEngineKind },
                    set: { selectedEngineID = $0.rawValue }
                )) {
                    ForEach(DictationEngineKind.allCases) { kind in
                        Text(kind.displayName + (kind.isImplemented ? "" : " · soon"))
                            .tag(kind)
                            .disabled(!kind.isImplemented)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                .disabled(session.isRecording || session.isFinishing)

                if selectedEngineKind == .googleMedASR {
                    Label("Buffers until Stop", systemImage: "waveform.badge.magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                } else {
                    Label("Streaming", systemImage: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            if selectedEngineKind == .googleMedASR {
                medASRControls
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
    }

    private var medASRControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("/usr/bin/env or python3 path", text: $medASRPythonExecutable)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                TextField(GoogleMedASRDictationEngine.defaultModelIdentifier,
                          text: $medASRModelIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
            }
            HStack(spacing: 8) {
                TextField("Optional worker script path", text: $medASRScriptPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                Picker("Device", selection: $medASRDevice) {
                    Text("Auto").tag("auto")
                    Text("CPU").tag("cpu")
                    Text("CUDA").tag("cuda")
                    Text("MPS").tag("mps")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 82)
            }
            TextField("Optional env, e.g. HF_TOKEN=...", text: $medASREnvironment, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1...3)
            Text("MedASR runs from a local Python worker. First run may download the model; protected Hugging Face access can use HF_TOKEN here.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transcript")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    session.clearTranscripts()
                } label: {
                    Label("Clear", systemImage: "eraser")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(session.finalTranscript.isEmpty
                          && session.partialTranscript.isEmpty)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !session.finalTranscript.isEmpty {
                        Text(session.finalTranscript)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    if !session.partialTranscript.isEmpty {
                        Text(session.partialTranscript)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .italic()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    if session.finalTranscript.isEmpty && session.partialTranscript.isEmpty {
                        Text("Click Record and speak. Partial results show in italic; finalised text in regular weight.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 180)
            .background(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))

            HStack {
                if !session.finalTranscript.isEmpty {
                    Text("\(DictationSession.splitSentences(session.finalTranscript).count) sentence(s)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if session.isRecording {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("Recording")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }

    // MARK: - Report editor

    private var reportEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Active section", selection: Binding(
                    get: { session.activeSection },
                    set: { session.activeSection = $0 }
                )) {
                    ForEach(ReportSection.Kind.allCases, id: \.self) { kind in
                        Text(kind.displayLabel).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("Dictated finals append to this section. Say \"section impression\" to switch.")

                Spacer()

                Button {
                    saveDraft()
                } label: {
                    Label("Save", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(report.statusMessage.isEmpty
                      ? "Save report JSON snapshot."
                      : report.statusMessage)
            }

            aiFeatureRow

            if report.report.signOff != nil {
                Label("Signed — further edits will create an addendum",
                      systemImage: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.report.sections) { section in
                        sectionView(section)
                    }
                    if report.report.sections.allSatisfy({ $0.sentences.isEmpty }) {
                        Text("Sections appear here once you dictate. Say \"section findings\" to switch sections, or use a macro like \".liver normal\".")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 220)
            .background(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))

            if !report.statusMessage.isEmpty {
                Text(report.statusMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(report.statusMessage.lowercased().contains("fail") ? .red : .secondary)
                    .lineLimit(2)
            }
        }
    }

    private func sectionView(_ section: ReportSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(section.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                if section.kind == session.activeSection {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.accentColor)
                }
                Spacer()
                Text("\(section.sentences.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if section.sentences.isEmpty {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(section.sentences) { sentence in
                    sentenceRow(sentence)
                }
            }
        }
    }

    /// AI feature buttons: Draft Impression (heuristic / LLM) and
    /// Describe View (VLM). Both append to the report tagged
    /// `aiDrafted` / `vlmSuggested`; the user accepts inline.
    private var aiFeatureRow: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    aiInFlight = true
                    await session.draftImpressionRequested()
                    aiInFlight = false
                }
            } label: {
                Label("Draft Impression", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(aiInFlight || report.report.isFinalised)
            .help("Generate a one-paragraph impression from the current Findings (\(session.impressionDrafter.displayName)).")

            Button {
                Task {
                    aiInFlight = true
                    await session.describeViewRequested()
                    aiInFlight = false
                }
            } label: {
                Label("Describe View", systemImage: "eye")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(aiInFlight || session.imageProvider == nil || report.report.isFinalised)
            .help(session.imageProvider == nil
                  ? "Pixel-to-text needs the active viewer image — wired in a later commit."
                  : "Run the VLM (\(session.pixelToText.displayName)) on the current slice and append a finding-style sentence.")

            Spacer()

            if aiInFlight {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Inline accept/reject controls shown next to AI-suggested sentences.
    /// Only visible when the sentence is still pending (.aiDrafted /
    /// .vlmSuggested).
    private func suggestionControls(for sentence: ReportSentence) -> some View {
        HStack(spacing: 4) {
            Button {
                report.applyMutation { current in
                    AISuggestionAcceptor.acceptLastPending(in: current)
                }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.green)
            }
            .buttonStyle(.borderless)
            .help("Accept this AI suggestion (locks it in).")

            Button {
                report.removeSentence(id: sentence.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Reject this AI suggestion.")
        }
    }

    private func sentenceRow(_ sentence: ReportSentence) -> some View {
        HStack(alignment: .top, spacing: 6) {
            provenanceBadge(sentence.provenance)
            Text(sentence.text)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .foregroundColor(AISuggestionAcceptor.isPendingSuggestion(sentence)
                                 ? .secondary : .primary)
                .italic(AISuggestionAcceptor.isPendingSuggestion(sentence))
            if AISuggestionAcceptor.isPendingSuggestion(sentence) {
                suggestionControls(for: sentence)
            } else {
                Button {
                    report.removeSentence(id: sentence.id)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove sentence")
            }
        }
    }

    private func provenanceBadge(_ p: ReportSentence.Provenance) -> some View {
        let (label, color): (String, Color) = {
            switch p {
            case .dictated:              return ("DIC", .accentColor)
            case .typed:                 return ("KEY", .secondary)
            case .macro:                 return ("MAC", .blue)
            case .aiDrafted:             return ("AI",  .orange)
            case .vlmSuggested:          return ("VLM", .purple)
            case .acceptedAISuggestion:  return ("AI✓", .green)
            }
        }()
        return Text(label)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color)
            .cornerRadius(3)
            .help("Provenance: \(p.rawValue)")
    }

    // MARK: - Actions

    private var selectedEngineKind: DictationEngineKind {
        DictationEngineKind(rawValue: selectedEngineID) ?? .appleSpeech
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

    private func applySelectedEngineIfMedASR() {
        guard selectedEngineKind == .googleMedASR else { return }
        applySelectedEngine()
    }

    private func applySelectedEngine() {
        let kind = selectedEngineKind
        guard kind.isImplemented else {
            selectedEngineID = DictationEngineKind.appleSpeech.rawValue
            session.statusMessage = "\(kind.displayName) is not wired yet; using Apple Speech."
            return
        }
        guard !session.isRecording && !session.isFinishing else {
            session.statusMessage = "Stop dictation before switching engines."
            return
        }
        switch kind {
        case .appleSpeech:
            session.setEngine(AppleSpeechDictationEngine())
        case .googleMedASR:
            session.setEngine(GoogleMedASRDictationEngine(configuration: medASRConfiguration))
        case .whisperKit, .remoteDGXWhisper:
            break
        }
    }

    private func syncReportWithActiveStudy(preferExisting: Bool) {
        let volumes = activeStudyVolumes
        guard !volumes.isEmpty else { return }
        report.bindToStudy(volumes: volumes, preferExisting: preferExisting)
        if !report.report.metadata.reportingClinician.isEmpty {
            clinicianName = report.report.metadata.reportingClinician
        } else if !clinicianName.isEmpty {
            report.setMetadata { metadata in
                metadata.reportingClinician = clinicianName
            }
        }
    }

    private func startNewDraft() {
        report.newDraft(for: activeStudyVolumes)
        if !clinicianName.isEmpty {
            report.setMetadata { metadata in
                metadata.reportingClinician = clinicianName
            }
        }
        session.clearTranscripts()
        rawTab = Tab.report.rawValue
    }

    private func saveDraft() {
        if activeStudyVolumes.isEmpty {
            report.save()
        } else {
            _ = report.attachToStudy(volumes: activeStudyVolumes)
        }
    }

    private func attachReportToStudy() {
        _ = report.attachToStudy(volumes: activeStudyVolumes)
        rawTab = Tab.report.rawValue
    }

    private func finaliseReport() {
        _ = report.finaliseReport(by: clinicianName, volumes: activeStudyVolumes)
        rawTab = Tab.report.rawValue
    }

    private func toggleRecording() async {
        guard !report.report.isFinalised else {
            session.statusMessage = "Report is final — reopen it before adding dictation."
            return
        }
        if !activeStudyVolumes.isEmpty,
           report.report.metadata.studyKey != viewer.currentStudyReportKey {
            report.bindToStudy(volumes: activeStudyVolumes, preferExisting: true)
        }
        if session.isRecording {
            await session.stop()
        } else {
            await session.start()
        }
    }
}

// MARK: - Display labels for section kinds

private extension ReportSection.Kind {
    var displayLabel: String {
        switch self {
        case .clinicalHistory: return "Clinical History"
        case .technique:       return "Technique"
        case .comparison:      return "Comparison"
        case .findings:        return "Findings"
        case .impression:      return "Impression"
        case .recommendations: return "Recommendations"
        case .custom:          return "Custom"
        }
    }
}
