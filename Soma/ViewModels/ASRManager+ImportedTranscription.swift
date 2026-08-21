import Foundation
import Network

extension ASRManager {
    @MainActor
    func transcribeImportedRemotely(_ id: UUID) async throws -> String {
        guard var job = currentImport(id), let rawURL = job.remoteURL,
            let base = URL(string: rawURL), base.scheme?.lowercased() == "https"
        else { throw SomaError("Remote imports require an HTTPS Soma Voice Server URL.") }
        let token = voiceServerToken
        guard !token.isEmpty else { throw SomaError("Set the Soma Voice Server token before importing media.") }
        let clientID = voiceServerClientID
        while true {
            do {
                job = try await prepareRemoteImportSession(id, job: job, base: base, token: token, clientID: clientID)
                job = try await uploadRemoteImportChunks(id, job: job, base: base, token: token, clientID: clientID)
                guard let sessionID = job.sessionID else { throw SomaError("Import session could not be prepared.") }
                updateImport(id, phase: .transcribing)
                try await retryImportRequest(id) { try await self.finalizeImportedSession(base: base, token: token, sessionID: sessionID) }
                let final = try await retryImportRequest(id) {
                    try await self.waitForImportedSession(base: base, token: token, sessionID: sessionID)
                }
                return final.text ?? ""
            } catch is ImportedSessionLost {
                job = currentImport(id) ?? job
                job.sessionID = nil
                job.nextChunkIndex = 0
                job.retryCount = 0
                replaceImport(job)
            }
        }
    }

    @MainActor
    func prepareRemoteImportSession(_ id: UUID, job: MediaImportJob, base: URL, token: String, clientID: String) async throws
        -> MediaImportJob
    {
        guard job.sessionID == nil else { return job }
        updateImport(id, phase: .uploading)
        let sessionID = try await retryImportRequest(id) {
            try await self.createImportedSession(base: base, token: token, clientID: clientID, job: job)
        }
        var updated = currentImport(id) ?? job
        updated.sessionID = sessionID
        replaceImport(updated)
        return updated
    }

    @MainActor
    func uploadRemoteImportChunks(_ id: UUID, job: MediaImportJob, base: URL, token: String, clientID: String) async throws
        -> MediaImportJob
    {
        guard let sessionID = job.sessionID, let chunks = job.plannedChunks else {
            throw SomaError("Import session could not be prepared.")
        }
        var current = job
        while current.nextChunkIndex < chunks.count {
            current = try await uploadRemoteImportChunk(
                id, job: current, chunks: chunks, sessionID: sessionID, base: base, token: token, clientID: clientID)
        }
        return current
    }

    @MainActor
    func uploadRemoteImportChunk(
        _ id: UUID, job: MediaImportJob, chunks: [MediaImportChunk], sessionID: String, base: URL, token: String, clientID: String
    ) async throws -> MediaImportJob {
        let index = job.nextChunkIndex
        let chunk = chunks[index]
        let chunkURL = importChunkURL(for: job, index: index)
        updateImport(id, phase: .converting)
        try await MediaImportTools.exportChunk(
            sourceURL: job.sourceURL, startSeconds: chunk.startSeconds, durationSeconds: chunk.durationSeconds, to: chunkURL)
        defer { try? FileManager.default.removeItem(at: chunkURL) }
        try ensureImportActive(id)
        let reason = VoiceChunkReason(rawValue: chunk.reason) ?? .forced
        try await uploadAndConfirmImportedChunk(
            id, job: job, chunks: chunks, sessionID: sessionID, chunkURL: chunkURL, reason: reason, base: base, token: token,
            clientID: clientID)
        var updated = currentImport(id) ?? job
        updated.nextChunkIndex += 1
        updated.retryCount = 0
        replaceImport(updated)
        return updated
    }

    @MainActor
    func uploadAndConfirmImportedChunk(
        _ id: UUID, job: MediaImportJob, chunks: [MediaImportChunk], sessionID: String, chunkURL: URL, reason: VoiceChunkReason, base: URL,
        token: String, clientID: String
    ) async throws {
        let index = job.nextChunkIndex
        let chunk = chunks[index]
        let overlap = Int(chunk.overlapSeconds * 1_000)
        let duration = Int(chunk.durationSeconds * 1_000)
        updateImport(id, phase: .uploading)
        let jobID = try await submitImportedChunkRequest(
            id, base: base, token: token, clientID: clientID, sessionID: sessionID, job: job, index: index, attempt: 0, chunkURL: chunkURL,
            reason: reason, overlap: overlap, duration: duration)
        do {
            _ = try await retryImportRequest(id) {
                try await self.waitForImportedChunk(base: base, token: token, clientID: clientID, jobID: jobID)
            }
        } catch let error as VoiceServerRemoteError where error.code == "pathological_repetition" {
            try await recoverPathologicalImportedChunk(
                id, job: job, chunks: chunks, sessionID: sessionID, chunkURL: chunkURL, reason: reason, base: base, token: token,
                clientID: clientID)
        }
    }

    func submitImportedChunkRequest(
        _ id: UUID, base: URL, token: String, clientID: String, sessionID: String, job: MediaImportJob, index: Int, attempt: Int,
        chunkURL: URL, reason: VoiceChunkReason, overlap: Int, duration: Int, contextChunkIndex: Int? = nil
    ) async throws -> String {
        try await retryImportRequest(id) {
            try await self.uploadImportedChunk(
                base: base, token: token, clientID: clientID, sessionID: sessionID, job: job, index: index, attempt: attempt,
                chunkURL: chunkURL, reason: reason, overlapMilliseconds: overlap, durationMilliseconds: duration,
                retryFailedChunk: attempt > 0, contextChunkIndex: contextChunkIndex)
        }
    }

    @MainActor
    func recoverPathologicalImportedChunk(
        _ id: UUID, job: MediaImportJob, chunks: [MediaImportChunk], sessionID: String, chunkURL: URL, reason: VoiceChunkReason, base: URL,
        token: String, clientID: String
    ) async throws {
        let index = job.nextChunkIndex
        let chunk = chunks[index]
        let overlap = Int(chunk.overlapSeconds * 1_000)
        let duration = Int(chunk.durationSeconds * 1_000)
        let retryJobID = try await submitImportedChunkRequest(
            id, base: base, token: token, clientID: clientID, sessionID: sessionID, job: job, index: index, attempt: 1, chunkURL: chunkURL,
            reason: reason, overlap: overlap, duration: duration)
        do {
            _ = try await retryImportRequest(id) {
                try await self.waitForImportedChunk(base: base, token: token, clientID: clientID, jobID: retryJobID)
            }
        } catch let error as VoiceServerRemoteError where error.code == "pathological_repetition" {
            try await retryImportedChunkWithContext(
                id, job: job, chunks: chunks, sessionID: sessionID, reason: reason, base: base, token: token, clientID: clientID)
        }
    }

    @MainActor
    func retryImportedChunkWithContext(
        _ id: UUID, job: MediaImportJob, chunks: [MediaImportChunk], sessionID: String, reason: VoiceChunkReason, base: URL, token: String,
        clientID: String
    ) async throws {
        let index = job.nextChunkIndex
        guard index > 0 else { throw SomaError("The first media segment repeated itself excessively. Retry the import.") }
        let chunk = chunks[index]
        let contextURL = importWorkDirectory(for: job).appendingPathComponent(String(format: "chunk-%05d-context.flac", index))
        defer { try? FileManager.default.removeItem(at: contextURL) }
        let start = chunks[index - 1].startSeconds
        try await MediaImportTools.exportChunk(
            sourceURL: job.sourceURL, startSeconds: start, durationSeconds: chunk.startSeconds + chunk.durationSeconds - start,
            to: contextURL)
        let jobID = try await submitImportedChunkRequest(
            id, base: base, token: token, clientID: clientID, sessionID: sessionID, job: job, index: index, attempt: 2,
            chunkURL: contextURL, reason: reason, overlap: Int(chunk.overlapSeconds * 1_000), duration: Int(chunk.durationSeconds * 1_000),
            contextChunkIndex: index - 1)
        _ = try await retryImportRequest(id) {
            try await self.waitForImportedChunk(base: base, token: token, clientID: clientID, jobID: jobID)
        }
    }

    @MainActor
    func transcribeImportedLocally(_ id: UUID) async throws -> String {
        guard var job = currentImport(id), let chunks = job.plannedChunks else { throw SomaError("Import was not prepared.") }
        let total = chunks.count
        let localPort = try await ensureServerReady()
        while job.nextChunkIndex < total {
            let index = job.nextChunkIndex
            let chunk = chunks[index]
            let start = chunk.startSeconds
            let chunkDuration = chunk.durationSeconds
            updateImport(id, phase: .converting)
            let chunkURL = importChunkURL(for: job, index: index)
            try await MediaImportTools.exportChunk(
                sourceURL: job.sourceURL, startSeconds: start, durationSeconds: chunkDuration, to: chunkURL)
            try ensureImportActive(id)
            defer { try? FileManager.default.removeItem(at: chunkURL) }
            updateImport(id, phase: .transcribing)
            var fragment = try await transcribeImportedChunkLocally(chunkURL, port: localPort)
            if MediaImportTools.hasPathologicalRepetition(fragment) {
                fragment = try await transcribeImportedChunkLocally(chunkURL, port: localPort)
                if MediaImportTools.hasPathologicalRepetition(fragment) {
                    guard index > 0, let previous = job.localFragments.last else {
                        throw SomaError("The first media segment repeated itself excessively. Retry the import.")
                    }
                    let contextURL = importWorkDirectory(for: job).appendingPathComponent(String(format: "chunk-%05d-context.flac", index))
                    defer { try? FileManager.default.removeItem(at: contextURL) }
                    let contextStart = chunks[index - 1].startSeconds
                    try await MediaImportTools.exportChunk(
                        sourceURL: job.sourceURL, startSeconds: contextStart, durationSeconds: start + chunkDuration - contextStart,
                        to: contextURL)
                    let combined = try await transcribeImportedChunkLocally(contextURL, port: localPort)
                    guard !MediaImportTools.hasPathologicalRepetition(combined),
                        let currentOnly = MediaImportTools.removingContextPrefix(previous, from: combined)
                    else {
                        throw SomaError("A media segment could not be recovered safely. Retry the import.")
                    }
                    fragment = currentOnly
                }
            }
            try ensureImportActive(id)
            job = currentImport(id) ?? job
            job.localFragments.append(fragment)
            job.nextChunkIndex += 1
            replaceImport(job)
        }
        return job.localFragments.reduce("") { MediaImportTools.mergedText($0, with: $1) }
    }

    @MainActor
    func completeImport(_ id: UUID, transcript: String) throws {
        guard let index = importJobs.firstIndex(where: { $0.id == id }) else { return }
        let job = importJobs[index]
        let textURL = importsDir.appendingPathComponent("History/\(job.id.uuidString).txt")
        try transcript.write(to: textURL, atomically: true, encoding: .utf8)
        importJobs.remove(at: index)
        importHistory.insert(
            MediaImportHistory(
                id: job.id,
                displayName: job.displayName,
                completedAt: Date(),
                transcriptPath: textURL.path,
                translatedTranscriptPath: nil,
                durationSeconds: job.durationSeconds
            ), at: 0)
        if job.shouldTranslateAfterTranscription {
            let translatedURL = importsDir.appendingPathComponent("History/\(job.id.uuidString).en.txt")
            textPriorityQueue?.enqueueBackgroundTranslation(importID: job.id, transcript: transcript, destination: translatedURL)
        }
        try? FileManager.default.removeItem(at: importWorkDirectory(for: job))
        persistImportQueue()
    }

    @MainActor
    func currentImport(_ id: UUID) -> MediaImportJob? { importJobs.first(where: { $0.id == id }) }

    @MainActor
    func replaceImport(_ job: MediaImportJob) {
        guard let index = importJobs.firstIndex(where: { $0.id == job.id }) else { return }
        importJobs[index] = job
        persistImportQueue()
    }

    @MainActor
    func updateImport(_ id: UUID, phase: MediaImportPhase, error: String? = nil) {
        guard var job = currentImport(id) else { return }
        job.phase = phase
        job.errorMessage = error
        replaceImport(job)
    }

    func importWorkDirectory(for job: MediaImportJob) -> URL {
        importsDir.appendingPathComponent("Work/\(job.id.uuidString)", isDirectory: true)
    }

    func importChunkURL(for job: MediaImportJob, index: Int) -> URL {
        let directory = importWorkDirectory(for: job)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(String(format: "chunk-%05d.flac", index))
    }

    func retryImportRequest<T>(_ id: UUID, operation: @escaping () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            try ensureImportActive(id)
            do { return try await operation() } catch is ImportedSessionLost { throw ImportedSessionLost() } catch let error
                as VoiceServerRemoteError where error.code == "pathological_repetition"
            { throw error } catch let error as VoiceServerRemoteError where !error.retryable { throw error } catch {
                attempt += 1
                guard var job = currentImport(id) else { throw CancellationError() }
                job.phase = .waitingForNetwork
                job.retryCount = attempt
                job.errorMessage = "Retrying: \(error.localizedDescription)"
                replaceImport(job)
                let seconds = min(60.0, pow(2.0, Double(min(attempt - 1, 6)))) + Double.random(in: 0...0.5)
                try await waitForConnectivityOrDelay(seconds)
            }
        }
    }

    func waitForConnectivityOrDelay(_ seconds: Double) async throws {
        let startedOffline = connectivityMonitor.currentPath.status != .satisfied
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int(seconds * 1_000)))
        while clock.now < deadline {
            try Task.checkCancellation()
            if startedOffline, connectivityMonitor.currentPath.status == .satisfied { return }
            let remaining = clock.now.duration(to: deadline)
            try await Task.sleep(for: min(remaining, .milliseconds(250)))
        }
    }

    struct ImportedSessionLost: Error {}

    @MainActor
    func ensureImportActive(_ id: UUID) throws {
        guard !cancelledImportIDs.contains(id), currentImport(id) != nil else { throw CancellationError() }
    }
}
