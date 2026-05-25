import Foundation

import SwiftUI

import AppKit

import Combine

import UniformTypeIdentifiers


extension SomaViewModel {

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
                    recentRoots: recentProjectRoots,
                    rawCapture: auditRawCaptureNextRun
                )
                let stepDuration = Date().timeIntervalSince(stepStart)

                if let error = bundle.error {
                    throw SomaError(error)
                }
                logActivity("Prepared \(bundle.packet_mode ?? "unknown") packet with \(bundle.evidence_items?.count ?? 0) items. Confidence: \(bundle.confidence ?? 0)", duration: stepDuration)

                await MainActor.run {
                    gatherBundle = bundle
                    latestTokenSavings = bundle.token_savings
                    _ = recordPacketRun(prompt: prompt, bundle: bundle)
                    auditRawCaptureNextRun = false
                    showContextPanel = true
                    relayPhase = .done
                    ollama.checkStatus()
                    loadAuditReport()
                    logActivity("Prepared Codex packet (~\(bundle.estimated_tokens ?? 0) tokens)")
                    logActivity("Evidence compile total time", duration: Date().timeIntervalSince(startTime))
                }
            } catch {
                await MainActor.run {
                    logActivity("Relay failed: \(error.localizedDescription)")
                    relayPhase = .failed(error.localizedDescription)
                    relayError = error.localizedDescription
                    auditRawCaptureNextRun = false
                }
            }
        }
    }

    func runPythonChat(prompt: String, history: [[String: AnyCodable]]) async throws -> OllamaResponse {
        let scriptPath = try scriptURL(named: "scout_pipeline").path
        let pyPath = pythonPath()
        let env = scriptEnvironment()

        return try await Task.detached(priority: .userInitiated) {
            let historyJSON = (try? String(data: JSONEncoder().encode(history), encoding: .utf8)) ?? "[]"
            let output = try await SomaViewModel.executeProcess(path: pyPath, args: [scriptPath, prompt, historyJSON], environment: env)
            return try JSONDecoder().decode(OllamaResponse.self, from: output)
        }.value
    }

    func runGather(prompt: String, projectRoot: String, recentRoots: [String], rawCapture: Bool = false) async throws -> GatherBundle {
        let scriptPath = try scriptURL(named: "scout_pipeline").path
        let pyPath = pythonPath()
        var env = scriptEnvironment(projectRoot: projectRoot)
        if rawCapture {
            env["SOMA_AUDIT_RAW_CAPTURE"] = "1"
        }
        let depth = analysisDepth.rawValue

        return try await Task.detached(priority: .userInitiated) {
            let recentRootsJSON = (try? String(data: JSONEncoder().encode(recentRoots), encoding: .utf8)) ?? "[]"
            let output = try await SomaViewModel.executeProcess(
                path: pyPath,
                args: [
                    scriptPath,
                    prompt,
                    "--mode", "gather",
                    "--project-root", projectRoot,
                    "--recent-roots-json", recentRootsJSON,
                    "--token-budget", "balanced",
                    "--analysis-depth", depth,
                ],
                environment: env
            )
            return try JSONDecoder().decode(GatherBundle.self, from: output)
        }.value
    }

func loadAuditReport() {
        Task {
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".soma/audit/latest.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            do {
                let data = try Data(contentsOf: file)
                let report = try JSONDecoder().decode(AuditReport.self, from: data)
                await MainActor.run {
                    self.auditReport = report
                    self.auditError = nil
                }
            } catch {
                await MainActor.run {
                    self.auditError = "Audit report unreadable: \(error.localizedDescription)"
                }
            }
        }
    }

func markAudit(status: String, notes: String = "") {
        guard let runID = auditReport?.run_id else {
            auditError = "No audit run selected."
            return
        }
        auditMarkBusy = true
        auditError = nil
        Task {
            do {
                let script = try scriptURL(named: "soma_audit")
                let data = try await runScript(
                    path: pythonPath(),
                    args: [
                        script.path,
                        "--mark", runID,
                        "--status", status,
                        "--notes", notes,
                    ]
                )
                let report = try JSONDecoder().decode(AuditReport.self, from: data)
                await MainActor.run {
                    self.auditReport = report
                    self.auditMarkBusy = false
                    self.auditError = nil
                    self.logActivity("Audit \(runID) marked \(status)")
                }
            } catch {
                await MainActor.run {
                    self.auditMarkBusy = false
                    self.auditError = error.localizedDescription
                }
            }
        }
    }

    func runRelayScript(bundle: GatherBundle) async throws -> RelayResponse {
        let scriptPath = try scriptURL(named: "relay").path
        let pyPath = pythonPath()
        let env = scriptEnvironment()

        return try await Task.detached(priority: .userInitiated) {
            let bundleJSON = (try? String(data: JSONEncoder().encode(bundle), encoding: .utf8)) ?? "{}"
            let output = try await SomaViewModel.executeProcess(path: pyPath, args: [scriptPath, bundleJSON], environment: env)
            return try JSONDecoder().decode(RelayResponse.self, from: output)
        }.value
    }

func loadTokenBenchmarkReport() {
        Task {
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".soma/token_stats.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            do {
                let data = try Data(contentsOf: file)
                let report = try JSONDecoder().decode(TokenBenchmarkReport.self, from: data)
                await MainActor.run {
                    self.tokenBenchmarkReport = report
                    self.tokenBenchmarkError = nil
                }
            } catch {
                await MainActor.run {
                    self.tokenBenchmarkError = "Context benchmark report unreadable: \(error.localizedDescription)"
                }
            }
        }
    }

func loadAgentBenchmarkReport() {
        Task {
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".soma/agent_benchmarks/latest.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            do {
                let data = try Data(contentsOf: file)
                let report = try JSONDecoder().decode(AgentBenchmarkReport.self, from: data)
                await MainActor.run {
                    self.agentBenchmarkReport = report
                    self.agentBenchmarkError = nil
                }
            } catch {
                await MainActor.run {
                    self.agentBenchmarkError = "A/B benchmark report unreadable: \(error.localizedDescription)"
                }
            }
        }
    }

func runTokenBenchmark() {
        guard !selectedProjectRoot.isEmpty else {
            tokenBenchmarkError = "Select a project root before measuring context reduction."
            return
        }
        tokenBenchmarkBusy = true
        tokenBenchmarkError = nil
        logActivity("Measuring estimated context reduction for \((selectedProjectRoot as NSString).lastPathComponent)...")
        Task {
            do {
                let script = try scriptURL(named: "soma_token_benchmark")
                let data = try await runScript(
                    path: pythonPath(),
                    args: [
                        script.path,
                        "--project-root", selectedProjectRoot,
                        "--baseline", "both",
                        "--budget", "fast",
                    ]
                )
                let report = try JSONDecoder().decode(TokenBenchmarkReport.self, from: data)
                await MainActor.run {
                    self.tokenBenchmarkReport = report
                    self.tokenBenchmarkBusy = false
                    self.tokenBenchmarkError = nil
                    self.logActivity("Context benchmark \(report.status ?? "unknown"): reduced \(report.summary?.total_saved_tokens ?? 0) estimated tokens")
                }
            } catch {
                await MainActor.run {
                    self.tokenBenchmarkBusy = false
                    self.tokenBenchmarkError = error.localizedDescription
                    self.logActivity("Context benchmark failed: \(error.localizedDescription)")
                }
            }
        }
    }

func chooseAndRunAgentBenchmark() {
        guard !selectedProjectRoot.isEmpty else {
            agentBenchmarkError = "Select a project root before running an A/B benchmark."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose A/B benchmark scenario"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            runAgentBenchmark(scenarioPath: url.path)
        }
    }

func runAgentBenchmark(scenarioPath: String) {
        agentBenchmarkBusy = true
        agentBenchmarkError = nil
        logActivity("Running agent A/B benchmark from \((scenarioPath as NSString).lastPathComponent)...")
        Task {
            do {
                let script = try scriptURL(named: "soma_agent_ab_benchmark")
                let data = try await runScript(
                    path: pythonPath(),
                    args: [
                        script.path,
                        "--scenario", scenarioPath,
                        "--agents", "codex,gemini,hermes",
                        "--budget", "fast",
                        "--python", pythonPath(),
                    ]
                )
                let report = try JSONDecoder().decode(AgentBenchmarkReport.self, from: data)
                await MainActor.run {
                    self.agentBenchmarkReport = report
                    self.agentBenchmarkBusy = false
                    self.agentBenchmarkError = nil
                    self.logActivity("A/B benchmark \(report.status ?? "unknown"): \(report.summary?.paired_result_count ?? 0) accepted pairs")
                }
            } catch {
                await MainActor.run {
                    self.agentBenchmarkBusy = false
                    self.agentBenchmarkError = error.localizedDescription
                    self.logActivity("A/B benchmark failed: \(error.localizedDescription)")
                }
            }
        }
    }

func runSomaHelper(args: [String]) async throws -> Data {
        let scriptPath = try scriptURL(named: "soma_mcp_server").path
        return try await runScript(path: pythonPath(), args: [scriptPath] + args)
    }

nonisolated func scriptURL(named name: String) throws -> URL {
        // Prefer source directory — gateway/ package must be co-located with soma_mcp_server.py.
        // #filePath resolves to: …/Soma/Soma/ViewModels/SomaViewModel+Execution.swift
        // Two .deletingLastPathComponent() calls reach: …/Soma/Soma/
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // drop SomaViewModel+Execution.swift → ViewModels/
            .deletingLastPathComponent()   // drop ViewModels/ → Soma/ (contains gateway/)
            .appendingPathComponent("\(name).py")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        // Fallback: bundled resource (only valid when gateway/ is also bundled)
        if let bundled = Bundle.main.url(forResource: name, withExtension: "py") {
            return bundled
        }
        throw SomaError("\(name).py not found in source or bundle")
    }

nonisolated func pythonPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3") {
            return "/opt/homebrew/bin/python3"
        }
        return "/usr/bin/python3"
    }

func scriptEnvironment(projectRoot: String? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = (environment["PATH"] ?? "") + ":/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:\(homeDir)/.local/bin"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        LocalModelSettingsStore.apply(to: &environment)
        if let projectRoot, !projectRoot.isEmpty {
            environment["SOMA_PROJECT_ROOT"] = projectRoot
        } else if !selectedProjectRoot.isEmpty {
            environment["SOMA_PROJECT_ROOT"] = selectedProjectRoot
        }
        return environment
    }

func runScript(path: String, args: [String], workingDirectory: String? = nil) async throws -> Data {
        let env = scriptEnvironment()
        return try await Self.executeProcess(path: path, args: args, workingDirectory: workingDirectory, environment: env)
    }

private static func executeProcess(path: String, args: [String], workingDirectory: String? = nil, environment: [String: String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.environment = environment
            if let wd = workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: wd)
            }
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
