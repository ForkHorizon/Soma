import SwiftUI

/// Word-level highlighting across the engine candidates for one recording.
///
/// Seven transcripts of the same sentence are nearly identical, and the whole
/// question is which two or three words they disagree about. Reading them side
/// by side to find that by eye is the slowest part of review — and the part a
/// listener ends up replaying the audio for, because they lost track of what
/// they were listening for.
enum GroundTruthDiff {
    /// One candidate's words plus the positions no other candidate agrees on.
    struct Marked {
        let words: [String]
        let differing: Set<Int>
    }

    /// Punctuation and case differ between the engines on every single word —
    /// GigaAM writes lowercase and unpunctuated — so comparing raw would paint
    /// the entire transcript and say nothing. This is the same normalisation the
    /// consensus votes on, so the highlights match what actually counted as a
    /// disagreement.
    private static func key(_ word: String) -> String {
        String(word.lowercased().replacingOccurrences(of: "ё", with: "е")
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Marks every candidate against the first one, then folds the differences
    /// found on the anchor's side back into the anchor itself — otherwise the
    /// transcript everything is compared against would be the one place a
    /// disagreement stays invisible.
    static func mark(_ candidates: [(String, String)], anchor preferred: String? = nil) -> [String: Marked] {
        let named = preferred.flatMap { name in candidates.first { $0.0 == name && !$0.1.isEmpty }?.0 }
        guard let anchorName = named ?? candidates.first(where: { !$0.1.isEmpty })?.0 else {
            return candidates.reduce(into: [:]) { $0[$1.0] = Marked(words: [], differing: []) }
        }
        let anchor = words(of: candidates.first { $0.0 == anchorName }?.1 ?? "")
        let anchorKeys = anchor.map(key)

        var anchorDiffering: Set<Int> = []
        var marked: [String: Marked] = [:]
        for (name, text) in candidates where name != anchorName {
            let candidate = words(of: text)
            var own: Set<Int> = []
            for change in candidate.map(key).difference(from: anchorKeys) {
                switch change {
                case let .insert(offset, _, _): own.insert(offset)
                case let .remove(offset, _, _): anchorDiffering.insert(offset)
                }
            }
            marked[name] = Marked(words: candidate, differing: own)
        }
        marked[anchorName] = Marked(words: anchor, differing: anchorDiffering)
        return marked
    }

    /// Byte-identical transcripts folded into one entry, first occurrence
    /// keeping its position.
    ///
    /// Grouping is on the EXACT text, not the normalised form: two candidates
    /// that differ only in punctuation still have to be told apart, because
    /// whichever one is adopted becomes the reference and its punctuation goes
    /// with it. Only transcripts that are the same string are the same choice.
    static func group(_ candidates: [(String, String)]) -> [(names: [String], text: String)] {
        var groups: [(names: [String], text: String)] = []
        for (name, text) in candidates {
            if let index = groups.firstIndex(where: { $0.text == text }) {
                groups[index].names.append(name)
            } else {
                groups.append((names: [name], text: text))
            }
        }
        return groups
    }

    private static func words(of text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// One attributed run rather than a stack of views, so the paragraph still
    /// wraps and stays selectable.
    static func render(_ marked: Marked, tint: Color) -> Text {
        guard !marked.words.isEmpty else { return Text("(nothing)").foregroundColor(.secondary) }
        var line = AttributedString()
        for index in marked.words.indices {
            let spacer = index == marked.words.count - 1 ? "" : " "
            var piece = AttributedString(marked.words[index] + spacer)
            if marked.differing.contains(index) {
                piece.foregroundColor = tint
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            line.append(piece)
        }
        return Text(line)
    }
}
