import Foundation
import SwiftUI

extension DateFormatter {
    static let somaDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}


struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String?
}

struct OllamaResponse: Codable, Sendable {
    let response: String?
    let history: [[String: AnyCodable]]?
    let error: String?
}

struct GatherBundle: Codable, Sendable {
    let mode: String?
    let original_prompt: String?
    let project_root: String?
    let project_type: String?
    let routing_decision: String?
    let packet_profile: String?
    let packet_mode: String?
    let analysis_depth: String?
    let analysis_stages: [AnalysisStage]?
    let collection_plan: CollectionPlan?
    let collection_plan_source: String?
    let collection_plan_warnings: [String]?
    let preflight: [String: AnyCodable]?
    let model_analysis: [String: AnyCodable]?
    let gather_reason: String?
    let confidence: Double?
    let git_status: String?
    let git_diff: String?
    let git_diff_summary: GitDiffSummary?
    let repo_index: RepoIndexSummary?
    let gathered_files: [String: GatheredFile]?
    let evidence_items: [EvidenceItem]?
    let evidence_quality: [String: AnyCodable]?
    let error_lines: [String]?
    let context_summary: String?
    let open_questions: [String]?
    let assumptions: [String]?
    let token_budget: String?
    let estimated_tokens: Int?
    let token_savings: TokenSavings?
    let language_optimization: LanguageOptimization?
    let audit: AuditSummary?
    let estimated_context_reduction: TokenMetric?
    let operation_savings: TokenMetric?
    let local_ai_metrics: LocalAIMetrics?
    let omitted_context: [String: AnyCodable]?
    let codex_packet: String?
    let enriched_prompt: String?
    let error: String?
}

struct CollectionPlan: Codable, Sendable, Hashable {
    let task_type: String?
    let target_scope: String?
    let scope_hints: [String]?
    let required_evidence: [String]?
    let excluded_context: [String]?
    let expected_packet_style: String?
    let confidence: Double?
    let warnings: [String]?
}

struct TokenMetric: Codable, Sendable, Hashable {
    let metric: String?
    let status: String?
    let model_profile: String?
    let label: String?
    let estimator: String?
    let chars_per_token: Double?
    let exact_encoding: String?
    let packet_tokens: Int?
    let budget: String?
    let budget_tokens: Int?
    let budget_used_pct: Double?
    let baseline_type: String?
    let baseline_tokens: Int?
    let saved_tokens: Int?
    let savings_pct: Double?
    let operation_baseline_tokens: Int?
    let operation_baseline_chars: Int?
    let soma_response_tokens: Int?
    let warnings: [String]?
}

struct TokenSavings: Codable, Sendable, Hashable {
    let status: String?
    let primary_metric: String?
    let model_profile: String?
    let label: String?
    let estimator: String?
    let chars_per_token: Double?
    let exact_encoding: String?
    let packet_tokens: Int?
    let budget: String?
    let budget_tokens: Int?
    let budget_used_pct: Double?
    let baseline_type: String?
    let saved_tokens: Int?
    let savings_pct: Double?
    let estimated_context_reduction: TokenMetric?
    let operation_savings: TokenMetric?
    let warnings: [String]?
}

struct LanguageOptimization: Codable, Sendable, Hashable {
    let status: String?
    let source_language: String?
    let target_language: String?
    let engine: String?
    let original_prompt_tokens: Int?
    let normalized_prompt_tokens: Int?
    let saved_tokens: Int?
    let savings_pct: Double?
    let protected_spans_count: Int?
    let original_prompt_hash: String?
    let warning: String?
}

struct LocalAIMetrics: Codable, Sendable, Hashable {
    let local_ai_policy: String?
    let local_ai_call_count: Int?
    let local_ai_input_tokens: Int?
    let local_ai_output_tokens: Int?
    let local_ai_latency_ms: Double?
    let candidate_tokens_before: Int?
    let candidate_tokens_after: Int?
    let local_ai_net_savings_tokens: Int?
}

struct AuditSummary: Codable, Sendable, Hashable {
    let run_id: String?
    let task_id: String?
    let workflow: String?
    let project_root: String?
    let project_type: String?
    let prompt_hash: String?
    let normalized_prompt_hash: String?
    let packet_hash: String?
    let selected_evidence: [AuditEvidence]?
    let missing_evidence: AuditMissingEvidence?
    let evidence_quality: AuditEvidenceQuality?
    let tool_calls_expected: [String]?
    let next_calls: [String]?
    let raw_capture_enabled: Bool?
    let audit_report_path: String?
}

struct AuditReport: Codable, Sendable, Hashable {
    let run_id: String?
    let task_id: String?
    let workflow: String?
    let client: String?
    let status: String?
    let created_at: String?
    let updated_at: String?
    let project_root: String?
    let project_type: String?
    let prompt_hash: String?
    let normalized_prompt_hash: String?
    let packet_hash: String?
    let prompt_chars: Int?
    let normalized_prompt_chars: Int?
    let packet_chars: Int?
    let estimated_tokens: Int?
    let raw_capture_enabled: Bool?
    let raw_artifacts: [String: String]?
    let language_optimization: LanguageOptimization?
    let selected_evidence: [AuditEvidence]?
    let missing_evidence: AuditMissingEvidence?
    let evidence_quality: AuditEvidenceQuality?
    let tool_calls_expected: [String]?
    let tool_calls: [AuditToolCall]?
    let events: [AuditEvent]?
    let quality_review: AuditQualityReview?
    let audit_report_path: String?
}

struct AuditEvidence: Codable, Sendable, Hashable, Identifiable {
    var id: String { path ?? UUID().uuidString }
    let path: String?
    let kind: String?
    let reason: String?
    let symbols: [String]?
    let start_line: Int?
    let end_line: Int?
}

struct AuditMissingEvidence: Codable, Sendable, Hashable {
    let status: String?
    let unresolved_references: [AuditMissingReference]?
    let missing_files: [AuditMissingReference]?
    let missing_symbols: [AuditMissingReference]?
    let unresolved_concepts: [AuditMissingReference]?
    let found_not_selected: [AuditMissingReference]?
    let resolved_references: [AuditMissingReference]?
    let quality_warnings: [String]?
    let skipped_stages: [AuditSkippedStage]?
    let requested_extra_context: [String]?
    let explicit_paths_found: [String]?
    let reason: String?
}

struct AuditMissingReference: Codable, Sendable, Hashable, Identifiable {
    var id: String { reference ?? UUID().uuidString }
    let reference: String?
    let reason: String?
    let kind: String?
    let matched_paths: [String]?
}

struct AuditSkippedStage: Codable, Sendable, Hashable, Identifiable {
    var id: String { "\(stage ?? "stage")-\(status ?? "status")-\(reason ?? "")" }
    let stage: String?
    let status: String?
    let reason: String?
}

struct AuditEvidenceQuality: Codable, Sendable, Hashable {
    let status: String?
    let strong_match_count: Int?
    let weak_match_count: Int?
    let warnings: [String]?
}

struct AuditToolCall: Codable, Sendable, Hashable, Identifiable {
    var id: String { "\(ts ?? "")-\(tool ?? "")" }
    let ts: String?
    let tool: String?
    let status: String?
    let duration_ms: Double?
    let input_tokens: Int?
    let output_tokens: Int?
    let packet_tokens: Int?
    let prompt_hash: String?
    let packet_hash: String?
}

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

    private enum CodingKeys: String, CodingKey {
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

struct AnyCodable: Codable, Sendable {
    let value: Sendable

    init(_ value: Sendable) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil()                                          { self.value = JSONNull() }
        else if let value = try? container.decode(String.self)            { self.value = value }
        else if let value = try? container.decode(Int.self)               { self.value = value }
        else if let value = try? container.decode(Double.self)            { self.value = value }
        else if let value = try? container.decode(Bool.self)             { self.value = value }
        else if let value = try? container.decode([String: AnyCodable].self) { self.value = value }
        else if let value = try? container.decode([AnyCodable].self)     { self.value = value }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown type") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value = value as? String                     { try container.encode(value) }
        else if let value = value as? Int                  { try container.encode(value) }
        else if let value = value as? Double               { try container.encode(value) }
        else if let value = value as? Bool                 { try container.encode(value) }
        else if let value = value as? [String: AnyCodable] { try container.encode(value) }
        else if let value = value as? [AnyCodable]         { try container.encode(value) }
        else if value is JSONNull                          { try container.encodeNil() }
    }
}

extension AnyCodable {
    var displayValue: String {
        if let value = value as? String { return value }
        if let value = value as? Int { return String(value) }
        if let value = value as? Double { return String(format: "%.2f", value) }
        if let value = value as? Bool { return value ? "true" : "false" }
        if value is JSONNull { return "null" }
        return String(describing: value)
    }
}

// Consolidated status models
struct SomaGatewayStatus: Codable, Sendable {
    let status: String?
    let project_root: String?
    let server: SomaServerInfo?
    let nexus: SomaNexusStatus?
    let graph: SomaGraphStatus?
}

struct SomaServerInfo: Codable, Sendable {
    let transport: String?
    let tool_count: Int?
    let tool_names: [String]?
}

struct SomaNexusStatus: Codable, Sendable {
    let connected: Bool?
    let port: Int?
    let project_path: String?
    let session_id: String?
    let session_generation: Int?
    let unity_version: String?
    let busy_reason: String?
}

struct SomaGraphStatus: Codable, Sendable {
    let available: Bool?
    let project_graph_available: Bool?
    let managed_available: Bool?
    let legacy_available: Bool?
    let storage_kind: String?
    let stale: Bool?
    let node_count: Int?
    let edge_count: Int?
    let storage_path: String?
    let managed_path: String?
    let legacy_paths: [String]?
    let graphify_version: String?
    let recommended_action: String?
}

struct GraphStorageInfo: Codable, Sendable {
    let project_id: String?
    let project_root: String?
    let display_name: String?
    let project_dir: String?
    let output_root: String?
    let graph_dir: String?
    let graph_json: String?
    let legacy_paths: [String]?
}

struct ClientConfigStatus: Codable, Sendable {
    let status: String
    let summary: String
    let config_path: String?
    let soma_installed: Bool?
    let direct_nexus_exposed: Bool?
    let tool_exposure_clean: Bool?
    let actual_project_root: String?
    let expected_project_root: String?
    let project_matches: Bool?
    let issues: [String]
}

struct ClientConfigInstallStatus: Codable, Sendable {
    let status: String
    let summary: String
    let config_path: String?
    let backup_path: String?
    let soma_installed: Bool?
    let direct_nexus_removed: Bool?
    let old_soma_blocks_replaced: Int?
    let actual_project_root: String?
    let expected_project_root: String?
    let project_matches: Bool?
    let issues: [String]
}

struct ClientConfigRollbackStatus: Codable, Sendable {
    let status: String
    let summary: String
    let config_path: String?
    let backup_path: String?
    let restored: Bool?
    let post_restore_status: String?
    let post_restore_issues: [String]?
    let issues: [String]?
}

struct ProjectAISetupReport: Codable, Sendable {
    let status: String?
    let summary: String?
    let generated_at: String?
    let updated_at: String?
    let project_root: String?
    let mode: String?
    let files_inspected: [ProjectAISetupFile]?
    let files_changed: [ProjectAISetupChangedFile]?
    let backups: [ProjectAISetupBackup]?
    let issues: [String]?
    let removed_direct_mcp_servers: [String]?
    let inserted_or_updated_prompt_blocks: [String]?
    let verification: ProjectAISetupVerification?
    let remaining_risks: [String]?
    let local_ai_checks: [ProjectAISetupLocalCheck]?
    let report_path: String?
}

struct ProjectAISetupFile: Codable, Sendable, Identifiable {
    var id: String { path ?? label ?? UUID().uuidString }
    let label: String?
    let path: String?
    let exists: Bool?
    let issues: [String]?
    let direct_markers: [String]?
    let soma_first_block: Bool?
    let size: Int?
}

struct ProjectAISetupChangedFile: Codable, Sendable, Identifiable {
    var id: String { path ?? UUID().uuidString }
    let path: String?
    let backup_path: String?
}

struct ProjectAISetupBackup: Codable, Sendable, Identifiable {
    var id: String { "\(path ?? "")-\(backup_path ?? "")" }
    let path: String?
    let backup_path: String?
}

struct ProjectAISetupVerification: Codable, Sendable {
    let status: String?
    let remaining_issues: [String]?
}

struct ProjectAISetupLocalCheck: Codable, Sendable, Identifiable {
    var id: String { stage ?? UUID().uuidString }
    let stage: String?
    let status: String?
    let model: String?
    let reason: String?
    let error: String?
    let warnings: [String]?
    let notes: [String]?
}

struct LiveVerifyStatus: Codable, Sendable {
    let status: String
    let project_root: String?
    let issues: [String]?
    let tools: LiveVerifyTools?
    let nexus: SomaNexusStatus?
    let graph: SomaGraphStatus?
    let calls: [String: LiveVerifyCall]?
}

struct LiveVerifyTools: Codable, Sendable {
    let count: Int?
    let expected_count: Int?
    let unity_exposed: [String]?
}

struct LiveVerifyCall: Codable, Sendable {
    let status: String?
    let summary: String?
    let instance_id: Int?
    let path: String?
}

struct MCPSmokeReport: Codable, Sendable {
    let status: String?
    let generated_at: String?
    let project_root: String?
    let clients: [String: ClientConfigStatus]?
    let server: MCPSmokeServer?
    let initialize: MCPSmokeStep?
    let tools_list: MCPSmokeStep?
    let tool_results: [MCPSmokeStep]?
    let plugin_status: MCPSmokePluginStatus?
    let summary: MCPSmokeSummary?
    let issues: [String]?
    let log_file: String?
}

struct MCPSmokeServer: Codable, Sendable {
    let status: String?
    let tool_count: Int?
    let tool_names: [String]?
}

struct MCPSmokeStep: Codable, Sendable, Identifiable {
    var id: String { tool ?? output_hash ?? summary ?? "mcp-smoke-step" }
    let tool: String?
    let status: String?
    let result_status: String?
    let summary: String?
    let reason: String?
    let duration_ms: Double?
    let output_chars: Int?
    let output_hash: String?
    let tool_count: Int?
    let tool_names: [String]?
}

struct MCPSmokePluginStatus: Codable, Sendable {
    let unity_nexus: String?
    let nexus_connected: Bool?
    let nexus_project: String?
    let project_matches: Bool?
}

struct MCPSmokeSummary: Codable, Sendable {
    let tool_count: Int?
    let smoked_tools: Int?
    let skipped_tools: Int?
    let failed_tools: [String]?
    let config_degraded: [String]?
    let duration_ms: Double?
}

// Structured log entry from ~/.soma/logs/soma_YYYYMMDD.jsonl
struct SomaLogEntry: Identifiable, Sendable {
    let id: UUID = UUID()
    let ts: String
    let event: String
    let tool: String?
    let method: String?
    let status: String
    let duration_ms: Double?
    let input_tokens: Int?
    let output_tokens: Int?
    let packet_tokens: Int?
    let budget_used_pct: Double?
    let saved_tokens: Int?
    let savings_pct: Double?
    let primary_metric: String?
    let operation_saved_tokens: Int?
    let operation_savings_pct: Double?
    let operation_baseline_tokens: Int?
    let soma_response_tokens: Int?
    let estimated_context_saved_tokens: Int?
    let estimated_context_reduction_pct: Double?
    let estimated_context_baseline_tokens: Int?
    let baseline_type: String?
    let token_estimator: String?
    let client: String?
    let run_id: String?
    let task_id: String?
    let workflow: String?
    let prompt_hash: String?
    let packet_hash: String?
    let local_model_provider: String?
    let local_model: String?
    let local_model_stage: String?
    let local_model_json_mode: Bool?
    let local_model_num_predict: Int?
    let local_model_tool_count: Int?
    let local_model_message_count: Int?
    let local_ai_policy: String?
    let local_ai_call_count: Int?
    let local_ai_input_tokens: Int?
    let local_ai_output_tokens: Int?
    let local_ai_latency_ms: Double?
    let candidate_tokens_before: Int?
    let candidate_tokens_after: Int?
    let local_ai_net_savings_tokens: Int?
    let output_truncated: Bool?
    let omitted_output_tokens: Int?
    let source_language: String?
    let translation_status: String?
    let translation_engine: String?
    let prompt_saved_tokens: Int?
    let prompt_savings_pct: Double?
    let protected_spans_count: Int?
    let error: String?
    let rawPayload: String?

    var displayName: String { tool ?? method ?? event }
    var totalTokens: Int { (input_tokens ?? 0) + (output_tokens ?? 0) }
    var isError: Bool { status == "error" }
    var isDegraded: Bool { status == "degraded" }
    var shortTime: String { String(ts.prefix(19)).replacingOccurrences(of: "T", with: " ") }

    init?(from dict: [String: Any]) {
        guard let ts = dict["ts"] as? String,
              let event = dict["event"] as? String else { return nil }
        self.ts = ts
        self.event = event
        self.tool = dict["tool"] as? String
        self.method = dict["method"] as? String
        self.status = (dict["status"] as? String) ?? "ok"
        self.duration_ms = dict["duration_ms"] as? Double
        self.input_tokens = dict["input_tokens"] as? Int
        self.output_tokens = dict["output_tokens"] as? Int
        self.packet_tokens = SomaLogEntry.intValue(dict["packet_tokens"])
        self.budget_used_pct = SomaLogEntry.doubleValue(dict["budget_used_pct"])
        self.saved_tokens = SomaLogEntry.intValue(dict["saved_tokens"])
        self.savings_pct = SomaLogEntry.doubleValue(dict["savings_pct"])
        self.primary_metric = dict["primary_metric"] as? String
        self.operation_saved_tokens = SomaLogEntry.intValue(dict["operation_saved_tokens"])
        self.operation_savings_pct = SomaLogEntry.doubleValue(dict["operation_savings_pct"])
        self.operation_baseline_tokens = SomaLogEntry.intValue(dict["operation_baseline_tokens"])
        self.soma_response_tokens = SomaLogEntry.intValue(dict["soma_response_tokens"])
        self.estimated_context_saved_tokens = SomaLogEntry.intValue(dict["estimated_context_saved_tokens"])
        self.estimated_context_reduction_pct = SomaLogEntry.doubleValue(dict["estimated_context_reduction_pct"])
        self.estimated_context_baseline_tokens = SomaLogEntry.intValue(dict["estimated_context_baseline_tokens"])
        self.baseline_type = dict["baseline_type"] as? String
        self.token_estimator = dict["token_estimator"] as? String
        self.client = dict["client"] as? String
        self.run_id = dict["run_id"] as? String
        self.task_id = dict["task_id"] as? String
        self.workflow = dict["workflow"] as? String
        self.prompt_hash = dict["prompt_hash"] as? String
        self.packet_hash = dict["packet_hash"] as? String
        self.local_model_provider = dict["local_model_provider"] as? String
        self.local_model = dict["local_model"] as? String
        self.local_model_stage = dict["local_model_stage"] as? String
        self.local_model_json_mode = dict["local_model_json_mode"] as? Bool
        self.local_model_num_predict = SomaLogEntry.intValue(dict["local_model_num_predict"])
        self.local_model_tool_count = SomaLogEntry.intValue(dict["local_model_tool_count"])
        self.local_model_message_count = SomaLogEntry.intValue(dict["local_model_message_count"])
        self.local_ai_policy = dict["local_ai_policy"] as? String
        self.local_ai_call_count = SomaLogEntry.intValue(dict["local_ai_call_count"])
        self.local_ai_input_tokens = SomaLogEntry.intValue(dict["local_ai_input_tokens"])
        self.local_ai_output_tokens = SomaLogEntry.intValue(dict["local_ai_output_tokens"])
        self.local_ai_latency_ms = SomaLogEntry.doubleValue(dict["local_ai_latency_ms"])
        self.candidate_tokens_before = SomaLogEntry.intValue(dict["candidate_tokens_before"])
        self.candidate_tokens_after = SomaLogEntry.intValue(dict["candidate_tokens_after"])
        self.local_ai_net_savings_tokens = SomaLogEntry.intValue(dict["local_ai_net_savings_tokens"])
        self.output_truncated = dict["output_truncated"] as? Bool
        self.omitted_output_tokens = SomaLogEntry.intValue(dict["omitted_output_tokens"])
        self.source_language = dict["source_language"] as? String
        self.translation_status = dict["translation_status"] as? String
        self.translation_engine = dict["translation_engine"] as? String
        self.prompt_saved_tokens = SomaLogEntry.intValue(dict["prompt_saved_tokens"])
        self.prompt_savings_pct = SomaLogEntry.doubleValue(dict["prompt_savings_pct"])
        self.protected_spans_count = SomaLogEntry.intValue(dict["protected_spans_count"])
        self.error = dict["error"] as? String
        self.rawPayload = SomaLogEntry.prettyPayload(from: dict)
    }

    private static func prettyPayload(from dict: [String: Any]) -> String? {
        let redacted = redactSensitiveValues(in: dict)
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func redactSensitiveValues(in value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, nestedValue) in dict {
                let lower = key.lowercased()
                if lower.contains("token") || lower.contains("secret") || lower.contains("password") || lower.contains("apikey") || lower.contains("api_key") || lower.contains("authorization") {
                    output[key] = "[REDACTED]"
                } else {
                    output[key] = redactSensitiveValues(in: nestedValue)
                }
            }
            return output
        }
        if let array = value as? [Any] {
            return array.map { redactSensitiveValues(in: $0) }
        }
        return value
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}

struct SomaLocalModelStat: Identifiable, Sendable {
    let id: String
    let calls: Int
    let errors: Int
    let avgDuration: Double
    let totalTokens: Int
    let stages: [String: Int]
    let models: [String: Int]

    var errorRate: Double { calls > 0 ? Double(errors) / Double(calls) : 0 }
}

struct SomaToolStat: Identifiable, Sendable {
    let id: String
    let calls: Int
    let errors: Int
    let avgDuration: Double
    let totalTokens: Int
    let totalSavedTokens: Int
    let avgSavingsPct: Double?
    let totalOperationSavedTokens: Int
    let avgOperationSavingsPct: Double?
    let totalEstimatedContextSavedTokens: Int
    let avgEstimatedContextReductionPct: Double?

    var errorRate: Double { calls > 0 ? Double(errors) / Double(calls) : 0 }
}

struct TokenBenchmarkReport: Codable, Sendable {
    let status: String?
    let generated_at: String?
    let model_profile: String?
    let budget: String?
    let baseline: String?
    let summary: TokenBenchmarkSummary?
    let results: [TokenBenchmarkResult]?
}

struct TokenBenchmarkSummary: Codable, Sendable {
    let mode: String?
    let result_count: Int?
    let valid_result_count: Int?
    let failed_result_count: Int?
    let failed_fixture_count: Int?
    let avg_savings_pct: Double?
    let total_baseline_tokens: Int?
    let total_soma_packet_tokens: Int?
    let total_saved_tokens: Int?
}

struct TokenBenchmarkResult: Codable, Sendable {
    let project: String?
    let project_root: String?
    let project_type: String?
    let status: String?
    let baseline_tokens: Int?
    let soma_packet_tokens: Int?
    let saved_tokens: Int?
    let savings_pct: Double?
}

struct AgentBenchmarkReport: Codable, Sendable {
    let status: String?
    let generated_at: String?
    let scenario_path: String?
    let project_root: String?
    let agents: [String]?
    let model_profile: String?
    let budget: String?
    let depth: String?
    let mode: String?
    let summary: AgentBenchmarkSummary?
    let comparisons: [AgentBenchmarkComparison]?
    let runs: [AgentBenchmarkRun]?
}

struct AgentBenchmarkSummary: Codable, Sendable {
    let run_count: Int?
    let failed_run_count: Int?
    let comparison_count: Int?
    let paired_result_count: Int?
    let total_direct_tokens: Int?
    let total_with_soma_tokens: Int?
    let total_saved_tokens: Int?
    let avg_savings_pct: Double?
    let usage_sources: [String]?
}

struct AgentBenchmarkComparison: Codable, Sendable {
    let task_id: String?
    let run_id: String?
    let agent: String?
    let status: String?
    let direct_tokens: Int?
    let with_soma_tokens: Int?
    let saved_tokens: Int?
    let savings_pct: Double?
    let direct_usage_source: String?
    let with_soma_usage_source: String?
    let acceptance_status: String?
    let direct_acceptance_status: String?
    let with_soma_acceptance_status: String?
    let soma_packet_status: String?
}

struct AgentBenchmarkRun: Codable, Sendable, Identifiable {
    var id: String { "\(task_id ?? "task")-\(agent ?? "agent")-\(mode ?? "mode")" }
    let run_id: String?
    let task_id: String?
    let agent: String?
    let mode: String?
    let workflow: String?
    let status: String?
    let duration_ms: Double?
    let usage_source: String?
    let total_tokens: Int?
    let prompt_sha256: String?
    let stdout_sha256: String?
    let stderr_sha256: String?
    let tool_marker_count: Int?
    let soma_packet_tokens: Int?
    let soma_packet_status: String?
    let acceptance_status: String?
}
