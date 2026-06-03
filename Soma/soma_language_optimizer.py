#!/usr/bin/env python3
"""Prompt language optimization facade."""
from __future__ import annotations

import subprocess
import sys as _sys

_sys.dont_write_bytecode = True

from soma_language_optimizer_cli import main
from soma_language_optimizer_codex import (
    _codex_improve_schema,
    _codex_translate_schema,
    _improve_general_prompt_codex,
    _run_codex_json,
    _translate_general_prompt_codex,
)
from soma_language_optimizer_confidence import (
    _confidence_prompt,
    _confidence_schema,
    score_general_prompt_confidence,
)
from soma_language_optimizer_core import (
    CODEX_STAGE_MODELS,
    DEFAULT_CODEX_STAGE_REASONING_EFFORT,
    PLACEHOLDER_PREFIX,
    TARGET_LANGUAGE,
    ProtectedPrompt,
    _clip_text,
    _compute_metadata,
    _cyrillic_count,
    _extract_json_object,
    _improved_prompt_sanity_error,
    _looks_like_codex_payload_echo,
    _placeholder,
    _restore_valid_improved_prompt,
    _schema_string_list,
    _sha,
    _span_patterns,
    _string_list,
    detect_language,
    estimate_tokens,
    is_codex_stage_model,
    log_fields,
    invalid_placeholders,
    protect_spans,
    restore_spans,
)
from soma_language_optimizer_flow import (
    _improver_model,
    _translator_model,
    improve_general_prompt,
    optimize_general_prompt,
    optimize_prompt_language,
    translate_general_prompt,
)
from soma_language_optimizer_local import (
    _free_cloud_translate,
    _local_ollama_improve_prompt,
    _local_ollama_repair_prompt,
    _local_ollama_translate,
    _log_local_prompt_call,
    _log_local_translation_call,
)

__all__ = [name for name in globals() if not name.startswith("__")]


if __name__ == "__main__":
    _sys.modules.setdefault("soma_language_optimizer", _sys.modules[__name__])
    raise SystemExit(main())
