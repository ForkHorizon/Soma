import Combine
import Foundation
import SwiftUI

struct Layer1ASRProcessResult {
    let status: Layer1ModelRunStatus
    let version: String
    let rawResponse: String
    let text: String?
    let timestamps: [Layer1WordTimestamp]
    let error: String?
}

@MainActor
final class Layer1GroundTruthRunner: ObservableObject {
    @Published private(set) var store: Layer1GroundTruthStore
    @Published private(set) var isRunning = false
    @Published private(set) var currentFileID: String?
    @Published private(set) var currentModelID: String?
    @Published private(set) var failure: String?

    private var workerTask: Task<Void, Never>?
    private var process: Process?
    private var currentBatchID: String?

    init() {
        self.store = Layer1GroundTruthStore()
    }

    init(store: Layer1GroundTruthStore) {
        self.store = store
    }

    deinit {
        workerTask?.cancel()
        process?.terminate()
    }

    var state: Layer1State { store.state }
    var batches: [Layer1Batch] { state.batches.sorted { $0.createdAt > $1.createdAt } }
    var files: [Layer1AudioFile] { state.files.sorted { $0.addedAt > $1.addedAt } }
    var segments: [Layer1Segment] { state.segments }
    var reviewSegments: [Layer1Segment] { store.segmentsForReview() }
    var models: [Layer1ModelSpec] { Layer1ModelSpec.catalog }
    var resumeSegmentID: String? { store.resumeSegmentID }

    var pendingRuns: Int { store.queuedRuns().count }
    var verifiedMinutes: Double {
        let ids = store.fullyVerifiedFileIDs()
        return state.files.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.duration } / 60
    }

    func addBatch(count: Int, asr: ASRManager) {
        failure = nil
        let candidates = asr.recordingIndex.map { Layer1AudioCandidate(url: $0.url, date: $0.date, duration: $0.duration) }
        guard store.addBatch(count: count, candidates: candidates) != nil else {
            failure = "No new WAV files were available for this batch."
            objectWillChange.send()
            return
        }
        objectWillChange.send()
    }

    func start() {
        guard !isRunning else { return }
        failure = nil
        isRunning = true
        workerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let batch = self.store.nextQueuedBatch() {
                self.currentBatchID = batch.id
                let batchRuns = self.store.latestRuns(for: batch.id).filter { $0.status == .queued }
                var batchError: String?
                let modelIDs = Layer1ModelSpec.catalog.map(\.id).filter { modelID in
                    batchRuns.contains { $0.modelID == modelID }
                }
                for modelID in modelIDs {
                    guard batchError == nil, !Task.isCancelled else { break }
                    let runs = batchRuns.filter { $0.modelID == modelID }
                    guard !runs.isEmpty else { continue }
                    self.currentFileID = runs.first?.audioID
                    self.currentModelID = modelID
                    let command = self.store.commandConfiguration(for: modelID)
                    guard !command.command.isEmpty else {
                        batchError = "No batch command configured for Layer 1 model \(modelID)"
                        break
                    }
                    let configuration = runs[0].configuration.merging([
                        "version": command.version,
                        "command": command.command.joined(separator: " "),
                        "batch_mode": "model_major_v1",
                    ]) { _, new in new }
                    self.store.markRunning(runs, configuration: configuration, version: command.version)
                    let result = await self.executeBatch(
                        batchID: batch.id, modelID: modelID,
                        runs: runs, command: command)
                    if Task.isCancelled { return }
                    guard result.status == 0 else {
                        batchError = result.error.isEmpty ? "Model batch failed: \(modelID)" : result.error
                        break
                    }
                    guard result.rows.count == runs.count,
                        Set(result.rows.map(\.runID)) == Set(runs.map(\.id))
                    else {
                        batchError = "Model batch returned incomplete or duplicate results: \(modelID)"
                        break
                    }
                    for row in result.rows {
                        self.store.finish(
                            row.runID, status: .completed, version: row.version,
                            rawResponse: row.rawResponse, text: row.text,
                            timestamps: row.timestamps, error: nil,
                            duration: row.duration)
                    }
                }
                if let batchError {
                    self.store.failBatch(batch.id, error: batchError)
                }
                self.currentBatchID = nil
            }
            self.isRunning = false
            self.currentBatchID = nil
            self.currentFileID = nil
            self.currentModelID = nil
            self.workerTask = nil
        }
    }

    func stop() {
        let batchID = currentBatchID
        workerTask?.cancel()
        workerTask = nil
        process?.terminate()
        process = nil
        if let batchID {
            store.failBatch(batchID, error: "Batch stopped before all model heads completed")
        } else {
            store.requeueInterruptedRuns()
        }
        isRunning = false
        currentBatchID = nil
        currentFileID = nil
        currentModelID = nil
        objectWillChange.send()
    }

    func retryFailed() {
        store.retryFailed()
        failure = nil
        objectWillChange.send()
    }

    func saveDecision(segmentID: String, text: String?, action: Layer1HumanAction, sourceModelID: String? = nil) {
        store.saveDecision(segmentID: segmentID, text: text, action: action, sourceModelID: sourceModelID)
        objectWillChange.send()
    }

    func flagSegmentation(_ segmentID: String) {
        store.markSegmentationNeedsReview(segmentID)
        objectWillChange.send()
    }

    private struct Layer1BatchOutputRow {
        let runID: String
        let version: String
        let rawResponse: String
        let text: String?
        let timestamps: [Layer1WordTimestamp]
        let duration: Double
    }

    private struct Layer1BatchExecution {
        let status: Int32
        let output: String
        let error: String
        let rows: [Layer1BatchOutputRow]
    }

    private func executeBatch(
        batchID: String, modelID: String, runs: [Layer1ModelRun],
        command: (command: [String], version: String)
    ) async -> Layer1BatchExecution {
        let manifest = store.writeBatchManifest(batchID: batchID, modelID: modelID, runs: runs)
        let worker = repoRoot.appendingPathComponent("Scripts/layer1_batch_asr_worker.py")
        guard FileManager.default.fileExists(atPath: worker.path) else {
            return .init(status: 127, output: "", error: "Layer 1 batch worker is missing", rows: [])
        }
        let result = await runBatchProcess(arguments: [
            worker.path, "--manifest", manifest.path,
            "--model", modelID,
            "--version", command.version,
            "--command", command.command.joined(separator: "\u{1f}"),
        ])
        guard result.status == 0 else {
            return .init(
                status: result.status, output: result.output,
                error: result.error.isEmpty ? "Model batch failed: \(modelID)" : result.error,
                rows: [])
        }
        var rows: [Layer1BatchOutputRow] = []
        var seen = Set<String>()
        for line in result.output.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["error"] == nil,
                let runID = object["id"] as? String,
                !seen.contains(runID)
            else {
                return .init(
                    status: 1, output: result.output,
                    error: "Batch produced malformed or duplicate JSON output for \(modelID)", rows: [])
            }
            seen.insert(runID)
            let timestamps = (object["words"] as? [[String: Any]] ?? []).compactMap { word -> Layer1WordTimestamp? in
                guard let value = word["word"] as? String,
                    let start = word["start"] as? Double,
                    let end = word["end"] as? Double
                else { return nil }
                return Layer1WordTimestamp(word: value, start: start, end: end)
            }
            rows.append(
                Layer1BatchOutputRow(
                    runID: runID,
                    version: object["version"] as? String ?? command.version,
                    rawResponse: String(line), text: object["text"] as? String,
                    timestamps: timestamps, duration: 0))
        }
        return .init(status: 0, output: result.output, error: result.error, rows: rows)
    }

    private func runBatchProcess(arguments: [String]) async -> (status: Int32, output: String, error: String) {
        await withCheckedContinuation { continuation in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let outputURL = directory.appendingPathComponent("stdout")
            let errorURL = directory.appendingPathComponent("stderr")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            guard let outputHandle = try? FileHandle(forWritingTo: outputURL),
                let errorHandle = try? FileHandle(forWritingTo: errorURL)
            else {
                continuation.resume(returning: (127, "", "Could not create batch output files"))
                return
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: pythonPath)
            task.arguments = arguments
            task.currentDirectoryURL = repoRoot
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONUNBUFFERED"] = "1"
            environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:" + (environment["PATH"] ?? "")
            task.environment = environment
            task.standardOutput = outputHandle
            task.standardError = errorHandle
            task.terminationHandler = { process in
                try? outputHandle.close()
                try? errorHandle.close()
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                let error = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: directory)
                continuation.resume(returning: (process.terminationStatus, output, error.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do {
                try task.run()
                self.process = task
            } catch {
                try? outputHandle.close()
                try? errorHandle.close()
                try? FileManager.default.removeItem(at: directory)
                continuation.resume(returning: (127, "", error.localizedDescription))
            }
        }
    }

    private func execute(_ run: Layer1ModelRun, command: (command: [String], version: String)) async -> Layer1ASRProcessResult {
        let script = repoRoot.appendingPathComponent("Scripts/layer1_asr_worker.py")
        let audio = store.file(for: run.audioID)?.path ?? ""
        guard FileManager.default.fileExists(atPath: script.path), !audio.isEmpty else {
            return .init(
                status: .failed, version: command.version, rawResponse: "",
                text: nil, timestamps: [], error: "Layer 1 worker or source audio is missing")
        }
        let result = await runProcess(arguments: [
            script.path, "--audio", audio,
            "--model", run.modelID,
            "--version", command.version,
            "--command", command.command.joined(separator: "\u{1f}"),
            "--audio-hash", store.file(for: run.audioID)?.audioHash ?? "",
        ])
        return parse(result.output, status: result.status, fallbackVersion: command.version)
    }

    private func runProcess(arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: pythonPath)
            task.arguments = arguments
            task.currentDirectoryURL = repoRoot
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            task.environment = env
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            task.terminationHandler = { [weak self] process in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                Task { @MainActor [weak self] in
                    self?.process = nil
                    continuation.resume(returning: (process.terminationStatus, output))
                }
            }
            do {
                try task.run()
                process = task
            } catch { continuation.resume(returning: (127, error.localizedDescription)) }
        }
    }

    private func parse(_ output: String, status: Int32, fallbackVersion: String) -> Layer1ASRProcessResult {
        guard status == 0 else {
            return .init(
                status: .failed, version: fallbackVersion, rawResponse: output, text: nil,
                timestamps: [],
                error: output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Worker exited with status \(status)" : output)
        }
        guard let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(
                status: .completed, version: fallbackVersion, rawResponse: output,
                text: text, timestamps: [], error: nil)
        }
        let text = object["text"] as? String
        let version = object["version"] as? String ?? fallbackVersion
        let timestamps = (object["words"] as? [[String: Any]] ?? []).compactMap { row -> Layer1WordTimestamp? in
            guard let word = row["word"] as? String,
                let start = row["start"] as? Double, let end = row["end"] as? Double
            else { return nil }
            return Layer1WordTimestamp(word: word, start: start, end: end)
        }
        return .init(
            status: .completed, version: version, rawResponse: output, text: text,
            timestamps: timestamps, error: nil)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var pythonPath: String {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
    }
}
