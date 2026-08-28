import Foundation

extension Layer1GroundTruthStore {
    static func normalize(_ text: String) -> String {
        var output = ""
        for character in text.lowercased() {
            if character.isWhitespace {
                output.append(" ")
            } else if "+#*".contains(character) {
                output.append(character)
            } else if character.unicodeScalars.allSatisfy({
                CharacterSet.punctuationCharacters.contains($0)
            }) {
                continue
            } else {
                output.append(character)
            }
        }
        return output.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func assemble(_ segments: [Layer1Segment]) -> String {
        segments.sorted { $0.start < $1.start }.compactMap { $0.decision.text }.joined(separator: " ")
    }
}
