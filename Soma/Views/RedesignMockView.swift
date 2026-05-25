#if DEBUG
import SwiftUI

struct RedesignMockView: View {
    @State private var selectedMock = "Prepare Packet"
    private let mockScreens = ["Prepare Packet", "Local AI", "Logs", "System Status"]

    var body: some View {
        SomaPage {
            WorkflowHeader(
                title: "UI Redesign Mock",
                subtitle: "Static reference for the new Soma layout system: compact runtime chrome, clearer workbench hierarchy, readable observer screens, and stable macOS spacing.",
                icon: "sparkles.rectangle.stack",
                tone: .info,
                trailing: AnyView(screenPicker)
            )

            mockRuntimeBar

            switch selectedMock {
            case "Local AI":
                localAIMock
            case "Logs":
                logsMock
            case "System Status":
                systemStatusMock
            default:
                preparePacketMock
            }
        }
    }

    private var screenPicker: some View {
        Picker("Mock Screen", selection: $selectedMock) {
            ForEach(mockScreens, id: \.self) { screen in
                Text(screen).tag(screen)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 440)
    }

    private var mockRuntimeBar: some View {
        SomaPanel(title: "Visible Runtime Bar", subtitle: "All runtime controls remain visible, but each pill has one state and one action.", icon: "slider.horizontal.3", tone: .neutral) {
            HStack(spacing: 8) {
                mockRuntimePill("Project", "UnityTestForNexus", "folder.fill", .info, "Choose")
                mockRuntimePill("MCP", "Offline", "server.rack", .danger, "Start")
                mockRuntimePill("Local AI", "gemma4:e4b", "cpu", .warning, "Load")
                mockRuntimePill("Graph", "Fresh", "point.3.connected.trianglepath.dotted", .good, "Update")
                mockRuntimePill("Unity", "Skipped", "circle.grid.3x3.fill", .neutral, nil)
            }
        }
    }

    private func mockRuntimePill(_ title: String, _ value: String, _ icon: String, _ tone: SomaStatusTone, _ action: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(tone.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.caption.bold())
                    .foregroundColor(tone.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let action {
                Button(action) {}
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 210)
        .background(SomaDesign.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
    }

    private var preparePacketMock: some View {
        SomaSplitWorkbench {
            SomaPanel(title: "Task", subtitle: "The primary action stays close to the input. Progress and blockers are explicit.", icon: "doc.text.magnifyingglass", tone: .info) {
                StatusBanner(title: "Ready to prepare a packet", detail: "Describe a bug, feature, failing test, or review target. Soma will gather focused project evidence.", tone: .info)
                Text("Fix the flaky integration test around Unity scene loading and explain which files matter.")
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
                    .background(SomaDesign.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: SomaDesign.radius))
                HStack {
                    Button("Clear") {}
                        .buttonStyle(.bordered)
                    Spacer()
                    Button {
                    } label: {
                        Label("Prepare Packet", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            SomaPanel(title: "Packet Result", subtitle: "Copy actions, warnings, evidence, and metrics are visible after success.", icon: "checkmark.circle.fill", tone: .good) {
                HStack(spacing: 10) {
                    MetricTile(title: "Evidence", value: "8", detail: "files and traces", tone: .info)
                    MetricTile(title: "Packet", value: "12.1k", detail: "estimated tokens", tone: .neutral)
                    MetricTile(title: "Saved", value: "19.4M", detail: "avoided output", tone: .good)
                }
                StatusBanner(title: "Review warnings", detail: "Runtime/Tests.meta was referenced but not selected. Confirm whether it matters before sending.", tone: .warning)
            }
        } secondary: {
            SomaPanel(title: "Workflow", subtitle: "Steps remain readable at narrow widths.", icon: "list.bullet.rectangle", tone: .neutral) {
                StepChecklist(steps: [
                    WorkflowStep(id: "project", title: "1. Project", detail: "UnityTestForNexus", tone: .good),
                    WorkflowStep(id: "task", title: "2. Task", detail: "Task text received", tone: .good),
                    WorkflowStep(id: "evidence", title: "3. Evidence", detail: "8 items selected", tone: .good),
                    WorkflowStep(id: "review", title: "4. Review", detail: "Ready to copy", tone: .good),
                ])
            }
            SomaPanel(title: "Next Actions", subtitle: nil, icon: "arrow.right.circle", tone: .info) {
                StatusChip(text: "Copy packet", tone: .good, icon: "doc.on.doc")
                StatusChip(text: "Open evidence", tone: .info, icon: "folder")
                StatusChip(text: "Inspect audit", tone: .neutral, icon: "number")
            }
        }
    }

    private var localAIMock: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
            mockModelRole("Scout", "Direct file exploration chat", "gemma4:e4b", .warning)
            mockModelRole("Planner / Ranker", "Evidence planning and ranking", "gemma4:e4b", .good)
            mockModelRole("Analyst", "Deeper packet analysis", "qwen3-coder:30b", .neutral)
            mockModelRole("Translator", "Prompt language optimization", "Auto", .info)
        }
    }

    private func mockModelRole(_ title: String, _ subtitle: String, _ model: String, _ tone: SomaStatusTone) -> some View {
        SomaPanel(title: title, subtitle: subtitle, icon: "cpu", tone: tone) {
            SomaKeyValueRow(label: "Model", value: model, tone: tone)
            SomaKeyValueRow(label: "Installed", value: model == "Auto" ? "Fallback" : "Yes", tone: .good)
            SomaKeyValueRow(label: "Loaded", value: title == "Scout" ? "Not loaded" : "On demand", tone: title == "Scout" ? .warning : .neutral)
            HStack {
                Button("Choose") {}
                    .buttonStyle(.bordered)
                Button("Load") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(model == "Auto")
            }
        }
    }

    private var logsMock: some View {
        SomaSplitWorkbench {
            SomaPanel(title: "Logs", subtitle: "Filters are separated from the title so the header cannot collapse.", icon: "chart.bar.doc.horizontal", tone: .info) {
                HStack(spacing: 10) {
                    StatusChip(text: "2 calls", tone: .info)
                    StatusChip(text: "22,553 tokens", tone: .warning)
                    StatusChip(text: "1 Local AI", tone: .good)
                    Spacer()
                    TextField("Run/task", text: .constant(""))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                mockLogRow("client_config_verify", "codex", "14:24:26", .good)
                mockLogRow("tools/list", "mcp_response · 2.281 tok", "14:24:15", .good)
                mockLogRow("local_model_call", "gemma4:e4b · Scout · translation", "14:23:40", .warning)
            }
        } secondary: {
            SomaPanel(title: "Today", subtitle: "Readable summary first, dense rows second.", icon: "calendar", tone: .neutral) {
                MetricTile(title: "Tool Calls", value: "2", detail: "successful today", tone: .info)
                MetricTile(title: "Local AI", value: "1", detail: "gemma4:e4b", tone: .good)
                StatusBanner(title: "Latest trace degraded", detail: "Missing Runtime/Tests.meta. Evidence can still be copied.", tone: .warning)
            }
        }
    }

    private func mockLogRow(_ title: String, _ detail: String, _ time: String, _ tone: SomaStatusTone) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tone.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.caption, design: .monospaced).bold())
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(time)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 7)
        .overlay(Divider(), alignment: .bottom)
    }

    private var systemStatusMock: some View {
        SomaSplitWorkbench {
            SomaPanel(title: "Attention", subtitle: "The first layer says what needs action.", icon: "exclamationmark.triangle.fill", tone: .warning) {
                StatusBanner(title: "MCP is offline", detail: "Prepare Packet still works. Start MCP only when Codex, Gemini, or Hermes needs live tools.", tone: .info)
                StatusBanner(title: "Graph is fresh", detail: "No graph action needed for the selected project.", tone: .good)
            }
            SomaPanel(title: "Agent Readiness", subtitle: "Dense diagnostics remain available below the summary.", icon: "checklist.checked", tone: .info) {
                HStack(spacing: 10) {
                    MetricTile(title: "Codex", value: "OK", detail: "config verified", tone: .good)
                    MetricTile(title: "Gemini", value: "OK", detail: "config verified", tone: .good)
                    MetricTile(title: "Hermes", value: "OK", detail: "config verified", tone: .good)
                }
            }
        } secondary: {
            SomaPanel(title: "Runtime", subtitle: nil, icon: "gauge.with.dots.needle.67percent", tone: .neutral) {
                SomaKeyValueRow(label: "Project", value: "UnityTestForNexus", tone: .info)
                SomaKeyValueRow(label: "MCP", value: "Offline", tone: .danger)
                SomaKeyValueRow(label: "Local AI", value: "gemma4:e4b", tone: .warning)
                SomaKeyValueRow(label: "Graph", value: "Fresh", tone: .good)
            }
        }
    }
}
#endif
