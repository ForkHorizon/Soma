import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class RusToPromptQueueRunnerCLITests(unittest.TestCase):
    def test_stress_script_accepts_queue_staged_flags(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            cases = temp_path / "case.txt"
            control = temp_path / "control.json"
            out_dir = temp_path / "out"
            cases.write_text("### rpq-unit\nСделай Project Info компактнее.\n", encoding="utf-8")
            control.write_text(json.dumps({"pause": False, "skip_cooldown": False, "stop": False}), encoding="utf-8")

            completed = subprocess.run(
                _queue_dry_run_args(cases, control, out_dir),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=30,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue((out_dir / "prompts.json").exists())
            self.assertTrue((out_dir / "progress.log").exists())
            self.assertIn("Dry run wrote", (out_dir / "progress.log").read_text(encoding="utf-8"))


def _queue_dry_run_args(cases: Path, control: Path, out_dir: Path) -> list[str]:
    return [
        sys.executable,
        str(ROOT / "Scripts" / "rus_to_prompt_stress.py"),
        "--benchmark-mode",
        "staged",
        "--cases-file",
        str(cases),
        "--limit",
        "1",
        "--translator-models",
        "qwen3.5:9b",
        "--analyzer-models",
        "qwen3.5:9b",
        "--confidence-referee",
        "hybrid",
        "--confidence-model",
        "gemini-3.1-flash-lite-preview",
        "--confidence-reasoning-effort",
        "medium",
        "--confidence-workers",
        "1",
        "--confidence-batch-size",
        "1",
        "--translation-confidence-threshold",
        "0.75",
        "--codex-stage-reasoning-effort",
        "medium",
        "--workers",
        "1",
        "--stage-cooldown-seconds",
        "0",
        "--control-file",
        str(control),
        "--resume-existing",
        "--local-confidence-models",
        "qwen3-coder:30b-a3b-q4_K_M",
        "qwen3:30b-a3b",
        "--hybrid-confidence-gemini-model",
        "gemini-3.1-flash-lite-preview",
        "--hybrid-confidence-fallback-referee",
        "gemini",
        "--hybrid-confidence-local-threshold",
        "0.80",
        "--hybrid-confidence-disagreement-threshold",
        "0.15",
        "--out-dir",
        str(out_dir),
        "--dry-run",
    ]


if __name__ == "__main__":
    unittest.main()
