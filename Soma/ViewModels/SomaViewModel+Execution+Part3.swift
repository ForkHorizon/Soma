import Foundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

extension SomaViewModel {
nonisolated func pythonPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3") {
            return "/opt/homebrew/bin/python3"
        }
        return "/usr/bin/python3"
    }


func scriptEnvironment(projectRoot: String? = nil, includeProjectRoot: Bool = true) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = (environment["PATH"] ?? "") + ":/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:\(homeDir)/.local/bin"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        LocalModelSettingsStore.apply(to: &environment)
        if !includeProjectRoot {
            environment.removeValue(forKey: "SOMA_PROJECT_ROOT")
        } else if let projectRoot, !projectRoot.isEmpty {
            environment["SOMA_PROJECT_ROOT"] = projectRoot
        } else if !selectedProjectRoot.isEmpty {
            environment["SOMA_PROJECT_ROOT"] = selectedProjectRoot
        }
        return environment
    }


func runScript(path: String, args: [String], workingDirectory: String? = nil) async throws -> Data {
        let env = scriptEnvironment()
        return try await Self.executeProcess(path: path, args: args, workingDirectory: workingDirectory, environment: env)
    }


static func executeProcess(path: String, args: [String], workingDirectory: String? = nil, environment: [String: String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.environment = environment
            if let wd = workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: wd)
            }
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
    }

}
