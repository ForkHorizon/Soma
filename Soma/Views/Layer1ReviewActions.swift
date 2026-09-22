import SwiftUI

struct Layer1ReviewActions: ViewModifier {
    let asr: ASRManager
    @ObservedObject var runner: Layer1GroundTruthRunner
    @Binding var resultsPresented: Bool
    @Binding var clearAllPresented: Bool
    @Binding var deleteAudioID: String?
    @Binding var finalDeleteAudioID: String?
    let onDeleted: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $resultsPresented) {
                Layer1HistorySheet(asr: asr, runner: runner)
            }
            .confirmationDialog(
                "Clear all human results?", isPresented: $clearAllPresented, titleVisibility: .visible
            ) {
                Button("Clear human results", role: .destructive) {
                    Task { await runner.resetAllHumanResults() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Human decisions and gold for all \(runner.files.count) files will be cleared. AI results remain; Stage 2 results are also cleared."
                )
            }
            .confirmationDialog(
                "Delete this audio?",
                isPresented: Binding(
                    get: { deleteAudioID != nil }, set: { if !$0 { deleteAudioID = nil } }),
                titleVisibility: .visible
            ) {
                Button("Continue", role: .destructive) {
                    finalDeleteAudioID = deleteAudioID
                    deleteAudioID = nil
                }
                Button("Cancel", role: .cancel) { deleteAudioID = nil }
            } message: {
                Text("This starts a second confirmation. The selected WAV, TXT and all related results will be permanently deleted.")
            }
            .confirmationDialog(
                "Confirm permanent deletion",
                isPresented: Binding(
                    get: { finalDeleteAudioID != nil }, set: { if !$0 { finalDeleteAudioID = nil } }),
                titleVisibility: .visible
            ) {
                Button(
                    "Delete \(finalDeleteAudioID.flatMap { runner.store.file(for: $0)?.url.lastPathComponent } ?? "audio")",
                    role: .destructive
                ) {
                    guard let id = finalDeleteAudioID else { return }
                    finalDeleteAudioID = nil
                    Task {
                        await runner.deleteLayer1Audio(audioID: id, asr: asr)
                        onDeleted()
                    }
                }
                Button("Cancel", role: .cancel) { finalDeleteAudioID = nil }
            } message: {
                Text("This cannot be undone. The physical audio and every saved analysis result for this file will be removed.")
            }
    }
}
