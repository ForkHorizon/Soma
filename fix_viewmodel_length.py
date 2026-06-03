import re

with open('./Soma/ViewModels/SomaViewModel+Execution+Part3.swift', 'r') as f:
    content = f.read()

search = """static func executeProcess(path: String, args: [String], workingDirectory: String? = nil, environment: [String: String], timeout: TimeInterval = 300) async throws -> Data {
        return try await withThrowingTaskGroup(of: Data.self) { group in
            let process = Process()

            group.addTask {
                return try await withTaskCancellationHandler {
                    return try await withCheckedThrowingContinuation { continuation in
                        process.executableURL = URL(fileURLWithPath: path)
                        process.arguments = args
                        process.environment = environment
                        if let wd = workingDirectory {
                            process.currentDirectoryURL = URL(fileURLWithPath: wd)
                        }
                        let stdout = Pipe()
                        let stderr = Pipe()
                        process.standardOutput = stdout
                        process.standardError = stderr
                        do {
                            try process.run()
                            DispatchQueue.global(qos: .userInitiated).async {
                                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                                process.waitUntilExit()
                                if process.terminationStatus == 0 {
                                    continuation.resume(returning: outputData)
                                } else {
                                    continuation.resume(throwing: SomaError(String(data: errorData, encoding: .utf8) ?? "Unknown error"))
                                }
                            }
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                } onCancel: {
                    if process.isRunning {
                        process.terminate()
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SomaError("Process execution timed out after \\(timeout) seconds.")
            }

            do {
                guard let result = try await group.next() else {
                    throw SomaError("Failed to get process result")
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }"""

replace = """static func executeProcess(path: String, args: [String], workingDirectory: String? = nil, environment: [String: String], timeout: TimeInterval = 300) async throws -> Data {
        return try await withThrowingTaskGroup(of: Data.self) { group in
            let process = Process()
            group.addTask { return try await Self.runProcessTask(process, path: path, args: args, workingDirectory: workingDirectory, environment: environment) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SomaError("Process execution timed out after \\(timeout) seconds.")
            }
            do {
                guard let result = try await group.next() else { throw SomaError("Failed to get process result") }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static func runProcessTask(_ process: Process, path: String, args: [String], workingDirectory: String?, environment: [String: String]) async throws -> Data {
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                process.environment = environment
                if let wd = workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: wd) }
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        if process.terminationStatus == 0 { continuation.resume(returning: outputData) }
                        else { continuation.resume(throwing: SomaError(String(data: errorData, encoding: .utf8) ?? "Unknown error")) }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }"""

content = content.replace(search, replace)
with open('./Soma/ViewModels/SomaViewModel+Execution+Part3.swift', 'w') as f:
    f.write(content)
