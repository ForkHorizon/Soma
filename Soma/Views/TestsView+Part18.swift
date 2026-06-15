import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func loadResultRuns(from outDir: URL) {
        let resultsURL = outDir.appendingPathComponent("results.jsonl")
        do {
            resultPromptByCaseID = loadPromptManifest(from: outDir)
            resultConfidenceJudgesByItemID = loadConfidenceJudgesMap(from: outDir)
            let text = try String(contentsOf: resultsURL, encoding: .utf8)
            let decoder = JSONDecoder()
            resultRunRows = text
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> TestRunResult? in
                    guard let data = String(line).data(using: .utf8) else { return nil }
                    return try? decoder.decode(TestRunResult.self, from: data)
                }
                .sorted {
                    if $0.caseID == $1.caseID {
                        let lhs = effectiveConfidence($0.overallConfidence)
                        let rhs = effectiveConfidence($1.overallConfidence)
                        if lhs == rhs { return $0.comboID < $1.comboID }
                        return lhs > rhs
                    }
                    return $0.caseID < $1.caseID
            }
            selectedRunRowID = resultRunRows.first?.id
            expandedRunDebugIDs = selectedRunRowID.map { Set([$0]) } ?? []
        } catch {
            resultRunRows = []
            resultPromptByCaseID = [:]
            resultConfidenceJudgesByItemID = [:]
            expandedRunDebugIDs = []
        }
    }


    func loadPromptManifest(from outDir: URL) -> [String: String] {
        let manifestURL = outDir.appendingPathComponent("prompts.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([TestPromptManifestCase].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0.prompt) })
    }


    func loadConfidenceJudgesMap(from outDir: URL) -> [String: [TestConfidenceJudgeResult]] {
        let stateURL = outDir.appendingPathComponent("confidence_state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode(TestConfidenceStateEnvelope.self, from: data) else {
            return [:]
        }

        var grouped: [String: [TestConfidenceJudgeResult]] = [:]
        for (rawKey, payload) in decoded.localJudges {
            guard let parsed = parseConfidenceStateKey(rawKey) else { continue }
            let result = TestConfidenceJudgeResult(
                itemID: parsed.itemID,
                judgeModel: parsed.model,
                payload: payload
            )
            grouped[parsed.itemID, default: []].append(result)
        }

        for key in grouped.keys {
            grouped[key]?.sort {
                let lhs = $0.judgeModel.localizedStandardCompare($1.judgeModel)
                if lhs == .orderedSame {
                    return ($0.payload.stage ?? "") < ($1.payload.stage ?? "")
                }
                return lhs == .orderedAscending
            }
        }
        return grouped
    }


    func parseConfidenceStateKey(_ key: String) -> (itemID: String, model: String)? {
        guard let data = key.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [Any],
              array.count == 2 else {
            return nil
        }
        let itemID = String(describing: array[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let model = String(describing: array[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty, !model.isEmpty else { return nil }
        return (itemID, model)
    }


    func saveLastRunOutput(_ outDir: URL) {
        UserDefaults.standard.set(outDir.path, forKey: lastRunOutputKey)
    }


    func loadLastResultsIfAvailable() {
        guard !isRunningTests else { return }
        if let storedPath = UserDefaults.standard.string(forKey: lastRunOutputKey) {
            let storedURL = URL(fileURLWithPath: storedPath)
            if FileManager.default.fileExists(atPath: storedURL.appendingPathComponent("summary.json").path) {
                loadResultsSummary(from: storedURL)
                return
            }
            if hasNonEmptyResults(at: storedURL), loadPartialResults(from: storedURL) {
                return
            }
        }

        if let latest = latestResultsOutputDirectory() {
            loadResultsSummary(from: latest)
        }
    }


    func hasNonEmptyResults(at directory: URL) -> Bool {
        let resultsURL = directory.appendingPathComponent("results.jsonl")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resultsURL.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }


    func latestResultsOutputDirectory() -> URL? {
        let stressURL = repoRootURL.appendingPathComponent(".stress")
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: stressURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else {
            return nil
        }

        return directories
            .filter { directory in
                guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true else { return false }
                return FileManager.default.fileExists(atPath: directory.appendingPathComponent("summary.json").path)
                    || hasNonEmptyResults(at: directory)
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }


    func codexExecutablePath() -> String {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        if let existing = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return existing
        }
        return "codex"
    }


    func geminiExecutablePath() -> String {
        let candidates = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini"
        ]
        if let existing = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return existing
        }
        return "gemini"
    }


    func codexSearchPath(existing: String?) -> String {
        let required = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        let existingParts = (existing ?? "").split(separator: ":").map(String.init)
        let merged = required + existingParts.filter { !required.contains($0) }
        return merged.joined(separator: ":")
    }


    func runTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }


    func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
    }


    func selectedModelsSummary(_ selection: Set<String>) -> String {
        let models = Array(selection).sorted()
        if models.isEmpty { return "No models selected" }
        return models.joined(separator: ", ")
    }


    func mergePresets(_ presets: [RusToPromptModelPreset]) -> [RusToPromptModelPreset] {
        var seen = Set<String>()
        var merged: [RusToPromptModelPreset] = []
        for preset in presets {
            let key = preset.model.lowercased()
            guard !seen.contains(key) else { continue }
            merged.append(preset)
            seen.insert(key)
        }
        return merged
    }


    func addCustomModel(
        _ customModel: Binding<String>,
        selection: Binding<Set<String>>,
        storageKey: String
    ) {
        let model = customModel.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        selection.wrappedValue.insert(model)
        saveModelSelection(selection.wrappedValue, key: storageKey)
        customModel.wrappedValue = ""
    }


    func isCodexModelName(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("gpt-oss") { return false }
        return normalized.hasPrefix("gpt-")
            || normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4")
            || normalized.hasPrefix("codex-")
    }


    func isGeminiModelName(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("gemini-")
            || normalized.hasPrefix("auto-gemini")
            || normalized.hasPrefix("gemma-4-")
    }


    func isDeepSeekModelName(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("deepseek-")
    }


    func providerForOnlineModelName(_ model: String) -> String? {
        if isDeepSeekModelName(model) { return "deepseek" }
        if isGeminiModelName(model) { return "gemini" }
        if isCodexModelName(model) { return "codex" }
        return nil
    }


    func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "deepseek":
            return "DeepSeek"
        case "gemini":
            return "Gemini"
        case "codex":
            return "Codex"
        case "local":
            return "Local"
        default:
            return provider.capitalized
        }
    }

}
