import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class SomaViewModel: ObservableObject {
    let lastProjectRootKey = "relay.lastProjectRoot"
    let recentProjectRootsKey = "relay.recentProjectRoots"
    var hasHydratedProjectRoots = false
    var somaServerProcess: Process?
    var somaServerInput: Pipe?
    var logRefreshTimer: Timer?

    @Published var scoutPrompt = ""
    @Published var scoutTranscript = ""
    @Published var scoutHistory: [[String: AnyCodable]] = []
    @Published var scoutLoading = false

    @Published var relayPrompt = ""
    @Published var relayPhase: RelayPhase = .idle
    @Published var gatherBundle: GatherBundle?
    @Published var relayResponse: RelayResponse?
    @Published var showContextPanel = false
    @Published var relayError: String?
    @Published var selectedProjectRoot = ""
    @Published var recentProjectRoots: [String] = []
    @Published var analysisDepth: AnalysisDepth = .deterministic

    @Published var somaServerRunning = false
    @Published var somaServerPID: Int32?
    @Published var somaServerPort: Int?
    @Published var somaServerBusy = false
    @Published var nexusConnected = false
    @Published var graphAvailable = false
    @Published var graphStale = false
    @Published var mcpInstallStatus: String?
    @Published var mcpConfigPreview: String?

    @Published var activityLogs: [String] = []
    @Published var showActivityLog = false

    @Published var graphifyVersion: String = "Unknown"
    @Published var nexusVersion: String = "Offline"
    @Published var systemBusy = false
    @Published var graphifyBusy = false

    @Published var logEntries: [SomaLogEntry] = []
    @Published var toolStats: [SomaToolStat] = []
    @Published var logsLoading = false

    init() {}

    func resetState() {
        scoutPrompt = ""
        scoutTranscript = ""
        scoutHistory = []
        scoutLoading = false

        relayPrompt = ""
        relayPhase = .idle
        gatherBundle = nil
        relayResponse = nil
        showContextPanel = false
        relayError = nil
        activityLogs = []
    }

}
