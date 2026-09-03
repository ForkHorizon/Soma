import Foundation

extension MediaImportTools {
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

    static func executable(named name: String) -> URL? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
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
