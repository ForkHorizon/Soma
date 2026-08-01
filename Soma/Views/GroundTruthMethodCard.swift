import SwiftUI

/// Exactly what leaves this app and with which decode parameters. Written out
/// in full because a consensus number is meaningless without knowing which
/// engines produced it — and because these are the knobs the accuracy work
/// will actually be tuning.
struct GroundTruthMethodCard: View {
    let bestOf: Int
    @State private var expanded = true

    private var passes: [(String, String)] {
        [
            ("w-greedy · Whisper large-v3 (mlx)",
             "language=ru, temperature=0.0, condition_on_previous_text=false. Deterministic, and the strongest single decode this backend has — mlx_whisper raises NotImplementedError for beam search, so there is no beam to fall back on."),
            ("gigaam · GigaAM v2 RNNT (CPU)",
             "Russian-specialist model, 20 s windows with 1 s overlap. Shares no weights or training data with Whisper — it is the only genuinely independent vote here."),
            ("w-prompt · Whisper, primed",
             "Same as w-greedy plus initial_prompt listing the vocabulary actually dictated here (Swift, Xcode, Git, коммит, ветка…). Moves terminology and spelling, not acoustics."),
            ("w-fallback · Whisper, shipping defaults",
             "Every mlx default: the six-temperature fallback and cross-window conditioning. This is what the app uses today, kept as a voter so the shipping config is judged rather than trusted."),
            ("w-sample · Whisper, sampled",
             "temperature=0.4, best_of=\(bestOf) — \(bestOf) sampled decodes per window, ranked by average logprob. The only non-deterministic member, and the only place where paying for more compute per file buys anything: repeating a temperature-0 decode returns byte-identical text."),
        ]
    }

    var body: some View {
        DisclosureGroup("What gets run, and with which parameters", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                note("Audio never leaves this Mac. Each recording is read as mono 16 kHz float and handed to a local engine venv; the app itself sends nothing over the network.")
                ForEach(passes, id: \.0) { pass in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pass.0).font(.callout).bold()
                        Text(pass.1).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("How a verdict is reached").font(.callout).bold()
                note("Only w-greedy and GigaAM run on every file. The three remaining Whisper decodes are spent solely on recordings where those two disagree, which is what keeps a full corpus run to hours instead of days.")
                note("Accepted needs GigaAM to match at least two Whisper decodes (or to match w-greedy outright on the first pass). Four Whisper opinions agreeing with each other is not enough — they share one acoustic model, so their mistakes are correlated.")
                note("Comparison is case-insensitive, ignores punctuation and unifies ё/е. Latin terms GigaAM spells out phonetically (unity → юнити, assets → асец) are not counted as disagreements; two Cyrillic words that differ always are, and so are digits against spelled-out numbers.")
                note("Never auto-accepted: a token repeated six times or more, which is what a Whisper hallucination loop looks like even when every config produces it.")
                note("Recordings where GigaAM hears nothing and Whisper returns a short stock phrase are filed as no speech, not as a disagreement — that is Whisper hallucinating over silence.")
            }
            .padding(.top, 10)
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The files a human still has to settle, cheapest first.
struct GroundTruthReviewList: View {
    let items: [GroundTruthVerdict]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items.prefix(200)) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Text(item.edits > 0 ? "\(item.edits)w" : "—")
                            .font(.caption).monospaced().frame(width: 34, alignment: .trailing)
                            .foregroundStyle(item.edits <= 2 ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.file).font(.caption).monospaced()
                            Text(item.reason).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
                if items.count > 200 {
                    Text("…and \(items.count - 200) more").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                if items.isEmpty {
                    Text("Nothing to review yet.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Needs review (\(items.count)) — sorted by how many words actually differ")
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
