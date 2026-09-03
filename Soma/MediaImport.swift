import Foundation

enum MediaImportPhase: String, Codable, Equatable {
    case queued
    case probing
    case converting
    case uploading
    case transcribing
    case waitingForNetwork
    case needsSource
    case failed
}

struct MediaImportChunk: Codable, Equatable {
    let startSeconds: Double
    let durationSeconds: Double
    let reason: String
    let overlapSeconds: Double
}
