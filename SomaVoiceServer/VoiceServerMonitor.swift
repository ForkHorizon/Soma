import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class VoiceServerMonitor: ObservableObject {
    @Published var status: VoiceServerStatus?
    @Published var message = "Checking server..."
    @Published var isRefreshing = false
    @Published var idleSeconds = 900

    private let label = "com.daliys.soma.voice-server"
    private let pollSeconds: UInt64 = 3
    private var pollTask: Task<Void, Never>?

    init() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: (self?.pollSeconds ?? 3) * 1_000_000_000)
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    var serverOnline: Bool { status?.ok == true }
    var backendRunning: Bool { status?.backend.backend_running == true }
    var modelLoaded: Bool { status?.backend.backend_loaded == true }
    var hasWork: Bool { (status?.queue.running ?? 0) > 0 || (status?.queue.queued ?? 0) > 0 }

    var menuBarSymbol: String {
        if hasWork { return "clock.badge.fill" }
        if serverOnline && modelLoaded { return "memorychip.fill" }
        if serverOnline { return "server.rack" }
        return "server.rack"
    }

    var serverURL: String {
        "http://127.0.0.1:\(connection()?.port ?? 18765)"
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let connection = connection() else {
            status = nil
            message = "Server is stopped or not installed."
            return
        }
        do {
            var request = URLRequest(url: connection.url.appendingPathComponent("v1/status"))
            if !connection.token.isEmpty {
                request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
            }
            request.timeoutInterval = 4
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                status = nil
                message = "Server returned an error."
                return
            }
            let decoded = try JSONDecoder().decode(VoiceServerStatus.self, from: data)
            status = decoded
            idleSeconds = decoded.settings.idle_seconds
            message = "Online"
        } catch {
            status = nil
            message = "Unavailable: \(error.localizedDescription)"
        }
    }

    func updateIdleSeconds(_ seconds: Int) async {
        idleSeconds = seconds
        guard let connection = connection() else { return }
        do {
            var request = URLRequest(url: connection.url.appendingPathComponent("v1/settings"))
            request.httpMethod = "PATCH"
            if !connection.token.isEmpty {
                request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 5
            request.httpBody = try JSONSerialization.data(withJSONObject: ["idle_seconds": seconds])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SomaVoiceServerError("Settings update failed") }
            status = try JSONDecoder().decode(VoiceServerStatus.self, from: data)
            message = "Settings saved"
        } catch {
            message = "Could not save settings: \(error.localizedDescription)"
        }
    }

    func startServer() async {
        let uid = String(getuid())
        _ = runLaunchctl(["bootstrap", "gui/\(uid)", launchAgentURL.path])
        _ = runLaunchctl(["kickstart", "gui/\(uid)/\(label)"])
        try? await Task.sleep(nanoseconds: 800_000_000)
        await refresh()
    }

    func stopServer() async {
        let uid = String(getuid())
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        status = nil
        message = "Stopped"
    }

    func quitAndStop() async {
        await stopServer()
        NSApplication.shared.terminate(nil)
    }

    func openLogs() {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        let files = [
            logs.appendingPathComponent("soma-voice-server.out.log"),
            logs.appendingPathComponent("soma-voice-server.err.log"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        if files.isEmpty {
            NSWorkspace.shared.open(logs)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    func copyServerURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serverURL, forType: .string)
        message = "Server URL copied"
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private struct ServerConnection {
        let port: Int
        let token: String

        var url: URL {
            URL(string: "http://127.0.0.1:\(port)")!
        }
    }

    private func connection() -> ServerConnection? {
        guard let data = try? Data(contentsOf: launchAgentURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let arguments = plist["ProgramArguments"] as? [String],
            let portText = value(after: "--port", in: arguments),
            let port = Int(portText), (1...65535).contains(port)
        else { return nil }
        let environment = plist["EnvironmentVariables"] as? [String: String]
        let token = environment?["SOMA_VOICE_TOKEN"] ?? value(after: "--token", in: arguments) ?? ""
        return ServerConnection(port: port, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func runLaunchctl(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            message = error.localizedDescription
            return false
        }
    }
}

struct SomaVoiceServerError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

struct VoiceServerStatus: Decodable {
    let ok: Bool
    let server: ServerInfo
    let settings: Settings
    let queue: QueueInfo
    let backend: BackendInfo

    struct ServerInfo: Decodable {
        let uptime_seconds: Double
        let default_engine: String
    }

    struct Settings: Decodable {
        let idle_seconds: Int
    }

    struct QueueInfo: Decodable {
        let queued: Int
        let running: Int
        let max: Int
        let active_job: JobInfo?
        let done: Int
        let failed: Int
    }

    struct BackendInfo: Decodable {
        let active_engine: String?
        let active_port: Int?
        let backend_running: Bool
        let backend_loaded: Bool
        let backend_idle_seconds: Double?
        let backend_last_used_seconds_ago: Double?
    }

    struct JobInfo: Decodable {
        let job_id: String
        let status: String
        let engine: String
        let queued_seconds: Double?
        let infer_seconds: Double?
    }
}
