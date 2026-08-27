import CryptoKit
import Foundation

enum Layer1BatchStatus: String, Codable, CaseIterable { case queued, running, completed, partial, failed }
enum Layer1ModelRunStatus: String, Codable { case queued, running, completed, failed }
enum Layer1HumanAction: String, Codable { case selectedModel, selectedAndEdited, manual, noSpeech, unclear }
enum Layer1ReviewStatus: String, Codable { case pending, verified }

struct Layer1ModelSpec: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let family: String
    let optional: Bool
    var identifiable: String { id }

    var configuration: [String: String] {
        ["model": id, "family": family, "audio_scope": "full_original", "language": "ru"]
    }

    static let catalog: [Layer1ModelSpec] = [
        .init(id: "whisper-large-v3-mlx", title: "Whisper large-v3 (MLX)", family: "Whisper", optional: false),
        .init(id: "gigaam-v2-rnnt", title: "GigaAM v2 RNNT", family: "GigaAM", optional: false),
        .init(id: "gigaam-v2-ctc", title: "GigaAM v2 CTC", family: "GigaAM", optional: false),
        .init(id: "gigaam-v3-rnnt", title: "GigaAM v3 RNNT", family: "GigaAM", optional: false),
        .init(id: "gigaam-v3-e2e-ctc", title: "GigaAM v3 e2e-CTC", family: "GigaAM", optional: false),
        .init(id: "parakeet-tdt-v3", title: "Parakeet-TDT-v3", family: "Parakeet", optional: false),
        .init(id: "qwen3-asr-1.7b", title: "Qwen3-ASR-1.7B", family: "Qwen", optional: false),
        .init(id: "vosk-small-ru", title: "Vosk small-ru", family: "Vosk", optional: false),
        .init(id: "wav2vec2-xls-r-ru", title: "wav2vec2 XLS-R ru", family: "wav2vec2", optional: false),
        .init(id: "mms-1b-rus", title: "MMS-1B rus", family: "MMS", optional: false),
        .init(id: "faster-whisper", title: "faster-whisper", family: "Whisper", optional: false),
        .init(id: "gigaam-multilingual", title: "GigaAM-Multilingual", family: "GigaAM", optional: true),
    ]
}

struct Layer1AudioCandidate: Hashable {
    let url: URL
    let date: Date
    let duration: Double
}

struct Layer1AudioFile: Codable, Hashable, Identifiable {
    let id: String
    let path: String
    let audioHash: String
    let duration: Double
    let addedAt: Date
    var batchIDs: [String]
    var lastStatus: Layer1BatchStatus

    var url: URL { URL(fileURLWithPath: path) }
}

struct Layer1WordTimestamp: Codable, Hashable {
    let word: String
    let start: Double
    let end: Double
}

struct Layer1ModelRun: Codable, Hashable, Identifiable {
    let id: String
    let audioID: String
    let modelID: String
    let model: String
    let family: String
    let version: String
    let configuration: [String: String]
    let startedAt: Date?
    let finishedAt: Date?
    let duration: Double?
    let attempt: Int
    var status: Layer1ModelRunStatus
    var rawResponse: String?
    var text: String?
    var wordTimestamps: [Layer1WordTimestamp]
    var error: String?
}

struct Layer1ModelSuggestion: Codable, Hashable {
    let modelID: String
    let model: String
    let status: Layer1ModelRunStatus
    let text: String?
    let error: String?
    let runID: String?
}

struct Layer1SegmentDecision: Codable, Hashable {
    var status: Layer1ReviewStatus
    var text: String?
    var normalizedText: String?
    var action: Layer1HumanAction?
    var sourceModelID: String?
    var createdAt: Date?
    var updatedAt: Date?
}

struct Layer1Segment: Codable, Hashable, Identifiable {
    let id: String
    let audioID: String
    let start: Double
    let end: Double
    let segmentationAlgorithmVersion: String
    let sourceWordRange: Range<Int>?
    var modelSuggestions: [String: Layer1ModelSuggestion]
    let proposalOrder: [String]
    var segmentationNeedsReview: Bool
    var decision: Layer1SegmentDecision
}

struct Layer1Batch: Codable, Hashable, Identifiable {
    let id: String
    let createdAt: Date
    let requestedCount: Int
    let fileIDs: [String]
    var status: Layer1BatchStatus
}

struct Layer1State: Codable {
    static let currentSchemaVersion = 1
    var schemaVersion = currentSchemaVersion
    var createdAt = Date()
    var updatedAt = Date()
    var batches: [Layer1Batch] = []
    var files: [Layer1AudioFile] = []
    var modelRuns: [Layer1ModelRun] = []
    var segments: [Layer1Segment] = []
    var lastReviewSegmentID: String?
}

/// The first ground-truth layer is deliberately a different namespace and
/// schema from every previous Ground Truth artifact. It stores raw model
/// replies and append-only review events, so later normalization rules can be
/// changed without decoding the audio again.
final class Layer1GroundTruthStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soma/GroundTruthLayer1", isDirectory: true)
    }

    let directory: URL
    private(set) var state: Layer1State

    init(directory: URL = Layer1GroundTruthStore.directory) {
        self.directory = directory
        self.state = Self.loadState(from: directory) ?? Layer1State()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        bootstrapCommandConfiguration()
        recoverInterruptedRuns()
        retryLegacyEnvironmentFailures()
        normalizePartiallyQueuedBatches()
        save()
    }

    var stateURL: URL { directory.appendingPathComponent("state.json") }
    var historyURL: URL { directory.appendingPathComponent("history.jsonl") }
    var commandConfigurationURL: URL { directory.appendingPathComponent("model_commands.json") }

    var requiredModelIDs: Set<String> { Set(Layer1ModelSpec.catalog.filter { !$0.optional }.map(\.id)) }
    var allModelIDs: [String] { Layer1ModelSpec.catalog.map(\.id) }

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
                id: id, path: source.url.path,
                audioHash: Self.sha256(file: source.url), duration: source.duration,
                addedAt: now, batchIDs: [batchID], lastStatus: .queued)
            state.files.append(file)
            for spec in Layer1ModelSpec.catalog {
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
            id: batchID, createdAt: now, requestedCount: wanted,
            fileIDs: fileIDs, status: .queued)
        state.batches.append(batch)
        appendHistory(event: "batch_added", payload: ["batchID": batchID, "count": fileIDs.count])
        refreshStatuses()
        save()
        return batch
    }

    func queuedRuns() -> [Layer1ModelRun] {
        state.modelRuns.filter { $0.status == .queued }.sorted { lhs, rhs in
            let l = state.files.first { $0.id == lhs.audioID }?.addedAt ?? .distantPast
            let r = state.files.first { $0.id == rhs.audioID }?.addedAt ?? .distantPast
            return l < r
        }
    }

    func latestRuns(for batchID: String) -> [Layer1ModelRun] {
        guard let batch = state.batches.first(where: { $0.id == batchID }) else { return [] }
        let fileIDs = Set(batch.fileIDs)
        return runsForLatestAttempts().filter { fileIDs.contains($0.audioID) }
    }

    func nextQueuedBatch() -> Layer1Batch? {
        state.batches.sorted { $0.createdAt < $1.createdAt }.first { batch in
            latestRuns(for: batch.id).contains { $0.status == .queued }
        }
    }

    func markRunning(
        _ runs: [Layer1ModelRun], configuration: [String: String], version: String,
        at date: Date = Date()
    ) {
        let ids = Set(runs.map(\.id))
        for index in state.modelRuns.indices where ids.contains(state.modelRuns[index].id) {
            let old = state.modelRuns[index]
            state.modelRuns[index] = Layer1ModelRun(
                id: old.id, audioID: old.audioID, modelID: old.modelID,
                model: old.model, family: old.family, version: version,
                configuration: configuration, startedAt: date, finishedAt: nil,
                duration: nil, attempt: old.attempt, status: .running,
                rawResponse: nil, text: nil, wordTimestamps: [], error: nil)
        }
        refreshStatuses()
        save()
    }

    func writeBatchManifest(batchID: String, modelID: String, runs: [Layer1ModelRun]) -> URL {
        let directoryURL = directory.appendingPathComponent("batch-manifests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appendingPathComponent("\(batchID)-\(modelID).jsonl")
        let lines = runs.compactMap { run -> String? in
            guard let file = file(for: run.audioID) else { return nil }
            let row: [String: Any] = [
                "id": run.id, "file": file.url.lastPathComponent,
                "audio": file.path, "audio_hash": file.audioHash,
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
        state.segments.removeAll { fileIDs.contains($0.audioID) }
        let latestIDs = Set(latestRuns(for: batchID).map(\.id))
        for index in state.modelRuns.indices where latestIDs.contains(state.modelRuns[index].id) {
            let old = state.modelRuns[index]
            state.modelRuns[index] = Layer1ModelRun(
                id: old.id, audioID: old.audioID, modelID: old.modelID,
                model: old.model, family: old.family, version: old.version,
                configuration: old.configuration, startedAt: old.startedAt,
                finishedAt: Date(), duration: old.duration, attempt: old.attempt,
                status: .failed, rawResponse: old.rawResponse, text: old.text,
                wordTimestamps: old.wordTimestamps, error: error)
        }
        appendHistory(event: "batch_failed", payload: ["batchID": batchID, "error": error])
        refreshStatuses()
        save()
    }

    func retryFailed(fileIDs: Set<String>? = nil) {
        let latest = runsForLatestAttempts()
        let failed = latest.filter { $0.status == .failed && (fileIDs == nil || fileIDs!.contains($0.audioID)) }
        let batchIDs = Set(
            failed.flatMap { run in
                state.files.first { $0.id == run.audioID }?.batchIDs ?? []
            })
        let runsToRetry = latest.filter { run in
            batchIDs.contains { batchID in
                state.batches.first { $0.id == batchID }?.fileIDs.contains(run.audioID) == true
            }
        }
        for old in runsToRetry {
            guard let spec = Layer1ModelSpec.catalog.first(where: { $0.id == old.modelID }) else { continue }
            state.modelRuns.append(
                Layer1ModelRun(
                    id: UUID().uuidString, audioID: old.audioID, modelID: spec.id,
                    model: spec.title, family: spec.family, version: "unconfigured",
                    configuration: spec.configuration, startedAt: nil, finishedAt: nil,
                    duration: nil, attempt: old.attempt + 1, status: .queued,
                    rawResponse: nil, text: nil, wordTimestamps: [], error: nil))
        }
        if !runsToRetry.isEmpty {
            appendHistory(event: "retry_failed_batches", payload: ["count": runsToRetry.count, "batches": batchIDs.count])
            refreshStatuses()
            save()
        }
    }

    /// Requeue the complete user batch when old runs failed only because the
    /// app did not expose Homebrew's ffmpeg to decoder subprocesses.
    private func retryLegacyEnvironmentFailures() {
        let failed = runsForLatestAttempts().filter {
            $0.status == .failed && ($0.error ?? "").contains("ffmpeg")
        }
        guard !failed.isEmpty else { return }
        let batchIDs = Set(
            failed.flatMap { run in
                state.files.first { $0.id == run.audioID }?.batchIDs ?? []
            })
        requeueWholeBatches(batchIDs)
        appendHistory(event: "retry_legacy_environment_failures", payload: ["batches": batchIDs.count])
        refreshStatuses()
    }

    /// Old Layer-1 may already contain a partial retry (some latest runs
    /// completed while the remaining heads failed). Under atomic semantics the
    /// completed heads must be rerun too, otherwise stale segments survive.
    private func normalizePartiallyQueuedBatches() {
        let affected = state.batches.filter { batch in
            let statuses = Set(latestRuns(for: batch.id).map(\.status))
            return statuses.contains(.queued) && (statuses.contains(.completed) || statuses.contains(.failed))
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
            state.segments.removeAll { fileIDs.contains($0.audioID) }
            for old in latest where latestRuns(for: batchID).contains(where: { $0.id == old.id }) && old.status != .queued {
                guard let spec = Layer1ModelSpec.catalog.first(where: { $0.id == old.modelID }) else { continue }
                state.modelRuns.append(
                    Layer1ModelRun(
                        id: UUID().uuidString, audioID: old.audioID, modelID: spec.id,
                        model: spec.title, family: spec.family, version: "unconfigured",
                        configuration: spec.configuration, startedAt: nil, finishedAt: nil,
                        duration: nil, attempt: old.attempt + 1, status: .queued,
                        rawResponse: nil, text: nil, wordTimestamps: [], error: nil))
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

    func markRunning(
        _ runID: String, configuration: [String: String], version: String,
        at date: Date = Date()
    ) {
        guard let index = state.modelRuns.firstIndex(where: { $0.id == runID }) else { return }
        state.modelRuns[index].status = .running
        state.modelRuns[index] = Layer1ModelRun(
            id: state.modelRuns[index].id,
            audioID: state.modelRuns[index].audioID, modelID: state.modelRuns[index].modelID,
            model: state.modelRuns[index].model, family: state.modelRuns[index].family,
            version: version, configuration: configuration,
            startedAt: date, finishedAt: nil, duration: nil, attempt: state.modelRuns[index].attempt,
            status: .running, rawResponse: nil, text: nil, wordTimestamps: [], error: nil)
        refreshStatuses()
        save()
    }

    func finish(
        _ runID: String, status: Layer1ModelRunStatus, version: String,
        rawResponse: String, text: String?, timestamps: [Layer1WordTimestamp],
        error: String?, duration: Double, at date: Date = Date()
    ) {
        guard let index = state.modelRuns.firstIndex(where: { $0.id == runID }) else { return }
        let old = state.modelRuns[index]
        state.modelRuns[index] = Layer1ModelRun(
            id: old.id, audioID: old.audioID, modelID: old.modelID,
            model: old.model, family: old.family, version: version, configuration: old.configuration,
            startedAt: old.startedAt, finishedAt: date, duration: duration, attempt: old.attempt,
            status: status, rawResponse: rawResponse, text: text, wordTimestamps: timestamps, error: error)
        var history: [String: Any] = ["runID": runID, "status": status.rawValue]
        if let error { history["error"] = error }
        appendHistory(event: "model_run_finished", payload: history)
        refreshStatuses()
        if status != .running { buildSegmentsIfReady(audioID: old.audioID) }
        save()
    }

    func saveDecision(
        segmentID: String, text: String?, action: Layer1HumanAction,
        sourceModelID: String? = nil, now: Date = Date()
    ) {
        guard let index = state.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let previous = state.segments[index].decision
        state.segments[index].decision = Layer1SegmentDecision(
            status: .verified, text: text, normalizedText: Self.normalize(text ?? ""),
            action: action, sourceModelID: sourceModelID,
            createdAt: previous.createdAt ?? now, updatedAt: now)
        state.lastReviewSegmentID = segmentID
        var history: [String: Any] = ["segmentID": segmentID, "action": action.rawValue]
        if let text { history["text"] = text }
        if let sourceModelID { history["sourceModelID"] = sourceModelID }
        appendHistory(event: "human_decision", payload: history)
        refreshStatuses()
        save()
    }

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
        state.modelRuns.filter { $0.audioID == audioID && $0.modelID == modelID }.max { $0.attempt < $1.attempt }
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
    func verifiedSegmentsCount() -> Int { state.segments.filter { $0.decision.status == .verified }.count }

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

    func save() {
        state.updatedAt = Date()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    static func normalize(_ text: String) -> String {
        var output = ""
        for character in text.lowercased() {
            if character.isWhitespace {
                output.append(" ")
            } else if "+#*".contains(character) {
                output.append(character)
            } else if character.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) {
                continue
            } else {
                output.append(character)
            }
        }
        return output.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func assemble(_ segments: [Layer1Segment]) -> String {
        segments.sorted { $0.start < $1.start }.compactMap { $0.decision.text }.joined(separator: " ")
    }

    static func sha256(file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "unreadable" }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1024 * 1024)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        try? handle.close()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func makeSegments(
        audioID: String, duration: Double, words: [Layer1WordTimestamp],
        suggestions: [String: Layer1ModelSuggestion], algorithmVersion: String = "layer1-seg-v1"
    ) -> [Layer1Segment] {
        let clean = words.filter { $0.end > $0.start && !$0.word.isEmpty }
        if clean.isEmpty {
            return [
                segment(
                    audioID: audioID, start: 0, end: max(duration, 0.1), range: nil,
                    suggestions: suggestions, needsReview: duration > 7, algorithmVersion: algorithmVersion)
            ]
        }
        var groups: [(Int, Int)] = []
        var start = 0
        for index in clean.indices {
            let count = index - start + 1
            let pause = index + 1 < clean.count ? clean[index + 1].start - clean[index].end : .infinity
            if count >= 7 || (count >= 3 && pause >= 0.45) {
                groups.append((start, index + 1))
                start = index + 1
            }
        }
        if start < clean.count { groups.append((start, clean.count)) }
        return groups.enumerated().map { number, group in
            let first = clean[group.0]
            let last = clean[group.1 - 1]
            let left = max(0, first.start - 0.15)
            let right = min(max(duration, last.end), last.end + 0.15)
            return segment(
                audioID: audioID, start: left, end: max(left + 0.05, right),
                range: group.0..<group.1, suggestions: suggestions, needsReview: group.1 - group.0 > 7,
                algorithmVersion: algorithmVersion + ":\(number)")
        }
    }

    private static func segment(
        audioID: String, start: Double, end: Double, range: Range<Int>?,
        suggestions: [String: Layer1ModelSuggestion], needsReview: Bool, algorithmVersion: String
    ) -> Layer1Segment {
        let ids = Layer1ModelSpec.catalog.map(\.id)
        let offset = abs(audioID.hashValue) % max(ids.count, 1)
        let order = Array(ids[offset...] + ids[..<offset])
        return Layer1Segment(
            id: "\(audioID)#\(start)#\(end)", audioID: audioID, start: start, end: end,
            segmentationAlgorithmVersion: algorithmVersion, sourceWordRange: range,
            modelSuggestions: suggestions, proposalOrder: order, segmentationNeedsReview: needsReview,
            decision: Layer1SegmentDecision(
                status: .pending, text: nil, normalizedText: nil,
                action: nil, sourceModelID: nil, createdAt: nil, updatedAt: nil))
    }

    private func buildSegmentsIfReady(audioID: String) {
        guard !state.segments.contains(where: { $0.audioID == audioID }),
            let file = file(for: audioID)
        else { return }
        let runs = runs(for: audioID)
        guard runs.count == allModelIDs.count,
            runs.allSatisfy({ $0.status == .completed })
        else { return }
        let hasUnmappedSuccessfulRun = runs.contains {
            $0.status == .completed && !($0.text ?? "").isEmpty && $0.wordTimestamps.isEmpty
        }
        let timed = hasUnmappedSuccessfulRun ? [] : (runs.first(where: { !$0.wordTimestamps.isEmpty })?.wordTimestamps ?? [])
        let base = Self.makeSegments(
            audioID: audioID, duration: file.duration,
            words: timed, suggestions: [:])
        state.segments.append(
            contentsOf: base.map { segment in
                var result = segment
                result.modelSuggestions = Dictionary(
                    uniqueKeysWithValues: runs.map { run in
                        let scoped: String?
                        if !run.wordTimestamps.isEmpty {
                            let timed = run.wordTimestamps.filter { $0.end > segment.start && $0.start < segment.end }
                                .map(\.word).joined(separator: " ")
                            scoped = timed.isEmpty ? run.text : timed
                        } else {
                            scoped = run.text
                        }
                        return (
                            run.modelID,
                            Layer1ModelSuggestion(
                                modelID: run.modelID, model: run.model,
                                status: run.status, text: scoped, error: run.error, runID: run.id)
                        )
                    })
                return result
            })
    }

    private func refreshStatuses() {
        for index in state.files.indices { state.files[index].lastStatus = status(for: state.files[index].id) }
        for index in state.batches.indices {
            let statuses = state.batches[index].fileIDs.map { status(for: $0) }
            if statuses.contains(.running) {
                state.batches[index].status = .running
            } else if statuses.contains(.queued) {
                state.batches[index].status = .queued
            } else if statuses.contains(.partial) {
                state.batches[index].status = .partial
            } else if statuses.allSatisfy({ $0 == .completed }) {
                state.batches[index].status = .completed
            } else {
                state.batches[index].status = .failed
            }
        }
    }

    private func runsForLatestAttempts() -> [Layer1ModelRun] {
        var latest: [String: Layer1ModelRun] = [:]
        for run in state.modelRuns {
            let key = "\(run.audioID)#\(run.modelID)"
            if latest[key]?.attempt ?? 0 < run.attempt { latest[key] = run }
        }
        return Array(latest.values)
    }

    private func recoverInterruptedRuns() {
        requeueInterruptedRuns()
    }

    private func bootstrapCommandConfiguration() {
        guard !FileManager.default.fileExists(atPath: commandConfigurationURL.path) else { return }
        let empty = Dictionary(uniqueKeysWithValues: Layer1ModelSpec.catalog.map { ($0.id, ["version": "unconfigured", "command": ""]) })
        let data = try? JSONSerialization.data(withJSONObject: empty, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: commandConfigurationURL, options: .atomic)
    }

    func commandConfiguration(for modelID: String) -> (command: [String], version: String) {
        guard let data = try? Data(contentsOf: commandConfigurationURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
            let row = object[modelID], let raw = row["command"] as? String,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return ([], "unconfigured") }
        return (raw.split(separator: " ").map(String.init), row["version"] as? String ?? "unversioned")
    }

    private func appendHistory(event: String, payload: [String: Any]) {
        var row = payload
        row["event"] = event
        row["at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: row), var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        if let handle = try? FileHandle(forWritingTo: historyURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: historyURL)
        }
    }

    private static func loadState(from directory: URL) -> Layer1State? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Layer1State.self, from: data)
    }
}
