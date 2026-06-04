import Foundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
extension SomaViewModel {
func loadAuditReport() {
        Task { [weak self] in guard let self else { return }
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".soma/audit/latest.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            do {
                let data = try Data(contentsOf: file)
                let report = try JSONDecoder().decode(AuditReport.self, from: data)
                await MainActor.run {
                    self.auditReport = report
                    self.auditError = nil
                }
            } catch {
                await MainActor.run {
                    self.auditError = "Audit report unreadable: \(error.localizedDescription)"
                }
            }
        }
    }
func markAudit(status: String, notes: String = "") {
        guard let runID = auditReport?.run_id else {
            auditError = "No audit run selected."
            return
        }
        auditMarkBusy = true
        auditError = nil
        Task { [weak self] in guard let self else { return }
            do {
                let script = try scriptURL(named: "soma_audit")
                let data = try await runScript(
                    path: pythonPath(),
                    args: [
                        script.path,
                        "--mark", runID,
                        "--status", status,
                        "--notes", notes,
                    ]
                )
                let report = try JSONDecoder().decode(AuditReport.self, from: data)
                await MainActor.run {
                    self.auditReport = report
                    self.auditMarkBusy = false
                    self.auditError = nil
                    self.logActivity("Audit \(runID) marked \(status)")
                }
            } catch {
                await MainActor.run {
                    self.auditMarkBusy = false
                    self.auditError = error.localizedDescription
                }
            }
        }
    }
    func runRelayScript(bundle: GatherBundle) async throws -> RelayResponse {
        let scriptPath = try scriptURL(named: "relay").path
        let pyPath = pythonPath()
        let env = scriptEnvironment()
        return try await Task.detached(priority: .userInitiated) {
            let bundleJSON = (try? String(data: JSONEncoder().encode(bundle), encoding: .utf8)) ?? "{}"
            let output = try await SomaViewModel.executeProcess(path: pyPath, args: [scriptPath, bundleJSON], environment: env)
            return try JSONDecoder().decode(RelayResponse.self, from: output)
        }.value
    }
func loadTokenBenchmarkReport() {
        Task { [weak self] in guard let self else { return }
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".soma/token_stats.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            do {
                let data = try Data(contentsOf: file)
                let report = try JSONDecoder().decode(TokenBenchmarkReport.self, from: data)
                await MainActor.run {
                    self.tokenBenchmarkReport = report
                    self.tokenBenchmarkError = nil
                }
            } catch {
                await MainActor.run {
                    self.tokenBenchmarkError = "Context benchmark report unreadable: \(error.localizedDescription)"
                }
            }
        }
    }
func loadAgentBenchmarkReport() {
        Task { [weak self] in guard let self else { return }
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".soma/agent_benchmarks/latest.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            do {
                let data = try Data(contentsOf: file)
                let report = try JSONDecoder().decode(AgentBenchmarkReport.self, from: data)
                await MainActor.run {
                    self.agentBenchmarkReport = report
                    self.agentBenchmarkError = nil
                }
            } catch {
                await MainActor.run {
                    self.agentBenchmarkError = "A/B benchmark report unreadable: \(error.localizedDescription)"
                }
            }
        }
    }
func runTokenBenchmark() {
        guard !selectedProjectRoot.isEmpty else {
            tokenBenchmarkError = "Select a project root before measuring context reduction."
            return
        }
        tokenBenchmarkBusy = true
        tokenBenchmarkError = nil
        logActivity("Measuring estimated context reduction for \((selectedProjectRoot as NSString).lastPathComponent)...")
        Task { [weak self] in guard let self else { return }
            do {
                let script = try scriptURL(named: "soma_token_benchmark")
                let data = try await runScript(
                    path: pythonPath(),
                    args: [
                        script.path,
                        "--project-root", selectedProjectRoot,
                        "--baseline", "both",
                        "--budget", "fast",
                    ]
                )
                let report = try JSONDecoder().decode(TokenBenchmarkReport.self, from: data)
                await MainActor.run {
                    self.tokenBenchmarkReport = report
                    self.tokenBenchmarkBusy = false
                    self.tokenBenchmarkError = nil
                    self.logActivity("Context benchmark \(report.status ?? "unknown"): reduced \(report.summary?.total_saved_tokens ?? 0) estimated tokens")
                }
            } catch {
                await MainActor.run {
                    self.tokenBenchmarkBusy = false
                    self.tokenBenchmarkError = error.localizedDescription
                    self.logActivity("Context benchmark failed: \(error.localizedDescription)")
                }
            }
        }
    }
func chooseAndRunAgentBenchmark() {
        guard !selectedProjectRoot.isEmpty else {
            agentBenchmarkError = "Select a project root before running an A/B benchmark."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose A/B benchmark scenario"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            runAgentBenchmark(scenarioPath: url.path)
        }
    }
func runAgentBenchmark(scenarioPath: String) {
        agentBenchmarkBusy = true
        agentBenchmarkError = nil
        logActivity("Running agent A/B benchmark from \((scenarioPath as NSString).lastPathComponent)...")
        Task { [weak self] in guard let self else { return }
            do {
                let script = try scriptURL(named: "soma_agent_ab_benchmark")
                let data = try await runScript(
                    path: pythonPath(),
                    args: [
                        script.path,
                        "--scenario", scenarioPath,
                        "--agents", "codex,gemini,hermes",
                        "--budget", "fast",
                        "--python", pythonPath(),
                    ]
                )
                let report = try JSONDecoder().decode(AgentBenchmarkReport.self, from: data)
                await MainActor.run {
                    self.agentBenchmarkReport = report
                    self.agentBenchmarkBusy = false
                    self.agentBenchmarkError = nil
                    self.logActivity("A/B benchmark \(report.status ?? "unknown"): \(report.summary?.paired_result_count ?? 0) accepted pairs")
                }
            } catch {
                await MainActor.run {
                    self.agentBenchmarkBusy = false
                    self.agentBenchmarkError = error.localizedDescription
                    self.logActivity("A/B benchmark failed: \(error.localizedDescription)")
                }
            }
        }
    }
func runSomaHelper(args: [String]) async throws -> Data {
        let scriptPath = try scriptURL(named: "soma_mcp_server").path
        return try await runScript(path: pythonPath(), args: [scriptPath] + args)
    }
nonisolated func scriptURL(named name: String) throws -> URL {
        // Prefer source directory — gateway/ package must be co-located with soma_mcp_server.py.
        // #filePath resolves to: …/Soma/Soma/ViewModels/SomaViewModel+Execution.swift
        // Two .deletingLastPathComponent() calls reach: …/Soma/Soma/
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // drop SomaViewModel+Execution.swift → ViewModels/
            .deletingLastPathComponent()   // drop ViewModels/ → Soma/ (contains gateway/)
            .appendingPathComponent("\(name).py")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        // Fallback: bundled resource (only valid when gateway/ is also bundled)
        if let bundled = Bundle.main.url(forResource: name, withExtension: "py") {
            return bundled
        }
        throw SomaError("\(name).py not found in source or bundle")
    }
}
