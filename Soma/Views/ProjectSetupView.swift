import AppKit
import SwiftUI

struct ProjectSetupView: View {
    @ObservedObject var viewModel: SomaViewModel
    @Binding var selectedRoute: AppRoute?

    var body: some View {
        SomaPage(maxWidth: 1120) {
            WorkflowHeader(
                title: "Project Setup",
                subtitle: "A calm readiness check for packet mode. Optional systems are not blockers.",
                icon: "checklist",
                tone: readinessTone,
                trailing: AnyView(chooseButton)
            )

            if viewModel.selectedProjectRoot.isEmpty {
                EmptyStateView(
                    icon: "folder.badge.plus",
                    title: "Choose a project",
                    subtitle: "Soma needs one local project root before it can prepare useful packets.",
                    actionTitle: "Choose Project",
                    actionIcon: "folder",
                    action: chooseProjectRoot
                )
            } else {
                SomaSplitWorkbench {
                    readinessPanel
                    contextPanel
                } secondary: {
                    optionalPanel
                    usagePanel
                }
            }
        }
        .onAppear {
            viewModel.refreshSomaStatus()
            viewModel.hydratePacketHistoryIfNeeded()
        }
    }

    private var chooseButton: some View {
        Button {
            chooseProjectRoot()
        } label: {
            Label(viewModel.selectedProjectRoot.isEmpty ? "Choose Project" : "Change Project", systemImage: "folder")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private var readinessPanel: some View {
        SomaPanel(title: readinessTitle, subtitle: readinessSubtitle, icon: readinessTone.symbol, tone: readinessTone) {
            StepChecklist(steps: [
                WorkflowStep(id: "project", title: "Project selected", detail: projectName, tone: .good),
                WorkflowStep(id: "context", title: hasCoreContext ? "Context ready" : "Add SOMA.md", detail: hasCoreContext ? "Project-specific context is visible." : "Recommended for stronger packets.", tone: hasCoreContext ? .good : .warning),
                WorkflowStep(id: "packet", title: "Packet mode", detail: "Ready to run without MCP.", tone: .good),
                WorkflowStep(id: "feedback", title: "Feedback loop", detail: "\(projectPackets.count) real packet run\(projectPackets.count == 1 ? "" : "s").", tone: projectPackets.isEmpty ? .neutral : .info),
            ])

            HStack(spacing: 8) {
                Button {
                    selectedRoute = .relay
                } label: {
                    Label("Prepare Packet", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    selectedRoute = .packets
                } label: {
                    Label("View Packets", systemImage: "tray.full")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }

    private var contextPanel: some View {
        SomaPanel(title: "Context Files", subtitle: "Only SOMA.md is recommended for comfort reset. Agent files are optional.", icon: "doc.text", tone: hasCoreContext ? .good : .warning) {
            fileRow("SOMA.md", required: true)
            fileRow(".soma/project.json", required: false)
            fileRow("AGENTS.md", required: false)
            fileRow("GEMINI.md", required: false)

            StatusBanner(
                title: hasCoreContext ? "Setup is enough for packet mode" : "Recommended next step",
                detail: hasCoreContext ? "Prepare Packet can use project-local context now." : "Add SOMA.md with purpose, important paths, and commands. Everything else can wait.",
                tone: hasCoreContext ? .good : .warning
            )
        }
    }

    private var optionalPanel: some View {
        SomaPanel(title: "Optional Systems", subtitle: "Useful later, not required to start.", icon: "slider.horizontal.3", tone: .neutral) {
            SomaKeyValueRow(label: "MCP", value: viewModel.somaServerRunning ? "Online" : "Optional", tone: viewModel.somaServerRunning ? .good : .neutral)
            SomaKeyValueRow(label: "Graphify", value: graphLabel, tone: graphTone)
            SomaKeyValueRow(label: "Graph storage", value: graphStorageLabel, tone: graphTone)
            SomaKeyValueRow(label: "Graph scope", value: graphScopeLabel, tone: .neutral)
            SomaKeyValueRow(label: "Graphify tool", value: viewModel.graphifyVersion, tone: viewModel.graphToolUpToDate == false ? .warning : .neutral)
            if let buildVersion = viewModel.graphBuildVersion, !buildVersion.isEmpty {
                SomaKeyValueRow(label: "Graph built with", value: buildVersion, tone: buildVersion == viewModel.graphifyVersion ? .neutral : .warning)
            }
            if let nodeCount = viewModel.graphNodeCount, let edgeCount = viewModel.graphEdgeCount {
                SomaKeyValueRow(label: "Graph size", value: "\(nodeCount) nodes / \(edgeCount) edges", tone: .info)
            }
            if viewModel.graphDegraded {
                StatusBanner(
                    title: "Graph degraded",
                    detail: viewModel.graphDegradedReason ?? "Diagnostics found a graph quality issue. Soma will skip graph hints until it is refreshed.",
                    tone: .warning
                )
            }
            if viewModel.graphLegacyAvailable {
                StatusBanner(
                    title: viewModel.graphManagedAvailable ? "Legacy graph still exists" : "Legacy graph found",
                    detail: viewModel.graphManagedAvailable ? "Soma will use managed storage first. The old project folder is retained until you remove it." : "Move it into Soma storage to keep the project root clean.",
                    tone: viewModel.graphManagedAvailable ? .info : .warning
                )
            }
            HStack(spacing: 8) {
                if viewModel.graphLegacyAvailable && !viewModel.graphManagedAvailable {
                    Button {
                        viewModel.migrateGraphifyGraph()
                    } label: {
                        Label("Move to Soma Storage", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    if viewModel.graphManagedAvailable {
                        viewModel.refreshManagedGraphifyGraph()
                    } else {
                        viewModel.initializeGraphify()
                    }
                } label: {
                    Label(viewModel.graphManagedAvailable ? "Update Graph" : "Build Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.bordered)
                if viewModel.graphAvailable {
                    Button {
                        viewModel.openGraphifyReport()
                    } label: {
                        Label("Open Report", systemImage: "doc.richtext")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            .disabled(viewModel.graphifyBusy || viewModel.selectedProjectRoot.isEmpty)
            SomaKeyValueRow(label: "Nexus / Unity", value: viewModel.nexusConnected ? "Connected" : "Optional", tone: viewModel.nexusConnected ? .info : .neutral)
            SomaKeyValueRow(label: "Local AI", value: "Optional", tone: .neutral)
            Button {
                selectedRoute = .diagnostics
            } label: {
                Label("Open Diagnostics", systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var usagePanel: some View {
        SomaPanel(title: "Usage", subtitle: "Real packet history from the simplified UI.", icon: "chart.bar.doc.horizontal", tone: projectPackets.isEmpty ? .neutral : .info) {
            SomaKeyValueRow(label: "Workspace opens", value: "\(viewModel.projectUsageCount(viewModel.selectedProjectRoot))", tone: .info)
            SomaKeyValueRow(label: "Packet runs", value: "\(projectPackets.count)", tone: projectPackets.isEmpty ? .neutral : .info)
            SomaKeyValueRow(label: "Last packet", value: viewModel.latestPacketFeedbackLabel(), tone: viewModel.latestPacketFeedbackTone())
        }
    }

    private func fileRow(_ path: String, required: Bool) -> some View {
        let exists = viewModel.projectFileExists(path, in: viewModel.selectedProjectRoot)
        return SomaKeyValueRow(label: path, value: exists ? "Found" : (required ? "Missing" : "Optional"), tone: exists ? .good : (required ? .warning : .neutral))
    }

    private var projectPackets: [PacketHistoryItem] {
        viewModel.packetsForSelectedProject()
    }

    private var projectName: String {
        viewModel.selectedProjectRoot.isEmpty ? "No project" : (viewModel.selectedProjectRoot as NSString).lastPathComponent
    }

    private var hasCoreContext: Bool {
        viewModel.projectFileExists("SOMA.md", in: viewModel.selectedProjectRoot) || viewModel.projectFileExists(".soma/project.json", in: viewModel.selectedProjectRoot)
    }

    private var readinessTitle: String {
        hasCoreContext ? "Ready for packet mode" : "Needs one context file"
    }

    private var readinessSubtitle: String {
        hasCoreContext ? "You can start with Prepare Packet." : "This is not a hard failure. Add SOMA.md when you want better project-specific packets."
    }

    private var readinessTone: SomaStatusTone {
        if viewModel.selectedProjectRoot.isEmpty { return .warning }
        return hasCoreContext ? .good : .warning
    }

    private var graphLabel: String {
        if viewModel.graphDegraded { return "Degraded optional" }
        if viewModel.graphAvailable { return viewModel.graphStale ? "Stale optional" : "Ready optional" }
        return "Optional"
    }

    private var graphStorageLabel: String {
        switch viewModel.graphStorageKind {
        case "managed":
            return "Managed"
        case "legacy":
            return "Legacy"
        default:
            return "Missing"
        }
    }

    private var graphScopeLabel: String {
        viewModel.graphScope == "unity_assets" ? "Unity Assets only" : "Project root"
    }

    private var graphTone: SomaStatusTone {
        if viewModel.graphDegraded { return .warning }
        if viewModel.graphAvailable && !viewModel.graphStale { return .good }
        if viewModel.graphAvailable && viewModel.graphStale { return .warning }
        return .neutral
    }

    private func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project Root"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        viewModel.selectProjectRoot(path)
    }
}
