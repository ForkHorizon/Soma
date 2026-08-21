import Foundation

// Detached-run support. The staged benchmark is a child process whose stdout/stderr go
// to a file (not an app-held pipe), so it survives app quit/crash. Progress is read by
// tailing progress.log; a run interrupted by app restart is re-attached by PID instead of
// re-spawned, which is what previously stacked up duplicate run_start entries and errors.
extension RusToPromptQueueManager {

    // MARK: progress.log tailing

    func armProgressTail(runURL: URL) {
        let logURL = runURL.appendingPathComponent("progress.log")
        progressLogURL = logURL
        processOutputBuffer = ""
        // Start at end-of-file so we surface live events only, not replay the whole history
        // (a resumed/re-attached run appends to an existing, possibly large, log).
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        progressLogOffset = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func disarmProgressTail() {
        progressLogURL = nil
        progressLogOffset = 0
        processOutputBuffer = ""
    }

    func pumpProgressLog() {
        guard let logURL = progressLogURL,
            let handle = try? FileHandle(forReadingFrom: logURL)
        else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: progressLogOffset)
        } catch {
            return
        }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        progressLogOffset += UInt64(data.count)
        if let text = String(data: data, encoding: .utf8) {
            consumeProcessOutput(text)
        }
    }

    // MARK: re-attach on launch

    /// Called from recoverRunningItems for an item that was `.running` at last save.
    /// Returns true if the still-alive child was re-attached (caller must NOT re-queue it).
    func reattachRunningChildIfAlive(index: Int) -> Bool {
        guard activeProcess == nil, activeReattachedPID == nil else { return false }
        let item = items[index]
        guard let path = item.outputPath, !path.isEmpty else { return false }
        let runURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: runURL.appendingPathComponent("progress.log").path) else { return false }
        // Prefer the saved PID (verified live + argv matches this out-dir, so a recycled PID
        // can't hijack the queue). If it's missing or dead, scan for an orphaned child still
        // running against this out-dir — covers old runs saved before PID tracking and the
        // narrow crash window between spawn and the PID hitting disk. Either way we never
        // re-spawn a second process onto a results file an orphan is still writing.
        let savedPID = item.pid.flatMap { Self.processExists($0) && Self.processMatchesRun(pid: $0, outDir: path) ? $0 : nil }
        guard let pid = savedPID ?? Self.discoverRunPID(outDir: path) else { return false }
        items[index].pid = pid

        activeReattachedPID = pid
        activeItemID = item.id
        activeControlFileURL = appSupportURL.appendingPathComponent(item.id).appendingPathComponent("control.json")
        currentOutputPath = path
        currentStage = "Running staged benchmark"
        items[index].status = .running
        items[index].statusMessage = "Running staged benchmark"
        items[index].recoveredAfterRestart = false
        items[index].updatedAt = Date()
        if let snapshot = item.snapshot {
            resetModelProgress(itemID: item.id, snapshot: snapshot)
        }
        armProgressTail(runURL: runURL)
        isRunning = true
        appendActivity("Re-attached to running queue run \(item.id) (pid \(pid)).")
        return true
    }

    // MARK: re-attached exit detection (no Process handle / terminationHandler)

    func pollReattachedExit() {
        guard let pid = activeReattachedPID, !reattachedExitInFlight else { return }
        guard !Self.processExists(pid) else { return }
        // activeReattachedPID stays set (the busy lock that keeps startNextIfPossible from
        // launching the next item) until handleReattachedExit's defer clears it.
        reattachedExitInFlight = true
        handleReattachedExit(runURL: currentOutputPath.map { URL(fileURLWithPath: $0) })
    }

    func handleReattachedExit(runURL: URL?) {
        let itemID = activeItemID
        let outputPath = currentOutputPath
        let controlURL = activeControlFileURL
        let finishedStatus = runURL.flatMap { Self.lastRunFinishedStatus(runURL: $0) }

        Task {
            let completed = finishedStatus != nil && finishedStatus != "failed"
            let completionMessage = completed ? await queueRunCompletionMessage(outputPath: outputPath) : nil
            let stopped = !completed ? await controlFlagFromActiveFileAsync("stop", controlURL: controlURL) : false

            await MainActor.run {
                pumpProgressLog()
                defer {
                    batteryStartOverrideItemID = nil
                    activeReattachedPID = nil
                    reattachedExitInFlight = false
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
                if completed {
                    let msg = completionMessage ?? "Completed"
                    items[index].status = .completed
                    items[index].statusMessage = msg
                    completeModelProgress(itemID: itemID)
                    appendActivity("Queue run \(itemID): \(msg).")
                } else {
                    items[index].status = stopped ? .interrupted : .failed
                    items[index].statusMessage = stopped ? "Interrupted by user" : "Run process exited without finishing"
                    markModelProgressTerminal(itemID: itemID, label: items[index].statusMessage, status: stopped ? "interrupted" : "failed")
                    appendActivity("Queue run \(itemID) ended: \(items[index].statusMessage).")
                }
                items[index].finishedAt = Date()
                items[index].updatedAt = Date()
                saveToDisk()
            }
        }
    }

    // MARK: helpers

    static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0): 0 = alive; EPERM also means alive (owned by another uid); ESRCH = gone.
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// True if the live `pid`'s argv references this run's out-dir — i.e. it really is our
    /// staged-benchmark child and not a recycled PID now owned by something unrelated.
    nonisolated static func processMatchesRun(pid: Int32, outDir: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let command = String(data: data, encoding: .utf8) ?? ""
        // Match the main-runner entrypoint specifically — transient codex/gemini child calls
        // also carry the out-dir but invoke a different binary, not rus_to_prompt_stress.py.
        return command.contains(outDir) && command.contains("rus_to_prompt_stress.py")
    }

    /// Scan all processes for a still-running staged-benchmark child writing to this out-dir.
    /// Used when no usable PID was saved (legacy runs / crash-before-save).
    nonisolated static func discoverRunPID(outDir: String) -> Int32? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") {
            guard line.contains(outDir), line.contains("rus_to_prompt_stress.py") else { continue }
            let trimmed = line.drop(while: { $0 == " " })
            if let pidStr = trimmed.split(separator: " ", maxSplits: 1).first, let pid = Int32(pidStr) {
                return pid
            }
        }
        return nil
    }

    /// Status of the last `run_finished` SOMA_PROGRESS event in progress.log, or nil if the
    /// run never emitted one (crashed / killed mid-run).
    nonisolated static func lastRunFinishedStatus(runURL: URL) -> String? {
        let logURL = runURL.appendingPathComponent("progress.log")
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"event\":\"run_finished\"") {
            guard let start = line.range(of: "SOMA_PROGRESS ")?.upperBound,
                let data = line[start...].data(using: .utf8),
                let event = try? JSONDecoder().decode(QueueProgressEvent.self, from: data)
            else { continue }
            return event.status ?? "ok"
        }
        return nil
    }
}
