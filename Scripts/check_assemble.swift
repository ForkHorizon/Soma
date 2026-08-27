// swiftc -typecheck harness: GroundTruthGold.assemble correctness without Xcode.
// Mirrors SomaTests/GroundTruthDiffTests.swift conventions. Run:
//   xcrun swiftc -o /tmp/assemble_check Soma/ViewModels/GroundTruthGlossary.swift Scripts/check_assemble.swift -framework Foundation
import Foundation

// Test double for the filesystem anchor GroundTruthGlossary depends on; it
// redirects every read/write the file-progress types make into a temp dir so
// this harness can exercise the pure assemble() without touching real data.
enum GroundTruthRunner {
    static let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("assemble-check-\(Int.random(in: 1...1_000_000))", isDirectory: true)
}

// Minimal mirrors of the Soma types used by assemble (GroundTruthGlossary.swift
// declares the real ones; redeclaring here would clash, so this harness instead
// COMPILES the real file and calls GroundTruthGold.assemble directly).
// GroundTruthGold.settled()/write() hit the filesystem; assemble() is pure.

struct GroundTruthVerdict: Hashable {
    let file: String
    let status: String
    let reason: String
    let edits: Int
    let candidates: [String: String]
    let terms: [String]
    let spots: [ClosedRange<Double>]
    let operations: [GroundTruthReviewOperation]
}

func operation(_ id: String, _ anchor: Range<Int>, _ texts: [(names: [String], text: String)]) -> GroundTruthReviewOperation {
    GroundTruthReviewOperation(id: id, signature: id, anchor: anchor, seconds: nil,
                               contextBefore: "", contextAfter: "",
                               alternatives: texts.map { GroundTruthOperationAlternative(names: $0.names, text: $0.text) })
}

func verdict(ops: [GroundTruthReviewOperation], greedy: String) -> GroundTruthVerdict {
    GroundTruthVerdict(file: "t.wav", status: "review", reason: "", edits: 0,
                       candidates: ["w-greedy": greedy], terms: [], spots: [], operations: ops)
}

var failures = 0
func expect(_ got: String?, _ want: String?, _ note: String) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(note): got \(got ?? "nil"), want \(want ?? "nil")")
}

// 1. undecided multi-alternative operation -> nil (no partial gold).
// A single-alternative op is intentionally NOT a blocker: it carries the
// majority correction and applies unattended (checked in test 2).
expect(GroundTruthGold.assemble(verdict(ops: [operation("a", 1..<2, [(["w-greedy"], "два"), (["gigaam"], "дом")])], greedy: "раз два три"),
                                choices: [:]), nil, "undecided choice blocks")

// 2. single-alternative ops apply without a recorded choice
let v2 = verdict(ops: [operation("a", 1..<2, [(["gigaam", "gigaam-ctc"], "два-два")])], greedy: "раз два три")
expect(GroundTruthGold.assemble(v2, choices: [:]), "раз два-два три", "majority correction auto-applies")

// 3. recorded choice overrides
let v3 = verdict(ops: [operation("a", 1..<2, [(["w-greedy"], "два"), (["gigaam"], "два-два")])], greedy: "раз два три")
let c3 = ["a": GroundTruthOperationChoice(signature: "a", text: "два-два", source: "manual")]
expect(GroundTruthGold.assemble(v3, choices: c3), "раз два-два три", "recorded choice wins")

// 4. multiple ops apply right-to-left without index shift
let v4 = verdict(ops: [operation("a", 1..<2, [(["gigaam"], "X")]),
                       operation("b", 3..<4, [(["gigaam"], "Y")])], greedy: "a b c d e")
expect(GroundTruthGold.assemble(v4, choices: [:]), "a X c Y e", "two ops, anchors hold")

// 5. insertion (zero-width anchor) inserts
let v5 = verdict(ops: [operation("a", 2..<2, [(["gigaam"], "новое")])], greedy: "a b c d")
expect(GroundTruthGold.assemble(v5, choices: [:]), "a b новое c d", "insertion")

// 6. deletion: empty text over a non-empty span
let v6 = verdict(ops: [operation("a", 1..<3, [(["gigaam"], "")])], greedy: "a b c d")
expect(GroundTruthGold.assemble(v6, choices: [:]), "a d", "deletion")

// 7. anchor past the end after a re-vote -> nil, never truncated gold
let v7 = verdict(ops: [operation("a", 9..<10, [(["gigaam"], "X")])], greedy: "a b c")
expect(GroundTruthGold.assemble(v7, choices: [:]), nil, "out-of-range anchor fails closed")

// 8. both single-alt and multi-alt ops in one file
let v8 = verdict(ops: [operation("a", 0..<1, [(["gigaam", "gigaam-ctc"], "Первый")]),
                       operation("b", 2..<3, [(["w-greedy"], "три"), (["gigaam"], "тэри")])],
                 greedy: "первый два три")
expect(GroundTruthGold.assemble(v8, choices: ["b": GroundTruthOperationChoice(signature: "b", text: "тэри", source: "manual")]),
       "Первый два тэри", "mixed ops")

// Queue filtering (the frozen-counter bug): decisions and gold on disk must
// shrink the queue before the sheet even opens.
// 9. a file already in gold.jsonl never comes back
let q9 = GroundTruthVerdict(file: "done.wav", status: "review", reason: "", edits: 0,
                            candidates: ["w-greedy": "a"], terms: [], spots: [],
                            operations: [operation("only", 0..<1, [(["x"], "p"), (["y"], "q")])])
expect(String(GroundTruthRunner.operationQueue([q9], settled: ["done.wav"]).count), "0",
       "settled file leaves the queue")

// 10. a recorded decision with a matching signature is done; a stale one returns
let q10 = GroundTruthVerdict(file: "half.wav", status: "review", reason: "", edits: 0,
                             candidates: ["w-greedy": "a"], terms: [], spots: [],
                             operations: [operation("kept", 0..<1, [(["x"], "p"), (["y"], "q")]),
                                          operation("revoted", 1..<2, [(["x"], "r"), (["y"], "s")])])
let queue10 = GroundTruthRunner.operationQueue([q10], decided: ["half.wav": ["kept": "kept", "revoted": "old-signature"]])
expect(queue10.map(\.operation.id).joined(separator: ","), "revoted",
       "decided op drops, stale signature re-asks")

// 11. every op decided but gold never written (app closed at the final
// editor) -> the file keeps exactly one item, which reopens that edit
let q11 = q10
let queue11 = GroundTruthRunner.operationQueue([q11], decided: ["half.wav": ["kept": "kept", "revoted": "revoted"]])
expect(String(queue11.count), "1", "fully decided, uncommitted file keeps its final edit")

// 12. a single-alternative-only file never had a human question and leaves
let q12 = GroundTruthVerdict(file: "auto.wav", status: "review", reason: "", edits: 0,
                             candidates: ["w-greedy": "a"], terms: [], spots: [],
                             operations: [operation("maj", 0..<1, [(["x", "y"], "p")])])
expect(String(GroundTruthRunner.operationQueue([q12]).count), "0",
       "majority-only file never enters the queue")

print(failures == 0 ? "ALL OK" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
