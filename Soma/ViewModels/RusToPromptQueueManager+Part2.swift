import Combine
import Foundation

struct RusToPromptQueueRunContext {
    let item: RusToPromptQueueItem
    let runURL: URL
    let casesURL: URL
    let controlURL: URL
    let snapshot: RusToPromptQueueItemSnapshot
}

extension RusToPromptQueueManager {
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


    func startItem(at index: Int, installedModels: Set<String>) {
        guard activeProcess == nil, items.indices.contains(index) else { return }
        let installedLower = Set(installedModels.map { $0.lowercased() })
        let translators = localCandidates(settings.translatorCandidates, installedLower: installedLower)
        let improvers = localCandidates(settings.improverCandidates, installedLower: installedLower)
        guard validateQueueModels(index: index, translators: translators, improvers: improvers) else { return }
        guard let context = prepareRunContext(index: index, translators: translators, improvers: improvers) else { return }

        markRunStarted(index: index, context: context)
        let process = makeQueueProcess(context: context, translators: translators, improvers: improvers)
        attachQueueHandlers(to: process)

        do {
            try process.run()
            activeProcess = process
            appendActivity("Started queue run \(context.item.id): \(translators.count) translators, \(improvers.count) improvers.")
        } catch {
            activeProcess = nil
            activeItemID = nil
            activeControlFileURL = nil
            mark(index: index, status: .failed, message: "Could not start queue run: \(error.localizedDescription)")
        }
    }

    func localCandidates(_ candidates: [String], installedLower: Set<String>) -> [String] {
        candidates.filter { installedLower.contains($0.lowercased()) && Self.isLocalStageModel($0) }
    }

    func validateQueueModels(index: Int, translators: [String], improvers: [String]) -> Bool {
        guard !translators.isEmpty else {
            mark(index: index, status: .blocked, message: "No installed local translator candidates.")
            return false
        }
        guard !improvers.isEmpty else {
            mark(index: index, status: .blocked, message: "No installed local improver candidates.")
            return false
        }
        return true
    }

    func prepareRunContext(index: Int, translators: [String], improvers: [String]) -> RusToPromptQueueRunContext? {
        let item = items[index]
        let runURL = repoRootURL.appendingPathComponent(".stress").appendingPathComponent("queue-runs").appendingPathComponent("\(Self.timestampID())-\(item.id)")
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
            return nil
        }
        return RusToPromptQueueRunContext(item: item, runURL: runURL, casesURL: casesURL, controlURL: controlURL, snapshot: queueSnapshot(translators: translators, improvers: improvers))
    }

    func queueSnapshot(translators: [String], improvers: [String]) -> RusToPromptQueueItemSnapshot {
        RusToPromptQueueItemSnapshot(translatorModels: translators, improverModels: improvers, confidenceReferee: settings.confidenceReferee, confidenceModel: settings.confidenceModel, localConfidenceModels: Array(settings.localConfidenceModels.prefix(2)), hybridGeminiModel: settings.hybridGeminiModel, hybridFallbackReferee: settings.hybridFallbackReferee ?? "gemini", confidenceBatchSize: settings.confidenceBatchSize, cooldownSeconds: settings.cooldownSeconds)
    }

    func markRunStarted(index: Int, context: RusToPromptQueueRunContext) {
        items[index].status = .running
        items[index].statusMessage = "Running staged benchmark"
        items[index].startedAt = Date()
        items[index].updatedAt = Date()
        items[index].outputPath = context.runURL.path
        items[index].runCount += 1
        items[index].snapshot = context.snapshot
        saveToDisk()
        activeItemID = context.item.id
        activeControlFileURL = context.controlURL
        currentOutputPath = context.runURL.path
        currentStage = "Starting"
        currentModel = "-"
        processOutputBuffer = ""
        isRunning = true
    }

    func makeQueueProcess(context: RusToPromptQueueRunContext, translators: [String], improvers: [String]) -> Process {
        let process = Process()
        process.currentDirectoryURL = repoRootURL
        process.executableURL = URL(fileURLWithPath: pythonPath())
        process.arguments = queueArguments(context: context, translators: translators, improvers: improvers)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SOMA_PROJECT_ROOT")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = Self.searchPath(existing: environment["PATH"])
        LocalModelSettingsStore.apply(to: &environment)
        process.environment = environment
        return process
    }

    func queueArguments(context: RusToPromptQueueRunContext, translators: [String], improvers: [String]) -> [String] {
        var arguments = [stressScriptURL.path, "--benchmark-mode", "staged", "--cases-file", context.casesURL.path, "--limit", "1", "--translator-models"]
        arguments.append(contentsOf: translators)
        arguments.append("--analyzer-models")
        arguments.append(contentsOf: improvers)
        arguments.append(contentsOf: queueConfidenceArguments(context: context))
        return arguments
    }

    func queueConfidenceArguments(context: RusToPromptQueueRunContext) -> [String] {
        let snapshot = context.snapshot
        let model = snapshot.confidenceReferee == "hybrid" ? snapshot.hybridGeminiModel : snapshot.confidenceModel
        var arguments = ["--confidence-referee", snapshot.confidenceReferee, "--confidence-model", model, "--confidence-reasoning-effort", RusToPromptSettingsStore.defaultConfidenceReasoning, "--confidence-workers", ["hybrid", "local"].contains(snapshot.confidenceReferee) ? "1" : "3", "--confidence-batch-size", "\(snapshot.confidenceBatchSize)", "--translation-confidence-threshold", "0.75", "--codex-bin", Self.codexExecutablePath(), "--gemini-bin", Self.geminiExecutablePath(), "--codex-stage-reasoning-effort", RusToPromptSettingsStore.defaultConfidenceReasoning, "--workers", "1", "--stage-cooldown-seconds", String(format: "%.1f", snapshot.cooldownSeconds), "--control-file", context.controlURL.path, "--out-dir", context.runURL.path]
        if snapshot.confidenceReferee == "hybrid" {
            arguments.append("--local-confidence-models")
            arguments.append(contentsOf: snapshot.localConfidenceModels)
            arguments.append(contentsOf: ["--hybrid-confidence-gemini-model", snapshot.hybridGeminiModel, "--hybrid-confidence-fallback-referee", snapshot.hybridFallbackReferee ?? "gemini", "--hybrid-confidence-local-threshold", "0.80", "--hybrid-confidence-disagreement-threshold", "0.15"])
        }
        return arguments
    }

    func attachQueueHandlers(to process: Process) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consumeProcessOutput(text) }
        }
        process.terminationHandler = { [weak self] finishedProcess in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.handleProcessFinished(status: finishedProcess.terminationStatus) }
        }
    }


    func handleProcessFinished(status: Int32) {
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


    func consumeProcessOutput(_ text: String) {
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


    func decodeProgressEvent(from line: String) -> QueueProgressEvent? {
        guard line.hasPrefix(progressPrefix) else { return nil }
        let payload = String(line.dropFirst(progressPrefix.count))
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QueueProgressEvent.self, from: data)
    }

}
