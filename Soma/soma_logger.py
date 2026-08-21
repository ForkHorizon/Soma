#!/usr/bin/env python3
"""
soma_logger.py — Structured logging and analytics for Soma MCP.

Every tool call, latency, token count, error, and status is written as a
JSON line to ~/.soma/logs/soma_YYYYMMDD.jsonl. Daily rotation, 14-day
retention. Provides @log_tool_call decorator for wrapping soma_* functions.
"""

from __future__ import annotations

import functools
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

try:
    from token_calculator import estimate_tokens as _shared_estimate_tokens
except Exception:
    _shared_estimate_tokens = None

SOMA_LOG_DIR = Path.home() / ".soma" / "logs"
SOMA_LOG_RETENTION_DAYS = 14
SOMA_SESSION_STATS_FILE = SOMA_LOG_DIR / "session_stats.json"


# ── Helpers ───────────────────────────────────────────────────────────────────


def _estimate_tokens(text: str) -> int:
    """Rough 4-chars-per-token estimate."""
    if _shared_estimate_tokens is not None:
        try:
            return _shared_estimate_tokens(text, os.environ.get("SOMA_TOKEN_MODEL_PROFILE", "fallback"))
        except Exception:
            pass
    return max(0, len(text) // 4)


def _today_log_file() -> Path:
    SOMA_LOG_DIR.mkdir(parents=True, exist_ok=True)
    date_str = datetime.now(tz=timezone.utc).strftime("%Y%m%d")
    return SOMA_LOG_DIR / f"soma_{date_str}.jsonl"


def _rotate_old_logs() -> None:
    """Remove JSONL logs older than SOMA_LOG_RETENTION_DAYS."""
    try:
        cutoff = time.time() - SOMA_LOG_RETENTION_DAYS * 86400
        for log_file in SOMA_LOG_DIR.glob("soma_*.jsonl"):
            try:
                if log_file.stat().st_mtime < cutoff:
                    log_file.unlink(missing_ok=True)
            except OSError:
                pass
    except Exception:
        pass


# ── Core write ────────────────────────────────────────────────────────────────


def write_log_entry(entry: dict[str, Any]) -> None:
    """Append a structured log entry to today's JSONL file (fire-and-forget)."""
    try:
        log_file = _today_log_file()
        with log_file.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, default=str) + "\n")
    except Exception:
        pass  # never crash the server due to logging


def log_mcp_event(
    *,
    event: str,
    tool: str | None = None,
    method: str | None = None,
    status: str = "ok",
    duration_ms: float | None = None,
    input_tokens: int | None = None,
    output_tokens: int | None = None,
    error: str | None = None,
    project_root: str | None = None,
    budget: str | None = None,
    depth: str | None = None,
    extra: dict[str, Any] | None = None,
) -> None:
    """Write a single structured log entry."""
    entry: dict[str, Any] = {
        "ts": datetime.now(tz=timezone.utc).isoformat(),
        "event": event,
    }
    if tool:
        entry["tool"] = tool
    if method:
        entry["method"] = method
    entry["status"] = status
    if duration_ms is not None:
        entry["duration_ms"] = round(duration_ms, 1)
    if input_tokens is not None:
        entry["input_tokens"] = input_tokens
    if output_tokens is not None:
        entry["output_tokens"] = output_tokens
    if error:
        entry["error"] = error[:500]
    if project_root:
        entry["project_root"] = project_root
    if budget:
        entry["budget"] = budget
    if depth:
        entry["depth"] = depth
    if extra:
        entry.update(extra)

    write_log_entry(entry)
    _update_session_stats(entry)
    try:
        from soma_audit import append_event

        if entry.get("run_id"):
            append_event(str(entry.get("run_id")), entry)
    except Exception:
        pass


# ── Session stats ─────────────────────────────────────────────────────────────

_session_stats: dict[str, Any] = {}


def _update_session_stats(entry: dict[str, Any]) -> None:
    global _session_stats
    tool = entry.get("tool") or entry.get("method", "unknown")
    status = entry.get("status", "ok")
    dur = entry.get("duration_ms", 0) or 0
    in_tok = entry.get("input_tokens", 0) or 0
    out_tok = entry.get("output_tokens", 0) or 0

    if tool not in _session_stats:
        _session_stats[tool] = {
            "calls": 0,
            "ok": 0,
            "error": 0,
            "degraded": 0,
            "total_duration_ms": 0.0,
            "total_input_tokens": 0,
            "total_output_tokens": 0,
            "errors": [],
        }

    s = _session_stats[tool]
    s["calls"] += 1
    s[status if status in {"ok", "error", "degraded"} else "error"] += 1
    s["total_duration_ms"] += dur
    s["total_input_tokens"] += in_tok
    s["total_output_tokens"] += out_tok
    if status == "error" and entry.get("error"):
        s["errors"] = (s["errors"] + [entry["error"]])[-10:]

    # Persist to file (best-effort)
    try:
        SOMA_LOG_DIR.mkdir(parents=True, exist_ok=True)
        SOMA_SESSION_STATS_FILE.write_text(
            json.dumps(
                {"updated_at": datetime.now(tz=timezone.utc).isoformat(), "tools": _session_stats},
                indent=2,
                default=str,
            )
        )
    except Exception:
        pass


def get_session_stats() -> dict[str, Any]:
    return dict(_session_stats)


# ── Decorator ─────────────────────────────────────────────────────────────────


def log_tool_call(func: Callable) -> Callable:
    """
    Decorator for soma_* async functions.
    Measures latency, estimates token counts, and logs each call.
    """
    tool_name = func.__name__

    @functools.wraps(func)
    async def wrapper(*args: Any, **kwargs: Any) -> str:
        # Estimate input tokens from args
        input_text = json.dumps({"args": args, "kwargs": kwargs}, default=str)
        input_tokens = _estimate_tokens(input_text)

        # Extract common params for richer logging
        project_root = kwargs.get("project_root") or os.environ.get("SOMA_PROJECT_ROOT")
        budget = kwargs.get("budget")
        depth = kwargs.get("depth")

        start = time.monotonic()
        status = "ok"
        error_msg: str | None = None
        result_text = ""
        parsed_result: dict[str, Any] = {}

        try:
            result_text = await func(*args, **kwargs)
            # Parse status from result if it's our compact JSON format
            try:
                parsed = json.loads(result_text)
                if isinstance(parsed, dict):
                    parsed_result = parsed
                    status = parsed.get("status", "ok")
            except Exception:
                pass
        except Exception as exc:
            status = "error"
            error_msg = str(exc)
            result_text = json.dumps({"status": "error", "summary": error_msg})
            raise
        finally:
            duration_ms = (time.monotonic() - start) * 1000
            output_tokens = _estimate_tokens(result_text)
            omitted = parsed_result.get("omitted") if isinstance(parsed_result, dict) else {}
            evidence = parsed_result.get("evidence") if isinstance(parsed_result, dict) else []
            analysis_stages = parsed_result.get("analysis_stages") if isinstance(parsed_result, dict) else []
            local_ai_metrics = parsed_result.get("local_ai_metrics") if isinstance(parsed_result, dict) else {}
            token_savings = parsed_result.get("token_savings") if isinstance(parsed_result, dict) else {}
            language_optimization = (
                parsed_result.get("language_optimization") if isinstance(parsed_result, dict) else {}
            )
            if not isinstance(token_savings, dict):
                token_savings = {}
            if not isinstance(language_optimization, dict):
                language_optimization = {}
            if not isinstance(local_ai_metrics, dict):
                local_ai_metrics = {}
            operation_savings = parsed_result.get("operation_savings") or token_savings.get("operation_savings")
            estimated_context = parsed_result.get("estimated_context_reduction") or token_savings.get(
                "estimated_context_reduction"
            )
            if not isinstance(operation_savings, dict):
                operation_savings = {}
            if not isinstance(estimated_context, dict):
                estimated_context = {}
            audit = parsed_result.get("audit") if isinstance(parsed_result, dict) else {}
            if not isinstance(audit, dict):
                audit = {}
            try:
                from soma_audit import current_context

                audit_context = current_context()
            except Exception:
                audit_context = {}
            run_id = audit.get("run_id") or audit_context.get("run_id")
            task_id = audit.get("task_id") or audit_context.get("task_id")
            workflow = audit.get("workflow") or audit_context.get("workflow")
            client = audit_context.get("client")
            extra = {
                "run_id": run_id,
                "task_id": task_id,
                "workflow": workflow,
                "client": client,
                "prompt_hash": audit.get("prompt_hash"),
                "packet_hash": audit.get("packet_hash"),
                "project_type": parsed_result.get("project_type"),
                "packet_mode": parsed_result.get("packet_mode") or parsed_result.get("mode"),
                "estimated_tokens": parsed_result.get("estimated_tokens"),
                "evidence_count": len(evidence) if isinstance(evidence, list) else None,
                "discovered_files": omitted.get("discovered_files") if isinstance(omitted, dict) else None,
                "git_changed_file_count": omitted.get("git_changed_file_count") if isinstance(omitted, dict) else None,
                "analysis_depth": parsed_result.get("depth") or parsed_result.get("analysis_depth"),
                "analysis_stage_statuses": {
                    str(stage.get("stage")): stage.get("status")
                    for stage in analysis_stages
                    if isinstance(stage, dict) and stage.get("stage")
                }
                if isinstance(analysis_stages, list)
                else None,
                "packet_tokens": token_savings.get("packet_tokens"),
                "budget_used_pct": token_savings.get("budget_used_pct"),
                "saved_tokens": token_savings.get("saved_tokens"),
                "savings_pct": token_savings.get("savings_pct"),
                "baseline_type": token_savings.get("baseline_type"),
                "primary_metric": token_savings.get("primary_metric"),
                "token_estimator": token_savings.get("estimator"),
                "operation_saved_tokens": operation_savings.get("saved_tokens"),
                "operation_savings_pct": operation_savings.get("savings_pct"),
                "operation_baseline_tokens": operation_savings.get("operation_baseline_tokens")
                or operation_savings.get("baseline_tokens"),
                "soma_response_tokens": operation_savings.get("soma_response_tokens"),
                "estimated_context_saved_tokens": estimated_context.get("saved_tokens"),
                "estimated_context_reduction_pct": estimated_context.get("savings_pct"),
                "estimated_context_baseline_tokens": estimated_context.get("baseline_tokens"),
                "source_language": language_optimization.get("source_language"),
                "translation_status": language_optimization.get("status"),
                "translation_engine": language_optimization.get("engine"),
                "prompt_saved_tokens": language_optimization.get("saved_tokens"),
                "prompt_savings_pct": language_optimization.get("savings_pct"),
                "protected_spans_count": language_optimization.get("protected_spans_count"),
                "local_ai_policy": local_ai_metrics.get("local_ai_policy"),
                "local_ai_call_count": local_ai_metrics.get("local_ai_call_count"),
                "local_ai_input_tokens": local_ai_metrics.get("local_ai_input_tokens"),
                "local_ai_output_tokens": local_ai_metrics.get("local_ai_output_tokens"),
                "local_ai_latency_ms": local_ai_metrics.get("local_ai_latency_ms"),
                "candidate_tokens_before": local_ai_metrics.get("candidate_tokens_before"),
                "candidate_tokens_after": local_ai_metrics.get("candidate_tokens_after"),
                "local_ai_net_savings_tokens": local_ai_metrics.get("local_ai_net_savings_tokens"),
                "output_truncated": omitted.get("output_truncated") if isinstance(omitted, dict) else None,
                "omitted_output_tokens": omitted.get("omitted_output_tokens") if isinstance(omitted, dict) else None,
            }
            log_mcp_event(
                event="tool_call",
                tool=tool_name,
                status=status,
                duration_ms=duration_ms,
                input_tokens=input_tokens,
                output_tokens=output_tokens,
                error=error_msg,
                project_root=project_root,
                budget=budget,
                depth=depth,
                extra={key: value for key, value in extra.items() if value is not None},
            )

        return result_text

    return wrapper


# ── MCP request/response logging ──────────────────────────────────────────────


def log_mcp_request(method: str, req_id: Any, params_size: int, extra: dict[str, Any] | None = None) -> float:
    """Log an incoming MCP request. Returns the start timestamp."""
    start = time.monotonic()
    log_mcp_event(
        event="mcp_request",
        method=method,
        status="received",
        extra={"req_id": req_id, "params_chars": params_size, **(extra or {})},
    )
    return start


def log_mcp_response(
    method: str, req_id: Any, start: float, status: str, output_size: int, extra: dict[str, Any] | None = None
) -> None:
    """Log an outgoing MCP response."""
    duration_ms = (time.monotonic() - start) * 1000
    log_mcp_event(
        event="mcp_response",
        method=method,
        status=status,
        duration_ms=duration_ms,
        output_tokens=_estimate_tokens("x" * output_size),
        extra={"req_id": req_id, "output_chars": output_size, **(extra or {})},
    )


# ── Server lifecycle ──────────────────────────────────────────────────────────


def log_server_start(project_root: str | None, pid: int) -> None:
    _rotate_old_logs()
    log_mcp_event(
        event="server_start",
        status="ok",
        project_root=project_root,
        extra={"pid": pid},
    )


def log_server_stop(pid: int, reason: str = "stdin_closed") -> None:
    log_mcp_event(
        event="server_stop",
        status="ok",
        extra={"pid": pid, "reason": reason, "session_summary": _session_stats},
    )


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Soma logger CLI")
    parser.add_argument("--tail", type=int, default=20, help="Tail N log entries from today")
    parser.add_argument("--stats", action="store_true", help="Show session stats")
    parser.add_argument("--date", default=None, help="Date to read (YYYYMMDD), default today")
    parser.add_argument("--server-stop-pid", type=int, default=None, help="Write a server_stop event for PID")
    parser.add_argument("--reason", default="swift_stop", help="Reason for --server-stop-pid")
    args = parser.parse_args()

    if args.server_stop_pid is not None:
        log_server_stop(args.server_stop_pid, args.reason)
        print(json.dumps({"status": "ok", "event": "server_stop", "pid": args.server_stop_pid}))
    elif args.stats:
        stats_file = SOMA_SESSION_STATS_FILE
        if stats_file.exists():
            print(stats_file.read_text())
        else:
            print(json.dumps({"message": "No session stats yet."}))
    else:
        date_str = args.date or datetime.now(tz=timezone.utc).strftime("%Y%m%d")
        log_file = SOMA_LOG_DIR / f"soma_{date_str}.jsonl"
        if not log_file.exists():
            print(json.dumps({"message": f"No log file for {date_str}"}))
        else:
            lines = log_file.read_text(encoding="utf-8").splitlines()
            for line in lines[-args.tail :]:
                try:
                    entry = json.loads(line)
                    ts = entry.get("ts", "")[:19]
                    event = entry.get("event", "?")
                    tool = entry.get("tool") or entry.get("method", "")
                    status = entry.get("status", "?")
                    dur = entry.get("duration_ms")
                    tok_in = entry.get("input_tokens", 0)
                    tok_out = entry.get("output_tokens", 0)
                    dur_str = f" {dur:.0f}ms" if dur else ""
                    tok_str = f" [{tok_in}→{tok_out} tok]" if tok_in or tok_out else ""
                    err_str = f" ERR:{entry['error'][:60]}" if entry.get("error") else ""
                    print(f"{ts}  {event:<16} {tool:<28} {status:<10}{dur_str}{tok_str}{err_str}")
                except Exception:
                    print(line)
