import Combine
import Foundation
import SwiftUI
final class OllamaManager: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isOllamaRunning = false
    @Published var isBusy = false
    @Published var installedModels: [OllamaInstalledModel] = []
    @Published var loadedModelNames: Set<String> = []
    @Published var tagsError: String?
    @Published var modelName: String {
        didSet { persistModelName(modelName, for: .scout) }
    }
    @Published var rankerModelName: String {
        didSet { persistModelName(rankerModelName, for: .ranker) }
    }
    @Published var analystModelName: String {
        didSet { persistModelName(analystModelName, for: .analyst) }
    }
    @Published var translatorModelName: String {
        didSet { persistModelName(translatorModelName, for: .translator) }
    }
    private var timer: Timer?
    init() {
        modelName = LocalModelSettingsStore.model(for: .scout)
        rankerModelName = LocalModelSettingsStore.model(for: .ranker)
        analystModelName = LocalModelSettingsStore.model(for: .analyst)
        translatorModelName = LocalModelSettingsStore.model(for: .translator)
        startPolling()
    }
    deinit {
        timer?.invalidate()
    }
    func startPolling() {
        timer?.invalidate()   // never stack a second poll timer if called again
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
        refreshInstalledModels()
        checkStatus()
    }
    func modelName(for role: LocalModelRole) -> String {
        switch role {
        case .scout: return modelName
        case .ranker: return rankerModelName
        case .analyst: return analystModelName
        case .translator: return translatorModelName
        }
    }
    func updateModel(_ model: String, for role: LocalModelRole) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch role {
        case .scout:
            modelName = trimmed
            checkStatus()
        case .ranker:
            rankerModelName = trimmed
        case .analyst:
            analystModelName = trimmed
        case .translator:
            translatorModelName = trimmed
        }
    }
    func configuredRole(for model: String, stage: String? = nil) -> LocalModelRole? {
        let normalized = model.lowercased()
        if !modelName.isEmpty && normalized == modelName.lowercased() { return .scout }
        if !rankerModelName.isEmpty && normalized == rankerModelName.lowercased() { return .ranker }
        if !analystModelName.isEmpty && normalized == analystModelName.lowercased() { return .analyst }
        if !translatorModelName.isEmpty && normalized == translatorModelName.lowercased() { return .translator }
        if let stage {
            return LocalModelRole.allCases.first { $0.stageHints.contains(stage) }
        }
        return nil
    }
    func isConfiguredModelInstalled(_ role: LocalModelRole) -> Bool {
        let model = modelName(for: role)
        guard !model.isEmpty else { return true }
        return installedModels.contains { $0.name.lowercased() == model.lowercased() }
    }
    func isLoaded(_ model: String) -> Bool {
        guard !model.isEmpty else { return false }
        return loadedModelNames.contains { $0.lowercased().hasPrefix(model.lowercased()) }
    }
    func refreshInstalledModels() {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            if let errorMsg = error?.localizedDescription {
                Task { @MainActor [weak self] in
                    self?.tagsError = errorMsg
                    self?.installedModels = []
                }
                return
            }

            guard let data else {
                Task { @MainActor [weak self] in
                    self?.tagsError = "Ollama returned no model list."
                    self?.installedModels = []
                }
                return
            }

            do {
                let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
                let sorted = decoded.models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                Task { @MainActor [weak self] in
                    self?.installedModels = sorted
                    self?.tagsError = nil
                }
            } catch {
                let decodingError = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.tagsError = decodingError
                    self?.installedModels = []
                }
            }
        }.resume()
    }
    func checkStatus() {
        guard let url = URL(string: "http://127.0.0.1:11434/api/ps") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            if error != nil {
                Task { @MainActor [weak self] in
                    self?.updateStatus(isRunning: false, loadedModels: [])
                }
                return
            }

            let loaded: Set<String>
            if
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let models = json["models"] as? [[String: Any]]
            {
                loaded = Set(models.compactMap { ($0["name"] as? String)?.lowercased() })
            } else {
                loaded = []
            }

            Task { @MainActor [weak self] in
                self?.updateStatus(isRunning: true, loadedModels: loaded)
            }
        }.resume()
    }
    private func updateStatus(isRunning: Bool, loadedModels: Set<String>) {
        if isOllamaRunning != isRunning {
            isOllamaRunning = isRunning
        }
        if loadedModelNames != loadedModels {
            loadedModelNames = loadedModels
        }
        let scoutLoaded = isRunning && isLoaded(modelName)
        if isModelLoaded != scoutLoaded {
            isModelLoaded = scoutLoaded
        }
    }
    func launchOllama() {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ollama")
            process.arguments = ["serve"]
            try? process.run()
            Thread.sleep(forTimeInterval: 4)
            DispatchQueue.main.async {
                self.isBusy = false
                self.refreshInstalledModels()
                self.checkStatus()
            }
        }
    }
    /// Idle keep-loaded duration shared with the Voice-to-Text ASR server.
    /// 0 means unload immediately; the shared default is the user-selected one hour.
    private var keepAliveSeconds: Int {
        let minutes = UserDefaults.standard.object(forKey: "modelKeepLoadedMinutes") as? Int ?? 60
        return minutes * 60
    }
    func startModel() { sendKeepAlive(keepAliveSeconds, model: modelName) }
    func stopModel() { sendKeepAlive(0, model: modelName) }
    func loadModel(_ model: String) {
        sendKeepAlive(keepAliveSeconds, model: model)
    }
    func unloadModel(_ model: String) {
        sendKeepAlive(0, model: model)
    }
    private func sendKeepAlive(_ keepAlive: Int, model: String) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        isBusy = true
        Task.detached {
            let body = try? JSONSerialization.data(withJSONObject: [
                "model": trimmedModel,
                "prompt": "",
                "keep_alive": keepAlive,
                "stream": false,
            ])
            var request = request
            request.httpBody = body

            URLSession.shared.dataTask(with: request) { _, _, _ in
                DispatchQueue.main.async {
                    self.isBusy = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.refreshInstalledModels()
                        self.checkStatus()
                    }
                }
            }.resume()
        }
    }
    private func persistModelName(_ model: String, for role: LocalModelRole) {
        LocalModelSettingsStore.setModel(model, for: role)
    }
}
nonisolated private struct OllamaTagsResponse: Decodable {
    let models: [OllamaInstalledModel]
}
