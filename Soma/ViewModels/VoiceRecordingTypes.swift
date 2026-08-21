import Foundation

// Value types shared by ASRManager and the voice views, kept apart from the
// manager so the recording model reads without the capture machinery.

struct VoiceRecording: Identifiable, Hashable {
    let url: URL
    let date: Date
    let duration: Double
    let hasTranscript: Bool  // saved alongside the audio as a sidecar .txt
    var id: URL { url }
}

/// A completed WAV awaiting the serial global-voice delivery queue.
struct CapturedVoiceRecording {
    let url: URL
    let chunkPipeline: VoiceChunkPipeline?
    let expectedChunkCount: Int
}

enum ASRTranscriptionSource {
    case inApp
    case global
}

enum VoiceServerConnectionState {
    case unknown
    case checking
    case online
    case offline
}
