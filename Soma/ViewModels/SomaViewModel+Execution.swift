import Foundation

import SwiftUI

import AppKit

import Combine


extension SomaViewModel {

func runRelayScript(bundle: GatherBundle) async throws -> RelayResponse {
        let script = try scriptURL(named: "relay")
        let bundleJSON = (try? String(data: JSONEncoder().encode(bundle), encoding: .utf8)) ?? "{}"
        let output = try await runScript(path: pythonPath(), args: [script.path, bundleJSON])
        return try JSONDecoder().decode(RelayResponse.self, from: output)
    }

func runSomaHelper(args: [String]) async throws -> Data {
        let script = try scriptURL(named: "soma_mcp_server")
        return try await runScript(path: pythonPath(), args: [script.path] + args)
    }

func scriptURL(named name: String) throws -> URL {
        // Prefer source directory — gateway/ package must be co-located with soma_mcp_server.py.
        // #filePath resolves to: …/Soma/Soma/ViewModels/SomaViewModel+Execution.swift
        // Two .deletingLastPathComponent() calls reach: …/Soma/Soma/
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // drop SomaViewModel+Execution.swift → ViewModels/
            .deletingLastPathComponent()   // drop ViewModels/ → Soma/ (contains gateway/)
            .appendingPathComponent("\(name).py")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        // Fallback: bundled resource (only valid when gateway/ is also bundled)
        if let bundled = Bundle.main.url(forResource: name, withExtension: "py") {
            return bundled
        }
        throw SomaError("\(name).py not found in source or bundle")
    }

func pythonPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3") {
            return "/opt/homebrew/bin/python3"
        }
        return "/usr/bin/python3"
    }

func scriptEnvironment(projectRoot: String? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = (environment["PATH"] ?? "") + ":/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:\(homeDir)/.local/bin"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["SOMA_LOCAL_MODEL"] = environment["SOMA_LOCAL_MODEL"] ?? "gemma4:e4b"
        environment["SOMA_RANKER_MODEL"] = environment["SOMA_RANKER_MODEL"] ?? "gemma4:e4b"
        environment["SOMA_ANALYST_MODEL"] = environment["SOMA_ANALYST_MODEL"] ?? "qwen3-coder:30b-a3b-q4_K_M"
        if let projectRoot, !projectRoot.isEmpty {
            environment["SOMA_PROJECT_ROOT"] = projectRoot
        } else if !selectedProjectRoot.isEmpty {
            environment["SOMA_PROJECT_ROOT"] = selectedProjectRoot
        }
        return environment
    }

func runScript(path: String, args: [String], workingDirectory: String? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.environment = scriptEnvironment()
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
