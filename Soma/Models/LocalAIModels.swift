import Foundation

enum LocalModelRole: String, CaseIterable, Identifiable, Codable {
    case scout
    case ranker
    case analyst
    case translator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scout: return "Scout"
        case .ranker: return "Planner / Ranker"
        case .analyst: return "Analyst"
        case .translator: return "Translator"
        }
    }

    var envKey: String {
        switch self {
        case .scout: return "SOMA_LOCAL_MODEL"
        case .ranker: return "SOMA_RANKER_MODEL"
        case .analyst: return "SOMA_ANALYST_MODEL"
        case .translator: return "SOMA_TRANSLATOR_MODEL"
        }
    }

    var defaultModel: String {
        switch self {
        case .scout, .ranker: return "gemma4:e4b"
        case .analyst: return "qwen3-coder:30b-a3b-q4_K_M"
        case .translator: return ""
        }
    }

    var subtitle: String {
        switch self {
        case .scout:
            return "Direct file exploration chat and keep-alive controls."
        case .ranker:
            return "Collection planning, evidence ranking, filters, and referees."
        case .analyst:
            return "Deeper packet analysis used by analyst mode and Prompt Builder."
        case .translator:
            return "Prompt language optimization. Auto follows backend fallback."
        }
    }

    var stageHints: [String] {
        switch self {
        case .scout:
            return ["ollama_chat", "scout"]
        case .ranker:
            return ["collection_plan", "candidate_filter", "ranker", "quality_referee", "evidence_referee", "summary"]
        case .analyst:
            return ["analyst"]
        case .translator:
            return ["translation"]
        }
    }

    var allowsAuto: Bool { self == .translator }
}

struct OllamaInstalledModel: Identifiable, Decodable, Hashable {
    let name: String
    let model: String?
    let modified_at: String?
    let size: Int64?
    let digest: String?
    let details: Details?

    var id: String { name }

    struct Details: Decodable, Hashable {
        let family: String?
        let parameter_size: String?
        let quantization_level: String?
    }

    var parameterSize: String {
        details?.parameter_size ?? "unknown size"
    }

    var quantization: String {
        details?.quantization_level ?? "unknown quant"
    }

    var displayDetail: String {
        [parameterSize, quantization, formattedSize].filter { !$0.isEmpty }.joined(separator: " | ")
    }

    var formattedSize: String {
        guard let size else { return "" }
        let gb = Double(size) / 1_000_000_000
        return String(format: "%.1f GB", gb)
    }
}

enum LocalModelSettingsStore {
    private static let keyPrefix = "localAI.model."

    static func userDefaultsKey(for role: LocalModelRole) -> String {
        keyPrefix + role.rawValue
    }

    static func model(for role: LocalModelRole) -> String {
        let key = userDefaultsKey(for: role)
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.string(forKey: key) ?? ""
        }
        if let envValue = ProcessInfo.processInfo.environment[role.envKey], !envValue.isEmpty {
            return envValue
        }
        return role.defaultModel
    }

    static func setModel(_ model: String, for role: LocalModelRole) {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: userDefaultsKey(for: role))
    }

    static func apply(to environment: inout [String: String]) {
        for role in LocalModelRole.allCases {
            let model = model(for: role).trimmingCharacters(in: .whitespacesAndNewlines)
            if role.allowsAuto && model.isEmpty {
                environment.removeValue(forKey: role.envKey)
            } else if !model.isEmpty {
                environment[role.envKey] = model
            }
        }
    }
}
