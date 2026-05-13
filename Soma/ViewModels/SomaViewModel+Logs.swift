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
            let latestSavings = entries.first { $0.event == "tool_call" && $0.savings_pct != nil }.map {
                TokenSavings(
                    status: "ok",
                    primary_metric: $0.primary_metric,
                    model_profile: nil,
                    label: nil,
                    estimator: $0.token_estimator,
                    chars_per_token: nil,
                    exact_encoding: nil,
                    packet_tokens: $0.packet_tokens,
                    budget: nil,
                    budget_tokens: nil,
                    budget_used_pct: $0.budget_used_pct,
                    baseline_type: $0.baseline_type,
                    saved_tokens: $0.saved_tokens,
                    savings_pct: $0.savings_pct,
                    estimated_context_reduction: nil,
                    operation_savings: nil,
                    warnings: nil
                )
            }
            await MainActor.run {
                logEntries = entries
                toolStats = stats
                if let latestSavings {
                    self.latestTokenSavings = latestSavings
                }
                logsLoading = false
            }
        }
    }

func computeToolStats(from entries: [SomaLogEntry]) -> [SomaToolStat] {
        var map: [String: (calls: Int, errors: Int, totalDur: Double, totalTok: Int, savedTok: Int, savings: [Double], opSavedTok: Int, opSavings: [Double], estSavedTok: Int, estSavings: [Double])] = [:]
        for e in entries where e.event == "tool_call" {
            let name = e.displayName
            var s = map[name] ?? (0, 0, 0, 0, 0, [], 0, [], 0, [])
            s.calls += 1
            if e.isError { s.errors += 1 }
            s.totalDur += e.duration_ms ?? 0
            s.totalTok += e.totalTokens
            s.savedTok += e.saved_tokens ?? 0
            if let pct = e.savings_pct { s.savings.append(pct) }
            s.opSavedTok += e.operation_saved_tokens ?? 0
            if let pct = e.operation_savings_pct { s.opSavings.append(pct) }
            s.estSavedTok += e.estimated_context_saved_tokens ?? 0
            if let pct = e.estimated_context_reduction_pct { s.estSavings.append(pct) }
            map[name] = s
        }
        return map.map { (name, s) in
            SomaToolStat(
                id: name,
                calls: s.calls,
                errors: s.errors,
                avgDuration: s.calls > 0 ? s.totalDur / Double(s.calls) : 0,
                totalTokens: s.totalTok,
                totalSavedTokens: s.savedTok,
                avgSavingsPct: s.savings.isEmpty ? nil : s.savings.reduce(0, +) / Double(s.savings.count),
                totalOperationSavedTokens: s.opSavedTok,
                avgOperationSavingsPct: s.opSavings.isEmpty ? nil : s.opSavings.reduce(0, +) / Double(s.opSavings.count),
                totalEstimatedContextSavedTokens: s.estSavedTok,
                avgEstimatedContextReductionPct: s.estSavings.isEmpty ? nil : s.estSavings.reduce(0, +) / Double(s.estSavings.count)
            )
        }.sorted { $0.calls > $1.calls }
    }

}
