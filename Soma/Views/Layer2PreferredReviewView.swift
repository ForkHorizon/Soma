import SwiftUI

struct Layer2PreferredReviewView: View {
    @ObservedObject var asr: ASRManager
    @ObservedObject var runner: Layer1GroundTruthRunner
    @Environment(\.dismiss) var dismiss
    @State var selectedAudioID: String?
    @State private var preferredText = ""
    @State var loadedAudioID: String?
    @State private var transcripts: [String: Layer2PreferredTranscript] = [:]
    @State private var loadedSourceText = ""
    @State private var suppressTextChange = false
    @State var isDirty = false
    @State var pendingAudioID: String?
    @State var showDiscardAlert = false
    @State var errorMessage: String?
    @State private var eligibleFilesSnapshot: [Layer1AudioFile] = []
    @State private var eligibilityTask: Task<Void, Never>?
    @State private var dirtyFileSnapshot: Layer1AudioFile?
    @State var sourceChangedWhileEditing = false

    var eligibleFiles: [Layer1AudioFile] {
        eligibleFilesSnapshot
    }

    private var selectedFile: Layer1AudioFile? {
        eligibleFiles.first { $0.id == selectedAudioID }
    }

    private var detailFile: Layer1AudioFile? {
        selectedFile ?? (isDirty ? dirtyFileSnapshot : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stage 2 · Preferred transcript").font(.title3.bold())
                    Text("Edit a separate practical version without changing the verbatim Stage 1 gold.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { requestDismiss() }
            }

            if eligibleFiles.isEmpty && !isDirty {
                ContentUnavailableView(
                    "No Stage 2 files yet", systemImage: "checkmark.seal",
                    description: Text("Complete and confirm a Stage 1 file first."))
            } else {
                HStack(alignment: .top, spacing: 16) {
                    fileList
                    if let file = detailFile {
                        detail(file)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 980, height: 700, alignment: .topLeading)
        .onAppear {
            refreshEligibleFiles()
            reloadStage2()
            loadCurrent()
        }
        .onChange(of: selectedAudioID) { _, _ in loadCurrent() }
        .onChange(of: runner.state.updatedAt) { _, _ in
            refreshEligibleFiles()
            reloadStage2()
            let currentSource = selectedAudioID.map(currentSourceText)
            if isDirty {
                if currentSource != loadedSourceText {
                    sourceChangedWhileEditing = true
                }
            } else {
                loadedAudioID = nil
            }
            reconcileSelection()
        }
        .onChange(of: eligibleFiles.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: preferredText) { _, _ in
            if suppressTextChange {
                suppressTextChange = false
            } else if loadedAudioID == selectedAudioID {
                isDirty = true
            }
        }
        .interactiveDismissDisabled(isDirty)
        .alert("Unsaved changes", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) { discardAndContinue() }
            Button("Cancel", role: .cancel) { pendingAudioID = nil }
        } message: {
            Text("Your Stage 2 edits have not been saved.")
        }
        .alert(
            "Stage 2 error",
            isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .onDisappear {
            eligibilityTask?.cancel()
            asr.stopPlayback()
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verified files").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(eligibleFiles) { file in
                        Button {
                            requestSelection(file.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.url.lastPathComponent).font(.callout.monospaced())
                                HStack {
                                    Text(formatTime(file.duration)).font(.caption)
                                    Spacer()
                                    Text(transcripts[file.id] == nil ? "Not saved" : "Saved")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                file.id == selectedAudioID
                                    ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 260, alignment: .topLeading)
    }

    private func detail(_ file: Layer1AudioFile) -> some View {
        let source = file.id == loadedAudioID ? loadedSourceText : ""
        return VStack(alignment: .leading, spacing: 10) {
            Text(file.url.lastPathComponent).font(.headline.monospaced())
            player(file)
            Text("Stage 1 · verbatim gold (read-only)").font(.caption.bold())
            if sourceChangedWhileEditing {
                Text("Stage 1 changed. Reload before continuing.")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                Text(source.isEmpty ? "No verified source text" : source)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150)
            .padding(8)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            HStack {
                Text("Stage 2 · preferred version").font(.caption.bold())
                Spacer()
                if isDirty {
                    Text("Unsaved changes").font(.caption).foregroundStyle(.orange)
                } else if transcripts[file.id] != nil {
                    Text("Saved").font(.caption).foregroundStyle(.green)
                }
            }
            TextEditor(text: $preferredText)
                .font(.body)
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .disabled(sourceChangedWhileEditing)
            HStack {
                Text("Stage 1 stays unchanged. This edit is saved separately.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if sourceChangedWhileEditing {
                    Button("Reload without edits") { requestReload() }
                }
                Button("Save Stage 2") { save(file) }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceChangedWhileEditing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func loadCurrent() {
        guard let first = eligibleFiles.first else { return }
        if selectedAudioID == nil {
            selectedAudioID = first.id
            loadCurrent(first.id)
        } else if let selectedAudioID {
            loadCurrent(selectedAudioID)
        }
    }

    private func refreshEligibleFiles() {
        let files = runner.files
        let structuralIDs = runner.store.structurallyVerifiedFileIDs()
        eligibilityTask?.cancel()
        eligibilityTask = Task {
            let ids = await Task.detached(priority: .utility) {
                Set(files.filter { Layer1GroundTruthStore.audioMatches($0) }.map(\.id))
            }.value
            guard !Task.isCancelled else { return }
            let eligibleIDs = structuralIDs.intersection(ids)
            eligibleFilesSnapshot = files.filter { eligibleIDs.contains($0.id) }
            reconcileSelection()
        }
    }

    private func reconcileSelection() {
        guard let first = eligibleFiles.first else {
            if isDirty {
                errorMessage = "Stage 1 changed while this file had unsaved edits. Save or copy the text before continuing."
                return
            }
            selectedAudioID = nil
            loadedAudioID = nil
            return
        }
        guard let selectedAudioID, eligibleFiles.contains(where: { $0.id == selectedAudioID }) else {
            if isDirty {
                pendingAudioID = first.id
                showDiscardAlert = true
            } else {
                self.selectedAudioID = first.id
            }
            return
        }
        loadCurrent(selectedAudioID)
    }

    func loadCurrent(_ audioID: String) {
        guard let file = eligibleFiles.first(where: { $0.id == audioID }) else { return }
        guard loadedAudioID != file.id else { return }
        loadedAudioID = file.id
        dirtyFileSnapshot = file
        asr.stopPlayback()
        let source = runner.store.stage2ReviewSourceText(audioID: file.id) ?? ""
        loadedSourceText = source
        let nextText = transcripts[file.id]?.preferredText ?? source
        suppressTextChange = preferredText != nextText
        preferredText = nextText
        isDirty = false
        sourceChangedWhileEditing = false
    }

    private func currentSourceText(_ audioID: String) -> String {
        Layer1GroundTruthStore.assemble(runner.segments.filter { $0.audioID == audioID })
    }

    private func save(_ file: Layer1AudioFile) {
        guard let source = runner.store.stage2SourceText(audioID: file.id),
            source == loadedSourceText
        else {
            sourceChangedWhileEditing = true
            errorMessage = "Stage 1 changed while this file was open. Reload it before saving."
            return
        }
        do {
            let entry = try runner.store.saveStage2Transcript(
                audioID: file.id, preferredText: preferredText)
            transcripts[file.id] = entry
            isDirty = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadStage2() {
        do {
            transcripts = try runner.store.stage2Transcripts().reduce(into: [:]) {
                $0[$1.audioID] = $1
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
