import Foundation

extension Layer1GroundTruthStore {
    func markRunning(
        _ runs: [Layer1ModelRun], configuration: [String: String], version: String,
        at date: Date = Date()
    ) {
        let ids = Set(runs.map(\.id))
        for index in state.modelRuns.indices where ids.contains(state.modelRuns[index].id) {
            let old = state.modelRuns[index]
            state.modelRuns[index] = Layer1ModelRun(
                id: old.id, audioID: old.audioID, modelID: old.modelID, model: old.model,
                family: old.family,
                version: version, configuration: configuration, startedAt: date, finishedAt: nil,
                duration: nil, attempt: old.attempt, status: .running, rawResponse: nil, text: nil,
                wordTimestamps: [], error: nil)
        }
        refreshStatuses()
        save()
    }

    func markRunning(
        _ runID: String, configuration: [String: String], version: String, at date: Date = Date()
    ) {
        guard let index = state.modelRuns.firstIndex(where: { $0.id == runID }) else { return }
        let old = state.modelRuns[index]
        state.modelRuns[index] = Layer1ModelRun(
            id: old.id, audioID: old.audioID, modelID: old.modelID, model: old.model, family: old.family,
            version: version, configuration: configuration, startedAt: date, finishedAt: nil,
            duration: nil, attempt: old.attempt, status: .running, rawResponse: nil, text: nil,
            wordTimestamps: [], error: nil)
        refreshStatuses()
        save()
    }

    func finish(_ runID: String, completion: Layer1RunCompletion, at date: Date = Date()) {
        guard let index = state.modelRuns.firstIndex(where: { $0.id == runID }) else { return }
        let old = state.modelRuns[index]
        state.modelRuns[index] = Layer1ModelRun(
            id: old.id, audioID: old.audioID, modelID: old.modelID, model: old.model, family: old.family,
            version: completion.version, configuration: old.configuration, startedAt: old.startedAt,
            finishedAt: date, duration: completion.duration, attempt: old.attempt,
            status: completion.status,
            rawResponse: completion.rawResponse, text: completion.text,
            wordTimestamps: completion.timestamps,
            error: completion.error)
        var history: [String: Any] = ["runID": runID, "status": completion.status.rawValue]
        if let error = completion.error { history["error"] = error }
        appendHistory(event: "model_run_finished", payload: history)
        refreshStatuses()
        if completion.status != .running { buildSegmentsIfReady(audioID: old.audioID) }
        save()
    }

    func saveDecision(
        segmentID: String, text: String?, action: Layer1HumanAction,
        sourceModelID: String? = nil, now: Date = Date()
    ) {
        guard let index = state.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let audioID = state.segments[index].audioID
        let previous = state.segments[index].decision
        state.segments[index].decision = Layer1SegmentDecision(
            status: .verified, text: text, normalizedText: Self.normalize(text ?? ""), action: action,
            sourceModelID: sourceModelID, createdAt: previous.createdAt ?? now, updatedAt: now)
        state.lastReviewSegmentID = segmentID
        var history: [String: Any] = ["segmentID": segmentID, "action": action.rawValue]
        if let text { history["text"] = text }
        if let sourceModelID { history["sourceModelID"] = sourceModelID }
        appendHistory(event: "human_decision", payload: history)
        refreshStatuses()
        writeHumanGoldIfComplete(audioID: audioID)
        save()
    }
}
