import Foundation
import SwiftUI
import AppKit
import Combine
@MainActor
final class PromptCompilerViewModel: ObservableObject {
    @Published var weakPrompt = ""
    @Published var phase: RelayPhase = .idle
    @Published var gatherBundle: GatherBundle?
    @Published var showEvidence = true
    @Published var errorMessage: String?
    func resetState(somaViewModel: SomaViewModel) {
        weakPrompt = ""
        phase = .idle
        gatherBundle = nil
        showEvidence = true
        errorMessage = nil
        somaViewModel.activityLogs = []
    }
    func compilePrompt(somaViewModel: SomaViewModel, ollama: OllamaManager) {
        let prompt = weakPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        weakPrompt = ""
        gatherBundle = nil
        errorMessage = nil
        showEvidence = true
        somaViewModel.activityLogs = []
        somaViewModel.logActivity("Starting Prompt Compiler: \(prompt)")
        let startTime = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                self.phase = .gathering
                let rootLabel = somaViewModel.selectedProjectRoot.isEmpty ? "no selected root" : somaViewModel.selectedProjectRoot
                somaViewModel.logActivity("Planning collection and compiling strong prompt via analyst gather (\(rootLabel))...")
                let stepStart = Date()
                let bundle = try await self.runAnalystGather(
                    prompt: prompt,
                    projectRoot: somaViewModel.selectedProjectRoot,
                    recentRoots: somaViewModel.recentProjectRoots,
                    somaViewModel: somaViewModel
                )
                let stepDuration = Date().timeIntervalSince(stepStart)
                if let error = bundle.error {
                    throw SomaError(self.friendlyError(error))
                }
                await MainActor.run {
                    self.gatherBundle = bundle
                    somaViewModel.latestTokenSavings = bundle.token_savings
                    self.phase = .done
                    ollama.checkStatus()
                    somaViewModel.loadAuditReport()
                    somaViewModel.logActivity(
                        "Compiled strong prompt with \(bundle.evidence_items?.count ?? 0) evidence items", duration: stepDuration)
                    somaViewModel.logActivity("Prompt compile total time", duration: Date().timeIntervalSince(startTime))
                }
            } catch {
                await MainActor.run {
                    let message = self.friendlyError(error.localizedDescription)
                    somaViewModel.logActivity("Prompt Compiler failed: \(message)")
                    self.phase = .failed(message)
                    self.errorMessage = message
                }
            }
        }
    }
    private func runAnalystGather(prompt: String, projectRoot: String, recentRoots: [String], somaViewModel: SomaViewModel) async throws
        -> GatherBundle
    {
        let script = try somaViewModel.scriptURL(named: "scout_pipeline")
        let recentRootsJSON = (try? String(data: JSONEncoder().encode(recentRoots), encoding: .utf8)) ?? "[]"
        let output = try await somaViewModel.runScript(
            path: somaViewModel.pythonPath(),
            args: [
                script.path,
                prompt,
                "--mode", "gather",
                "--project-root", projectRoot,
                "--recent-roots-json", recentRootsJSON,
                "--token-budget", "balanced",
                "--analysis-depth", "analyst",
                "--packet-profile", "prompt_compiler",
                "--planning-mode", "auto",
            ]
        )
        return try decodeGatherBundle(output)
    }
    private func decodeGatherBundle(_ output: Data) throws -> GatherBundle {
        do {
            return try JSONDecoder().decode(GatherBundle.self, from: output)
        } catch {
            let preview = String(data: Data(output.prefix(800)), encoding: .utf8) ?? "<non-utf8 output>"
            throw SomaError(
                "Prompt Compiler returned JSON that the app could not decode: \(decodeErrorSummary(error)). Output starts with: \(preview)")
        }
    }
    private func decodeErrorSummary(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let value = context.codingPath.map(\.stringValue).joined(separator: ".")
            return value.isEmpty ? "<root>" : value
        }
        switch error {
        case DecodingError.typeMismatch(let type, let context):
            return "type mismatch for \(type) at \(path(context)): \(context.debugDescription)"
        case DecodingError.valueNotFound(let type, let context):
            return "missing value for \(type) at \(path(context)): \(context.debugDescription)"
        case DecodingError.keyNotFound(let key, let context):
            return "missing key \(key.stringValue) at \(path(context)): \(context.debugDescription)"
        case DecodingError.dataCorrupted(let context):
            return "data corrupted at \(path(context)): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }
    private func friendlyError(_ message: String) -> String {
        if message.contains("Select a project root") || message.contains("project context") {
            return "This prompt needs local project context. Select a project root in the top bar, then compile again."
        }
        return message
    }
}
