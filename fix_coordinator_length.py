import re

with open('./Soma/SomaMCPCoordinator.swift', 'r') as f:
    content = f.read()

search = """    private func executePythonTool(tool: String, params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
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
        requestStr += "\\n"

        return try await withThrowingTaskGroup(of: [String: AnyCodable].self) { group in
            group.addTask {
                return try await withTaskCancellationHandler {
                    return try await withCheckedThrowingContinuation { continuation in
                        Task {
                            await self.storeContinuation(id: requestId, continuation: continuation)
                            do {
                                try stdin.fileHandleForWriting.write(contentsOf: requestStr.data(using: .utf8)!)
                            } catch {
                                await self.removeContinuation(id: requestId)
                                continuation.resume(throwing: MCPError.toolExecutionFailed("Failed to write to python backend"))
                            }
                        }
                    }
                } onCancel: {
                    Task {
                        await self.cancelContinuation(id: requestId)
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 300_000_000_000) // 300 seconds
                throw MCPError.toolExecutionFailed("Request timed out after 300 seconds.")
            }

            do {
                guard let result = try await group.next() else {
                    throw MCPError.toolExecutionFailed("Failed to get result from python backend")
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }"""

replace = """    private func executePythonTool(tool: String, params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
        try await startPythonBackendIfNeeded()
        guard let stdin = pythonStdin else { throw MCPError.toolExecutionFailed("Python backend not running") }
        let requestId = requestCounter
        requestCounter += 1

        let request = MCPRequest(jsonrpc: "2.0", id: requestId, method: tool, params: params)
        guard let requestData = try? JSONEncoder().encode(request),
              var requestStr = String(data: requestData, encoding: .utf8) else {
            throw MCPError.toolExecutionFailed("Failed to encode request")
        }
        requestStr += "\\n"

        return try await executeWithTimeout(requestId: requestId, requestStr: requestStr, stdin: stdin)
    }

    private func executeWithTimeout(requestId: Int, requestStr: String, stdin: Pipe) async throws -> [String: AnyCodable] {
        return try await withThrowingTaskGroup(of: [String: AnyCodable].self) { group in
            group.addTask { return try await self.dispatchRequestTask(requestId: requestId, requestStr: requestStr, stdin: stdin) }
            group.addTask {
                try await Task.sleep(nanoseconds: 300_000_000_000)
                throw MCPError.toolExecutionFailed("Request timed out after 300 seconds.")
            }
            do {
                guard let result = try await group.next() else { throw MCPError.toolExecutionFailed("Failed to get result") }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func dispatchRequestTask(requestId: Int, requestStr: String, stdin: Pipe) async throws -> [String: AnyCodable] {
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                Task {
                    await self.storeContinuation(id: requestId, continuation: continuation)
                    do {
                        try stdin.fileHandleForWriting.write(contentsOf: requestStr.data(using: .utf8)!)
                    } catch {
                        await self.removeContinuation(id: requestId)
                        continuation.resume(throwing: MCPError.toolExecutionFailed("Failed to write to python backend"))
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelContinuation(id: requestId) }
        }
    }"""

content = content.replace(search, replace)
with open('./Soma/SomaMCPCoordinator.swift', 'w') as f:
    f.write(content)
