import Foundation

struct VoiceServerErrorEnvelope: Decodable {
    let error: VoiceServerErrorDetail?
}

struct VoiceServerErrorDetail: Decodable {
    let code: String?
    let message: String?
    let retryable: Bool?
}
