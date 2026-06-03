from __future__ import annotations

import time
from pathlib import Path

from rus_to_prompt_stress_models import (
    TRANSLATION_ONLY_ANALYZER_MODEL,
    PromptCase,
    progress_event_line,
    provider_for_stage_model,
)
from rus_to_prompt_stress_results import build_case_result_from_payloads, build_translation_only_result
from rus_to_prompt_stress_runner_confidence import (
    best_translation,
    cooldown,
    emit_translation_gate,
    replace_result,
    rejected_improver_result,
    score_and_attach_confidence,
    score_and_attach_confidence_batch,
    score_and_attach_confidence_batches,
    write_result,
)
from rus_to_prompt_stress_runner_resume import (
    emit_resume_skip,
    find_existing_result,
    find_existing_translation,
    translation_payload_from_result,
    write_existing_results,
)
from rus_to_prompt_stress_providers import improve_with_codex, improve_with_gemini, translate_with_codex, translate_with_gemini

import soma_language_optimizer as optimizer  # noqa: E402


def run_cases(cases, translators, analyzers, args, results_path: Path, total_operations: int, existing_results=None):
    results = list(existing_results or [])
    with results_path.open("w", encoding="utf-8") as file:
        write_existing_results(file, results)
        if args.benchmark_mode == "translation":
            _run_translation_mode(cases, translators, args, file, results, total_operations)
        elif args.benchmark_mode == "staged":
            _run_staged_mode(cases, translators, analyzers, args, file, results, total_operations)
        else:
            _run_matrix_mode(cases, translators, analyzers, args, file, results, total_operations)
    return results


def _run_matrix_mode(cases, translators, analyzers, args, file, results, total_operations):
    operation = 0
    for case in cases:
        for translator in translators:
            for analyzer in analyzers:
                operation += 1
                existing = find_existing_result(results, case.id, translator, analyzer, args.benchmark_mode)
                if existing is not None:
                    emit_resume_skip(case, "matrix_resume", translator, analyzer, operation, total_operations)
                    continue
                result = _run_one(case, translator, analyzer, args, operation, total_operations)
                score_and_attach_confidence(case, result, "translation", args, operation, total_operations)
                if result.translation_status in {"translated", "original_english"} and result.improve_status:
                    score_and_attach_confidence(case, result, "improve", args, operation, total_operations)
                    score_and_attach_confidence(case, result, "overall", args, operation, total_operations)
                write_result(file, results, result, operation, total_operations)
                cooldown(args, case, translator, analyzer, operation, total_operations, "operation finished")


def _run_translation_mode(cases, translators, args, file, results, total_operations):
    operation = 0
    for case in cases:
        for translator in translators:
            operation += 1
            existing = find_existing_translation(results, case.id, translator, args.benchmark_mode)
            if existing is not None:
                emit_resume_skip(case, "translation_resume", translator, TRANSLATION_ONLY_ANALYZER_MODEL, operation, total_operations)
                continue
            translation, translation_seconds = _run_translation_stage(case, translator, args, operation, total_operations)
            provider = provider_for_stage_model(translator, args.translator_provider)
            result = build_translation_only_result(case, translator, TRANSLATION_ONLY_ANALYZER_MODEL, provider, "none", translation, translation_seconds)
            result.benchmark_mode = "translation"
            score_and_attach_confidence(case, result, "translation", args, operation, total_operations)
            write_result(file, results, result, operation, total_operations)
            cooldown(args, case, translator, None, operation, total_operations, "translation finished")


def _run_staged_mode(cases, translators, analyzers, args, file, results, total_operations):
    operation = 0
    for case in cases:
        translation_rows = []
        pending_translation_results = []
        for translator in translators:
            operation += 1
            existing = find_existing_translation(results, case.id, translator, args.benchmark_mode)
            if existing is not None:
                emit_resume_skip(case, "translation_resume", translator, TRANSLATION_ONLY_ANALYZER_MODEL, operation, total_operations)
                translation_rows.append((translation_payload_from_result(existing), existing.translation_seconds or 0.0, existing))
                if args.confidence_referee != "off" and existing.translation_confidence is None:
                    pending_translation_results.append((operation, existing))
                continue
            translation, translation_seconds = _run_translation_stage(case, translator, args, operation, total_operations)
            result = _translation_only_result(case, translator, translation, translation_seconds, args)
            translation_rows.append((translation, translation_seconds, result))
            pending_translation_results.append((operation, result))
            write_result(file, results, result, operation, total_operations)
            cooldown(args, case, translator, None, operation, total_operations, "translation finished")
        score_and_attach_confidence_batch(case, pending_translation_results, "translation", args, total_operations)
        for operation_index, result in pending_translation_results:
            emit_translation_gate(case, result, args, operation_index, total_operations)
            replace_result(file, results, result, operation_index, total_operations)
        operation = _run_staged_improvers(case, analyzers, translation_rows, args, file, results, operation, total_operations)


def _run_staged_improvers(case, analyzers, translation_rows, args, file, results, operation: int, total_operations: int) -> int:
    best = best_translation(translation_rows, args)
    _emit_best_translation(case, best, operation, total_operations)
    pending_improver_results = []
    for analyzer in analyzers:
        operation += 1
        if best is None:
            existing = find_existing_result(results, case.id, "none", analyzer, args.benchmark_mode)
            if existing is not None:
                emit_resume_skip(case, "improver_resume", "none", analyzer, operation, total_operations)
                continue
            result = rejected_improver_result(case, analyzer, args)
            result.benchmark_mode = "staged"
            write_result(file, results, result, operation, total_operations)
            cooldown(args, case, result.translator_model, analyzer, operation, total_operations, "improver stage finished")
            continue
        else:
            translation_payload, translation_seconds, translation_result = best
            existing = find_existing_result(results, case.id, translation_result.translator_model, analyzer, args.benchmark_mode)
            if existing is not None:
                emit_resume_skip(case, "improver_resume", translation_result.translator_model, analyzer, operation, total_operations)
                continue
            result = _run_improver_from_translation(case, translation_payload, translation_seconds, translation_result, analyzer, args, operation, total_operations)
        result.benchmark_mode = "staged"
        pending_improver_results.append((operation, result))
        cooldown(args, case, result.translator_model, analyzer, operation, total_operations, "improver stage finished")
    score_and_attach_confidence_batches(case, [("improve", pending_improver_results), ("overall", pending_improver_results)], args, total_operations)
    for operation_index, result in pending_improver_results:
        write_result(file, results, result, operation_index, total_operations)
    return operation


def _emit_best_translation(case, best, operation: int, total_operations: int) -> None:
    if best is None:
        print(progress_event_line(event="best_translation_selected", stage="translation_selection", case_id=case.id, category=case.category, operation_index=operation, total_operations=total_operations, status="rejected", reason="No translation passed the confidence gate."), flush=True)
        return
    _translation_payload, _translation_seconds, result = best
    confidence = (result.translation_confidence or {}).get("confidence") if isinstance(result.translation_confidence, dict) else None
    print(progress_event_line(event="best_translation_selected", stage="translation_selection", case_id=case.id, category=case.category, translator_model=result.translator_model, operation_index=operation, total_operations=total_operations, status="accepted", confidence=confidence), flush=True)


def _translation_only_result(case, translator, translation, translation_seconds, args):
    provider = provider_for_stage_model(translator, args.translator_provider)
    result = build_translation_only_result(case, translator, TRANSLATION_ONLY_ANALYZER_MODEL, provider, "none", translation, translation_seconds)
    result.benchmark_mode = "staged"
    return result


def _run_one(case, translator: str, analyzer: str, args, operation: int, total_operations: int):
    started = time.monotonic()
    translator_provider = provider_for_stage_model(translator, args.translator_provider)
    analyzer_provider = provider_for_stage_model(analyzer, args.analyzer_provider)
    _emit_stage_start(case, "translating", translator, analyzer, operation, total_operations)
    translation, translation_seconds = _translate(case.prompt, translator, translator_provider, args)
    _emit_stage_complete(case, "translating", translator, analyzer, operation, total_operations, translation.get("status"))
    _emit_stage_start(case, "analyzing", translator, analyzer, operation, total_operations)
    improve, improve_seconds = _improve(translation, analyzer, analyzer_provider, args)
    _emit_stage_complete(case, "analyzing", translator, analyzer, operation, total_operations, (improve or {}).get("status") or "skipped")
    result = build_case_result_from_payloads(case, translator, analyzer, translator_provider, analyzer_provider, translation, improve, translation_seconds, improve_seconds)
    result.seconds = time.monotonic() - started
    result.benchmark_mode = "matrix"
    return result


def _run_translation_stage(case: PromptCase, translator: str, args, operation: int, total_operations: int):
    provider = provider_for_stage_model(translator, args.translator_provider)
    _emit_stage_start(case, "translating", translator, None, operation, total_operations)
    payload, seconds = _translate(case.prompt, translator, provider, args)
    _emit_stage_complete(case, "translating", translator, None, operation, total_operations, payload.get("status"))
    return payload, seconds


def _run_improver_from_translation(case, translation_payload, translation_seconds, translation_result, analyzer, args, operation, total_operations):
    translator = str(translation_result.translator_model or "")
    translator_provider = str(translation_result.translator_provider or "local")
    analyzer_provider = provider_for_stage_model(analyzer, args.analyzer_provider)
    _emit_stage_start(case, "analyzing", translator, analyzer, operation, total_operations)
    improve, improve_seconds = _improve(translation_payload, analyzer, analyzer_provider, args)
    _emit_stage_complete(case, "analyzing", translator, analyzer, operation, total_operations, (improve or {}).get("status") or "skipped")
    result = build_case_result_from_payloads(case, translator, analyzer, translator_provider, analyzer_provider, translation_payload, improve, translation_seconds, improve_seconds)
    result.translation_confidence = translation_result.translation_confidence
    result.benchmark_mode = "staged"
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


def _emit_stage_start(case, stage, translator, analyzer, operation, total_operations):
    print(progress_event_line(event="stage_start", stage=stage, case_id=case.id, category=case.category, translator_model=translator, analyzer_model=analyzer, operation_index=operation, total_operations=total_operations, status="running"), flush=True)


def _emit_stage_complete(case, stage, translator, analyzer, operation, total_operations, status):
    print(progress_event_line(event="stage_complete", stage=stage, case_id=case.id, category=case.category, translator_model=translator, analyzer_model=analyzer, operation_index=operation, total_operations=total_operations, status=status), flush=True)
