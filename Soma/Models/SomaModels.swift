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
