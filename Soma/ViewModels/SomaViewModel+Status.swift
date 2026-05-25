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
                    graphManagedAvailable = status.graph?.managed_available ?? false
                    graphLegacyAvailable = status.graph?.legacy_available ?? false
                    graphStorageKind = status.graph?.storage_kind ?? (graphAvailable ? "legacy" : "missing")
                    graphNodeCount = status.graph?.node_count
                    graphEdgeCount = status.graph?.edge_count
                    graphStoragePath = status.graph?.storage_path
                    graphManagedPath = status.graph?.managed_path
                    graphLegacyPaths = status.graph?.legacy_paths ?? []
                    if let version = status.graph?.graphify_version, !version.isEmpty {
                        graphifyVersion = version
                    }
                    nexusVersion = status.nexus?.unity_version ?? "Offline"
                    
                    let nexusText = nexusConnected ? "Unity plugin connected (\(nexusVersion))" : "Unity plugin skipped/offline"
                    let graphText = graphAvailable ? "\(graphStorageKind) graph \(graphStale ? "stale" : "ready")" : "graph optional/missing"
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
            loadMCPSmokeReport()
            verifyClientConfigs()
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
                let graphifyBin = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/graphify"
                for platform in ["claude", "codex", "agents", "gemini", "hermes"] {
                    _ = try? await runScript(path: graphifyBin, args: ["install", "--platform", platform])
                }
                await MainActor.run {
                    self.systemBusy = false
                    self.logActivity("Graphify upgraded and client integrations refreshed")
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
        logActivity("Building managed Graphify graph for \((selectedProjectRoot as NSString).lastPathComponent)...")
        Task {
            do {
                let storageData = try await runSomaHelper(args: ["--graph-storage-json", "--project-root", selectedProjectRoot])
                let storage = try JSONDecoder().decode(GraphStorageInfo.self, from: storageData)
                guard let outputRoot = storage.output_root, !outputRoot.isEmpty else {
                    throw SomaError("Graphify storage path was not returned by Soma helper")
                }
                let graphifyBin = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/graphify"
                let args = ["extract", selectedProjectRoot, "--out", outputRoot]
                _ = try await runScript(path: graphifyBin, args: args, workingDirectory: selectedProjectRoot)
                await MainActor.run {
                    self.graphifyBusy = false
                    self.graphAvailable = true
                    self.graphManagedAvailable = true
                    self.graphStorageKind = "managed"
                    self.graphStale = false
                    self.logActivity("Managed Graphify graph created/updated successfully")
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

    func migrateGraphifyGraph() {
        guard !selectedProjectRoot.isEmpty else { return }
        graphifyBusy = true
        logActivity("Moving legacy Graphify graph into Soma storage...")
        Task {
            do {
                _ = try await runSomaHelper(args: ["--migrate-graph", "--project-root", selectedProjectRoot])
                await MainActor.run {
                    self.graphifyBusy = false
                    self.logActivity("Legacy Graphify graph copied into Soma storage")
                    self.refreshSomaStatus()
                }
            } catch {
                await MainActor.run {
                    self.graphifyBusy = false
                    self.logActivity("Graphify migration failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func openGraphifyReport() {
        let basePath = graphStoragePath ?? graphManagedPath
        guard let basePath, !basePath.isEmpty else { return }
        let reportPath = (basePath as NSString).appendingPathComponent("GRAPH_REPORT.md")
        let htmlPath = (basePath as NSString).appendingPathComponent("graph.html")
        let target = FileManager.default.fileExists(atPath: htmlPath) ? htmlPath : reportPath
        guard FileManager.default.fileExists(atPath: target) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: target))
    }

func projectPathsMatch(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs, !lhs.isEmpty, !rhs.isEmpty else { return true }
        let left = URL(fileURLWithPath: lhs).standardizedFileURL.path
        let right = URL(fileURLWithPath: rhs).standardizedFileURL.path
        return left == right
    }

}
