import SwiftUI

struct Layer2ClearResultsActions: ViewModifier {
    @ObservedObject var runner: Layer1GroundTruthRunner
    @Binding var presented: Bool
    let onCleared: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Clear all Stage 2 results?", isPresented: $presented, titleVisibility: .visible
        ) {
            Button("Clear Stage 2 results", role: .destructive) {
                Task {
                    await runner.resetAllStage2Results()
                    onCleared()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Preferred transcripts for all saved files will be removed. Layer 1, AI results, human decisions and audio remain.")
        }
    }
}

extension Layer2PreferredReviewView {
    var clearResultsButton: some View {
        Button("Clear all Stage 2 results", role: .destructive) { clearAllPresented = true }
            .disabled(isDirty || transcripts.isEmpty)
    }

    func didClearStage2Results() {
        errorMessage = runner.failure
        if errorMessage == nil {
            reloadStage2()
            refreshEligibleFiles()
        }
    }

    func requestSelection(_ audioID: String) {
        guard audioID != selectedAudioID else { return }
        if isDirty {
            pendingAudioID = audioID
            showDiscardAlert = true
        } else {
            selectedAudioID = audioID
        }
    }

    func requestDismiss() {
        guard isDirty else {
            asr.stopPlayback()
            dismiss()
            return
        }
        pendingAudioID = nil
        showDiscardAlert = true
    }

    func requestReload() {
        pendingAudioID = selectedAudioID
        showDiscardAlert = true
    }

    func discardAndContinue() {
        isDirty = false
        sourceChangedWhileEditing = false
        guard let pendingAudioID else {
            asr.stopPlayback()
            dismiss()
            return
        }
        self.pendingAudioID = nil
        loadedAudioID = nil
        let target =
            eligibleFiles.contains { $0.id == pendingAudioID }
            ? pendingAudioID : eligibleFiles.first?.id
        selectedAudioID = target
        if let target { loadCurrent(target) }
    }

    func formatTime(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}
