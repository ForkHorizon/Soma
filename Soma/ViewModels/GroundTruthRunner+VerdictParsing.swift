import Foundation

extension GroundTruthRunner {
    /// One verdicts.jsonl row back into the struct the queue reads. Robust by
    /// design: a malformed line (a crashed write, a hand edit) is dropped
    /// rather than taking the whole load down with it.
    static func verdict(fromLine line: Substring) -> GroundTruthVerdict? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = object["file"] as? String,
              let status = object["status"] as? String
        else { return nil }
        let pairs = (object["terms"] as? [[String]] ?? []).compactMap { pair -> TermPair? in
            pair.count == 2 ? TermPair(heard: pair[0], written: pair[1]) : nil
        }
        return GroundTruthVerdict(file: file, status: status,
                                  reason: object["reason"] as? String ?? "",
                                  edits: object["edits"] as? Int ?? 0,
                                  candidates: object["candidates"] as? [String: String] ?? [:],
                                  terms: pairs, spots: Self.spots(object["spot_seconds"]),
                                  operations: Self.operations(object["review_operations"]))
    }

    private static func spots(_ raw: Any?) -> [ClosedRange<Double>] {
        (raw as? [[Double]] ?? []).compactMap { pair in
            guard pair.count == 2, pair[1] > pair[0] else { return nil }
            return pair[0]...pair[1]
        }
    }
}
