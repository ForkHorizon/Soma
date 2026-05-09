import Foundation

import SwiftUI

import AppKit

import Combine


extension SomaViewModel {

func startSomaServer() {
        guard !selectedProjectRoot.isEmpty else { return }
        somaServerRunning = true
        somaServerBusy = false
        mcpInstallStatus = "Soma Swift MCP stdio server ready for \(selectedProjectRoot)."
        logActivity("Soma MCP Gateway marked as ready")
        refreshSomaStatus()
        startLogRefreshTimer()
    }

func stopSomaServer() {
        somaServerRunning = false
        mcpInstallStatus = "Soma MCP Gateway disabled."
        stopLogRefreshTimer()
    }

func copyMCPConfig(client: String) {
        guard !selectedProjectRoot.isEmpty else {
            mcpInstallStatus = "Select a project root before copying MCP config."
            return
        }
        Task {
            do {
                let data = try await runSomaHelper(args: ["--print-client-config", client, "--project-root", selectedProjectRoot])
                guard let config = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !config.isEmpty else {
                    throw SomaError("Empty MCP config")
                }
                await MainActor.run {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(config, forType: .string)
                    mcpConfigPreview = config
                    mcpInstallStatus = "\(client.capitalized) MCP config copied. Merge it into the client config and remove direct Nexus entries."
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Config generation failed: \(error.localizedDescription)"
                }
            }
        }
    }

func copyGeminiConfig() { copyMCPConfig(client: "gemini") }

func copyClaudeConfig() { copyMCPConfig(client: "claude") }

func verifyCodexConfig() {
        Task {
            do {
                let data = try await runSomaHelper(args: ["--verify-client-config", "codex"])
                let status = try JSONDecoder().decode(ClientConfigStatus.self, from: data)
                await MainActor.run {
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let issueText = status.issues.isEmpty ? "no issues" : status.issues.joined(separator: ", ")
                    mcpInstallStatus = "Codex config \(status.status): \(status.summary) (\(issueText))."
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Codex config verification failed: \(error.localizedDescription)"
                }
            }
        }
    }

func installCodexConfig() {
        guard !selectedProjectRoot.isEmpty else {
            mcpInstallStatus = "Select a project root before installing Codex config."
            return
        }
        Task {
            do {
                let data = try await runSomaHelper(args: ["--install-codex-config", "--project-root", selectedProjectRoot])
                let status = try JSONDecoder().decode(ClientConfigInstallStatus.self, from: data)
                await MainActor.run {
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let backupText = status.backup_path == nil ? "no previous config backup needed" : "backup: \(status.backup_path ?? "")"
                    mcpInstallStatus = "Codex config \(status.status): \(status.summary) \(backupText)."
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Codex config install failed: \(error.localizedDescription)"
                }
            }
        }
    }

func rollbackCodexConfig() {
        Task {
            do {
                let data = try await runSomaHelper(args: ["--rollback-codex-config"])
                let status = try JSONDecoder().decode(ClientConfigRollbackStatus.self, from: data)
                await MainActor.run {
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let backupText = status.backup_path ?? "no backup"
                    mcpInstallStatus = "Codex rollback \(status.status): \(status.summary) \(backupText)."
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Codex rollback failed: \(error.localizedDescription)"
                }
            }
        }
    }

func runLiveVerify() {
        guard !selectedProjectRoot.isEmpty else {
            mcpInstallStatus = "Select a project root before running live verification."
            return
        }
        Task {
            do {
                let script = try scriptURL(named: "verify_soma_live_workflow")
                let data = try await runScript(
                    path: pythonPath(),
                    args: [
                        script.path,
                        "--project-root", selectedProjectRoot,
                        "--live-unity",
                        "--run-apply",
                        "--cleanup-apply",
                    ]
                )
                let status = try JSONDecoder().decode(LiveVerifyStatus.self, from: data)
                await MainActor.run {
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    mcpInstallStatus = summarizeLiveVerify(status)
                    nexusConnected = status.nexus?.connected ?? nexusConnected
                    graphAvailable = status.graph?.project_graph_available ?? status.graph?.available ?? graphAvailable
                    graphStale = status.graph?.stale ?? graphStale
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Live verify failed: \(error.localizedDescription)"
                }
            }
        }
    }

func summarizeLiveVerify(_ status: LiveVerifyStatus) -> String {
        let tools = "\(status.tools?.count ?? 0)/\(status.tools?.expected_count ?? 12) tools"
        let unityTools = status.tools?.unity_exposed?.isEmpty == false ? "unity exposed" : "no unity tools"
        let nexus = status.nexus?.connected == true ? "nexus connected" : "nexus offline"
        let graph = status.graph?.project_graph_available == true ? ((status.graph?.stale == true) ? "graph stale" : "graph ready") : "graph missing"
        let calls = status.calls ?? [:]
        let scene = calls["soma_scene"]?.status ?? "missing"
        let inspect = calls["soma_inspect"]?.status ?? "missing"
        let apply = calls["soma_apply"]?.status ?? "missing"
        let cleanup = calls["cleanup_apply"]?.status ?? "missing"
        let issueText = (status.issues ?? []).isEmpty ? "no issues" : (status.issues ?? []).joined(separator: ", ")
        return "Live verify \(status.status): \(tools), \(unityTools), \(nexus), \(graph), scene \(scene), inspect \(inspect), apply \(apply), cleanup \(cleanup). \(issueText)."
    }

}
