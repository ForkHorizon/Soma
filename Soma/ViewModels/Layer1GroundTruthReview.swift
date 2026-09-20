import Foundation

enum Layer1HumanAction: String, Codable {
    case selectedModel, selectedAndEdited, manual, noSpeech, unclear
}
enum Layer1ReviewStatus: String, Codable { case pending, verified }
