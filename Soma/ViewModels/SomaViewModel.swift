import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class SomaViewModel: ObservableObject {
    let lastProjectRootKey = "relay.lastProjectRoot"
    let recentProjectRootsKey = "relay.recentProjectRoots"
    let projectLastUsedKey = "relay.projectLastUsed"
    let projectUsageCountsKey = "relay.projectUsageCounts"
    let packetHistoryKey = "soma.packetHistory"
    var hasHydratedProjectRoots = false
    var hasHydratedPacketHistory = false
    var somaServerProcess: Process?
    var somaServerInput: Pipe?
    var logRefreshTimer: Timer?

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
    @Published var graphManagedAvailable = false
    @Published var graphLegacyAvailable = false
    @Published var graphStorageKind = "missing"
    @Published var graphNodeCount: Int?
    @Published var graphEdgeCount: Int?
    @Published var graphStoragePath: String?
    @Published var graphManagedPath: String?
    @Published var graphLegacyPaths: [String] = []
    @Published var graphToolLatestVersion: String?
    @Published var graphToolUpToDate: Bool?
    @Published var graphDegraded = false
    @Published var graphDegradedReason: String?
    @Published var graphDiagnosticsPath: String?
    @Published var graphSemanticRefreshPending: Bool?
    @Published var graphSourceRoot: String?
    @Published var graphScope = "project_root"
    @Published var mcpInstallStatus: String?
    @Published var mcpConfigPreview: String?
    @Published var codexConfigStatus: ClientConfigStatus?
    @Published var geminiConfigStatus: ClientConfigStatus?
    @Published var hermesConfigStatus: ClientConfigStatus?
    @Published var mcpSmokeReport: MCPSmokeReport?
    @Published var mcpSmokeBusy = false
    @Published var mcpSmokeError: String?
    @Published var projectSetupReport: ProjectAISetupReport?
    @Published var projectSetupBusy = false
    @Published var projectSetupError: String?
    @Published var hermesSetupBusy = false
    @Published var hermesSetupError: String?
    @Published var hermesLaunchCommand: String?
    @Published var hermesStarterPrompt: String?

    @Published var activityLogs: [String] = []
    @Published var showActivityLog = false

    @Published var graphifyVersion: String = "Unknown"
    @Published var graphBuildVersion: String?
    @Published var nexusVersion: String = "Offline"
    @Published var systemBusy = false
    @Published var graphifyBusy = false

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

    @Published var logEntries: [SomaLogEntry] = []
    @Published var toolStats: [SomaToolStat] = []
    @Published var localModelStats: [SomaLocalModelStat] = []
    @Published var logsLoading = false
    @Published var logsClearBusy = false
    @Published var latestTokenSavings: TokenSavings?
    @Published var tokenBenchmarkReport: TokenBenchmarkReport?
    @Published var tokenBenchmarkBusy = false
    @Published var tokenBenchmarkError: String?
    @Published var agentBenchmarkReport: AgentBenchmarkReport?
    @Published var agentBenchmarkBusy = false
    @Published var agentBenchmarkError: String?
    @Published var auditReport: AuditReport?
    @Published var auditError: String?
    @Published var auditRawCaptureNextRun = false
    @Published var auditMarkBusy = false
    @Published var packetHistory: [PacketHistoryItem] = []

    init() {}

    func resetState() {
        activityLogs = []
    }

}
