import Foundation

extension Layer1GroundTruthStore {
    func markSegmentationNeedsReview(_ segmentID: String) {
        guard let index = state.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        state.segments[index].segmentationNeedsReview = true
        appendHistory(event: "segmentation_flagged", payload: ["segmentID": segmentID])
        save()
    }

    func segmentsForReview() -> [Layer1Segment] {
        state.segments.filter { $0.decision.status == .pending }.sorted { $0.id < $1.id }
    }

    func file(for id: String) -> Layer1AudioFile? { state.files.first { $0.id == id } }

    func currentRun(audioID: String, modelID: String) -> Layer1ModelRun? {
        state.modelRuns.filter { $0.audioID == audioID && $0.modelID == modelID }.max {
            $0.attempt < $1.attempt
        }
    }

    func runs(for audioID: String) -> [Layer1ModelRun] {
        Layer1ModelSpec.catalog.compactMap { currentRun(audioID: audioID, modelID: $0.id) }
    }

    func completeFilesCount() -> Int { state.files.filter { status(for: $0.id) == .completed }.count }

    func fullyVerifiedFilesCount() -> Int {
        state.files.filter { file in
            let segments = state.segments.filter { $0.audioID == file.id }
            return !segments.isEmpty && segments.allSatisfy { $0.decision.status == .verified }
        }.count
    }

    func fullyVerifiedFileIDs() -> Set<String> {
        Set(
            state.files.filter { file in
                let segments = state.segments.filter { $0.audioID == file.id }
                return !segments.isEmpty && segments.allSatisfy { $0.decision.status == .verified }
            }.map(\.id))
    }

    var resumeSegmentID: String? {
        guard let last = state.lastReviewSegmentID,
            let index = state.segments.firstIndex(where: { $0.id == last })
        else { return nil }
        return state.segments.dropFirst(index + 1).first(where: { $0.decision.status == .pending })?.id
            ?? state.segments.first(where: { $0.decision.status == .pending })?.id
    }

    func readyFilesCount() -> Int {
        state.files.filter { file in
            state.segments.contains { segment in
                segment.audioID == file.id && segment.decision.status == .pending
            }
        }.count
    }

    func verifiedSegmentsCount() -> Int {
        state.segments.filter { $0.decision.status == .verified }.count
    }

    func status(for audioID: String) -> Layer1BatchStatus {
        let runs = runs(for: audioID)
        let modelRuns = runs.filter { allModelIDs.contains($0.modelID) }
        if modelRuns.contains(where: { $0.status == .running }) { return .running }
        let failures = modelRuns.filter { $0.status == .failed }.count
        if failures == modelRuns.count, !modelRuns.isEmpty { return .failed }
        if failures > 0 { return .partial }
        if modelRuns.contains(where: { $0.status == .queued }) { return .queued }
        return modelRuns.count == allModelIDs.count ? .completed : .failed
    }
}
