import AppKit
import SwiftUI

struct ProjectsView: View {
    @ObservedObject var viewModel: SomaViewModel
    @Binding var selectedRoute: AppRoute?

    var body: some View {
        SomaPage {
            WorkflowHeader(
                title: "Projects",
                subtitle: "Open a local workspace before preparing packets. Project context, health, graph state, and activity are scoped to the selected project.",
                icon: "folder.fill",
                tone: viewModel.selectedProjectRoot.isEmpty ? .warning : .info,
                trailing: AnyView(addProjectButton)
            )

            if viewModel.selectedProjectRoot.isEmpty && viewModel.recentProjectRoots.isEmpty {
                emptyProjectsState
            } else {
                ScrollView {
                    SomaSplitWorkbench {
                        activeWorkspacePanel
                        recentProjectsPanel
                    } secondary: {
                        workspaceModelPanel
                        projectLocalContextPanel
                        projectSetupRecommendationsPanel
                    }
                }
            }
        }
    }

    private var addProjectButton: some View {
        Button {
            chooseProjectRoot()
        } label: {
            Label("Add Project", systemImage: "folder.badge.plus")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private var emptyProjectsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 52, weight: .semibold))
                .foregroundColor(.blue)
            Text("Open a project to start")
                .font(.title2.bold())
            Text("Soma works best as a workspace app: choose a repository or project folder, then prepare packets inside that context.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button {
                chooseProjectRoot()
            } label: {
                Label("Choose Project Folder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .padding(24)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
        .overlay(RoundedRectangle(cornerRadius: SomaDesign.radius).stroke(Color.secondary.opacity(0.10)))
    }

    private var activeWorkspacePanel: some View {
        SomaPanel(title: "Active Workspace", subtitle: "The project every workflow will use right now.", icon: "folder.fill", tone: viewModel.selectedProjectRoot.isEmpty ? .warning : .good) {
            if viewModel.selectedProjectRoot.isEmpty {
                StatusBanner(title: "No project opened", detail: "Prepare Packet is disabled until you choose a local project folder.", tone: .warning)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text((viewModel.selectedProjectRoot as NSString).lastPathComponent)
                                .font(.title3.bold())
                            Text(viewModel.selectedProjectRoot)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                        Spacer()
                        StatusChip(text: workspaceReadinessLabel, tone: workspaceReadinessTone)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                        MetricTile(title: "Context", value: contextStatusLabel, detail: "SOMA/profile/agents", tone: hasAnyContextFile ? .good : .warning)
                        MetricTile(title: "Health", value: activeHealthLabel, detail: "project-local warnings", tone: activeHealthTone)
                        MetricTile(title: "Graph", value: graphStatusLabel, detail: "optional packet context", tone: graphTone)
                        MetricTile(title: "Usage", value: "\(viewModel.projectUsageCount(viewModel.selectedProjectRoot))", detail: "workspace opens", tone: .info)
                        MetricTile(title: "Last used", value: viewModel.projectLastUsedLabel(viewModel.selectedProjectRoot), detail: "local app history", tone: .neutral)
                        MetricTile(title: "Activity", value: "\(projectLogCount)", detail: "loaded log entries", tone: projectLogCount > 0 ? .info : .neutral)
                    }

                    HStack(spacing: 8) {
                        Button {
                            selectedRoute = .relay
                        } label: {
                            Label("Prepare Packet", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            selectedRoute = .projectHealth
                        } label: {
                            Label("Setup Context", systemImage: "doc.badge.gearshape")
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            viewModel.clearProjectRoot()
                        } label: {
                            Label("Close Workspace", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var recentProjectsPanel: some View {
        SomaPanel(title: "Recent Projects", subtitle: "Open a previous workspace without deleting anything from disk.", icon: "clock.arrow.circlepath", tone: .neutral) {
            if viewModel.recentProjectRoots.isEmpty {
                Text("No recent projects yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("\(viewModel.recentProjectRoots.count) workspace\(viewModel.recentProjectRoots.count == 1 ? "" : "s")")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Only one active workspace at a time")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    ForEach(viewModel.recentProjectRoots, id: \.self) { root in
                        projectRow(root)
                    }
                }
            }
        }
    }

    private func projectRow(_ root: String) -> some View {
        let isActive = root == viewModel.selectedProjectRoot
        let warningCount = viewModel.projectHealthWarningCount(for: root)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "folder")
                    .foregroundColor(isActive ? .green : .blue)
                    .frame(width: 18)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text((root as NSString).lastPathComponent)
                            .font(.headline)
                        if isActive {
                            StatusChip(text: "Active", tone: .good)
                        }
                    }
                    Text(root)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                if isActive {
                    Button("Opened") {
                        selectedRoute = .relay
                    }
                    .disabled(true)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Open") {
                        viewModel.selectProjectRoot(root)
                        selectedRoute = .relay
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                compactProjectFact(title: "Context", value: viewModel.projectContextSummary(for: root), tone: viewModel.projectContextSummary(for: root).contains("missing") ? .warning : .good)
                compactProjectFact(title: "Agents", value: viewModel.projectAgentsSummary(for: root), tone: viewModel.projectAgentsSummary(for: root).contains("Not") ? .neutral : .good)
                compactProjectFact(title: "Graph", value: viewModel.projectGraphSummary(for: root), tone: graphTone(for: root))
                compactProjectFact(title: "Health", value: warningCount == 0 ? "OK" : "\(warningCount) warning\(warningCount == 1 ? "" : "s")", tone: warningCount == 0 ? .good : .warning)
                compactProjectFact(title: "Last used", value: viewModel.projectLastUsedLabel(root), tone: .neutral)
                compactProjectFact(title: "Usage", value: "\(viewModel.projectUsageCount(root)) opens", tone: .info)
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.selectProjectRoot(root)
                    selectedRoute = .relay
                } label: {
                    Label("Prepare Packet", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    viewModel.selectProjectRoot(root)
                    selectedRoute = .projectHealth
                } label: {
                    Label("Setup Context", systemImage: "doc.badge.gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(role: .destructive) {
                    viewModel.removeRecentProjectRoot(root)
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Remove this project from Soma's recent list without deleting files from disk.")
            }
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor).opacity(isActive ? 0.75 : 0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? Color.green.opacity(0.25) : Color.secondary.opacity(0.08)))
    }

    private func compactProjectFact(title: String, value: String, tone: SomaStatusTone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.bold())
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .foregroundColor(tone.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(tone.color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var workspaceModelPanel: some View {
        SomaPanel(title: "Workspace Model", subtitle: "Near-version product rules from the UI/UX plan.", icon: "rectangle.3.group", tone: .info) {
            StepChecklist(steps: [
                WorkflowStep(id: "open", title: "1. Open project", detail: "A project folder becomes the active workspace.", tone: viewModel.selectedProjectRoot.isEmpty ? .warning : .good),
                WorkflowStep(id: "prepare", title: "2. Prepare Packet", detail: "Packet generation runs inside the opened project.", tone: .info),
                WorkflowStep(id: "settings", title: "3. Global defaults", detail: "Global settings are defaults/fallbacks. Local AI role/model selection stays global for v1.", tone: .neutral),
                WorkflowStep(id: "health", title: "4. Project support", detail: "Health, graph, usage, and activity explain the workspace without owning the main flow.", tone: .neutral),
            ])
        }
    }

    private var projectLocalContextPanel: some View {
        SomaPanel(title: "Project-Local Context", subtitle: "Detected files; setup actions remain project-scoped.", icon: "doc.badge.gearshape", tone: hasAnyContextFile ? .good : .warning) {
            SomaKeyValueRow(label: "SOMA.md", value: fileExists("SOMA.md") ? "Recommended" : "Missing", tone: fileExists("SOMA.md") ? .good : .warning)
            SomaKeyValueRow(label: "AGENTS.md", value: fileExists("AGENTS.md") ? "Detected" : "Optional", tone: fileExists("AGENTS.md") ? .good : .neutral)
            SomaKeyValueRow(label: "GEMINI.md", value: fileExists("GEMINI.md") ? "Detected" : "Optional", tone: fileExists("GEMINI.md") ? .good : .neutral)
            SomaKeyValueRow(label: ".soma/project.json", value: fileExists(".soma/project.json") ? "Detected" : "Not created", tone: fileExists(".soma/project.json") ? .good : .neutral)
            Text("Project setup should write these files into the selected project. Global settings remain app defaults/fallbacks, not hidden workspace state.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var projectSetupRecommendationsPanel: some View {
        SomaPanel(title: "Setup Recommendations", subtitle: "Near-version guidance only; full profile generation comes later.", icon: "lightbulb", tone: setupRecommendations.isEmpty ? .good : .warning) {
            if viewModel.selectedProjectRoot.isEmpty {
                StatusBanner(title: "No workspace open", detail: "Choose a project to see project-local setup recommendations.", tone: .warning)
            } else if setupRecommendations.isEmpty {
                StatusBanner(title: "Workspace context looks usable", detail: "The project has at least one local context/profile file. Prepare Packet can run in this workspace.", tone: .good)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(setupRecommendations, id: \.self) { recommendation in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundColor(.orange)
                                .padding(.top, 6)
                            Text(recommendation)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var hasAnyContextFile: Bool {
        fileExists("SOMA.md") || fileExists("AGENTS.md") || fileExists("GEMINI.md") || fileExists(".soma/project.json")
    }

    private var contextStatusLabel: String { hasAnyContextFile ? "Loaded" : "Needs setup" }
    private var graphStatusLabel: String { viewModel.graphAvailable ? (viewModel.graphStale ? "Stale" : "Fresh") : "None" }
    private var graphTone: SomaStatusTone { viewModel.graphAvailable ? (viewModel.graphStale ? .warning : .good) : .neutral }
    private var workspaceReadinessLabel: String { hasAnyContextFile ? "Workspace Open" : "Needs Setup" }
    private var workspaceReadinessTone: SomaStatusTone { hasAnyContextFile ? .good : .warning }
    private var activeHealthLabel: String {
        let warnings = viewModel.projectHealthWarningCount(for: viewModel.selectedProjectRoot)
        return warnings == 0 ? "OK" : "\(warnings) warning\(warnings == 1 ? "" : "s")"
    }
    private var activeHealthTone: SomaStatusTone { viewModel.projectHealthWarningCount(for: viewModel.selectedProjectRoot) == 0 ? .good : .warning }
    private var setupRecommendations: [String] { viewModel.selectedProjectRoot.isEmpty ? [] : viewModel.projectSetupRecommendations(for: viewModel.selectedProjectRoot) }
    private var projectLogCount: Int { viewModel.logEntries.count }

    private func graphTone(for root: String) -> SomaStatusTone {
        let summary = viewModel.projectGraphSummary(for: root)
        if summary == "Fresh" || summary == "Found" { return .good }
        if summary == "Stale" { return .warning }
        return .neutral
    }

    private func fileExists(_ relativePath: String) -> Bool {
        viewModel.projectFileExists(relativePath, in: viewModel.selectedProjectRoot)
    }

    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project Root"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        viewModel.selectProjectRoot(path)
        selectedRoute = .relay
    }
}
