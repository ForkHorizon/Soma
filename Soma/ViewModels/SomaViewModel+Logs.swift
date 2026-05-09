import Foundation

import SwiftUI

import AppKit

import Combine


extension SomaViewModel {

func logActivity(_ message: String, duration: Double? = nil) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        var log = "[\(timestamp)] \(message)"
        if let duration = duration {
            log += String(format: " (%.2fs)", duration)
        }
        activityLogs.append(log)
    }

func startLogRefreshTimer() {
        logRefreshTimer?.invalidate()
        logRefreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.loadStructuredLogs()
            }
        }
    }

func stopLogRefreshTimer() {
        logRefreshTimer?.invalidate()
        logRefreshTimer = nil
    }

func loadStructuredLogs(date: Date = Date()) {
        logsLoading = true
        Task {
            let dateStr = DateFormatter.somaDate.string(from: date)
            let logFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".soma/logs/soma_\(dateStr).jsonl")
            var entries: [SomaLogEntry] = []
            if let content = try? String(contentsOf: logFile, encoding: .utf8) {
                for line in content.components(separatedBy: "\n").reversed() {
                    guard !line.isEmpty,
                          let data = line.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let entry = SomaLogEntry(from: dict) else { continue }
                    entries.append(entry)
                    if entries.count >= 200 { break }
                }
            }
            let stats = computeToolStats(from: entries)
            await MainActor.run {
                logEntries = entries
                toolStats = stats
                logsLoading = false
            }
        }
    }

func computeToolStats(from entries: [SomaLogEntry]) -> [SomaToolStat] {
        var map: [String: (calls: Int, errors: Int, totalDur: Double, totalTok: Int)] = [:]
        for e in entries where e.event == "tool_call" {
            let name = e.displayName
            var s = map[name] ?? (0, 0, 0, 0)
            s.calls += 1
            if e.isError { s.errors += 1 }
            s.totalDur += e.duration_ms ?? 0
            s.totalTok += e.totalTokens
            map[name] = s
        }
        return map.map { (name, s) in
            SomaToolStat(
                id: name,
                calls: s.calls,
                errors: s.errors,
                avgDuration: s.calls > 0 ? s.totalDur / Double(s.calls) : 0,
                totalTokens: s.totalTok
            )
        }.sorted { $0.calls > $1.calls }
    }

}
