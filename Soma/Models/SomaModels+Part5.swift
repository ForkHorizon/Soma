import Foundation
import SwiftUI

nonisolated struct TokenBenchmarkSummary: Codable, Sendable {
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

nonisolated struct TokenBenchmarkResult: Codable, Sendable {
    let project: String?
    let project_root: String?
    let project_type: String?
    let status: String?
    let baseline_tokens: Int?
    let soma_packet_tokens: Int?
    let saved_tokens: Int?
    let savings_pct: Double?
}

nonisolated struct AgentBenchmarkReport: Codable, Sendable {
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

nonisolated struct AgentBenchmarkSummary: Codable, Sendable {
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

nonisolated struct AgentBenchmarkComparison: Codable, Sendable {
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

nonisolated struct AgentBenchmarkRun: Codable, Sendable, Identifiable {
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
