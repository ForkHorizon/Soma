import Foundation
import SwiftUI
import AppKit
import Combine
extension SomaViewModel {
    func diagnoseGraphifyGraph() {
        guard !selectedProjectRoot.isEmpty else { return }
        graphifyBusy = true
        logActivity("Running Graphify diagnostics...")
        Task { [weak self] in
            guard let self else { return }
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
        Task { [weak self] in
            guard let self else { return }
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
        Task { [weak self] in
            guard let self else { return }
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
    func generateAndOpenGraphifyReport(args: [String], label: String) {
        guard !selectedProjectRoot.isEmpty else { return }
        graphifyBusy = true
        logActivity("Generating \(label)...")
        Task { [weak self] in
            guard let self else { return }
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
