import Foundation

struct RecordingIndexEntry: Sendable {
    let url: URL
    let date: Date
    let duration: TimeInterval
    let hasTranscript: Bool
}

struct RecordingDurationCacheEntry: Sendable {
    let fileSize: Int64
    let modificationDate: Date
    let duration: TimeInterval
}
