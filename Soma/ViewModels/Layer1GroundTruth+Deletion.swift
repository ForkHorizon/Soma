import Foundation

enum Layer1DeletionError: LocalizedError {
    case stateUnavailable
    case stateCouldNotSave

    var errorDescription: String? {
        switch self {
        case .stateUnavailable: return "Layer 1 state is unavailable and cannot be changed."
        case .stateCouldNotSave: return "Layer 1 state could not be saved after deletion."
        }
    }
}

extension Layer1GroundTruthStore {
    @discardableResult
    func removeLayer1Results(
        audioIDs: Set<String>, historyEvent: String = "layer1_results_removed"
    ) throws -> Set<String> {
        guard canPersistState else { throw Layer1DeletionError.stateUnavailable }
        let files = state.files.filter { audioIDs.contains($0.id) }
        guard !files.isEmpty else { return [] }
        let ids = Set(files.map(\.id))
        let batchIDs = Set(files.flatMap(\.batchIDs)).union(
            state.batches.filter { batch in batch.fileIDs.contains { ids.contains($0) } }.map(\.id))
        let removedSegments = Set(state.segments.filter { ids.contains($0.audioID) }.map(\.id))

        try removeStage2Transcripts(audioIDs: ids)
        files.forEach { removeHumanGold(audioID: $0.id) }
        state.files.removeAll { ids.contains($0.id) }
        state.modelRuns.removeAll { ids.contains($0.audioID) }
        state.segments.removeAll { ids.contains($0.audioID) }
        state.batches = state.batches.compactMap { batch in
            let remaining = batch.fileIDs.filter { !ids.contains($0) }
            guard !remaining.isEmpty else { return nil }
            return Layer1Batch(
                id: batch.id, createdAt: batch.createdAt, requestedCount: batch.requestedCount,
                fileIDs: remaining, status: batch.status)
        }
        if let last = state.lastReviewSegmentID, removedSegments.contains(last) {
            state.lastReviewSegmentID = nil
        }
        removeBatchManifests(batchIDs, audioIDs: ids)
        refreshStatuses()
        guard save() else { throw Layer1DeletionError.stateCouldNotSave }
        appendHistory(
            event: historyEvent,
            payload: ["count": ids.count, "audioIDs": ids.sorted()])
        return ids
    }

    private func removeBatchManifests(_ batchIDs: Set<String>, audioIDs: Set<String>) {
        guard !batchIDs.isEmpty || !audioIDs.isEmpty else { return }
        let manifests = directory.appendingPathComponent("batch-manifests", isDirectory: true)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: manifests, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for file in files {
            let hasBatchReference = batchIDs.contains {
                file.lastPathComponent.hasPrefix("\($0)-")
            }
            let hasAudioReference =
                (try? String(contentsOf: file, encoding: .utf8)).map { contents in
                    audioIDs.contains { contents.contains($0) }
                } ?? false
            if hasBatchReference || hasAudioReference { try? FileManager.default.removeItem(at: file) }
        }
    }
}
