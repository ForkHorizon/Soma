import Foundation

enum MCPError: Error {
    case invalidRequest
    case toolExecutionFailed(String)
}

struct MCPRequest: Codable, Sendable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: [String: AnyCodable]?
}

struct MCPResponse: Codable, Sendable {
    let jsonrpc: String
    let id: Int
    let result: [String: AnyCodable]?
    let error: MCPErrorResponse?
}

struct MCPErrorResponse: Codable, Sendable {
    let code: Int
    let message: String
}

actor SomaMCPCoordinator {
    private let pythonExecutable: String = "/opt/homebrew/bin/python3"
    private let scoutPipelinePath: String

    private var pythonProcess: Process?
    private var pythonStdin: Pipe?
    private var pythonStdout: Pipe?
    private var pendingRequests: [Int: CheckedContinuation<[String: AnyCodable], Error>] = [:]
    private var requestCounter: Int = 1000
    private var isStartingProcess = false

    init() {
        scoutPipelinePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("scout_pipeline.py").path
    }

    nonisolated func startStdioServer() {
        let inputHandle = FileHandle.standardInput
        let outputHandle = FileHandle.standardOutput

        inputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return } // EOF

            if let requestLine = String(data: data, encoding: .utf8) {
                let lines = requestLine.components(separatedBy: .newlines)
                for line in lines where !line.isEmpty {
                    if let reqData = line.data(using: .utf8),
                       let request = try? JSONDecoder().decode(MCPRequest.self, from: reqData) {
                        Task { [weak self] in
                            await self?.handleRequest(request, outputHandle: outputHandle)
                        }
                    }
                }
            }
        }

        RunLoop.main.run()
    }

    private func startPythonBackendIfNeeded() async throws {
        if let process = pythonProcess, process.isRunning {
            return
        }

        if isStartingProcess {
            // Wait briefly for the process to be started by another task
            while isStartingProcess {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
            if let process = pythonProcess, process.isRunning {
                return
            }
        }

        isStartingProcess = true
        defer { isStartingProcess = false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath())

        let somaMcpServerPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("soma_mcp_server.py").path

        process.arguments = [somaMcpServerPath, "--daemon"]

        let stdin = Pipe()
        let stdout = Pipe()

        process.standardInput = stdin
        process.standardOutput = stdout

        try process.run()

        self.pythonProcess = process
        self.pythonStdin = stdin
        self.pythonStdout = stdout

        Task {
            await readPythonDaemonOutput()
        }
    }

    private func readPythonDaemonOutput() async {
        guard let stdout = pythonStdout else { return }

        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8) else { continue }
                if let response = try? JSONDecoder().decode(MCPResponse.self, from: data) {
                    if let continuation = pendingRequests.removeValue(forKey: response.id) {
                        if let error = response.error {
                            continuation.resume(throwing: MCPError.toolExecutionFailed(error.message))
                        } else {
                            continuation.resume(returning: response.result ?? [:])
                        }
                    }
                }
            }
        } catch {
            print("Error reading from python daemon: \(error)")
        }
    }

    private func handleRequest(_ request: MCPRequest, outputHandle: FileHandle) async {
        var response: MCPResponse
        do {
            let result = try await executeTool(method: request.method, params: request.params)
            response = MCPResponse(jsonrpc: "2.0", id: request.id, result: result, error: nil)
        } catch {
            let errResp = MCPErrorResponse(code: -32000, message: error.localizedDescription)
            response = MCPResponse(jsonrpc: "2.0", id: request.id, result: nil, error: errResp)
        }

        if let respData = try? JSONEncoder().encode(response),
           var respStr = String(data: respData, encoding: .utf8) {
            respStr += "\n"
            outputHandle.write(respStr.data(using: .utf8)!)
        }
    }

    private func executeTool(method: String, params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
        switch method {
        case "soma_prepare_context", "soma_get_map", "soma_ask", "soma_inspect",
             "soma_scene", "soma_execute", "soma_debug", "soma_delta",
             "soma_apply", "soma_remember", "soma_review", "soma_code_context":
            return try await executePythonTool(tool: method, params: params)
        case "tools/list":
            return listTools()
        default:
            throw MCPError.invalidRequest
        }
    }

    private func executePythonTool(tool: String, params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
        try await startPythonBackendIfNeeded()

        guard let stdin = pythonStdin else {
            throw MCPError.toolExecutionFailed("Python backend not running")
        }

        let requestId = requestCounter
        requestCounter += 1

        let request = MCPRequest(jsonrpc: "2.0", id: requestId, method: tool, params: params)
        let requestData = try JSONEncoder().encode(request)
        guard var requestStr = String(data: requestData, encoding: .utf8) else {
            throw MCPError.toolExecutionFailed("Failed to encode request")
        }
        requestStr += "\n"

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation
            do {
                try stdin.fileHandleForWriting.write(contentsOf: requestStr.data(using: .utf8)!)
            } catch {
                pendingRequests.removeValue(forKey: requestId)
                continuation.resume(throwing: MCPError.toolExecutionFailed("Failed to write to python backend"))
            }
        }
    }

    nonisolated private func pythonPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3") {
            return "/opt/homebrew/bin/python3"
        }
        return "/usr/bin/python3"
    }

    nonisolated private func listTools() -> [String: AnyCodable] {
         let tools: [[String: AnyCodable]] = [
            ["name": AnyCodable("soma_prepare_context"), "description": AnyCodable("Compile a bounded evidence packet.")],
            ["name": AnyCodable("soma_get_map"), "description": AnyCodable("Return a compact living project map.")],
            ["name": AnyCodable("soma_ask"), "description": AnyCodable("Answer a project question with Graphify context.")],
            ["name": AnyCodable("soma_inspect"), "description": AnyCodable("Inspect a Unity object or component.")],
            ["name": AnyCodable("soma_scene"), "description": AnyCodable("Return a compact Unity scene snapshot.")],
            ["name": AnyCodable("soma_execute"), "description": AnyCodable("Advanced escape hatch for restricted Nexus batch operations.")],
            ["name": AnyCodable("soma_debug"), "description": AnyCodable("Gather debug evidence from code, git, Nexus logs, and health.")],
            ["name": AnyCodable("soma_delta"), "description": AnyCodable("Return git changes plus Unity timeline and scene delta.")],
            ["name": AnyCodable("soma_apply"), "description": AnyCodable("Write Unity code files, wait for compilation, and return compiler errors.")],
            ["name": AnyCodable("soma_remember"), "description": AnyCodable("Save, list, or clear structured project memory.")],
            ["name": AnyCodable("soma_review"), "description": AnyCodable("Prepare a bug/regression review packet.")],
            ["name": AnyCodable("soma_code_context"), "description": AnyCodable("Deterministic code context.")]
        ]
        return ["tools": AnyCodable(tools)]
    }
}
