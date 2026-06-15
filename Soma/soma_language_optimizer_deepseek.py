from __future__ import annotations

from typing import Any

from token_calculator import estimate_tokens
from soma_deepseek_api import run_deepseek_json
from soma_language_optimizer_core import (
    TARGET_LANGUAGE,
    _cyrillic_count,
    _looks_like_codex_payload_echo,
    _restore_valid_improved_prompt,
    _schema_string_list,
    _sha,
    _string_list,
    invalid_placeholders,
    protect_spans,
    restore_spans,
)


def _deepseek_translate_schema() -> dict[str, Any]:
    return {"type": "object", "additionalProperties": False, "properties": {"status": {"type": "string", "enum": ["ok", "failed"]}, "source_language": {"type": "string"}, "translation_status": {"type": "string"}, "translation": {"type": "string"}, "warnings": _schema_string_list()}, "required": ["status", "source_language", "translation_status", "translation", "warnings"]}


def _deepseek_improve_schema() -> dict[str, Any]:
    return {"type": "object", "additionalProperties": False, "properties": {"status": {"type": "string", "enum": ["ok", "failed"]}, "improved_prompt": {"type": "string"}, "warnings": _schema_string_list()}, "required": ["status", "improved_prompt", "warnings"]}


def _translate_general_prompt_deepseek(original: str, source_language: str, translator_model: str, model_profile: str, timeout: float) -> dict[str, Any]:
    warnings, result = _deepseek_translation_result(original, source_language, translator_model)
    protected = protect_spans(original)
    decoded, meta = run_deepseek_json(prompt=_deepseek_translation_prompt(source_language, protected), schema=_deepseek_translate_schema(), model=translator_model, timeout=timeout, temp_prefix="soma-rus-prompt-deepseek-translate-")
    if not isinstance(decoded, dict):
        warnings.append(str(meta.get("error") or "DeepSeek translation failed."))
        result["protected_spans_count"] = len(protected.spans)
        return result
    return _finish_deepseek_translation(decoded, warnings, result, original, protected, model_profile)


def _improve_general_prompt_deepseek(translation: str, improver_model: str, model_profile: str, timeout: float) -> dict[str, Any]:
    warnings, result = _deepseek_improvement_result(improver_model)
    protected = protect_spans(translation)
    decoded, meta = run_deepseek_json(prompt=_deepseek_improvement_prompt(protected), schema=_deepseek_improve_schema(), model=improver_model, timeout=timeout, temp_prefix="soma-rus-prompt-deepseek-improve-")
    if not isinstance(decoded, dict):
        warnings.append(str(meta.get("error") or "DeepSeek improvement failed."))
        return _degraded_improvement(result, translation, protected, model_profile)
    return _finish_deepseek_improvement(decoded, warnings, result, translation, protected, model_profile)


def _deepseek_translation_result(original, source_language, translator_model):
    warnings: list[str] = []
    result = {"status": "failed", "source_language": source_language, "target_language": TARGET_LANGUAGE, "translation_status": None, "translation_engine": f"deepseek:{translator_model}", "translation": "", "translator_model": translator_model, "warnings": warnings, "protected_spans_count": 0, "original_prompt_hash": _sha(original)}
    return warnings, result


def _deepseek_improvement_result(improver_model):
    warnings: list[str] = []
    result = {"status": "failed", "improved_prompt": "", "improver_model": improver_model, "warnings": warnings, "protected_spans_count": 0, "improvement_retry_used": False}
    return warnings, result


def _deepseek_translation_prompt(source_language, protected):
    return ("You are a precise technical translator. Do not use tools. Translate only the protected prompt between the delimiters to concise English.\n\nRules:\n- Return JSON only.\n- Set status exactly to ok when the translation succeeds, otherwise failed.\n- Preserve every protected placeholder exactly, such as __SOMA_PROTECTED_SPAN_0__.\n- Preserve code, paths, URLs, commands, JSON, symbols, and model names exactly through their placeholders.\n- Translate Russian 'сохрани'/'сохранить' as 'preserve' or 'keep unchanged' when it refers to technical literals.\n- Do not add implementation details, project context, commentary, or new requirements.\n\n" f"Source language hint: {source_language}\nProtected span count: {len(protected.spans)}\nProtected prompt:\n<<<PROMPT\n{protected.text}\nPROMPT>>>")


def _deepseek_improvement_prompt(protected):
    return ("You are a conservative prompt editor. Do not use tools. Rewrite only the translated request between the delimiters into one direct, high-quality English task prompt.\n\nRules:\n- Return JSON only.\n- Set status exactly to ok when the improvement succeeds, otherwise failed.\n- The improved_prompt must be the final copyable task prompt, not a meta-prompt about creating a prompt.\n- Preserve every protected placeholder exactly, such as __SOMA_PROTECTED_SPAN_0__.\n- Each placeholder must appear the same number of times as in the translated request; do not omit, rename, or duplicate placeholders.\n- Do not invent project context, file contents, bugs, quantified targets, output formats, or requirements not present.\n- Preserve commands, paths, URLs, JSON, code, model names, and symbols literally through their placeholders.\n- Keep it concise and action-oriented.\n\n" f"Protected span count: {len(protected.spans)}\nTranslated request:\n<<<PROMPT\n{protected.text}\nPROMPT>>>")


def _finish_deepseek_translation(decoded, warnings, result, original, protected, model_profile):
    translated_protected = str(decoded.get("translation") or "").strip()
    warnings.extend(_string_list(decoded.get("warnings")))
    validation_error = _deepseek_translation_error(decoded, translated_protected, protected, original)
    if validation_error:
        warnings.append(validation_error)
        result["protected_spans_count"] = len(protected.spans)
        return result
    translation = restore_spans(translated_protected, protected.spans).strip()
    result.update({"status": "ok", "translation_status": "translated", "translation": translation, "protected_spans_count": len(protected.spans), "translation_tokens": estimate_tokens(translation, model_profile)})
    return result


def _deepseek_translation_error(decoded, translated_protected, protected, original):
    if not _deepseek_status_ok(decoded) or not translated_protected:
        return "DeepSeek translation returned failed status or empty translation."
    if _looks_like_codex_payload_echo(translated_protected):
        return "DeepSeek translation echoed the control payload instead of translating the prompt."
    invalid = invalid_placeholders(translated_protected, len(protected.spans))
    if invalid:
        return "DeepSeek translation corrupted protected placeholders: " + ", ".join(invalid[:5])
    translation = restore_spans(translated_protected, protected.spans).strip()
    return "DeepSeek translation did not sufficiently normalize Cyrillic text." if not translation or _cyrillic_count(translation) >= max(2, _cyrillic_count(original) // 2) else None


def _finish_deepseek_improvement(decoded, warnings, result, translation, protected, model_profile):
    improved_protected = str(decoded.get("improved_prompt") or "").strip()
    warnings.extend(_string_list(decoded.get("warnings")))
    if not _deepseek_status_ok(decoded) or not improved_protected:
        warnings.append("DeepSeek improvement returned failed status or empty prompt.")
        return _degraded_improvement(result, translation, protected, model_profile)
    if _looks_like_codex_payload_echo(improved_protected):
        warnings.append("DeepSeek improvement echoed the control payload instead of improving the prompt.")
        return _degraded_improvement(result, translation, protected, model_profile)
    improved, validation_error = _restore_valid_improved_prompt(translation, protected, improved_protected)
    if validation_error:
        warnings.append("DeepSeek improvement failed validation: " + validation_error)
        return _degraded_improvement(result, translation, protected, model_profile)
    result.update({"status": "ok", "improved_prompt": improved, "protected_spans_count": len(protected.spans), "improved_prompt_tokens": estimate_tokens(improved, model_profile)})
    return result


def _degraded_improvement(result, translation, protected, model_profile):
    result.update({"status": "degraded", "improved_prompt": translation, "protected_spans_count": len(protected.spans), "improved_prompt_tokens": estimate_tokens(translation, model_profile)})
    return result


def _deepseek_status_ok(decoded: dict[str, Any]) -> bool:
    status = str(decoded.get("status") or "").strip().lower()
    return status in {"ok", "success", "succeeded", "completed", "complete", "done", "pass", "passed"}
