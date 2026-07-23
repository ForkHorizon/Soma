import AppKit
import Combine
import Foundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @ObservedObject var rusToPromptQueueManager: RusToPromptQueueManager
    @ObservedObject var voiceASR: ASRManager
    @ObservedObject var voicePrompter: RusToPromptViewModel
    @ObservedObject var globalVoice: GlobalVoiceController
    @ObservedObject var textPriorityQueue: VoiceTextPriorityQueue
    @StateObject private var promptCompilerViewModel = PromptCompilerViewModel()
    @StateObject private var rusToPromptViewModel = RusToPromptViewModel()
    @State private var selectedRoute: AppRoute? = .rusToPrompt
    @AppStorage("globalVoicePasteEnabled") private var globalVoicePasteEnabled = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel, ollama: ollama, selectedRoute: $selectedRoute)
                .navigationTitle("Soma")
        } detail: {
            VStack(spacing: 0) {
                if let route = selectedRoute {
                    switch route {
                    case .rusToPrompt:
                        RusToPromptView(viewModel: rusToPromptViewModel, somaViewModel: viewModel, ollama: ollama, queueManager: rusToPromptQueueManager)
                    case .voiceToText:
                        VoiceToTextView(somaViewModel: viewModel, ollama: ollama, asr: voiceASR, prompter: voicePrompter, globalVoice: globalVoice, textPriorityQueue: textPriorityQueue)
                    case .queue:
                        TestsView(mode: .queue, ollama: ollama, queueManager: rusToPromptQueueManager)
                    case .modelStats:
                        TestsView(mode: .stats, ollama: ollama, queueManager: rusToPromptQueueManager)
                    case .tests:
                        TestsView(mode: .full, ollama: ollama, queueManager: rusToPromptQueueManager)
                    case .promptCompiler:
                        PromptCompilerView(viewModel: promptCompilerViewModel, somaViewModel: viewModel, ollama: ollama)
                    case .localAI:
                        LocalAISettingsView(viewModel: viewModel, ollama: ollama)
                    case .logs:
                        LogsView(viewModel: viewModel, ollama: ollama)
                    case .tokenCalculator:
                        TokenCalculatorView(viewModel: viewModel)
                    case .systemStatus:
                        SystemStatusView(viewModel: viewModel, ollama: ollama)
                    case .extensions:
                        ToolVersionsView(viewModel: viewModel)
                    case .projectOverview:
                        ProjectOverviewView(viewModel: viewModel)
                    }
                } else {
                    Spacer()
                    Text("Select Rus to Prompt to start")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .task {
            viewModel.hydrateProjectRootsIfNeeded()
        }
        .onAppear {
            textPriorityQueue.onImportTranslationCompleted = { [weak voiceASR] id, path in
                voiceASR?.setImportedTranslation(id, path: path)
            }
            textPriorityQueue.configure(somaViewModel: viewModel, ollama: ollama, prompter: voicePrompter)
            voiceASR.configure(textPriorityQueue: textPriorityQueue)
            globalVoice.configure(asr: voiceASR, somaViewModel: viewModel, ollama: ollama, prompter: voicePrompter, textPriorityQueue: textPriorityQueue)
            globalVoice.setEnabled(globalVoicePasteEnabled)
        }
        .onChange(of: globalVoicePasteEnabled) { _, enabled in
            globalVoice.setEnabled(enabled, promptForPermission: enabled)
        }
    }

}

nonisolated struct ProjectOverviewPayload: Codable, Sendable {
    let status: String?
    let project_root: String?
    let display_name: String?
    let git: ProjectGitOverview?
    let graph: SomaGraphStatus?
    let clients: [ExtensionClientStatus]?
    let memory: ProjectMemoryOverview?
    let issues: [String]?
}

nonisolated struct ProjectGitOverview: Codable, Sendable {
    let is_repo: Bool?
    let branch: String?
    let ahead: Int?
    let behind: Int?
    let changed_count: Int?
    let staged_count: Int?
    let unstaged_count: Int?
    let untracked_count: Int?
    let dirty: Bool?
    let last_commit: String?
    let summary: String?
}

nonisolated struct ProjectMemoryOverview: Codable, Sendable {
    let status: String?
    let installed_tools: [ProjectInstalledTool]?
    let codebase_memory_installed: Bool?
    let codebase_memory_indexed: Bool?
    let projectmem_installed: Bool?
    let projectmem_initialized: Bool?
    let projectmem_setup_mode: Bool?
    let agents_memory_block: Bool?
    let graph_available: Bool?
    let graph_stale: Bool?
    let issues: [String]?
}

nonisolated struct ProjectInstalledTool: Codable, Identifiable, Sendable {
    let id: String
    let name: String?
    let status: String?
}

nonisolated struct ProjectToolSetupResult: Codable, Sendable {
    let status: String?
    let summary: String?
    let tool_id: String?
    let name: String?
    let issues: [String]?
    let restart_needed: [String]?
}

struct ProjectOverviewView: View {
    @ObservedObject var viewModel: SomaViewModel
    @State private var overview: ProjectOverviewPayload?
    @State private var busy = false
    @State private var status = ""
    @State private var toolChooserPresented = false
    @State private var toolCatalog: [ExtensionToolStatus] = []
    @State private var toolChooserBusy = false
    @State private var toolSetupBusy = false
    @State private var installingProjectToolId: String?
    @State private var toolSetupStatus = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if currentOverview == nil && !viewModel.selectedProjectRoot.isEmpty {
                    loadingOverview
                } else {
                    metrics
                    gitCard
                    memoryCard
                    clientsCard
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .task(id: viewModel.selectedProjectRoot) {
            await refresh(projectRoot: viewModel.selectedProjectRoot, clear: true)
        }
        .sheet(isPresented: $toolChooserPresented) {
            ProjectToolChooserSheet(
                tools: toolCatalog,
                supportedToolIds: projectInstallableToolIds,
                installedToolIds: installedProjectToolIds,
                busy: toolChooserBusy || toolSetupBusy,
                installingToolId: installingProjectToolId,
                status: toolSetupStatus,
                install: { toolId in await setupProjectTool(toolId) },
                close: { toolChooserPresented = false }
            )
            .frame(width: 540, height: 460)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(currentOverview?.display_name ?? projectName)
                    .font(.largeTitle.bold())
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            Text(viewModel.selectedProjectRoot.isEmpty ? "No project selected" : viewModel.selectedProjectRoot)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button { Task { await refresh(projectRoot: viewModel.selectedProjectRoot) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button { Task { await runThenRefresh(["--sync-project-clients"], done: "Project client sync finished.") } } label: {
                    Label("Sync Clients", systemImage: "arrow.triangle.2.circlepath")
                }
                Button { Task { await runThenRefresh(["--refresh-managed-graph"], done: "Graph refresh finished.") } } label: {
                    Label("Refresh Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Button { viewModel.openGraphifyReport() } label: {
                    Label("Open Report", systemImage: "doc.richtext")
                }
                Button { openProjectFolder() } label: {
                    Label("Open Folder", systemImage: "folder")
                }
            }
            .disabled(busy || viewModel.selectedProjectRoot.isEmpty)
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            metricCard("Git", currentOverview?.git?.summary ?? "Unknown", currentOverview?.git?.branch ?? "No branch", "point.topleft.down.curvedto.point.bottomright.up", currentOverview?.git?.dirty == true ? .orange : .green)
            metricCard("Graph", graphSummary, graphSubtitle, "network", currentOverview?.graph?.stale == true ? .orange : .green)
            metricCard("Memory", memoryMetric, memorySummary, "brain", memoryTone)
            metricCard("Clients", clientSummary, "\(currentOverview?.clients?.count ?? 0) configs", "terminal", clientSummary == "ok" ? .green : .orange)
        }
    }

    private var gitCard: some View {
        overviewCard("Git", "arrow.triangle.branch") {
            let git = currentOverview?.git
            row("Repository", git?.is_repo == true ? "Yes" : "No")
            row("Branch", git?.branch ?? "None")
            row("Changes", "\(git?.changed_count ?? 0) total, \(git?.staged_count ?? 0) staged, \(git?.unstaged_count ?? 0) unstaged, \(git?.untracked_count ?? 0) untracked")
            if let ahead = git?.ahead { row("Ahead", String(ahead)) }
            if let behind = git?.behind { row("Behind", String(behind)) }
            row("Last commit", git?.last_commit ?? "None")
        }
    }

    private var memoryCard: some View {
        overviewCard("Memory & Graph", "brain.head.profile") {
            HStack {
                Text(installedMemoryTools.isEmpty ? "No project tools installed" : "\(installedMemoryTools.count) installed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button { openToolChooser() } label: {
                    Label("Add Tool", systemImage: "plus.circle")
                }
                .controlSize(.small)
                .disabled(busy || viewModel.selectedProjectRoot.isEmpty)
            }
            if toolSetupBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(toolSetupStatus.isEmpty ? "Installing tool..." : toolSetupStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if !toolSetupStatus.isEmpty {
                Text(toolSetupStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            ForEach(installedMemoryTools) { tool in
                row(tool.name ?? tool.id, tool.status ?? "Installed")
            }
            issueText(currentOverview?.memory?.issues)
        }
    }

    private var clientsCard: some View {
        overviewCard("Agents", "terminal") {
            ForEach((currentOverview?.clients ?? []).prefix(14)) { client in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: client.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(client.status == "ok" ? .green : .orange)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(client.client.capitalized): \(client.summary ?? client.status ?? "unknown")")
                            .font(.caption)
                        Text(client.config_path ?? "No config path")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var loadingOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                loadingMetricCard("Git", "point.topleft.down.curvedto.point.bottomright.up")
                loadingMetricCard("Graph", "network")
                loadingMetricCard("Memory", "brain")
                loadingMetricCard("Clients", "terminal")
            }
            loadingDetailCard("Git", "arrow.triangle.branch")
            loadingDetailCard("Memory & Graph", "brain.head.profile")
            loadingDetailCard("Agents", "terminal")
        }
    }

    private func overviewCard<Content: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func metricCard(_ title: String, _ value: String, _ subtitle: String, _ icon: String, _ tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundColor(tone)
                Text(title).font(.caption).foregroundColor(.secondary)
            }
            Text(value)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
    }

    private func loadingMetricCard(_ title: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundColor(.accentColor)
                Text(title).font(.caption).foregroundColor(.secondary)
            }
            placeholderLine(width: 110, height: 16)
            placeholderLine(width: 145, height: 8)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.12)))
    }

    private func loadingDetailCard(_ title: String, _ icon: String) -> some View {
        overviewCard(title, icon) {
            ForEach(0..<4, id: \.self) { index in
                placeholderLine(width: index.isMultiple(of: 2) ? 260 : 180)
            }
        }
    }

    private func placeholderLine(width: CGFloat? = nil, height: CGFloat = 10) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(Color.accentColor.opacity(0.18))
            .frame(width: width, height: height)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value.isEmpty ? "None" : value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func issueText(_ issues: [String]?) -> some View {
        Group {
            if let issues, !issues.isEmpty {
                Text(issues.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private var projectName: String {
        viewModel.selectedProjectRoot.isEmpty ? "Project" : (viewModel.selectedProjectRoot as NSString).lastPathComponent
    }

    private var graphSummary: String {
        guard currentOverview?.graph?.project_graph_available == true || currentOverview?.graph?.available == true else { return "Missing" }
        return currentOverview?.graph?.stale == true ? "Stale" : "Fresh"
    }

    private var graphSubtitle: String {
        let nodes = currentOverview?.graph?.node_count ?? 0
        let edges = currentOverview?.graph?.edge_count ?? 0
        return "\(nodes) nodes, \(edges) edges"
    }

    private var memorySummary: String {
        let issues = currentOverview?.memory?.issues?.count ?? 0
        if issues > 0 { return "\(issues) issues" }
        return installedMemoryTools.isEmpty ? "Add from extensions" : "\(installedMemoryTools.count) installed"
    }

    private var memoryMetric: String {
        installedMemoryTools.isEmpty ? "No tools" : (currentOverview?.memory?.status ?? "unknown")
    }

    private var memoryTone: Color {
        if currentOverview?.memory?.status == "degraded" { return .orange }
        return installedMemoryTools.isEmpty ? .secondary : .green
    }

    private var installedMemoryTools: [ProjectInstalledTool] {
        currentOverview?.memory?.installed_tools ?? []
    }

    private var clientSummary: String {
        let issues = (currentOverview?.clients ?? []).flatMap { $0.issues ?? [] }
        return issues.isEmpty ? "ok" : "\(Set(issues).count) issues"
    }

    private var currentOverview: ProjectOverviewPayload? {
        guard overview?.project_root == viewModel.selectedProjectRoot else { return nil }
        return overview
    }

    private var projectInstallableToolIds: Set<String> {
        ["codebase-memory", "projectmem", "graphify"]
    }

    private var installedProjectToolIds: Set<String> {
        Set(installedMemoryTools.map(\.id))
    }

    private func openToolChooser() {
        toolChooserPresented = true
        toolSetupStatus = ""
        Task { await loadToolCatalog() }
    }

    private func loadToolCatalog() async {
        await MainActor.run { toolChooserBusy = true }
        do {
            let data = try await viewModel.runSomaHelper(args: ["--tool-status-json"])
            let report = try JSONDecoder().decode(ToolStatusResponse.self, from: data)
            await MainActor.run {
                toolCatalog = report.tools
                toolChooserBusy = false
            }
        } catch {
            await MainActor.run {
                toolChooserBusy = false
                toolSetupStatus = "Tool list failed: \(error.localizedDescription)"
            }
        }
    }

    private func setupProjectTool(_ toolId: String) async {
        let projectRoot = viewModel.selectedProjectRoot
        guard !projectRoot.isEmpty else { return }
        let name = toolCatalog.first { $0.tool_id == toolId }?.name ?? toolId
        await MainActor.run {
            toolSetupBusy = true
            installingProjectToolId = toolId
            toolSetupStatus = "Installing \(name)..."
        }
        do {
            let data = try await viewModel.runSomaHelper(args: projectArgs(["--setup-project-tool", toolId], projectRoot: projectRoot))
            let result = try JSONDecoder().decode(ProjectToolSetupResult.self, from: data)
            let stillSelected = await MainActor.run { viewModel.selectedProjectRoot == projectRoot }
            guard stillSelected else {
                await MainActor.run {
                    toolSetupBusy = false
                    installingProjectToolId = nil
                }
                return
            }
            await refresh(projectRoot: projectRoot)
            await MainActor.run {
                toolSetupBusy = false
                installingProjectToolId = nil
                let issues = result.issues ?? []
                if result.status == "ok" {
                    toolSetupStatus = "\(result.name ?? name) installed."
                } else if issues.isEmpty {
                    toolSetupStatus = "\(result.name ?? name) \(result.status ?? "unknown")."
                } else {
                    toolSetupStatus = "\(result.name ?? name) \(result.status ?? "degraded"): \(issues.joined(separator: ", "))"
                }
            }
        } catch {
            await MainActor.run {
                toolSetupBusy = false
                installingProjectToolId = nil
                toolSetupStatus = "\(name) setup failed: \(error.localizedDescription)"
            }
        }
    }

    private func refresh(projectRoot: String, clear: Bool = false) async {
        guard !projectRoot.isEmpty else {
            await MainActor.run {
                overview = nil
                busy = false
                status = ""
            }
            return
        }
        await MainActor.run {
            if clear { overview = nil }
            busy = true
            status = "Refreshing project overview..."
        }
        do {
            let data = try await viewModel.runSomaHelper(args: projectArgs(["--project-overview-json"], projectRoot: projectRoot))
            let decoded = try JSONDecoder().decode(ProjectOverviewPayload.self, from: data)
            await MainActor.run {
                guard viewModel.selectedProjectRoot == projectRoot else { return }
                overview = decoded
                busy = false
                status = "Project overview refreshed."
            }
        } catch {
            await MainActor.run {
                guard viewModel.selectedProjectRoot == projectRoot else { return }
                busy = false
                status = "Project overview failed: \(error.localizedDescription)"
            }
        }
    }

    private func runThenRefresh(_ baseArgs: [String], done: String) async {
        let projectRoot = viewModel.selectedProjectRoot
        guard !projectRoot.isEmpty else { return }
        await MainActor.run {
            busy = true
            status = "Running \(baseArgs.first ?? "action")..."
        }
        do {
            _ = try await viewModel.runSomaHelper(args: projectArgs(baseArgs, projectRoot: projectRoot))
            let stillSelected = await MainActor.run { viewModel.selectedProjectRoot == projectRoot }
            guard stillSelected else { return }
            await refresh(projectRoot: projectRoot)
            await MainActor.run {
                guard viewModel.selectedProjectRoot == projectRoot else { return }
                status = done
            }
        } catch {
            await MainActor.run {
                guard viewModel.selectedProjectRoot == projectRoot else { return }
                busy = false
                status = "Action failed: \(error.localizedDescription)"
            }
        }
    }

    private func projectArgs(_ base: [String], projectRoot: String) -> [String] {
        base + ["--project-root", projectRoot]
    }

    private func openProjectFolder() {
        guard !viewModel.selectedProjectRoot.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: viewModel.selectedProjectRoot))
    }
}

private struct ProjectToolChooserSheet: View {
    let tools: [ExtensionToolStatus]
    let supportedToolIds: Set<String>
    let installedToolIds: Set<String>
    let busy: Bool
    let installingToolId: String?
    let status: String
    let install: (String) async -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add Tool")
                    .font(.title2.bold())
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            if tools.isEmpty {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(status.isEmpty ? "Loading tools..." : status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(tools) { tool in
                            toolRow(tool)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if !status.isEmpty && !tools.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
    }

    private func toolRow(_ tool: ExtensionToolStatus) -> some View {
        let supported = supportedToolIds.contains(tool.tool_id)
        let installed = installedToolIds.contains(tool.tool_id)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: tool.tool_id))
                .foregroundColor((supported || installed) ? .accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(tool.name ?? tool.tool_id)
                        .font(.headline)
                    Text(tool.kind ?? "Tool")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Text(tool.detail ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(installed ? "Installed in this project" : (supported ? versionSummary(tool) : "Managed globally in Extensions"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if installingToolId == tool.tool_id {
                ProgressView().controlSize(.small)
            } else if installed {
                Text("Installed")
                    .font(.caption.bold())
                    .foregroundColor(.green)
            } else {
                Button("Install") {
                    Task { await install(tool.tool_id) }
                }
                .disabled(busy || !supported)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func versionSummary(_ tool: ExtensionToolStatus) -> String {
        let installed = tool.installed_version ?? "not installed"
        let latest = tool.latest_version ?? "latest unknown"
        return "Current \(installed), latest \(latest)"
    }

    private func icon(for toolId: String) -> String {
        switch toolId {
        case "codebase-memory": return "brain.head.profile"
        case "projectmem": return "book.closed"
        case "graphify": return "network"
        case "ponytail": return "scissors"
        default: return "wrench.and.screwdriver"
        }
    }
}
