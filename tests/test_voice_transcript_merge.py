"""Pure transcript-stitching logic: chunk overlap joins and decoder-loop
detection. No server, no sockets — these run in microseconds."""

import unittest

from soma_test_bootstrap import install_soma_imports

install_soma_imports()

import voice_asr_engines
import voice_transcript_merge


class VoiceTranscriptMergeTests(unittest.TestCase):
    def test_forced_overlap_reports_unsafe_when_words_do_not_match(self):
        self.assertEqual(voice_transcript_merge.join_overlap("hello world", "world again"), ("hello world again", True))
        self.assertEqual(
            voice_transcript_merge.join_overlap("hello world", "different words"),
            ("hello world different words", False),
        )

    def test_an_unmatched_seam_duplicates_words_but_never_drops_them(self):
        """The client keeps the chunked transcript when a seam does not match
        instead of re-transcribing the whole recording, so a failed join must
        stay lossless. Measured: seams fail on 53% of forced boundaries, so this
        is the common path, not an edge case."""
        merged, matched = voice_transcript_merge.join_overlap("я думаю что надо", "сделать это сегодня")
        self.assertFalse(matched)
        for word in ("я", "думаю", "что", "надо", "сделать", "это", "сегодня"):
            self.assertIn(word, merged.split(), f"a failed join dropped {word!r}")

    def test_a_matched_seam_keeps_the_overlap_once(self):
        merged, matched = voice_transcript_merge.join_overlap("я думаю что надо", "что надо сделать это")
        self.assertTrue(matched)
        self.assertEqual(merged, "я думаю что надо сделать это")

    def test_repetition_guard_rejects_decoder_loops(self):
        self.assertFalse(voice_transcript_merge.has_pathological_repetition("yes yes yes yes"))
        self.assertTrue(voice_transcript_merge.has_pathological_repetition("already " * 12))
        self.assertTrue(voice_transcript_merge.has_pathological_repetition("come back here for a second " * 3))
        self.assertTrue(voice_transcript_merge.has_pathological_repetition("f sağ " * 6))
        self.assertTrue(voice_transcript_merge.has_pathological_repetition("... " * 8))

    def test_gigaam_join_removes_exact_overlap(self):
        self.assertEqual(
            voice_asr_engines.join_parts(["hello brave world", "brave world again", "again today"]),
            "hello brave world again today",
        )


if __name__ == "__main__":
    unittest.main()
