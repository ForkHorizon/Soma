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
    func startNextIfPossible(allowBatteryStart: Bool = false) {
        refreshPowerSourceValue()
        applyPowerGate()
        guard activeProcess == nil, activeReattachedPID == nil, !isPaused else { return }
        guard let index = nextStartableQueueIndex() else {
            isRunning = false
            currentStage = "Idle"
            currentModel = "-"
            currentOutputPath = nil
            return
        }
        let selectedItemID = items[index].id
        guard canStartQueueOnCurrentPower(allowBatteryStart: allowBatteryStart) else {
            markWaitingForPower(index: index)
            return
        }
        fetchInstalledModels { [weak self] installed, isOnline in
            guard let self else { return }
            guard let currentIndex = self.items.firstIndex(where: { $0.id == selectedItemID && self.isStartableQueueItem($0) }) else {
                self.startNextIfPossible(allowBatteryStart: allowBatteryStart)
                return
            }
            guard self.canStartQueueOnCurrentPower(allowBatteryStart: allowBatteryStart) else {
                self.markWaitingForPower(index: currentIndex)
                return
            }
            if !isOnline && self.queueNeedsOllamaForConfiguredModels() {
                self.mark(index: currentIndex, status: .waitingLocalAI, message: "Waiting for Ollama")
                self.appendActivity("Ollama offline; queue waiting.")
                return
            }
            self.startItem(at: currentIndex, installedModels: installed, allowBatteryStart: allowBatteryStart)
        }
    }


    func nextStartableQueueIndex() -> Int? {
        items.indices
            .filter { isStartableQueueItem(items[$0]) }
            .min { lhs, rhs in
                let left = items[lhs]
                let right = items[rhs]
                if left.createdAt == right.createdAt {
                    return left.id < right.id
                }
                return left.createdAt < right.createdAt
            }
    }


    func isStartableQueueItem(_ item: RusToPromptQueueItem) -> Bool {
        item.status == .queued || item.status == .waitingLocalAI
    }


    func startItem(at index: Int, installedModels: Set<String>, allowBatteryStart: Bool = false) {
        guard activeProcess == nil, items.indices.contains(index) else { return }
        let installedLower = Set(installedModels.map { $0.lowercased() })
        let translators = stageCandidates(settings.translatorCandidates, installedLower: installedLower)
        let improvers = stageCandidates(settings.improverCandidates, installedLower: installedLower)
        guard validateQueueModels(index: index, translators: translators, improvers: improvers) else { return }
        guard let context = prepareRunContext(index: index, translators: translators, improvers: improvers) else { return }

        markRunStarted(index: index, context: context)
        if powerSource == .battery && allowBatteryStart {
            batteryStartOverrideItemID = context.item.id
        }
        let process = makeQueueProcess(context: context, translators: translators, improvers: improvers)
        attachQueueHandlers(to: process, runURL: context.runURL)

        do {
            try process.run()
            activeProcess = process
            items[index].pid = process.processIdentifier
            saveToDisk()
            appendActivity("Started queue run \(context.item.id) (pid \(process.processIdentifier)): \(translators.count) translators, \(improvers.count) improvers.")
        } catch {
            batteryStartOverrideItemID = nil
            activeProcess = nil
            activeItemID = nil
            activeControlFileURL = nil
            mark(index: index, status: .failed, message: "Could not start queue run: \(error.localizedDescription)")
        }
    }

    func localCandidates(_ candidates: [String], installedLower: Set<String>) -> [String] {
        candidates.filter { installedLower.contains($0.lowercased()) && Self.isLocalStageModel($0) }
    }

    func stageCandidates(_ candidates: [String], installedLower: Set<String>) -> [String] {
        candidates.filter { candidate in
            if Self.isOnlineStageModel(candidate) { return true }
            return installedLower.contains(candidate.lowercased()) && Self.isLocalStageModel(candidate)
        }
    }

    func queueNeedsOllamaForConfiguredModels() -> Bool {
        settings.translatorCandidates.contains { Self.isLocalStageModel($0) }
            || settings.improverCandidates.contains { Self.isLocalStageModel($0) }
            || settings.confidenceReferee == "local"
            || settings.confidenceReferee == "hybrid"
    }

    func validateQueueModels(index: Int, translators: [String], improvers: [String]) -> Bool {
        guard !translators.isEmpty else {
            mark(index: index, status: .blocked, message: "No runnable translator candidates.")
            return false
        }
        guard !improvers.isEmpty else {
            mark(index: index, status: .blocked, message: "No runnable improver candidates.")
            return false
        }
        return true
    }

    func prepareRunContext(index: Int, translators: [String], improvers: [String]) -> RusToPromptQueueRunContext? {
        let item = items[index]
        let resumedURL = item.recoveredAfterRestart ? item.outputPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } : nil
        let runURL = resumedURL ?? repoRootURL.appendingPathComponent(".stress").appendingPathComponent("queue-runs").appendingPathComponent("\(Self.timestampID())-\(item.id)")
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
        items[index].startedAt = items[index].startedAt ?? Date()
        items[index].updatedAt = Date()
        items[index].outputPath = context.runURL.path
        items[index].runCount += 1
        items[index].recoveredAfterRestart = false
        items[index].snapshot = context.snapshot
        saveToDisk()
        activeItemID = context.item.id
        activeControlFileURL = context.controlURL
        currentOutputPath = context.runURL.path
        currentStage = "Starting"
        currentModel = "-"
        resetModelProgress(itemID: context.item.id, snapshot: context.snapshot)
        armProgressTail(runURL: context.runURL)
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
        DeepSeekCredentialStore.apply(to: &environment)
        GeminiCredentialStore.apply(to: &environment)
        process.environment = environment
        return process
    }

    func queueArguments(context: RusToPromptQueueRunContext, translators: [String], improvers: [String]) -> [String] {
        var arguments = [stressScriptURL.path, "--benchmark-mode", "staged", "--cases-file", context.casesURL.path, "--limit", "1", "--translator-models"]
        arguments.append(contentsOf: translators)
        arguments.append("--analyzer-models")
        arguments.append(contentsOf: improvers)
        arguments.append(contentsOf: queueConfidenceArguments(context: context))
        if context.item.recoveredAfterRestart {
            arguments.append("--resume-existing")
        }
        return arguments
    }

    func queueConfidenceArguments(context: RusToPromptQueueRunContext) -> [String] {
        let snapshot = context.snapshot
        let model = snapshot.confidenceReferee == "hybrid" ? snapshot.hybridGeminiModel : snapshot.confidenceModel
        var arguments = ["--confidence-referee", snapshot.confidenceReferee, "--confidence-model", model, "--confidence-reasoning-effort", RusToPromptSettingsStore.defaultConfidenceReasoning, "--confidence-workers", ["hybrid", "local"].contains(snapshot.confidenceReferee) ? "1" : "3", "--confidence-batch-size", "\(snapshot.confidenceBatchSize)", "--translation-confidence-threshold", "0.75", "--codex-bin", Self.codexExecutablePath(), "--gemini-bin", Self.geminiExecutablePath(), "--codex-stage-reasoning-effort", RusToPromptSettingsStore.defaultConfidenceReasoning, "--workers", "1", "--stage-cooldown-seconds", String(format: "%.1f", snapshot.cooldownSeconds), "--control-file", context.controlURL.path, "--out-dir", context.runURL.path]
        if snapshot.confidenceReferee == "hybrid" {
            arguments.append("--local-confidence-models")
            arguments.append(contentsOf: snapshot.localConfidenceModels)
            arguments.append(contentsOf: ["--hybrid-confidence-online-model", snapshot.hybridGeminiModel, "--hybrid-confidence-fallback-referee", snapshot.hybridFallbackReferee ?? "gemini", "--hybrid-confidence-local-threshold", "0.80", "--hybrid-confidence-disagreement-threshold", "0.15"])
        }
        return arguments
    }

    func attachQueueHandlers(to process: Process, runURL: URL) {
        // Detach the child from an app-held pipe: route stdout/stderr to a file so app
        // quit/crash can't break the pipe (which killed the run) and the orphaned child
        // keeps running. Live progress is read by tailing progress.log on the timer.
        let captureURL = runURL.appendingPathComponent("process.out")
        if !FileManager.default.fileExists(atPath: captureURL.path) {
            FileManager.default.createFile(atPath: captureURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: captureURL) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        process.terminationHandler = { [weak self] finishedProcess in
            DispatchQueue.main.async { self?.handleProcessFinished(status: finishedProcess.terminationStatus) }
        }
    }


    func handleProcessFinished(status: Int32) {
        let itemID = activeItemID
        let outputPath = activeItemID.flatMap { id in items.first(where: { $0.id == id })?.outputPath }
        let controlURL = activeControlFileURL

        Task {
            let completionMessage: String?
            if status == 0 {
                completionMessage = await queueRunCompletionMessage(outputPath: outputPath)
            } else {
                completionMessage = nil
            }

            let stopped = status != 0 ? await controlFlagFromActiveFileAsync("stop", controlURL: controlURL) : false

            await MainActor.run {
                pumpProgressLog()  // flush any final progress.log lines before tearing down the tail
                defer {
                    batteryStartOverrideItemID = nil
                    activeProcess = nil
                    activeReattachedPID = nil
                    activeItemID = nil
                    activeControlFileURL = nil
                    disarmProgressTail()
                    isRunning = false
                    currentStage = "Idle"
                    currentModel = "-"
                    startNextIfPossible()
                }
                guard let itemID = itemID, let index = items.firstIndex(where: { $0.id == itemID }) else { return }
                items[index].pid = nil

                if status == 0 {
                    let msg = completionMessage ?? "Completed"
                    items[index].status = .completed
                    items[index].statusMessage = msg
                    completeModelProgress(itemID: itemID)
                    appendActivity("Queue run \(itemID): \(msg).")
                } else {
                    items[index].status = stopped ? .interrupted : .failed
                    items[index].statusMessage = stopped ? "Interrupted by user" : "Process exited with code \(status)"
                    markModelProgressTerminal(itemID: itemID, label: items[index].statusMessage, status: stopped ? "interrupted" : "failed")
                    appendActivity("Queue run \(itemID) ended: \(items[index].statusMessage).")
                }
                items[index].finishedAt = Date()
                items[index].updatedAt = Date()
                saveToDisk()
            }
        }
    }
}
