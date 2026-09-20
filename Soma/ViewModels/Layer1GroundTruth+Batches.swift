import Foundation

extension Layer1GroundTruthStore {
    func addBatch(count: Int, candidates: [Layer1AudioCandidate], now: Date = Date()) -> Layer1Batch? {
        let wanted = max(0, count)
        guard wanted > 0 else { return nil }
        let knownPaths = Set(state.files.map(\.path))
        let selected = candidates.filter { !knownPaths.contains($0.url.path) }.prefix(wanted)
        guard !selected.isEmpty else { return nil }
        let batchID = UUID().uuidString
        let fileIDs = selected.map { source in
            let id = source.url.standardizedFileURL.path
            let file = Layer1AudioFile(
                id: id, path: source.url.path, audioHash: Self.sha256(file: source.url),
                duration: source.duration,
                addedAt: now, batchIDs: [batchID], lastStatus: .queued)
            state.files.append(file)
            for spec in activeModelSpecs {
                state.modelRuns.append(
                    Layer1ModelRun(
                        id: UUID().uuidString, audioID: file.id, modelID: spec.id,
                        model: spec.title, family: spec.family, version: "unconfigured",
                        configuration: spec.configuration, startedAt: nil, finishedAt: nil,
                        duration: nil, attempt: 1, status: .queued, rawResponse: nil,
                        text: nil, wordTimestamps: [], error: nil))
            }
            return file.id
        }
        let batch = Layer1Batch(
            id: batchID, createdAt: now, requestedCount: wanted, fileIDs: fileIDs, status: .queued)
        state.batches.append(batch)
        appendHistory(event: "batch_added", payload: ["batchID": batchID, "count": fileIDs.count])
        refreshStatuses()
        save()
        return batch
    }

    func queuedRuns() -> [Layer1ModelRun] {
        state.modelRuns.filter { $0.status == .queued && activeModelIDs.contains($0.modelID) }.sorted {
            lhs, rhs in
            let left = state.files.first { $0.id == lhs.audioID }?.addedAt ?? .distantPast
            let right = state.files.first { $0.id == rhs.audioID }?.addedAt ?? .distantPast
            return left < right
        }
    }

    func latestRuns(for batchID: String) -> [Layer1ModelRun] {
        guard let batch = state.batches.first(where: { $0.id == batchID }) else { return [] }
        let fileIDs = Set(batch.fileIDs)
        return runsForLatestAttempts().filter { fileIDs.contains($0.audioID) }
    }

    func nextQueuedBatch() -> Layer1Batch? {
        state.batches.sorted { $0.createdAt < $1.createdAt }.first { batch in
            latestRuns(for: batch.id).contains {
                $0.status == .queued && activeModelIDs.contains($0.modelID)
            }
        }
    }

    func writeBatchManifest(batchID: String, modelID: String, runs: [Layer1ModelRun]) -> URL {
        let directoryURL = directory.appendingPathComponent("batch-manifests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appendingPathComponent("\(batchID)-\(modelID).jsonl")
        let lines = runs.compactMap { run -> String? in
            guard let file = file(for: run.audioID) else { return nil }
            let row: [String: Any] = [
                "id": run.id, "file": file.url.lastPathComponent, "audio": file.path,
                "audio_hash": file.audioHash,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: row),
                let line = String(data: data, encoding: .utf8)
            else { return nil }
            return line
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func failBatch(_ batchID: String, error: String) {
        let batch = state.batches.first { $0.id == batchID }
        let fileIDs = Set(batch?.fileIDs ?? [])
        guard !fileIDs.isEmpty else { return }
        fileIDs.forEach { invalidateStage2Transcript(audioID: $0) }
        state.segments.removeAll { fileIDs.contains($0.audioID) }
        let latestIDs = Set(latestRuns(for: batchID).map(\.id))
        for index in state.modelRuns.indices where latestIDs.contains(state.modelRuns[index].id) {
            let old = state.modelRuns[index]
            state.modelRuns[index] = Layer1ModelRun(
                id: old.id, audioID: old.audioID, modelID: old.modelID, model: old.model,
                family: old.family,
                version: old.version, configuration: old.configuration, startedAt: old.startedAt,
                finishedAt: Date(),
                duration: old.duration, attempt: old.attempt, status: .failed, rawResponse: old.rawResponse,
                text: old.text, wordTimestamps: old.wordTimestamps, error: error)
        }
        appendHistory(event: "batch_failed", payload: ["batchID": batchID, "error": error])
        refreshStatuses()
        save()
    }

    func retryFailed(fileIDs: Set<String>? = nil) {
        let latest = runsForLatestAttempts()
        let failed = latest.filter { run in
            run.status == .failed && (fileIDs == nil || fileIDs!.contains(run.audioID))
        }
        let batchIDs = Set(
            failed.flatMap { run in state.files.first { $0.id == run.audioID }?.batchIDs ?? [] })
        let runsToRetry = latest.filter { run in
            batchIDs.contains { batchID in
                state.batches.first { $0.id == batchID }?.fileIDs.contains(run.audioID) == true
            }
        }
        for old in runsToRetry {
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
        if !runsToRetry.isEmpty {
            appendHistory(
                event: "retry_failed_batches",
                payload: ["count": runsToRetry.count, "batches": batchIDs.count])
            refreshStatuses()
            save()
        }
    }
}
