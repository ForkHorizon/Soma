import Foundation

extension Layer1GroundTruthRunner {
    var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    var pythonPath: String {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3")
            ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
    }
}
