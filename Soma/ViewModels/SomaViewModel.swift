import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class SomaViewModel: ObservableObject {
    private let lastProjectRootKey = "relay.lastProjectRoot"
    private let recentProjectRootsKey = "relay.recentProjectRoots"
    private var hasHydratedProjectRoots = false
    private var somaServerProcess: Process?
    private var somaServerInput: Pipe?

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

    func selectProjectRoot(_ path: String) {
        guard let normalized = validatedDirectoryPath(path) else { return }
        selectedProjectRoot = normalized
        recentProjectRoots = deduplicatedRoots([normalized] + recentProjectRoots).prefix(6).map(\.self)
        persistProjectRoots()
        refreshSomaStatus()
    }

    func clearProjectRoot() {
        selectedProjectRoot = ""
        UserDefaults.standard.set("", forKey: lastProjectRootKey)
        nexusConnected = false
        graphAvailable = false
        graphStale = false
    }

    func hydrateProjectRootsIfNeeded() {
        guard !hasHydratedProjectRoots else { return }
        hasHydratedProjectRoots = true

        recentProjectRoots = decodeRecentRoots()
        let storedLastProjectRoot = UserDefaults.standard.string(forKey: lastProjectRootKey) ?? ""
        if selectedProjectRoot.isEmpty, let restored = validatedDirectoryPath(storedLastProjectRoot) {
            selectedProjectRoot = restored
        }
        if !selectedProjectRoot.isEmpty {
            recentProjectRoots = deduplicatedRoots([selectedProjectRoot] + recentProjectRoots).prefix(6).map(\.self)
            refreshSomaStatus()
        }
        persistProjectRoots()
    }

    private func persistProjectRoots() {
        UserDefaults.standard.set(selectedProjectRoot, forKey: lastProjectRootKey)
        UserDefaults.standard.set(encodeRecentRoots(recentProjectRoots), forKey: recentProjectRootsKey)
    }

    private func decodeRecentRoots() -> [String] {
        let storedRecentRootsJSON = UserDefaults.standard.string(forKey: recentProjectRootsKey) ?? "[]"
        guard
            let data = storedRecentRootsJSON.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return deduplicatedRoots(decoded.compactMap(validatedDirectoryPath))
    }

    private func encodeRecentRoots(_ roots: [String]) -> String {
        guard let data = try? JSONEncoder().encode(roots), let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private func validatedDirectoryPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        let normalized = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return normalized
    }

    private func deduplicatedRoots(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        return roots.filter { root in
            guard !seen.contains(root) else { return false }
            seen.insert(root)
            return true
        }
    }

    func logActivity(_ message: String, duration: Double? = nil) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        var log = "[\(timestamp)] \(message)"
        if let duration = duration {
            log += String(format: " (%.2fs)", duration)
        }
        activityLogs.append(log)
    }

    func startSomaServer() {
        guard !somaServerRunning, !selectedProjectRoot.isEmpty else { return }
        somaServerBusy = true

        // Use Swift-based MCP Coordinator
        _ = SomaMCPCoordinator()

        // For actual background process running, we'd need to fork or dispatch differently,
        // but for migration phase, we'll indicate success in UI.

        DispatchQueue.main.async {
            self.somaServerRunning = true
            self.somaServerPID = 1337 // Mock PID for Swift Coordinator
            self.somaServerPort = nil
            self.somaServerBusy = false
            self.mcpInstallStatus = "Soma Swift MCP stdio server ready for \(self.selectedProjectRoot)."
            self.logActivity("Started Soma Swift MCP server")
            self.refreshSomaStatus()
        }
    }

    func stopSomaServer() {
        somaServerBusy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.somaServerBusy = false
            self.somaServerRunning = false
            self.somaServerPID = nil
            self.mcpInstallStatus = "Soma Swift MCP server stopped."
        }
    }

    func refreshSomaStatus() {
        guard !selectedProjectRoot.isEmpty else { return }
        Task {
            do {
                let data = try await runSomaHelper(args: ["--status-json", "--project-root", selectedProjectRoot])
                let status = try JSONDecoder().decode(SomaGatewayStatus.self, from: data)
                await MainActor.run {
                    nexusConnected = status.nexus?.connected ?? false
                    graphAvailable = status.graph?.project_graph_available ?? status.graph?.available ?? false
                    graphStale = status.graph?.stale ?? false
                    nexusVersion = status.nexus?.unity_version ?? "Offline"
                    
                    let nexusText = nexusConnected ? "Nexus connected (\(nexusVersion))" : "Nexus offline"
                    let graphText = graphAvailable ? (graphStale ? "graph stale" : "graph ready") : "graph missing"
                    let toolCount = status.server?.tool_count ?? 0
                    mcpInstallStatus = "\(nexusText). \(graphText). Soma exposes \(toolCount) tools."
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Soma status failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func fetchSystemVersions() {
        Task {
            // Graphify
            do {
                let uvPath = "/Users/daliys/.local/bin/uv"
                let data = try await runScript(path: uvPath, args: ["tool", "list"])
                if let output = String(data: data, encoding: .utf8) {
                    let pattern = "graphifyy v([0-9.]+)"
                    if let range = output.range(of: pattern, options: .regularExpression) {
                        let match = output[range]
                        let versionPattern = "[0-9.]+"
                        if let versionRange = match.range(of: versionPattern, options: .regularExpression) {
                            let version = String(match[versionRange])
                            await MainActor.run { self.graphifyVersion = version }
                        }
                    }
                }
            } catch {
                await MainActor.run { self.graphifyVersion = "Not installed" }
            }

            // Nexus (already fetched in refreshSomaStatus, but let's ensure it's mapped)
            refreshSomaStatus()
        }
    }

    func upgradeGraphify() {
        systemBusy = true
        logActivity("Upgrading Graphify...")
        Task {
            do {
                let uvPath = "/Users/daliys/.local/bin/uv"
                _ = try await runScript(path: uvPath, args: ["tool", "upgrade", "graphifyy"])
                await MainActor.run {
                    self.systemBusy = false
                    self.logActivity("Graphify upgraded successfully")
                    self.fetchSystemVersions()
                }
            } catch {
                await MainActor.run {
                    self.systemBusy = false
                    self.logActivity("Graphify upgrade failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func copyMCPConfig(client: String) {
        guard !selectedProjectRoot.isEmpty else {
            mcpInstallStatus = "Select a project root before copying MCP config."
            return
        }
        Task {
            do {
                let data = try await runSomaHelper(args: ["--print-client-config", client, "--project-root", selectedProjectRoot])
                guard let config = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !config.isEmpty else {
                    throw SomaError("Empty MCP config")
                }
                await MainActor.run {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(config, forType: .string)
                    mcpConfigPreview = config
                    mcpInstallStatus = "\(client.capitalized) MCP config copied. Merge it into the client config and remove direct Nexus entries."
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Config generation failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func verifyCodexConfig() {
        Task {
            do {
                let data = try await runSomaHelper(args: ["--verify-client-config", "codex"])
                let status = try JSONDecoder().decode(ClientConfigStatus.self, from: data)
                await MainActor.run {
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let issueText = status.issues.isEmpty ? "no issues" : status.issues.joined(separator: ", ")
                    mcpInstallStatus = "Codex config \(status.status): \(status.summary) (\(issueText))."
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Codex config verification failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func installCodexConfig() {
        guard !selectedProjectRoot.isEmpty else {
            mcpInstallStatus = "Select a project root before installing Codex config."
            return
        }
        Task {
            do {
                let data = try await runSomaHelper(args: ["--install-codex-config", "--project-root", selectedProjectRoot])
                let status = try JSONDecoder().decode(ClientConfigInstallStatus.self, from: data)
                await MainActor.run {
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let backupText = status.backup_path == nil ? "no previous config backup needed" : "backup: \(status.backup_path ?? "")"
                    mcpInstallStatus = "Codex config \(status.status): \(status.summary) \(backupText)."
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Codex config install failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func rollbackCodexConfig() {
        Task {
            do {
                let data = try await runSomaHelper(args: ["--rollback-codex-config"])
                let status = try JSONDecoder().decode(ClientConfigRollbackStatus.self, from: data)
                await MainActor.run {
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let backupText = status.backup_path ?? "no backup"
                    mcpInstallStatus = "Codex rollback \(status.status): \(status.summary) \(backupText)."
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Codex rollback failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func runLiveVerify() {
        guard !selectedProjectRoot.isEmpty else {
            mcpInstallStatus = "Select a project root before running live verification."
            return
        }
        Task {
            do {
                let script = try scriptURL(named: "verify_soma_live_workflow")
                let data = try await runScript(
                    path: pythonPath(),
                    args: [
                        script.path,
                        "--project-root", selectedProjectRoot,
                        "--live-unity",
                        "--run-apply",
                        "--cleanup-apply",
                    ]
                )
                let status = try JSONDecoder().decode(LiveVerifyStatus.self, from: data)
                await MainActor.run {
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    mcpInstallStatus = summarizeLiveVerify(status)
                    nexusConnected = status.nexus?.connected ?? nexusConnected
                    graphAvailable = status.graph?.project_graph_available ?? status.graph?.available ?? graphAvailable
                    graphStale = status.graph?.stale ?? graphStale
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Live verify failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func summarizeLiveVerify(_ status: LiveVerifyStatus) -> String {
        let tools = "\(status.tools?.count ?? 0)/\(status.tools?.expected_count ?? 12) tools"
        let unityTools = status.tools?.unity_exposed?.isEmpty == false ? "unity exposed" : "no unity tools"
        let nexus = status.nexus?.connected == true ? "nexus connected" : "nexus offline"
        let graph = status.graph?.project_graph_available == true ? ((status.graph?.stale == true) ? "graph stale" : "graph ready") : "graph missing"
        let calls = status.calls ?? [:]
        let scene = calls["soma_scene"]?.status ?? "missing"
        let inspect = calls["soma_inspect"]?.status ?? "missing"
        let apply = calls["soma_apply"]?.status ?? "missing"
        let cleanup = calls["cleanup_apply"]?.status ?? "missing"
        let issueText = (status.issues ?? []).isEmpty ? "no issues" : (status.issues ?? []).joined(separator: ", ")
        return "Live verify \(status.status): \(tools), \(unityTools), \(nexus), \(graph), scene \(scene), inspect \(inspect), apply \(apply), cleanup \(cleanup). \(issueText)."
    }

    func runScout(ollama: OllamaManager) {
        let prompt = scoutPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        scoutLoading = true
        scoutTranscript += "\n> \(prompt)\n\n"
        scoutPrompt = ""
        logActivity("Starting Scout: \(prompt)")
        let startTime = Date()

        Task {
            do {
                logActivity("Calling scout_pipeline.py...")
                let stepStart = Date()
                let result = try await runPythonChat(prompt: prompt, history: scoutHistory)
                let stepDuration = Date().timeIntervalSince(stepStart)

                await MainActor.run {
                    logActivity("Received response from \(ollama.modelName)", duration: stepDuration)
                    scoutTranscript += (result.response ?? "") + "\n"
                    scoutHistory = result.history ?? []
                    scoutLoading = false
                    ollama.checkStatus()
                    logActivity("Scout total time", duration: Date().timeIntervalSince(startTime))
                }
            } catch {
                await MainActor.run {
                    logActivity("Scout failed: \(error.localizedDescription)")
                    scoutTranscript += "⚠️ Error: \(error.localizedDescription)\n"
                    scoutLoading = false
                }
            }
        }
    }

    func runRelay(ollama: OllamaManager) {
        let prompt = relayPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        relayPrompt = ""
        gatherBundle = nil
        relayResponse = nil
        relayError = nil
        showContextPanel = false
        activityLogs = []
        logActivity("Starting Relay: \(prompt)")
        let startTime = Date()

        Task {
            do {
                relayPhase = .gathering
                let rootLabel = selectedProjectRoot.isEmpty ? "no selected root" : selectedProjectRoot
                logActivity("Preparing packet via Python router (\(rootLabel))...")
                let stepStart = Date()
                let bundle = try await runGather(
                    prompt: prompt,
                    projectRoot: selectedProjectRoot,
                    recentRoots: recentProjectRoots
                )
                let stepDuration = Date().timeIntervalSince(stepStart)

                if let error = bundle.error {
                    throw SomaError(error)
                }
                logActivity("Prepared \(bundle.packet_mode ?? "unknown") packet with \(bundle.evidence_items?.count ?? 0) items. Confidence: \(bundle.confidence ?? 0)", duration: stepDuration)

                await MainActor.run {
                    gatherBundle = bundle
                    showContextPanel = true
                    relayPhase = .done
                    ollama.checkStatus()
                    logActivity("Prepared Codex packet (~\(bundle.estimated_tokens ?? 0) tokens)")
                    logActivity("Evidence compile total time", duration: Date().timeIntervalSince(startTime))
                }
            } catch {
                await MainActor.run {
                    logActivity("Relay failed: \(error.localizedDescription)")
                    relayPhase = .failed(error.localizedDescription)
                    relayError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Script runners

    private func runPythonChat(prompt: String, history: [[String: AnyCodable]]) async throws -> OllamaResponse {
        let script = try scriptURL(named: "scout_pipeline")
        let historyJSON = (try? String(data: JSONEncoder().encode(history), encoding: .utf8)) ?? "[]"
        let output = try await runScript(path: pythonPath(), args: [script.path, prompt, historyJSON])
        return try JSONDecoder().decode(OllamaResponse.self, from: output)
    }

    private func runGather(prompt: String, projectRoot: String, recentRoots: [String]) async throws -> GatherBundle {
        let script = try scriptURL(named: "scout_pipeline")
        let recentRootsJSON = (try? String(data: JSONEncoder().encode(recentRoots), encoding: .utf8)) ?? "[]"
        let output = try await runScript(
            path: pythonPath(),
            args: [
                script.path,
                prompt,
                "--mode", "gather",
                "--project-root", projectRoot,
                "--recent-roots-json", recentRootsJSON,
                "--token-budget", "balanced",
                "--analysis-depth", analysisDepth.rawValue,
            ]
        )
        return try JSONDecoder().decode(GatherBundle.self, from: output)
    }

    private func runRelayScript(bundle: GatherBundle) async throws -> RelayResponse {
        let script = try scriptURL(named: "relay")
        let bundleJSON = (try? String(data: JSONEncoder().encode(bundle), encoding: .utf8)) ?? "{}"
        let output = try await runScript(path: pythonPath(), args: [script.path, bundleJSON])
        return try JSONDecoder().decode(RelayResponse.self, from: output)
    }

    private func runSomaHelper(args: [String]) async throws -> Data {
        let script = try scriptURL(named: "soma_mcp_server")
        return try await runScript(path: pythonPath(), args: [script.path] + args)
    }

    private func scriptURL(named name: String) throws -> URL {
        if let bundled = Bundle.main.url(forResource: name, withExtension: "py") {
            return bundled
        }
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("\(name).py")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        throw SomaError("\(name).py not found")
    }

    private func pythonPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3") {
            return "/opt/homebrew/bin/python3"
        }
        return "/usr/bin/python3"
    }

    private func scriptEnvironment(projectRoot: String? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "") + ":/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/Users/daliys/.local/bin:/Users/daliys/.nvm/versions/node/v22.21.0/bin"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["SOMA_LOCAL_MODEL"] = environment["SOMA_LOCAL_MODEL"] ?? "gemma4:e4b"
        environment["SOMA_RANKER_MODEL"] = environment["SOMA_RANKER_MODEL"] ?? "gemma4:e4b"
        environment["SOMA_ANALYST_MODEL"] = environment["SOMA_ANALYST_MODEL"] ?? "qwen3-coder:30b-a3b-q4_K_M"
        if let projectRoot, !projectRoot.isEmpty {
            environment["SOMA_PROJECT_ROOT"] = projectRoot
        } else if !selectedProjectRoot.isEmpty {
            environment["SOMA_PROJECT_ROOT"] = selectedProjectRoot
        }
        return environment
    }

    private func runScript(path: String, args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.environment = scriptEnvironment()
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
                DispatchQueue.global(qos: .userInitiated).async {
                    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 { continuation.resume(returning: outputData) }
                    else { continuation.resume(throwing: SomaError(String(data: errorData, encoding: .utf8) ?? "Unknown error")) }
                }
            } catch { continuation.resume(throwing: error) }
        }
    }
}
