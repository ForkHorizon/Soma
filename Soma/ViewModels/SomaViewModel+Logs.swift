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
        Task { [weak self] in guard let self else { return }
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
            let localStats = computeLocalModelStats(from: entries)
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
                self.logEntries = entries
                self.toolStats = stats
                self.localModelStats = localStats
                if let latestSavings {
                    self.latestTokenSavings = latestSavings
                }
                self.logsLoading = false
                self.refreshPacketLiveToolCounts()
            }
        }
    }
func clearAllLogs() {
        logsClearBusy = true
        Task { [weak self] in guard let self else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let logsDir = home.appendingPathComponent(".soma/logs")
            let analyticsDir = home.appendingPathComponent(".soma/analytics")
            let tokenStatsDir = home.appendingPathComponent(".soma/token_stats")
            let pathsToRemove = [
                logsDir.appendingPathComponent("session_stats.json"),
                home.appendingPathComponent(".soma/token_stats.json")
            ]
            let manager = FileManager.default
            if let files = try? manager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "jsonl" || file.lastPathComponent == "session_stats.json" {
                    try? manager.removeItem(at: file)
                }
            }
            if let files = try? manager.contentsOfDirectory(at: analyticsDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "json" {
                    try? manager.removeItem(at: file)
                }
            }
            if let files = try? manager.contentsOfDirectory(at: tokenStatsDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "json" {
                    try? manager.removeItem(at: file)
                }
            }
            for path in pathsToRemove {
                try? manager.removeItem(at: path)
            }
            await MainActor.run {
                self.logEntries = []
                self.toolStats = []
                self.localModelStats = []
                self.latestTokenSavings = nil
                self.tokenBenchmarkReport = nil
                self.tokenBenchmarkError = nil
                self.logsClearBusy = false
                self.logsLoading = false
                self.logActivity("Deleted all Soma logs and analytics")
            }
        }
    }
func deleteTodayLogs(date: Date = Date()) {
        logsClearBusy = true
        Task { [weak self] in guard let self else { return }
            let file = Self.logFileURL(for: date)
            try? FileManager.default.removeItem(at: file)
            await MainActor.run {
                self.logEntries = []
                self.toolStats = []
                self.localModelStats = []
                self.logsClearBusy = false
                self.logsLoading = false
                self.logActivity("Deleted today's Soma activity logs")
            }
        }
    }
func deleteVisibleLogs(_ entries: [SomaLogEntry], date: Date = Date()) {
        guard !entries.isEmpty else { return }
        logsClearBusy = true
        Task { [weak self] in guard let self else { return }
            await rewriteLogFile(date: date, deleting: Set(entries.map(Self.logSignature)))
            let remaining = self.logEntries.filter { !Set(entries.map(Self.logSignature)).contains(Self.logSignature($0)) }
            let stats = computeToolStats(from: remaining)
            let localStats = computeLocalModelStats(from: remaining)
            await MainActor.run {
                self.logEntries = remaining
                self.toolStats = stats
                self.localModelStats = localStats
                self.logsClearBusy = false
                self.logsLoading = false
                self.logActivity("Cleared visible filtered activity logs")
            }
        }
    }
func deleteRunLogs(runID: String, date: Date = Date()) {
        logsClearBusy = true
        Task { [weak self] in guard let self else { return }
            let signatures = Set(self.logEntries.filter { $0.run_id == runID }.map(Self.logSignature))
            await rewriteLogFile(date: date, deleting: signatures)
            let remaining = self.logEntries.filter { $0.run_id != runID }
            let stats = computeToolStats(from: remaining)
            let localStats = computeLocalModelStats(from: remaining)
            await MainActor.run {
                self.logEntries = remaining
                self.toolStats = stats
                self.localModelStats = localStats
                self.logsClearBusy = false
                self.logsLoading = false
                self.logActivity("Deleted activity for run \(runID)")
            }
        }
    }
func resetAuditTraces() {
        logsClearBusy = true
        Task { [weak self] in guard let self else { return }
            let auditDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".soma/audit")
            if let files = try? FileManager.default.contentsOfDirectory(at: auditDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "json" || file.pathExtension == "jsonl" {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            try? FileManager.default.removeItem(at: auditDir.appendingPathComponent("runs"))
            try? FileManager.default.removeItem(at: auditDir.appendingPathComponent("raw"))
            await MainActor.run {
                self.auditReport = nil
                self.auditError = nil
                self.logsClearBusy = false
                self.logActivity("Reset Soma audit traces")
            }
        }
    }
func startNewLogSession() {
        logsClearBusy = true
        Task { [weak self] in guard let self else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser
            try? FileManager.default.removeItem(at: home.appendingPathComponent(".soma/logs/session_stats.json"))
            await MainActor.run {
                self.logEntries = []
                self.toolStats = []
                self.localModelStats = []
                self.logsClearBusy = false
                self.logsLoading = false
                self.logActivity("Started a new clean activity session")
            }
        }
    }
    private static func logFileURL(for date: Date) -> URL {
        let dateStr = DateFormatter.somaDate.string(from: date)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".soma/logs/soma_\(dateStr).jsonl")
    }
    private nonisolated static func logSignature(_ entry: SomaLogEntry) -> String {
        [entry.ts, entry.event, entry.tool ?? "", entry.method ?? "", entry.run_id ?? "", entry.task_id ?? "", entry.status].joined(separator: "|")
    }
    private func rewriteLogFile(date: Date, deleting signatures: Set<String>) async {
        let file = Self.logFileURL(for: date)
        guard !signatures.isEmpty,
              let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let keptLines = content.components(separatedBy: "\n").filter { line in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = SomaLogEntry(from: dict) else { return true }
            return !signatures.contains(Self.logSignature(entry))
        }
        try? keptLines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
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
func computeLocalModelStats(from entries: [SomaLogEntry]) -> [SomaLocalModelStat] {
        var map: [String: (calls: Int, errors: Int, totalDur: Double, totalTok: Int, stages: [String: Int])] = [:]
        for e in entries where e.event == "local_model_call" {
            let model = e.local_model ?? "unknown"
            let stage = e.local_model_stage ?? "unknown"
            var s = map[model] ?? (0, 0, 0, 0, [:])
            s.calls += 1
            if e.isError { s.errors += 1 }
            s.totalDur += e.duration_ms ?? 0
            s.totalTok += e.totalTokens
            s.stages[stage, default: 0] += 1
            map[model] = s
        }
        return map.map { (model, s) in
            SomaLocalModelStat(
                id: model,
                calls: s.calls,
                errors: s.errors,
                avgDuration: s.calls > 0 ? s.totalDur / Double(s.calls) : 0,
                totalTokens: s.totalTok,
                stages: s.stages,
                models: [model: s.calls]
            )
        }.sorted { $0.calls > $1.calls }
    }
}
