import Foundation

/// Serializes session creation and file-backed uploads. Recording can continue
/// while this actor uploads and the server decodes completed phrase chunks.
actor VoiceChunkPipeline {
    private let base: URL
    private let token: String
    private let clientID: String
    private let engine: String
    private let idleSeconds: Int
    private let workClass: VoiceWorkClass
    private let capabilityHint: Bool?
    private let onCapabilities: (@Sendable (VoiceServerHealth?) -> Void)?
    private let onPartialTranscript: (@Sendable (String) -> Void)?
    private let sessionRequestID = UUID().uuidString
    private var sessionID: String?
    private var started = false
    private var cancelled = false
    private var warmupTask: Task<Void, Never>?
    private var capabilityTask: Task<VoiceServerHealth?, Never>?
    private var partialTask: Task<Void, Never>?
    private var pending: [Int: VoiceChunk] = [:]
    private var uploaded: Set<Int> = []
    private var failure: Error?
    private var allChunkURLs: [URL] = []
    private var sentFinalChunk = false
    private var supportsFinalChunkFinalize = false

    init(
        base: URL,
        token: String,
        clientID: String,
        engine: String,
        idleSeconds: Int,
        workClass: VoiceWorkClass = .interactive,
        capabilityHint: Bool? = nil,
        onCapabilities: (@Sendable (VoiceServerHealth?) -> Void)? = nil,
        onPartialTranscript: (@Sendable (String) -> Void)? = nil
    ) {
        self.base = base
        self.token = token
        self.clientID = clientID
        self.engine = engine
        self.idleSeconds = idleSeconds
        self.workClass = workClass
        self.capabilityHint = capabilityHint
        self.onCapabilities = onCapabilities
        self.onPartialTranscript = onPartialTranscript
    }

    func start() async {
        guard !started, !cancelled else { return }
        started = true
        guard capabilityHint != false else {
            failure = VoiceChunkPipelineError.unsupported
            log("session_unavailable", ["error": "chunk sessions are known to be unsupported"])
            return
        }
        // Warm before anything else and without awaiting: a cold model load is
        // tens of seconds and depends on nothing here, so every round trip it
        // waits behind is added straight to the user's tail latency.
        startWarmup()
        // Creating the session is itself the capability probe — an older server
        // 404s it — so capabilities are fetched alongside rather than ahead of
        // it. Their only other job is deciding whether the final chunk can
        // carry the finalize header, which is not needed until that chunk.
        startCapabilityFetch()
        do {
            let createdSessionID = try await createSession()
            guard !cancelled else {
                await deleteSession(createdSessionID)
                return
            }
            sessionID = createdSessionID
            partialTask = VoiceSessionPartialWatcher.start(
                sessionID: createdSessionID, base: base, token: token, clientID: clientID,
                engine: engine, idleSeconds: idleSeconds, onPartial: onPartialTranscript
            )
            await drain()
            if !cancelled {
                log("session_started", ["session_id": sessionID ?? ""])
            }
        } catch {
            if !cancelled {
                failure = error
                log("session_unavailable", ["error": error.localizedDescription])
            }
        }
    }

    private func startWarmup() {
        warmupTask = Task { [base, token, clientID, engine, idleSeconds] in
            let warmStartedAt = Date()
            do {
                let result = try await VoiceServerRequest.warm(
                    base: base,
                    token: token,
                    clientID: clientID,
                    engine: engine,
                    idleSeconds: idleSeconds
                )
                VoiceMetrics.log(
                    "warmup_finished",
                    [
                        "engine": engine,
                        "already_loaded": "\(result.already_loaded ?? false)",
                        "load_seconds": "\(result.load_seconds ?? 0)",
                        "request_milliseconds": "\(Int(Date().timeIntervalSince(warmStartedAt) * 1_000))",
                    ])
            } catch {
                VoiceMetrics.log(
                    "warmup_failed",
                    [
                        "engine": engine,
                        "request_milliseconds": "\(Int(Date().timeIntervalSince(warmStartedAt) * 1_000))",
                    ])
            }
        }
    }

    private func startCapabilityFetch() {
        capabilityTask = Task { [base, token, clientID, engine, idleSeconds] in
            await VoiceServerRequest.health(base: base, token: token, clientID: clientID, engine: engine, idleSeconds: idleSeconds)
        }
    }

    /// Awaits the concurrent capability fetch. Called only where the answer is
    /// actually used, so it never sits on the record-start path.
    private func resolveCapabilities() async {
        guard let capabilityTask else { return }
        self.capabilityTask = nil
        let health = await capabilityTask.value
        let capabilities = Set(health?.capabilities ?? [])
        let supported =
            (health?.version ?? 0) >= 2
            && capabilities.isSuperset(of: ["warmup", "chunk_sessions", "long_poll"])
        supportsFinalChunkFinalize = supported && capabilities.contains("final_chunk_finalize")
        // Only a server that answered and said "no" invalidates the session. If
        // the probe itself failed we keep going: the session is demonstrably
        // working, and an explicit finalize request covers the missing flag.
        if health != nil, !supported, failure == nil {
            failure = VoiceChunkPipelineError.unsupported
        }
        onCapabilities?(health)
    }

    /// Waits for every sealed chunk to be acknowledged, then hands back the
    /// session that is ready to finalize.
    private func drainRemainingChunks(expectedChunkCount: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(90)
        while uploaded.count < expectedChunkCount && failure == nil && Date() < deadline {
            await drain()
            if uploaded.count < expectedChunkCount {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        if let failure {
            cleanup()
            throw failure
        }
        guard uploaded.count == expectedChunkCount else {
            cleanup()
            throw VoiceChunkPipelineError.missingChunk(uploaded.count)
        }
        guard let sessionID else {
            cleanup()
            throw VoiceChunkPipelineError.missingSession
        }
        return sessionID
    }

    func enqueue(_ chunk: VoiceChunk) async {
        guard !cancelled else {
            try? FileManager.default.removeItem(at: chunk.url)
            return
        }
        allChunkURLs.append(chunk.url)
        pending[chunk.index] = chunk
        await drain()
    }

    func finalize(expectedChunkCount: Int) async throws -> VoiceChunkPipelineResult {
        if !started { await start() }
        // Backstop for a session with no final chunk: the capability answer is
        // long since in, and the client still wants it for its cache.
        await resolveCapabilities()
        let releasedAt = Date()
        log(
            "recording_released",
            [
                "expected_chunks": "\(expectedChunkCount)",
                "acknowledged_chunks": "\(uploaded.count)",
                "pending_chunks": "\(max(0, expectedChunkCount - uploaded.count))",
            ])
        let sessionID = try await drainRemainingChunks(expectedChunkCount: expectedChunkCount)
        do {
            if !supportsFinalChunkFinalize || !sentFinalChunk {
                try await finalizeSession(sessionID)
            }
            let response = try await waitForFinalSession(sessionID)
            guard response.status == "done" else {
                throw VoiceChunkPipelineError.server(response.error?.message ?? "Voice session did not finish.")
            }
            let result = VoiceChunkPipelineResult(
                text: response.text ?? "",
                mergeSafe: response.merge_safe ?? false,
                inferSeconds: response.metrics?.infer_seconds
            )
            log(
                "session_done",
                [
                    "accepted_chunks": "\(response.accepted_chunks ?? 0)",
                    "completed_chunks": "\(response.completed_chunks ?? 0)",
                    "queued_seconds": "\(response.metrics?.queued_seconds ?? 0)",
                    "infer_seconds": "\(response.metrics?.infer_seconds ?? 0)",
                    "duration_milliseconds": "\(response.metrics?.duration_milliseconds ?? 0)",
                    "release_to_final_milliseconds": "\(Int(Date().timeIntervalSince(releasedAt) * 1_000))",
                ])
            partialTask?.cancel()
            partialTask = nil
            cleanup()
            return result
        } catch {
            cleanup()
            throw error
        }
    }

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        warmupTask?.cancel()
        warmupTask = nil
        capabilityTask?.cancel()
        capabilityTask = nil
        partialTask?.cancel()
        partialTask = nil
        let activeSessionID = sessionID
        sessionID = nil
        cleanup()
        if let activeSessionID {
            await deleteSession(activeSessionID)
        }
    }

    private func drain() async {
        guard failure == nil, let sessionID else { return }
        while let next = pending.keys.sorted().first(where: { !uploaded.contains($0) }), let chunk = pending[next] {
            // First point that needs capabilities: only a server advertising
            // final_chunk_finalize accepts the piggybacked finalize header.
            if chunk.reason == .final {
                await resolveCapabilities()
                guard failure == nil else { return }
            }
            do {
                let uploadStartedAt = Date()
                try await upload(chunk, to: sessionID)
                uploaded.insert(next)
                sentFinalChunk = sentFinalChunk || chunk.reason == .final
                log(
                    "chunk_uploaded",
                    [
                        "index": "\(next)",
                        "reason": chunk.reason.rawValue,
                        "duration_milliseconds": "\(chunk.durationMilliseconds)",
                        "upload_milliseconds": "\(Int(Date().timeIntervalSince(uploadStartedAt) * 1_000))",
                    ])
            } catch {
                failure = error
                return
            }
        }
    }

    private func createSession() async throws -> String {
        var request = request(base.appendingPathComponent("v1/sessions"))
        request.httpMethod = "POST"
        request.setValue(sessionRequestID, forHTTPHeaderField: "X-Soma-Request-ID")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 201, let session = try? JSONDecoder().decode(VoiceServerSessionResponse.self, from: data),
            let sessionID = session.session_id
        else {
            throw VoiceChunkPipelineError.server(remoteErrorMessage(data, fallback: "Could not create voice session."))
        }
        return sessionID
    }

    private func upload(_ chunk: VoiceChunk, to sessionID: String) async throws {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                var request = request(base.appendingPathComponent("v1/sessions/\(sessionID)/chunks/\(chunk.index)"))
                request.httpMethod = "PUT"
                request.setValue(chunk.contentType, forHTTPHeaderField: "Content-Type")
                request.setValue(workClass.rawValue, forHTTPHeaderField: "X-Soma-Work-Class")
                request.setValue("\(sessionID)-\(chunk.index)", forHTTPHeaderField: "X-Soma-Request-ID")
                request.setValue(chunk.reason.rawValue, forHTTPHeaderField: "X-Soma-Chunk-Reason")
                if supportsFinalChunkFinalize, chunk.reason == .final {
                    request.setValue("1", forHTTPHeaderField: "X-Soma-Finalize-Session")
                }
                request.setValue("\(chunk.overlapMilliseconds)", forHTTPHeaderField: "X-Soma-Overlap-Milliseconds")
                request.setValue("\(chunk.durationMilliseconds)", forHTTPHeaderField: "X-Soma-Chunk-Duration-Milliseconds")
                request.timeoutInterval = 60
                let (data, response) = try await URLSession.shared.upload(for: request, fromFile: chunk.url)
                guard (response as? HTTPURLResponse)?.statusCode == 202 else {
                    throw VoiceChunkPipelineError.server(remoteErrorMessage(data, fallback: "Chunk upload failed."))
                }
                return
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        throw lastError ?? VoiceChunkPipelineError.server("Chunk upload failed.")
    }

    private func finalizeSession(_ sessionID: String) async throws {
        var request = request(base.appendingPathComponent("v1/sessions/\(sessionID)/finalize"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceChunkPipelineError.server(remoteErrorMessage(data, fallback: "Could not finalize voice session."))
        }
    }

    private func deleteSession(_ sessionID: String) async {
        var request = request(base.appendingPathComponent("v1/sessions/\(sessionID)"))
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
    }

    private func waitForFinalSession(_ sessionID: String) async throws -> VoiceServerSessionResponse {
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            var components = URLComponents(url: base.appendingPathComponent("v1/sessions/\(sessionID)"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "wait", value: "25")]
            var request = request(components.url!)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                let payload = try? JSONDecoder().decode(VoiceServerSessionResponse.self, from: data)
            else {
                throw VoiceChunkPipelineError.server(remoteErrorMessage(data, fallback: "Voice session polling failed."))
            }
            if payload.status == "done" || payload.status == "failed" || payload.status == "canceled" {
                return payload
            }
        }
        throw VoiceChunkPipelineError.server("Voice session timed out.")
    }

    private func request(_ url: URL) -> URLRequest {
        VoiceServerRequest.build(url, token: token, clientID: clientID, engine: engine, idleSeconds: idleSeconds)
    }

    private func cleanup() {
        for url in allChunkURLs { try? FileManager.default.removeItem(at: url) }
        allChunkURLs.removeAll()
        pending.removeAll()
    }

    private func remoteErrorMessage(_ data: Data, fallback: String) -> String {
        (try? JSONDecoder().decode(VoiceServerSessionResponse.self, from: data).error?.message) ?? fallback
    }

    private func log(_ event: String, _ fields: [String: String]) {
        VoiceMetrics.log(event, fields)
    }
}
