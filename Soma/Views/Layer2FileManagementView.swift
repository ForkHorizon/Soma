import SwiftUI

struct Layer2FileManagementView: View {
    let asr: ASRManager
    @ObservedObject var runner: Layer1GroundTruthRunner
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var resultID: String?
    @State private var audioID: String?
    @State private var deleteAll = false
    @State private var errorMessage: String?

    private var files: [Layer1AudioFile] {
        let ids = runner.store.structurallyVerifiedFileIDs()
        return runner.files.filter {
            ids.contains($0.id) && Layer1GroundTruthStore.audioMatches($0)
        }
    }

    private var hasStage2Results: Bool {
        guard let entries = try? runner.store.stage2Transcripts() else { return false }
        return !entries.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Layer 2 · Manage audio").font(.title3.bold())
                    Text("Listen to verified audio and remove preferred results or the file itself.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            Button("Delete all Stage 2 results", role: .destructive) { deleteAll = true }
                .disabled(!hasStage2Results)
            if let errorMessage {
                StatusBanner(title: "Stage 2 deletion failed", detail: errorMessage, tone: .danger)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(files) { file in fileRow(file) }
                }
            }
        }
        .padding(22)
        .frame(width: 900, height: 620, alignment: .topLeading)
        .confirmationDialog(
            "Delete all Stage 2 results?", isPresented: $deleteAll, titleVisibility: .visible
        ) {
            Button("Delete results", role: .destructive) { deleteAllResults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Preferred transcripts will be removed. Layer 1 and the audio files will remain.")
        }
        .confirmationDialog(
            "Delete this Stage 2 result?",
            isPresented: Binding(get: { resultID != nil }, set: { if !$0 { resultID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete result", role: .destructive) {
                guard let id = resultID else { return }
                resultID = nil
                deleteResult(id)
            }
            Button("Cancel", role: .cancel) { resultID = nil }
        } message: {
            Text("The verified Layer 1 text and audio will remain.")
        }
        .confirmationDialog(
            "Delete this audio permanently?",
            isPresented: Binding(get: { audioID != nil }, set: { if !$0 { audioID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete audio", role: .destructive) {
                guard let id = audioID else { return }
                audioID = nil
                Task {
                    await runner.deleteLayer1Audio(audioID: id, asr: asr)
                    onChanged()
                }
            }
            Button("Cancel", role: .cancel) { audioID = nil }
        } message: {
            Text("The WAV, TXT, Layer 1, human review and Stage 2 data will be deleted.")
        }
    }

    private func fileRow(_ file: Layer1AudioFile) -> some View {
        HStack(spacing: 10) {
            Button {
                asr.togglePlayback(file.url)
            } label: {
                Image(systemName: asr.playingURL == file.url ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.url.lastPathComponent).font(.callout.monospaced())
                Text(String(format: "%.1f s", file.duration)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                asr.reveal(file.url)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).help("Show in Finder")
            Button("Delete result") { resultID = file.id }
            Button("Delete audio", role: .destructive) { audioID = file.id }
        }
        .padding(10)
        .background(SomaDesign.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
    }

    private func deleteResult(_ id: String) {
        do {
            try runner.store.removeStage2Transcripts(audioIDs: Set([id]))
            errorMessage = nil
            onChanged()
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteAllResults() {
        do {
            let ids = Set(try runner.store.stage2Transcripts().map(\.audioID))
            try runner.store.removeStage2Transcripts(audioIDs: ids)
            errorMessage = nil
            onChanged()
        } catch { errorMessage = error.localizedDescription }
    }
}
