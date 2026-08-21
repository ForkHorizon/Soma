from __future__ import annotations

import json
from dataclasses import asdict, fields
from pathlib import Path

from rus_to_prompt_stress_models import CaseResult, TRANSLATION_ONLY_ANALYZER_MODEL, PromptCase, progress_event_line


def load_resume_results(path: Path, benchmark_mode: str) -> list[CaseResult]:
    if not path.exists():
        return []
    loaded: list[CaseResult] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            result = case_result_from_dict(row)
        except Exception:
            continue
        if result.benchmark_mode == benchmark_mode:
            loaded.append(result)
    return dedupe_results(loaded)


def case_result_from_dict(row: dict) -> CaseResult:
    names = {field.name for field in fields(CaseResult)}
    values = {name: row[name] for name in names if name in row}
    return CaseResult(**values)


def dedupe_results(results: list[CaseResult]) -> list[CaseResult]:
    order: list[tuple[str, str, str, str]] = []
    by_key: dict[tuple[str, str, str, str], CaseResult] = {}
    for result in results:
        key = resume_key(result)
        if key not in by_key:
            order.append(key)
        by_key[key] = result
    return [by_key[key] for key in order]


def write_existing_results(file, results: list[CaseResult]) -> None:
    for result in results:
        file.write(json.dumps(asdict(result), ensure_ascii=False) + "\n")
    file.flush()


def find_existing_translation(
    results: list[CaseResult], case_id: str, translator: str, benchmark_mode: str
) -> CaseResult | None:
    return find_existing_result(results, case_id, translator, TRANSLATION_ONLY_ANALYZER_MODEL, benchmark_mode)


def find_existing_result(
    results: list[CaseResult],
    case_id: str,
    translator: str | None,
    analyzer: str | None,
    benchmark_mode: str,
) -> CaseResult | None:
    wanted = (case_id, benchmark_mode, translator or "", analyzer or "")
    for result in reversed(results):
        if resume_key(result) == wanted:
            return result
    return None


def resume_key(result: CaseResult) -> tuple[str, str, str, str]:
    return (
        result.id,
        result.benchmark_mode,
        result.translator_model or "",
        result.analyzer_model or "",
    )


def translation_payload_from_result(result: CaseResult) -> dict:
    ok = result.translation_status in {"translated", "original_english"}
    return {
        "status": "ok" if ok else "failed",
        "translation_status": result.translation_status,
        "translation": result.translation,
        "source_language": result.source_language,
        "protected_spans_count": result.protected_spans_count,
        "warnings": result.warnings,
    }


def emit_resume_skip(
    case: PromptCase,
    stage: str,
    translator: str | None,
    analyzer: str | None,
    operation: int,
    total_operations: int,
) -> None:
    print(
        progress_event_line(
            event="resume_skip",
            stage=stage,
            case_id=case.id,
            category=case.category,
            translator_model=translator,
            analyzer_model=analyzer,
            operation_index=operation,
            total_operations=total_operations,
            status="already_completed",
        ),
        flush=True,
    )
