import SwiftUI

/// Exactly what leaves this app and with which decode parameters. Written out
/// in full because a consensus number is meaningless without knowing which
/// engines produced it — and because these are the knobs the accuracy work
/// will actually be tuning.
struct GroundTruthMethodCard: View {
    let bestOf: Int
    // Collapsed by default: it is reference material, read once. The review
    // queue below it is the part touched every session.
    @State private var expanded = false

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
                note("Comparison is case-insensitive, ignores punctuation and unifies ё/е. Nothing else is forgiven automatically — not digits against spelled-out numbers, and not GigaAM's phonetic spelling of English terms (unity → юнити). Latin against Cyrillic looks the same whether the engines heard the same word or two different ones, so those pairs are proposed in the review queue and only stop counting as disagreements once you have heard the recording and confirmed them.")
                note("Never auto-accepted: a token repeated six times or more, which is what a Whisper hallucination loop looks like even when every config produces it.")
                note("A recording is filed as no speech only on evidence: Whisper's own no_speech_prob above 0.5 — measured at 0.85 on a hallucinated \"Спасибо\" against 0.02 on real speech — together with GigaAM independently hearing nothing. Audible audio that Whisper is merely unsure about goes to a human instead.")
                note("Confirming a term costs no model time to apply: every decode stays on disk, so Apply glossary just re-votes the cached results and the queue shrinks in seconds.")
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
