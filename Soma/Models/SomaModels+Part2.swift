import Foundation
import SwiftUI

struct AuditEvent: Codable, Sendable, Hashable, Identifiable {
    var id: String { "\(ts ?? "")-\(event ?? "")-\(tool ?? "")" }
    let ts: String?
    let event: String?
    let tool: String?
    let status: String?
    let duration_ms: Double?
    let total_tokens: Int?
    let acceptance_status: String?
}

struct AuditQualityReview: Codable, Sendable, Hashable {
    let status: String?
    let notes: String?
    let reviewed_at: String?
    let source: String?
}

struct AnalysisStage: Codable, Sendable, Hashable {
    let stage: String?
    let model: String?
    let status: String?
    let error: String?
    let notes: [String]?
    let candidate_count_before: Int?
    let candidate_count_after: Int?
    let candidate_tokens_before: Int?
    let candidate_tokens_after: Int?
    let local_ai_net_savings_tokens: Int?

    enum CodingKeys: String, CodingKey {
        case stage
        case model
        case status
        case error
        case notes
        case candidate_count_before
        case candidate_count_after
        case candidate_tokens_before
        case candidate_tokens_after
        case local_ai_net_savings_tokens
    }

    init(
        stage: String? = nil,
        model: String? = nil,
        status: String? = nil,
        error: String? = nil,
        notes: [String]? = nil,
        candidate_count_before: Int? = nil,
        candidate_count_after: Int? = nil,
        candidate_tokens_before: Int? = nil,
        candidate_tokens_after: Int? = nil,
        local_ai_net_savings_tokens: Int? = nil
    ) {
        self.stage = stage
        self.model = model
        self.status = status
        self.error = error
        self.notes = notes
        self.candidate_count_before = candidate_count_before
        self.candidate_count_after = candidate_count_after
        self.candidate_tokens_before = candidate_tokens_before
        self.candidate_tokens_after = candidate_tokens_after
        self.local_ai_net_savings_tokens = local_ai_net_savings_tokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = try container.decodeIfPresent(String.self, forKey: .stage)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        if let notesArray = try? container.decodeIfPresent([String].self, forKey: .notes) {
            notes = notesArray
        } else if let note = try? container.decodeIfPresent(String.self, forKey: .notes) {
            notes = note.isEmpty ? [] : [note]
        } else {
            notes = nil
        }
        candidate_count_before = try container.decodeIfPresent(Int.self, forKey: .candidate_count_before)
        candidate_count_after = try container.decodeIfPresent(Int.self, forKey: .candidate_count_after)
        candidate_tokens_before = try container.decodeIfPresent(Int.self, forKey: .candidate_tokens_before)
        candidate_tokens_after = try container.decodeIfPresent(Int.self, forKey: .candidate_tokens_after)
        local_ai_net_savings_tokens = try container.decodeIfPresent(Int.self, forKey: .local_ai_net_savings_tokens)
    }
}

struct GitDiffSummary: Codable, Sendable, Hashable {
    let changed_files: [GitChangedFile]?
    let changed_file_count: Int?
    let hunks: [GitHunk]?
    let raw_diff_chars_omitted: Int?
}

struct GitChangedFile: Codable, Sendable, Hashable {
    let status: String?
    let path: String?
    let added: String?
    let removed: String?
}

struct GitHunk: Codable, Sendable, Hashable {
    let file: String?
    let start_line: Int?
    let end_line: Int?
    let added: Int?
    let removed: Int?
    let signals: [String]?
}

struct RepoIndexSummary: Codable, Sendable, Hashable {
    let cache_path: String?
    let indexed_file_count: Int?
    let changed_index_entries: Int?
}

struct GatheredFile: Codable, Sendable, Hashable {
    let tool: String?
    let preview: String?
}

struct EvidenceItem: Codable, Sendable, Hashable {
    let path: String?
    let kind: String?
    let reason: String?
    let preview: String?
    let start_line: Int?
    let end_line: Int?
    let symbols: [String]?
    let unity_refs: [String]?
}

struct RelayResponse: Codable, Sendable {
    let response: String?
    let source: String?
    let model: String?
    let routing_decision: String?
    let enriched_prompt: String?
    let codex_packet: String?
    let estimated_tokens: Int?
    let files_used: [String]?
    let errors_found: Int?
    let error: String?
}

struct PacketHistoryItem: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let createdAt: String
    let projectRoot: String
    let projectName: String
    let prompt: String
    let status: String
    let packetMode: String?
    let estimatedTokens: Int?
    let evidencePaths: [String]
    let evidenceSummaries: [String]?
    let warnings: [String]
    let auditRunID: String?
    var usefulness: String?
    var whyNotUseful: String?
    var missedFiles: [String]
    var agentUsedSoma: Bool
    var toolCallCount: Int
    var finalOutcome: String

    init(
        id: String,
        createdAt: String,
        projectRoot: String,
        projectName: String,
        prompt: String,
        status: String,
        packetMode: String?,
        estimatedTokens: Int?,
        evidencePaths: [String],
        evidenceSummaries: [String]?,
        warnings: [String],
        auditRunID: String?,
        usefulness: String? = nil,
        whyNotUseful: String? = nil,
        missedFiles: [String] = [],
        agentUsedSoma: Bool = false,
        toolCallCount: Int = 0,
        finalOutcome: String = "unknown"
    ) {
        self.id = id
        self.createdAt = createdAt
        self.projectRoot = projectRoot
        self.projectName = projectName
        self.prompt = prompt
        self.status = status
        self.packetMode = packetMode
        self.estimatedTokens = estimatedTokens
        self.evidencePaths = evidencePaths
        self.evidenceSummaries = evidenceSummaries
        self.warnings = warnings
        self.auditRunID = auditRunID
        self.usefulness = usefulness
        self.whyNotUseful = whyNotUseful
        self.missedFiles = missedFiles
        self.agentUsedSoma = agentUsedSoma
        self.toolCallCount = toolCallCount
        self.finalOutcome = finalOutcome
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case projectRoot
        case projectName
        case prompt
        case status
        case packetMode
        case estimatedTokens
        case evidencePaths
        case evidenceSummaries
        case warnings
        case auditRunID
        case usefulness
        case whyNotUseful
        case missedFiles
        case agentUsedSoma
        case toolCallCount
        case finalOutcome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        projectRoot = try container.decode(String.self, forKey: .projectRoot)
        projectName = try container.decode(String.self, forKey: .projectName)
        prompt = try container.decode(String.self, forKey: .prompt)
        status = try container.decode(String.self, forKey: .status)
        packetMode = try container.decodeIfPresent(String.self, forKey: .packetMode)
        estimatedTokens = try container.decodeIfPresent(Int.self, forKey: .estimatedTokens)
        evidencePaths = try container.decodeIfPresent([String].self, forKey: .evidencePaths) ?? []
        evidenceSummaries = try container.decodeIfPresent([String].self, forKey: .evidenceSummaries)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        auditRunID = try container.decodeIfPresent(String.self, forKey: .auditRunID)
        usefulness = try container.decodeIfPresent(String.self, forKey: .usefulness)
        whyNotUseful = try container.decodeIfPresent(String.self, forKey: .whyNotUseful)
        missedFiles = try container.decodeIfPresent([String].self, forKey: .missedFiles) ?? []
        agentUsedSoma = try container.decodeIfPresent(Bool.self, forKey: .agentUsedSoma) ?? false
        toolCallCount = try container.decodeIfPresent(Int.self, forKey: .toolCallCount) ?? 0
        finalOutcome = try container.decodeIfPresent(String.self, forKey: .finalOutcome) ?? "unknown"
    }
}

struct JSONNull: Codable, Sendable, Hashable {}
