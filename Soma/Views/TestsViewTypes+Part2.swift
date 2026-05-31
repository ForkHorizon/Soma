import SwiftUI
import AppKit
import Foundation

struct TestModelCombinationSummary: Decodable, Identifiable {
    let comboID: String
    let translatorModel: String
    let analyzerModel: String
    let total: Int
    let ok: Int
    let degraded: Int
    let failed: Int
    let translationConfidence: TestConfidenceAggregate
    let improveConfidence: TestConfidenceAggregate
    let overallConfidence: TestConfidenceAggregate
    let lowConfidenceCount: Int
    let durationSeconds: Double
    let topWarnings: [String]
    let lowCases: [TestLowConfidenceCase]
    var id: String { comboID }
    enum CodingKeys: String, CodingKey {
        case comboID = "combo_id"
        case translatorModel = "translator_model"
        case analyzerModel = "analyzer_model"
        case total
        case ok
        case degraded
        case failed
        case translationConfidence = "translation_confidence"
        case improveConfidence = "improve_confidence"
        case overallConfidence = "overall_confidence"
        case lowConfidenceCount = "low_confidence_count"
        case durationSeconds = "duration_seconds"
        case topWarnings = "top_warnings"
        case lowCases = "low_cases"
    }
}

struct TestSummaryEnvelope: Decodable {
    let total: Int?
    let runStatus: String?
    let success: Bool?
    let confidenceFailedCount: Int?
    let externalErrorCounts: [String: Int]?
    let issueCounts: [String: Int]?
    let modelCombinations: [TestModelCombinationSummary]
    enum CodingKeys: String, CodingKey {
        case total
        case runStatus = "run_status"
        case success
        case confidenceFailedCount = "confidence_failed_count"
        case externalErrorCounts = "external_error_counts"
        case issueCounts = "issue_counts"
        case modelCombinations = "model_combinations"
    }
}

struct TestModelStatsEnvelope: Decodable {
    let generatedAt: String?
    let scannedRuns: Int
    let skippedRuns: Int
    let translationModels: [TestModelRoleStats]
    let improverModels: [TestModelRoleStats]
    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case scannedRuns = "scanned_runs"
        case skippedRuns = "skipped_runs"
        case translationModels = "translation_models"
        case improverModels = "improver_models"
    }
}

struct TestModelRoleStats: Decodable, Identifiable {
    let model: String
    let provider: String
    let attempts: Int
    let confidenceCount: Int
    let avgConfidence: Double?
    let medianConfidence: Double?
    let minConfidence: Double?
    let lowConfidenceCount: Int
    let confidenceFailedCount: Int
    let pipelineFailedCount: Int
    let degradedCount: Int
    let avgSeconds: Double?
    let lastTestedAt: String?
    let worstCases: [TestModelStatsCase]
    let topWarnings: [TestModelStatsWarning]
    let recentRuns: [TestModelStatsRecentRun]
    var id: String { "\(provider)|\(model)" }
    enum CodingKeys: String, CodingKey {
        case model
        case provider
        case attempts
        case confidenceCount = "confidence_count"
        case avgConfidence = "avg_confidence"
        case medianConfidence = "median_confidence"
        case minConfidence = "min_confidence"
        case lowConfidenceCount = "low_confidence_count"
        case confidenceFailedCount = "confidence_failed_count"
        case pipelineFailedCount = "pipeline_failed_count"
        case degradedCount = "degraded_count"
        case avgSeconds = "avg_seconds"
        case lastTestedAt = "last_tested_at"
        case worstCases = "worst_cases"
        case topWarnings = "top_warnings"
        case recentRuns = "recent_runs"
    }
}

struct TestModelStatsCase: Decodable, Identifiable {
    let runDir: String
    let caseID: String
    let category: String?
    let confidence: Double?
    let confidenceFailed: Bool?
    let status: String?
    let relatedModel: String?
    let warnings: [String]?
    var id: String { "\(runDir)|\(caseID)|\(relatedModel ?? "")" }
    enum CodingKeys: String, CodingKey {
        case runDir = "run_dir"
        case caseID = "case_id"
        case category
        case confidence
        case confidenceFailed = "confidence_failed"
        case status
        case relatedModel = "related_model"
        case warnings
    }
}

struct TestModelStatsWarning: Decodable, Identifiable {
    let warning: String
    let count: Int
    var id: String { warning }
}

struct TestModelStatsRecentRun: Decodable, Identifiable {
    let runDir: String
    let finishedAt: String?
    let attempts: Int
    let avgConfidence: Double?
    let lowConfidenceCount: Int
    let failedCount: Int
    var id: String { runDir }
    enum CodingKeys: String, CodingKey {
        case runDir = "run_dir"
        case finishedAt = "finished_at"
        case attempts
        case avgConfidence = "avg_confidence"
        case lowConfidenceCount = "low_confidence_count"
        case failedCount = "failed_count"
    }
}
