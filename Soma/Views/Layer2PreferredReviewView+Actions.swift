import SwiftUI

extension Layer2PreferredReviewView {
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
