import SwiftUI
import AppKit
import Foundation

enum TestOutputTab: String, CaseIterable, Identifiable {
    case progress = "Progress"
    case results = "Results"
    var id: String { rawValue }
}

enum TestResultsMode: String, CaseIterable, Identifiable {
    case byModel = "By Model"
    case byCase = "By Case"
    var id: String { rawValue }
}

enum TestBenchmarkMode: String, CaseIterable, Identifiable {
    case staged = "Staged"
    case translation = "Translation"
    case matrix = "Full Matrix"
    var id: String { rawValue }
    var cliValue: String {
        switch self {
        case .staged: return "staged"
        case .translation: return "translation"
        case .matrix: return "matrix"
        }
    }
    var shortDescription: String {
        switch self {
        case .staged:
            return "Rank translators per case, then send the best translation to each improver."
        case .translation:
            return "Only test Russian or mixed input -> English translation quality."
        case .matrix:
            return "Run every translator -> improver pair for end-to-end checks."
        }
    }
}

enum TestModelRole {
    case translator
    case improver
}

enum TestModelSort: String, CaseIterable, Identifiable {
    case smart = "Smart"
    case quality = "Quality"
    case speed = "Speed"
    case name = "Name"
    var id: String { rawValue }
}

enum TestPipelineStep: Int, CaseIterable, Identifiable {
    case translate
    case translationCheck
    case improve
    case improveConfidence
    case overallConfidence
    case save
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .translate: return "Translate"
        case .translationCheck: return "Translation Check"
        case .improve: return "Improve"
        case .improveConfidence: return "Improve Confidence"
        case .overallConfidence: return "Overall Confidence"
        case .save: return "Save"
        }
    }
    var icon: String {
        switch self {
        case .translate: return "character.book.closed"
        case .translationCheck: return "checkmark.shield"
        case .improve: return "wand.and.sparkles"
        case .improveConfidence: return "gauge.with.dots.needle.50percent"
        case .overallConfidence: return "scope"
        case .save: return "tray.and.arrow.down"
        }
    }
}

struct TestRankedModelPreset: Identifiable {
    let preset: RusToPromptModelPreset
    let stats: TestModelRoleStats?
    let quality: String
    let speed: String
    let detail: String
    var id: String { preset.id }
    var hasStats: Bool { stats != nil }
    var attempts: Int { stats?.attempts ?? 0 }
    var avgConfidence: Double? { stats?.avgConfidence }
    var avgSeconds: Double? { stats?.avgSeconds }
    var pipelineFailedCount: Int { stats?.pipelineFailedCount ?? 0 }
    var confidenceFailedCount: Int { stats?.confidenceFailedCount ?? 0 }
    var lowConfidenceCount: Int { stats?.lowConfidenceCount ?? 0 }
    var confidenceCount: Int { stats?.confidenceCount ?? 0 }
    var isBroken: Bool { quality == "Broken" }
    var pipelineFailRate: Double {
        attempts > 0 ? Double(pipelineFailedCount) / Double(attempts) : 0
    }
    var confidenceFailRate: Double {
        attempts > 0 ? Double(confidenceFailedCount) / Double(attempts) : 0
    }
    var qualityRank: Int {
        switch quality {
        case "Best": return 5
        case "High": return 4
        case "Good": return 3
        case "Risk": return 2
        case "No data": return 1
        case "Broken": return 0
        default: return 1
        }
    }
}

struct TestProgressEvent: Decodable {
    let event: String
    let stage: String
    let timestamp: String?
    let caseID: String?
    let category: String?
    let translatorModel: String?
    let analyzerModel: String?
    let operationIndex: Int?
    let totalOperations: Int?
    let batchSize: Int?
    let batchIndex: Int?
    let batchTotal: Int?
    let status: String?
    let reason: String?
    let confidence: Double?
    enum CodingKeys: String, CodingKey {
        case event
        case stage
        case timestamp
        case caseID = "case_id"
        case category
        case translatorModel = "translator_model"
        case analyzerModel = "analyzer_model"
        case operationIndex = "operation_index"
        case totalOperations = "total_operations"
        case batchSize = "batch_size"
        case batchIndex = "batch_index"
        case batchTotal = "batch_total"
        case status
        case reason
        case confidence
    }
}

struct TestConfidenceAggregate: Decodable {
    let count: Int?
    let avg: Double?
    let median: Double?
    let min: Double?
    let failed: Int?
    let byStatus: [String: Int]?
    enum CodingKeys: String, CodingKey {
        case count
        case avg
        case median
        case min
        case failed
        case byStatus = "by_status"
    }
}

struct TestLowConfidenceCase: Decodable, Identifiable {
    let id: String
    let category: String?
    let status: String?
    let confidences: [String: Double]?
    let failedStages: [String]?
    let warnings: [String]?
    enum CodingKeys: String, CodingKey {
        case id
        case category
        case status
        case confidences
        case failedStages = "failed_stages"
        case warnings
    }
}

struct TestRunConfidence: Decodable, Hashable {
    let status: String?
    let confidence: Double?
    let verdict: String?
    let error: String?
    let warnings: [String]?
    let reasoningEffort: String?
    enum CodingKeys: String, CodingKey {
        case status
        case confidence
        case verdict
        case error
        case warnings
        case reasoningEffort = "reasoning_effort"
    }
}

struct TestRunResult: Decodable, Identifiable, Hashable {
    let caseID: String
    let category: String?
    let status: String
    let translationStatus: String?
    let improveStatus: String?
    let seconds: Double
    let translation: String?
    let improvedPrompt: String?
    let translatorModel: String
    let analyzerModel: String
    let translationConfidence: TestRunConfidence?
    let improveConfidence: TestRunConfidence?
    let overallConfidence: TestRunConfidence?
    let warnings: [String]
    var id: String { "\(caseID)|\(translatorModel)|\(analyzerModel)" }
    var comboID: String { "\(translatorModel) -> \(analyzerModel)" }
    enum CodingKeys: String, CodingKey {
        case caseID = "id"
        case category
        case status
        case translationStatus = "translation_status"
        case improveStatus = "improve_status"
        case seconds
        case translation
        case improvedPrompt = "improved_prompt"
        case translatorModel = "translator_model"
        case analyzerModel = "analyzer_model"
        case translationConfidence = "translation_confidence"
        case improveConfidence = "improve_confidence"
        case overallConfidence = "overall_confidence"
        case warnings
    }
}

struct TestPromptManifestCase: Decodable {
    let id: String
    let category: String?
    let prompt: String
}

struct TestCaseRunGroup: Identifiable {
    let caseID: String
    let title: String
    let rows: [TestRunResult]
    var id: String { caseID }
}
