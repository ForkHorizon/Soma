from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from rus_to_prompt_stress_models import (
    DEFAULT_CONFIDENCE_REASONING_EFFORT,
    DEFAULT_HYBRID_DISAGREEMENT_THRESHOLD,
    DEFAULT_HYBRID_LOCAL_CONFIDENCE_THRESHOLD,
    ROOT,
    adversarial_prompts,
    benchmark_operation_count,
    load_prompt_cases_from_file,
    progress_event_line,
    split_model_values,
)
from rus_to_prompt_stress_results import apply_run_health, summarize
from rus_to_prompt_stress_runner_modes import run_cases
from rus_to_prompt_stress_runner_resume import load_resume_results
from rus_to_prompt_stress_runner_summary import summary_metadata


def main() -> int:
    parser = _parser()
    args = parser.parse_args()
    _configure_environment()
    cases = _selected_cases(args)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    _install_progress_log(out_dir)
    (out_dir / "prompts.json").write_text(json.dumps([asdict(case) for case in cases], ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.dry_run:
        print(f"Dry run wrote {len(cases)} prompt cases to {out_dir / 'prompts.json'}")
        return 0
    translators = split_model_values(args.translator_models, args.translator_model)
    analyzers = split_model_values(args.analyzer_models, args.analyzer_model)
    total_operations = benchmark_operation_count(args.benchmark_mode, len(cases), len(translators), len(analyzers))
    started_at = datetime.now(timezone.utc).isoformat()
    results_path = out_dir / "results.jsonl"
    existing_results = load_resume_results(results_path, args.benchmark_mode) if args.resume_existing else []
    print(progress_event_line(event="run_start", stage="queued", total_operations=total_operations, status="running"), flush=True)
    results = run_cases(cases, translators, analyzers, args, results_path, total_operations, existing_results=existing_results)
    summary = summarize(results, started_at, datetime.now(timezone.utc).isoformat())
    summary.update(summary_metadata(args, translators, analyzers, total_operations, results))
    apply_run_health(summary, total_operations)
    (out_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(progress_event_line(event="run_finished", stage="done", total_operations=total_operations, status=summary.get("run_status")), flush=True)
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    _add_stage_args(parser)
    _add_confidence_args(parser)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--stage-cooldown-seconds", type=float, default=0)
    parser.add_argument("--control-file")
    parser.add_argument("--resume-existing", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser


def _add_stage_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--benchmark-mode", default="matrix", choices=["matrix", "staged", "translation"])
    parser.add_argument("--out-dir", default=str(ROOT / ".stress" / f"rus-to-prompt-{datetime.now().strftime('%Y%m%d-%H%M%S')}"))
    parser.add_argument("--cases-file")
    parser.add_argument("--translator-model", default=os.environ.get("SOMA_TRANSLATOR_MODEL") or "qwen3.5:9b")
    parser.add_argument("--analyzer-model", default=os.environ.get("SOMA_ANALYST_MODEL") or "qwen3-coder:30b-a3b-q4_K_M")
    parser.add_argument("--translator-models", nargs="+")
    parser.add_argument("--analyzer-models", nargs="+")
    parser.add_argument("--translator-provider", default=os.environ.get("SOMA_RUS_TO_PROMPT_TRANSLATOR_PROVIDER", "local"), choices=["local", "codex", "gemini", "deepseek"])
    parser.add_argument("--analyzer-provider", default=os.environ.get("SOMA_RUS_TO_PROMPT_ANALYZER_PROVIDER", "local"), choices=["local", "codex", "gemini", "deepseek"])
    parser.add_argument("--model-profile", default="gpt-5.5")
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--codex-bin", default=os.environ.get("SOMA_CODEX_BIN", "codex"))
    parser.add_argument("--gemini-bin", default=os.environ.get("SOMA_GEMINI_BIN", "/opt/homebrew/bin/gemini"))
    parser.add_argument("--codex-stage-timeout", type=float, default=180)
    parser.add_argument("--gemini-stage-timeout", type=float, default=240)
    parser.add_argument("--deepseek-stage-timeout", type=float, default=float(os.environ.get("SOMA_DEEPSEEK_STAGE_TIMEOUT", "240")))
    parser.add_argument("--codex-stage-reasoning-effort", default=os.environ.get("SOMA_RUS_TO_PROMPT_CODEX_STAGE_REASONING_EFFORT", "medium"))


def _add_confidence_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--confidence-referee", default="off", choices=["off", "codex", "gemini", "deepseek", "local", "hybrid"])
    parser.add_argument("--confidence-model", default=os.environ.get("SOMA_RUS_TO_PROMPT_CONFIDENCE_MODEL", "gpt-5.4-mini"))
    parser.add_argument("--confidence-reasoning-effort", default=DEFAULT_CONFIDENCE_REASONING_EFFORT)
    parser.add_argument("--confidence-workers", type=int, default=1)
    parser.add_argument("--confidence-batch-size", type=int, default=1)
    parser.add_argument("--translation-confidence-threshold", type=float, default=0.75)
    parser.add_argument("--local-confidence-models", nargs="+")
    parser.add_argument("--hybrid-confidence-online-model", "--hybrid-confidence-gemini-model", dest="hybrid_confidence_online_model", default=os.environ.get("SOMA_RUS_TO_PROMPT_HYBRID_ONLINE_MODEL") or os.environ.get("SOMA_RUS_TO_PROMPT_HYBRID_GEMINI_MODEL", "gemini-3-flash-preview"))
    parser.add_argument("--hybrid-confidence-fallback-referee", default="gemini", choices=["gemini", "codex", "deepseek", "off"])
    parser.add_argument("--hybrid-confidence-local-threshold", type=float, default=DEFAULT_HYBRID_LOCAL_CONFIDENCE_THRESHOLD)
    parser.add_argument("--hybrid-confidence-disagreement-threshold", type=float, default=DEFAULT_HYBRID_DISAGREEMENT_THRESHOLD)


def _selected_cases(args: argparse.Namespace):
    all_cases = load_prompt_cases_from_file(Path(args.cases_file)) if args.cases_file else adversarial_prompts()
    return all_cases[: max(0, min(args.limit, len(all_cases)))]


def _configure_environment() -> None:
    os.environ.pop("SOMA_PROJECT_ROOT", None)
    os.environ.setdefault("SOMA_PROMPT_TRANSLATION_TIMEOUT", "90")
    os.environ.setdefault("SOMA_PROMPT_POLISH_TIMEOUT", "180")
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")


class _Tee:
    def __init__(self, *streams):
        self.streams = streams

    def write(self, data: str) -> int:
        for stream in self.streams:
            try:
                stream.write(data)
            except ValueError:
                pass
        return len(data)

    def flush(self) -> None:
        for stream in self.streams:
            try:
                stream.flush()
            except ValueError:
                pass


def _install_progress_log(out_dir: Path) -> None:
    log = (out_dir / "progress.log").open("a", encoding="utf-8", buffering=1)
    sys.stdout = _Tee(sys.stdout, log)
    sys.stderr = _Tee(sys.stderr, log)
