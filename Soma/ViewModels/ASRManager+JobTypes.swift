import Foundation

struct VoiceServerRemoteError: LocalizedError {
    let code: String
    let message: String
    let retryable: Bool

    var errorDescription: String? { message }
}

struct VoiceServerJobResponse: Decodable {
    let job_id: String?
    let status: String?
    let text: String?
    let infer_seconds: Double?
    let queued_seconds: Double?
    let error: VoiceServerErrorDetail?
}
