import Foundation

extension GroundTruthRunner {
    /// Files ordered so that finishing one is realistic — a file only becomes a
    /// gold row once every one of its operations is settled, so an hour spent
    /// inside a 49-operation recording produces nothing at all.
    ///
    /// Cheapest-first alone would fill the corpus with short easy audio, the
    /// same bias that makes the auto-accepted files unusable on their own (187
    /// of them, 13 words each). So the cheap and the expensive halves are
    /// interleaved: every second file you finish is a hard one, and stopping
    /// early still leaves a corpus that spans both.
    /// `settled` — files already in gold.jsonl — and `decided` — operation ids
    /// with a recorded decision whose signature still matches — are work that
    /// no longer needs a human. Without them the queue count never drops no
    /// matter how many sessions land on disk.
    nonisolated static func operationQueue(
        _ verdicts: [GroundTruthVerdict],
        settled: Set<String> = [],
        decided: [String: [String: String]] = [:]
    ) -> [GroundTruthReviewItem] {
        var pending: [(verdict: GroundTruthVerdict, operations: [GroundTruthReviewOperation])] = []
        for verdict in verdicts where !settled.contains(verdict.file) {
            let shown = needsAHuman(for: verdict, decided: decided[verdict.file] ?? [:])
            guard !shown.isEmpty || hasUnsettledMultiChoice(verdict) else { continue }
            // A file whose every question is answered but whose gold row never
            // landed (the app closed at the final editor) keeps one item, so
            // the session reopens it at that final edit instead of dropping
            // the file — and its on-disk decisions — silently.
            let operations = shown.isEmpty ? [needsAHuman(for: verdict).first ?? fallbackOperation(for: verdict)] : shown
            pending.append((verdict, operations))
        }
        pending.sort {
            $0.operations.count == $1.operations.count
                ? captureTime($0.verdict.file) > captureTime($1.verdict.file) : $0.operations.count < $1.operations.count
        }
        let cheap = Array(pending.prefix(pending.count / 2))
        let hard = Array(pending.dropFirst(pending.count / 2))
        return (cheap.indices.flatMap { [cheap[$0], hard[$0]] } + hard.dropFirst(cheap.count))
            .flatMap { verdict, operations in
                operations.enumerated().map {
                    GroundTruthReviewItem(verdict: verdict, operation: $0.element, index: $0.offset + 1, total: operations.count)
                }
            }
    }

    /// True when the file has real multi-alternative operations (not the
    /// whole-recording fallback) that are not yet backed by a gold row.
    nonisolated static func hasUnsettledMultiChoice(_ verdict: GroundTruthVerdict) -> Bool {
        verdict.operations.contains { $0.alternatives.count > 1 }
    }

    /// A single-alternative operation carries the majority correction and has
    /// nothing to choose between, so it is applied without being shown. A
    /// recorded decision whose signature still matches is likewise done; a
    /// stale signature (a re-vote changed the question) comes back.
    nonisolated static func needsAHuman(
        for verdict: GroundTruthVerdict,
        decided: [String: String] = [:]
    ) -> [GroundTruthReviewOperation] {
        let operations = verdict.operations.isEmpty ? [fallbackOperation(for: verdict)] : verdict.operations
        return operations.filter { $0.alternatives.count > 1 && decided[$0.id] != $0.signature }
            .sorted { ($0.seconds?.lowerBound ?? -.infinity) < ($1.seconds?.lowerBound ?? -.infinity) }
    }

    nonisolated static func captureTime(_ file: String) -> Int64 {
        Int64(String(file.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber }))) ?? .min
    }
    nonisolated static func fallbackOperation(for verdict: GroundTruthVerdict) -> GroundTruthReviewOperation {
        GroundTruthReviewOperation(
            id: "whole-recording", signature: "whole-recording",
            anchor: 0..<(verdict.candidates["w-greedy"]?.split(separator: " ").count ?? 0), seconds: nil, contextBefore: "",
            contextAfter: "",
            alternatives: Dictionary(grouping: verdict.candidates, by: { $0.value }).map {
                GroundTruthOperationAlternative(names: $0.value.map(\.key).sorted(), text: $0.key)
            })
    }

    static func operations(_ raw: Any?) -> [GroundTruthReviewOperation] {
        (raw as? [[String: Any]] ?? []).compactMap { row -> GroundTruthReviewOperation? in
            guard let id = row["id"] as? String, let signature = row["signature"] as? String, let anchor = row["anchor"] as? [Int],
                anchor.count == 2
            else { return nil }
            let alternatives = (row["alternatives"] as? [[String: Any]] ?? []).compactMap { option -> GroundTruthOperationAlternative? in
                guard let names = option["names"] as? [String], let text = option["text"] as? String else { return nil }
                return GroundTruthOperationAlternative(names: names, text: text)
            }
            let seconds = (row["seconds"] as? [Double]).flatMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]...$0[1] : nil }
            let context = row["context"] as? [String] ?? []
            return GroundTruthReviewOperation(
                id: id, signature: signature, anchor: anchor[0]..<anchor[1], seconds: seconds, contextBefore: context.first ?? "",
                contextAfter: context.count > 1 ? context[1] : "", alternatives: alternatives)
        }
    }
}
