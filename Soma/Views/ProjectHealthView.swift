import SwiftUI

struct ProjectHealthView: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager

    var body: some View {
        SomaPage {
            WorkflowHeader(
                title: "Project Health",
                subtitle: "Project-scoped readiness, setup recommendations, and Graph/Graphify state. This supports Prepare Packet without becoming the main workflow.",
                icon: "waveform.path.ecg",
                tone: overallTone,
                trailing: AnyView(refreshButton)
            )

            SomaSplitWorkbench {
                healthSummaryPanel
                graphPanel
                recommendationsPanel
            } secondary: {
                contextFilesPanel
                usagePanel
                futureGraphConfigPanel
            }
        }
        .onAppear {
            viewModel.refreshSomaStatus()
            viewModel.loadStructuredLogs()
            viewModel.loadAuditReport()
        }
    }

    private var refreshButton: some View {
        Button {
            viewModel.refreshSomaStatus()
            viewModel.loadStructuredLogs()
            viewModel.loadAuditReport()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(viewModel.selectedProjectRoot.isEmpty)
    }

    private var healthSummaryPanel: some View {
        SomaPanel(title: "Readiness Summary", subtitle: "First visible layer: clear recommendations, not raw diagnostics.", icon: "gauge.with.dots.needle.67percent", tone: overallTone) {
            StatusBanner(title: readinessTitle, detail: readinessDetail, tone: overallTone)
            StepChecklist(steps: readinessSteps)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                MetricTile(title: "Project", value: projectName, detail: projectPathDetail, tone: viewModel.selectedProjectRoot.isEmpty ? .warning : .good)
                MetricTile(title: "Context", value: contextSummary, detail: "SOMA/profile/agents", tone: hasContext ? .good : .warning)
                MetricTile(title: "Graph", value: graphSummary, detail: graphDetail, tone: graphTone)
                MetricTile(title: "Project size", value: projectSizeSummary, detail: "approx file count", tone: viewModel.selectedProjectRoot.isEmpty ? .neutral : .info)
                MetricTile(title: "Packet runs", value: "\(recentPacketRunCount)", detail: "recent prepared packets", tone: recentPacketRunCount > 0 ? .info : .neutral)
                MetricTile(title: "Warnings", value: "\(recurringWarningCount)", detail: "missing/degraded evidence", tone: recurringWarningCount > 0 ? .warning : .good)
            }
        }
    }

    private var graphPanel: some View {
        SomaPanel(title: "Graph / Graphify", subtitle: "Graph is project configuration, not just a hidden status chip.", icon: "point.3.connected.trianglepath.dotted", tone: graphTone) {
            SomaKeyValueRow(label: "Status", value: graphSummary, tone: graphTone)
            SomaKeyValueRow(label: "Freshness", value: viewModel.graphAvailable ? (viewModel.graphStale ? "Needs update" : "Fresh") : "Not built", tone: graphTone)
            SomaKeyValueRow(label: "Project type", value: projectTypeGuess, tone: .neutral)
            SomaKeyValueRow(label: "Storage", value: graphStorageLabel, tone: graphStorageExists ? .good : .neutral)
            SomaKeyValueRow(label: "Contributes to Prepare Packet", value: graphContributionLabel, tone: graphTone)
            SomaKeyValueRow(label: "Recommended action", value: graphRecommendation, tone: graphTone)
            HStack(spacing: 8) {
                Button {
                    viewModel.initializeGraphify()
                } label: {
                    if viewModel.graphifyBusy {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working") }
                    } else {
                        Label(viewModel.graphAvailable ? "Update Graph" : "Build Graph", systemImage: "bolt.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.selectedProjectRoot.isEmpty || viewModel.graphifyBusy || viewModel.systemBusy)

                Button {
                    viewModel.upgradeGraphify()
                } label: {
                    Label("Check Graphify Update", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.systemBusy || viewModel.graphifyBusy)
            }
        }
    }

    private var recommendationsPanel: some View {
        SomaPanel(title: "Recommendations", subtitle: "Setup advice for the selected workspace.", icon: "lightbulb", tone: recommendations.isEmpty ? .good : .warning) {
            if recommendations.isEmpty {
                StatusBanner(title: "No immediate setup recommendation", detail: "The selected project has enough visible context for packet preparation. Detailed graph and agent setup can still be improved later.", tone: .good)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(recommendations, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(item)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var contextFilesPanel: some View {
        SomaPanel(title: "Context Files", subtitle: "Project-local files Soma can detect today.", icon: "doc.text.magnifyingglass", tone: hasContext ? .good : .warning) {
            fileRow("SOMA.md", required: true)
            fileRow("AGENTS.md", required: false)
            fileRow("GEMINI.md", required: false)
            fileRow(".soma/project.json", required: false)
            Text("Setup Context is intentionally project-local: these files live in the selected folder. App-wide model and server settings remain defaults/fallbacks.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usagePanel: some View {
        SomaPanel(title: "Project Usage", subtitle: "Near-version analytics from currently loaded logs.", icon: "chart.bar.doc.horizontal", tone: .neutral) {
            SomaKeyValueRow(label: "Workspace opens", value: "\(viewModel.projectUsageCount(viewModel.selectedProjectRoot))", tone: viewModel.selectedProjectRoot.isEmpty ? .neutral : .info)
            SomaKeyValueRow(label: "Last used", value: viewModel.projectLastUsedLabel(viewModel.selectedProjectRoot), tone: viewModel.selectedProjectRoot.isEmpty ? .neutral : .info)
            SomaKeyValueRow(label: "Recent packet/tool entries", value: "\(viewModel.logEntries.count)", tone: viewModel.logEntries.isEmpty ? .neutral : .info)
            SomaKeyValueRow(label: "Latest audit", value: viewModel.auditReport?.run_id.map { String($0.prefix(12)) } ?? "No audit loaded", tone: viewModel.auditReport == nil ? .neutral : .info)
            SomaKeyValueRow(label: "Evidence selected", value: "\(viewModel.auditReport?.selected_evidence?.count ?? 0)", tone: (viewModel.auditReport?.selected_evidence?.isEmpty == false) ? .good : .neutral)
            SomaKeyValueRow(label: "Local AI", value: ollama.isOllamaRunning ? "Available" : "Offline", tone: ollama.isOllamaRunning ? .good : .neutral)
        }
    }

    private var futureGraphConfigPanel: some View {
        SomaPanel(title: "Graph Config Later", subtitle: "Documented but intentionally not overbuilt in the near version.", icon: "slider.horizontal.3", tone: .neutral) {
            StepChecklist(steps: [
                WorkflowStep(id: "enable", title: "Enable graph per project", detail: viewModel.graphAvailable ? "Detected from graphify-out today; explicit enable/disable arrives later." : "No graph detected; build/update remains the available near-version control.", tone: viewModel.graphAvailable ? .good : .neutral),
                WorkflowStep(id: "preset", title: "Project type preset", detail: "Currently inferred as \(projectTypeGuess). Manual presets are later scope.", tone: .neutral),
                WorkflowStep(id: "paths", title: "Include/ignore paths", detail: "Future config: important paths, ignored paths, generated files exclusion, filters, and max file size.", tone: .neutral),
                WorkflowStep(id: "storage", title: "Storage location", detail: graphStorageExists ? "Using graphify-out in the selected project." : "Will use graphify-out after the graph is built.", tone: graphStorageExists ? .good : .neutral),
            ])
            Text("These controls are placeholders only; near-version Project Health should clarify graph status without redesigning Graphify backend/config.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fileRow(_ path: String, required: Bool) -> some View {
        let exists = fileExists(path)
        return SomaKeyValueRow(label: path, value: exists ? "Found" : (required ? "Missing" : "Optional"), tone: exists ? .good : (required ? .warning : .neutral))
    }

    private var recommendations: [String] {
        var items: [String] = []
        if viewModel.selectedProjectRoot.isEmpty {
            items.append("Choose a project folder before running Prepare Packet.")
            return items
        }
        items.append(contentsOf: viewModel.projectSetupRecommendations(for: viewModel.selectedProjectRoot))
        if !viewModel.graphAvailable { items.append("Build a project graph when graph context would improve packet quality.") }
        if viewModel.graphAvailable && viewModel.graphStale { items.append("Update Graphify because the current graph may be stale.") }
        if viewModel.logEntries.isEmpty { items.append("Run Prepare Packet once to populate project activity and audit details.") }
        return items
    }

    private var overallTone: SomaStatusTone {
        if viewModel.selectedProjectRoot.isEmpty { return .warning }
        if !hasContext || (viewModel.graphAvailable && viewModel.graphStale) { return .warning }
        return .good
    }
    private var readinessTitle: String {
        if viewModel.selectedProjectRoot.isEmpty { return "No project selected" }
        if !hasContext { return "Needs setup" }
        if viewModel.graphAvailable && viewModel.graphStale { return "Needs attention" }
        return "Ready"
    }
    private var readinessDetail: String {
        if viewModel.selectedProjectRoot.isEmpty { return "Open a workspace to evaluate project-local context, graph state, and activity." }
        if !hasContext { return "Project opened, but no SOMA.md/AGENTS.md/GEMINI.md/.soma/project.json was detected." }
        return "Project context is visible. Prepare Packet can use this workspace; optional graph and activity details are below."
    }
    private var projectName: String { viewModel.selectedProjectRoot.isEmpty ? "None" : (viewModel.selectedProjectRoot as NSString).lastPathComponent }
    private var projectPathDetail: String { viewModel.selectedProjectRoot.isEmpty ? "choose folder" : "active workspace" }
    private var hasContext: Bool { fileExists("SOMA.md") || fileExists("AGENTS.md") || fileExists("GEMINI.md") || fileExists(".soma/project.json") }
    private var contextSummary: String { hasContext ? "Loaded" : "Missing" }
    private var graphSummary: String { viewModel.graphAvailable ? (viewModel.graphStale ? "Stale" : "Fresh") : "None" }
    private var graphTone: SomaStatusTone { viewModel.graphAvailable ? (viewModel.graphStale ? .warning : .good) : .neutral }
    private var graphDetail: String { viewModel.graphAvailable ? "project graph exists" : "optional" }
    private var graphStorageLabel: String { graphStorageExists ? "graphify-out" : "Not found" }
    private var graphStorageExists: Bool { fileExists("graphify-out/graph.json") || fileExists("graphify-out/GRAPH_REPORT.md") }
    private var projectSizeSummary: String { viewModel.approximateProjectFileCountLabel(for: viewModel.selectedProjectRoot) }
    private var recentPacketRunCount: Int {
        viewModel.logEntries.filter { entry in
            entry.event == "tool_call" && (entry.tool == "soma_prepare_context" || entry.displayName.contains("prepare") || entry.displayName.contains("relay"))
        }.count
    }
    private var recurringWarningCount: Int {
        let degradedLogCount = viewModel.logEntries.filter { $0.isDegraded || $0.isError || ($0.error?.isEmpty == false) }.count
        let auditWarnings = viewModel.auditReport?.missing_evidence?.quality_warnings?.count ?? 0
        let unresolved = (viewModel.auditReport?.missing_evidence?.unresolved_references?.count ?? 0) + (viewModel.auditReport?.missing_evidence?.missing_files?.count ?? 0)
        return degradedLogCount + auditWarnings + unresolved
    }
    private var graphContributionLabel: String {
        if viewModel.graphAvailable && !viewModel.graphStale { return "Used as optional context" }
        if viewModel.graphAvailable && viewModel.graphStale { return "Available but should be updated" }
        return "Not used until built"
    }
    private var graphRecommendation: String {
        if viewModel.selectedProjectRoot.isEmpty { return "Choose a project first" }
        if viewModel.graphAvailable && viewModel.graphStale { return "Update graph before graph-heavy packets" }
        if viewModel.graphAvailable { return "No graph action needed" }
        return "Build graph when codebase structure matters"
    }

    private var readinessSteps: [WorkflowStep] {
        [
            WorkflowStep(id: "context", title: hasContext ? "Context file loaded" : "Context file missing", detail: hasContext ? contextSummaryDetail : "Add SOMA.md or an agent context file for stronger packets.", tone: hasContext ? .good : .warning),
            WorkflowStep(id: "graph", title: "Graph \(graphSummary.lowercased())", detail: graphRecommendation, tone: graphTone),
            WorkflowStep(id: "packets", title: "\(recentPacketRunCount) recent packet run\(recentPacketRunCount == 1 ? "" : "s")", detail: recentPacketRunCount > 0 ? "Activity exists for this workspace." : "Run Prepare Packet once to create recent activity.", tone: recentPacketRunCount > 0 ? .info : .neutral),
            WorkflowStep(id: "warnings", title: "\(recurringWarningCount) recurring warning\(recurringWarningCount == 1 ? "" : "s")", detail: recurringWarningCount > 0 ? "Review missing/degraded evidence in diagnostics." : "No loaded missing-evidence warnings.", tone: recurringWarningCount > 0 ? .warning : .good),
        ]
    }

    private var contextSummaryDetail: String {
        ["SOMA.md", "AGENTS.md", "GEMINI.md", ".soma/project.json"]
            .filter { fileExists($0) }
            .joined(separator: ", ")
    }

    private var projectTypeGuess: String {
        if fileExists("Package.swift") { return "Swift" }
        if fileExists("Assets") && fileExists("ProjectSettings") { return "Unity" }
        if fileExists("package.json") { return "Web/Node" }
        if fileExists("pyproject.toml") { return "Python" }
        return "Unknown"
    }

    private func fileExists(_ relativePath: String) -> Bool {
        viewModel.projectFileExists(relativePath, in: viewModel.selectedProjectRoot)
    }
}
