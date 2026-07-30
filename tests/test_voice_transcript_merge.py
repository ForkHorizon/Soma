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
        self.assertEqual(voice_transcript_merge.join_overlap("hello world", "different words"), ("hello world different words", False))

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
