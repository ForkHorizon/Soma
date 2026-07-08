import Foundation
import SwiftUI
import AppKit
import Combine
extension SomaViewModel {
func selectProjectRoot(_ path: String) {
        guard let normalized = validatedDirectoryPath(path) else { return }
        selectedProjectRoot = normalized
        var roots = deduplicatedRoots(recentProjectRoots)
        if !roots.contains(normalized) {
            roots.append(normalized)
            if roots.count > 10 { roots.removeFirst(roots.count - 10) }
        }
        recentProjectRoots = roots
        recordProjectOpen(normalized)
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
            var roots = deduplicatedRoots(recentProjectRoots)
            if !roots.contains(selectedProjectRoot) {
                roots.append(selectedProjectRoot)
                if roots.count > 10 { roots.removeFirst(roots.count - 10) }
            }
            recentProjectRoots = roots
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
func removeRecentProjectRoot(_ root: String) {
        guard let normalized = validatedDirectoryPath(root) ?? (root.isEmpty ? nil : root) else { return }
        recentProjectRoots.removeAll { $0 == normalized }
        if selectedProjectRoot == normalized {
            clearProjectRoot()
        }
        persistProjectRoots()
    }
func recordProjectOpen(_ root: String) {
        var lastUsed = projectLastUsedMap()
        lastUsed[root] = ISO8601DateFormatter().string(from: Date())
        UserDefaults.standard.set(encodeStringMap(lastUsed), forKey: projectLastUsedKey)
        var counts = projectUsageCountMap()
        counts[root, default: 0] += 1
        UserDefaults.standard.set(encodeIntMap(counts), forKey: projectUsageCountsKey)
    }
func projectUsageCount(_ root: String) -> Int {
        projectUsageCountMap()[root] ?? 0
    }
func projectLastUsedLabel(_ root: String) -> String {
        guard let raw = projectLastUsedMap()[root], let date = ISO8601DateFormatter().date(from: raw) else {
            return "Never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
func projectContextSummary(for root: String) -> String {
        if projectFileExists("SOMA.md", in: root) { return "SOMA.md found" }
        if projectFileExists(".soma/project.json", in: root) { return "Project profile found" }
        if projectFileExists("AGENTS.md", in: root) || projectFileExists("GEMINI.md", in: root) { return "Agent context found" }
        return "Context missing"
    }
func projectAgentsSummary(for root: String) -> String {
        var agents: [String] = []
        if projectFileExists("AGENTS.md", in: root) { agents.append("Codex") }
        if projectFileExists("GEMINI.md", in: root) { agents.append("Gemini") }
        return agents.isEmpty ? "Not configured" : agents.joined(separator: "/") + " configured"
    }
func projectGraphSummary(for root: String) -> String {
        if projectFileExists("graphify-out/graph.json", in: root) || projectFileExists("graphify-out/GRAPH_REPORT.md", in: root) {
            return root == selectedProjectRoot ? (graphStale ? "Stale" : "Fresh") : "Found"
        }
        return "None"
    }
func projectHealthWarningCount(for root: String) -> Int {
        var count = 0
        if !projectFileExists("SOMA.md", in: root) && !projectFileExists(".soma/project.json", in: root) { count += 1 }
        if root == selectedProjectRoot && graphAvailable && graphStale { count += 1 }
        return count
    }
func approximateProjectFileCountLabel(for root: String) -> String {
        guard !root.isEmpty else { return "None" }
        let maxFiles = 20_000
        let skippedDirectories = Set([".git", ".build", ".swiftpm", "DerivedData", "node_modules", "Library", "graphify-out"])
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "Unknown"
        }
        var count = 0
        for case let url as URL in enumerator {
            if skippedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else { continue }
            if values.isDirectory == true { continue }
            if values.isRegularFile == true {
                count += 1
                if count >= maxFiles { return "\(maxFiles.formatted())+" }
            }
        }
        return count.formatted()
    }
func projectSetupRecommendations(for root: String) -> [String] {
        var items: [String] = []
        if !projectFileExists("SOMA.md", in: root) {
            items.append("Add SOMA.md so project purpose, important paths, and run commands are explicit.")
        }
        if !projectFileExists(".soma/project.json", in: root) {
            items.append("Create .soma/project.json later when the project profile format is finalized.")
        }
        if !projectFileExists("AGENTS.md", in: root) && !projectFileExists("GEMINI.md", in: root) {
            items.append("Detect or add agent instruction files if this project needs client-specific guidance.")
        }
        return items
    }
func projectFileExists(_ relativePath: String, in root: String) -> Bool {
        guard !root.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(relativePath))
    }
func projectLastUsedMap() -> [String: String] {
        decodeStringMap(UserDefaults.standard.string(forKey: projectLastUsedKey) ?? "{}")
    }
func projectUsageCountMap() -> [String: Int] {
        decodeIntMap(UserDefaults.standard.string(forKey: projectUsageCountsKey) ?? "{}")
    }
func decodeStringMap(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8), let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }
func decodeIntMap(_ json: String) -> [String: Int] {
        guard let data = json.data(using: .utf8), let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return decoded
    }
func encodeStringMap(_ map: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(map), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
func encodeIntMap(_ map: [String: Int]) -> String {
        guard let data = try? JSONEncoder().encode(map), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
