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

enum MediaImportError: LocalizedError {
    case ffmpegUnavailable
    case ffprobeUnavailable
    case noAudioStream
    case invalidDuration
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegUnavailable: "FFmpeg is required to import audio or video. Install it with: brew install ffmpeg"
        case .ffprobeUnavailable: "FFprobe is required to inspect media. Install it with: brew install ffmpeg"
        case .noAudioStream: "This file has no readable audio stream."
        case .invalidDuration: "Could not determine the media duration."
        case .processFailed(let message): message
        }
    }
}

enum MediaImportTools {
    /// A minute is short enough that an interactive dictation only waits for the
    /// currently-running import segment, while still amortising FFmpeg startup.
    static let chunkSeconds = 60.0
    static let overlapSeconds = 2.0

    static func ffmpegURL() -> URL? { executable(named: "ffmpeg") }
    static func ffprobeURL() -> URL? { executable(named: "ffprobe") }

    static func probeDuration(_ sourceURL: URL) async throws -> Double {
        guard let ffprobe = ffprobeURL() else { throw MediaImportError.ffprobeUnavailable }
        let audioStream = try await run(ffprobe, [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=index", "-of", "default=nokey=1:noprint_wrappers=1",
            sourceURL.path,
        ])
        guard !audioStream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaImportError.noAudioStream
        }
        let output = try await run(ffprobe, [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "format=duration", "-of", "default=nokey=1:noprint_wrappers=1",
            sourceURL.path,
        ])
        guard let duration = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)), duration > 0 else {
            throw MediaImportError.noAudioStream
        }
        return duration
    }

    static func exportChunk(sourceURL: URL, startSeconds: Double, durationSeconds: Double, to outputURL: URL) async throws {
        guard let ffmpeg = ffmpegURL() else { throw MediaImportError.ffmpegUnavailable }
        try? FileManager.default.removeItem(at: outputURL)
        _ = try await run(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-ss", String(format: "%.3f", startSeconds), "-i", sourceURL.path,
            "-map", "0:a:0", "-vn", "-t", String(format: "%.3f", durationSeconds),
            "-ac", "1", "-ar", "16000", "-c:a", "flac", outputURL.path,
        ])
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw MediaImportError.processFailed("FFmpeg did not create the audio chunk.")
        }
    }

    static func chunkStart(index: Int) -> Double {
        Double(index) * (chunkSeconds - overlapSeconds)
    }

    static func chunkCount(for duration: Double) -> Int {
        max(1, Int(ceil(max(0, duration - overlapSeconds) / (chunkSeconds - overlapSeconds))))
    }

    static func mergedText(_ text: String, with next: String) -> String {
        let left = text.split(whereSeparator: { $0.isWhitespace })
        let right = next.split(whereSeparator: { $0.isWhitespace })
        let overlap = min(left.count, right.count, 16)
        for count in stride(from: overlap, through: 1, by: -1) {
            if left.suffix(count).map(normalize) == right.prefix(count).map(normalize) {
                return (Array(left) + Array(right.dropFirst(count))).joined(separator: " ")
            }
        }
        return [text, next].filter { !$0.isEmpty }.joined(separator: " ")
    }

    nonisolated private static func normalize(_ value: Substring) -> String {
        value.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func executable(named name: String) -> URL? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: message)
                } else {
                    continuation.resume(throwing: MediaImportError.processFailed(message.isEmpty ? "FFmpeg failed with exit code \(process.terminationStatus)." : message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: MediaImportError.processFailed(error.localizedDescription))
            }
        }
    }
}
