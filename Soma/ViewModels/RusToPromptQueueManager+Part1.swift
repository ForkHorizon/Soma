import Combine
import Foundation
extension RusToPromptQueueManager {
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
        if isPowerPaused { return "paused on battery" }
        if isRunning { return "running" }
        if powerSource == .battery && queuedCount > 0 { return "\(queuedCount) waiting power" }
        if queuedCount > 0 { return "\(queuedCount) queued" }
        if failedCount > 0 { return "\(failedCount) failed" }
        return "idle"
    }
    var queueDirectoryPath: String {
        appSupportURL.path
    }
    nonisolated static func isLocalStageModel(_ model: String) -> Bool {
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
        items.append(item)
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
        isPowerPaused = false
        batteryStartOverrideItemID = nil
        isPaused = true
        if let activeItemID, let index = items.firstIndex(where: { $0.id == activeItemID }) {
            items[index].statusMessage = "Paused after current stage"
            items[index].updatedAt = Date()
        }
        writeControl(["pause": true, "skip_cooldown": false, "stop": false])
        saveToDisk()
        appendActivity("Queue paused after current stage.")
    }
    func resume(allowBatteryStart: Bool = true) {
        allowActiveRunOnBatteryIfNeeded(allowBatteryStart)
        isPowerPaused = false
        isPaused = false
        if let activeItemID, let index = items.firstIndex(where: { $0.id == activeItemID }) {
            items[index].statusMessage = "Running staged benchmark"
            items[index].updatedAt = Date()
        }
        writeControl(["pause": false, "skip_cooldown": false, "stop": false])
        saveToDisk()
        appendActivity("Queue resumed.")
        startNextIfPossible(allowBatteryStart: allowBatteryStart)
    }
    func runNow(allowBatteryStart: Bool = true) {
        guard activeProcess != nil else {
            startNextIfPossible(allowBatteryStart: allowBatteryStart)
            return
        }
        allowActiveRunOnBatteryIfNeeded(allowBatteryStart)
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
        items[index].outputPath = nil
        items[index].recoveredAfterRestart = false
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
        Task {
            let value = await Self.readFreeMemoryGB()
            await MainActor.run {
                self.freeMemoryGB = value
            }
        }
    }
}
