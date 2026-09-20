import Foundation

struct Layer1ModelSuggestion: Codable, Hashable {
    let modelID: String
    let model: String
    let status: Layer1ModelRunStatus
    let text: String?
    let reviewText: String?
    let error: String?
    let runID: String?
}

struct Layer1SegmentDecision: Codable, Hashable {
    var status: Layer1ReviewStatus
    var text: String?
    var normalizedText: String?
    var action: Layer1HumanAction?
    var sourceModelID: String?
    var createdAt: Date?
    var updatedAt: Date?
}
