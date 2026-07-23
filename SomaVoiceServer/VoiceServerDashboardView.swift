import SwiftUI

struct VoiceServerDashboardView: View {
    @ObservedObject var monitor: VoiceServerMonitor

    private let idleOptions = [
        (0, "After each request"),
        (300, "5 minutes"),
        (600, "10 minutes"),
        (900, "15 minutes"),
        (1800, "30 minutes"),
        (3600, "1 hour"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statusGrid
            queueSection
            settingsSection
            footerActions
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: monitor.serverOnline ? "server.rack" : "server.rack")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Soma Voice Server")
                    .font(.title3.weight(.semibold))
                Text(monitor.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if monitor.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            row("Server", monitor.serverOnline ? "Online" : "Offline", statusColor)
            row("URL", monitor.serverURL, .secondary)
            row("Engine", monitor.status?.backend.active_engine ?? monitor.status?.server.default_engine ?? "Whisper", .secondary)
            row("Backend", monitor.backendRunning ? "Running" : "Stopped", monitor.backendRunning ? .green : .secondary)
            row("Loaded in RAM", monitor.modelLoaded ? "Yes" : "No", monitor.modelLoaded ? .green : .secondary)
            row("Uptime", uptimeText, .secondary)
        }
        .font(.callout)
    }

    private func row(_ title: String, _ value: String, _ color: Color) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Queue", systemImage: "list.bullet.rectangle")
                .font(.headline)
            HStack(spacing: 12) {
                metric("Queued", monitor.status?.queue.queued ?? 0)
                metric("Running", monitor.status?.queue.running ?? 0)
                metric("Done", monitor.status?.queue.done ?? 0)
                metric("Failed", monitor.status?.queue.failed ?? 0)
            }
            if let job = monitor.status?.queue.active_job {
                Text("Working now: \(job.engine) · \(job.job_id.prefix(8)) · \(job.status)")
                    .font(.callout)
                    .foregroundStyle(.primary)
            } else {
                Text("No active job")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Settings", systemImage: "slider.horizontal.3")
                .font(.headline)
            Picker("Unload model after", selection: idleBinding) {
                ForEach(idleOptions, id: \.0) { seconds, title in
                    Text(title).tag(seconds)
                }
            }
            .pickerStyle(.menu)
            .disabled(!monitor.serverOnline)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await monitor.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                Task {
                    if monitor.serverOnline {
                        await monitor.stopServer()
                    } else {
                        await monitor.startServer()
                    }
                }
            } label: {
                Label(monitor.serverOnline ? "Stop Server" : "Start Server", systemImage: monitor.serverOnline ? "stop.fill" : "play.fill")
            }
            Button {
                monitor.copyServerURL()
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            Button {
                monitor.openLogs()
            } label: {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    private var idleBinding: Binding<Int> {
        Binding(
            get: { monitor.idleSeconds },
            set: { value in Task { await monitor.updateIdleSeconds(value) } }
        )
    }

    private var statusColor: Color {
        if monitor.hasWork { return .yellow }
        if monitor.serverOnline { return .green }
        return .secondary
    }

    private var uptimeText: String {
        guard let seconds = monitor.status?.server.uptime_seconds else { return "-" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
