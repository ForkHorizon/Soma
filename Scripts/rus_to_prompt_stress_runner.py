from __future__ import annotations

import argparse
import json
import os
import time
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from rus_to_prompt_stress_models import ROOT, adversarial_prompts, load_prompt_cases_from_file, provider_for_stage_model, split_model_values
from rus_to_prompt_stress_results import apply_run_health, build_case_result_from_payloads, summarize
from rus_to_prompt_stress_providers import improve_with_codex, improve_with_gemini, translate_with_codex, translate_with_gemini

import soma_language_optimizer as optimizer  # noqa: E402


def main() -> int:
    parser = _parser()
    args = parser.parse_args()
    _configure_environment()
    cases = _selected_cases(args)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "prompts.json").write_text(json.dumps([asdict(case) for case in cases], ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.dry_run:
        print(f"Dry run wrote {len(cases)} prompt cases to {out_dir / 'prompts.json'}")
        return 0
    translator_models = split_model_values(args.translator_models, args.translator_model)
    analyzer_models = split_model_values(args.analyzer_models, args.analyzer_model)
    started_at = datetime.now(timezone.utc).isoformat()
    results = _run_matrix(cases, translator_models, analyzer_models, args, out_dir / "results.jsonl")
    summary = summarize(results, started_at, datetime.now(timezone.utc).isoformat())
    total_operations = len(cases) * len(translator_models) * len(analyzer_models)
    summary.update({"benchmark_mode": "matrix", "total_operations": total_operations, "translator_models": translator_models, "analyzer_models": analyzer_models})
    apply_run_health(summary, total_operations)
    (out_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default=str(ROOT / ".stress" / f"rus-to-prompt-{datetime.now().strftime('%Y%m%d-%H%M%S')}"))
    parser.add_argument("--cases-file")
    parser.add_argument("--translator-model", default=os.environ.get("SOMA_TRANSLATOR_MODEL") or "qwen3.5:9b")
    parser.add_argument("--analyzer-model", default=os.environ.get("SOMA_ANALYST_MODEL") or "qwen3-coder:30b-a3b-q4_K_M")
    parser.add_argument("--translator-models", nargs="+")
    parser.add_argument("--analyzer-models", nargs="+")
    parser.add_argument("--translator-provider", default=os.environ.get("SOMA_RUS_TO_PROMPT_TRANSLATOR_PROVIDER", "local"), choices=["local", "codex", "gemini"])
    parser.add_argument("--analyzer-provider", default=os.environ.get("SOMA_RUS_TO_PROMPT_ANALYZER_PROVIDER", "local"), choices=["local", "codex", "gemini"])
    parser.add_argument("--model-profile", default="gpt-5.5")
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--codex-bin", default=os.environ.get("SOMA_CODEX_BIN", "codex"))
    parser.add_argument("--gemini-bin", default=os.environ.get("SOMA_GEMINI_BIN", "/opt/homebrew/bin/gemini"))
    parser.add_argument("--codex-stage-timeout", type=float, default=180)
    parser.add_argument("--gemini-stage-timeout", type=float, default=240)
    parser.add_argument("--dry-run", action="store_true")
    return parser


def _selected_cases(args: argparse.Namespace):
    all_cases = load_prompt_cases_from_file(Path(args.cases_file)) if args.cases_file else adversarial_prompts()
    return all_cases[: max(0, min(args.limit, len(all_cases)))]


def _run_matrix(cases, translators, analyzers, args, results_path: Path):
    results = []
    with results_path.open("w", encoding="utf-8") as file:
        for case in cases:
            for translator in translators:
                for analyzer in analyzers:
                    result = _run_one(case, translator, analyzer, args)
                    results.append(result)
                    file.write(json.dumps(asdict(result), ensure_ascii=False) + "\n")
                    file.flush()
    return results


def _run_one(case, translator: str, analyzer: str, args):
    started = time.monotonic()
    translator_provider = provider_for_stage_model(translator, args.translator_provider)
    analyzer_provider = provider_for_stage_model(analyzer, args.analyzer_provider)
    translation, translation_seconds = _translate(case.prompt, translator, translator_provider, args)
    improve, improve_seconds = _improve(translation, analyzer, analyzer_provider, args)
    result = build_case_result_from_payloads(case, translator, analyzer, translator_provider, analyzer_provider, translation, improve, translation_seconds, improve_seconds)
    result.seconds = time.monotonic() - started
    return result


def _translate(prompt: str, model: str, provider: str, args):
    start = time.monotonic()
    if provider == "codex":
        payload = translate_with_codex(prompt, model, args.codex_stage_timeout, args.codex_bin, args.model_profile)
    elif provider == "gemini":
        payload = translate_with_gemini(prompt, model, args.gemini_stage_timeout, args.gemini_bin, args.model_profile)
    else:
        payload = optimizer.translate_general_prompt(prompt, model, args.model_profile)
    return payload, time.monotonic() - start


def _improve(translation: dict, model: str, provider: str, args):
    if translation.get("status") != "ok":
        return None, 0.0
    start = time.monotonic()
    text = str(translation.get("translation") or "")
    if provider == "codex":
        payload = improve_with_codex(text, model, args.codex_stage_timeout, args.codex_bin, args.model_profile)
    elif provider == "gemini":
        payload = improve_with_gemini(text, model, args.gemini_stage_timeout, args.gemini_bin, args.model_profile)
    else:
        payload = optimizer.improve_general_prompt(text, model, args.model_profile)
    return payload, time.monotonic() - start


def _configure_environment() -> None:
    os.environ.pop("SOMA_PROJECT_ROOT", None)
    os.environ.setdefault("SOMA_PROMPT_TRANSLATION_TIMEOUT", "90")
    os.environ.setdefault("SOMA_PROMPT_POLISH_TIMEOUT", "180")
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
