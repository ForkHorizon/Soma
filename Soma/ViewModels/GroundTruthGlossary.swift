import Foundation

struct GroundTruthOperationAlternative: Hashable, Identifiable {
    let names: [String]
    let text: String
    var id: String { names.joined(separator: "+") + ":" + text }
}

struct GroundTruthReviewOperation: Hashable, Identifiable {
    let id: String
    let signature: String
    let anchor: Range<Int>
    let seconds: ClosedRange<Double>?
    let contextBefore: String
    let contextAfter: String
    let alternatives: [GroundTruthOperationAlternative]
}

struct GroundTruthReviewItem: Identifiable, Hashable {
    let verdict: GroundTruthVerdict
    let operation: GroundTruthReviewOperation
    let index: Int
    let total: Int
    var id: String { "\(verdict.file)#\(operation.id)#\(operation.signature)" }
}

struct GroundTruthOperationChoice: Hashable {
    let signature: String
    let text: String
    let source: String
}

/// Crash-safe, append-only decisions for individual operations. A newer row
/// with the same file/operation supersedes the older one on load.
enum GroundTruthReviewProgress {
    static var url: URL {
        GroundTruthRunner.outputDirectory.appendingPathComponent("review_progress.jsonl")
    }

    static func choices(for verdict: GroundTruthVerdict) -> [String: GroundTruthOperationChoice] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let signatures = Dictionary(uniqueKeysWithValues: verdict.operations.map { ($0.id, $0.signature) })
        return text.split(separator: "\n").reduce(into: [:]) { choices, line in
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  row["file"] as? String == verdict.file,
                  let id = row["operation"] as? String,
                  let signature = row["signature"] as? String,
                  signatures[id] == signature,
                  let choice = row["text"] as? String,
                  let source = row["source"] as? String
            else { return }
            choices[id] = GroundTruthOperationChoice(signature: signature, text: choice, source: source)
        }
    }

    /// Every decision on disk as file → operation id → signature, so the queue
    /// can subtract work already done with one read instead of one per verdict.
    /// Later rows supersede earlier ones, matching choices(for:).
    static func signaturesByFile() -> [String: [String: String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return text.split(separator: "\n").reduce(into: [:]) { result, line in
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let file = row["file"] as? String,
                  let id = row["operation"] as? String,
                  let signature = row["signature"] as? String
            else { return }
            result[file, default: [:]][id] = signature
        }
    }

    static func record(file: String, operation: GroundTruthReviewOperation, text: String, source: String) {
        let row: [String: Any] = ["file": file, "operation": operation.id,
                                  "signature": operation.signature, "text": text, "source": source]
        append(row, to: url)
    }

    private static func append(_ row: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"
        try? FileManager.default.createDirectory(at: GroundTruthRunner.outputDirectory,
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// Term pairs the listener has confirmed against the audio, plus the reference
/// transcripts they have settled by hand.
///
/// Nothing here is inferred. GigaAM writing "юнити" where Whisper wrote "unity"
/// only *looks* like the same word — the consensus never forgives it until this
/// file says it may, because a rule based on script alone would hide exactly the
/// technical terms the corpus is full of.
enum GroundTruthGlossary {
    static var url: URL {
        GroundTruthRunner.outputDirectory.appendingPathComponent("glossary.json")
    }

    /// Casefold, unify ё/е, drop punctuation (keeping a run of `+`/`#`/`*`
    /// when it's glued to a letter/digit on at least one side), collapse
    /// whitespace. The single Swift port of Scripts/ground_truth_text.py's
    /// `normalize` (issue #0070/#61 fixed the Python side; #0083 is this
    /// port, so "C++"/"C#"/"C" stay distinct here too — every prior in-place
    /// copy here or in GroundTruthDiff.key stripped +/#/* unconditionally
    /// and silently hid disagreements on exactly those terms).
    static func normalize(_ text: String) -> String {
        let folded = Array(text.precomposedStringWithCanonicalMapping.lowercased()
                                .replacingOccurrences(of: "ё", with: "е"))
        var kept: [Character] = []
        var index = 0
        while index < folded.count {
            let character = folded[index]
            if character.isLetter || character.isNumber || character.isWhitespace {
                kept.append(character)
                index += 1
                continue
            }
            guard "+#*".contains(character) else {
                kept.append(" ")
                index += 1
                continue
            }
            var end = index
            while end < folded.count, "+#*".contains(folded[end]) { end += 1 }
            let gluedLeft = index > 0 && (folded[index - 1].isLetter || folded[index - 1].isNumber)
            let gluedRight = end < folded.count && (folded[end].isLetter || folded[end].isNumber)
            if gluedLeft || gluedRight {
                kept.append(contentsOf: folded[index..<end])
            } else {
                kept.append(" ")
            }
            index = end
        }
        return String(kept).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Maps what GigaAM heard to the spellings accepted for it.
    static func load() -> [String: [String]] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { return [:] }
        return object
    }

    static func contains(heard: String, written: String) -> Bool {
        load()[heard]?.contains(written) ?? false
    }

    static func confirm(heard: String, written: String) {
        var glossary = load()
        var spellings = glossary[heard] ?? []
        guard !spellings.contains(written) else { return }
        spellings.append(written)
        glossary[heard] = spellings
        save(glossary)
    }

    static func forget(heard: String, written: String) {
        var glossary = load()
        guard var spellings = glossary[heard] else { return }
        spellings.removeAll { $0 == written }
        glossary[heard] = spellings.isEmpty ? nil : spellings
        save(glossary)
    }

    private static func save(_ glossary: [String: [String]]) {
        try? FileManager.default.createDirectory(at: GroundTruthRunner.outputDirectory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: glossary,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Reference transcripts settled by hand, appended one JSON object per line so a
/// crash mid-session cannot take the earlier decisions with it.
enum GroundTruthGold {
    static var url: URL {
        GroundTruthRunner.outputDirectory.appendingPathComponent("gold.jsonl")
    }

    static func settled() -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["file"] as? String
        })
    }

    static func write(file: String, text: String, source: String) {
        let row: [String: Any] = ["file": file, "text": text, "source": source]
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"
        try? FileManager.default.createDirectory(at: GroundTruthRunner.outputDirectory,
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// An operation left with a single reading was decided by the majority of
    /// decodes and is never shown, so it settles itself.
    static func choice(for operation: GroundTruthReviewOperation,
                       among choices: [String: GroundTruthOperationChoice]) -> GroundTruthOperationChoice? {
        if let recorded = choices[operation.id], recorded.signature == operation.signature { return recorded }
        guard operation.alternatives.count == 1, let only = operation.alternatives.first else { return nil }
        return GroundTruthOperationChoice(signature: operation.signature, text: only.text,
                                          source: only.names.joined(separator: "+"))
    }

    static func settle(_ verdict: GroundTruthVerdict,
                       choices: [String: GroundTruthOperationChoice]) -> Bool {
        guard !settled().contains(verdict.file),
              let text = assemble(verdict, choices: choices)
        else { return false }
        write(file: verdict.file, text: text, source: "operation-review")
        return true
    }

    /// The reference a file's operations add up to, or nil while any operation
    /// is still undecided or an anchor no longer fits the transcript it was
    /// computed against (a re-vote can shift both).
    ///
    /// Exposed because the final review step shows this text for one last
    /// human edit before it becomes gold — the reviewer can fix words no
    /// engine disputed, which the choice-by-choice flow can never surface.
    static func assemble(_ verdict: GroundTruthVerdict,
                         choices: [String: GroundTruthOperationChoice]) -> String? {
        guard var words = verdict.candidates["w-greedy"]?.split(separator: " ").map(String.init)
        else { return nil }
        for operation in verdict.operations.sorted(by: { $0.anchor.lowerBound > $1.anchor.lowerBound }) {
            guard let choice = choice(for: operation, among: choices),
                  operation.anchor.lowerBound >= 0, operation.anchor.upperBound <= words.count
            else { return nil }
            words.replaceSubrange(operation.anchor, with: choice.text.split(separator: " ").map(String.init))
        }
        return words.joined(separator: " ")
    }
}
