from __future__ import annotations

import argparse
import json
import os
from typing import Any


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    if args.rus_to_prompt:
        _emit(_api().optimize_general_prompt(args.prompt, args.model_profile))
        return 0
    if args.rus_to_prompt_translate:
        _emit(_api().translate_general_prompt(args.prompt, args.translator_model, args.model_profile))
        return 0
    if args.rus_to_prompt_improve:
        _emit(_api().improve_general_prompt(args.prompt, args.improver_model, args.model_profile))
        return 0
    if args.rus_to_prompt_confidence:
        _emit(_confidence_payload(args))
        return 0
    raise SystemExit("choose --rus-to-prompt, --rus-to-prompt-translate, --rus-to-prompt-improve, or --rus-to-prompt-confidence")


def _parse_args(argv):
    parser = argparse.ArgumentParser(description="Soma prompt language utilities")
    parser.add_argument("prompt", nargs="?", default="")
    parser.add_argument("--rus-to-prompt", action="store_true", help="Translate and polish a general prompt without project context.")
    parser.add_argument("--rus-to-prompt-translate", action="store_true", help="Translate a general prompt without project context.")
    parser.add_argument("--rus-to-prompt-improve", action="store_true", help="Improve an English prompt without project context.")
    parser.add_argument("--rus-to-prompt-confidence", action="store_true", help="Score final prompt quality with Codex CLI without project context.")
    parser.add_argument("--translator-model", default=None)
    parser.add_argument("--improver-model", default=None)
    parser.add_argument("--confidence-model", default="gpt-5.4-mini")
    parser.add_argument("--confidence-reasoning-effort", default=os.environ.get("SOMA_RUS_TO_PROMPT_CONFIDENCE_REASONING_EFFORT", "medium"), choices=["none", "minimal", "low", "medium", "high", "xhigh"])
    parser.add_argument("--translation", default="")
    parser.add_argument("--improved-prompt", default="")
    parser.add_argument("--pipeline-status", default="ok")
    parser.add_argument("--warning", action="append", default=[])
    parser.add_argument("--model-profile", default="gpt-5.5")
    return parser.parse_args(argv)


def _confidence_payload(args):
    return _api().score_general_prompt_confidence(source_prompt=args.prompt, translation=args.translation, improved_prompt=args.improved_prompt, pipeline_status=args.pipeline_status, pipeline_warnings=args.warning, confidence_model=args.confidence_model, reasoning_effort=args.confidence_reasoning_effort)


def _api():
    import sys
    return sys.modules.get("soma_language_optimizer") or sys.modules[__name__]


def _emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False))
