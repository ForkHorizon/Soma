#!/usr/bin/env python3
"""Task-level audit trail for real Soma usage.

Audit reports correlate a user task, Soma packet, selected evidence, tool calls,
and quality review without writing raw private content by default.
"""

from __future__ import annotations

import argparse
import contextlib
import contextvars
import hashlib
import json
import os
import re
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator


SOMA_AUDIT_DIR = Path.home() / ".soma" / "audit"
SOMA_AUDIT_RUNS_DIR = SOMA_AUDIT_DIR / "runs"
SOMA_AUDIT_RAW_DIR = SOMA_AUDIT_DIR / "raw"
SOMA_AUDIT_LATEST = SOMA_AUDIT_DIR / "latest.json"
AUDIT_ARGUMENT_KEYS = {"run_id", "task_id", "client", "workflow"}
COMMON_CONCEPT_REFERENCES = {"github", "gitlab", "bitbucket", "codex", "gemini", "ollama", "nexus", "unity", "soma"}

_audit_context: contextvars.ContextVar[dict[str, Any]] = contextvars.ContextVar("soma_audit_context", default={})


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def _sha(text: str | None) -> str:
    return "sha256:" + hashlib.sha256((text or "").encode("utf-8", errors="replace")).hexdigest()


def hash_text(text: str | None) -> str:
    return _sha(text)


def _safe_id(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", str(value or ""))[:120] or "run"


def audit_enabled() -> bool:
    return os.environ.get("SOMA_AUDIT_ENABLED", "1").lower() not in {"0", "false", "no"}


def raw_capture_enabled() -> bool:
    return os.environ.get("SOMA_AUDIT_RAW_CAPTURE", "0").lower() in {"1", "true", "yes"}


def new_run_id() -> str:
    return f"run_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:8]}"


def current_context() -> dict[str, Any]:
    return dict(_audit_context.get({}))


@contextlib.contextmanager
def scoped_context(**values: Any) -> Iterator[dict[str, Any]]:
    merged = current_context()
    merged.update({key: value for key, value in values.items() if value is not None})
    token = _audit_context.set(merged)
    try:
        yield merged
    finally:
        _audit_context.reset(token)


def context_from_arguments(arguments: dict[str, Any] | None) -> dict[str, Any]:
    raw = arguments if isinstance(arguments, dict) else {}
    return {key: raw.get(key) for key in AUDIT_ARGUMENT_KEYS if raw.get(key) is not None}


def ensure_context(
    *, workflow: str = "packet_mode", task_id: str | None = None, run_id: str | None = None, client: str | None = None
) -> dict[str, Any]:
    context = current_context()
    resolved_run_id = run_id or context.get("run_id") or os.environ.get("SOMA_AUDIT_RUN_ID") or new_run_id()
    resolved_task_id = (
        task_id or context.get("task_id") or os.environ.get("SOMA_AUDIT_TASK_ID") or f"task_{resolved_run_id[-8:]}"
    )
    return {
        "run_id": str(resolved_run_id),
        "task_id": str(resolved_task_id),
        "workflow": str(context.get("workflow") or workflow),
        "client": client or context.get("client"),
    }


def _report_path(run_id: str) -> Path:
    safe = _safe_id(run_id)
    matches = sorted(SOMA_AUDIT_RUNS_DIR.glob(f"audit_*_{safe}.json"))
    if matches:
        return matches[-1]
    return SOMA_AUDIT_RUNS_DIR / f"audit_{_stamp()}_{safe}.json"


def _load_json(path: Path) -> dict[str, Any] | None:
    try:
        if path.exists():
            parsed = json.loads(path.read_text(encoding="utf-8"))
            return parsed if isinstance(parsed, dict) else None
    except Exception:
        return None
    return None


def load_report(run_id: str | None = None) -> dict[str, Any] | None:
    if run_id:
        return _load_json(_report_path(run_id))
    return _load_json(SOMA_AUDIT_LATEST)


def _write_report(report: dict[str, Any]) -> dict[str, Any]:
    if not audit_enabled():
        return report
    SOMA_AUDIT_RUNS_DIR.mkdir(parents=True, exist_ok=True)
    SOMA_AUDIT_DIR.mkdir(parents=True, exist_ok=True)
    report["updated_at"] = _now()
    path = _report_path(str(report.get("run_id") or new_run_id()))
    report["audit_report_path"] = str(path)
    rendered = json.dumps(report, indent=2, sort_keys=True, default=str)
    path.write_text(rendered, encoding="utf-8")
    SOMA_AUDIT_LATEST.write_text(rendered, encoding="utf-8")
    return report


def _write_raw_artifacts(
    run_id: str,
    *,
    prompt: str | None = None,
    normalized_prompt: str | None = None,
    packet: str | None = None,
    transcript: str | None = None,
) -> dict[str, str]:
    if not raw_capture_enabled():
        return {}
    raw_dir = SOMA_AUDIT_RAW_DIR / _safe_id(run_id)
    raw_dir.mkdir(parents=True, exist_ok=True)
    artifacts: dict[str, str] = {}
    values = {
        "prompt.txt": prompt,
        "normalized_prompt.txt": normalized_prompt,
        "packet.txt": packet,
        "transcript.txt": transcript,
    }
    for name, text in values.items():
        if text is None:
            continue
        path = raw_dir / name
        path.write_text(text, encoding="utf-8")
        artifacts[name.removesuffix(".txt")] = str(path)
    return artifacts


def _reference_fragments(text: str) -> list[str]:
    fragments: list[str] = []
    for match in re.findall(r"`([^`]+)`|\"([^\"]+)\"|'([^']+)'", text or ""):
        fragments.extend([part.strip() for part in match if part and part.strip()])
    fragments.extend(
        re.findall(
            r"\b[A-Za-z0-9_./-]+\.(?:swift|py|ts|tsx|js|jsx|go|rs|cpp|cc|h|hpp|java|kt|php|rb|json|jsonl|yaml|yml|toml|md|txt|log)\b",
            text or "",
        )
    )
    fragments.extend(re.findall(r"(?:^|\s)((?:\./|\../)?[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+)", text or ""))
    fragments.extend(
        re.findall(r"\b(?=[A-Za-z0-9_]*[a-z])(?=[A-Za-z0-9_]*[A-Z][A-Za-z0-9_]*[A-Z])[A-Z][A-Za-z0-9_]*\b", text or "")
    )
    cleaned: list[str] = []
    for fragment in fragments:
        value = fragment.strip().strip(".,:)(")
        if value and len(value) <= 180 and value not in cleaned:
            cleaned.append(value)
    return cleaned[:40]


def _candidate_rows(
    project_root: str, discovered: list[dict[str, Any]] | None, repo_index: dict[str, Any] | None
) -> list[dict[str, Any]]:
    rows = (repo_index or {}).get("files") or discovered or []
    result: list[dict[str, Any]] = []
    for item in rows:
        path = str(item.get("path") or "")
        if not path:
            continue
        try:
            rel = os.path.relpath(path, project_root)
        except Exception:
            rel = path
        result.append(
            {
                "path": path,
                "rel": rel,
                "name": os.path.basename(path),
                "stem": os.path.splitext(os.path.basename(path))[0],
                "symbols": [str(symbol) for symbol in (item.get("symbols") or [])],
            }
        )
    return result


def _match_reference(reference: str, rows: list[dict[str, Any]]) -> list[str]:
    ref = reference.lower().strip()
    matches: list[str] = []
    for row in rows:
        values = {
            row["path"].lower(),
            row["rel"].lower(),
            row["name"].lower(),
            row["stem"].lower(),
            *(symbol.lower() for symbol in row["symbols"]),
        }
        if ref in values or any(value.endswith("/" + ref) for value in values):
            matches.append(row["path"])
            continue
        if "." not in ref and "/" not in ref:
            if any(ref == symbol.lower() for symbol in row["symbols"]):
                matches.append(row["path"])
    return list(dict.fromkeys(matches))[:5]


def _reference_kind(reference: str, matches: list[str]) -> str:
    ref = reference.strip()
    lowered = ref.lower()
    if lowered in COMMON_CONCEPT_REFERENCES:
        return "concept"
    has_file_extension = bool(re.search(r"\.[a-z0-9]{1,8}$", lowered))
    looks_absolute_or_relative = ref.startswith(("/", "./", "../", "~"))
    if matches:
        if "/" in ref or has_file_extension or looks_absolute_or_relative:
            return "file"
        return "symbol"
    if "/" in ref and not has_file_extension and not looks_absolute_or_relative:
        return "concept"
    if has_file_extension or looks_absolute_or_relative:
        return "file"
    if re.match(r"^[A-Z][A-Za-z0-9_]{2,}$", ref):
        return "symbol"
    return "concept"


def build_missing_evidence(
    *,
    original_prompt: str,
    normalized_prompt: str,
    project_root: str,
    discovered: list[dict[str, Any]] | None,
    repo_index: dict[str, Any] | None,
    evidence_items: list[dict[str, Any]],
    preflight: dict[str, Any] | None,
    evidence_quality: dict[str, Any] | None,
    graph_result: dict[str, Any] | None = None,
    analysis_stages: list[dict[str, Any]] | None = None,
    next_calls: list[str] | None = None,
) -> dict[str, Any]:
    rows = _candidate_rows(project_root, discovered, repo_index)
    selected = {str(item.get("path") or "") for item in evidence_items}
    references = _reference_fragments(original_prompt) + _reference_fragments(normalized_prompt)
    references = list(dict.fromkeys(references))
    unresolved: list[dict[str, Any]] = []
    missing_files: list[dict[str, Any]] = []
    missing_symbols: list[dict[str, Any]] = []
    unresolved_concepts: list[dict[str, Any]] = []
    found_not_selected: list[dict[str, Any]] = []
    resolved: list[dict[str, Any]] = []
    for reference in references:
        matches = _match_reference(reference, rows)
        kind = _reference_kind(reference, matches)
        if not matches:
            item = {"reference": reference, "reason": "not_found_in_project_index", "kind": kind}
            if kind == "file":
                missing_files.append(item)
                unresolved.append(item)
            elif kind == "symbol":
                missing_symbols.append(item)
                unresolved.append(item)
            else:
                unresolved_concepts.append(
                    {"reference": reference, "reason": "concept_not_resolved_to_project_file", "kind": kind}
                )
        elif not any(path in selected for path in matches):
            found_not_selected.append(
                {"reference": reference, "matched_paths": matches, "reason": "found_but_not_selected", "kind": kind}
            )
        else:
            resolved.append(
                {"reference": reference, "matched_paths": [path for path in matches if path in selected], "kind": kind}
            )

    skipped_stages: list[dict[str, Any]] = []
    if graph_result is not None and not graph_result.get("graphs"):
        skipped_stages.append({"stage": "graphify", "status": "skipped", "reason": "no_project_graph"})
    for stage in analysis_stages or []:
        if isinstance(stage, dict) and stage.get("status") not in {None, "ok"}:
            skipped_stages.append(
                {
                    "stage": stage.get("stage"),
                    "status": stage.get("status"),
                    "reason": stage.get("error") or stage.get("reason"),
                }
            )

    return {
        "status": "ok"
        if not missing_files and not missing_symbols and (evidence_quality or {}).get("status") == "ok"
        else "degraded",
        "unresolved_references": unresolved[:12],
        "missing_files": missing_files[:12],
        "missing_symbols": missing_symbols[:12],
        "unresolved_concepts": unresolved_concepts[:12],
        "found_not_selected": found_not_selected[:12],
        "resolved_references": resolved[:12],
        "quality_warnings": ((evidence_quality or {}).get("warnings") or [])[:8],
        "skipped_stages": skipped_stages[:8],
        "requested_extra_context": (next_calls or [])[:6],
        "explicit_paths_found": (preflight or {}).get("explicit_paths") or [],
    }


def selected_evidence_summary(evidence_items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "path": item.get("path"),
            "kind": item.get("kind"),
            "reason": item.get("reason"),
            "symbols": (item.get("symbols") or [])[:8],
            "start_line": item.get("start_line"),
            "end_line": item.get("end_line"),
        }
        for item in evidence_items[:12]
    ]


def build_prepare_audit(
    *,
    context: dict[str, Any],
    status: str,
    project_root: str | None,
    project_type: str | None,
    original_prompt: str,
    normalized_prompt: str,
    packet: str,
    estimated_tokens: int | None,
    evidence_items: list[dict[str, Any]],
    missing_evidence: dict[str, Any],
    evidence_quality: dict[str, Any] | None,
    tool_calls_expected: list[str],
    language_optimization: dict[str, Any] | None,
) -> dict[str, Any]:
    run_id = str(context["run_id"])
    raw_artifacts = _write_raw_artifacts(
        run_id, prompt=original_prompt, normalized_prompt=normalized_prompt, packet=packet
    )
    created_at = _now()
    return {
        "run_id": run_id,
        "task_id": str(context["task_id"]),
        "workflow": str(context.get("workflow") or "packet_mode"),
        "client": context.get("client"),
        "status": status,
        "created_at": created_at,
        "project_root": project_root,
        "project_type": project_type,
        "prompt_hash": _sha(original_prompt),
        "normalized_prompt_hash": _sha(normalized_prompt),
        "packet_hash": _sha(packet),
        "prompt_chars": len(original_prompt or ""),
        "normalized_prompt_chars": len(normalized_prompt or ""),
        "packet_chars": len(packet or ""),
        "estimated_tokens": estimated_tokens,
        "raw_capture_enabled": raw_capture_enabled(),
        "raw_artifacts": raw_artifacts,
        "language_optimization": language_optimization or {},
        "selected_evidence": selected_evidence_summary(evidence_items),
        "missing_evidence": missing_evidence,
        "evidence_quality": evidence_quality or {},
        "tool_calls_expected": tool_calls_expected,
        "tool_calls": [],
        "events": [
            {
                "ts": created_at,
                "event": "audit_start",
                "status": "ok",
                "prompt_hash": _sha(original_prompt),
                "normalized_prompt_hash": _sha(normalized_prompt),
            }
        ],
        "quality_review": None,
    }


def write_prepare_audit(report: dict[str, Any]) -> dict[str, Any]:
    if not audit_enabled():
        return report
    _write_report(report)
    write_audit_log_event(
        "audit_packet_created",
        status=report.get("status", "ok"),
        run_id=report.get("run_id"),
        task_id=report.get("task_id"),
        workflow=report.get("workflow"),
        project_root=report.get("project_root"),
        extra={
            "prompt_hash": report.get("prompt_hash"),
            "packet_hash": report.get("packet_hash"),
            "evidence_count": len(report.get("selected_evidence") or []),
            "missing_evidence_status": (report.get("missing_evidence") or {}).get("status"),
            "raw_capture_enabled": report.get("raw_capture_enabled"),
        },
    )
    missing = report.get("missing_evidence") or {}
    if missing.get("status") == "degraded":
        write_audit_log_event(
            "audit_missing_evidence",
            status="degraded",
            run_id=report.get("run_id"),
            task_id=report.get("task_id"),
            workflow=report.get("workflow"),
            project_root=report.get("project_root"),
            extra={
                "unresolved_count": len(missing.get("unresolved_references") or []),
                "found_not_selected_count": len(missing.get("found_not_selected") or []),
            },
        )
    write_audit_log_event(
        "audit_finish",
        status=report.get("status", "ok"),
        run_id=report.get("run_id"),
        task_id=report.get("task_id"),
        workflow=report.get("workflow"),
        project_root=report.get("project_root"),
        extra={"packet_hash": report.get("packet_hash"), "raw_capture_enabled": report.get("raw_capture_enabled")},
    )
    return report


def compact_response_audit(report: dict[str, Any]) -> dict[str, Any]:
    return {
        "run_id": report.get("run_id"),
        "task_id": report.get("task_id"),
        "workflow": report.get("workflow"),
        "project_root": report.get("project_root"),
        "project_type": report.get("project_type"),
        "prompt_hash": report.get("prompt_hash"),
        "normalized_prompt_hash": report.get("normalized_prompt_hash"),
        "packet_hash": report.get("packet_hash"),
        "selected_evidence": report.get("selected_evidence") or [],
        "missing_evidence": report.get("missing_evidence") or {},
        "evidence_quality": report.get("evidence_quality") or {},
        "tool_calls_expected": report.get("tool_calls_expected") or [],
        "next_calls": report.get("tool_calls_expected") or [],
        "raw_capture_enabled": report.get("raw_capture_enabled") or False,
        "audit_report_path": report.get("audit_report_path"),
    }


def append_event(run_id: str | None, event: dict[str, Any]) -> None:
    if not audit_enabled() or not run_id:
        return
    report = load_report(str(run_id))
    if not report:
        return
    entry = {"ts": _now(), **event}
    report.setdefault("events", []).append(entry)
    if event.get("event") == "tool_call":
        report.setdefault("tool_calls", []).append(
            {
                "ts": entry["ts"],
                "tool": event.get("tool"),
                "status": event.get("status"),
                "duration_ms": event.get("duration_ms"),
                "input_tokens": event.get("input_tokens"),
                "output_tokens": event.get("output_tokens"),
                "packet_tokens": event.get("packet_tokens"),
                "prompt_hash": event.get("prompt_hash"),
                "packet_hash": event.get("packet_hash"),
            }
        )
    _write_report(report)


def write_audit_log_event(
    event: str,
    *,
    status: str = "ok",
    run_id: str | None = None,
    task_id: str | None = None,
    workflow: str | None = None,
    project_root: str | None = None,
    extra: dict[str, Any] | None = None,
) -> None:
    try:
        from soma_logger import log_mcp_event

        payload = {"run_id": run_id, "task_id": task_id, "workflow": workflow}
        if extra:
            payload.update(extra)
        log_mcp_event(
            event=event,
            status=status,
            project_root=project_root,
            extra={k: v for k, v in payload.items() if v is not None},
        )
    except Exception:
        pass


def mark_quality(run_id: str, status: str, notes: str = "") -> dict[str, Any]:
    if status not in {"accepted", "wrong", "needs_more_evidence"}:
        raise ValueError("status must be accepted, wrong, or needs_more_evidence")
    report = load_report(run_id)
    if not report:
        raise FileNotFoundError(f"No audit report for run_id: {run_id}")
    mapped = {"accepted": "ok", "wrong": "failed", "needs_more_evidence": "degraded"}[status]
    review = {"status": status, "notes": notes, "reviewed_at": _now(), "source": "manual"}
    report["quality_review"] = review
    report["status"] = mapped
    _write_report(report)
    write_audit_log_event(
        "audit_quality_review",
        status=mapped,
        run_id=report.get("run_id"),
        task_id=report.get("task_id"),
        workflow=report.get("workflow"),
        project_root=report.get("project_root"),
        extra={"quality_status": status, "notes_hash": _sha(notes) if notes else None},
    )
    return report


def purge_old_audit() -> None:
    try:
        report_cutoff = time.time() - int(os.environ.get("SOMA_AUDIT_RETENTION_DAYS", "14")) * 86400
        raw_cutoff = time.time() - int(os.environ.get("SOMA_AUDIT_RAW_RETENTION_DAYS", "7")) * 86400
        for path in SOMA_AUDIT_RUNS_DIR.glob("audit_*.json"):
            if path.stat().st_mtime < report_cutoff:
                path.unlink(missing_ok=True)
        for path in SOMA_AUDIT_RAW_DIR.glob("*"):
            if path.stat().st_mtime < raw_cutoff and path.is_dir():
                for child in path.glob("*"):
                    child.unlink(missing_ok=True)
                path.rmdir()
    except Exception:
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect or mark Soma task audit reports.")
    parser.add_argument("--latest", action="store_true", help="Print latest audit report.")
    parser.add_argument("--run", default=None, help="Print audit report for run_id.")
    parser.add_argument("--mark", default=None, help="Mark quality status for run_id.")
    parser.add_argument("--status", choices=["accepted", "wrong", "needs_more_evidence"], default=None)
    parser.add_argument("--notes", default="")
    args = parser.parse_args()

    if args.mark:
        if not args.status:
            parser.error("--mark requires --status")
        print(json.dumps(mark_quality(args.mark, args.status, args.notes), indent=2, sort_keys=True, default=str))
        return 0
    report = load_report(args.run if args.run else None)
    if not report:
        print(json.dumps({"status": "not_found", "run_id": args.run}))
        return 1
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
