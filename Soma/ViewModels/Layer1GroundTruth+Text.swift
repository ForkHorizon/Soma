import Foundation

extension Layer1GroundTruthStore {
    static func normalizeForReview(_ text: String) -> String {
        var output = ""
        var needsSpace = false
        for character in text.precomposedStringWithCanonicalMapping.lowercased() {
            if character.isLetter || character.isNumber {
                if needsSpace && !output.isEmpty { output.append(" ") }
                output.append(character)
                needsSpace = false
            } else {
                needsSpace = true
            }
        }
        return output
    }

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
