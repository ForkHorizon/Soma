import AppKit
import SwiftUI

struct VoiceServerMenuView: View {
    @ObservedObject var monitor: VoiceServerMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusSummary
            Divider()
            Button("Open Window") {
                openWindow(id: "server")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Button(monitor.serverOnline ? "Stop Server" : "Start Server") {
                Task {
                    if monitor.serverOnline {
                        await monitor.stopServer()
                    } else {
                        await monitor.startServer()
                    }
                }
            }
            Button("Refresh") {
                Task { await monitor.refresh() }
            }
            Button("Open Logs") {
                monitor.openLogs()
            }
            Button("Copy Server URL") {
                monitor.copyServerURL()
            }
            Divider()
            Button("Quit and Stop Server") {
                Task { await monitor.quitAndStop() }
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(statusTitle, systemImage: monitor.menuBarSymbol)
            Text("Loaded in RAM: \(monitor.modelLoaded ? "Yes" : "No")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Queue: \(monitor.status?.queue.queued ?? 0) queued, \(monitor.status?.queue.running ?? 0) running")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        if monitor.hasWork { return "Working" }
        if monitor.serverOnline { return "Online" }
        return "Offline"
    }
}
