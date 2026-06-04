import Foundation
import SwiftUI
import AppKit
import Combine
@MainActor
final class ScoutViewModel: ObservableObject {
    @Published var scoutPrompt = ""
    @Published var scoutTranscript = ""
    @Published var scoutHistory: [[String: AnyCodable]] = []
    @Published var scoutLoading = false
    func resetState() {
        scoutPrompt = ""
        scoutTranscript = ""
        scoutHistory = []
        scoutLoading = false
    }
    func runScout(ollama: OllamaManager, somaViewModel: SomaViewModel) {
        let prompt = scoutPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        scoutLoading = true
        scoutTranscript += "\n> \(prompt)\n\n"
        scoutPrompt = ""
        somaViewModel.logActivity("Starting Scout: \(prompt)")
        let startTime = Date()
        Task { [weak self] in guard let self else { return }
            do {
                somaViewModel.logActivity("Calling scout_pipeline.py...")
                let stepStart = Date()
                let result = try await self.runPythonChat(prompt: prompt, history: self.scoutHistory, somaViewModel: somaViewModel)
                let stepDuration = Date().timeIntervalSince(stepStart)
                await MainActor.run {
                    somaViewModel.logActivity("Received response from \(ollama.modelName)", duration: stepDuration)
                    self.scoutTranscript += (result.response ?? "") + "\n"
                    self.scoutHistory = result.history ?? []
                    self.scoutLoading = false
                    ollama.checkStatus()
                    somaViewModel.logActivity("Scout total time", duration: Date().timeIntervalSince(startTime))
                }
            } catch {
                await MainActor.run {
                    somaViewModel.logActivity("Scout failed: \(error.localizedDescription)")
                    self.scoutTranscript += "⚠️ Error: \(error.localizedDescription)\n"
                    self.scoutLoading = false
                }
            }
        }
    }
    private func runPythonChat(prompt: String, history: [[String: AnyCodable]], somaViewModel: SomaViewModel) async throws -> OllamaResponse {
        let script = try somaViewModel.scriptURL(named: "scout_pipeline")
        let historyJSON = (try? String(data: JSONEncoder().encode(history), encoding: .utf8)) ?? "[]"
        let output = try await somaViewModel.runScript(path: somaViewModel.pythonPath(), args: [script.path, prompt, historyJSON])
        return try JSONDecoder().decode(OllamaResponse.self, from: output)
    }
}
