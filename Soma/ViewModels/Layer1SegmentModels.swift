import Foundation

struct Layer1Segment: Codable, Hashable, Identifiable {
    let id: String
    let audioID: String
    let start: Double
    let end: Double
    let segmentationAlgorithmVersion: String
    let sourceWordRange: Range<Int>?
    var modelSuggestions: [String: Layer1ModelSuggestion]
    let proposalOrder: [String]
    var segmentationNeedsReview: Bool
    var decision: Layer1SegmentDecision
}

struct Layer1Batch: Codable, Hashable, Identifiable {
    let id: String
    let createdAt: Date
    let requestedCount: Int
    let fileIDs: [String]
    var status: Layer1BatchStatus
}
