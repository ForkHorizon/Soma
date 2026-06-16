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
        Task { [weak self] in guard let self else { return }
            do {
                self.logActivity("Calling scout_pipeline.py...")
                let stepStart = Date()
                let result = try await self.runPythonChat(prompt: prompt, history: self.scoutHistory)
                let stepDuration = Date().timeIntervalSince(stepStart)
                await MainActor.run {
                    self.logActivity("Received response from \(ollama.modelName)", duration: stepDuration)
                    self.scoutTranscript += (result.response ?? "") + "\n"
                    self.scoutHistory = result.history ?? []
                    self.scoutLoading = false
                    ollama.checkStatus()
                    self.logActivity("Scout total time", duration: Date().timeIntervalSince(startTime))
                }
            } catch {
                await MainActor.run {
                    self.logActivity("Scout failed: \(error.localizedDescription)")
                    self.scoutTranscript += "⚠️ Error: \(error.localizedDescription)\n"
                    self.scoutLoading = false
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
        Task { [weak self] in guard let self else { return }
            do {
                self.relayPhase = .gathering
                let rootLabel = selectedProjectRoot.isEmpty ? "no selected root" : selectedProjectRoot
                self.logActivity("Preparing packet via Python router (\(rootLabel))...")
                let stepStart = Date()
                let bundle = try await self.runGather(
                    prompt: prompt,
                    projectRoot: selectedProjectRoot,
                    recentRoots: recentProjectRoots,
                    rawCapture: auditRawCaptureNextRun
                )
                let stepDuration = Date().timeIntervalSince(stepStart)
                if let error = bundle.error {
                    throw SomaError(error)
                }
                self.logActivity("Prepared \(bundle.packet_mode ?? "unknown") packet with \(bundle.evidence_items?.count ?? 0) items. Confidence: \(bundle.confidence ?? 0)", duration: stepDuration)
                await MainActor.run {
                    self.applyGatherBundle(bundle, prompt: prompt, startTime: startTime, ollama: ollama)
                }
            } catch {
                await MainActor.run {
                    self.logActivity("Relay failed: \(error.localizedDescription)")
                    self.relayPhase = .failed(error.localizedDescription)
                    self.relayError = error.localizedDescription
                    self.auditRawCaptureNextRun = false
                }
            }
        }
    }
    func applyGatherBundle(_ bundle: GatherBundle, prompt: String, startTime: Date, ollama: OllamaManager) {
        gatherBundle = bundle
        latestTokenSavings = bundle.token_savings
        auditRawCaptureNextRun = false
        showContextPanel = true
        relayPhase = .done
        ollama.checkStatus()
        loadAuditReport()
        logActivity("Prepared Codex packet (~\(bundle.estimated_tokens ?? 0) tokens)")
        logActivity("Evidence compile total time", duration: Date().timeIntervalSince(startTime))
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
    func runRusToPrompt(prompt: String) async throws -> RusToPromptResult {
        let scriptPath = try scriptURL(named: "soma_language_optimizer").path
        let pyPath = pythonPath()
        let env = scriptEnvironment(includeProjectRoot: false)
        return try await Task.detached(priority: .userInitiated) {
            let output = try await SomaViewModel.executeProcess(
                path: pyPath,
                args: [scriptPath, "--rus-to-prompt", prompt],
                environment: env
            )
            return try JSONDecoder().decode(RusToPromptResult.self, from: output)
        }.value
    }
    func runRusToPromptTranslate(prompt: String, translatorModel: String) async throws -> RusToPromptTranslationResult {
        let scriptPath = try scriptURL(named: "soma_language_optimizer").path
        let pyPath = pythonPath()
        let env = scriptEnvironment(includeProjectRoot: false)
        return try await Task.detached(priority: .userInitiated) {
            let output = try await SomaViewModel.executeProcess(
                path: pyPath,
                args: [
                    scriptPath,
                    "--rus-to-prompt-translate",
                    "--translator-model", translatorModel,
                    prompt,
                ],
                environment: env
            )
            return try JSONDecoder().decode(RusToPromptTranslationResult.self, from: output)
        }.value
    }
    func runRusToPromptImprove(prompt: String, analyzerModel: String) async throws -> RusToPromptImproveResult {
        let scriptPath = try scriptURL(named: "soma_language_optimizer").path
        let pyPath = pythonPath()
        let env = scriptEnvironment(includeProjectRoot: false)
        return try await Task.detached(priority: .userInitiated) {
            let output = try await SomaViewModel.executeProcess(
                path: pyPath,
                args: [
                    scriptPath,
                    "--rus-to-prompt-improve",
                    "--improver-model", analyzerModel,
                    prompt,
                ],
                environment: env
            )
            return try JSONDecoder().decode(RusToPromptImproveResult.self, from: output)
        }.value
    }
    func runRusToPromptConfidence(
        prompt: String,
        translation: String,
        improvedPrompt: String,
        pipelineStatus: String,
        warnings: [String],
        confidenceModel: String,
        reasoningEffort: String = RusToPromptSettingsStore.defaultConfidenceReasoning
    ) async throws -> RusToPromptConfidenceResult {
        let scriptPath = try scriptURL(named: "soma_language_optimizer").path
        let pyPath = pythonPath()
        let env = scriptEnvironment(includeProjectRoot: false)
        return try await Task.detached(priority: .userInitiated) {
            var args = [
                scriptPath,
                "--rus-to-prompt-confidence",
                "--confidence-model", confidenceModel,
                "--confidence-reasoning-effort", reasoningEffort,
                "--translation", translation,
                "--improved-prompt", improvedPrompt,
                "--pipeline-status", pipelineStatus,
            ]
            for warning in warnings where !warning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args.append("--warning")
                args.append(warning)
            }
            args.append(prompt)
            let output = try await SomaViewModel.executeProcess(
                path: pyPath,
                args: args,
                environment: env
            )
            return try JSONDecoder().decode(RusToPromptConfidenceResult.self, from: output)
        }.value
    }
}
