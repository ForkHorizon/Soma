import Combine
import Foundation

extension RusToPromptQueueManager {
    nonisolated func queueRunCompletionMessage(outputPath: String?) async -> String {
        guard let outputPath, !outputPath.isEmpty else { return "Completed; summary missing" }
        let summaryURL = URL(fileURLWithPath: outputPath).appendingPathComponent("summary.json")
        return await Task.detached {
            guard let data = try? Data(contentsOf: summaryURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Completed; summary missing"
            }
            let runStatus = object["run_status"] as? String
            let success = object["success"] as? Bool
            if runStatus == "failed" {
                return Self.queueRunIssueMessage(prefix: "Completed with failed summary", summary: object)
            }
            if runStatus == "completed_with_issues" || success == false {
                return Self.queueRunIssueMessage(prefix: "Completed with issues", summary: object)
            }
            return "Completed"
        }.value
    }


    nonisolated static func queueRunIssueMessage(prefix: String, summary: [String: Any]) -> String {
        guard let issueCounts = summary["issue_counts"] as? [String: Any] else { return prefix }
        let issues = issueCounts
            .compactMap { key, value -> (String, Int)? in
                let count: Int
                if let intValue = value as? Int {
                    count = intValue
                } else if let number = value as? NSNumber {
                    count = number.intValue
                } else {
                    return nil
                }
                return count > 0 ? (key.replacingOccurrences(of: "_", with: " "), count) : nil
            }
            .sorted { lhs, rhs in
                if lhs.0 == rhs.0 { return lhs.1 > rhs.1 }
                return lhs.0 < rhs.0
            }
            .prefix(3)
            .map { "\($0.0) \($0.1)" }
        return issues.isEmpty ? prefix : "\(prefix): \(issues.joined(separator: ", "))"
    }


    func consumeProcessOutput(_ text: String) {
        processOutputBuffer += text
        let parts = processOutputBuffer.components(separatedBy: .newlines)
        guard parts.count > 1 else { return }
        processOutputBuffer = parts.last ?? ""

        let linesToProcess = Array(parts.dropLast())
        let prefix = progressPrefix

        Task.detached {
            var events: [(QueueProgressEvent?, String)] = []
            let decoder = JSONDecoder()
            for line in linesToProcess {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if trimmed.hasPrefix(prefix) {
                    let payload = String(trimmed.dropFirst(prefix.count))
                    if let data = payload.data(using: .utf8),
                       let event = try? decoder.decode(QueueProgressEvent.self, from: data) {
                        events.append((event, trimmed))
                    } else {
                        events.append((nil, trimmed))
                    }
                } else {
                    events.append((nil, trimmed))
                }
            }

            let parsedEvents = events
            await MainActor.run {
                for (eventOpt, trimmed) in parsedEvents {
                    if let event = eventOpt {
                        self.currentStage = self.displayStage(for: event)
                        if let translator = event.translatorModel, let analyzer = event.analyzerModel {
                            self.currentModel = "\(translator) -> \(analyzer)"
                        } else if let translator = event.translatorModel {
                            self.currentModel = translator
                        } else if let confidenceModel = event.confidenceModel {
                            self.currentModel = confidenceModel
                        }
                        self.updateModelProgress(for: event)
                        self.appendActivity(self.activityText(for: event))
                    } else {
                        self.appendActivity(trimmed)
                    }
                }
            }
        }
    }


    nonisolated func decodeProgressEvent(from line: String) -> QueueProgressEvent? {
        guard line.hasPrefix(progressPrefix) else { return nil }
        let payload = String(line.dropFirst(progressPrefix.count))
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QueueProgressEvent.self, from: data)
    }
}
