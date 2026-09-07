import SwiftUI

struct Layer1FileManagementView: View {
    let asr: ASRManager
    @ObservedObject var runner: Layer1GroundTruthRunner
    @Environment(\.dismiss) private var dismiss
    @State private var resetID: String?
    @State private var deleteID: String?
    @State private var resetAll = false
    @State private var deleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Layer 1 · Manage audio").font(.title3.bold())
                    Text("Listen to each file before resetting or permanently deleting it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            HStack(spacing: 8) {
                Button("Reset all Layer 1 results") { resetAll = true }
                    .disabled(runner.files.isEmpty)
                Button("Delete all Layer 1 audio", role: .destructive) { deleteAll = true }
                    .disabled(runner.files.isEmpty)
            }
            if let failure = runner.failure {
                StatusBanner(title: "Deletion needs attention", detail: failure, tone: .danger)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(runner.files) { file in fileRow(file) }
                }
            }
        }
        .padding(22)
        .frame(width: 900, height: 620, alignment: .topLeading)
        .confirmationDialog(
            "Reset all Layer 1 results?", isPresented: $resetAll, titleVisibility: .visible
        ) {
            Button("Reset results", role: .destructive) {
                Task { await runner.resetAllLayer1Results() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The audio and TXT files will remain. Model answers, segments, decisions and Stage 2 results will be removed.")
        }
        .confirmationDialog(
            "Delete all Layer 1 audio?", isPresented: $deleteAll, titleVisibility: .visible
        ) {
            Button("Delete audio", role: .destructive) {
                Task { await runner.deleteAllLayer1Audio(asr: asr) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes \(runner.files.count) WAV files, TXT files and all related Layer 1 and Layer 2 data.")
        }
        .confirmationDialog(
            "Reset this Layer 1 result?",
            isPresented: Binding(get: { resetID != nil }, set: { if !$0 { resetID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Reset result", role: .destructive) {
                guard let id = resetID else { return }
                resetID = nil
                Task { await runner.resetLayer1Result(audioID: id) }
            }
            Button("Cancel", role: .cancel) { resetID = nil }
        } message: {
            Text("The audio stays available. All Layer 1 results and the related Stage 2 result will be removed.")
        }
        .confirmationDialog(
            "Delete this audio permanently?",
            isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete audio", role: .destructive) {
                guard let id = deleteID else { return }
                deleteID = nil
                Task { await runner.deleteLayer1Audio(audioID: id, asr: asr) }
            }
            Button("Cancel", role: .cancel) { deleteID = nil }
        } message: {
            Text("The WAV, TXT, all model answers, human review, gold data and Stage 2 result will be deleted.")
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
                Text("\(String(format: "%.1f", file.duration)) s · \(runner.store.status(for: file.id).rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !FileManager.default.fileExists(atPath: file.url.path) {
                StatusChip(text: "Missing", tone: .danger)
            }
            Spacer()
            Button {
                asr.reveal(file.url)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).help("Show in Finder")
            Button("Reset") { resetID = file.id }
            Button("Delete", role: .destructive) { deleteID = file.id }
        }
        .padding(10)
        .background(SomaDesign.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
    }
}
