import Foundation

extension ASRManager {
    // MARK: Transcription

    /// POST one WAV to the warm server and return its transcript (nil on error).
    /// Used for both new recordings and saved-file re-transcription.
    func transcribeFile(_ audioURL: URL) async -> String? {
        if usesRemoteServer {
            return await transcribeRemotely(audioURL)
        }
        do {
            let port = try await ensureServerReady()
            let payload: [String: Any] = [
                "audio": audioURL.path,
                "idle_seconds": keepLoadedMinutes * 60,
            ]
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/transcribe")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            req.timeoutInterval = 600  // first call may load the model

            let (data, response) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                await MainActor.run { status = "Transcription failed: \(obj["error"] as? String ?? "HTTP \(code)")" }
                return nil
            }
            if let secs = obj["infer_seconds"] as? Double { await MainActor.run { lastInferSeconds = secs } }
            return (obj["text"] as? String) ?? ""
        } catch {
            await MainActor.run { status = "Error: \(error.localizedDescription)" }
            return nil
        }
    }

    @MainActor
    func checkVoiceServer(silent: Bool = false) async {
        guard let base = voiceServerURL else {
            remoteChunkCapability = nil
            remoteCapabilityIdentity = ""
            voiceServerConnectionState = .offline
            voiceServerStatusDetail = voiceServerURLProblem
            if !silent { status = voiceServerURLProblem }
            return
        }
        voiceServerConnectionState = .checking
        voiceServerStatusDetail = "Checking \(base.host ?? base.absoluteString)…"
        do {
            var req = remoteRequest(base.appendingPathComponent("v1/health"))
            req.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let message = remoteErrorMessage(data) ?? "HTTP error"
                remoteChunkCapability = nil
                remoteCapabilityIdentity = ""
                voiceServerConnectionState = .offline
                voiceServerStatusDetail = message
                if !silent { status = "Voice Server check failed: \(message)" }
                return
            }
            applyRemoteCapabilities(try? JSONDecoder().decode(VoiceServerHealth.self, from: data))
            if !silent { status = "Voice Server online." }
        } catch {
            applyRemoteCapabilities(nil)
            voiceServerStatusDetail = error.localizedDescription
            if !silent { status = "Voice Server unavailable: \(error.localizedDescription)" }
        }
    }

    /// Records what one /v1/health answer tells us. Shared so a recording's own
    /// probe updates the cache and the badge without a second request.
    @MainActor
    func applyRemoteCapabilities(_ health: VoiceServerHealth?) {
        guard let health else {
            remoteChunkCapability = nil
            remoteCapabilityIdentity = ""
            voiceServerConnectionState = .offline
            voiceServerStatusDetail = "Unreachable"
            return
        }
        let capabilities = Set(health.capabilities ?? [])
        remoteChunkCapability = (health.version ?? 0) >= 2
            && capabilities.isSuperset(of: ["warmup", "chunk_sessions", "long_poll"])
        remoteCapabilityIdentity = remoteCapabilityConfigIdentity
        voiceServerConnectionState = .online
        voiceServerStatusDetail = "Online"
    }

    func transcribeRemotely(_ audioURL: URL) async -> String? {
        guard let base = voiceServerURL else {
            await MainActor.run {
                voiceServerConnectionState = .offline
                voiceServerStatusDetail = voiceServerURLProblem
                status = voiceServerURLProblem
            }
            return nil
        }
        do {
            let startedAt = Date()
            let audio = try Data(contentsOf: audioURL)
            let requestID = UUID().uuidString
            let jobID = try await submitRemoteJob(base: base, audio: audio, requestID: requestID)
            await MainActor.run {
                voiceServerConnectionState = .online
                voiceServerStatusDetail = "Online"
                status = "Queued on Soma Voice Server…"
            }
            do {
                let text = try await pollRemoteJob(base: base, jobID: jobID)
                VoiceMetrics.log("whole_file_finished", [
                    "release_to_final_milliseconds": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
                ])
                return text
            } catch let error as VoiceServerRemoteError where error.retryable || error.code == "job_not_found" {
                await MainActor.run { status = "Voice Server lost job; retrying…" }
                let retryJobID = try await submitRemoteJob(base: base, audio: audio, requestID: UUID().uuidString)
                let text = try await pollRemoteJob(base: base, jobID: retryJobID)
                VoiceMetrics.log("whole_file_finished", [
                    "release_to_final_milliseconds": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
                    "retried": "true",
                ])
                return text
            }
        } catch {
            await MainActor.run {
                voiceServerConnectionState = .offline
                voiceServerStatusDetail = error.localizedDescription
                status = "Voice Server error: \(error.localizedDescription)"
            }
            return nil
        }
    }

    func submitRemoteJob(base: URL, audio: Data, requestID: String) async throws -> String {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                var req = remoteRequest(base.appendingPathComponent("v1/transcriptions"))
                req.httpMethod = "POST"
                req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
                req.setValue(voiceServerClientID, forHTTPHeaderField: "X-Soma-Client-ID")
                req.setValue(requestID, forHTTPHeaderField: "X-Soma-Request-ID")
                req.setValue(engine, forHTTPHeaderField: "X-Soma-Engine")
                req.setValue(String(keepLoadedMinutes * 60), forHTTPHeaderField: "X-Soma-Idle-Seconds")
                req.httpBody = audio
                req.timeoutInterval = 60
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 202,
                      let payload = try? JSONDecoder().decode(VoiceServerJobResponse.self, from: data),
                      let jobID = payload.job_id
                else {
                    throw remoteError(data, fallback: "Upload failed (HTTP \(code)).", retryable: code >= 500)
                }
                return jobID
            } catch {
                if let remoteError = error as? VoiceServerRemoteError, !remoteError.retryable {
                    throw remoteError
                }
                lastError = error
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        throw lastError ?? SomaError("Upload failed.")
    }

    func pollRemoteJob(base: URL, jobID: String) async throws -> String {
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            do {
                var components = URLComponents(url: base.appendingPathComponent("v1/transcriptions/\(jobID)"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "wait", value: "25")]
                var req = remoteRequest(components.url!)
                req.timeoutInterval = 30
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200,
                      let payload = try? JSONDecoder().decode(VoiceServerJobResponse.self, from: data)
                else {
                    throw remoteError(data, fallback: "Polling failed (HTTP \(code)).", retryable: code >= 500)
                }
                switch payload.status {
                case "done":
                    await MainActor.run { lastInferSeconds = payload.infer_seconds }
                    return payload.text ?? ""
                case "failed":
                    let detail = payload.error
                    throw VoiceServerRemoteError(
                        code: detail?.code ?? "transcription_failed",
                        message: detail?.message ?? "Remote transcription \(payload.status ?? "failed").",
                        retryable: detail?.retryable ?? true
                    )
                default:
                    let queued = payload.queued_seconds.map { String(format: "%.1fs", $0) } ?? "waiting"
                    await MainActor.run { status = "Voice Server \(payload.status ?? "queued") (\(queued))…" }
                }
            } catch {
                if let remoteError = error as? VoiceServerRemoteError { throw remoteError }
                if let somaError = error as? SomaError { throw somaError }
                await MainActor.run { status = "Waiting for Soma Voice Server…" }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SomaError("Remote transcription timed out.")
    }

    func remoteRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = voiceServerToken
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    func remoteErrorMessage(_ data: Data) -> String? {
        (try? JSONDecoder().decode(VoiceServerErrorEnvelope.self, from: data).error?.message)
    }

    func remoteError(_ data: Data, fallback: String, retryable: Bool) -> VoiceServerRemoteError {
        let detail = (try? JSONDecoder().decode(VoiceServerErrorEnvelope.self, from: data).error)
        return VoiceServerRemoteError(
            code: detail?.code ?? "http_error",
            message: detail?.message ?? fallback,
            retryable: detail?.retryable ?? retryable
        )
    }
}
