import SwiftUI

// MARK: - System Status (MCP Gateway Dashboard)

struct SystemStatusView: View {
    @ObservedObject var viewModel: SomaViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dashboardHeader
                projectHealthCard
                tokenSavingsCard
                gatewayGrid
                componentSection
                Spacer(minLength: 40)
            }
            .padding(28)
        }
        .onAppear { viewModel.fetchSystemVersions() }
    }

    // MARK: - Dashboard Header

    private var dashboardHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MCP Gateway")
                    .font(.largeTitle.bold())
                Text("Soma · Nexus · Graphify · Ollama")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            overallStatusBadge
        }
    }

    private var overallStatusBadge: some View {
        let allOk = viewModel.somaServerRunning && viewModel.graphAvailable && !viewModel.graphStale
        let label = allOk ? "All Systems Ready" : viewModel.somaServerRunning ? "Partial" : "Offline"
        let color: Color = allOk ? .green : viewModel.somaServerRunning ? .orange : .red

        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
                .shadow(color: color.opacity(0.6), radius: 4)
            Text(label).font(.subheadline.bold())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.3)))
        .cornerRadius(20)
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
                        : "xmark.circle.fill",
                    label: viewModel.graphAvailable
                        ? (viewModel.graphStale ? "Graph Stale" : "Graph Fresh")
                        : "No Graph",
                    color: viewModel.graphAvailable ? (viewModel.graphStale ? .orange : .green) : .red
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
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.1)))
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

    // MARK: - Token Savings

    private var tokenSavingsCard: some View {
        let savings = viewModel.latestTokenSavings
        let benchmark = viewModel.tokenBenchmarkReport
        let benchmarkSummary = benchmark?.summary
        let benchmarkRoot = benchmark?.results?.first?.project_root
        let benchmarkStale = benchmarkRoot != nil && !viewModel.projectPathsMatch(viewModel.selectedProjectRoot, benchmarkRoot)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Token Savings", systemImage: "chart.line.downtrend.xyaxis")
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
                        Label("Measure Selected Project", systemImage: "speedometer")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.selectedProjectRoot.isEmpty || viewModel.tokenBenchmarkBusy)
            }

            HStack(spacing: 18) {
                savingsMetric(
                    title: "Current Packet",
                    value: (savings?.packet_tokens).map { "\($0)" } ?? "No data",
                    detail: (savings?.budget_used_pct).map { String(format: "%.1f%% of budget", $0) } ?? "run soma_prepare_context",
                    color: .purple
                )
                savingsMetric(
                    title: "Saved",
                    value: (savings?.saved_tokens).map { "\($0)" } ?? "—",
                    detail: (savings?.savings_pct).map { String(format: "%.1f%%", $0) } ?? savings?.status ?? "not measured",
                    color: .green
                )
                savingsMetric(
                    title: "Benchmark",
                    value: (benchmarkSummary?.total_saved_tokens).map { "\($0)" } ?? "—",
                    detail: (benchmarkSummary?.avg_savings_pct).map { String(format: "%.1f%% avg", $0) } ?? "opt-in only",
                    color: benchmarkStale ? .orange : .blue
                )
            }

            HStack(spacing: 8) {
                Text("Estimator: \(savings?.estimator ?? benchmark?.model_profile ?? "estimated")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let baseline = savings?.baseline_type {
                    Text("Baseline: \(baseline.replacingOccurrences(of: "_", with: " "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if benchmarkStale {
                    Label("Benchmark is for another project", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if let error = viewModel.tokenBenchmarkError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(18)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.1)))
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
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(iconColor.opacity(0.2)))
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
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(iconColor.opacity(0.2)))
    }

    // MARK: - Component Section (Codex config / install)

    private var componentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Client Configuration", systemImage: "gear.badge.checkmark")
                .font(.headline)

            HStack(spacing: 12) {
                clientConfigCard(
                    client: "Codex",
                    icon: "terminal.fill",
                    description: "Install Soma-only config and remove direct Nexus exposure.",
                    actionLabel: "Install Config",
                    action: { viewModel.installCodexConfig() }
                )
                clientConfigCard(
                    client: "Gemini CLI",
                    icon: "sparkles",
                    description: "Copy Soma MCP config for Gemini CLI (manual paste required).",
                    actionLabel: "Copy Config",
                    action: { viewModel.copyGeminiConfig() }
                )
                clientConfigCard(
                    client: "Claude",
                    icon: "message.fill",
                    description: "Copy Soma MCP config for Claude Desktop (manual paste required).",
                    actionLabel: "Copy Config",
                    action: { viewModel.copyClaudeConfig() }
                )
            }

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
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.1)))
    }

    private func clientConfigCard(
        client: String,
        icon: String,
        description: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(.secondary)
                Text(client).font(.subheadline.bold())
            }
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(actionLabel, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.selectedProjectRoot.isEmpty)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12)))
    }
}
