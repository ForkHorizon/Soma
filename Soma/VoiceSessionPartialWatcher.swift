import Foundation

/// Streams a session's transcript as it decodes.
///
/// Chunks finish while the user is still speaking — a measured median of 86% of
/// the final text is already on the server by the time they release the key — so
/// anything downstream can start on it instead of waiting for the merge. Kept
/// apart from VoiceChunkPipeline because it only reads: it never uploads,
/// finalises or owns session state.
enum VoiceSessionPartialWatcher {
    nonisolated static func start(
        sessionID: String,
        base: URL,
        token: String,
        clientID: String,
        engine: String,
        idleSeconds: Int,
        onPartial: (@Sendable (String) -> Void)?
    ) -> Task<Void, Never>? {
        guard let onPartial else { return nil }
        return Task {
            var seen = 0
            var lastText = ""
            while !Task.isCancelled {
                var components = URLComponents(
                    url: base.appendingPathComponent("v1/sessions/\(sessionID)"),
                    resolvingAgainstBaseURL: false
                )!
                components.queryItems = [
                    URLQueryItem(name: "wait", value: "25"),
                    URLQueryItem(name: "since_completed", value: "\(seen)"),
                ]
                var request = VoiceServerRequest.build(
                    components.url!, token: token, clientID: clientID, engine: engine, idleSeconds: idleSeconds)
                request.timeoutInterval = 30
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                    (response as? HTTPURLResponse)?.statusCode == 200,
                    let payload = try? JSONDecoder().decode(VoiceServerSessionResponse.self, from: data)
                else { return }
                seen = max(seen, payload.completed_chunks ?? seen)
                if let partial = payload.partial_text, !partial.isEmpty, partial != lastText {
                    lastText = partial
                    onPartial(partial)
                }
                if payload.status != "recording" && payload.status != "finalizing" { return }
            }
        }
    }
}
