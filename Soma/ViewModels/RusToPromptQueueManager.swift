import Combine
import Foundation

enum RusToPromptQueueItemStatus: String, Codable, CaseIterable {
    case queued
    case waitingLocalAI = "waiting_local_ai"
    case running
    case completed
    case failed
    case blocked
    case interrupted
}

struct RusToPromptQueueSettings: Codable, Hashable {
    var autoEnqueueEnabled: Bool
    var translatorCandidates: [String]
    var improverCandidates: [String]
    var confidenceReferee: String
    var confidenceModel: String
    var localConfidenceModels: [String]
    var hybridGeminiModel: String
    var hybridFallbackReferee: String?
    var confidenceBatchSize: Int
    var cooldownSeconds: Double
    var ramWarningGB: Double

    static func defaults() -> RusToPromptQueueSettings {
        let translators = localModelsFromDefaults(
            key: "tests.rusToPrompt.translatorModels",
            fallback: [RusToPromptSettingsStore.defaultTranslator]
        )
        let improvers = localModelsFromDefaults(
            key: "tests.rusToPrompt.improverModels",
            fallback: [RusToPromptSettingsStore.defaultAnalyzer]
        )
        let localJudges = localModelsFromDefaults(
            key: "tests.rusToPrompt.localConfidenceModels",
            fallback: ["qwen3:30b-a3b", "qwen3-coder:30b-a3b-q4_K_M"]
        )
        let confidenceModel = UserDefaults.standard.string(forKey: "tests.rusToPrompt.confidenceModel") ?? "gemini-3-flash-preview"
        let batchSize = UserDefaults.standard.integer(forKey: "tests.rusToPrompt.confidenceBatchSize")

        return RusToPromptQueueSettings(
            autoEnqueueEnabled: false,
            translatorCandidates: translators,
            improverCandidates: improvers,
            confidenceReferee: localJudges.count >= 2 ? "hybrid" : "gemini",
            confidenceModel: confidenceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gemini-3-flash-preview" : confidenceModel,
            localConfidenceModels: Array(localJudges.prefix(2)),
            hybridGeminiModel: confidenceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gemini-3-flash-preview" : confidenceModel,
            hybridFallbackReferee: "gemini",
            confidenceBatchSize: [1, 5, 10, 20].contains(batchSize) ? batchSize : 10,
            cooldownSeconds: 30,
            ramWarningGB: 6
        )
    }

    private static func localModelsFromDefaults(key: String, fallback: [String]) -> [String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return fallback.filter { RusToPromptQueueManager.isLocalStageModel($0) }
        }
        let models = decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && RusToPromptQueueManager.isLocalStageModel($0) }
        return models.isEmpty ? fallback.filter { RusToPromptQueueManager.isLocalStageModel($0) } : models
    }
}

struct RusToPromptQueueItemSnapshot: Codable, Hashable {
    var translatorModels: [String]
    var improverModels: [String]
    var confidenceReferee: String
    var confidenceModel: String
    var localConfidenceModels: [String]
    var hybridGeminiModel: String
    var hybridFallbackReferee: String?
    var confidenceBatchSize: Int
    var cooldownSeconds: Double
}

struct RusToPromptQueueItem: Identifiable, Codable, Hashable {
    var id: String
    var prompt: String
    var normalizedPrompt: String
    var source: String
    var status: RusToPromptQueueItemStatus
    var statusMessage: String
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var outputPath: String?
    var runCount: Int
    var recoveredAfterRestart: Bool
    var snapshot: RusToPromptQueueItemSnapshot?
}

private struct RusToPromptQueueDiskState: Codable {
    var settings: RusToPromptQueueSettings
    var items: [RusToPromptQueueItem]
}

private struct QueueProgressEvent: Decodable {
    let event: String?
    let stage: String?
    let caseID: String?
    let translatorModel: String?
    let analyzerModel: String?
    let operationIndex: Int?
    let totalOperations: Int?
    let status: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case event
        case stage
        case caseID = "case_id"
        case translatorModel = "translator_model"
        case analyzerModel = "analyzer_model"
        case operationIndex = "operation_index"
        case totalOperations = "total_operations"
        case status
        case reason
    }
}

private struct QueueOllamaTagsResponse: Decodable {
    let models: [OllamaInstalledModel]
}

@MainActor
final class RusToPromptQueueManager: ObservableObject {
    @Published private(set) var items: [RusToPromptQueueItem] = []
    @Published var settings: RusToPromptQueueSettings
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentStage = "Idle"
    @Published private(set) var currentModel = "-"
    @Published private(set) var currentOutputPath: String?
    @Published private(set) var recentActivity: [String] = []
    @Published private(set) var freeMemoryGB: Double?

    private let progressPrefix = "SOMA_PROGRESS "
    private let repoRootURL: URL
    private let appSupportURL: URL
    private let queueFileURL: URL
    private var activeProcess: Process?
    private var activeItemID: String?
    private var activeControlFileURL: URL?
    private var processOutputBuffer = ""
    private var timer: Timer?

    init() {
        let sourceURL = URL(fileURLWithPath: #filePath)
        repoRootURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        appSupportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Soma")
            .appendingPathComponent("RusToPromptQueue")
        queueFileURL = appSupportURL.appendingPathComponent("queue.json")
        settings = RusToPromptQueueSettings.defaults()
        loadFromDisk()
        recoverRunningItems()
        saveToDisk()
        startTimer()
    }

    deinit {
        timer?.invalidate()
    }

    var queuedCount: Int {
        items.filter { $0.status == .queued || $0.status == .waitingLocalAI }.count
    }

    var failedCount: Int {
        items.filter { $0.status == .failed || $0.status == .blocked || $0.status == .interrupted }.count
    }

    var completedCount: Int {
        items.filter { $0.status == .completed }.count
    }

    var statusBadgeText: String {
        if isRunning { return "running" }
        if queuedCount > 0 { return "\(queuedCount) queued" }
        if failedCount > 0 { return "\(failedCount) failed" }
        return "idle"
    }

    var queueDirectoryPath: String {
        appSupportURL.path
    }

    static func isLocalStageModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        if normalized.hasPrefix("gpt-") || normalized.hasPrefix("codex-") { return false }
        if normalized.hasPrefix("o1") || normalized.hasPrefix("o3") || normalized.hasPrefix("o4") { return false }
        if normalized.hasPrefix("gemini-") || normalized.hasPrefix("auto-gemini") || normalized.hasPrefix("gemma-4-") { return false }
        return true
    }

    func enqueueRealPrompt(_ prompt: String, source: String = "Rus to Prompt") {
        guard settings.autoEnqueueEnabled else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = normalizePrompt(trimmed)
        let activeStatuses: Set<RusToPromptQueueItemStatus> = [.queued, .waitingLocalAI, .running]
        if items.contains(where: { $0.normalizedPrompt == normalized && activeStatuses.contains($0.status) }) {
            appendActivity("Skipped duplicate real prompt.")
            return
        }

        let now = Date()
        let item = RusToPromptQueueItem(
            id: "rpq-\(Self.timestampID())-\(UUID().uuidString.prefix(6))",
            prompt: trimmed,
            normalizedPrompt: normalized,
            source: source,
            status: .queued,
            statusMessage: "Queued",
            createdAt: now,
            updatedAt: now,
            startedAt: nil,
            finishedAt: nil,
            outputPath: nil,
            runCount: 0,
            recoveredAfterRestart: false,
            snapshot: nil
        )
        items.insert(item, at: 0)
        appendActivity("Queued real prompt \(item.id).")
        saveToDisk()
        startNextIfPossible()
    }

    func setAutoEnqueueEnabled(_ enabled: Bool) {
        settings.autoEnqueueEnabled = enabled
        saveToDisk()
    }

    func updateTranslatorCandidates(_ models: [String]) {
        settings.translatorCandidates = cleanLocalModels(models)
        saveToDisk()
        startNextIfPossible()
    }

    func updateImproverCandidates(_ models: [String]) {
        settings.improverCandidates = cleanLocalModels(models)
        saveToDisk()
        startNextIfPossible()
    }

    func updateConfidence(
        referee: String,
        model: String,
        localModels: [String],
        hybridGeminiModel: String,
        hybridFallbackReferee: String? = nil,
        batchSize: Int
    ) {
        settings.confidenceReferee = referee
        settings.confidenceModel = model
        settings.localConfidenceModels = Array(cleanLocalModels(localModels).prefix(2))
        settings.hybridGeminiModel = hybridGeminiModel
        settings.hybridFallbackReferee = hybridFallbackReferee ?? settings.hybridFallbackReferee ?? "gemini"
        settings.confidenceBatchSize = [1, 5, 10, 20].contains(batchSize) ? batchSize : 10
        saveToDisk()
    }

    func updateCooldown(seconds: Double) {
        settings.cooldownSeconds = max(0, seconds)
        saveToDisk()
    }

    func updateRAMWarning(gb: Double) {
        settings.ramWarningGB = max(0, gb)
        saveToDisk()
    }

    func pause() {
        isPaused = true
        writeControl(["pause": true, "skip_cooldown": false, "stop": false])
        appendActivity("Queue paused after current stage.")
    }

    func resume() {
        isPaused = false
        writeControl(["pause": false, "skip_cooldown": false, "stop": false])
        appendActivity("Queue resumed.")
        startNextIfPossible()
    }

    func runNow() {
        writeControl(["pause": false, "skip_cooldown": true, "run_now": true, "stop": false])
        appendActivity("Cooldown skipped for active run.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.writeControl(["pause": false, "skip_cooldown": false, "run_now": false, "stop": false])
        }
    }

    func stopCurrent() {
        guard let process = activeProcess else { return }
        writeControl(["stop": true])
        process.terminate()
        appendActivity("Stop requested for current run.")
    }

    func retry(_ item: RusToPromptQueueItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].status = .queued
        items[index].statusMessage = "Queued for retry"
        items[index].updatedAt = Date()
        items[index].finishedAt = nil
        items[index].snapshot = nil
        appendActivity("Retry queued for \(item.id).")
        saveToDisk()
        startNextIfPossible()
    }

    func remove(_ item: RusToPromptQueueItem) {
        if activeItemID == item.id {
            stopCurrent()
        }
        items.removeAll { $0.id == item.id }
        appendActivity("Removed \(item.id).")
        saveToDisk()
    }

    func refreshFreeMemory() {
        DispatchQueue.global(qos: .utility).async {
            let value = Self.readFreeMemoryGB()
            DispatchQueue.main.async {
                self.freeMemoryGB = value
            }
        }
    }

    func startNextIfPossible() {
        guard activeProcess == nil, !isPaused else { return }
        guard let index = items.firstIndex(where: { $0.status == .queued || $0.status == .waitingLocalAI }) else {
            isRunning = false
            currentStage = "Idle"
            currentModel = "-"
            currentOutputPath = nil
            return
        }
        fetchInstalledModels { [weak self] installed, isOnline in
            guard let self else { return }
            if !isOnline {
                self.mark(index: index, status: .waitingLocalAI, message: "Waiting for Ollama")
                self.appendActivity("Ollama offline; queue waiting.")
                return
            }
            self.startItem(at: index, installedModels: installed)
        }
    }

    private func startItem(at index: Int, installedModels: Set<String>) {
        guard activeProcess == nil, items.indices.contains(index) else { return }
        let installedLower = Set(installedModels.map { $0.lowercased() })
        let translators = settings.translatorCandidates.filter { installedLower.contains($0.lowercased()) && Self.isLocalStageModel($0) }
        let improvers = settings.improverCandidates.filter { installedLower.contains($0.lowercased()) && Self.isLocalStageModel($0) }
        guard !translators.isEmpty else {
            mark(index: index, status: .blocked, message: "No installed local translator candidates.")
            return
        }
        guard !improvers.isEmpty else {
            mark(index: index, status: .blocked, message: "No installed local improver candidates.")
            return
        }

        let item = items[index]
        let runURL = repoRootURL
            .appendingPathComponent(".stress")
            .appendingPathComponent("queue-runs")
            .appendingPathComponent("\(Self.timestampID())-\(item.id)")
        let workspaceURL = appSupportURL.appendingPathComponent(item.id)
        let casesURL = workspaceURL.appendingPathComponent("case.txt")
        let controlURL = workspaceURL.appendingPathComponent("control.json")
        do {
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
            try "### \(item.id)\n\(item.prompt)\n".write(to: casesURL, atomically: true, encoding: .utf8)
            try #"{"pause":false,"skip_cooldown":false,"stop":false}"#.write(to: controlURL, atomically: true, encoding: .utf8)
        } catch {
            mark(index: index, status: .failed, message: "Could not prepare queue run: \(error.localizedDescription)")
            return
        }

        let snapshot = RusToPromptQueueItemSnapshot(
            translatorModels: translators,
            improverModels: improvers,
            confidenceReferee: settings.confidenceReferee,
            confidenceModel: settings.confidenceModel,
            localConfidenceModels: Array(settings.localConfidenceModels.prefix(2)),
            hybridGeminiModel: settings.hybridGeminiModel,
            hybridFallbackReferee: settings.hybridFallbackReferee ?? "gemini",
            confidenceBatchSize: settings.confidenceBatchSize,
            cooldownSeconds: settings.cooldownSeconds
        )
        items[index].status = .running
        items[index].statusMessage = "Running staged benchmark"
        items[index].startedAt = Date()
        items[index].updatedAt = Date()
        items[index].outputPath = runURL.path
        items[index].runCount += 1
        items[index].snapshot = snapshot
        saveToDisk()

        activeItemID = item.id
        activeControlFileURL = controlURL
        currentOutputPath = runURL.path
        currentStage = "Starting"
        currentModel = "-"
        processOutputBuffer = ""
        isRunning = true

        let process = Process()
        process.currentDirectoryURL = repoRootURL
        process.executableURL = URL(fileURLWithPath: pythonPath())
        var arguments = [
            stressScriptURL.path,
            "--benchmark-mode", "staged",
            "--cases-file", casesURL.path,
            "--limit", "1",
            "--translator-models",
        ]
        arguments.append(contentsOf: translators)
        arguments.append("--analyzer-models")
        arguments.append(contentsOf: improvers)
        arguments.append(contentsOf: [
            "--confidence-referee", snapshot.confidenceReferee,
            "--confidence-model", snapshot.confidenceReferee == "hybrid" ? snapshot.hybridGeminiModel : snapshot.confidenceModel,
            "--confidence-reasoning-effort", RusToPromptSettingsStore.defaultConfidenceReasoning,
            "--confidence-workers", ["hybrid", "local"].contains(snapshot.confidenceReferee) ? "1" : "3",
            "--confidence-batch-size", "\(snapshot.confidenceBatchSize)",
            "--translation-confidence-threshold", "0.75",
            "--codex-bin", Self.codexExecutablePath(),
            "--gemini-bin", Self.geminiExecutablePath(),
            "--codex-stage-reasoning-effort", RusToPromptSettingsStore.defaultConfidenceReasoning,
            "--workers", "1",
            "--stage-cooldown-seconds", String(format: "%.1f", snapshot.cooldownSeconds),
            "--control-file", controlURL.path,
            "--out-dir", runURL.path,
        ])
        if snapshot.confidenceReferee == "hybrid" {
            arguments.append("--local-confidence-models")
            arguments.append(contentsOf: snapshot.localConfidenceModels)
            arguments.append(contentsOf: [
                "--hybrid-confidence-gemini-model", snapshot.hybridGeminiModel,
                "--hybrid-confidence-fallback-referee", snapshot.hybridFallbackReferee ?? "gemini",
                "--hybrid-confidence-local-threshold", "0.80",
                "--hybrid-confidence-disagreement-threshold", "0.15",
            ])
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SOMA_PROJECT_ROOT")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = Self.searchPath(existing: environment["PATH"])
        LocalModelSettingsStore.apply(to: &environment)
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.consumeProcessOutput(text)
            }
        }
        process.terminationHandler = { [weak self] finishedProcess in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.handleProcessFinished(status: finishedProcess.terminationStatus)
            }
        }

        do {
            try process.run()
            activeProcess = process
            appendActivity("Started queue run \(item.id): \(translators.count) translators, \(improvers.count) improvers.")
        } catch {
            activeProcess = nil
            activeItemID = nil
            activeControlFileURL = nil
            mark(index: index, status: .failed, message: "Could not start queue run: \(error.localizedDescription)")
        }
    }

    private func handleProcessFinished(status: Int32) {
        defer {
            activeProcess = nil
            activeItemID = nil
            activeControlFileURL = nil
            isRunning = false
            currentStage = "Idle"
            currentModel = "-"
            startNextIfPossible()
        }
        guard let itemID = activeItemID, let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        if status == 0 {
            items[index].status = .completed
            items[index].statusMessage = "Completed"
            appendActivity("Queue run \(itemID) completed.")
        } else {
            let stopped = controlFlagFromActiveFile("stop")
            items[index].status = stopped ? .interrupted : .failed
            items[index].statusMessage = stopped ? "Interrupted by user" : "Process exited with code \(status)"
            appendActivity("Queue run \(itemID) ended: \(items[index].statusMessage).")
        }
        items[index].finishedAt = Date()
        items[index].updatedAt = Date()
        saveToDisk()
    }

    private func consumeProcessOutput(_ text: String) {
        processOutputBuffer += text
        let parts = processOutputBuffer.components(separatedBy: .newlines)
        guard parts.count > 1 else { return }
        processOutputBuffer = parts.last ?? ""
        for line in parts.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let event = decodeProgressEvent(from: trimmed) {
                currentStage = displayStage(for: event)
                if let translator = event.translatorModel, let analyzer = event.analyzerModel {
                    currentModel = "\(translator) -> \(analyzer)"
                } else if let translator = event.translatorModel {
                    currentModel = translator
                }
                appendActivity(activityText(for: event))
            } else {
                appendActivity(trimmed)
            }
        }
    }

    private func decodeProgressEvent(from line: String) -> QueueProgressEvent? {
        guard line.hasPrefix(progressPrefix) else { return nil }
        let payload = String(line.dropFirst(progressPrefix.count))
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QueueProgressEvent.self, from: data)
    }

    private func activityText(for event: QueueProgressEvent) -> String {
        let caseID = event.caseID ?? "case"
        switch event.event {
        case "stage_start":
            return "\(caseID) \(displayStage(for: event)) started · \(currentModel)"
        case "stage_complete":
            return "\(caseID) \(displayStage(for: event)) finished · \(event.status ?? "unknown")"
        case "translation_gate":
            return "\(caseID) translation \(event.status ?? "checked") · \(event.reason ?? "")"
        case "cooldown_start":
            return "\(caseID) cooldown started · \(event.reason ?? "")"
        case "cooldown_pause":
            return "\(caseID) cooldown paused"
        case "cooldown_complete":
            return "\(caseID) cooldown finished"
        case "result_write":
            return "\(caseID) result saved"
        default:
            return "\(caseID) \(displayStage(for: event)) · \(event.status ?? "")"
        }
    }

    private func displayStage(for event: QueueProgressEvent) -> String {
        switch event.stage {
        case "queued": return "Queued"
        case "translating": return "Translating"
        case "translation_confidence", "translation_confidence_batch": return "Translation Check"
        case "translation_rejected": return "Translation Rejected"
        case "analyzing": return "Improving"
        case "improve_confidence_batch": return "Improve Confidence"
        case "overall_confidence_batch": return "Overall Confidence"
        case "cooldown": return "Cooldown"
        case "writing_result": return "Saving"
        case "done": return "Done"
        case "failed": return "Failed"
        default:
            return (event.stage ?? "Working").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func mark(index: Int, status: RusToPromptQueueItemStatus, message: String) {
        guard items.indices.contains(index) else { return }
        items[index].status = status
        items[index].statusMessage = message
        items[index].updatedAt = Date()
        if status == .failed || status == .blocked || status == .interrupted || status == .completed {
            items[index].finishedAt = Date()
        }
        saveToDisk()
    }

    private func loadFromDisk() {
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return }
            let data = try Data(contentsOf: queueFileURL)
            let decoded = try JSONDecoder().decode(RusToPromptQueueDiskState.self, from: data)
            settings = decoded.settings
            items = decoded.items
        } catch {
            appendActivity("Queue state could not be loaded: \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            let state = RusToPromptQueueDiskState(settings: settings, items: items)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: queueFileURL, options: [.atomic])
        } catch {
            appendActivity("Queue state could not be saved: \(error.localizedDescription)")
        }
    }

    private func recoverRunningItems() {
        var changed = false
        for index in items.indices where items[index].status == .running {
            items[index].status = .queued
            items[index].statusMessage = "Recovered after restart"
            items[index].recoveredAfterRestart = true
            items[index].updatedAt = Date()
            changed = true
        }
        if changed {
            appendActivity("Recovered running queue items after app restart.")
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.refreshFreeMemory()
                self?.startNextIfPossible()
            }
        }
        refreshFreeMemory()
    }

    private func appendActivity(_ line: String) {
        let timestamp = Self.activityFormatter.string(from: Date())
        recentActivity.insert("\(timestamp) \(line)", at: 0)
        if recentActivity.count > 80 {
            recentActivity.removeLast(recentActivity.count - 80)
        }
    }

    private func writeControl(_ payload: [String: Bool]) {
        guard let activeControlFileURL else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: activeControlFileURL, options: [.atomic])
        } catch {
            appendActivity("Could not write control file: \(error.localizedDescription)")
        }
    }

    private func controlFlagFromActiveFile(_ key: String) -> Bool {
        guard let activeControlFileURL,
              let data = try? Data(contentsOf: activeControlFileURL),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (decoded[key] as? Bool) == true
    }

    private func fetchInstalledModels(completion: @escaping (Set<String>, Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else {
            completion([], false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard error == nil, let data else {
                    completion([], false)
                    return
                }
                let decoded = try? JSONDecoder().decode(QueueOllamaTagsResponse.self, from: data)
                completion(Set(decoded?.models.map(\.name) ?? []), decoded != nil)
            }
        }.resume()
    }

    private func cleanLocalModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var cleaned: [String] = []
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, Self.isLocalStageModel(trimmed), !seen.contains(key) else { continue }
            cleaned.append(trimmed)
            seen.insert(key)
        }
        return cleaned
    }

    private func normalizePrompt(_ prompt: String) -> String {
        prompt
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var stressScriptURL: URL {
        repoRootURL.appendingPathComponent("Scripts").appendingPathComponent("rus_to_prompt_stress.py")
    }

    private func pythonPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3") {
            return "/opt/homebrew/bin/python3"
        }
        return "/usr/bin/python3"
    }

    nonisolated private static func codexExecutablePath() -> String {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"].first {
            FileManager.default.fileExists(atPath: $0)
        } ?? "codex"
    }

    nonisolated private static func geminiExecutablePath() -> String {
        ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", "/usr/bin/gemini"].first {
            FileManager.default.fileExists(atPath: $0)
        } ?? "gemini"
    }

    nonisolated private static func searchPath(existing: String?) -> String {
        var parts = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let homeLocal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        parts.append(homeLocal)
        if let existing, !existing.isEmpty {
            parts.append(existing)
        }
        return parts.joined(separator: ":")
    }

    nonisolated private static func timestampID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    nonisolated private static let activityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    nonisolated private static func readFreeMemoryGB() -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let pageSize = 16_384.0
            let keys = ["Pages free", "Pages inactive", "Pages speculative"]
            var pages = 0.0
            for line in text.components(separatedBy: .newlines) {
                for key in keys where line.hasPrefix(key) {
                    let digits = line
                        .replacingOccurrences(of: ".", with: "")
                        .components(separatedBy: CharacterSet.decimalDigits.inverted)
                        .filter { !$0.isEmpty }
                    if let value = digits.first.flatMap(Double.init) {
                        pages += value
                    }
                }
            }
            return pages > 0 ? (pages * pageSize / 1_073_741_824.0) : nil
        } catch {
            return nil
        }
    }
}
