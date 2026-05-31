import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func adHocPreset(for model: String) -> RusToPromptModelPreset {
        if isGeminiModelName(model) {
            return RusToPromptModelPreset(
                model: model,
                quality: "Unknown",
                speed: "Unknown",
                ram: "0 GB",
                detail: "Custom Gemini CLI model. It will run through the Gemini provider if the CLI account can access it.",
                recommended: false,
                provider: "gemini"
            )
        }
        if isCodexModelName(model) {
            return RusToPromptModelPreset(
                model: model,
                quality: "Unknown",
                speed: "Unknown",
                ram: "0 GB",
                detail: "Custom Codex CLI model. It will run through Codex with the configured stage reasoning effort.",
                recommended: false,
                isCodex: true
            )
        }
        return RusToPromptModelPreset(
            model: model,
            quality: "Unknown",
            speed: "Unknown",
            ram: "Custom",
            detail: "Custom local Ollama model. Install it in Ollama before running tests.",
            recommended: false
        )
    }


    func statsRows(for role: TestModelRole) -> [TestModelRoleStats] {
        guard let modelStats else { return [] }
        switch role {
        case .translator:
            return modelStats.translationModels
        case .improver:
            return modelStats.improverModels
        }
    }


    func speedLabels(for rows: [TestModelRoleStats]) -> [String: String] {
        let timedRows = rows
            .filter { ($0.avgSeconds ?? 0) > 0 }
            .sorted {
                let lhs = $0.avgSeconds ?? .greatestFiniteMagnitude
                let rhs = $1.avgSeconds ?? .greatestFiniteMagnitude
                if lhs != rhs { return lhs < rhs }
                return $0.model.localizedStandardCompare($1.model) == .orderedAscending
            }
        let count = timedRows.count
        guard count > 0 else { return [:] }

        var labels: [String: String] = [:]
        for (index, row) in timedRows.enumerated() {
            let percentile = Double(index + 1) / Double(count)
            let label: String
            if percentile <= 0.25 {
                label = "Fastest"
            } else if percentile <= 0.50 {
                label = "Fast"
            } else if percentile <= 0.75 {
                label = "Balanced"
            } else {
                label = "Slow"
            }
            labels[row.model.lowercased()] = label
        }
        return labels
    }


    func qualityLabel(for stats: TestModelRoleStats?) -> String {
        guard let stats else { return "No data" }
        let attempts = max(stats.attempts, 0)
        let pipelineFailRate = attempts > 0 ? Double(stats.pipelineFailedCount) / Double(attempts) : 0
        let confidenceFailRate = attempts > 0 ? Double(stats.confidenceFailedCount) / Double(attempts) : 0

        if attempts > 0 && (pipelineFailRate >= 0.50 || (stats.confidenceCount == 0 && (stats.pipelineFailedCount > 0 || stats.confidenceFailedCount > 0))) {
            return "Broken"
        }
        guard let confidence = stats.avgConfidence else { return "No data" }
        if confidence < 0.80 || pipelineFailRate > 0.15 {
            return "Risk"
        }
        if confidence >= 0.89 && pipelineFailRate <= 0.025 && confidenceFailRate <= 0.05 {
            return "Best"
        }
        if confidence >= 0.86 && pipelineFailRate <= 0.075 {
            return "High"
        }
        return "Good"
    }


    func benchmarkDetail(for preset: RusToPromptModelPreset, stats: TestModelRoleStats?, quality: String, speed: String) -> String {
        guard let stats else {
            return [
                preset.detail,
                "No benchmark data yet.",
                "Run translation/staged tests to rank this model."
            ]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        }

        let attempts = max(stats.attempts, 0)
        let pipelineFailRate = attempts > 0 ? Double(stats.pipelineFailedCount) / Double(attempts) : 0
        let confidenceFailRate = attempts > 0 ? Double(stats.confidenceFailedCount) / Double(attempts) : 0
        return [
            preset.detail,
            "Benchmark quality: \(quality); speed: \(speed).",
            "Attempts \(stats.attempts), confidence scores \(stats.confidenceCount), avg \(formatConfidence(stats.avgConfidence)), median \(formatConfidence(stats.medianConfidence)), min \(formatConfidence(stats.minConfidence)).",
            "Low \(stats.lowConfidenceCount), confidence failed \(stats.confidenceFailedCount) (\(formatPercent(confidenceFailRate)), pipeline failed \(stats.pipelineFailedCount) (\(formatPercent(pipelineFailRate)), degraded \(stats.degradedCount).",
            "Average runtime \(formatOptionalSeconds(stats.avgSeconds)); last tested \(shortDateTime(stats.lastTestedAt))."
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n")
    }


    func rankedModelPresets(
        role: TestModelRole,
        knownPresets: [RusToPromptModelPreset],
        sort: TestModelSort,
        extraModels: Set<String> = []
    ) -> [TestRankedModelPreset] {
        let presets = installedModelPresets(knownPresets: knownPresets, extraModels: extraModels)
        let statsRows = statsRows(for: role)
        let statsByModel = modelStatsLookup(statsRows)
        let speedByModel = speedLabels(for: statsRows)
        let ranked = rankedRows(from: presets, statsByModel: statsByModel, speedByModel: speedByModel)
        return ranked.sorted { compareRankedModel($0, $1, sort: sort) }
    }


    func modelStatsLookup(_ rows: [TestModelRoleStats]) -> [String: TestModelRoleStats] {
        var lookup: [String: TestModelRoleStats] = [:]
        for row in rows {
            lookup[row.model.lowercased()] = row
        }
        return lookup
    }


    func rankedRows(
        from presets: [RusToPromptModelPreset],
        statsByModel: [String: TestModelRoleStats],
        speedByModel: [String: String]
    ) -> [TestRankedModelPreset] {
        presets.map { preset in
            let stats = statsByModel[preset.model.lowercased()]
            let quality = qualityLabel(for: stats)
            let speed = stats == nil ? "No data" : (speedByModel[preset.model.lowercased()] ?? "No data")
            return TestRankedModelPreset(
                preset: preset,
                stats: stats,
                quality: quality,
                speed: speed,
                detail: benchmarkDetail(for: preset, stats: stats, quality: quality, speed: speed)
            )
        }
    }


    func compareRankedModel(_ lhs: TestRankedModelPreset, _ rhs: TestRankedModelPreset, sort: TestModelSort) -> Bool {
        switch sort {
        case .smart:
            return compareSmartRankedModel(lhs, rhs)
        case .quality:
            return compareQualityRankedModel(lhs, rhs)
        case .speed:
            return compareSpeedRankedModel(lhs, rhs)
        case .name:
            return compareRankedModelName(lhs, rhs)
        }
    }


    func compareSmartRankedModel(_ lhs: TestRankedModelPreset, _ rhs: TestRankedModelPreset) -> Bool {
        if lhs.hasStats != rhs.hasStats { return lhs.hasStats }
        if lhs.isBroken != rhs.isBroken { return !lhs.isBroken }
        if lhs.qualityRank != rhs.qualityRank { return lhs.qualityRank > rhs.qualityRank }
        let lhsConfidence = lhs.avgConfidence ?? -1
        let rhsConfidence = rhs.avgConfidence ?? -1
        if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
        let lhsFailures = lhs.pipelineFailedCount + lhs.confidenceFailedCount + lhs.lowConfidenceCount
        let rhsFailures = rhs.pipelineFailedCount + rhs.confidenceFailedCount + rhs.lowConfidenceCount
        if lhsFailures != rhsFailures { return lhsFailures < rhsFailures }
        let lhsSeconds = lhs.avgSeconds ?? .greatestFiniteMagnitude
        let rhsSeconds = rhs.avgSeconds ?? .greatestFiniteMagnitude
        if lhsSeconds != rhsSeconds { return lhsSeconds < rhsSeconds }
        if lhs.attempts != rhs.attempts { return lhs.attempts > rhs.attempts }
        return compareRankedModelName(lhs, rhs)
    }


    func compareQualityRankedModel(_ lhs: TestRankedModelPreset, _ rhs: TestRankedModelPreset) -> Bool {
        if lhs.qualityRank != rhs.qualityRank { return lhs.qualityRank > rhs.qualityRank }
        let lhsConfidence = lhs.avgConfidence ?? -1
        let rhsConfidence = rhs.avgConfidence ?? -1
        if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
        return compareRankedModelName(lhs, rhs)
    }


    func compareSpeedRankedModel(_ lhs: TestRankedModelPreset, _ rhs: TestRankedModelPreset) -> Bool {
        let lhsSeconds = lhs.avgSeconds ?? .greatestFiniteMagnitude
        let rhsSeconds = rhs.avgSeconds ?? .greatestFiniteMagnitude
        if lhsSeconds != rhsSeconds { return lhsSeconds < rhsSeconds }
        if lhs.qualityRank != rhs.qualityRank { return lhs.qualityRank > rhs.qualityRank }
        return compareRankedModelName(lhs, rhs)
    }


    func compareRankedModelName(_ lhs: TestRankedModelPreset, _ rhs: TestRankedModelPreset) -> Bool {
        lhs.preset.model.localizedStandardCompare(rhs.preset.model) == .orderedAscending
    }

}
