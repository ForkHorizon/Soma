import Foundation

/// Builds authenticated Soma Voice Server requests, plus the two calls that need
/// no session state. The header block below had drifted into three copies
/// across the pipeline and the partial watcher.
enum VoiceServerRequest {
    nonisolated static func build(_ url: URL, token: String, clientID: String, engine: String, idleSeconds: Int) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientID, forHTTPHeaderField: "X-Soma-Client-ID")
        request.setValue(engine, forHTTPHeaderField: "X-Soma-Engine")
        request.setValue("\(idleSeconds)", forHTTPHeaderField: "X-Soma-Idle-Seconds")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Non-throwing so it can run detached alongside session creation; `nil`
    /// means "could not ask", which is deliberately not the same as "no".
    nonisolated static func health(base: URL, token: String, clientID: String, engine: String, idleSeconds: Int) async -> VoiceServerHealth? {
        var request = build(base.appendingPathComponent("v1/health"), token: token, clientID: clientID, engine: engine, idleSeconds: idleSeconds)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(VoiceServerHealth.self, from: data)
    }

    nonisolated static func warm(base: URL, token: String, clientID: String, engine: String, idleSeconds: Int) async throws -> VoiceServerWarmupResponse {
        var request = build(base.appendingPathComponent("v1/warmup"), token: token, clientID: clientID, engine: engine, idleSeconds: idleSeconds)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceChunkPipelineError.server("Model warm-up failed.")
        }
        return try JSONDecoder().decode(VoiceServerWarmupResponse.self, from: data)
    }
}
