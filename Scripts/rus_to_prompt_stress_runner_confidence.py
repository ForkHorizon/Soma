from __future__ import annotations

import json
import time
from dataclasses import asdict
from pathlib import Path
from typing import Any

from rus_to_prompt_confidence_semantics import canonical_confidence_status
from rus_to_prompt_stress_confidence import (
    aggregate_local_confidences,
    confidence_item_id,
    hybrid_escalation_reason,
    score_confidence_batch_with_provider,
    _attach_or_keep_local,
)
from rus_to_prompt_stress_models import (
    DEFAULT_HYBRID_DISAGREEMENT_THRESHOLD,
    DEFAULT_HYBRID_LOCAL_CONFIDENCE_THRESHOLD,
    DEFAULT_LOCAL_CONFIDENCE_MODELS,
    chunked,
    progress_event_line,
    provider_for_stage_model,
    read_control_file,
    confidence_value,
)
from rus_to_prompt_stress_results import (
    apply_deterministic_confidence_caps,
    build_translation_rejected_result,
    failed_confidence_result,
    translation_confidence_allows_improve,
    translation_rejection_reason,
)


def score_and_attach_confidence(case, result, stage: str, args, operation: int, total_operations: int) -> None:
    if args.confidence_referee == "off":
        return
    stage_label = confidence_progress_stage(stage)
    print(progress_event_line(event="confidence_batch_start", stage=stage_label, case_id=case.id, category=case.category, translator_model=result.translator_model, analyzer_model=result.analyzer_model, operation_index=operation, total_operations=total_operations, batch_size=1, batch_index=1, batch_total=1, status="running"), flush=True)
    item_id = confidence_item_id(result, stage)
    try:
        by_id = score_confidence_batch_with_provider([(item_id, case, result)], **confidence_kwargs(args, stage))
        confidence = by_id.get(item_id) or failed_confidence_result(args.confidence_model, stage, "Confidence judge did not return a result.", args.confidence_reasoning_effort, provider=args.confidence_referee)
    except Exception as exc:
        confidence = failed_confidence_result(args.confidence_model, stage, str(exc), args.confidence_reasoning_effort, provider=args.confidence_referee)
    setattr(result, confidence_attr(stage), confidence)
    print(progress_event_line(event="confidence_batch_complete", stage=stage_label, case_id=case.id, category=case.category, translator_model=result.translator_model, analyzer_model=result.analyzer_model, operation_index=operation, total_operations=total_operations, batch_size=1, batch_index=1, batch_total=1, status=confidence.get("status"), confidence=confidence.get("confidence")), flush=True)


def score_and_attach_confidence_batch(case, operation_results: list[tuple[int, Any]], stage: str, args, total_operations: int) -> None:
    if args.confidence_referee == "off" or not operation_results:
        return
    if args.confidence_referee == "hybrid":
        score_and_attach_confidence_batches(case, [(stage, operation_results)], args, total_operations)
        return
    stage_label = confidence_progress_stage(stage)
    batches = chunked(operation_results, int(args.confidence_batch_size or 1))
    for batch_index, batch in enumerate(batches, start=1):
        operation = batch[0][0]
        items = [(confidence_item_id(result, stage), case, result) for _operation, result in batch]
        scope = confidence_batch_scope([result for _operation, result in batch])
        print(progress_event_line(event="confidence_batch_start", stage=stage_label, case_id=case.id, category=case.category, operation_index=operation, total_operations=total_operations, batch_size=len(batch), batch_index=batch_index, batch_total=len(batches), status="running", confidence_model=args.confidence_model, confidence_item_ids=[item_id for item_id, _case, _result in items], confidence_model_refs=confidence_model_refs([result for _operation, result in batch]), **scope), flush=True)
        by_id = confidence_batch_results(items, stage, args)
        attached = []
        for _operation, result in batch:
            item_id = confidence_item_id(result, stage)
            confidence = by_id.get(item_id) or failed_confidence_result(args.confidence_model, stage, "Confidence judge did not return a result.", args.confidence_reasoning_effort, provider=args.confidence_referee)
            confidence = apply_deterministic_confidence_caps(confidence, result, stage)
            setattr(result, confidence_attr(stage), confidence)
            attached.append(confidence)
        print(progress_event_line(event="confidence_batch_complete", stage=stage_label, case_id=case.id, category=case.category, operation_index=operation, total_operations=total_operations, batch_size=len(batch), batch_index=batch_index, batch_total=len(batches), status=confidence_batch_status(attached), confidence=confidence_batch_average(attached), confidence_model=args.confidence_model, confidence_item_ids=[item_id for item_id, _case, _result in items], confidence_model_refs=confidence_model_refs([result for _operation, result in batch]), **scope), flush=True)


def score_and_attach_confidence_batches(case, stage_operation_results: list[tuple[str, list[tuple[int, Any]]]], args, total_operations: int) -> None:
    stage_operation_results = [(stage, rows) for stage, rows in stage_operation_results if rows]
    if args.confidence_referee == "off" or not stage_operation_results:
        return
    if args.confidence_referee != "hybrid":
        for stage, operation_results in stage_operation_results:
            score_and_attach_confidence_batch(case, operation_results, stage, args, total_operations)
        return
    _score_and_attach_hybrid_model_major(case, stage_operation_results, args, total_operations)


def _score_and_attach_hybrid_model_major(case, stage_operation_results: list[tuple[str, list[tuple[int, Any]]]], args, total_operations: int) -> None:
    state = load_confidence_state(args)
    local_models = list(dict.fromkeys(args.local_confidence_models or DEFAULT_LOCAL_CONFIDENCE_MODELS))[:2]
    batches_by_stage = _confidence_stage_batches(case, stage_operation_results, args)
    for judge_index, model in enumerate(local_models, start=1):
        for batch_info in _iter_confidence_batches(batches_by_stage):
            _score_local_judge_batch(case, batch_info, model, judge_index, len(local_models), args, total_operations, state)
    save_confidence_state(args, state)
    final = _aggregate_hybrid_confidences(batches_by_stage, local_models, args, state)
    _attach_hybrid_confidences(case, batches_by_stage, final, args, total_operations)


def _confidence_stage_batches(case, stage_operation_results: list[tuple[str, list[tuple[int, Any]]]], args) -> list[dict[str, Any]]:
    grouped: list[dict[str, Any]] = []
    for stage, operation_results in stage_operation_results:
        batches = []
        for batch_index, batch in enumerate(chunked(operation_results, int(args.confidence_batch_size or 1)), start=1):
            results = [result for _operation, result in batch]
            items = [(confidence_item_id(result, stage), case, result) for _operation, result in batch]
            batches.append(
                {
                    "stage": stage,
                    "stage_label": confidence_progress_stage(stage),
                    "operation": batch[0][0],
                    "batch_index": batch_index,
                    "batch_total": None,
                    "batch": batch,
                    "items": items,
                    "scope": confidence_batch_scope(results),
                    "refs": confidence_model_refs(results),
                }
            )
        for batch_info in batches:
            batch_info["batch_total"] = len(batches)
        grouped.append({"stage": stage, "batches": batches})
    return grouped


def _iter_confidence_batches(batches_by_stage: list[dict[str, Any]]):
    for stage_group in batches_by_stage:
        for batch_info in stage_group["batches"]:
            yield batch_info


def _score_local_judge_batch(case, batch_info: dict[str, Any], model: str, judge_index: int, judge_total: int, args, total_operations: int, state: dict[str, Any]) -> None:
    items = batch_info["items"]
    missing = [(item_id, case, result) for item_id, case, result in items if _confidence_state_key(item_id, model) not in state["local_judges"]]
    status = "cached" if not missing else "running"
    print(progress_event_line(event="confidence_batch_start", stage=batch_info["stage_label"], case_id=case.id, category=case.category, operation_index=batch_info["operation"], total_operations=total_operations, batch_size=len(items), batch_index=batch_info["batch_index"], batch_total=batch_info["batch_total"], status=status, confidence_model=model, confidence_judge_index=judge_index, confidence_judge_total=judge_total, confidence_item_ids=[item_id for item_id, _case, _result in items], confidence_model_refs=batch_info["refs"], **batch_info["scope"]), flush=True)
    attached = []
    if missing:
        try:
            by_id = score_confidence_batch_with_provider(missing, **_local_confidence_kwargs(args, batch_info["stage"], model))
        except Exception as exc:
            by_id = {item_id: failed_confidence_result(model, batch_info["stage"], str(exc), provider="local") for item_id, _case, _result in missing}
        for item_id, _case, _result in missing:
            confidence = by_id.get(item_id) or failed_confidence_result(model, batch_info["stage"], "Local confidence judge did not return this item.", provider="local")
            confidence = apply_deterministic_confidence_caps(confidence, _result, batch_info["stage"])
            state["local_judges"][_confidence_state_key(item_id, model)] = normalize_local_judge_confidence(confidence)
        save_confidence_state(args, state)
    for item_id, _case, _result in items:
        confidence = state["local_judges"].get(_confidence_state_key(item_id, model))
        if isinstance(confidence, dict):
            attached.append(confidence)
    print(progress_event_line(event="confidence_batch_complete", stage=batch_info["stage_label"], case_id=case.id, category=case.category, operation_index=batch_info["operation"], total_operations=total_operations, batch_size=len(items), batch_index=batch_info["batch_index"], batch_total=batch_info["batch_total"], status=confidence_batch_status(attached), confidence=confidence_batch_average(attached), confidence_model=model, confidence_judge_index=judge_index, confidence_judge_total=judge_total, confidence_item_ids=[item_id for item_id, _case, _result in items], confidence_model_refs=batch_info["refs"], **batch_info["scope"]), flush=True)


def _aggregate_hybrid_confidences(batches_by_stage: list[dict[str, Any]], local_models: list[str], args, state: dict[str, Any]) -> dict[str, dict[str, Any]]:
    final: dict[str, dict[str, Any]] = {}
    aggregate_model = " + ".join(local_models)
    fallback_by_stage: dict[str, list[tuple[str, Any, Any]]] = {}
    local_by_item: dict[str, list[dict[str, Any]]] = {}
    reasons: dict[str, str] = {}
    for batch_info in _iter_confidence_batches(batches_by_stage):
        stage = batch_info["stage"]
        for item_id, case, result in batch_info["items"]:
            confidences = [
                state["local_judges"].get(_confidence_state_key(item_id, model))
                or failed_confidence_result(model, stage, "Local confidence judge did not return this item.", provider="local")
                for model in local_models
            ]
            local_by_item[item_id] = confidences
            reason = hybrid_escalation_reason(confidences, threshold=args.hybrid_confidence_local_threshold, disagreement_threshold=args.hybrid_confidence_disagreement_threshold)
            if reason:
                fallback_by_stage.setdefault(stage, []).append((item_id, case, result))
                reasons[item_id] = reason
            else:
                final[item_id] = aggregate_local_confidences(confidences, model=aggregate_model, stage=stage, batch_item_id=item_id)
    for stage, items in fallback_by_stage.items():
        final.update(_fallback_confidences_model_major(items, local_by_item, reasons, aggregate_model, args, stage))
    return final


def _fallback_confidences_model_major(items, local_by_item: dict[str, list[dict[str, Any]]], reasons: dict[str, str], aggregate_model: str, args, stage: str) -> dict[str, dict[str, Any]]:
    provider = args.hybrid_confidence_fallback_referee
    if not items:
        return {}
    if provider == "off":
        return {item_id: aggregate_local_confidences(local_by_item[item_id], model=aggregate_model, stage=stage, batch_item_id=item_id) for item_id, _case, _result in items}
    fallback_kwargs = confidence_kwargs(args, stage)
    fallback_kwargs.update({"provider": provider, "model": args.hybrid_confidence_gemini_model or args.confidence_model})
    try:
        fallback = score_confidence_batch_with_provider(items, **fallback_kwargs)
    except Exception as exc:
        fallback = {item_id: failed_confidence_result(fallback_kwargs["model"], stage, str(exc), provider=provider) for item_id, _case, _result in items}
    return {
        item_id: _attach_or_keep_local(item_id, fallback.get(item_id), local_by_item[item_id], reasons[item_id], aggregate_model, stage)
        for item_id, _case, _result in items
    }


def _attach_hybrid_confidences(case, batches_by_stage: list[dict[str, Any]], final: dict[str, dict[str, Any]], args, total_operations: int) -> None:
    for batch_info in _iter_confidence_batches(batches_by_stage):
        attached = []
        for _operation, result in batch_info["batch"]:
            item_id = confidence_item_id(result, batch_info["stage"])
            confidence = final.get(item_id) or failed_confidence_result(args.confidence_model, batch_info["stage"], "Confidence judge did not return a result.", args.confidence_reasoning_effort, provider=args.confidence_referee)
            confidence = apply_deterministic_confidence_caps(confidence, result, batch_info["stage"])
            setattr(result, confidence_attr(batch_info["stage"]), confidence)
            attached.append(confidence)
        print(progress_event_line(event="confidence_batch_complete", stage=batch_info["stage_label"], case_id=case.id, category=case.category, operation_index=batch_info["operation"], total_operations=total_operations, batch_size=len(batch_info["items"]), batch_index=batch_info["batch_index"], batch_total=batch_info["batch_total"], status=confidence_batch_status(attached), confidence=confidence_batch_average(attached), confidence_model=args.confidence_referee, confidence_item_ids=[item_id for item_id, _case, _result in batch_info["items"]], confidence_model_refs=batch_info["refs"], **batch_info["scope"]), flush=True)


def _local_confidence_kwargs(args, stage: str, model: str) -> dict[str, Any]:
    kwargs = confidence_kwargs(args, stage)
    kwargs.update({"provider": "local", "model": model})
    return kwargs


def load_confidence_state(args) -> dict[str, Any]:
    path = confidence_state_path(args)
    try:
        decoded = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        decoded = {}
    local_judges = decoded.get("local_judges") if isinstance(decoded, dict) else None
    return {"version": 1, "local_judges": local_judges if isinstance(local_judges, dict) else {}}


def save_confidence_state(args, state: dict[str, Any]) -> None:
    path = confidence_state_path(args)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except Exception:
        pass


def confidence_state_path(args) -> Path:
    return Path(args.out_dir) / "confidence_state.json"


def _confidence_state_key(item_id: str, model: str) -> str:
    return json.dumps([item_id, model], ensure_ascii=False, separators=(",", ":"))


def confidence_model_refs(results) -> list[dict[str, str]]:
    refs = []
    for result in results:
        ref = {
            "translator_model": result.translator_model or "",
            "analyzer_model": result.analyzer_model or "",
        }
        refs.append(ref)
    return refs


def confidence_batch_results(items, stage: str, args) -> dict[str, dict[str, Any]]:
    try:
        return score_confidence_batch_with_provider(items, **confidence_kwargs(args, stage))
    except Exception as exc:
        return {
            item_id: failed_confidence_result(
                args.confidence_model,
                stage,
                str(exc),
                args.confidence_reasoning_effort,
                provider=args.confidence_referee,
            )
            for item_id, _case, _result in items
        }


def confidence_batch_scope(results) -> dict[str, str]:
    translators = {result.translator_model for result in results if result.translator_model}
    analyzers = {result.analyzer_model for result in results if result.analyzer_model}
    return {
        "translator_model": next(iter(translators)) if len(translators) == 1 else None,
        "analyzer_model": next(iter(analyzers)) if len(analyzers) == 1 else None,
    }


def confidence_batch_status(confidences) -> str:
    statuses = {canonical_confidence_status(confidence) or "unknown" for confidence in confidences if isinstance(confidence, dict)}
    if not statuses:
        return "failed"
    if statuses == {"ok"}:
        return "ok"
    if "failed" in statuses:
        return "failed"
    return "review"


def confidence_batch_average(confidences) -> float | None:
    numeric = [value for confidence in confidences if isinstance(confidence, dict) and (value := confidence_value(confidence)) is not None]
    return sum(numeric) / len(numeric) if numeric else None


def confidence_kwargs(args, stage: str) -> dict[str, Any]:
    return {
        "provider": args.confidence_referee,
        "model": args.confidence_model,
        "timeout": confidence_timeout(args),
        "stage": stage,
        "codex_bin": args.codex_bin,
        "gemini_bin": args.gemini_bin,
        "reasoning_effort": args.confidence_reasoning_effort,
        "local_models": args.local_confidence_models or DEFAULT_LOCAL_CONFIDENCE_MODELS,
        "hybrid_gemini_model": args.hybrid_confidence_gemini_model or args.confidence_model,
        "hybrid_fallback_provider": args.hybrid_confidence_fallback_referee,
        "hybrid_local_threshold": args.hybrid_confidence_local_threshold,
        "hybrid_disagreement_threshold": args.hybrid_confidence_disagreement_threshold,
    }


def confidence_timeout(args) -> float:
    return args.gemini_stage_timeout if args.confidence_referee in {"gemini", "hybrid"} else args.codex_stage_timeout


def confidence_progress_stage(stage: str) -> str:
    return {
        "translation": "translation_confidence_batch",
        "improve": "improve_confidence_batch",
        "overall": "overall_confidence_batch",
    }.get(stage, stage + "_confidence_batch")


def confidence_attr(stage: str) -> str:
    return {
        "translation": "translation_confidence",
        "improve": "improve_confidence",
        "overall": "overall_confidence",
    }[stage]


def emit_translation_gate(case, result, args, operation: int, total_operations: int) -> None:
    if result.translation_status not in {"translated", "original_english"}:
        status, reason = "rejected", "Translation failed."
    elif args.confidence_referee == "off":
        status, reason = "accepted", "Confidence gate disabled."
    elif translation_confidence_allows_improve(result.translation_confidence, args.translation_confidence_threshold):
        status, reason = "accepted", "Translation confidence passed."
    else:
        status = "rejected"
        reason = translation_rejection_reason(result.translation_confidence, args.translation_confidence_threshold)
    confidence = (result.translation_confidence or {}).get("confidence") if isinstance(result.translation_confidence, dict) else None
    print(progress_event_line(event="translation_gate", stage="translation_confidence", case_id=case.id, category=case.category, translator_model=result.translator_model, operation_index=operation, total_operations=total_operations, status=status, reason=reason, confidence=confidence), flush=True)


def best_translation(rows, args):
    accepted = []
    for position, (translation_payload, translation_seconds, result) in enumerate(rows):
        if result.translation_status not in {"translated", "original_english"}:
            continue
        if args.confidence_referee == "off":
            accepted.append((translation_selection_score(result, translation_seconds, 1.0, position), translation_payload, translation_seconds, result))
            continue
        confidence = result.translation_confidence or {}
        if translation_confidence_allows_improve(confidence, args.translation_confidence_threshold):
            value = confidence_value(confidence)
            accepted.append((translation_selection_score(result, translation_seconds, float(value or 0.0), position), translation_payload, translation_seconds, result))
    if not accepted:
        return None
    _score, translation_payload, translation_seconds, result = max(accepted, key=lambda item: item[0])
    return translation_payload, translation_seconds, result


def translation_selection_score(result, translation_seconds: float | None, confidence: float, position: int) -> tuple:
    translation = (result.translation or "").strip()
    confidence_payload = result.translation_confidence if isinstance(result.translation_confidence, dict) else {}
    local_values = [
        confidence_value(judge)
        for judge in confidence_payload.get("local_judges", [])
        if isinstance(judge, dict)
    ]
    numeric_local = [value for value in local_values if value is not None]
    local_disagreement = max(numeric_local) - min(numeric_local) if len(numeric_local) >= 2 else 0.0
    confidence_warnings = len(confidence_payload.get("warnings") or [])
    row_warnings = len(result.warnings or [])
    fallback_used = bool(confidence_payload.get("fallback_provider") or confidence_payload.get("hybrid_escalated"))
    cap_count = len(confidence_payload.get("deterministic_confidence_cap_reasons") or [])
    return (
        confidence,
        1 if row_warnings == 0 else 0,
        1 if confidence_warnings == 0 else 0,
        1 if not fallback_used else 0,
        1 if cap_count == 0 else 0,
        -local_disagreement,
        -confidence_warnings,
        -row_warnings,
        -len(translation),
        -(translation_seconds or 0.0),
        -position,
    )


def normalize_local_judge_confidence(confidence: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(confidence)
    raw_status = str(normalized.get("status") or "review")
    normalized["raw_status"] = raw_status
    normalized["status"] = normalized_local_status(raw_status, normalized.get("verdict"), confidence_value(normalized))
    return normalized


def normalized_local_status(raw_status: str, verdict: Any, value: float | None) -> str:
    raw = raw_status.strip().lower()
    verdict_text = str(verdict or "").strip().lower()
    if raw in {"failed", "fail", "rejected", "error", "exception"} or verdict_text == "fail":
        return "failed"
    if value is None:
        return "review"
    if value < 0.80 or raw in {"review", "degraded"} or verdict_text == "review":
        return "review"
    return "ok"


def rejected_improver_result(case, analyzer, args):
    payload = {"status": "failed", "translation_status": "failed", "translation": "", "source_language": "unknown", "warnings": ["No translation passed the staged confidence gate."]}
    provider = provider_for_stage_model(analyzer, args.analyzer_provider)
    return build_translation_rejected_result(case, "none", analyzer, "none", provider, payload, 0.0, "No translation passed the staged confidence gate; skipped improver stage.")


def write_result(file, results, result, operation: int, total_operations: int) -> None:
    print(progress_event_line(event="result_write", stage="writing_result", case_id=result.id, translator_model=result.translator_model, analyzer_model=result.analyzer_model, operation_index=operation, total_operations=total_operations, status=result.status), flush=True)
    results.append(result)
    file.write(json.dumps(asdict(result), ensure_ascii=False) + "\n")
    file.flush()


def replace_result(file, results, result, operation: int, total_operations: int) -> None:
    print(progress_event_line(event="result_update", stage="writing_result", case_id=result.id, translator_model=result.translator_model, analyzer_model=result.analyzer_model, operation_index=operation, total_operations=total_operations, status=result.status), flush=True)
    key = _result_key(result)
    for index in range(len(results) - 1, -1, -1):
        if _result_key(results[index]) == key:
            results[index] = result
            break
    else:
        results.append(result)
    file.seek(0)
    file.truncate()
    for row in results:
        file.write(json.dumps(asdict(row), ensure_ascii=False) + "\n")
    file.flush()


def _result_key(result) -> tuple[str, str, str, str]:
    return (
        result.id,
        result.benchmark_mode,
        result.translator_model or "",
        result.analyzer_model or "",
    )


def cooldown(args, case, translator: str | None, analyzer: str | None, operation: int, total_operations: int, reason: str) -> None:
    seconds = max(0.0, float(args.stage_cooldown_seconds or 0))
    if seconds <= 0:
        wait_if_paused(args, case, translator, analyzer, operation, total_operations)
        return
    deadline = time.monotonic() + seconds
    print(progress_event_line(event="cooldown_start", stage="cooldown", case_id=case.id, category=case.category, translator_model=translator, analyzer_model=analyzer, operation_index=operation, total_operations=total_operations, status="running", reason=f"{reason}; {seconds:.1f}s"), flush=True)
    paused = False
    while time.monotonic() < deadline:
        control = read_control_file(args.control_file)
        if control.get("stop"):
            raise KeyboardInterrupt("Queue stop requested.")
        if control.get("skip_cooldown") or control.get("run_now"):
            break
        if control.get("pause"):
            if not paused:
                print(progress_event_line(event="cooldown_pause", stage="cooldown", case_id=case.id, category=case.category, translator_model=translator, analyzer_model=analyzer, operation_index=operation, total_operations=total_operations, status="paused"), flush=True)
                paused = True
            time.sleep(0.5)
            deadline += 0.5
            continue
        paused = False
        time.sleep(min(0.5, max(0.0, deadline - time.monotonic())))
    print(progress_event_line(event="cooldown_complete", stage="cooldown", case_id=case.id, category=case.category, translator_model=translator, analyzer_model=analyzer, operation_index=operation, total_operations=total_operations, status="ok"), flush=True)


def wait_if_paused(args, case, translator: str | None, analyzer: str | None, operation: int, total_operations: int) -> None:
    paused = False
    while True:
        control = read_control_file(args.control_file)
        if control.get("stop"):
            raise KeyboardInterrupt("Queue stop requested.")
        if not control.get("pause"):
            if paused:
                print(progress_event_line(event="cooldown_complete", stage="cooldown", case_id=case.id, category=case.category, translator_model=translator, analyzer_model=analyzer, operation_index=operation, total_operations=total_operations, status="ok"), flush=True)
            return
        if not paused:
            print(progress_event_line(event="cooldown_pause", stage="cooldown", case_id=case.id, category=case.category, translator_model=translator, analyzer_model=analyzer, operation_index=operation, total_operations=total_operations, status="paused"), flush=True)
            paused = True
        time.sleep(0.5)
