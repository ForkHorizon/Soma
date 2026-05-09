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
        "errors": [],
    })

    slowest: list[dict[str, Any]] = []
    budget_hits: dict[str, int] = defaultdict(int)
    budget_total: dict[str, int] = defaultdict(int)

    for e in tool_calls:
        tool = e.get("tool", "unknown")
        status = e.get("status", "ok")
        dur = e.get("duration_ms", 0) or 0
        in_tok = e.get("input_tokens", 0) or 0
        out_tok = e.get("output_tokens", 0) or 0
        budget = e.get("budget")

        s = per_tool[tool]
        s["calls"] += 1
        s[status if status in {"ok", "error", "degraded"} else "error"] += 1
        s["total_duration_ms"] += dur
        s["total_input_tokens"] += in_tok
        s["total_output_tokens"] += out_tok
        if e.get("error"):
            s["errors"] = (s["errors"] + [e["error"][:120]])[-5:]

        slowest.append({"tool": tool, "duration_ms": dur, "status": status, "ts": e.get("ts", "")})

        if budget:
            budget_total[budget] += 1
            limit = TOKEN_BUDGETS.get(budget, 6000)
            if out_tok >= limit * 0.9:
                budget_hits[budget] += 1

    # Compute averages
    for tool, s in per_tool.items():
        calls = s["calls"] or 1
        s["avg_duration_ms"] = round(s["total_duration_ms"] / calls, 1)
        s["error_rate"] = round((s["error"] + s["degraded"]) / calls, 3)

    # Top slowest calls
    slowest_top = sorted(slowest, key=lambda x: x["duration_ms"], reverse=True)[:10]

    # Budget utilization
    budget_utilization = {}
    for budget, total in budget_total.items():
        hits = budget_hits.get(budget, 0)
        budget_utilization[budget] = {
            "total_calls": total,
            "near_limit_calls": hits,
            "utilization_pct": round(100 * hits / max(total, 1), 1),
        }

    # Totals
    total_calls = sum(s["calls"] for s in per_tool.values())
    total_input_tokens = sum(s["total_input_tokens"] for s in per_tool.values())
    total_output_tokens = sum(s["total_output_tokens"] for s in per_tool.values())
    total_errors = sum(s["error"] + s["degraded"] for s in per_tool.values())
    server_starts = sum(1 for e in entries if e.get("event") == "server_start")

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
            "error_count": total_errors,
            "server_starts": server_starts,
        },
        "per_tool": dict(per_tool),
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
