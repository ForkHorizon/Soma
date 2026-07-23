import SwiftUI

@main
struct SomaVoiceServerApp: App {
    @StateObject private var monitor = VoiceServerMonitor()

    var body: some Scene {
        Window("Soma Voice Server", id: "server") {
            VoiceServerDashboardView(monitor: monitor)
                .frame(minWidth: 460, minHeight: 520)
                .task { await monitor.refresh() }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            VoiceServerMenuView(monitor: monitor)
        } label: {
            Label("Soma Voice Server", systemImage: monitor.menuBarSymbol)
        }
    }
}
