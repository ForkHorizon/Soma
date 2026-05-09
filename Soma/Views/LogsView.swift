import SwiftUI

struct LogsView: View {
    @ObservedObject var viewModel: SomaViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logs & Analytics")
                        .font(.title2.bold())
                    Text("Today's tool calls from \(logFilePath)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    viewModel.loadStructuredLogs()
                } label: {
                    if viewModel.logsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.logsLoading)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            if viewModel.logEntries.isEmpty && !viewModel.logsLoading {
                emptyState
            } else {
                HSplitView {
                    // Left: per-tool stats
                    toolStatsPanel
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

                    // Right: log entry list
                    logEntryList
                }
            }
        }
        .onAppear { viewModel.loadStructuredLogs() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No logs for today")
                .font(.title3)
            Text("Start the Soma MCP server and call some tools.\nLogs are saved to \(logFilePath)")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tool stats panel

    private var toolStatsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tool Stats Today")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()

            // Summary row
            let totalCalls = viewModel.toolStats.reduce(0) { $0 + $1.calls }
            let totalTok = viewModel.toolStats.reduce(0) { $0 + $1.totalTokens }
            let totalErr = viewModel.toolStats.reduce(0) { $0 + $1.errors }

            HStack(spacing: 12) {
                statBadge(value: "\(totalCalls)", label: "Calls", color: .blue)
                statBadge(value: "\(totalTok)", label: "Tokens", color: .purple)
                if totalErr > 0 {
                    statBadge(value: "\(totalErr)", label: "Errors", color: .red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.toolStats) { stat in
                        toolStatRow(stat)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private func statBadge(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.callout, design: .monospaced).bold())
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 48)
    }

    private func toolStatRow(_ stat: SomaToolStat) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.id)
                    .font(.caption.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(stat.calls) calls")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if stat.avgDuration > 0 {
                        Text("\(Int(stat.avgDuration))ms avg")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            if stat.errors > 0 {
                Text("\(stat.errors) err")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Log entry list

    private var logEntryList: some View {
        List(viewModel.logEntries) { entry in
            logRow(entry)
                .listRowSeparator(.visible)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        }
        .listStyle(.plain)
    }

    private func logRow(_ entry: SomaLogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Status dot
            Circle()
                .fill(statusColor(entry))
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.displayName)
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(entry.isError ? .red : .primary)
                    Spacer()
                    Text(entry.shortTime)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 10) {
                    Text(entry.event)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if let dur = entry.duration_ms, dur > 0 {
                        Text("\(Int(dur))ms")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if entry.totalTokens > 0 {
                        Text("\(entry.totalTokens) tok")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.purple.opacity(0.8))
                    }
                }
                if let err = entry.error {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func statusColor(_ entry: SomaLogEntry) -> Color {
        if entry.isError { return .red }
        if entry.isDegraded { return .orange }
        return .green
    }

    private var logFilePath: String {
        let dateStr = DateFormatter.somaDate.string(from: Date())
        return "~/.soma/logs/soma_\(dateStr).jsonl"
    }
}
