import Combine
import Foundation
import SwiftUI

final class OllamaManager: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isOllamaRunning = false
    @Published var isBusy = false

    let modelName = ProcessInfo.processInfo.environment["SOMA_LOCAL_MODEL"] ?? "gemma4:e4b"
    let rankerModelName = ProcessInfo.processInfo.environment["SOMA_RANKER_MODEL"] ?? "gemma4:e4b"
    let analystModelName = ProcessInfo.processInfo.environment["SOMA_ANALYST_MODEL"] ?? "qwen3-coder:30b-a3b-q4_K_M"
    private var timer: Timer?

    init() { startPolling() }

    func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
        checkStatus()
    }

    func checkStatus() {
        guard let url = URL(string: "http://127.0.0.1:11434/api/ps") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if error != nil {
                    self.updateStatus(isRunning: false, isLoaded: false)
                    return
                }

                var isLoaded = false
                if
                    let data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let models = json["models"] as? [[String: Any]]
                {
                    isLoaded = models.contains {
                        ($0["name"] as? String)?.lowercased().hasPrefix(self.modelName.lowercased()) == true
                    }
                }
                self.updateStatus(isRunning: true, isLoaded: isLoaded)
            }
        }.resume()
    }

    private func updateStatus(isRunning: Bool, isLoaded: Bool) {
        if isOllamaRunning != isRunning {
            isOllamaRunning = isRunning
        }
        if isModelLoaded != isLoaded {
            isModelLoaded = isLoaded
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
                self.checkStatus()
            }
        }
    }

    func startModel() { sendKeepAlive(-1) }
    func stopModel() { sendKeepAlive(0) }

    private func sendKeepAlive(_ keepAlive: Int) {
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "prompt": "",
            "keep_alive": keepAlive,
            "stream": false,
        ])
        isBusy = true

        URLSession.shared.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.async {
                self.isBusy = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.checkStatus()
                }
            }
        }.resume()
    }
}
