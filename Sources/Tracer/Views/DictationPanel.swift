import SwiftUI

/// Inspector panel for the dictation workflow. Push-to-talk mic button,
/// live transcription stream, structured report editor with provenance
/// badges, and macro-aware section routing. Subsequent commits (C3) add
/// AI features (vibe reporting, pixel-to-text, voice-command routing).
///
/// Opens from AI Engines menu via ⌘⇧V.
public struct DictationPanel: View {
    @ObservedObject public var session: DictationSession
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

    public init(session: DictationSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            controls
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
                    report.save()
                } label: {
                    Label("Save", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(report.statusMessage.isEmpty
                      ? "Save report JSON snapshot."
                      : report.statusMessage)
            }

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

    private func sentenceRow(_ sentence: ReportSentence) -> some View {
        HStack(alignment: .top, spacing: 6) {
            provenanceBadge(sentence.provenance)
            Text(sentence.text)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .foregroundColor(sentence.provenance == .aiDrafted
                                 || sentence.provenance == .vlmSuggested
                                 ? .secondary : .primary)
                .italic(sentence.provenance == .aiDrafted
                        || sentence.provenance == .vlmSuggested)
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

    private func toggleRecording() async {
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
