import Foundation
import SwiftUI
import AppKit

@MainActor
final class RelayViewModel: ObservableObject {
    @Published var relayPrompt = ""
    @Published var relayPhase: RelayPhase = .idle
    @Published var gatherBundle: GatherBundle?
    @Published var relayResponse: RelayResponse?
    @Published var showContextPanel = false
    @Published var relayError: String?

    func resetState(somaViewModel: SomaViewModel) {
        relayPrompt = ""
        relayPhase = .idle
        gatherBundle = nil
        relayResponse = nil
        showContextPanel = false
        relayError = nil
        somaViewModel.activityLogs = [] // relay also cleared this in SomaViewModel.resetState
    }

    func runRelay(ollama: OllamaManager, somaViewModel: SomaViewModel) {
        let prompt = relayPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        relayPrompt = ""
        gatherBundle = nil
        relayResponse = nil
        relayError = nil
        showContextPanel = false
        somaViewModel.activityLogs = []
        somaViewModel.logActivity("Starting Relay: \(prompt)")
        let startTime = Date()

        Task {
            do {
                relayPhase = .gathering
                let rootLabel = somaViewModel.selectedProjectRoot.isEmpty ? "no selected root" : somaViewModel.selectedProjectRoot
                somaViewModel.logActivity("Preparing packet via Python router (\(rootLabel))...")
                let stepStart = Date()
                let bundle = try await runGather(
                    prompt: prompt,
                    projectRoot: somaViewModel.selectedProjectRoot,
                    recentRoots: somaViewModel.recentProjectRoots,
                    somaViewModel: somaViewModel
                )
                let stepDuration = Date().timeIntervalSince(stepStart)

                if let error = bundle.error {
                    throw SomaError(error)
                }
                somaViewModel.logActivity("Prepared \(bundle.packet_mode ?? "unknown") packet with \(bundle.evidence_items?.count ?? 0) items. Confidence: \(bundle.confidence ?? 0)", duration: stepDuration)

                await MainActor.run {
                    gatherBundle = bundle
                    showContextPanel = true
                    relayPhase = .done
                    ollama.checkStatus()
                    somaViewModel.logActivity("Prepared Codex packet (~\(bundle.estimated_tokens ?? 0) tokens)")
                    somaViewModel.logActivity("Evidence compile total time", duration: Date().timeIntervalSince(startTime))
                }
            } catch {
                await MainActor.run {
                    somaViewModel.logActivity("Relay failed: \(error.localizedDescription)")
                    relayPhase = .failed(error.localizedDescription)
                    relayError = error.localizedDescription
                }
            }
        }
    }

    private func runGather(prompt: String, projectRoot: String, recentRoots: [String], somaViewModel: SomaViewModel) async throws -> GatherBundle {
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
                "--analysis-depth", somaViewModel.analysisDepth.rawValue,
            ]
        )
        return try JSONDecoder().decode(GatherBundle.self, from: output)
    }
}
