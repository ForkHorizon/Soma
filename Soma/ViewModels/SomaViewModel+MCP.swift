import Foundation

import SwiftUI

import AppKit

import Combine


extension SomaViewModel {

func startSomaServer() {
        guard !selectedProjectRoot.isEmpty else { return }
        if let process = somaServerProcess, process.isRunning {
            somaServerRunning = true
            somaServerPID = process.processIdentifier
            mcpInstallStatus = "Soma MCP server already running with PID \(process.processIdentifier)."
            return
        }

        somaServerBusy = true
        do {
            let script = try scriptURL(named: "soma_mcp_server")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath())
            process.arguments = [script.path, "--project-root", selectedProjectRoot]
            process.environment = scriptEnvironment(projectRoot: selectedProjectRoot)

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { [weak self] proc in
                let pid = proc.processIdentifier
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.somaServerPID == pid {
                        self.somaServerRunning = false
                        self.somaServerBusy = false
                        self.somaServerPID = nil
                        self.somaServerProcess = nil
                        self.somaServerInput = nil
                        self.mcpInstallStatus = "Soma MCP server exited with status \(proc.terminationStatus)."
                        self.stopLogRefreshTimer()
                        self.loadStructuredLogs()
                    }
                }
            }

            try process.run()
            somaServerProcess = process
            somaServerInput = stdin
            somaServerPID = process.processIdentifier
            somaServerRunning = true
            somaServerBusy = false
            mcpInstallStatus = "Soma MCP server running with PID \(process.processIdentifier) for \(selectedProjectRoot)."
            logActivity("Started Soma MCP Gateway PID \(process.processIdentifier)")
            drainProcessPipe(stdout)
            drainProcessPipe(stderr)
            refreshSomaStatus()
            startLogRefreshTimer()
        } catch {
            somaServerRunning = false
            somaServerPID = nil
            somaServerProcess = nil
            somaServerInput = nil
            somaServerBusy = false
            mcpInstallStatus = "Soma MCP start failed: \(error.localizedDescription)"
            logActivity("Soma MCP start failed: \(error.localizedDescription)")
        }
    }

func stopSomaServer() {
        let pid = somaServerPID
        somaServerInput?.fileHandleForWriting.closeFile()
        if let process = somaServerProcess, process.isRunning {
            process.terminate()
        }
        somaServerRunning = false
        somaServerPID = nil
        somaServerProcess = nil
        somaServerInput = nil
        mcpInstallStatus = "Soma MCP Gateway disabled."
        if let pid {
            logServerStop(pid: pid)
        }
        stopLogRefreshTimer()
        loadStructuredLogs()
    }

func drainProcessPipe(_ pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async {
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
        }
    }

func logServerStop(pid: Int32) {
        Task { [weak self] in guard let self else { return }
            do {
                let logger = try scriptURL(named: "soma_logger")
                _ = try await runScript(path: pythonPath(), args: [logger.path, "--server-stop-pid", "\(pid)", "--reason", "swift_stop"])
            } catch {
                await MainActor.run {
                    self.logActivity("Failed to write server_stop log: \(error.localizedDescription)")
                }
            }
        }
    }

func copyMCPConfig(client: String) {
        guard !selectedProjectRoot.isEmpty else {
            mcpInstallStatus = "Select a project root before copying MCP config."
            return
        }
        Task { [weak self] in guard let self else { return }
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

func copyGeminiConfig() { copyMCPConfig(client: "gemini") }

func copyHermesConfig() { copyMCPConfig(client: "hermes") }

func copyClaudeConfig() { copyMCPConfig(client: "claude") }

func verifyClientConfigs() {
        verifyCodexConfig(updateStatusText: false)
        verifyGeminiConfig(updateStatusText: false)
        verifyHermesConfig(updateStatusText: false)
    }

func verifyCodexConfig() {
        verifyCodexConfig(updateStatusText: true)
    }

func verifyCodexConfig(updateStatusText: Bool) {
        Task { [weak self] in guard let self else { return }
            do {
                var args = ["--verify-client-config", "codex"]
                if !selectedProjectRoot.isEmpty {
                    args += ["--project-root", selectedProjectRoot]
                }
                let data = try await runSomaHelper(args: args)
                let status = try JSONDecoder().decode(ClientConfigStatus.self, from: data)
                await MainActor.run {
                    codexConfigStatus = status
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if updateStatusText {
                        let issueText = status.issues.isEmpty ? "no issues" : status.issues.joined(separator: ", ")
                        mcpInstallStatus = "Codex config \(status.status): \(status.summary) (\(issueText))."
                    }
                }
            } catch {
                await MainActor.run {
                    if updateStatusText {
                        mcpInstallStatus = "Codex config verification failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

func verifyGeminiConfig() {
        verifyGeminiConfig(updateStatusText: true)
    }

func verifyGeminiConfig(updateStatusText: Bool) {
        Task { [weak self] in guard let self else { return }
            do {
                var args = ["--verify-client-config", "gemini"]
                if !selectedProjectRoot.isEmpty {
                    args += ["--project-root", selectedProjectRoot]
                }
                let data = try await runSomaHelper(args: args)
                let status = try JSONDecoder().decode(ClientConfigStatus.self, from: data)
                await MainActor.run {
                    geminiConfigStatus = status
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if updateStatusText {
                        let issueText = status.issues.isEmpty ? "no issues" : status.issues.joined(separator: ", ")
                        mcpInstallStatus = "Gemini config \(status.status): \(status.summary) (\(issueText))."
                    }
                }
            } catch {
                await MainActor.run {
                    if updateStatusText {
                        mcpInstallStatus = "Gemini config verification failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

func verifyHermesConfig() {
        verifyHermesConfig(updateStatusText: true)
    }

func verifyHermesConfig(updateStatusText: Bool) {
        Task { [weak self] in guard let self else { return }
            do {
                var args = ["--verify-client-config", "hermes"]
                if !selectedProjectRoot.isEmpty {
                    args += ["--project-root", selectedProjectRoot]
                }
                let data = try await runSomaHelper(args: args)
                let status = try JSONDecoder().decode(ClientConfigStatus.self, from: data)
                await MainActor.run {
                    hermesConfigStatus = status
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if updateStatusText {
                        let issueText = status.issues.isEmpty ? "no issues" : status.issues.joined(separator: ", ")
                        mcpInstallStatus = "Hermes config \(status.status): \(status.summary) (\(issueText))."
                    }
                }
            } catch {
                await MainActor.run {
                    if updateStatusText {
                        mcpInstallStatus = "Hermes config verification failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

func installCodexConfig() {
        guard !selectedProjectRoot.isEmpty else {
            mcpInstallStatus = "Select a project root before installing Codex config."
            return
        }
        Task { [weak self] in guard let self else { return }
            do {
                let data = try await runSomaHelper(args: ["--install-codex-config", "--project-root", selectedProjectRoot])
                let status = try JSONDecoder().decode(ClientConfigInstallStatus.self, from: data)
                await MainActor.run {
                    codexConfigStatus = ClientConfigStatus(
                        status: status.status,
                        summary: status.summary,
                        config_path: status.config_path,
                        soma_installed: status.soma_installed,
                        direct_nexus_exposed: nil,
                        tool_exposure_clean: nil,
                        actual_project_root: status.actual_project_root,
                        expected_project_root: status.expected_project_root,
                        project_matches: status.project_matches,
                        issues: status.issues
                    )
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

func installGeminiConfig() {
        guard !selectedProjectRoot.isEmpty else {
            mcpInstallStatus = "Select a project root before installing Gemini config."
            return
        }
        Task { [weak self] in guard let self else { return }
            do {
                let data = try await runSomaHelper(args: ["--install-gemini-config", "--project-root", selectedProjectRoot])
                let status = try JSONDecoder().decode(ClientConfigInstallStatus.self, from: data)
                await MainActor.run {
                    geminiConfigStatus = ClientConfigStatus(
                        status: status.status,
                        summary: status.summary,
                        config_path: status.config_path,
                        soma_installed: status.soma_installed,
                        direct_nexus_exposed: nil,
                        tool_exposure_clean: nil,
                        actual_project_root: status.actual_project_root,
                        expected_project_root: status.expected_project_root,
                        project_matches: status.project_matches,
                        issues: status.issues
                    )
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let backupText = status.backup_path == nil ? "no previous config backup needed" : "backup: \(status.backup_path ?? "")"
                    mcpInstallStatus = "Gemini config \(status.status): \(status.summary) \(backupText)."
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Gemini config install failed: \(error.localizedDescription)"
                }
            }
        }
    }

func installHermesConfig() {
        guard !selectedProjectRoot.isEmpty else {
            mcpInstallStatus = "Select a project root before installing Hermes config."
            return
        }
        Task { [weak self] in guard let self else { return }
            do {
                let data = try await runSomaHelper(args: ["--install-hermes-config", "--project-root", selectedProjectRoot])
                let status = try JSONDecoder().decode(ClientConfigInstallStatus.self, from: data)
                await MainActor.run {
                    hermesConfigStatus = ClientConfigStatus(
                        status: status.status,
                        summary: status.summary,
                        config_path: status.config_path,
                        soma_installed: status.soma_installed,
                        direct_nexus_exposed: nil,
                        tool_exposure_clean: nil,
                        actual_project_root: status.actual_project_root,
                        expected_project_root: status.expected_project_root,
                        project_matches: status.project_matches,
                        issues: status.issues
                    )
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let backupText = status.backup_path == nil ? "no previous config backup needed" : "backup: \(status.backup_path ?? "")"
                    mcpInstallStatus = "Hermes config \(status.status): \(status.summary) \(backupText)."
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Hermes config install failed: \(error.localizedDescription)"
                }
            }
        }
    }

func useSelectedProjectWithHermes() {
        guard !selectedProjectRoot.isEmpty else {
            hermesSetupError = "Select a project root before setting up Hermes."
            mcpInstallStatus = "Select a project root before setting up Hermes."
            return
        }
        hermesSetupBusy = true
        hermesSetupError = nil
        mcpInstallStatus = "Hermes project setup started."
        logActivity("Setting up Hermes for \((selectedProjectRoot as NSString).lastPathComponent)...")

        Task { [weak self] in guard let self else { return }
            do {
                let installData = try await runSomaHelper(args: ["--install-hermes-config", "--project-root", selectedProjectRoot])
                let install = try JSONDecoder().decode(ClientConfigInstallStatus.self, from: installData)

                let verifyData = try await runSomaHelper(args: ["--verify-client-config", "hermes", "--project-root", selectedProjectRoot])
                let verify = try JSONDecoder().decode(ClientConfigStatus.self, from: verifyData)

                let smokeScript = try scriptURL(named: "verify_soma_mcp_clients")
                let smokeData = try await runScript(
                    path: pythonPath(),
                    args: [
                        smokeScript.path,
                        "--project-root", selectedProjectRoot,
                        "--clients", "hermes",
                        "--python", pythonPath(),
                    ]
                )
                let smoke = try JSONDecoder().decode(MCPSmokeReport.self, from: smokeData)

                let packet = try await runGather(
                    prompt: "Prepare Hermes setup context for this project. Identify README, docs, project manifests, AI agent config files, MCP/Soma integration files, current git state, risks, and the first project-owned files Hermes should trust before making edits.",
                    projectRoot: selectedProjectRoot,
                    recentRoots: recentProjectRoots,
                    rawCapture: false
                )
                let command = "cd \(shellQuoted(selectedProjectRoot)) && hermes --tui"
                let prompt = buildHermesStarterPrompt(packet: packet, command: command)

                await MainActor.run {
                    self.hermesConfigStatus = verify
                    self.mcpSmokeReport = smoke
                    self.gatherBundle = packet
                    self.hermesLaunchCommand = command
                    self.hermesStarterPrompt = prompt
                    self.hermesSetupBusy = false
                    self.hermesSetupError = nil
                    self.mcpConfigPreview = prompt

                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(prompt, forType: .string)

                    let backupText = install.backup_path == nil ? "no backup needed" : "backup: \(install.backup_path ?? "")"
                    let smokeStatus = smoke.status ?? "unknown"
                    let degraded = smoke.summary?.config_degraded ?? []
                    let packetStatus = packet.audit?.evidence_quality?.status ?? (packet.error == nil ? "ok" : "degraded")
                    if degraded.isEmpty {
                        self.mcpInstallStatus = "Hermes ready: config installed (\(backupText)), MCP smoke \(smokeStatus), starter packet \(packetStatus). Prompt copied; run `\(command)`."
                    } else {
                        self.mcpInstallStatus = "Hermes degraded: \(degraded.joined(separator: ", ")). Starter packet \(packetStatus). Prompt copied; run `\(command)` after fixing readiness."
                    }
                    self.loadStructuredLogs()
                    self.loadAuditReport()
                    self.logActivity("Hermes project setup complete: \(smokeStatus), packet \(packetStatus)")
                }
            } catch {
                await MainActor.run {
                    self.hermesSetupBusy = false
                    self.hermesSetupError = error.localizedDescription
                    self.mcpInstallStatus = "Hermes project setup failed: \(error.localizedDescription)"
                    self.logActivity("Hermes project setup failed: \(error.localizedDescription)")
                }
            }
        }
    }

func copyHermesStarterPrompt() {
        guard let prompt = hermesStarterPrompt, !prompt.isEmpty else {
            mcpInstallStatus = "Run Hermes setup before copying the starter prompt."
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(prompt, forType: .string)
        mcpInstallStatus = "Hermes starter prompt copied. Launch Hermes with `\(hermesLaunchCommand ?? "hermes --tui")`."
    }

func buildHermesStarterPrompt(packet: GatherBundle, command: String) -> String {
        let packetStatus = packet.audit?.evidence_quality?.status ?? (packet.error == nil ? "ok" : "degraded")
        let evidenceCount = packet.evidence_items?.count ?? 0
        let tokenText = packet.estimated_tokens.map(String.init) ?? "unknown"
        let quality = packet.audit?.evidence_quality
        let strong = quality?.strong_match_count ?? 0
        let weak = quality?.weak_match_count ?? 0
        let summary = packet.context_summary ?? packet.gather_reason ?? "Use Soma as the source of project evidence before editing."
        let evidencePaths = (packet.evidence_items ?? [])
            .prefix(8)
            .compactMap { $0.path }
            .map { "- \($0)" }
            .joined(separator: "\n")
        let evidenceSection = evidencePaths.isEmpty ? "- No selected evidence paths were returned. Treat this as degraded and gather targeted files only." : evidencePaths

        return """
        You are working in this project through Hermes:
        \(selectedProjectRoot)

        Launch command:
        \(command)

        Before editing or running broad scans, call Soma's MCP tool `soma_prepare_context` for the user's concrete task.

        Rules:
        - Treat Soma as the evidence/context backend and the first source of truth.
        - Do not broadly scan the repo unless Soma returns `degraded` or the packet clearly misses required files/symbols.
        - If Soma returns `degraded`, gather only targeted files needed to repair the missing evidence.
        - Do not rely on invented files, managers, configs, or APIs.
        - Keep raw prompts/transcripts private unless explicitly asked to capture them.
        - After edits, run the smallest relevant tests/build checks and report exact commands and results.

        Bootstrap packet:
        - status: \(packetStatus)
        - estimated tokens: \(tokenText)
        - evidence items: \(evidenceCount)
        - strong matches: \(strong)
        - weak matches: \(weak)
        - summary: \(summary)

        Selected evidence:
        \(evidenceSection)

        User task:
        """
    }

func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

func rollbackCodexConfig() {
        Task { [weak self] in guard let self else { return }
            do {
                let data = try await runSomaHelper(args: ["--rollback-codex-config"])
                let status = try JSONDecoder().decode(ClientConfigRollbackStatus.self, from: data)
                await MainActor.run {
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let backupText = status.backup_path ?? "no backup"
                    mcpInstallStatus = "Codex rollback \(status.status): \(status.summary) \(backupText)."
                    verifyCodexConfig(updateStatusText: false)
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Codex rollback failed: \(error.localizedDescription)"
                }
            }
        }
    }

func rollbackGeminiConfig() {
        Task { [weak self] in guard let self else { return }
            do {
                let data = try await runSomaHelper(args: ["--rollback-gemini-config"])
                let status = try JSONDecoder().decode(ClientConfigRollbackStatus.self, from: data)
                await MainActor.run {
                    mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let backupText = status.backup_path ?? "no backup"
                    mcpInstallStatus = "Gemini rollback \(status.status): \(status.summary) \(backupText)."
                    verifyGeminiConfig(updateStatusText: false)
                }
            } catch {
                await MainActor.run {
                    mcpInstallStatus = "Gemini rollback failed: \(error.localizedDescription)"
                }
            }
        }
    }

func analyzeProjectAISetup() {
        guard !selectedProjectRoot.isEmpty else {
            projectSetupError = "Select a project root before analyzing project AI setup."
            return
        }
        projectSetupBusy = true
        projectSetupError = nil
        Task { [weak self] in guard let self else { return }
            do {
                let data = try await runSomaHelper(args: ["--analyze-project-ai-setup", "--project-root", selectedProjectRoot])
                let report = try JSONDecoder().decode(ProjectAISetupReport.self, from: data)
                await MainActor.run {
                    self.projectSetupReport = report
                    self.projectSetupBusy = false
                    self.projectSetupError = nil
                    self.mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let riskText = (report.remaining_risks ?? report.issues ?? []).isEmpty ? "no risks" : (report.remaining_risks ?? report.issues ?? []).joined(separator: ", ")
                    self.mcpInstallStatus = "Project AI setup \(report.status ?? "unknown"): \(report.summary ?? "") (\(riskText))."
                    self.loadStructuredLogs()
                }
            } catch {
                await MainActor.run {
                    self.projectSetupBusy = false
                    self.projectSetupError = error.localizedDescription
                    self.mcpInstallStatus = "Project AI setup analysis failed: \(error.localizedDescription)"
                }
            }
        }
    }

func hardenProjectAISetup() {
        guard !selectedProjectRoot.isEmpty else {
            projectSetupError = "Select a project root before hardening project AI setup."
            return
        }
        projectSetupBusy = true
        projectSetupError = nil
        Task { [weak self] in guard let self else { return }
            do {
                let data = try await runSomaHelper(args: ["--harden-project-ai-setup", "--project-root", selectedProjectRoot])
                let report = try JSONDecoder().decode(ProjectAISetupReport.self, from: data)
                await MainActor.run {
                    self.projectSetupReport = report
                    self.projectSetupBusy = false
                    self.projectSetupError = nil
                    self.mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let changed = report.files_changed?.count ?? 0
                    let risks = report.remaining_risks?.count ?? 0
                    self.mcpInstallStatus = "Project AI setup \(report.status ?? "unknown"): changed \(changed) files, remaining risks \(risks)."
                    self.verifyCodexConfig(updateStatusText: false)
                    self.verifyGeminiConfig(updateStatusText: false)
                    self.verifyHermesConfig(updateStatusText: false)
                    self.loadStructuredLogs()
                }
            } catch {
                await MainActor.run {
                    self.projectSetupBusy = false
                    self.projectSetupError = error.localizedDescription
                    self.mcpInstallStatus = "Project AI setup hardening failed: \(error.localizedDescription)"
                }
            }
        }
    }

func rollbackProjectAISetup() {
        guard !selectedProjectRoot.isEmpty else {
            projectSetupError = "Select a project root before rolling back project AI setup."
            return
        }
        projectSetupBusy = true
        projectSetupError = nil
        Task { [weak self] in guard let self else { return }
            do {
                let data = try await runSomaHelper(args: ["--rollback-project-ai-setup", "--project-root", selectedProjectRoot])
                let report = try JSONDecoder().decode(ProjectAISetupReport.self, from: data)
                await MainActor.run {
                    self.projectSetupReport = report
                    self.projectSetupBusy = false
                    self.projectSetupError = nil
                    self.mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let restored = report.files_changed?.count ?? 0
                    self.mcpInstallStatus = "Project AI setup rollback \(report.status ?? "unknown"): restored \(restored) files."
                    self.verifyCodexConfig(updateStatusText: false)
                    self.verifyGeminiConfig(updateStatusText: false)
                    self.verifyHermesConfig(updateStatusText: false)
                    self.loadStructuredLogs()
                }
            } catch {
                await MainActor.run {
                    self.projectSetupBusy = false
                    self.projectSetupError = error.localizedDescription
                    self.mcpInstallStatus = "Project AI setup rollback failed: \(error.localizedDescription)"
                }
            }
        }
    }

func runSomaFirstSetup() {
        guard !selectedProjectRoot.isEmpty else {
            projectSetupError = "Select a project root before running Soma First setup."
            return
        }
        projectSetupBusy = true
        projectSetupError = nil
        mcpInstallStatus = "Soma First setup started."
        Task { [weak self] in guard let self else { return }
            do {
                let analysisData = try await runSomaHelper(args: ["--analyze-project-ai-setup", "--project-root", selectedProjectRoot])
                let setupReport = try JSONDecoder().decode(ProjectAISetupReport.self, from: analysisData)

                let codexData = try await runSomaHelper(args: ["--install-codex-config", "--project-root", selectedProjectRoot])
                let codexInstall = try JSONDecoder().decode(ClientConfigInstallStatus.self, from: codexData)
                let geminiData = try await runSomaHelper(args: ["--install-gemini-config", "--project-root", selectedProjectRoot])
                let geminiInstall = try JSONDecoder().decode(ClientConfigInstallStatus.self, from: geminiData)
                let hermesData = try await runSomaHelper(args: ["--install-hermes-config", "--project-root", selectedProjectRoot])
                let hermesInstall = try JSONDecoder().decode(ClientConfigInstallStatus.self, from: hermesData)

                let smokeScript = try scriptURL(named: "verify_soma_mcp_clients")
                let smokeData = try await runScript(
                    path: pythonPath(),
                    args: [
                        smokeScript.path,
                        "--project-root", selectedProjectRoot,
                        "--clients", "codex,gemini,hermes",
                        "--python", pythonPath(),
                    ]
                )
                let smoke = try JSONDecoder().decode(MCPSmokeReport.self, from: smokeData)

                let packetData = try await runSomaHelper(args: [
                    "--project-root", selectedProjectRoot,
                    "--run-tool", "soma_prepare_context",
                    #"{"goal":"Soma First setup smoke: identify project structure and current git state.","budget":"micro","depth":"deterministic","client":"swift","workflow":"soma_first_setup"}"#
                ])
                let packet = try JSONDecoder().decode(GatherBundle.self, from: packetData)

                await MainActor.run {
                    self.projectSetupReport = setupReport
                    self.codexConfigStatus = ClientConfigStatus(
                        status: codexInstall.status,
                        summary: codexInstall.summary,
                        config_path: codexInstall.config_path,
                        soma_installed: codexInstall.soma_installed,
                        direct_nexus_exposed: nil,
                        tool_exposure_clean: nil,
                        actual_project_root: codexInstall.actual_project_root,
                        expected_project_root: codexInstall.expected_project_root,
                        project_matches: codexInstall.project_matches,
                        issues: codexInstall.issues
                    )
                    self.geminiConfigStatus = ClientConfigStatus(
                        status: geminiInstall.status,
                        summary: geminiInstall.summary,
                        config_path: geminiInstall.config_path,
                        soma_installed: geminiInstall.soma_installed,
                        direct_nexus_exposed: nil,
                        tool_exposure_clean: nil,
                        actual_project_root: geminiInstall.actual_project_root,
                        expected_project_root: geminiInstall.expected_project_root,
                        project_matches: geminiInstall.project_matches,
                        issues: geminiInstall.issues
                    )
                    self.hermesConfigStatus = ClientConfigStatus(
                        status: hermesInstall.status,
                        summary: hermesInstall.summary,
                        config_path: hermesInstall.config_path,
                        soma_installed: hermesInstall.soma_installed,
                        direct_nexus_exposed: nil,
                        tool_exposure_clean: nil,
                        actual_project_root: hermesInstall.actual_project_root,
                        expected_project_root: hermesInstall.expected_project_root,
                        project_matches: hermesInstall.project_matches,
                        issues: hermesInstall.issues
                    )
                    self.mcpSmokeReport = smoke
                    self.gatherBundle = packet
                    self.projectSetupBusy = false
                    self.projectSetupError = nil
                    self.mcpConfigPreview = String(data: smokeData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let degraded = smoke.summary?.config_degraded ?? []
                    let packetStatus = packet.error == nil ? "ready" : "degraded"
                    self.mcpInstallStatus = degraded.isEmpty
                        ? "Soma First setup ready: configs installed, MCP smoke passed, first packet \(packetStatus)."
                        : "Soma First setup degraded: \(degraded.joined(separator: ", ")). First packet \(packetStatus)."
                    self.loadStructuredLogs()
                    self.loadAuditReport()
                }
            } catch {
                await MainActor.run {
                    self.projectSetupBusy = false
                    self.projectSetupError = error.localizedDescription
                    self.mcpInstallStatus = "Soma First setup failed: \(error.localizedDescription)"
                }
            }
        }
    }

func loadMCPSmokeReport() {
        Task { [weak self] in guard let self else { return }
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".soma/mcp_smoke/latest.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            do {
                let data = try Data(contentsOf: file)
                let report = try JSONDecoder().decode(MCPSmokeReport.self, from: data)
                await MainActor.run {
                    self.mcpSmokeReport = report
                    self.codexConfigStatus = report.clients?["codex"]
                    self.geminiConfigStatus = report.clients?["gemini"]
                    self.hermesConfigStatus = report.clients?["hermes"]
                    self.mcpSmokeError = nil
                }
            } catch {
                await MainActor.run {
                    self.mcpSmokeError = "MCP smoke report unreadable: \(error.localizedDescription)"
                }
            }
        }
    }

func runMCPSmoke() {
        guard !selectedProjectRoot.isEmpty else {
            mcpSmokeError = "Select a project root before running MCP smoke."
            return
        }
        mcpSmokeBusy = true
        mcpSmokeError = nil
        logActivity("Running guarded MCP smoke for \((selectedProjectRoot as NSString).lastPathComponent)...")
        Task { [weak self] in guard let self else { return }
            do {
                let script = try scriptURL(named: "verify_soma_mcp_clients")
                let data = try await runScript(
                    path: pythonPath(),
                    args: [
                        script.path,
                        "--project-root", selectedProjectRoot,
                        "--clients", "codex,gemini,hermes",
                        "--python", pythonPath(),
                    ]
                )
                let report = try JSONDecoder().decode(MCPSmokeReport.self, from: data)
                await MainActor.run {
                    self.mcpSmokeReport = report
                    self.mcpSmokeBusy = false
                    self.mcpSmokeError = nil
                    self.codexConfigStatus = report.clients?["codex"]
                    self.geminiConfigStatus = report.clients?["gemini"]
                    self.hermesConfigStatus = report.clients?["hermes"]
                    self.mcpConfigPreview = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let failed = report.summary?.failed_tools?.joined(separator: ", ") ?? ""
                    let failedSuffix = failed.isEmpty ? "" : ", failed: \(failed)"
                    self.mcpInstallStatus = "MCP smoke \(report.status ?? "unknown"): \(report.summary?.smoked_tools ?? 0) tools ok, \(report.summary?.skipped_tools ?? 0) skipped\(failedSuffix)."
                    self.loadStructuredLogs()
                }
            } catch {
                await MainActor.run {
                    self.mcpSmokeBusy = false
                    self.mcpSmokeError = error.localizedDescription
                    self.mcpInstallStatus = "MCP smoke failed: \(error.localizedDescription)"
                    self.logActivity("MCP smoke failed: \(error.localizedDescription)")
                }
            }
        }
    }

func runLiveVerify() {
        guard !selectedProjectRoot.isEmpty else {
            mcpInstallStatus = "Select a project root before running live verification."
            return
        }
        Task { [weak self] in guard let self else { return }
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

func summarizeLiveVerify(_ status: LiveVerifyStatus) -> String {
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

}
