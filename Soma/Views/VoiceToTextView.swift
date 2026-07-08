import SwiftUI

struct VoiceToTextView: View {
    let somaViewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @ObservedObject var asr: ASRManager
    @ObservedObject var prompter: RusToPromptViewModel
    @ObservedObject var globalVoice: GlobalVoiceController
    @AppStorage("modelKeepLoadedMinutes") private var keepLoadedMinutes = 10
    @AppStorage("voiceMode") private var voiceMode = "prompt"   // text | translate | prompt
    @AppStorage("globalVoicePasteEnabled") private var globalVoicePasteEnabled = false
    @State private var showSettings = false
    @State private var expandedRecordingURL: URL?
    @State private var expandedTranscript = ""

    private static let modes: [(id: String, title: String)] = [
        ("text", "Text only"), ("translate", "Translate"), ("prompt", "Prompt"),
    ]

    private var prompterRunning: Bool {
        [.translating, .analyzing, .checkingConfidence].contains(prompter.phase)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                recordButton
                statusLine
                modePanel
                enginePanel
                transcriptCard
                if voiceMode != "text" { translationCard }
                if voiceMode == "prompt" { promptCard }
                recordingsList
                settings
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { asr.refreshRecordings() }
        // Fire the chosen action once a recording is transcribed.
        .onChange(of: asr.completedTranscriptionID) { _, _ in
            guard asr.lastTranscriptionSource == .inApp else { return }
            runMode(on: asr.transcript)
        }
    }

    private func runMode(on raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !prompterRunning else { return }
        switch voiceMode {
        case "translate": startPrompter(text, mode: .translateOnly)
        case "prompt":    startPrompter(text, mode: .fullPrompt)
        default: break    // "text": just keep the transcript; user can run actions manually
        }
    }

    private func startPrompter(_ text: String, mode: RusToPromptMode) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !prompterRunning else { return }
        prompter.inputPrompt = clean
        prompter.transform(mode: mode, somaViewModel: somaViewModel, ollama: ollama)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if asr.isTranscribing { ProgressView().controlSize(.small) }
            Text(asr.status).foregroundStyle(.secondary)
            if let secs = asr.lastInferSeconds {
                Text("· \(String(format: "%.1fs", secs))").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }

    private var enginePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("ASR engine", systemImage: "waveform")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(asr.engineTitle).font(.caption).foregroundStyle(.secondary)
            }
            Picker("ASR engine", selection: $asr.engine) {
                ForEach(ASRManager.engines, id: \.id) { e in
                    Text(e.title).tag(e.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(asr.isTranscribing || asr.isRecording)
            Text("Whisper: best all-round, keeps English words and punctuation. GigaAM: faster, Russian-only, but garbles English. Switching reloads the model on the next recording.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }

    private var modePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What to do with speech", systemImage: "wand.and.stars")
                .font(.callout.weight(.medium))
            Picker("Mode", selection: $voiceMode) {
                ForEach(Self.modes, id: \.id) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(modeHint).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }

    private var modeHint: String {
        switch voiceMode {
        case "translate": return "After recognition, the text is translated to English. No prompt step."
        case "prompt":    return "After recognition: translate → polished English prompt."
        default:          return "Speech recognition only. Run translate or prompt manually with the buttons below."
        }
    }

    // MARK: result cards

    /// Card 1 — the recognized Russian text, with manual "translate" / "to prompt" actions
    /// so you can act on it even in "text" mode.
    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Recognized text (RU)", systemImage: "text.bubble")
                    .font(.callout.weight(.medium))
                Spacer()
                if !asr.transcript.isEmpty {
                    Button { asr.copyToClipboard(asr.transcript) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy text")
                }
            }
            Text(asr.transcript.isEmpty ? "Recognized speech will appear here after recording." : asr.transcript)
                .foregroundStyle(asr.transcript.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            HStack(spacing: 8) {
                Button { startPrompter(asr.transcript, mode: .translateOnly) } label: {
                    Label("Translate", systemImage: "character.book.closed")
                }
                Button { startPrompter(asr.transcript, mode: .fullPrompt) } label: {
                    Label("To prompt", systemImage: "wand.and.stars")
                }
            }
            .disabled(asr.transcript.trimmingCharacters(in: .whitespaces).isEmpty || prompterRunning || asr.isRecording)
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }

    /// Card 2 — the English translation.
    private var translationCard: some View {
        resultCard(title: "Translation (EN)", icon: "character.book.closed",
                   text: prompter.translation,
                   placeholder: "Translation will appear here.",
                   running: prompter.phase == .translating,
                   accent: false)
    }

    /// Card 3 — the polished English prompt.
    private var promptCard: some View {
        resultCard(title: "Prompt (EN)", icon: "wand.and.stars",
                   text: prompter.improvedPrompt,
                   placeholder: "Prompt will appear here.",
                   running: prompter.phase == .analyzing || prompter.phase == .checkingConfidence,
                   accent: true,
                   error: prompter.errorMessage)
    }

    private func resultCard(title: String, icon: String, text: String, placeholder: String,
                            running: Bool, accent: Bool, error: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon).font(.callout.weight(.medium))
                if running { ProgressView().controlSize(.small) }
                Spacer()
                if !text.isEmpty {
                    Button { asr.copyToClipboard(text) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy")
                }
            }
            if let error, !error.isEmpty {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Text(text.isEmpty ? placeholder : text)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background((accent ? Color.accentColor : Color(NSColor.textBackgroundColor)).opacity(accent ? 0.06 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke((accent ? Color.accentColor : Color.secondary).opacity(accent ? 0.2 : 0.15)))
    }

    private var recordButton: some View {
        Button(action: asr.toggleRecording) {
            ZStack {
                Circle()
                    .fill(asr.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 96, height: 96)
                Image(systemName: asr.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(asr.isTranscribing)
        .help(asr.isRecording ? "Stop and transcribe" : "Start recording")
        .padding(.top, 8)
    }

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recordings").font(.headline)
                Spacer()
                if asr.hasAnyTranscript {
                    Button {
                        asr.copyToClipboard(asr.allTranscriptsText())
                    } label: {
                        Label("Copy all transcripts", systemImage: "doc.on.doc")
                    }
                    .help("Copy the whole transcript history to the clipboard")
                }
                if !asr.recordings.isEmpty {
                    Text("\(asr.recordings.count)").foregroundStyle(.secondary)
                }
            }
            if asr.recordings.isEmpty {
                Text("No recordings yet. Press the mic to record.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(asr.recordings.enumerated()), id: \.element.id) { index, rec in
                        recordingRow(rec)
                        if index < asr.recordings.count - 1 { Divider() }
                    }
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func recordingRow(_ rec: VoiceRecording) -> some View {
        let isCurrent = asr.lastRecordingURL == rec.url
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: { asr.togglePlayback(rec.url) }) {
                    Image(systemName: asr.playingURL == rec.url ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(asr.playingURL == rec.url ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(asr.playingURL == rec.url ? "Stop" : "Play")

                VStack(alignment: .leading, spacing: 1) {
                    Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                    Text(durationText(rec.duration)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if rec.hasTranscript {
                    Button(expandedRecordingURL == rec.url ? "Hide text" : "Text") {
                        toggleTranscript(rec)
                    }
                    .help(expandedRecordingURL == rec.url ? "Hide transcript" : "Load transcript from disk")
                }
                Button("Transcribe") { asr.transcribe(recording: rec.url) }
                    .disabled(asr.isTranscribing || asr.isRecording)
                    .help("Send this recording to transcription")
                Button(action: { asr.reveal(rec.url) }) { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                Button(action: { asr.deleteRecording(rec.url) }) {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .disabled(asr.playingURL == rec.url)
                .help("Delete recording")
            }

            if expandedRecordingURL == rec.url {
                HStack(alignment: .top, spacing: 8) {
                    Text(expandedTranscript.isEmpty ? "Transcript file is empty." : expandedTranscript)
                        .font(.callout)
                        .foregroundStyle(expandedTranscript.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { asr.copyToClipboard(expandedTranscript) }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(expandedTranscript.isEmpty)
                    .help("Copy this transcript")
                }
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.08) : .clear)
    }

    private func toggleTranscript(_ rec: VoiceRecording) {
        if expandedRecordingURL == rec.url {
            expandedRecordingURL = nil
            expandedTranscript = ""
        } else {
            expandedRecordingURL = rec.url
            expandedTranscript = asr.transcript(for: rec.url)
        }
    }

    private func durationText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var settings: some View {
        DisclosureGroup("Settings", isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $keepLoadedMinutes, in: 0...120) {
                    Text("Keep model loaded when idle: **\(keepLoadedMinutes)** min")
                }
                Text("0 unloads immediately after each transcription. Higher values skip the slow reload on the next request.")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()

                Toggle("Global Right Command paste", isOn: $globalVoicePasteEnabled)
                    .toggleStyle(.switch)
                    .help("Hold Right Command to record, release to paste the selected Voice mode into the active app.")
                Text(globalVoice.status)
                    .font(.caption)
                    .foregroundStyle(globalVoice.needsAccessibilityPermission ? .orange : .secondary)
                if globalVoice.needsAccessibilityPermission {
                    Button {
                        globalVoice.openAccessibilitySettings()
                    } label: {
                        Label("Open Accessibility Settings", systemImage: "lock.shield")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}
