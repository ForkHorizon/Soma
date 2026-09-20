import Foundation

extension ASRManager {
    // MARK: Imported media queue

    @MainActor
    func enqueueImportedFiles(_ urls: [URL], translateAfterTranscription: Bool = false) {
        let remoteURL = voiceServerURL?.absoluteString
        for url in urls where url.isFileURL {
            var job = MediaImportJob(sourceURL: url, backend: backend, engine: engine, remoteURL: remoteURL)
            job.translateAfterTranscription = translateAfterTranscription
            importJobs.append(job)
        }
        persistImportQueue()
        startImportQueueIfNeeded()
    }

    @MainActor
    func retryImport(_ id: UUID) {
        guard let index = importJobs.firstIndex(where: { $0.id == id }) else { return }
        var job = importJobs[index]
        job.prepareForRetry()
        if job.backend == "remote" {
            job.remoteURL = voiceServerURL?.absoluteString
        }
        job.phase = FileManager.default.fileExists(atPath: job.sourcePath) ? .queued : .needsSource
        importJobs[index] = job
        persistImportQueue()
        startImportQueueIfNeeded()
    }

    @MainActor
    func cancelImport(_ id: UUID) {
        guard let index = importJobs.firstIndex(where: { $0.id == id }) else { return }
        let job = importJobs.remove(at: index)
        cancelledImportIDs.insert(id)
        try? FileManager.default.removeItem(at: importWorkDirectory(for: job))
        persistImportQueue()
        if let rawURL = job.remoteURL, let base = URL(string: rawURL), let sessionID = job.sessionID {
            let token = voiceServerToken
            Task { await Self.cancelImportedSession(base: base, token: token, clientID: self.voiceServerClientID, sessionID: sessionID) }
        }
    }

    @MainActor
    func locateImportSource(_ id: UUID, at url: URL) {
        guard let index = importJobs.firstIndex(where: { $0.id == id }), url.isFileURL else { return }
        importJobs[index].sourcePath = url.path
        importJobs[index].displayName = url.lastPathComponent
        importJobs[index].phase = .queued
        importJobs[index].errorMessage = nil
        persistImportQueue()
        startImportQueueIfNeeded()
    }

    @MainActor
    func importedTranscript(for item: MediaImportHistory) -> String {
        (try? String(contentsOf: item.transcriptURL, encoding: .utf8)) ?? ""
    }

    @MainActor
    func importedTranslation(for item: MediaImportHistory) -> String {
        guard let url = item.translatedTranscriptURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @MainActor
    func configure(textPriorityQueue: VoiceTextPriorityQueue) {
        self.textPriorityQueue = textPriorityQueue
    }

    @MainActor
    func setImportedTranslation(_ id: UUID, path: URL) {
        guard let index = importHistory.firstIndex(where: { $0.id == id }) else { return }
        let current = importHistory[index]
        importHistory[index] = MediaImportHistory(
            id: current.id,
            displayName: current.displayName,
            completedAt: current.completedAt,
            transcriptPath: current.transcriptPath,
            translatedTranscriptPath: path.path,
            durationSeconds: current.durationSeconds
        )
        persistImportQueue()
    }

    @MainActor
    func resumeImportQueue() {
        startImportQueueIfNeeded()
    }

    func restoreImportQueue() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: importQueueURL), let saved = try? decoder.decode([MediaImportJob].self, from: data) {
            importJobs = saved.map { savedJob in
                var job = savedJob
                job.prepareToResumeAfterRelaunch()
                return job
            }
        }
        if let data = try? Data(contentsOf: importHistoryURL), let saved = try? decoder.decode([MediaImportHistory].self, from: data) {
            importHistory = saved
        }
    }

    func persistImportQueue() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(importJobs) { try? data.write(to: importQueueURL, options: .atomic) }
        if let data = try? encoder.encode(importHistory) { try? data.write(to: importHistoryURL, options: .atomic) }
    }

    @MainActor
    func startImportQueueIfNeeded() {
        guard importQueueTask == nil, importJobs.contains(where: { $0.phase == .queued }) else { return }
        importQueueTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let job = self.importJobs.first(where: { $0.phase == .queued }) {
                self.activeImportID = job.id
                await self.processImport(job.id)
            }
            self.activeImportID = nil
            self.importQueueTask = nil
        }
    }

    @MainActor
    func processImport(_ id: UUID) async {
        cancelledImportIDs.remove(id)
        guard var job = currentImport(id) else { return }
        guard FileManager.default.fileExists(atPath: job.sourcePath) else {
            updateImport(id, phase: .needsSource, error: "Source file was moved. Choose it again to resume.")
            return
        }
        do {
            if job.durationSeconds == nil || job.plannedChunks == nil {
                updateImport(id, phase: .probing)
                let duration: Double
                if let knownDuration = job.durationSeconds {
                    duration = knownDuration
                } else {
                    duration = try await MediaImportTools.probeDuration(job.sourceURL)
                }
                let chunks = try await MediaImportTools.planChunks(sourceURL: job.sourceURL, duration: duration)
                job = currentImport(id) ?? job
                job.durationSeconds = duration
                job.plannedChunks = chunks
                job.totalChunks = chunks.count
                if job.nextChunkIndex > 0 || job.sessionID != nil {
                    job.nextChunkIndex = 0
                    job.sessionID = nil
                    job.localFragments = []
                }
                replaceImport(job)
            }
            let text =
                job.backend == "remote"
                ? try await transcribeImportedRemotely(id)
                : try await transcribeImportedLocally(id)
            try completeImport(id, transcript: text)
        } catch is CancellationError {
            return
        } catch {
            updateImport(id, phase: .failed, error: error.localizedDescription)
        }
    }
}
