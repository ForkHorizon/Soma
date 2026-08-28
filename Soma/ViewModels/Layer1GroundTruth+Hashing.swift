import CryptoKit
import Foundation

extension Layer1GroundTruthStore {
    static func sha256(file: URL) -> String {
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
