import Foundation

import SwiftUI

import AppKit

import Combine


extension SomaViewModel {

func selectProjectRoot(_ path: String) {
        guard let normalized = validatedDirectoryPath(path) else { return }
        selectedProjectRoot = normalized
        recentProjectRoots = deduplicatedRoots([normalized] + recentProjectRoots).prefix(6).map(\.self)
        persistProjectRoots()
        refreshSomaStatus()
    }

func clearProjectRoot() {
        selectedProjectRoot = ""
        UserDefaults.standard.set("", forKey: lastProjectRootKey)
        nexusConnected = false
        graphAvailable = false
        graphStale = false
    }

func hydrateProjectRootsIfNeeded() {
        guard !hasHydratedProjectRoots else { return }
        hasHydratedProjectRoots = true

        recentProjectRoots = decodeRecentRoots()
        
        let storedLastProjectRoot = UserDefaults.standard.string(forKey: lastProjectRootKey) ?? ""
        let envRoot = ProcessInfo.processInfo.environment["SOMA_PROJECT_ROOT"]
        let cwd = FileManager.default.currentDirectoryPath
        
        var targetRoot = ""
        if !storedLastProjectRoot.isEmpty { targetRoot = storedLastProjectRoot }
        else if let env = envRoot, !env.isEmpty { targetRoot = env }
        else if cwd != "/" && cwd != "/Users/\(NSUserName())" { targetRoot = cwd }
        
        if selectedProjectRoot.isEmpty, let restored = validatedDirectoryPath(targetRoot) {
            selectedProjectRoot = restored
        }
        if !selectedProjectRoot.isEmpty {
            recentProjectRoots = deduplicatedRoots([selectedProjectRoot] + recentProjectRoots).prefix(6).map(\.self)
            refreshSomaStatus()
        }
        persistProjectRoots()
    }

func persistProjectRoots() {
        UserDefaults.standard.set(selectedProjectRoot, forKey: lastProjectRootKey)
        UserDefaults.standard.set(encodeRecentRoots(recentProjectRoots), forKey: recentProjectRootsKey)
    }

func decodeRecentRoots() -> [String] {
        let storedRecentRootsJSON = UserDefaults.standard.string(forKey: recentProjectRootsKey) ?? "[]"
        guard
            let data = storedRecentRootsJSON.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return deduplicatedRoots(decoded.compactMap(validatedDirectoryPath))
    }

func encodeRecentRoots(_ roots: [String]) -> String {
        guard let data = try? JSONEncoder().encode(roots), let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

func validatedDirectoryPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        let normalized = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return normalized
    }

func deduplicatedRoots(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        return roots.filter { root in
            guard !seen.contains(root) else { return false }
            seen.insert(root)
            return true
        }
    }

}
