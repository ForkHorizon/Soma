import Foundation

extension ASRManager {
    // MARK: Warm server lifecycle

    /// Returns the live server port, launching the server if needed. The port is
    /// OS-assigned (server binds :0) and reported via the port file, so we never
    /// collide with other local servers the user runs.
    func ensureServerReady() async throws -> Int {
        if let p = port, await isOurServer(p) { return p }
        if let p = readPortFile(), await isOurServer(p) {
            port = p
            return p
        }

        try launchServer()
        status = "Loading model… (first run is slow)"
        for _ in 0..<120 {  // up to ~60s for the server to bind and write its port
            try await Task.sleep(nanoseconds: 500_000_000)
            if let p = readPortFile(), await isOurServer(p) {
                port = p
                return p
            }
        }
        let log = (try? String(contentsOf: logFileURL, encoding: .utf8))?.suffix(400) ?? ""
        throw SomaError("ASR server did not start. Check the engines folder and the '\(engine)' venv.\n\(log)")
    }

    func readPortFile() -> Int? {
        guard let s = try? String(contentsOf: portFileURL, encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True only if our server answers /health — guards against a stale port file
    /// or a foreign server squatting on the port.
    func isOurServer(_ port: Int) async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
            (resp as? HTTPURLResponse)?.statusCode == 200,
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        guard obj["ok"] as? Bool == true else { return false }
        // A live server running a different engine than the current selection is
        // not "ours" — force a relaunch so the picked engine actually takes effect.
        if let running = obj["engine"] as? String, running != engine { return false }
        return true
    }

    func teardownServer() {
        serverProcess?.terminate()
        serverProcess = nil
        port = nil
        try? FileManager.default.removeItem(at: portFileURL)
    }

    func launchServer() throws {
        if let p = serverProcess, p.isRunning { return }
        try? FileManager.default.removeItem(at: portFileURL)
        let root = enginesRoot.trimmingCharacters(in: .whitespaces)
        let venvPython = "\(root)/venv-\(engine)/bin/python"
        guard FileManager.default.fileExists(atPath: venvPython) else {
            throw SomaError("ASR venv for '\(engineTitle)' not found at \(venvPython)")
        }
        let script = "\(root)/asr_server.py"
        guard FileManager.default.fileExists(atPath: script) else {
            throw SomaError("asr_server.py not found at \(script)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: venvPython)
        process.arguments = [script]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        var env = ProcessInfo.processInfo.environment
        // Xcode injects Metal API-validation vars into the app's env; if they leak into
        // the torch/MPS child its compute kernels abort (SIGABRT) under the stricter
        // validation layer. Strip them so the server runs like it does from a terminal.
        for key in [
            "METAL_DEVICE_WRAPPER_TYPE", "METAL_DEBUG_ERROR_MODE", "METAL_ERROR_MODE",
            "MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION",
        ] {
            env.removeValue(forKey: key)
        }
        // A GUI app launched from Finder/Xcode inherits a minimal PATH (no /opt/homebrew/bin),
        // so child tools like ffmpeg aren't found. Prepend the Homebrew/local bins.
        let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + basePath
        env["ASR_ENGINE"] = engine
        env["ASR_PORT"] = "0"  // OS picks a free port
        env["ASR_PORT_FILE"] = portFileURL.path
        env["ASR_IDLE_SECONDS"] = String(keepLoadedMinutes * 60)
        env["HF_HOME"] = "\(modelsRoot)/hf"  // Whisper (mlx) weights cache
        env["ASR_GIGAAM_ROOT"] = "\(modelsRoot)/gigaam"  // GigaAM checkpoint dir
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        // Capture stdout+stderr so a failed start is diagnosable.
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            process.standardOutput = handle
            process.standardError = handle
        }
        try process.run()
        serverProcess = process
    }
}
