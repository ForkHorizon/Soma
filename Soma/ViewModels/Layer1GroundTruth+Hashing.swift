import CryptoKit
import Foundation

extension Layer1GroundTruthStore {
    func currentAudioMatches(_ file: Layer1AudioFile) -> Bool {
        Self.audioMatches(file)
    }

    nonisolated static func audioMatches(_ file: Layer1AudioFile) -> Bool {
        guard FileManager.default.fileExists(atPath: file.url.path),
            file.audioHash != "unreadable"
        else { return false }
        return sha256(file: file.url) == file.audioHash
    }

    nonisolated static func sha256(file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "unreadable" }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1024 * 1024)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        try? handle.close()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
