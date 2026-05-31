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
                    graphBuildVersion = status.graph?.graphify_version
                    graphDegraded = status.graph?.graph_degraded ?? false
                    graphDegradedReason = status.graph?.graph_degraded_reason
                    graphDiagnosticsPath = status.graph?.diagnostics_path
                    graphSourceRoot = status.graph?.graph_source_root
                    graphScope = status.graph?.graph_scope ?? "project_root"
                    if let version = status.graph?.tool_version, !version.isEmpty {
                        graphifyVersion = version
                    } else if let version = status.graph?.graphify_version, !version.isEmpty {
                        graphifyVersion = version
                    }
                    nexusVersion = status.nexus?.unity_version ?? "Offline"
                    
                    let nexusText = nexusConnected ? "Unity plugin connected (\(nexusVersion))" : "Unity plugin skipped/offline"
                    let graphText = graphAvailable ? "\(graphStorageKind) graph \(graphDegraded ? "degraded" : (graphStale ? "stale" : "ready"))" : "graph optional/missing"
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

    func refreshManagedGraphifyGraph(fullRebuild: Bool = false) {
        guard !selectedProjectRoot.isEmpty else { return }
        graphifyBusy = true
        let label = fullRebuild ? "Rebuilding managed Graphify graph" : "Refreshing managed Graphify graph"
        logActivity("\(label) for \((selectedProjectRoot as NSString).lastPathComponent)...")
        Task {
            do {
                var args = ["--refresh-managed-graph", "--project-root", selectedProjectRoot]
                if fullRebuild { args.append("--full-graph-rebuild") }
                let data = try await runSomaHelper(args: args)
                let result = try JSONDecoder().decode(GraphMaintenanceResult.self, from: data)
                await MainActor.run {
                    self.graphifyBusy = false
                    self.logActivity(result.summary ?? "Managed Graphify graph refreshed")
                    if let warnings = result.warnings, !warnings.isEmpty {
                        self.logActivity("Graphify warnings: \(warnings.joined(separator: "; "))")
                    }
                    self.refreshSomaStatus()
                }
            } catch {
                await MainActor.run {
                    self.graphifyBusy = false
                    self.logActivity("Managed Graphify refresh failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func refreshAllManagedGraphifyGraphs() {
        systemBusy = true
        logActivity("Refreshing all indexed managed Graphify graphs...")
        Task {
            do {
                let data = try await runSomaHelper(args: ["--refresh-all-managed-graphs"])
                let result = try JSONDecoder().decode(GraphMaintenanceResult.self, from: data)
                await MainActor.run {
                    self.systemBusy = false
                    self.logActivity("Graphify refresh all: \(result.refreshed ?? 0) refreshed, \(result.skipped ?? 0) skipped, \(result.failed ?? 0) failed")
                    self.refreshSomaStatus()
                }
            } catch {
                await MainActor.run {
                    self.systemBusy = false
                    self.logActivity("Graphify refresh all failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func checkGraphifyToolVersion() {
        systemBusy = true
        logActivity("Checking Graphify tool version...")
        Task {
            do {
                let data = try await runSomaHelper(args: ["--check-graphify-tool-json"])
                let status = try JSONDecoder().decode(GraphifyToolStatus.self, from: data)
                await MainActor.run {
                    self.systemBusy = false
                    if let installed = status.installed_version {
                        self.graphifyVersion = installed
                    }
                    self.graphToolLatestVersion = status.latest_version
                    self.graphToolUpToDate = status.up_to_date
                    let latest = status.latest_version ?? "unknown latest"
                    let state = status.up_to_date == false ? "update available" : "current"
                    self.logActivity("Graphify \(status.installed_version ?? "not installed") / \(latest): \(state)")
                }
            } catch {
                await MainActor.run {
                    self.systemBusy = false
                    self.logActivity("Graphify version check failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func diagnoseGraphifyGraph() {
        guard !selectedProjectRoot.isEmpty else { return }
        graphifyBusy = true
        logActivity("Running Graphify diagnostics...")
        Task {
            do {
                let data = try await runSomaHelper(args: ["--diagnose-graph-json", "--project-root", selectedProjectRoot])
                let result = try JSONDecoder().decode(GraphMaintenanceResult.self, from: data)
                await MainActor.run {
                    self.graphifyBusy = false
                    self.logActivity(result.summary ?? "Graphify diagnostics completed")
                    self.refreshSomaStatus()
                }
            } catch {
                await MainActor.run {
                    self.graphifyBusy = false
                    self.logActivity("Graphify diagnostics failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func checkGraphifySemanticUpdate() {
        guard !selectedProjectRoot.isEmpty else { return }
        graphifyBusy = true
        logActivity("Checking Graphify semantic refresh state...")
        Task {
            do {
                let data = try await runSomaHelper(args: ["--check-graph-semantic-update-json", "--project-root", selectedProjectRoot])
                let result = try JSONDecoder().decode(GraphSemanticUpdateStatus.self, from: data)
                await MainActor.run {
                    self.graphifyBusy = false
                    self.graphSemanticRefreshPending = result.pending
                    self.logActivity(result.summary ?? "Graphify semantic update check completed")
                }
            } catch {
                await MainActor.run {
                    self.graphifyBusy = false
                    self.logActivity("Graphify semantic update check failed: \(error.localizedDescription)")
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

    func openGraphifyTreeReport() {
        generateAndOpenGraphifyReport(args: ["--graph-tree-json", "--project-root", selectedProjectRoot], label: "Graph tree")
    }

    func openGraphifyCallflowReport() {
        generateAndOpenGraphifyReport(args: ["--graph-callflow-json", "--project-root", selectedProjectRoot], label: "Graph callflow")
    }

    private func generateAndOpenGraphifyReport(args: [String], label: String) {
        guard !selectedProjectRoot.isEmpty else { return }
        graphifyBusy = true
        logActivity("Generating \(label)...")
        Task {
            do {
                let data = try await runSomaHelper(args: args)
                let result = try JSONDecoder().decode(GraphReportResult.self, from: data)
                await MainActor.run {
                    self.graphifyBusy = false
                    guard result.status == "ok", let outputPath = result.output_path, !outputPath.isEmpty else {
                        self.logActivity("\(label) failed: \(result.summary ?? "unknown error")")
                        return
                    }
                    self.logActivity("\(label) generated")
                    NSWorkspace.shared.open(URL(fileURLWithPath: outputPath))
                }
            } catch {
                await MainActor.run {
                    self.graphifyBusy = false
                    self.logActivity("\(label) failed: \(error.localizedDescription)")
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
