import Foundation

struct QueuedTranscription {
    let url: URL
    let source: ASRTranscriptionSource
    let chunkPipeline: VoiceChunkPipeline?
    let expectedChunkCount: Int
    let continuation: CheckedContinuation<String?, Never>
}
