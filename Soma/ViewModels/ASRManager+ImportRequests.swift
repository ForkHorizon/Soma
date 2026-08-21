import Foundation

extension ASRManager {
    func importRemoteRequest(_ url: URL, token: String, clientID: String, engine: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Soma-Client-ID")
        if let engine { request.setValue(engine, forHTTPHeaderField: "X-Soma-Engine") }
        return request
    }

    func createImportedSession(base: URL, token: String, clientID: String, job: MediaImportJob) async throws -> String {
        var request = importRemoteRequest(base.appendingPathComponent("v1/sessions"), token: token, clientID: clientID, engine: job.engine)
        request.httpMethod = "POST"
        request.setValue(job.sessionRequestID, forHTTPHeaderField: "X-Soma-Request-ID")
        request.setValue(String(keepLoadedMinutes * 60), forHTTPHeaderField: "X-Soma-Idle-Seconds")
        request.setValue("auto", forHTTPHeaderField: "X-Soma-Language")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 201, let session = try? JSONDecoder().decode(VoiceServerSessionResponse.self, from: data),
            let id = session.session_id
        else {
            throw remoteError(
                data, fallback: "Could not create import session (HTTP \(code)).", retryable: code >= 500 || code == 408 || code == 429)
        }
        return id
    }

    func uploadImportedChunk(
        base: URL, token: String, clientID: String, sessionID: String, job: MediaImportJob, index: Int, attempt: Int, chunkURL: URL,
        reason: VoiceChunkReason, overlapMilliseconds: Int, durationMilliseconds: Int, retryFailedChunk: Bool = false,
        contextChunkIndex: Int? = nil
    ) async throws -> String {
        var request = importRemoteRequest(
            base.appendingPathComponent("v1/sessions/\(sessionID)/chunks/\(index)"), token: token, clientID: clientID, engine: job.engine)
        request.httpMethod = "PUT"
        request.setValue("audio/flac", forHTTPHeaderField: "Content-Type")
        request.setValue(VoiceWorkClass.background.rawValue, forHTTPHeaderField: "X-Soma-Work-Class")
        request.setValue("client-v1", forHTTPHeaderField: "X-Soma-Chunk-Recovery")
        request.setValue("\(job.id.uuidString)-\(index)-\(attempt)", forHTTPHeaderField: "X-Soma-Request-ID")
        request.setValue(reason.rawValue, forHTTPHeaderField: "X-Soma-Chunk-Reason")
        request.setValue("\(overlapMilliseconds)", forHTTPHeaderField: "X-Soma-Overlap-Milliseconds")
        request.setValue("\(durationMilliseconds)", forHTTPHeaderField: "X-Soma-Chunk-Duration-Milliseconds")
        if retryFailedChunk { request.setValue("1", forHTTPHeaderField: "X-Soma-Retry-Failed-Chunk") }
        if let contextChunkIndex { request.setValue("\(contextChunkIndex)", forHTTPHeaderField: "X-Soma-Context-Chunk-Index") }
        request.timeoutInterval = 90
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: chunkURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw ImportedSessionLost() }
        guard code == 202, let payload = try? JSONDecoder().decode(VoiceServerJobResponse.self, from: data), let jobID = payload.job_id
        else {
            throw remoteError(
                data, fallback: "Import chunk upload failed (HTTP \(code)).", retryable: code >= 500 || code == 408 || code == 429)
        }
        return jobID
    }

    func waitForImportedChunk(base: URL, token: String, clientID: String, jobID: String) async throws -> String {
        while true {
            var components = URLComponents(url: base.appendingPathComponent("v1/transcriptions/\(jobID)"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "wait", value: "25")]
            var request = importRemoteRequest(components.url!, token: token, clientID: clientID)
            request.timeoutInterval = 35
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw ImportedSessionLost() }
            guard code == 200, let payload = try? JSONDecoder().decode(VoiceServerJobResponse.self, from: data) else {
                throw remoteError(data, fallback: "Import chunk polling failed (HTTP \(code)).", retryable: code >= 500 || code == 408)
            }
            switch payload.status {
            case "done": return payload.text ?? ""
            case "failed":
                let detail = payload.error
                throw VoiceServerRemoteError(
                    code: detail?.code ?? "transcription_failed", message: detail?.message ?? "Import chunk failed.",
                    retryable: detail?.retryable ?? true)
            default: continue
            }
        }
    }

    func finalizeImportedSession(base: URL, token: String, sessionID: String) async throws {
        var request = importRemoteRequest(
            base.appendingPathComponent("v1/sessions/\(sessionID)/finalize"), token: token, clientID: voiceServerClientID)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw ImportedSessionLost() }
        guard code == 200 else {
            throw remoteError(data, fallback: "Could not finalize import session.", retryable: code >= 500 || code == 408)
        }
    }

    func waitForImportedSession(base: URL, token: String, sessionID: String) async throws -> VoiceServerSessionResponse {
        while true {
            var components = URLComponents(url: base.appendingPathComponent("v1/sessions/\(sessionID)"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "wait", value: "25")]
            var request = importRemoteRequest(components.url!, token: token, clientID: voiceServerClientID)
            request.timeoutInterval = 35
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw ImportedSessionLost() }
            guard code == 200, let payload = try? JSONDecoder().decode(VoiceServerSessionResponse.self, from: data) else {
                throw remoteError(data, fallback: "Import session polling failed (HTTP \(code)).", retryable: code >= 500 || code == 408)
            }
            switch payload.status {
            case "done": return payload
            case "failed", "canceled": throw SomaError(payload.error?.message ?? "Import session did not complete.")
            default: continue
            }
        }
    }

    func transcribeImportedChunkLocally(_ url: URL, port: Int) async throws -> String {
        let payload: [String: Any] = [
            "audio": url.path,
            "idle_seconds": keepLoadedMinutes * 60,
            "language": "auto",
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/transcribe")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 600
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SomaError(object["error"] as? String ?? "Local transcription failed.")
        }
        return object["text"] as? String ?? ""
    }

    static func cancelImportedSession(base: URL, token: String, clientID: String, sessionID: String) async {
        guard !token.isEmpty else { return }
        var request = URLRequest(url: base.appendingPathComponent("v1/sessions/\(sessionID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Soma-Client-ID")
        _ = try? await URLSession.shared.data(for: request)
    }
}
