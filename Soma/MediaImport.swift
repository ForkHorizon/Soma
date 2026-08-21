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
        let audioStream = try await run(
            ffprobe,
            [
                "-v", "error", "-select_streams", "a:0",
                "-show_entries", "stream=index", "-of", "default=nokey=1:noprint_wrappers=1",
                sourceURL.path,
            ])
        guard !audioStream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaImportError.noAudioStream
        }
        let output = try await run(
            ffprobe,
            [
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
        _ = try await run(
            ffmpeg,
            [
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

    static func planChunks(sourceURL: URL, duration: Double) async throws -> [MediaImportChunk] {
        guard let ffmpeg = ffmpegURL() else { throw MediaImportError.ffmpegUnavailable }
        let report = try await run(
            ffmpeg,
            [
                "-hide_banner", "-i", sourceURL.path,
                "-map", "0:a:0", "-af", "silencedetect=n=-40dB:d=0.65", "-f", "null", "-",
            ])
        let silenceEnds = report.split(whereSeparator: \.isNewline).compactMap { line -> Double? in
            guard let range = line.range(of: "silence_end:") else { return nil }
            return Double(line[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "|" }).first ?? "")
        }
        return planChunks(duration: duration, silenceEnds: silenceEnds)
    }

    static func planChunks(duration: Double, silenceEnds: [Double]) -> [MediaImportChunk] {
        var chunks: [MediaImportChunk] = []
        var start = 0.0
        while start < duration {
            let remaining = duration - start
            if remaining <= 70 {
                chunks.append(
                    MediaImportChunk(
                        startSeconds: start, durationSeconds: remaining, reason: VoiceChunkReason.pause.rawValue, overlapSeconds: 0))
                break
            }
            let target = start + 60
            let boundary = silenceEnds.filter { $0 >= start + 50 && $0 <= start + 70 }.min { abs($0 - target) < abs($1 - target) }
            if let boundary {
                chunks.append(
                    MediaImportChunk(
                        startSeconds: start, durationSeconds: boundary - start, reason: VoiceChunkReason.pause.rawValue, overlapSeconds: 0))
                start = boundary
            } else {
                chunks.append(
                    MediaImportChunk(
                        startSeconds: start, durationSeconds: 60, reason: VoiceChunkReason.forced.rawValue, overlapSeconds: overlapSeconds))
                start += chunkSeconds - overlapSeconds
            }
        }
        return chunks
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

    static func hasPathologicalRepetition(_ text: String, threshold: Int = 12) -> Bool {
        var punctuationRun = 0
        var previousPunctuation = ""
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = token.lowercased().filter { $0.isLetter || $0.isNumber }
            let punctuation = token.filter { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
            if word.isEmpty && !punctuation.isEmpty {
                punctuationRun = punctuation == previousPunctuation ? punctuationRun + 1 : 1
                if punctuationRun >= 8 { return true }
            } else {
                punctuationRun = 0
            }
            previousPunctuation = punctuation
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map {
            $0.lowercased().filter { $0.isLetter || $0.isNumber }
        }.filter { !$0.isEmpty }
        guard words.count >= 3 else { return false }
        for unitLength in 1...min(8, words.count / 3) {
            let minimumLength = max(threshold, unitLength * 3)
            guard words.count >= minimumLength else { continue }
            for start in 0...(words.count - minimumLength) {
                let repeats = (unitLength..<minimumLength).allSatisfy {
                    words[start + $0] == words[start + $0 % unitLength]
                }
                if repeats { return true }
            }
        }
        return false
    }

    static func removingContextPrefix(_ context: String, from text: String) -> String? {
        let contextWords = context.split(whereSeparator: { $0.isWhitespace })
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !contextWords.isEmpty, words.count > contextWords.count else { return nil }
        guard words.prefix(contextWords.count).map(normalize) == contextWords.map(normalize) else { return nil }
        return words.dropFirst(contextWords.count).joined(separator: " ")
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
                    continuation.resume(
                        throwing: MediaImportError.processFailed(
                            message.isEmpty ? "FFmpeg failed with exit code \(process.terminationStatus)." : message))
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
