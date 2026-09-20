import Foundation

extension Layer1GroundTruthStore {
    func retryLegacyEnvironmentFailures() {
        let failed = runsForLatestAttempts().filter {
            $0.status == .failed && ($0.error ?? "").contains("ffmpeg")
        }
        guard !failed.isEmpty else { return }
        let batchIDs = Set(
            failed.flatMap { run in state.files.first { $0.id == run.audioID }?.batchIDs ?? [] })
        requeueWholeBatches(batchIDs)
        appendHistory(event: "retry_legacy_environment_failures", payload: ["batches": batchIDs.count])
        refreshStatuses()
    }

    func normalizePartiallyQueuedBatches() {
        let affected = state.batches.filter { batch in
            let statuses = Set(
                latestRuns(for: batch.id).filter { activeModelIDs.contains($0.modelID) }.map(\.status))
            return statuses.contains(.queued)
                && (statuses.contains(.completed) || statuses.contains(.failed))
        }
        guard !affected.isEmpty else { return }
        requeueWholeBatches(Set(affected.map(\.id)))
        appendHistory(event: "normalize_partial_batches", payload: ["batches": affected.count])
        refreshStatuses()
    }

    private func requeueWholeBatches(_ batchIDs: Set<String>) {
        let latest = runsForLatestAttempts()
        for batchID in batchIDs {
            let fileIDs = Set(state.batches.first { $0.id == batchID }?.fileIDs ?? [])
            fileIDs.forEach { invalidateStage2Transcript(audioID: $0) }
            state.segments.removeAll { fileIDs.contains($0.audioID) }
            let batchRuns = latestRuns(for: batchID)
            for old in latest
            where batchRuns.contains(where: { $0.id == old.id }) && old.status != .queued {
                guard activeModelIDs.contains(old.modelID),
                    let spec = Layer1ModelSpec.catalog.first(where: { $0.id == old.modelID })
                else {
                    continue
                }
                state.modelRuns.append(
                    Layer1ModelRun(
                        id: UUID().uuidString, audioID: old.audioID, modelID: spec.id, model: spec.title,
                        family: spec.family, version: "unconfigured", configuration: spec.configuration,
                        startedAt: nil, finishedAt: nil, duration: nil, attempt: old.attempt + 1,
                        status: .queued, rawResponse: nil, text: nil, wordTimestamps: [], error: nil))
            }
        }
    }

    func requeueInterruptedRuns() {
        for index in state.modelRuns.indices where state.modelRuns[index].status == .running {
            state.modelRuns[index].status = .queued
            state.modelRuns[index].error = "Run stopped before completion; queued for resume"
        }
        refreshStatuses()
        save()
    }
}
