import Foundation

import SwiftUI

import AppKit

import Combine


extension SomaViewModel {

func refreshSomaStatus() {
        guard !selectedProjectRoot.isEmpty else { return }
        Task {
            do {
                let data = try await runSomaHelper(args: ["--status-json", "--project-root", selectedProjectRoot])
                let status = try JSONDecoder().decode(SomaGatewayStatus.self, from: data)
                await MainActor.run {
                    nexusConnected = status.nexus?.connected ?? false
                    graphAvailable = status.graph?.project_graph_available ?? status.graph?.available ?? false
                    graphStale = status.graph?.stale ?? false
                    nexusVersion = status.nexus?.unity_version ?? "Offline"
                    
                    let nexusText = nexusConnected ? "Unity plugin connected (\(nexusVersion))" : "Unity plugin skipped/offline"
                    let graphText = graphAvailable ? (graphStale ? "graph stale" : "graph ready") : "graph missing"
                    let toolCount = status.server?.tool_count ?? 0
                    let nexusProject = status.nexus?.project_path
                    let mismatch = nexusConnected && !projectPathsMatch(selectedProjectRoot, nexusProject)
                    let projectWarning = mismatch ? " Warning: Nexus project differs from selected root (\(nexusProject ?? "unknown"))." : ""
                    mcpInstallStatus = "\(nexusText). \(graphText). Soma exposes \(toolCount) tools.\(projectWarning)"
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Soma status failed: \(error.localizedDescription)"
                }
            }
            // Refresh activity feed alongside status
            loadStructuredLogs()
            loadTokenBenchmarkReport()
            loadAgentBenchmarkReport()
        }
    }

func fetchSystemVersions() {
        Task {
            // Graphify
            do {
                let uvPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/uv"
                let data = try await runScript(path: uvPath, args: ["tool", "list"])
                if let output = String(data: data, encoding: .utf8) {
                    let pattern = "graphifyy v([0-9.]+)"
                    if let range = output.range(of: pattern, options: .regularExpression) {
                        let match = output[range]
                        let versionPattern = "[0-9.]+"
                        if let versionRange = match.range(of: versionPattern, options: .regularExpression) {
                            let version = String(match[versionRange])
                            await MainActor.run { self.graphifyVersion = version }
                        }
                    }
                }
            } catch {
                await MainActor.run { self.graphifyVersion = "Not installed" }
            }

            // Nexus (already fetched in refreshSomaStatus, but let's ensure it's mapped)
            refreshSomaStatus()
        }
    }

func upgradeGraphify() {
        systemBusy = true
        logActivity("Upgrading Graphify...")
        Task {
            do {
                let uvPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/uv"
                _ = try await runScript(path: uvPath, args: ["tool", "upgrade", "graphifyy"])
                await MainActor.run {
                    self.systemBusy = false
                    self.logActivity("Graphify upgraded successfully")
                    self.fetchSystemVersions()
                }
            } catch {
                await MainActor.run {
                    self.systemBusy = false
                    self.logActivity("Graphify upgrade failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func initializeGraphify() {
        guard !selectedProjectRoot.isEmpty else { return }
        graphifyBusy = true
        logActivity("Initializing Graphify graph for \((selectedProjectRoot as NSString).lastPathComponent)...")
        Task {
            do {
                // Look for graphify binary via uv tool or direct path
                let graphifyBin = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/graphify"
                let args = ["update", "."]
                _ = try await runScript(path: graphifyBin, args: args, workingDirectory: selectedProjectRoot)
                await MainActor.run {
                    self.graphifyBusy = false
                    self.graphAvailable = true
                    self.graphStale = false
                    self.logActivity("Graphify graph created/updated successfully")
                    self.refreshSomaStatus()
                }
            } catch {
                await MainActor.run {
                    self.graphifyBusy = false
                    self.logActivity("Graphify initialization failed: \(error.localizedDescription)")
                }
            }
        }
    }

func projectPathsMatch(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs, !lhs.isEmpty, !rhs.isEmpty else { return true }
        let left = URL(fileURLWithPath: lhs).standardizedFileURL.path
        let right = URL(fileURLWithPath: rhs).standardizedFileURL.path
        return left == right
    }

}
