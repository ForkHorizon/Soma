import Foundation

struct Layer1AudioFile: Codable, Hashable, Identifiable {
    let id: String
    let path: String
    let audioHash: String
    let duration: Double
    let addedAt: Date
    var batchIDs: [String]
    var lastStatus: Layer1BatchStatus

    var url: URL { URL(fileURLWithPath: path) }
}

struct Layer1WordTimestamp: Codable, Hashable {
    let word: String
    let start: Double
    let end: Double
}
