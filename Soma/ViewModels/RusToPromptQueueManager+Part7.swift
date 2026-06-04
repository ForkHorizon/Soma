import Combine
import Foundation

extension RusToPromptQueueManager {
    var stressScriptURL: URL {
        repoRootURL.appendingPathComponent("Scripts").appendingPathComponent("rus_to_prompt_stress.py")
    }


    func pythonPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3") {
            return "/opt/homebrew/bin/python3"
        }
        return "/usr/bin/python3"
    }


    nonisolated static func codexExecutablePath() -> String {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"].first {
            FileManager.default.fileExists(atPath: $0)
        } ?? "codex"
    }


    nonisolated static func geminiExecutablePath() -> String {
        ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", "/usr/bin/gemini"].first {
            FileManager.default.fileExists(atPath: $0)
        } ?? "gemini"
    }


    nonisolated static func searchPath(existing: String?) -> String {
        var parts = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let homeLocal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        parts.append(homeLocal)
        if let existing, !existing.isEmpty {
            parts.append(existing)
        }
        return parts.joined(separator: ":")
    }


    nonisolated static func timestampID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }


    nonisolated static let activityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
