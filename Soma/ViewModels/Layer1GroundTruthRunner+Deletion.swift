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

    func resetAllHumanResults() async {
        await stopAndWait()
        do {
            _ = try store.removeHumanReviewResults(audioIDs: Set(files.map(\.id)))
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        objectWillChange.send()
    }

    func resetAllStage2Results() async {
        await stopAndWait()
        do {
            let ids = Set(try store.stage2Transcripts().map(\.audioID))
            try store.removeStage2Transcripts(audioIDs: ids)
            store.appendHistory(event: "stage2_results_removed", payload: ["count": ids.count])
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        objectWillChange.send()
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
