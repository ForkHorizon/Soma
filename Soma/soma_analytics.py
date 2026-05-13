#!/usr/bin/env python3
"""
soma_analytics.py — Daily analytics report from Soma structured logs.

Reads ~/.soma/logs/soma_*.jsonl, computes per-tool stats, token flow,
budget utilization, error rates, and slowest calls.
Outputs to ~/.soma/analytics/daily_report.json.

CLI: python3 soma_analytics.py --report today
     python3 soma_analytics.py --report 20260508
     python3 soma_analytics.py --summary
"""
from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SOMA_LOG_DIR = Path.home() / ".soma" / "logs"
SOMA_ANALYTICS_DIR = Path.home() / ".soma" / "analytics"
SOMA_TOKEN_STATS_FILE = Path.home() / ".soma" / "token_stats.json"
SOMA_AGENT_BENCHMARK_FILE = Path.home() / ".soma" / "agent_benchmarks" / "latest.json"
TOKEN_BUDGETS = {"micro": 1000, "fast": 2500, "balanced": 6000, "deep": 15000, "full": 30000}


# ── Parser ────────────────────────────────────────────────────────────────────

def _read_entries(date_str: str) -> list[dict[str, Any]]:
    log_file = SOMA_LOG_DIR / f"soma_{date_str}.jsonl"
    if not log_file.exists():
        return []
    entries = []
    for line in log_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return entries


# ── Aggregation ───────────────────────────────────────────────────────────────

def compute_report(date_str: str) -> dict[str, Any]:
    entries = _read_entries(date_str)
    tool_calls = [e for e in entries if e.get("event") == "tool_call"]
    mcp_requests = [e for e in entries if e.get("event") == "mcp_request"]

    if not entries:
        return {"date": date_str, "status": "no_data", "message": f"No log file for {date_str}"}

    # Per-tool stats
    per_tool: dict[str, dict[str, Any]] = defaultdict(lambda: {
        "calls": 0, "ok": 0, "error": 0, "degraded": 0,
        "total_duration_ms": 0.0, "avg_duration_ms": 0.0,
        "total_input_tokens": 0, "total_output_tokens": 0,
        "errors": [], "project_types": defaultdict(int),
        "packet_modes": defaultdict(int), "evidence_count": 0,
        "discovered_files": 0, "total_saved_tokens": 0,
        "savings_samples": [], "budget_used_samples": [],
        "operation_saved_tokens": 0, "operation_savings_samples": [],
        "estimated_context_saved_tokens": 0, "estimated_context_samples": [],
    })

    slowest: list[dict[str, Any]] = []
    budget_hits: dict[str, int] = defaultdict(int)
    budget_over: dict[str, int] = defaultdict(int)
    budget_total: dict[str, int] = defaultdict(int)

    for e in tool_calls:
        tool = e.get("tool", "unknown")
        status = e.get("status", "ok")
        dur = e.get("duration_ms", 0) or 0
        in_tok = e.get("input_tokens", 0) or 0
        out_tok = e.get("output_tokens", 0) or 0
        budget = e.get("budget")
        project_type = e.get("project_type")
        packet_mode = e.get("packet_mode")
        saved_tokens = e.get("saved_tokens")
        savings_pct = e.get("savings_pct")
        budget_used_pct = e.get("budget_used_pct")
        op_saved = e.get("operation_saved_tokens")
        op_pct = e.get("operation_savings_pct")
        est_saved = e.get("estimated_context_saved_tokens")
        est_pct = e.get("estimated_context_reduction_pct")

        s = per_tool[tool]
        s["calls"] += 1
        s[status if status in {"ok", "error", "degraded"} else "error"] += 1
        s["total_duration_ms"] += dur
        s["total_input_tokens"] += in_tok
        s["total_output_tokens"] += out_tok
        if e.get("error"):
            s["errors"] = (s["errors"] + [e["error"][:120]])[-5:]
        if project_type:
            s["project_types"][project_type] += 1
        if packet_mode:
            s["packet_modes"][packet_mode] += 1
        s["evidence_count"] += e.get("evidence_count", 0) or 0
        s["discovered_files"] += e.get("discovered_files", 0) or 0
        if isinstance(saved_tokens, (int, float)):
            s["total_saved_tokens"] += int(saved_tokens)
        if isinstance(savings_pct, (int, float)):
            s["savings_samples"].append(float(savings_pct))
        if isinstance(budget_used_pct, (int, float)):
            s["budget_used_samples"].append(float(budget_used_pct))
        if isinstance(op_saved, (int, float)):
            s["operation_saved_tokens"] += int(op_saved)
        if isinstance(op_pct, (int, float)):
            s["operation_savings_samples"].append(float(op_pct))
        if isinstance(est_saved, (int, float)):
            s["estimated_context_saved_tokens"] += int(est_saved)
        if isinstance(est_pct, (int, float)):
            s["estimated_context_samples"].append(float(est_pct))

        slowest.append({"tool": tool, "duration_ms": dur, "status": status, "ts": e.get("ts", "")})

        if budget:
            budget_total[budget] += 1
            limit = TOKEN_BUDGETS.get(budget, 6000)
            packet_tokens = e.get("packet_tokens") or out_tok
            if packet_tokens >= limit * 0.9:
                budget_hits[budget] += 1
            if packet_tokens > limit:
                budget_over[budget] += 1

    # Compute averages
    for tool, s in per_tool.items():
        calls = s["calls"] or 1
        s["avg_duration_ms"] = round(s["total_duration_ms"] / calls, 1)
        s["error_rate"] = round((s["error"] + s["degraded"]) / calls, 3)
        s["project_types"] = dict(s["project_types"])
        s["packet_modes"] = dict(s["packet_modes"])
        s["avg_savings_pct"] = round(sum(s["savings_samples"]) / max(len(s["savings_samples"]), 1), 1) if s["savings_samples"] else None
        s["avg_budget_used_pct"] = round(sum(s["budget_used_samples"]) / max(len(s["budget_used_samples"]), 1), 1) if s["budget_used_samples"] else None
        s["avg_operation_savings_pct"] = round(sum(s["operation_savings_samples"]) / max(len(s["operation_savings_samples"]), 1), 1) if s["operation_savings_samples"] else None
        s["avg_estimated_context_reduction_pct"] = round(sum(s["estimated_context_samples"]) / max(len(s["estimated_context_samples"]), 1), 1) if s["estimated_context_samples"] else None
        s.pop("savings_samples", None)
        s.pop("budget_used_samples", None)
        s.pop("operation_savings_samples", None)
        s.pop("estimated_context_samples", None)

    # Top slowest calls
    slowest_top = sorted(slowest, key=lambda x: x["duration_ms"], reverse=True)[:10]

    # Budget utilization
    budget_utilization = {}
    for budget, total in budget_total.items():
        hits = budget_hits.get(budget, 0)
        budget_utilization[budget] = {
            "total_calls": total,
            "near_limit_calls": hits,
            "over_limit_calls": budget_over.get(budget, 0),
            "utilization_pct": round(100 * hits / max(total, 1), 1),
        }

    # Totals
    total_calls = sum(s["calls"] for s in per_tool.values())
    total_input_tokens = sum(s["total_input_tokens"] for s in per_tool.values())
    total_output_tokens = sum(s["total_output_tokens"] for s in per_tool.values())
    total_errors = sum(s["error"] + s["degraded"] for s in per_tool.values())
    total_saved_tokens = sum(s.get("total_saved_tokens", 0) for s in per_tool.values())
    savings_values = [e.get("savings_pct") for e in tool_calls if isinstance(e.get("savings_pct"), (int, float))]
    avg_savings_pct = round(sum(savings_values) / max(len(savings_values), 1), 1) if savings_values else None
    operation_saved_tokens = sum(s.get("operation_saved_tokens", 0) for s in per_tool.values())
    operation_values = [e.get("operation_savings_pct") for e in tool_calls if isinstance(e.get("operation_savings_pct"), (int, float))]
    avg_operation_savings_pct = round(sum(operation_values) / max(len(operation_values), 1), 1) if operation_values else None
    estimated_saved_tokens = sum(s.get("estimated_context_saved_tokens", 0) for s in per_tool.values())
    estimated_values = [e.get("estimated_context_reduction_pct") for e in tool_calls if isinstance(e.get("estimated_context_reduction_pct"), (int, float))]
    avg_estimated_context_reduction_pct = round(sum(estimated_values) / max(len(estimated_values), 1), 1) if estimated_values else None
    server_starts = sum(1 for e in entries if e.get("event") == "server_start")
    savings_by_project_type: dict[str, dict[str, Any]] = defaultdict(lambda: {"calls": 0, "total_saved_tokens": 0, "savings_samples": []})
    for e in tool_calls:
        project_type = e.get("project_type") or "unknown"
        saved = e.get("saved_tokens")
        pct = e.get("savings_pct")
        if isinstance(saved, (int, float)) or isinstance(pct, (int, float)):
            bucket = savings_by_project_type[project_type]
            bucket["calls"] += 1
            if isinstance(saved, (int, float)):
                bucket["total_saved_tokens"] += int(saved)
            if isinstance(pct, (int, float)):
                bucket["savings_samples"].append(float(pct))
    for bucket in savings_by_project_type.values():
        samples = bucket.pop("savings_samples", [])
        bucket["avg_savings_pct"] = round(sum(samples) / max(len(samples), 1), 1) if samples else None
    latest_benchmark = None
    try:
        if SOMA_TOKEN_STATS_FILE.exists():
            stats = json.loads(SOMA_TOKEN_STATS_FILE.read_text(encoding="utf-8"))
            latest_benchmark = {
                "status": stats.get("status"),
                "generated_at": stats.get("generated_at"),
                "model_profile": stats.get("model_profile"),
                "budget": stats.get("budget"),
                "baseline": stats.get("baseline"),
                "summary": stats.get("summary"),
            }
    except Exception:
        latest_benchmark = {"status": "unreadable"}
    latest_agent_benchmark = None
    try:
        if SOMA_AGENT_BENCHMARK_FILE.exists():
            stats = json.loads(SOMA_AGENT_BENCHMARK_FILE.read_text(encoding="utf-8"))
            latest_agent_benchmark = {
                "status": stats.get("status"),
                "generated_at": stats.get("generated_at"),
                "summary": stats.get("summary"),
            }
    except Exception:
        latest_agent_benchmark = {"status": "unreadable"}

    report = {
        "date": date_str,
        "generated_at": datetime.now(tz=timezone.utc).isoformat(),
        "status": "ok",
        "summary": {
            "total_tool_calls": total_calls,
            "total_mcp_requests": len(mcp_requests),
            "total_input_tokens": total_input_tokens,
            "total_output_tokens": total_output_tokens,
            "total_tokens": total_input_tokens + total_output_tokens,
            "total_saved_tokens": total_saved_tokens,
            "avg_savings_pct": avg_savings_pct,
            "operation_saved_tokens": operation_saved_tokens,
            "avg_operation_savings_pct": avg_operation_savings_pct,
            "estimated_context_saved_tokens": estimated_saved_tokens,
            "avg_estimated_context_reduction_pct": avg_estimated_context_reduction_pct,
            "error_count": total_errors,
            "server_starts": server_starts,
        },
        "per_tool": dict(per_tool),
        "savings_by_project_type": dict(savings_by_project_type),
        "latest_token_benchmark": latest_benchmark,
        "latest_agent_benchmark": latest_agent_benchmark,
        "slowest_calls": slowest_top,
        "budget_utilization": budget_utilization,
    }

    # Persist
    SOMA_ANALYTICS_DIR.mkdir(parents=True, exist_ok=True)
    out_file = SOMA_ANALYTICS_DIR / f"report_{date_str}.json"
    out_file.write_text(json.dumps(report, indent=2, default=str))

    return report


def compute_multiday_summary(days: int = 7) -> dict[str, Any]:
    """Aggregate stats across the last N days."""
    now = datetime.now(tz=timezone.utc)
    totals: dict[str, Any] = {
        "days_with_data": 0, "total_tool_calls": 0,
        "total_tokens": 0, "total_errors": 0,
        "per_tool_calls": defaultdict(int),
        "date_range": [],
    }
    for i in range(days):
        from datetime import timedelta
        date = now - timedelta(days=i)
        date_str = date.strftime("%Y%m%d")
        report = compute_report(date_str)
        if report.get("status") == "no_data":
            continue
        totals["days_with_data"] += 1
        totals["date_range"].append(date_str)
        s = report.get("summary", {})
        totals["total_tool_calls"] += s.get("total_tool_calls", 0)
        totals["total_tokens"] += s.get("total_tokens", 0)
        totals["total_errors"] += s.get("error_count", 0)
        for tool, stats in report.get("per_tool", {}).items():
            totals["per_tool_calls"][tool] += stats.get("calls", 0)
    totals["per_tool_calls"] = dict(totals["per_tool_calls"])
    totals["date_range"].sort()
    return totals


# ── Formatting ────────────────────────────────────────────────────────────────

def _print_report(report: dict[str, Any]) -> None:
    if report.get("status") == "no_data":
        print(f"No data for {report['date']}")
        return

    s = report["summary"]
    print(f"\n{'='*60}")
    print(f"Soma Analytics — {report['date']}")
    print(f"{'='*60}")
    print(f"Tool calls:     {s['total_tool_calls']}")
    print(f"Total tokens:   {s['total_tokens']:,}  (in:{s['total_input_tokens']:,} out:{s['total_output_tokens']:,})")
    if s.get("avg_operation_savings_pct") is not None:
        print(f"Operation save: {s['operation_saved_tokens']:,} saved avg {s['avg_operation_savings_pct']:.1f}%")
    if s.get("avg_estimated_context_reduction_pct") is not None:
        print(f"Context reduce: {s['estimated_context_saved_tokens']:,} estimated avg {s['avg_estimated_context_reduction_pct']:.1f}%")
    print(f"Errors:         {s['error_count']}")
    print(f"Server starts:  {s['server_starts']}")
    print()

    print("Per-tool breakdown:")
    for tool, ts in sorted(report["per_tool"].items(), key=lambda x: -x[1]["calls"]):
        err_str = f" ERR:{ts['error']+ts['degraded']}" if (ts['error'] + ts['degraded']) > 0 else ""
        print(f"  {tool:<30} {ts['calls']:>4} calls  {ts['avg_duration_ms']:>7.0f}ms avg  "
              f"{ts['total_input_tokens']+ts['total_output_tokens']:>6} tok{err_str}")

    if report["slowest_calls"]:
        print("\nTop slowest calls:")
        for c in report["slowest_calls"][:5]:
            print(f"  {c['tool']:<30} {c['duration_ms']:>7.0f}ms  {c['status']}  {c['ts'][:19]}")

    if report["budget_utilization"]:
        print("\nBudget utilization (near-limit %):")
        for budget, bu in report["budget_utilization"].items():
            print(f"  {budget:<12} {bu['total_calls']:>4} calls  {bu['utilization_pct']:>5.1f}% near limit")
    print()


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Soma analytics reporter")
    parser.add_argument("--report", default=None,
                        help="Date to report: 'today', 'yesterday', or YYYYMMDD")
    parser.add_argument("--summary", action="store_true",
                        help="7-day rolling summary")
    parser.add_argument("--json", action="store_true",
                        help="Output raw JSON instead of formatted text")
    args = parser.parse_args()

    if args.summary:
        data = compute_multiday_summary(7)
        if args.json:
            print(json.dumps(data, indent=2, default=str))
        else:
            print(json.dumps(data, indent=2, default=str))
    elif args.report:
        from datetime import timedelta
        now = datetime.now(tz=timezone.utc)
        if args.report == "today":
            date_str = now.strftime("%Y%m%d")
        elif args.report == "yesterday":
            date_str = (now - timedelta(days=1)).strftime("%Y%m%d")
        else:
            date_str = args.report
        report = compute_report(date_str)
        if args.json:
            print(json.dumps(report, indent=2, default=str))
        else:
            _print_report(report)
    else:
        parser.print_help()
