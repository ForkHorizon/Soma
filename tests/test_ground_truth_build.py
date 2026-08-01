"""Guards that protect an unattended overnight run.

A verdict is final — nothing reruns a file that already has one — so the rules
about WHEN one may be written are the difference between a night that resumes
and a corpus that is silently incomplete.
"""
import sys
import types
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))

from ground_truth_build import Runner   # noqa: E402
from ground_truth_corpus import has_audio   # noqa: E402


def _runner(tmp: Path) -> Runner:
    args = types.SimpleNamespace(out=tmp, engines_root=tmp, models_root=tmp, best_of=5)
    return Runner(args)


def _wav(path: Path, frames: int) -> Path:
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16000)
        handle.writeframes(b"\x00\x00" * frames)
    return path


def test_a_file_no_engine_reached_is_left_pending(tmp_path=None):
    tmp = tmp_path or Path(__import__("tempfile").mkdtemp())
    runner = _runner(tmp)
    # An engine that failed to LOAD produces no rows at all. Settling that file
    # would write an error verdict and bury it: reruns skip anything decided.
    assert not runner.can_settle("rec-1.wav")


def test_an_engine_that_ran_and_failed_may_still_settle(tmp_path=None):
    tmp = tmp_path or Path(__import__("tempfile").mkdtemp())
    runner = _runner(tmp)
    runner.decoded[("rec-1.wav", "w-greedy")] = {"text": "", "error": None}
    runner.decoded[("rec-1.wav", "gigaam")] = {"text": None, "error": "ValueError: ..."}
    # This is a real per-file failure, not a missing turn — it is allowed to
    # become an error verdict.
    assert runner.can_settle("rec-1.wav")


def test_the_ctc_head_alone_is_enough_to_settle(tmp_path=None):
    tmp = tmp_path or Path(__import__("tempfile").mkdtemp())
    runner = _runner(tmp)
    runner.decoded[("rec-1.wav", "w-greedy")] = {"text": "привет"}
    runner.decoded[("rec-1.wav", "gigaam-ctc")] = {"text": "привет"}
    assert runner.can_settle("rec-1.wav")


def test_whisper_alone_is_not_enough_to_settle(tmp_path=None):
    tmp = tmp_path or Path(__import__("tempfile").mkdtemp())
    runner = _runner(tmp)
    runner.decoded[("rec-1.wav", "w-greedy")] = {"text": "привет"}
    assert not runner.can_settle("rec-1.wav")


def test_zero_frame_containers_are_screened_out(tmp_path=None):
    tmp = tmp_path or Path(__import__("tempfile").mkdtemp())
    # 35 of these exist in the live corpus: aborted recordings, 4096 bytes,
    # no frames. Every engine raises on them.
    assert not has_audio(_wav(tmp / "empty.wav", 0))
    assert has_audio(_wav(tmp / "real.wav", 16000))


def test_an_unreadable_header_is_left_to_the_engines(tmp_path=None):
    tmp = tmp_path or Path(__import__("tempfile").mkdtemp())
    broken = tmp / "broken.wav"
    broken.write_bytes(b"not a wav at all")
    # Screening is only meant to catch the known empty-container case; anything
    # else should reach an engine so its error is reported rather than guessed.
    assert has_audio(broken)
