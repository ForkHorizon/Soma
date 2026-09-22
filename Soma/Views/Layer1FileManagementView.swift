import SwiftUI

struct Layer1FileManagementView: View {
    let asr: ASRManager
    @ObservedObject var runner: Layer1GroundTruthRunner
    @Environment(\.dismiss) private var dismiss
    @State private var resetID: String?
    @State private var deleteID: String?
    @State private var finalDeleteID: String?
    @State private var resetAll = false

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
                Button("Clear all AI results", role: .destructive) { resetAll = true }
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
            "Clear all AI results?", isPresented: $resetAll, titleVisibility: .visible
        ) {
            Button("Clear AI results", role: .destructive) {
                Task { await runner.resetAllLayer1Results() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(runner.files.count) files will have AI, human-review and Stage 2 results cleared. WAV and TXT files remain.")
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
                finalDeleteID = id
            }
            Button("Cancel", role: .cancel) { deleteID = nil }
        } message: {
            Text("This starts a second confirmation. The WAV, TXT and all related results will be permanently deleted.")
        }
        .confirmationDialog(
            "Confirm permanent deletion",
            isPresented: Binding(get: { finalDeleteID != nil }, set: { if !$0 { finalDeleteID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete \(finalDeleteID.flatMap { runner.store.file(for: $0)?.url.lastPathComponent } ?? "audio")", role: .destructive) {
                guard let id = finalDeleteID else { return }
                finalDeleteID = nil
                Task { await runner.deleteLayer1Audio(audioID: id, asr: asr) }
            }
            Button("Cancel", role: .cancel) { finalDeleteID = nil }
        } message: {
            Text("This cannot be undone. The physical audio and every saved analysis result will be removed.")
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
