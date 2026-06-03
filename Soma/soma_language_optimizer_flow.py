from __future__ import annotations

import os
import sys
from typing import Any

from token_calculator import estimate_tokens
from soma_language_optimizer_core import TARGET_LANGUAGE, _compute_metadata, _cyrillic_count, _restore_valid_improved_prompt, _sha, detect_language, is_codex_stage_model, invalid_placeholders, protect_spans, restore_spans


def _api():
    return sys.modules.get("soma_language_optimizer") or sys.modules[__name__]


def optimize_prompt_language(goal: str, model_profile: str = "gpt-5.5") -> tuple[str, dict[str, Any]]:
    source_language = detect_language(goal)
    if os.environ.get("SOMA_TRANSLATION_ENABLED", "1").lower() in {"0", "false", "no"}:
        return goal, _metadata(goal, goal, source_language, "disabled", None, 0, model_profile=model_profile)
    if source_language == "en":
        return goal, _metadata(goal, goal, source_language, "original_english", None, 0, model_profile=model_profile)
    protected = protect_spans(goal)
    provider = os.environ.get("SOMA_TRANSLATION_PROVIDER", "local").lower().strip()
    timeout = float(os.environ.get("SOMA_TRANSLATION_TIMEOUT", "8") or 8)
    translator_model = _translator_model()
    try:
        translated_protected, engine = _translate_protected(protected.text, provider, translator_model, timeout)
        normalized = _restore_translation(goal, protected, translated_protected)
        return normalized, _metadata(goal, normalized, source_language, "translated", engine, len(protected.spans), model_profile=model_profile)
    except Exception as exc:
        engine = f"{provider}:{translator_model}" if provider == "local" else provider
        return goal, _metadata(goal, goal, source_language, "failed_fallback", engine, len(protected.spans), warning=str(exc), model_profile=model_profile)


def _metadata(original, normalized, source_language, status, engine, protected_count, warning=None, model_profile="gpt-5.5"):
    return _compute_metadata(original=original, normalized=normalized, source_language=source_language, status=status, engine=engine, protected_count=protected_count, warning=warning, model_profile=model_profile)


def _translate_protected(text, provider, translator_model, timeout):
    if provider == "local":
        return _api()._local_ollama_translate(text, translator_model, timeout), f"local:{translator_model}"
    if provider == "free_cloud":
        return _api()._free_cloud_translate(text, timeout), "free_cloud"
    raise RuntimeError(f"unsupported translation provider: {provider}")


def _restore_translation(original, protected, translated_protected):
    normalized = restore_spans(translated_protected, protected.spans).strip()
    if not normalized or _cyrillic_count(normalized) >= max(2, _cyrillic_count(original) // 2):
        raise RuntimeError("translation did not sufficiently normalize Cyrillic text")
    return normalized


def _translator_model() -> str:
    return os.environ.get("SOMA_TRANSLATOR_MODEL") or os.environ.get("SOMA_RANKER_MODEL") or os.environ.get("SOMA_LOCAL_MODEL") or "gemma4:e4b"


def translate_general_prompt(prompt: str, model: str | None = None, model_profile: str = "gpt-5.5") -> dict[str, Any]:
    original = (prompt or "").strip()
    source_language = detect_language(original)
    translator_model = model or _translator_model()
    result, warnings = _translation_result(original, source_language, translator_model)
    if not original:
        warnings.append("Prompt is empty.")
        return result
    if source_language == "en":
        result.update({"status": "ok", "translation_status": "original_english", "translation_engine": None, "translation": original, "translation_tokens": estimate_tokens(original, model_profile)})
        return result
    if is_codex_stage_model(translator_model):
        return _api()._translate_general_prompt_codex(original, source_language, translator_model, model_profile, _translation_timeout())
    return _translate_general_local(original, translator_model, model_profile, result, warnings)


def _translation_result(original, source_language, translator_model):
    warnings: list[str] = []
    return {"status": "failed", "source_language": source_language, "target_language": TARGET_LANGUAGE, "translation_status": None, "translation_engine": None, "translation": "", "translator_model": translator_model, "warnings": warnings, "protected_spans_count": 0, "original_prompt_hash": _sha(original)}, warnings


def _translation_timeout():
    return float(os.environ.get("SOMA_PROMPT_TRANSLATION_TIMEOUT", os.environ.get("SOMA_TRANSLATION_TIMEOUT", "45")) or 45)


def _translate_general_local(original, translator_model, model_profile, result, warnings):
    protected = protect_spans(original)
    try:
        translated_protected = _api()._local_ollama_translate(protected.text, translator_model, _translation_timeout())
        invalid = invalid_placeholders(translated_protected, len(protected.spans))
        if invalid:
            raise RuntimeError("translation corrupted protected placeholders: " + ", ".join(invalid[:5]))
        translation = _restore_translation(original, protected, translated_protected)
        result.update({"status": "ok", "translation_status": "translated", "translation_engine": f"local:{translator_model}", "translation": translation, "protected_spans_count": len(protected.spans), "translation_tokens": estimate_tokens(translation, model_profile)})
    except Exception as exc:
        warnings.append(str(exc))
        result.update({"translation_status": "failed_fallback", "translation_engine": f"local:{translator_model}", "protected_spans_count": len(protected.spans)})
    return result


def _improver_model() -> str:
    return os.environ.get("SOMA_ANALYST_MODEL") or os.environ.get("SOMA_RANKER_MODEL") or os.environ.get("SOMA_LOCAL_MODEL") or "qwen3-coder:30b-a3b-q4_K_M"


def improve_general_prompt(prompt: str, model: str | None = None, model_profile: str = "gpt-5.5") -> dict[str, Any]:
    translation = (prompt or "").strip()
    improver_model = model or _improver_model()
    result, warnings = _improvement_result(improver_model)
    if not translation:
        warnings.append("Translation is empty.")
        return result
    if is_codex_stage_model(improver_model):
        return _api()._improve_general_prompt_codex(translation, improver_model, model_profile, _improvement_timeout())
    return _improve_general_local(translation, improver_model, model_profile, result, warnings)


def _improvement_result(improver_model):
    warnings: list[str] = []
    return {"status": "failed", "improved_prompt": "", "improver_model": improver_model, "warnings": warnings, "protected_spans_count": 0, "improvement_retry_used": False}, warnings


def _improvement_timeout():
    return float(os.environ.get("SOMA_PROMPT_POLISH_TIMEOUT", os.environ.get("SOMA_TRANSLATION_TIMEOUT", "45")) or 45)


def _improve_general_local(translation, improver_model, model_profile, result, warnings):
    protected = protect_spans(translation)
    try:
        improved, retry_used = _validated_local_improvement(translation, protected, improver_model, _improvement_timeout(), warnings)
        result.update({"status": "ok", "improved_prompt": improved, "protected_spans_count": len(protected.spans), "improved_prompt_tokens": estimate_tokens(improved, model_profile), "improvement_retry_used": retry_used})
    except Exception as exc:
        warnings.append(f"Prompt improvement failed: {exc}")
        result.update({"status": "degraded", "improved_prompt": translation, "protected_spans_count": len(protected.spans), "improved_prompt_tokens": estimate_tokens(translation, model_profile)})
    return result


def _validated_local_improvement(translation, protected, improver_model, timeout, warnings):
    improved_protected = _api()._local_ollama_improve_prompt(protected.text, improver_model, timeout)
    improved, validation_error = _restore_valid_improved_prompt(translation, protected, improved_protected)
    if not validation_error:
        return improved, False
    repaired = _repair_improvement(translation, protected, improver_model, timeout, validation_error, improved_protected)
    warnings.append(f"Prompt improvement retry recovered after: {validation_error}")
    return repaired, True


def _repair_improvement(translation, protected, improver_model, timeout, validation_error, improved_protected):
    try:
        repaired_protected = _api()._local_ollama_repair_prompt(protected.text, improver_model, timeout, validation_error, improved_protected)
        repaired, repair_error = _restore_valid_improved_prompt(translation, protected, repaired_protected)
        if repair_error:
            raise RuntimeError(repair_error)
        return repaired
    except Exception as retry_exc:
        raise RuntimeError(f"{validation_error}; retry failed: {retry_exc}") from retry_exc


def optimize_general_prompt(prompt: str, model_profile: str = "gpt-5.5") -> dict[str, Any]:
    translator_model = _translator_model()
    improver_model = _improver_model()
    translation_result = translate_general_prompt(prompt, translator_model, model_profile)
    result = {**translation_result, "translator_model": translator_model, "improver_model": improver_model, "improved_prompt": "", "improved_prompt_tokens": None}
    if translation_result.get("status") != "ok":
        return result
    improve_result = improve_general_prompt(str(translation_result.get("translation") or ""), improver_model, model_profile)
    warnings = list(translation_result.get("warnings") or []) + list(improve_result.get("warnings") or [])
    result.update({"status": improve_result.get("status"), "improved_prompt": improve_result.get("improved_prompt"), "improved_prompt_tokens": improve_result.get("improved_prompt_tokens"), "improvement_retry_used": improve_result.get("improvement_retry_used", False), "warnings": warnings, "protected_spans_count": int(translation_result.get("protected_spans_count") or 0) + int(improve_result.get("protected_spans_count") or 0)})
    return result
