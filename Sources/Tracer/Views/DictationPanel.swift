import SwiftUI

/// Inspector panel for the dictation workflow. Push-to-talk mic button,
/// live transcription stream, and a scratch transcript pane. Subsequent
/// commits add the report editor (sections, macros) and AI features
/// (vibe reporting, pixel-to-text, voice-command routing).
///
/// Opens from AI Engines menu via ⌘⇧V.
public struct DictationPanel: View {
    @ObservedObject public var session: DictationSession

    public init(session: DictationSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            controls
            Divider()
            transcript
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 460)
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

    // MARK: - Actions

    private func toggleRecording() async {
        if session.isRecording {
            await session.stop()
        } else {
            await session.start()
        }
    }
}
