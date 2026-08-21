import AppKit
import SwiftUI

nonisolated struct ToolStatusResponse: Codable, Sendable {
    let status: String?
    let tools: [ExtensionToolStatus]
}

nonisolated struct ExtensionToolStatus: Codable, Identifiable, Sendable {
    var id: String { tool_id }
    let tool_id: String
    let name: String?
    let kind: String?
    let detail: String?
    let installed_version: String?
    let latest_version: String?
    let up_to_date: Bool?
    let status: String?
    let updated: Bool?
    let before_version: String?
    let output: String?
    let issues: [String]?
    let clients: [ExtensionClientStatus]?
    let projects: [ExtensionProjectStatus]?
    let smoke: ExtensionSmokeStatus?
    let restart_needed: [String]?
}

nonisolated struct ExtensionClientStatus: Codable, Identifiable, Sendable {
    var id: String { "\(client):\(config_path ?? ""):\(project_root ?? "")" }
    let client: String
    let status: String?
    let summary: String?
    let config_path: String?
    let project_root: String?
    let issues: [String]?
    let restart_needed: Bool?
}

nonisolated struct ExtensionProjectStatus: Codable, Identifiable, Sendable {
    var id: String { project_root }
    let project_root: String
}

nonisolated struct ExtensionSmokeStatus: Codable, Sendable {
    let status: String?
    let summary: String?
}

struct ToolVersionsView: View {
    @ObservedObject var viewModel: SomaViewModel
    @State private var tools: [ExtensionToolStatus] = []
    @State private var clientReport: [ExtensionClientStatus] = []
    @State private var busy = false
    @State private var status = ""
    @State private var restartStatus = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(tools) { tool in
                    ToolVersionRow(
                        tool: tool,
                        busy: busy,
                        update: { await update(tool.tool_id) }
                    )
                }
                if !clientReport.isEmpty {
                    clientStatus
                }
                restartButtons
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .task { await refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Global extensions update first, then Soma verifies Codex, Gemini, Antigravity, Claude, and Hermes configs across known projects."
            )
            .font(.callout)
            .foregroundColor(.secondary)
            HStack(spacing: 10) {
                Button("Check for Updates") { Task { await refresh() } }
                    .disabled(busy)
                Button("Verify Clients") { Task { await verifyClients(sync: false) } }
                    .disabled(busy)
                Button("Sync Clients") { Task { await verifyClients(sync: true) } }
                    .disabled(busy)
                Button("Setup Project Memory") { Task { await setupProjectMemory() } }
                    .disabled(busy || viewModel.selectedProjectRoot.isEmpty)
                if busy {
                    ProgressView().controlSize(.small)
                }
                Text(status).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            }
        }
    }

    private var clientStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Client verification").font(.headline)
            ForEach(clientReport.prefix(16)) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(item.status == "ok" ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.client.capitalized): \(item.summary ?? item.status ?? "unknown")")
                            .font(.caption)
                        Text(item.config_path ?? "No config path")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let issues = item.issues, !issues.isEmpty {
                            Text(issues.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var restartButtons: some View {
        let clients = restartClients
        return Group {
            if !clients.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Restart required").font(.headline)
                    HStack(spacing: 8) {
                        ForEach(clients, id: \.self) { client in
                            Button("Restart \(client.capitalized)") {
                                Task { await restart(client) }
                            }
                        }
                    }
                    if !restartStatus.isEmpty {
                        Text(restartStatus).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
            }
        }
    }

    private var restartClients: [String] {
        let fromTools = tools.flatMap { $0.restart_needed ?? [] }
        let fromClients = clientReport.compactMap { ($0.restart_needed == true) ? $0.client : nil }
        return Array(Set(fromTools + fromClients))
            .filter { ["codex", "antigravity", "claude"].contains($0.lowercased()) }
            .sorted()
    }

    private func refresh() async {
        busy = true
        defer { busy = false }
        do {
            let data = try await viewModel.runSomaHelper(args: ["--tool-status-json"])
            let report = try JSONDecoder().decode(ToolStatusResponse.self, from: data)
            await MainActor.run {
                tools = report.tools
                status = "Checked \(tools.count) tools."
            }
        } catch {
            await MainActor.run { status = "Tool check failed: \(error.localizedDescription)" }
        }
    }

    private func update(_ toolId: String) async {
        busy = true
        defer { busy = false }
        do {
            let data = try await viewModel.runSomaHelper(args: projectArgs(["--update-tool", toolId]))
            let report = try JSONDecoder().decode(ExtensionToolStatus.self, from: data)
            await MainActor.run {
                tools = tools.map { $0.tool_id == toolId ? report : $0 }
                clientReport = report.clients ?? clientReport
                let issues = report.issues?.isEmpty == false ? " Issues: \(report.issues!.joined(separator: ", "))." : ""
                status = "\(report.name ?? toolId) \(report.status ?? "unknown").\(issues)"
            }
        } catch {
            await MainActor.run { status = "Update failed: \(error.localizedDescription)" }
        }
    }

    private func verifyClients(sync: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let flag = sync ? "--sync-ai-clients" : "--verify-ai-clients-json"
            let data = try await viewModel.runSomaHelper(args: projectArgs([flag]))
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rawClients = try JSONSerialization.data(withJSONObject: decoded?["clients"] ?? [])
            let clients = try JSONDecoder().decode([ExtensionClientStatus].self, from: rawClients)
            await MainActor.run {
                clientReport = clients
                status = "\(sync ? "Synced" : "Verified") \(clients.count) client configs."
            }
        } catch {
            await MainActor.run { status = "Client verification failed: \(error.localizedDescription)" }
        }
    }

    private func setupProjectMemory() async {
        busy = true
        defer { busy = false }
        do {
            let data = try await viewModel.runSomaHelper(args: projectArgs(["--setup-memory-tools"]))
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            await refresh()
            await MainActor.run {
                let toolIssues = (decoded?["issues"] as? [String]) ?? []
                let restart = (decoded?["restart_needed"] as? [String]) ?? []
                status =
                    "Project memory \(decoded?["status"] as? String ?? "unknown"): \(toolIssues.count) issues, restart \(restart.joined(separator: ", "))."
            }
        } catch {
            await MainActor.run { status = "Project memory setup failed: \(error.localizedDescription)" }
        }
    }

    private func projectArgs(_ base: [String]) -> [String] {
        var args = base
        if !viewModel.selectedProjectRoot.isEmpty {
            args += ["--project-root", viewModel.selectedProjectRoot]
        }
        for root in viewModel.recentProjectRoots where root != viewModel.selectedProjectRoot {
            args += ["--recent-project-root", root]
        }
        return args
    }

    private func restart(_ client: String) async {
        let app = ["codex": "Codex", "antigravity": "Antigravity", "claude": "Claude"][client.lowercased()] ?? client.capitalized
        await MainActor.run { restartStatus = "Restarting \(app)..." }
        let quit = Process()
        quit.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        quit.arguments = ["-e", "tell application \"\(app)\" to quit"]
        try? quit.run()
        quit.waitUntilExit()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", app]
        do {
            try open.run()
            open.waitUntilExit()
            await MainActor.run { restartStatus = "\(app) restart requested." }
        } catch {
            await MainActor.run { restartStatus = "\(app) restart failed: \(error.localizedDescription)" }
        }
    }
}

private struct ToolVersionRow: View {
    let tool: ExtensionToolStatus
    let busy: Bool
    let update: () async -> Void

    private var upToDate: Bool { tool.up_to_date == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(tool.name ?? tool.tool_id).font(.headline)
                        Text(tool.kind ?? "Tool")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Text(tool.detail ?? "").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                versions
            }

            HStack(spacing: 10) {
                stateLabel
                Spacer()
                Button("Update") { Task { await update() } }
                    .disabled(busy || upToDate || tool.latest_version == nil)
            }

            if let issues = tool.issues, !issues.isEmpty {
                Text(issues.joined(separator: ", "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            if let smoke = tool.smoke {
                Text("Smoke: \(smoke.status ?? "unknown") \(smoke.summary ?? "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let output = tool.output, !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var versions: some View {
        HStack(spacing: 8) {
            chip("current", tool.installed_version ?? "-")
            Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
            chip("latest", tool.latest_version ?? "-")
        }
    }

    private func chip(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.system(.callout, design: .monospaced).weight(.semibold))
        }
    }

    @ViewBuilder private var stateLabel: some View {
        if upToDate {
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundColor(.green)
        } else if tool.installed_version != nil && tool.latest_version != nil {
            Label("Update available", systemImage: "arrow.up.circle.fill")
                .font(.caption).foregroundColor(.orange)
        } else {
            Label(tool.status ?? "Unknown", systemImage: "questionmark.circle")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}
