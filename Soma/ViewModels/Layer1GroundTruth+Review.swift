import Foundation

extension Layer1GroundTruthStore {
    func markSegmentationNeedsReview(_ segmentID: String) {
        guard let index = state.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let audioID = state.segments[index].audioID
        state.segments[index].segmentationNeedsReview = true
        appendHistory(event: "segmentation_flagged", payload: ["segmentID": segmentID])
        removeHumanGold(audioID: audioID)
        invalidateStage2Transcript(audioID: audioID)
        save()
    }

    func clearSegmentationNeedsReview(_ segmentID: String) {
        guard let index = state.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let audioID = state.segments[index].audioID
        state.segments[index].segmentationNeedsReview = false
        appendHistory(event: "segmentation_flag_cleared", payload: ["segmentID": segmentID])
        invalidateStage2Transcript(audioID: audioID)
        writeHumanGoldIfComplete(audioID: audioID)
        save()
    }

    func segmentsForReview() -> [Layer1Segment] {
        state.segments.filter { $0.decision.status == .pending }.sorted {
            if $0.audioID != $1.audioID { return $0.audioID < $1.audioID }
            return $0.start < $1.start
        }
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
        fullyVerifiedFileIDs().count
    }

    func fullyVerifiedFileIDs() -> Set<String> {
        let structural = structurallyVerifiedFileIDs()
        return Set(state.files.filter { structural.contains($0.id) && currentAudioMatches($0) }.map(\.id))
    }

    func structurallyVerifiedFileIDs() -> Set<String> {
        Set(
            state.files.filter { file in
                let segments = state.segments.filter { $0.audioID == file.id }
                return hasCompleteCoverage(segments, duration: file.duration)
                    && segments.allSatisfy { $0.decision.status == .verified && !$0.segmentationNeedsReview }
            }.map(\.id))
    }

    private func hasCompleteCoverage(_ segments: [Layer1Segment], duration: Double) -> Bool {
        let ordered = segments.sorted { $0.start < $1.start }
        guard !ordered.isEmpty, ordered.first?.start ?? 1 <= 0.05,
            (ordered.last?.end ?? 0) + 0.05 >= duration,
            (ordered.last?.end ?? 0) <= duration + 0.05
        else { return false }
        for segment in ordered
        where segment.start < 0 || segment.end <= segment.start || segment.end > duration + 0.05 { return false }
        return zip(ordered, ordered.dropFirst()).allSatisfy { previous, next in
            next.start >= previous.end - 0.05 && next.start <= previous.end + 0.05
        }
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
        let modelRuns = runs.filter { activeModelIDs.contains($0.modelID) }
        if modelRuns.contains(where: { $0.status == .running }) { return .running }
        let failures = modelRuns.filter { $0.status == .failed }.count
        if failures == modelRuns.count, !modelRuns.isEmpty { return .failed }
        if failures > 0 { return .partial }
        if modelRuns.contains(where: { $0.status == .queued }) { return .queued }
        return modelRuns.count == activeModelIDs.count ? .completed : .failed
    }
}
