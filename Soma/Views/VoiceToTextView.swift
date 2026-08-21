import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VoiceToTextView: View {
    let somaViewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @ObservedObject var asr: ASRManager
    @ObservedObject var prompter: RusToPromptViewModel
    @ObservedObject var globalVoice: GlobalVoiceController
    @ObservedObject var textPriorityQueue: VoiceTextPriorityQueue
    @AppStorage("modelKeepLoadedMinutes") private var keepLoadedMinutes = 60
    @AppStorage(VoiceOutputMode.storageKey) private var voiceMode = VoiceOutputMode.prompt.rawValue
    @AppStorage("globalVoicePasteEnabled") private var globalVoicePasteEnabled = false
    @AppStorage("asrBackend") private var asrBackend = "local"
    @AppStorage("voiceServerURL") private var voiceServerURL = ""
    @State private var voiceServerToken = VoiceServerTokenStore.load()
    @State private var voiceServerTokenError: String?
    @State private var showSettings = false
    @State private var expandedRecordingURL: URL?
    @State private var expandedTranscript = ""
    @State private var importDropTarget = false
    @State private var expandedImportHistoryID: UUID?
    @State private var translateImportedMedia = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                recordButton
                mediaImportPanel
                statusLine
                modePanel
                enginePanel
                if asrBackend == "remote" {
                    voiceServerStatusPanel
                }
                transcriptCard
                if voiceMode != "text" { translationCard }
                if voiceMode == "prompt" { promptCard }
                recordingsList
                settings
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear {
            asr.refreshRecordings()
            asr.resumeImportQueue()
            voiceServerToken = VoiceServerTokenStore.load()
            if asrBackend == "remote" {
                Task { await asr.checkVoiceServer(silent: true) }
            }
        }
        .onChange(of: voiceServerToken) { _, token in
            voiceServerTokenError = VoiceServerTokenStore.save(token)
        }
        .onChange(of: asrBackend) { _, backend in
            if backend == "remote" {
                Task { await asr.checkVoiceServer(silent: true) }
            }
        }
        // Fire the chosen action once a recording is transcribed.
        .onChange(of: asr.completedTranscriptionID) { _, _ in
            guard asr.lastTranscriptionSource == .inApp else { return }
            runMode(on: asr.transcript)
        }
    }

    private func runMode(on raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch voiceMode {
        case "translate": startPrompter(text, mode: .translateOnly)
        case "prompt": startPrompter(text, mode: .fullPrompt)
        default: break  // "text": just keep the transcript; user can run actions manually
        }
    }

    private func startPrompter(_ text: String, mode: RusToPromptMode) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let outputMode: VoiceOutputMode = mode == .fullPrompt ? .prompt : .english
        Task { _ = try? await textPriorityQueue.translateInteractive(clean, mode: outputMode) }
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
            Text(
                "Whisper: best all-round, keeps English words and punctuation. GigaAM: faster, Russian-only, but garbles English. Switching reloads the model on the next recording."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }

    private var voiceServerStatusPanel: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(voiceServerStatusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("Soma Voice Server")
                    .font(.callout.weight(.medium))
                Text(voiceServerStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                Task { await asr.checkVoiceServer() }
            } label: {
                Label("Test Server", systemImage: "network")
            }
            .disabled(asr.isRecording || asr.isTranscribing || asr.voiceServerConnectionState == .checking)
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }

    private var voiceServerStatusText: String {
        switch asr.voiceServerConnectionState {
        case .unknown: return "Not checked"
        case .checking: return asr.voiceServerStatusDetail
        case .online: return "Online"
        case .offline: return "Offline: \(asr.voiceServerStatusDetail)"
        }
    }

    private var voiceServerStatusColor: Color {
        switch asr.voiceServerConnectionState {
        case .unknown: return .secondary
        case .checking: return .yellow
        case .online: return .green
        case .offline: return .red
        }
    }

    private var modePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What to do with speech", systemImage: "wand.and.stars")
                .font(.callout.weight(.medium))
            Picker("Mode", selection: $voiceMode) {
                ForEach(VoiceOutputMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
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
        VoiceOutputMode(rawValue: voiceMode)?.hint ?? VoiceOutputMode.prompt.hint
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
                    Button {
                        asr.copyToClipboard(asr.transcript)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless).help(Text(verbatim: "Copy text"))
                }
            }
            Text(asr.transcript.isEmpty ? "Recognized speech will appear here after recording." : asr.transcript)
                .foregroundStyle(asr.transcript.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            HStack(spacing: 8) {
                Button {
                    startPrompter(asr.transcript, mode: .translateOnly)
                } label: {
                    Label("Translate", systemImage: "character.book.closed")
                }
                Button {
                    startPrompter(asr.transcript, mode: .fullPrompt)
                } label: {
                    Label("To prompt", systemImage: "wand.and.stars")
                }
            }
            .disabled(asr.transcript.trimmingCharacters(in: .whitespaces).isEmpty || asr.isRecording)
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }

    /// Card 2 — the English translation.
    private var translationCard: some View {
        resultCard(
            title: "Translation (EN)", icon: "character.book.closed",
            text: prompter.translation,
            placeholder: "Translation will appear here.",
            running: prompter.phase == .translating,
            accent: false)
    }

    /// Card 3 — the polished English prompt.
    private var promptCard: some View {
        resultCard(
            title: "Prompt (EN)", icon: "wand.and.stars",
            text: prompter.improvedPrompt,
            placeholder: "Prompt will appear here.",
            running: prompter.phase == .analyzing || prompter.phase == .checkingConfidence,
            accent: true,
            error: prompter.errorMessage)
    }

    private func resultCard(
        title: String, icon: String, text: String, placeholder: String,
        running: Bool, accent: Bool, error: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon).font(.callout.weight(.medium))
                if running { ProgressView().controlSize(.small) }
                Spacer()
                if !text.isEmpty {
                    Button {
                        asr.copyToClipboard(text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless).help(Text(verbatim: "Copy"))
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
        .help(Text(verbatim: asr.isRecording ? "Stop and transcribe" : "Start recording"))
        .padding(.top, 8)
    }

    private var mediaImportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Import audio or video", systemImage: "tray.and.arrow.down")
                    .font(.headline)
                Spacer()
                Button("Choose files") { chooseImportFiles() }
            }
            Toggle("Also translate imported transcripts to English in the background", isOn: $translateImportedMedia)
                .font(.caption)
            Text(
                "Drop one or more media files here. Soma converts audio locally to lossless 16 kHz FLAC chunks. Live dictation always goes ahead of background imports and translation."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(importDropTarget ? "Release to queue files" : "Drop audio or video files")
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(importDropTarget ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $importDropTarget, perform: receiveDroppedMedia)

            if !asr.importJobs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(asr.importJobs) { job in
                        importJobRow(job)
                        if job.id != asr.importJobs.last?.id { Divider() }
                    }
                }
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if textPriorityQueue.activeDescription != "Idle" || textPriorityQueue.pendingBackgroundCount > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(textPriorityQueue.activeDescription)
                    Spacer()
                    Text("\(textPriorityQueue.pendingBackgroundCount) remaining")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            ForEach(textPriorityQueue.failedBackgroundImportIDs, id: \.self) { importID in
                HStack {
                    Text("Background translation failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { textPriorityQueue.retryFailedBackgroundTranslation(importID: importID) }
                    Button("Cancel", role: .destructive) { textPriorityQueue.cancelBackgroundTranslation(importID: importID) }
                }
                .controlSize(.small)
            }
            if !asr.importHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Imported transcripts").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(asr.importHistory.prefix(5)) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.displayName).lineLimit(1)
                                Spacer()
                                Text(item.completedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Button(expandedImportHistoryID == item.id ? "Hide text" : "Text") {
                                    expandedImportHistoryID = expandedImportHistoryID == item.id ? nil : item.id
                                }
                            }
                            if expandedImportHistoryID == item.id {
                                Text(asr.importedTranscript(for: item))
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if item.translatedTranscriptPath != nil {
                                    Text("English translation")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Text(asr.importedTranslation(for: item))
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }

    private func importJobRow(_ job: MediaImportJob) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: importIcon(for: job.phase)).foregroundStyle(job.phase == .failed ? .red : Color.accentColor)
                Text(job.displayName).lineLimit(1)
                Spacer()
                Text(importPhaseTitle(job.phase)).font(.caption).foregroundStyle(.secondary)
            }
            if job.totalChunks != nil {
                ProgressView(value: job.progress)
            } else if job.phase == .probing || job.phase == .converting {
                ProgressView()
            }
            if let error = job.errorMessage, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(job.phase == .failed || job.phase == .needsSource ? .red : .secondary)
            }
            HStack(spacing: 8) {
                if job.isRetryable {
                    Button("Retry") { asr.retryImport(job.id) }
                }
                if job.phase == .needsSource {
                    Button("Locate source") { chooseReplacementSource(for: job.id) }
                }
                Button("Cancel", role: .destructive) { asr.cancelImport(job.id) }
                Spacer()
                if let total = job.totalChunks {
                    Text("\(job.nextChunkIndex) / \(total) chunks").font(.caption).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
    }

    private func importPhaseTitle(_ phase: MediaImportPhase) -> String {
        switch phase {
        case .queued: "Queued"
        case .probing: "Inspecting"
        case .converting: "Converting"
        case .uploading: "Uploading"
        case .transcribing: "Transcribing"
        case .waitingForNetwork: "Waiting for network"
        case .needsSource: "Source needed"
        case .failed: "Failed"
        }
    }

    private func importIcon(for phase: MediaImportPhase) -> String {
        switch phase {
        case .failed: "exclamationmark.triangle.fill"
        case .needsSource: "questionmark.folder"
        case .waitingForNetwork: "wifi.exclamationmark"
        default: "waveform"
        }
    }

    private func receiveDroppedMedia(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls = [URL?](repeating: nil, count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock()
                urls[index] = url
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            asr.enqueueImportedFiles(urls.compactMap { $0 }, translateAfterTranscription: translateImportedMedia)
        }
        return !providers.isEmpty
    }

    private func chooseImportFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Queue files"
        if panel.runModal() == .OK { asr.enqueueImportedFiles(panel.urls, translateAfterTranscription: translateImportedMedia) }
    }

    private func chooseReplacementSource(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Use this source"
        if panel.runModal() == .OK, let url = panel.url { asr.locateImportSource(id, at: url) }
    }

    private var recordingsList: some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recordings").font(.headline)
                Spacer()
                if asr.hasAnyTranscript {
                    Button {
                        asr.copyToClipboard(asr.allTranscriptsText())
                    } label: {
                        Label("Copy all transcripts", systemImage: "doc.on.doc")
                    }
                    .help(Text(verbatim: "Copy the whole transcript history to the clipboard"))
                }
                if !asr.recordings.isEmpty {
                    Text("\(asr.recordings.count) of \(asr.recordingsTotal)")
                        .foregroundStyle(.secondary)
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

                if asr.hasMoreRecordings {
                    Button("Show \(asr.nextRecordingsPageSize) more") {
                        asr.loadMoreRecordings()
                    }
                    .frame(maxWidth: .infinity)
                    .help(Text(verbatim: "Load the next recordings"))
                }
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
                .help(Text(verbatim: asr.playingURL == rec.url ? "Stop" : "Play"))

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
                    .help(Text(verbatim: expandedRecordingURL == rec.url ? "Hide transcript" : "Load transcript from disk"))
                }
                Button("Transcribe") { asr.transcribe(recording: rec.url) }
                    .disabled(asr.isTranscribing || asr.isRecording)
                    .help(Text(verbatim: "Send this recording to transcription"))
                Button(action: { asr.reveal(rec.url) }) { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help(Text(verbatim: "Show in Finder"))
                Button(action: { asr.deleteRecording(rec.url) }) {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .disabled(asr.playingURL == rec.url)
                .help(Text(verbatim: "Delete recording"))
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
                    .help(Text(verbatim: "Copy this transcript"))
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
                Stepper(value: $keepLoadedMinutes, in: 0...60) {
                    Text("Keep model loaded when idle: **\(keepLoadedMinutes)** min")
                }
                Text("0 unloads immediately after each transcription. Higher values skip the slow reload on the next request.")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()

                Picker("Transcription backend", selection: $asrBackend) {
                    Text("Local Mac").tag("local")
                    Text("M1 Server").tag("remote")
                }
                .pickerStyle(.segmented)
                .disabled(asr.isRecording || asr.isTranscribing)
                if asrBackend == "remote" {
                    TextField("Server URL", text: $voiceServerURL)
                        .textFieldStyle(.roundedBorder)
                        .help(Text(verbatim: "HTTPS URL from Tailscale Serve, for example https://m1.tailnet.ts.net"))
                    SecureField("Server token", text: $voiceServerToken)
                        .textFieldStyle(.roundedBorder)
                    if let voiceServerTokenError {
                        Text(voiceServerTokenError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack(spacing: 8) {
                        Button {
                            Task { await asr.checkVoiceServer() }
                        } label: {
                            Label("Test Server", systemImage: "network")
                        }
                        .disabled(asr.isRecording || asr.isTranscribing || asr.voiceServerConnectionState == .checking)
                        Text("HTTPS is required. Audio is sent as WAV bytes; source media stays local for retry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Toggle("Global Right Command paste", isOn: $globalVoicePasteEnabled)
                    .toggleStyle(.switch)
                    .help(Text(verbatim: "Hold Right Command to record, release to paste the selected Voice mode into the active app."))
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
