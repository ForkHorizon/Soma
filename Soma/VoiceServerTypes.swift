import Foundation

enum VoiceWorkClass: String, Codable, Sendable {
    case interactive
    case background
}


enum VoiceChunkPipelineError: LocalizedError {
    case unsupported
    case missingSession
    case missingChunk(Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "Soma Voice Server does not support chunk sessions."
        case .missingSession: "Voice session was not created."
        case .missingChunk(let index): "Voice chunk \(index) was not uploaded."
        case .server(let message): message
        }
    }
}

struct VoiceChunkPipelineResult: Sendable {
    let text: String
    let mergeSafe: Bool
    let inferSeconds: Double?
}

nonisolated struct VoiceServerHealth: Decodable, Sendable {
    let version: Int?
    let capabilities: [String]?
}

nonisolated struct VoiceServerWarmupResponse: Decodable, Sendable {
    let already_loaded: Bool?
    let load_seconds: Double?
}

nonisolated struct VoiceServerSessionResponse: Decodable, Sendable {
    let session_id: String?
    let status: String?
    let text: String?
    let partial_text: String?
    let merge_safe: Bool?
    let accepted_chunks: Int?
    let completed_chunks: Int?
    let metrics: VoiceServerSessionMetrics?
    let error: VoiceServerPipelineError?
}

nonisolated struct VoiceServerSessionMetrics: Decodable, Sendable {
    let queued_seconds: Double?
    let infer_seconds: Double?
    let duration_milliseconds: Int?
}

nonisolated struct VoiceServerPipelineError: Decodable, Sendable {
    let message: String?
}

/// Emits timing-only, privacy-preserving diagnostics. Transcript text and audio
/// never appear in these events.
nonisolated enum VoiceMetrics {
    static func log(_ event: String, _ fields: [String: String] = [:]) {
        var payload = fields
        payload["event"] = event
        payload["timestamp_milliseconds"] = "\(Int(Date().timeIntervalSince1970 * 1_000))"
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return }
        print("[soma.voice] \(text)")
    }
}
