import Foundation

struct MediaImportJob: Identifiable, Codable, Equatable {
    let id: UUID
    var sourcePath: String
    var displayName: String
    var createdAt: Date
    var backend: String
    var engine: String
    var remoteURL: String?
    var phase: MediaImportPhase
    var durationSeconds: Double?
    var totalChunks: Int?
    var plannedChunks: [MediaImportChunk]?
    var nextChunkIndex: Int
    var sessionID: String?
    var sessionRequestID: String
    var retryCount: Int
    var errorMessage: String?
    var localFragments: [String]
    /// Imports remain transcript-only unless this is explicitly selected.
    /// Optional keeps manifests written by older app versions decodable.
    var translateAfterTranscription: Bool?

    init(sourceURL: URL, backend: String, engine: String, remoteURL: String?) {
        id = UUID()
        sourcePath = sourceURL.path
        displayName = sourceURL.lastPathComponent
        createdAt = Date()
        self.backend = backend
        self.engine = engine
        self.remoteURL = remoteURL
        phase = .queued
        durationSeconds = nil
        totalChunks = nil
        plannedChunks = nil
        nextChunkIndex = 0
        sessionID = nil
        sessionRequestID = UUID().uuidString
        retryCount = 0
        errorMessage = nil
        localFragments = []
        translateAfterTranscription = false
    }

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var shouldTranslateAfterTranscription: Bool { translateAfterTranscription ?? false }
    var isRetryable: Bool { phase == .failed || phase == .needsSource }

    mutating func prepareToResumeAfterRelaunch() {
        switch phase {
        case .probing, .converting, .uploading, .transcribing, .waitingForNetwork:
            phase = .queued
            errorMessage = nil
        case .queued, .needsSource, .failed:
            break
        }
    }

    mutating func prepareForRetry() {
        sessionID = nil
        nextChunkIndex = 0
        retryCount = 0
        errorMessage = nil
        localFragments = []
    }

    var progress: Double {
        guard let totalChunks, totalChunks > 0 else { return 0 }
        return min(1, Double(nextChunkIndex) / Double(totalChunks))
    }
}

struct MediaImportHistory: Identifiable, Codable, Equatable {
    let id: UUID
    let displayName: String
    let completedAt: Date
    let transcriptPath: String
    /// Present only when the user requested background English translation.
    let translatedTranscriptPath: String?
    let durationSeconds: Double?

    var transcriptURL: URL { URL(fileURLWithPath: transcriptPath) }
    var translatedTranscriptURL: URL? { translatedTranscriptPath.map(URL.init(fileURLWithPath:)) }
}
