import SwiftUI

// MARK: - System Status (MCP Gateway Dashboard)

struct SystemStatusView: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @State private var auditNotes = ""

    var body: some View {
        SomaPage {
            dashboardHeader
            attentionDashboard
            observerSummary
            SomaSplitWorkbench {
                projectHealthCard
                mcpReadinessCard
                tokenSavingsCard
                agentBenchmarkCard
            } secondary: {
                runtimeSnapshotPanel
                auditTraceCard
            }
            gatewayGrid
            componentSection
            Spacer(minLength: 40)
        }
        .onAppear {
            viewModel.fetchSystemVersions()
            viewModel.loadAuditReport()
        }
    }

    // MARK: - Dashboard Header

    private var dashboardHeader: some View {
        WorkflowHeader(
            title: "System Status",
            subtitle: "Attention-first observer view for project readiness, live MCP clients, optional graph context, local AI, and audit traces.",
            icon: "checklist.checked",
            tone: overallTone,
            trailing: AnyView(overallStatusBadge)
        )
    }

    private var overallTone: SomaStatusTone {
        if viewModel.selectedProjectRoot.isEmpty { return .warning }
        return viewModel.somaServerRunning ? .good : .info
    }

    private var attentionDashboard: some View {
        SomaPanel(title: "Needs Attention", subtitle: "Start here before reading dense diagnostics.", icon: "exclamationmark.triangle.fill", tone: attentionTone) {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.selectedProjectRoot.isEmpty {
                    StatusBanner(title: "No project selected", detail: "Choose a project in the top bar to unlock readiness checks, graph state, and audit traces.", tone: .warning)
                }
                if !viewModel.somaServerRunning {
                    StatusBanner(title: "MCP gateway is offline", detail: "Prepare Packet still works. Start MCP only when external clients need live Soma tools.", tone: viewModel.selectedProjectRoot.isEmpty ? .warning : .info)
                }
                if viewModel.graphAvailable && viewModel.graphStale {
                    StatusBanner(title: "Graph may be stale", detail: "Update Graphify before graph-heavy prompts if the project changed recently.", tone: .warning)
                }
                if viewModel.selectedProjectRoot.isEmpty == false && viewModel.somaServerRunning && !(viewModel.graphAvailable && viewModel.graphStale) {
                    StatusBanner(title: "No immediate action", detail: "Runtime checks look usable. Detailed diagnostics remain available below.", tone: .good)
                }
            }
        }
    }

    private var attentionTone: SomaStatusTone {
        if viewModel.selectedProjectRoot.isEmpty { return .warning }
        if viewModel.graphAvailable && viewModel.graphStale { return .warning }
        return viewModel.somaServerRunning ? .good : .info
    }

    private var runtimeSnapshotPanel: some View {
        SomaPanel(title: "Runtime Snapshot", subtitle: "Compact state mirrored from the top bar.", icon: "gauge.with.dots.needle.67percent", tone: overallTone) {
            SomaKeyValueRow(label: "Project", value: viewModel.selectedProjectRoot.isEmpty ? "Not selected" : (viewModel.selectedProjectRoot as NSString).lastPathComponent, tone: viewModel.selectedProjectRoot.isEmpty ? .warning : .info)
            SomaKeyValueRow(label: "MCP", value: viewModel.somaServerRunning ? "Online" : "Offline", tone: viewModel.somaServerRunning ? .good : .danger)
            SomaKeyValueRow(label: "Scout", value: ollama.modelName, tone: ollama.isModelLoaded ? .good : .warning)
            SomaKeyValueRow(label: "Ranker", value: ollama.rankerModelName, tone: .info)
            SomaKeyValueRow(label: "Analyst", value: ollama.analystModelName, tone: .info)
            SomaKeyValueRow(label: "Graph", value: viewModel.graphAvailable ? (viewModel.graphStale ? "Stale" : "Fresh") : "Optional", tone: viewModel.graphAvailable ? (viewModel.graphStale ? .warning : .good) : .neutral)
        }
    }

    private var overallStatusBadge: some View {
        let allOk = viewModel.somaServerRunning && !viewModel.selectedProjectRoot.isEmpty
        let label = allOk ? "Ready" : viewModel.somaServerRunning ? "Select Project" : "Offline"
        let color: Color = allOk ? .green : viewModel.somaServerRunning ? .orange : .red

        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
                .shadow(color: color.opacity(0.6), radius: 4)
            Text(label).font(.subheadline.bold())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(color.opacity(0.3)))
    }

    private var observerSummary: some View {
        let hasProject = !viewModel.selectedProjectRoot.isEmpty
        let allOk = hasProject && viewModel.somaServerRunning
        let title = allOk ? "Runtime looks ready" : hasProject ? "Project selected, gateway optional" : "Choose a project to unlock checks"
        let baseDetail = allOk
            ? "Live MCP checks and packet-mode diagnostics can run against the selected project."
            : hasProject
                ? "Packet mode can still run. Start MCP only when external clients need live Soma tools."
                : "Most status cards depend on a project root so Soma can validate configs, graph state, and traces."
        let detail = baseDetail + " Local AI roles: Scout \(ollama.modelName), Ranker \(ollama.rankerModelName), Analyst \(ollama.analystModelName)."
        return StatusBanner(
            title: title,
            detail: detail,
            tone: allOk ? .good : (hasProject ? .info : .warning)
        )
    }

    // MARK: - Project Health Card

    private var projectHealthCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Project Health", systemImage: "waveform.path.ecg")
                .font(.headline)

            HStack(spacing: 16) {
                healthPill(
                    icon: viewModel.selectedProjectRoot.isEmpty ? "folder.badge.questionmark" : "folder.fill",
                    label: viewModel.selectedProjectRoot.isEmpty
                        ? "No Project"
                        : (viewModel.selectedProjectRoot as NSString).lastPathComponent,
                    color: viewModel.selectedProjectRoot.isEmpty ? .red : .blue
                )
                healthPill(
                    icon: viewModel.graphAvailable
                        ? (viewModel.graphStale ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        : "circle.dashed",
                    label: viewModel.graphAvailable
                        ? (viewModel.graphStale ? "Graph Stale" : "Graph Fresh")
                        : "Graph Optional",
                    color: viewModel.graphAvailable ? (viewModel.graphStale ? .orange : .green) : .secondary
                )
                healthPill(
                    icon: viewModel.nexusConnected ? "circle.grid.3x3.fill" : "circle.grid.3x3",
                    label: viewModel.nexusConnected ? "Nexus Online" : "Nexus Offline",
                    color: viewModel.nexusConnected ? .blue : .secondary
                )
                healthPill(
                    icon: viewModel.somaServerRunning ? "bolt.circle.fill" : "bolt.circle",
                    label: viewModel.somaServerRunning ? "MCP Online" : "MCP Offline",
                    color: viewModel.somaServerRunning ? .green : .red
                )
            }

            if viewModel.graphStale && viewModel.graphAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Graph is older than 24 hours. Run `graphify update .` in your project root.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
            }
        }
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1)))
    }

    private func healthPill(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 13))
            Text(label)
                .font(.caption.bold())
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - MCP Readiness

    private var mcpReadinessCard: some View {
        let smoke = viewModel.mcpSmokeReport
        let failedTools = smoke?.summary?.failed_tools ?? []
        let configDegraded = smoke?.summary?.config_degraded ?? []

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AI Agent Readiness", systemImage: "checklist.checked")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.runMCPSmoke()
                } label: {
                    if viewModel.mcpSmokeBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Smoking…")
                        }
                    } else {
                        Label("Run MCP Smoke", systemImage: "play.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.selectedProjectRoot.isEmpty || viewModel.mcpSmokeBusy)
            }

            HStack(spacing: 12) {
                readinessTile(
                    title: "Codex MCP",
                    value: viewModel.codexConfigStatus?.status.capitalized ?? "Unknown",
                    detail: configDetail(viewModel.codexConfigStatus),
                    color: configColor(viewModel.codexConfigStatus)
                )
                readinessTile(
                    title: "Gemini MCP",
                    value: viewModel.geminiConfigStatus?.status.capitalized ?? "Unknown",
                    detail: configDetail(viewModel.geminiConfigStatus),
                    color: configColor(viewModel.geminiConfigStatus)
                )
                readinessTile(
                    title: "Hermes MCP",
                    value: viewModel.hermesConfigStatus?.status.capitalized ?? "Unknown",
                    detail: configDetail(viewModel.hermesConfigStatus),
                    color: configColor(viewModel.hermesConfigStatus)
                )
                readinessTile(
                    title: "Live MCP Smoke",
                    value: smoke?.status?.capitalized ?? "Not Run",
                    detail: smokeDetail(smoke),
                    color: smokeColor(smoke)
                )
                readinessTile(
                    title: "Plugin Guard",
                    value: smoke?.plugin_status?.unity_nexus?.capitalized ?? "Unknown",
                    detail: smoke?.plugin_status?.project_matches == true ? "Nexus project matches" : "Unity guarded/skipped",
                    color: smoke?.plugin_status?.unity_nexus == "ok" ? .blue : .secondary
                )
            }

            if !failedTools.isEmpty || !configDegraded.isEmpty {
                Text("Attention: \(failedTools.isEmpty ? "" : "failed tools: \(failedTools.joined(separator: ", "))")\(configDegraded.isEmpty ? "" : " config degraded: \(configDegraded.joined(separator: ", "))")")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if let error = viewModel.mcpSmokeError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1)))
    }

    private func readinessTile(title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.headline, design: .rounded).bold())
                .foregroundColor(color)
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(12)
        .background(Color(NSColor.textBackgroundColor).opacity(0.45))
        .cornerRadius(8)
    }

    private func configDetail(_ status: ClientConfigStatus?) -> String {
        guard let status else { return "degraded: missing client" }
        if status.status == "error" { return "error: invalid config" }
        if status.project_matches == false { return "degraded: wrong project root" }
        if status.direct_nexus_exposed == true { return "degraded: direct Nexus exposed" }
        if status.issues.contains("missing_config") || status.issues.contains("hermes_cli_missing") { return "degraded: missing client" }
        if status.issues.isEmpty { return "ready" }
        return status.issues.prefix(2).joined(separator: ", ")
    }

    private func configColor(_ status: ClientConfigStatus?) -> Color {
        guard let status else { return .secondary }
        if status.status == "ok" { return .green }
        if status.status == "error" { return .red }
        return .orange
    }

    private func smokeDetail(_ report: MCPSmokeReport?) -> String {
        guard let report else { return "Run before live tool use" }
        let ok = report.summary?.smoked_tools ?? 0
        let skipped = report.summary?.skipped_tools ?? 0
        let total = report.summary?.tool_count ?? report.server?.tool_count ?? 0
        return "\(ok)/\(total) exercised, \(skipped) guarded"
    }

    private func smokeColor(_ report: MCPSmokeReport?) -> Color {
        guard let report else { return .secondary }
        if report.status == "ok" { return .green }
        if report.status == "error" { return .red }
        return .orange
    }

    // MARK: - Token Measurement

    private var tokenSavingsCard: some View {
        let savings = viewModel.latestTokenSavings
        let operation = savings?.operation_savings
        let estimated = savings?.estimated_context_reduction
        let benchmark = viewModel.tokenBenchmarkReport
        let benchmarkSummary = benchmark?.summary
        let benchmarkRoot = benchmark?.results?.first?.project_root
        let benchmarkStale = benchmarkRoot != nil && !viewModel.projectPathsMatch(viewModel.selectedProjectRoot, benchmarkRoot)
        let agentBenchmark = viewModel.agentBenchmarkReport
        let agentSummary = agentBenchmark?.summary
        let agentBenchmarkStale = agentBenchmark?.project_root != nil && !viewModel.projectPathsMatch(viewModel.selectedProjectRoot, agentBenchmark?.project_root)
        let operationSaved = operation?.saved_tokens ?? savings?.saved_tokens
        let operationPct = operation?.savings_pct ?? savings?.savings_pct
        let responseTokens = operation?.soma_response_tokens ?? operation?.packet_tokens ?? savings?.packet_tokens
        let latestLanguage = viewModel.logEntries.first { $0.translation_status != nil }
        let localModelCalls = viewModel.localModelStats.reduce(0) { $0 + $1.calls }
        let localModelErrors = viewModel.localModelStats.reduce(0) { $0 + $1.errors }

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Real Token Measurement", systemImage: "chart.line.downtrend.xyaxis")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.runTokenBenchmark()
                } label: {
                    if viewModel.tokenBenchmarkBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Measuring…")
                        }
                    } else {
                        Label("Measure Context", systemImage: "speedometer")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.selectedProjectRoot.isEmpty || viewModel.tokenBenchmarkBusy)
            }

            HStack(spacing: 18) {
                savingsMetric(
                    title: "Operation",
                    value: operationSaved.map { "\($0)" } ?? "No data",
                    detail: operationPct.map { String(format: "%.1f%% vs ops", $0) } ?? savings?.status ?? "run soma_prepare_context",
                    color: .green
                )
                savingsMetric(
                    title: "Estimated",
                    value: (estimated?.saved_tokens).map { "\($0)" } ?? "—",
                    detail: (estimated?.savings_pct).map { String(format: "%.1f%% context", $0) } ?? "secondary",
                    color: .purple
                )
                savingsMetric(
                    title: "Observed A/B",
                    value: (agentSummary?.total_saved_tokens).map { "\($0)" } ?? "—",
                    detail: (agentSummary?.avg_savings_pct).map { String(format: "%.1f%% agent", $0) } ?? "scenario only",
                    color: agentBenchmarkStale ? .orange : .blue
                )
                savingsMetric(
                    title: "Prompt Lang",
                    value: (latestLanguage?.prompt_saved_tokens).map { "\($0)" } ?? "—",
                    detail: latestLanguage.map { languageDetail($0) } ?? "translation no data",
                    color: latestLanguage?.translation_status == "translated" ? .teal : .secondary
                )
                savingsMetric(
                    title: "Local AI",
                    value: localModelCalls > 0 ? "\(localModelCalls)" : "—",
                    detail: localModelDetail(errors: localModelErrors),
                    color: localModelErrors > 0 ? .orange : (localModelCalls > 0 ? .teal : .secondary)
                )
            }

            HStack(spacing: 8) {
                Text("Response: \(responseTokens.map { "\($0)" } ?? "—") tokens")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let budgetUsed = operation?.budget_used_pct ?? savings?.budget_used_pct {
                    Text(String(format: "%.1f%% budget", budgetUsed))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("Estimator: \(operation?.estimator ?? savings?.estimator ?? benchmark?.model_profile ?? "estimated")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let baseline = operation?.baseline_type ?? savings?.baseline_type {
                    Text("Baseline: \(baseline.replacingOccurrences(of: "_", with: " "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if benchmarkStale {
                    Label("Context benchmark is for another project", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if agentBenchmarkStale {
                    Label("A/B benchmark is for another project", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if let contextSaved = benchmarkSummary?.total_saved_tokens {
                Text("Latest opt-in context benchmark: \(contextSaved) estimated tokens reduced, \(String(format: "%.1f", benchmarkSummary?.avg_savings_pct ?? 0))% average.")
                    .font(.caption)
                    .foregroundColor(benchmarkStale ? .orange : .secondary)
            }
            if let error = viewModel.tokenBenchmarkError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
            if let error = viewModel.agentBenchmarkError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1)))
    }

    private func savingsMetric(title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced).bold())
                .foregroundColor(color)
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func languageDetail(_ entry: SomaLogEntry) -> String {
        if entry.translation_status == "translated" {
            return String(format: "%.1f%% %@->EN", entry.prompt_savings_pct ?? 0, (entry.source_language ?? "?").uppercased())
        }
        if entry.translation_status == "failed_fallback" {
            return "fallback \(entry.source_language ?? "?")"
        }
        return entry.translation_status ?? "unknown"
    }

    private func localModelDetail(errors: Int) -> String {
        guard let top = viewModel.localModelStats.first else {
            return "configured: \(ollama.modelName)"
        }
        let topStage = top.stages.sorted { $0.value > $1.value }.first?.key ?? "unknown"
        let role = ollama.configuredRole(for: top.id, stage: topStage)?.title ?? "unmapped"
        let errorText = errors > 0 ? " · \(errors) err" : ""
        return "\(role) · \(top.id) · \(topStage)\(errorText)"
    }

    // MARK: - Agent Benchmarks

    private var agentBenchmarkCard: some View {
        let report = viewModel.agentBenchmarkReport
        let summary = report?.summary
        let stale = report?.project_root != nil && !viewModel.projectPathsMatch(viewModel.selectedProjectRoot, report?.project_root)
        let comparisons = report?.comparisons ?? []

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Latest Benchmarks", systemImage: "chart.bar.doc.horizontal")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.chooseAndRunAgentBenchmark()
                } label: {
                    if viewModel.agentBenchmarkBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Running…")
                        }
                    } else {
                        Label("Run Scenario", systemImage: "play.circle")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.selectedProjectRoot.isEmpty || viewModel.agentBenchmarkBusy)
            }

            HStack(spacing: 12) {
                benchmarkAgentTile(agent: "codex", comparisons: comparisons)
                benchmarkAgentTile(agent: "gemini", comparisons: comparisons)
                benchmarkAgentTile(agent: "hermes", comparisons: comparisons)
                readinessTile(
                    title: "Acceptance",
                    value: "\(summary?.paired_result_count ?? 0)/\(summary?.comparison_count ?? 0)",
                    detail: summary?.failed_run_count.map { "\($0) failed runs" } ?? "no report",
                    color: (summary?.failed_run_count ?? 0) > 0 ? .orange : (report == nil ? .secondary : .green)
                )
            }

            if stale {
                Label("A/B benchmark is for another project", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if let scenario = report?.scenario_path {
                Text("Scenario: \(scenario)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            if let error = viewModel.agentBenchmarkError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1)))
    }

    private func benchmarkAgentTile(agent: String, comparisons: [AgentBenchmarkComparison]) -> some View {
        let agentComparisons = comparisons.filter { $0.agent == agent }
        let ok = agentComparisons.filter { $0.status == "ok" }
        let saved = ok.reduce(0) { $0 + ($1.saved_tokens ?? 0) }
        let avg = ok.isEmpty ? nil : ok.reduce(0.0) { $0 + ($1.savings_pct ?? 0) } / Double(ok.count)
        let failedAcceptance = agentComparisons.contains { $0.direct_acceptance_status == "failed" || $0.with_soma_acceptance_status == "failed" }
        let value = ok.isEmpty ? "—" : "\(saved)"
        let detail = avg.map { String(format: "%.1f%% saved", $0) } ?? (failedAcceptance ? "rubric failed" : "no accepted pair")
        let color: Color = ok.isEmpty ? (failedAcceptance ? .red : .secondary) : .blue
        return readinessTile(title: agent.capitalized, value: value, detail: detail, color: color)
    }

    // MARK: - Task Audit

    private var auditTraceCard: some View {
        let audit = viewModel.auditReport
        let missing = audit?.missing_evidence
        let unresolvedCount = (missing?.missing_files?.count ?? 0) + (missing?.missing_symbols?.count ?? 0)
        let conceptCount = missing?.unresolved_concepts?.count ?? 0
        let notSelectedCount = missing?.found_not_selected?.count ?? 0
        let evidenceCount = audit?.selected_evidence?.count ?? 0
        let strong = audit?.evidence_quality?.strong_match_count ?? 0
        let weak = audit?.evidence_quality?.weak_match_count ?? 0
        let qualityReason = packetQualityReason(audit)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Task Trace", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Toggle("Capture raw for next run", isOn: $viewModel.auditRawCaptureNextRun)
                    .toggleStyle(.switch)
                    .font(.caption)
                Button {
                    viewModel.loadAuditReport()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                readinessTile(
                    title: "Audit",
                    value: audit?.status?.capitalized ?? "No Data",
                    detail: audit?.run_id ?? "Run Soma Packet Mode",
                    color: auditColor(audit?.status)
                )
                readinessTile(
                    title: "Packet",
                    value: "\(evidenceCount)",
                    detail: qualityReason,
                    color: audit?.evidence_quality?.status == "ok" ? .green : .orange
                )
                readinessTile(
                    title: "Matches",
                    value: "\(strong)/\(weak)",
                    detail: "strong / weak",
                    color: strong > 0 && weak == 0 ? .green : (strong > 0 ? .orange : .secondary)
                )
                readinessTile(
                    title: "Missing",
                    value: "\(unresolvedCount + notSelectedCount)",
                    detail: unresolvedCount > 0 ? "\(unresolvedCount) files/symbols" : (notSelectedCount > 0 ? "\(notSelectedCount) not selected" : (conceptCount > 0 ? "\(conceptCount) concepts" : "none")),
                    color: (unresolvedCount + notSelectedCount) > 0 ? .orange : .green
                )
                readinessTile(
                    title: "Quality",
                    value: audit?.quality_review?.status?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unreviewed",
                    detail: audit?.quality_review?.reviewed_at ?? "manual or rubric",
                    color: qualityColor(audit?.quality_review?.status)
                )
            }

            if let audit {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt hash: \(audit.prompt_hash ?? "—")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text("Packet hash: \(audit.packet_hash ?? "—")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if audit.raw_capture_enabled == true {
                        Text("Raw artifacts captured locally for this run.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if let firstMissing = (missing?.missing_files?.first ?? missing?.missing_symbols?.first)?.reference {
                        Text("First unresolved reference: \(firstMissing)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if let concept = missing?.unresolved_concepts?.first?.reference {
                        Text("Unresolved concept: \(concept)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack {
                TextField("Optional review notes", text: $auditNotes)
                    .textFieldStyle(.roundedBorder)
                Button("Accepted") {
                    viewModel.markAudit(status: "accepted", notes: auditNotes)
                }
                .disabled(audit?.run_id == nil || viewModel.auditMarkBusy)
                Button("Wrong") {
                    viewModel.markAudit(status: "wrong", notes: auditNotes)
                }
                .disabled(audit?.run_id == nil || viewModel.auditMarkBusy)
                Button("Needs Evidence") {
                    viewModel.markAudit(status: "needs_more_evidence", notes: auditNotes)
                }
                .disabled(audit?.run_id == nil || viewModel.auditMarkBusy)
            }
            .controlSize(.small)

            if let error = viewModel.auditError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1)))
    }

    private func auditColor(_ status: String?) -> Color {
        if status == "ok" { return .green }
        if status == "failed" || status == "error" { return .red }
        if status == "degraded" { return .orange }
        return .secondary
    }

    private func qualityColor(_ status: String?) -> Color {
        if status == "accepted" { return .green }
        if status == "wrong" { return .red }
        if status == "needs_more_evidence" { return .orange }
        return .secondary
    }

    private func packetQualityReason(_ audit: AuditReport?) -> String {
        guard let audit else { return "run packet first" }
        if audit.evidence_quality?.status == "ok" && audit.missing_evidence?.status == "ok" {
            return "ok: strong evidence"
        }
        if let warning = audit.evidence_quality?.warnings?.first {
            return "degraded: \(warning)"
        }
        if audit.missing_evidence?.missing_files?.isEmpty == false {
            return "degraded: missing files"
        }
        if audit.missing_evidence?.missing_symbols?.isEmpty == false {
            return "degraded: missing symbols"
        }
        return audit.status == "degraded" ? "degraded: needs evidence" : (audit.evidence_quality?.status ?? "not checked")
    }

    // MARK: - Gateway Control Grid

    private var gatewayGrid: some View {
        HStack(spacing: 14) {
            gatewayControlCard(
                title: "Soma MCP",
                subtitle: viewModel.somaServerRunning ? "stdio transport" : "Offline",
                icon: "server.rack.shell",
                iconColor: viewModel.somaServerRunning ? .green : .secondary,
                status: viewModel.somaServerRunning ? "Ready" : "Stopped",
                statusColor: viewModel.somaServerRunning ? .green : .red,
                actionLabel: viewModel.somaServerRunning ? "Disable" : "Enable",
                actionBusy: viewModel.somaServerBusy,
                actionDisabled: viewModel.selectedProjectRoot.isEmpty,
                actionDestructive: viewModel.somaServerRunning,
                action: {
                    if viewModel.somaServerRunning { viewModel.stopSomaServer() }
                    else { viewModel.startSomaServer() }
                }
            )
            graphifyCard

            gatewayControlCard(
                title: "Nexus Unity",
                subtitle: viewModel.nexusVersion,
                icon: "circle.grid.3x3.fill",
                iconColor: viewModel.nexusConnected ? .blue : .secondary,
                status: viewModel.nexusConnected ? "Connected" : "Offline",
                statusColor: viewModel.nexusConnected ? .blue : .secondary,
                actionLabel: "Connect from Editor",
                actionBusy: false,
                actionDisabled: true,
                actionDestructive: false,
                action: {}
            )
        }
    }

    // MARK: - Graphify Card (3 actions: upgrade tool, init graph, update graph)

    private var graphifyCard: some View {
        let iconColor: Color = viewModel.graphAvailable ? .purple : .secondary
        let statusLabel = viewModel.graphAvailable
            ? (viewModel.graphStale ? "Stale" : "Fresh")
            : "No Graph"
        let statusColor: Color = viewModel.graphAvailable
            ? (viewModel.graphStale ? .orange : .green)
            : .red
        let isGraphBusy = viewModel.graphifyBusy
        let isUpgradeBusy = viewModel.systemBusy
        let noProject = viewModel.selectedProjectRoot.isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "shareplay")
                    .font(.system(size: 22))
                    .foregroundColor(iconColor)
                Spacer()
                Text(statusLabel)
                    .font(.caption.bold())
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.1))
                    .cornerRadius(6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Graphify").font(.headline)
                Text(viewModel.graphifyVersion)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            // 1. Check for Update — upgrades graphify tool globally via uv
            Button(action: { viewModel.upgradeGraphify() }) {
                if isUpgradeBusy && !isGraphBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Upgrading…").font(.caption)
                    }
                } else {
                    Label("Check for Update", systemImage: "arrow.down.circle")
                }
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(BorderedButtonStyle())
            .controlSize(.small)
            .disabled(isUpgradeBusy || isGraphBusy)

            // 2. Initialize Graph — only when no graph exists in the project
            if !viewModel.graphAvailable {
                Button(action: { viewModel.initializeGraphify() }) {
                    if isGraphBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Building…").font(.caption)
                        }
                    } else {
                        Label("Initialize Graph", systemImage: "bolt.fill")
                    }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(BorderedProminentButtonStyle())
                .controlSize(.small)
                .tint(.purple)
                .disabled(isGraphBusy || isUpgradeBusy || noProject)
            }

            // 3. Update Graph — always visible, runs graphify update . to rebuild from scratch
            Button(action: { viewModel.initializeGraphify() }) {
                if isGraphBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Building…").font(.caption)
                    }
                } else {
                    Text("Update Graph")
                }
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(BorderedButtonStyle())
            .controlSize(.small)
            .disabled(isGraphBusy || isUpgradeBusy || noProject)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(iconColor.opacity(0.2)))
    }

    private func gatewayControlCard(
        title: String,
        subtitle: String,
        icon: String,
        iconColor: Color,
        status: String,
        statusColor: Color,
        actionLabel: String,
        actionBusy: Bool,
        actionDisabled: Bool,
        actionDestructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(iconColor)
                Spacer()
                Text(status)
                    .font(.caption.bold())
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.1))
                    .cornerRadius(6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: action) {
                if actionBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.caption)
                    }
                } else {
                    Text(actionLabel)
                }
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(BorderedButtonStyle())
            .controlSize(.small)
            .tint(actionDestructive ? .red : nil)
            .disabled(actionBusy || actionDisabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(iconColor.opacity(0.2)))
    }

    // MARK: - AI Agent Setup

    private var componentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI Agent Setup", systemImage: "gear.badge.checkmark")
                .font(.headline)

            HStack(spacing: 12) {
                clientConfigCard(
                    client: "Codex",
                    icon: "terminal.fill",
                    description: "Install Soma-only config and remove direct Nexus exposure.",
                    status: viewModel.codexConfigStatus,
                    actionLabel: "Install Config",
                    action: { viewModel.installCodexConfig() },
                    verifyLabel: "Verify",
                    verifyAction: { viewModel.verifyCodexConfig() },
                    rollbackLabel: "Rollback",
                    rollbackAction: { viewModel.rollbackCodexConfig() }
                )
                clientConfigCard(
                    client: "Gemini CLI",
                    icon: "sparkles",
                    description: "Install Soma MCP config while preserving Gemini settings.",
                    status: viewModel.geminiConfigStatus,
                    actionLabel: "Install Config",
                    action: { viewModel.installGeminiConfig() },
                    verifyLabel: "Verify",
                    verifyAction: { viewModel.verifyGeminiConfig() },
                    rollbackLabel: "Rollback",
                    rollbackAction: { viewModel.rollbackGeminiConfig() }
                )
                clientConfigCard(
                    client: "Hermes",
                    icon: "point.3.connected.trianglepath.dotted",
                    description: "Install Soma as Hermes' evidence backend via MCP.",
                    status: viewModel.hermesConfigStatus,
                    actionLabel: "Install Config",
                    action: { viewModel.installHermesConfig() },
                    verifyLabel: "Verify",
                    verifyAction: { viewModel.verifyHermesConfig() },
                    rollbackLabel: nil,
                    rollbackAction: nil
                )
                clientConfigCard(
                    client: "Claude",
                    icon: "message.fill",
                    description: "Copy Soma MCP config for Claude Desktop (manual paste required).",
                    status: nil,
                    actionLabel: "Copy Config",
                    action: { viewModel.copyClaudeConfig() },
                    verifyLabel: nil,
                    verifyAction: nil,
                    rollbackLabel: nil,
                    rollbackAction: nil
                )
            }

            projectAISetupCard

            if let status = viewModel.mcpInstallStatus {
                Text(status)
                    .font(.caption)
                    .foregroundColor(status.contains("✓") || status.contains("OK") ? .green : .orange)
                    .padding(.top, 4)
            }

            if let preview = viewModel.mcpConfigPreview, !preview.isEmpty {
                DisclosureGroup("Config Preview") {
                    Text(preview)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                }
                .font(.caption.bold())
            }
        }
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1)))
    }

    private var projectAISetupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundColor(.secondary)
                Text("Project Setup Hardening")
                    .font(.subheadline.bold())
                Spacer()
                if let status = viewModel.projectSetupReport?.status {
                    Text(status.uppercased())
                        .font(.system(size: 9).bold())
                        .foregroundColor(setupColor(status))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(setupColor(status).opacity(0.1))
                        .cornerRadius(4)
                }
            }

            Text("Analyze project-local Gemini/Codex prompts and configs, then add Soma-first routing with backups. Harden also updates backed-up global client configs so external CLIs route through Soma.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let report = viewModel.projectSetupReport {
                HStack(spacing: 14) {
                    setupMetric("Inspected", "\(report.files_inspected?.count ?? 0)")
                    setupMetric("Changed", "\(report.files_changed?.count ?? 0)")
                    setupMetric("Risks", "\(report.remaining_risks?.count ?? report.issues?.count ?? 0)")
                    setupMetric("Backups", "\(report.backups?.count ?? 0)")
                }
                if let risks = report.remaining_risks, !risks.isEmpty {
                    Text(risks.prefix(3).joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                } else if let summary = report.summary {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundColor(setupColor(report.status ?? "ok"))
                        .lineLimit(2)
                }
            }

            if let error = viewModel.projectSetupError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Use This Project With Hermes", action: { viewModel.useSelectedProjectWithHermes() })
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Soma First Setup", action: { viewModel.runSomaFirstSetup() })
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                HStack(spacing: 8) {
                    Button("Analyze Only", action: { viewModel.analyzeProjectAISetup() })
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Harden Project + Global CLIs", action: { viewModel.hardenProjectAISetup() })
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Rollback", action: { viewModel.rollbackProjectAISetup() })
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .disabled(viewModel.selectedProjectRoot.isEmpty || viewModel.projectSetupBusy || viewModel.hermesSetupBusy)

            if viewModel.projectSetupBusy || viewModel.hermesSetupBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(viewModel.hermesSetupBusy ? "Preparing Hermes setup..." : "Checking project setup...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if let error = viewModel.hermesSetupError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            if let command = viewModel.hermesLaunchCommand {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundColor(.secondary)
                    Text(command)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy Prompt", action: { viewModel.copyHermesStarterPrompt() })
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }

            if let prompt = viewModel.hermesStarterPrompt, !prompt.isEmpty {
                DisclosureGroup("Hermes Starter Prompt") {
                    Text(prompt)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                }
                .font(.caption.bold())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

    private func setupMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.caption.bold())
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    private func setupColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "ok": return .green
        case "degraded", "skipped": return .orange
        case "error", "failed": return .red
        default: return .secondary
        }
    }

    private func clientConfigCard(
        client: String,
        icon: String,
        description: String,
        status: ClientConfigStatus?,
        actionLabel: String,
        action: @escaping () -> Void,
        verifyLabel: String?,
        verifyAction: (() -> Void)?,
        rollbackLabel: String?,
        rollbackAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(.secondary)
                Text(client).font(.subheadline.bold())
                Spacer()
                if let status {
                    Text(status.status.uppercased())
                        .font(.system(size: 9).bold())
                        .foregroundColor(configColor(status))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(configColor(status).opacity(0.1))
                        .cornerRadius(4)
                }
            }
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status {
                Text(configDetail(status))
                    .font(.system(size: 10))
                    .foregroundColor(configColor(status))
                    .lineLimit(2)
            }
            Spacer()
            HStack(spacing: 6) {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.selectedProjectRoot.isEmpty)
                if let verifyLabel, let verifyAction {
                    Button(verifyLabel, action: verifyAction)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let rollbackLabel, let rollbackAction {
                    Button(rollbackLabel, action: rollbackAction)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }
}
