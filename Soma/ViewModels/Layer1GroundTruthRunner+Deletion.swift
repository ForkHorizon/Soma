import Combine
import Foundation

extension Layer1GroundTruthRunner {
    func stopAndWait() async {
        let task = workerTask
        if isRunning { stop() }
        await task?.value
    }

    func resetLayer1Result(audioID: String) async {
        await stopAndWait()
        resetLayer1Results(audioIDs: Set([audioID]))
    }

    func resetAllLayer1Results() async {
        await stopAndWait()
        resetLayer1Results(audioIDs: Set(files.map(\.id)))
    }

    func deleteLayer1Audio(audioID: String, asr: ASRManager) async {
        await stopAndWait()
        guard let file = store.file(for: audioID) else { return }
        guard asr.deleteRecording(file.url) else {
            failure = asr.status
            objectWillChange.send()
            return
        }
        removeLayer1Results(audioIDs: Set([audioID]), historyEvent: "layer1_audio_deleted")
    }

    func deleteAllLayer1Audio(asr: ASRManager) async {
        await stopAndWait()
        let ids = Set(files.map(\.id))
        guard asr.deleteAllRecordings() else {
            failure = asr.status
            objectWillChange.send()
            return
        }
        removeLayer1Results(audioIDs: ids, historyEvent: "layer1_audio_deleted")
    }

    private func resetLayer1Results(audioIDs: Set<String>) {
        do {
            _ = try store.removeLayer1Results(audioIDs: audioIDs)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        objectWillChange.send()
    }

    private func removeLayer1Results(audioIDs: Set<String>, historyEvent: String) {
        do {
            _ = try store.removeLayer1Results(audioIDs: audioIDs, historyEvent: historyEvent)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        objectWillChange.send()
    }
}
