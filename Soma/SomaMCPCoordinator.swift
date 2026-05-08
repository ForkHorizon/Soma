import Foundation

enum MCPError: Error {
    case invalidRequest
    case toolExecutionFailed(String)
}

struct MCPRequest: Codable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: [String: AnyCodable]?
}

struct MCPResponse: Codable {
    let jsonrpc: String
    let id: Int
    let result: [String: AnyCodable]?
    let error: MCPErrorResponse?
}

struct MCPErrorResponse: Codable {
    let code: Int
    let message: String
}

class SomaMCPCoordinator {
    private let pythonExecutable: String = "/opt/homebrew/bin/python3"
    private let scoutPipelinePath: String

    init() {
        // In a real setup, this path would be more robust. Using a relative path for now.
        scoutPipelinePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("scout_pipeline.py").path
    }

    func startStdioServer() {
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
                        self?.handleRequest(request, outputHandle: outputHandle)
                    }
                }
            }
        }

        RunLoop.main.run()
    }

    private func handleRequest(_ request: MCPRequest, outputHandle: FileHandle) {
        Task {
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
    }

    private func executeTool(method: String, params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
        // Implement tool execution logic here, delegating to scout_pipeline.py or direct swift implementations
        switch method {
        case "soma_prepare_context":
            return try await executePythonTool(tool: "soma_prepare_context", params: params)
        case "soma_get_map":
            return try await executePythonTool(tool: "soma_get_map", params: params)
        case "soma_ask":
            return try await executePythonTool(tool: "soma_ask", params: params)
        case "soma_inspect":
            return try await executePythonTool(tool: "soma_inspect", params: params)
        case "soma_scene":
            return try await executePythonTool(tool: "soma_scene", params: params)
        case "soma_execute":
            return try await executePythonTool(tool: "soma_execute", params: params)
        case "soma_debug":
            return try await executePythonTool(tool: "soma_debug", params: params)
        case "soma_delta":
            return try await executePythonTool(tool: "soma_delta", params: params)
        case "soma_apply":
            return try await executePythonTool(tool: "soma_apply", params: params)
        case "soma_remember":
            return try await executePythonTool(tool: "soma_remember", params: params)
        case "soma_review":
            return try await executePythonTool(tool: "soma_review", params: params)
        case "tools/list":
            return listTools()
        default:
            throw MCPError.invalidRequest
        }
    }

    private func executePythonTool(tool: String, params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
        // Use Process() to call soma_mcp_server.py with the tool name and arguments.
        // Since soma_mcp_server.py has been modified to act as a CLI runner, we pass the tool via args.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath())

        let somaMcpServerPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("soma_mcp_server.py").path

        var args: [String] = [somaMcpServerPath, "--run-tool", tool]

        // Pass params as JSON string if any
        if let params = params,
           let paramData = try? JSONEncoder().encode(params),
           let paramStr = String(data: paramData, encoding: .utf8) {
             args.append(paramStr)
        }

        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus == 0 {
             if let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] {
                  // convert Any to AnyCodable for the dictionary
                  var resultDict: [String: AnyCodable] = [:]
                  for (key, value) in json {
                      resultDict[key] = AnyCodable(value)
                  }
                  return resultDict
             } else if let outputStr = String(data: outputData, encoding: .utf8) {
                  // If it's just a raw string result
                  return ["result": AnyCodable(outputStr)]
             }
             return [:]
        } else {
             let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown python error"
             throw MCPError.toolExecutionFailed(errorStr)
        }
    }

    private func pythonPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3") {
            return "/opt/homebrew/bin/python3"
        }
        return "/usr/bin/python3"
    }

    private func listTools() -> [String: AnyCodable] {
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
            ["name": AnyCodable("soma_review"), "description": AnyCodable("Prepare a bug/regression review packet.")]
        ]
        return ["tools": AnyCodable(tools)]
    }
}
