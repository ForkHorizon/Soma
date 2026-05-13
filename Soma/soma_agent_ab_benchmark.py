#!/usr/bin/env python3
"""Run read-only direct-vs-Soma agent token benchmarks.

This harness measures observed agent usage separately from Soma's internal
context-reduction estimates. It prefers real token usage emitted by the local
CLI JSON streams and falls back to transcript token estimates when the CLI does
not expose usage.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from token_calculator import estimate_payload, estimate_tokens


BENCHMARK_DIR = Path.home() / ".soma" / "agent_benchmarks"
DEFAULT_AGENTS = ("codex", "gemini")


def _server_script() -> str:
    return str(Path(__file__).with_name("soma_mcp_server.py"))


def _sha256(text: str) -> str:
    return hashlib.sha256((text or "").encode("utf-8", errors="replace")).hexdigest()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _load_scenario(path: str) -> dict[str, Any]:
    scenario_path = Path(path).expanduser().resolve()
    data = json.loads(scenario_path.read_text(encoding="utf-8"))
    project_root = Path(str(data.get("project_root") or "")).expanduser().resolve()
    if not project_root.is_dir():
        raise ValueError(f"Scenario project_root does not exist: {project_root}")
    tasks = data.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        raise ValueError("Scenario must include at least one task.")
    for index, task in enumerate(tasks):
        if not isinstance(task, dict) or not str(task.get("prompt") or "").strip():
            raise ValueError(f"Scenario task #{index + 1} must include a prompt.")
        task.setdefault("id", f"task_{index + 1}")
        task.setdefault("read_only", True)
    data["scenario_path"] = str(scenario_path)
    data["project_root"] = str(project_root)
    data["tasks"] = tasks
    return data


def _json_events(text: str) -> list[Any]:
    events: list[Any] = []
    stripped = (text or "").strip()
    if not stripped:
        return events
    try:
        parsed = json.loads(stripped)
        events.append(parsed)
        return events
    except Exception:
        pass
    for line in stripped.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except Exception:
            continue
    return events


def _walk_dicts(obj: Any) -> list[dict[str, Any]]:
    found: list[dict[str, Any]] = []
    if isinstance(obj, dict):
        found.append(obj)
        for value in obj.values():
            found.extend(_walk_dicts(value))
    elif isinstance(obj, list):
        for item in obj:
            found.extend(_walk_dicts(item))
    return found


def _int_field(data: dict[str, Any], names: tuple[str, ...]) -> int | None:
    for name in names:
        value = data.get(name)
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            return value
        if isinstance(value, float):
            return int(value)
        if isinstance(value, str) and value.isdigit():
            return int(value)
    return None


def extract_usage_from_events(stdout: str, stderr: str = "") -> dict[str, Any] | None:
    """Extract token usage from known Codex/Gemini JSON event shapes."""
    candidates: list[dict[str, Any]] = []
    for event in _json_events(stdout) + _json_events(stderr):
        for node in _walk_dicts(event):
            usage_nodes: list[dict[str, Any]] = []
            for key in ("usage", "token_usage", "usage_metadata", "usageMetadata"):
                value = node.get(key)
                if isinstance(value, dict):
                    usage_nodes.append(value)
            if any(k in node for k in ("total_tokens", "totalTokenCount", "prompt_tokens", "input_tokens", "promptTokenCount")):
                usage_nodes.append(node)
            for usage in usage_nodes:
                input_tokens = _int_field(usage, ("input_tokens", "prompt_tokens", "promptTokenCount", "cached_input_tokens"))
                output_tokens = _int_field(
                    usage,
                    ("output_tokens", "completion_tokens", "candidatesTokenCount", "responseTokenCount"),
                )
                total_tokens = _int_field(usage, ("total_tokens", "totalTokenCount", "total_tokens_used"))
                if total_tokens is None and (input_tokens is not None or output_tokens is not None):
                    total_tokens = (input_tokens or 0) + (output_tokens or 0)
                if total_tokens is not None:
                    candidates.append(
                        {
                            "usage_source": "cli_event",
                            "input_tokens": input_tokens,
                            "output_tokens": output_tokens,
                            "total_tokens": total_tokens,
                        }
                    )
    if not candidates:
        return None
    return max(candidates, key=lambda item: item.get("total_tokens") or 0)


def _transcript_usage(prompt: str, stdout: str, stderr: str, model_profile: str) -> dict[str, Any]:
    prompt_tokens = estimate_tokens(prompt, model_profile)
    transcript_tokens = estimate_tokens((stdout or "") + "\n" + (stderr or ""), model_profile)
    return {
        "usage_source": "transcript_estimate",
        "input_tokens": prompt_tokens,
        "output_tokens": transcript_tokens,
        "total_tokens": prompt_tokens + transcript_tokens,
    }


def _redacted_command(args: list[str]) -> list[str]:
    redacted = list(args)
    for index, arg in enumerate(args[:-1]):
        if arg == "--prompt":
            redacted[index + 1] = "<prompt>"
    if len(args) >= 3 and args[0] == "codex" and args[1] == "exec":
        # Codex receives prompt as the final positional argument.
        redacted[-1] = "<prompt>"
    return redacted


def _string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(item) for item in value if str(item or "").strip()]


def _evaluate_acceptance(task: dict[str, Any], stdout: str, stderr: str, run_status: str) -> dict[str, Any]:
    expected_files = _string_list(task.get("expected_files"))
    must_mention = _string_list(task.get("must_mention"))
    must_not_claim = _string_list(task.get("must_not_claim"))
    text = f"{stdout or ''}\n{stderr or ''}".lower()

    matched_files = [item for item in expected_files if item.lower() in text]
    missing_files = [item for item in expected_files if item.lower() not in text]
    matched_mentions = [item for item in must_mention if item.lower() in text]
    missing_mentions = [item for item in must_mention if item.lower() not in text]
    forbidden_found = [item for item in must_not_claim if item.lower() in text]

    has_rubric = bool(expected_files or must_mention or must_not_claim)
    if run_status != "ok":
        status = "not_applicable"
    elif not has_rubric:
        status = "manual_review_required"
    elif missing_files or missing_mentions or forbidden_found:
        status = "failed"
    else:
        status = "passed"

    return {
        "status": status,
        "expected_files_matched": matched_files,
        "expected_files_missing": missing_files,
        "must_mention_matched": matched_mentions,
        "must_mention_missing": missing_mentions,
        "must_not_claim_found": forbidden_found,
        "manual_acceptance_notes": str(task.get("manual_acceptance_notes") or ""),
    }


def _run_process(args: list[str], cwd: Path, timeout: int) -> dict[str, Any]:
    start = time.monotonic()
    try:
        proc = subprocess.run(
            args,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        status = "ok" if proc.returncode == 0 else "error"
        return {
            "status": status,
            "exit_code": proc.returncode,
            "duration_ms": round((time.monotonic() - start) * 1000, 1),
            "stdout": proc.stdout or "",
            "stderr": proc.stderr or "",
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "status": "error",
            "exit_code": None,
            "duration_ms": round((time.monotonic() - start) * 1000, 1),
            "stdout": exc.stdout if isinstance(exc.stdout, str) else "",
            "stderr": f"Timed out after {timeout}s",
        }
    except FileNotFoundError as exc:
        return {
            "status": "error",
            "exit_code": None,
            "duration_ms": round((time.monotonic() - start) * 1000, 1),
            "stdout": "",
            "stderr": str(exc),
        }


def _agent_command(agent: str, prompt: str, project_root: Path, model: str | None, read_only: bool) -> tuple[list[str], Path]:
    if agent == "codex":
        args = ["codex", "exec", "--json", "-C", str(project_root), "-s", "read-only" if read_only else "workspace-write"]
        if model:
            args.extend(["--model", model])
        args.append(prompt)
        return args, project_root
    if agent == "gemini":
        args = ["gemini", "--prompt", prompt, "--output-format", "stream-json", "--approval-mode", "plan"]
        if model:
            args.extend(["--model", model])
        args.append("--skip-trust")
        return args, project_root
    raise ValueError(f"Unsupported agent: {agent}")


def _prepare_soma_packet(project_root: Path, task_prompt: str, python: str, budget: str, depth: str, timeout: int, model_profile: str) -> dict[str, Any]:
    env = os.environ.copy()
    env["SOMA_PROJECT_ROOT"] = str(project_root)
    env["SOMA_TOKEN_MODEL_PROFILE"] = model_profile
    env["SOMA_GRAPHIFY_PROJECT_ONLY"] = "1"
    proc = subprocess.run(
        [
            python,
            _server_script(),
            "--project-root",
            str(project_root),
            "--run-tool",
            "soma_prepare_context",
            json.dumps({"goal": task_prompt, "budget": budget, "depth": depth}),
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        return {"status": "error", "summary": proc.stderr[-500:], "packet": ""}
    try:
        parsed = json.loads(proc.stdout)
        if not isinstance(parsed, dict):
            return {"status": "error", "summary": "Soma returned non-object JSON.", "packet": ""}
        return parsed
    except Exception as exc:
        return {"status": "error", "summary": f"Invalid Soma JSON: {exc}", "packet": ""}


def _with_soma_prompt(task_prompt: str, packet: str) -> str:
    return (
        "Run this task in read-only mode using Soma Packet Mode v1. Use the Soma evidence packet as compact project context. "
        "Avoid broad repo scans unless the packet is clearly insufficient.\n\n"
        f"Task:\n{task_prompt}\n\n"
        "Soma evidence packet:\n"
        "```text\n"
        f"{packet}\n"
        "```"
    )


def run_agent_once(
    *,
    agent: str,
    mode: str,
    prompt: str,
    project_root: Path,
    task: dict[str, Any],
    model: str | None,
    timeout: int,
    model_profile: str,
    soma_packet_tokens: int | None = None,
    soma_packet_status: str | None = None,
) -> dict[str, Any]:
    read_only = bool(task.get("read_only", True))
    args, cwd = _agent_command(agent, prompt, project_root, model, read_only)
    raw = _run_process(args, cwd, timeout)
    usage = extract_usage_from_events(raw["stdout"], raw["stderr"]) or _transcript_usage(prompt, raw["stdout"], raw["stderr"], model_profile)
    acceptance = _evaluate_acceptance(task, raw["stdout"], raw["stderr"], raw["status"])
    return {
        "task_id": str(task.get("id")),
        "agent": agent,
        "mode": mode,
        "workflow": "direct_agent" if mode == "direct" else "with_soma_packet",
        "status": raw["status"],
        "exit_code": raw["exit_code"],
        "duration_ms": raw["duration_ms"],
        "read_only": read_only,
        "model": model,
        "usage_source": usage["usage_source"],
        "input_tokens": usage.get("input_tokens"),
        "output_tokens": usage.get("output_tokens"),
        "total_tokens": usage.get("total_tokens"),
        "prompt_tokens_estimated": estimate_tokens(prompt, model_profile),
        "prompt_sha256": _sha256(prompt),
        "stdout_chars": len(raw["stdout"]),
        "stdout_sha256": _sha256(raw["stdout"]),
        "stderr_chars": len(raw["stderr"]),
        "stderr_sha256": _sha256(raw["stderr"]),
        "command": _redacted_command(args),
        "soma_packet_tokens": soma_packet_tokens,
        "soma_packet_status": soma_packet_status,
        "acceptance_status": acceptance["status"],
        "acceptance": acceptance,
    }


def skipped_with_soma_run(
    *,
    agent: str,
    task: dict[str, Any],
    model: str | None,
    soma_packet_tokens: int | None,
    soma_packet_status: str | None,
    reason: str,
) -> dict[str, Any]:
    return {
        "task_id": str(task.get("id")),
        "agent": agent,
        "mode": "with_soma",
        "workflow": "with_soma_packet",
        "status": "error",
        "exit_code": None,
        "duration_ms": 0,
        "read_only": bool(task.get("read_only", True)),
        "model": model,
        "usage_source": "unavailable",
        "input_tokens": None,
        "output_tokens": None,
        "total_tokens": None,
        "prompt_tokens_estimated": None,
        "prompt_sha256": None,
        "stdout_chars": 0,
        "stdout_sha256": None,
        "stderr_chars": 0,
        "stderr_sha256": None,
        "command": [],
        "soma_packet_tokens": soma_packet_tokens,
        "soma_packet_status": soma_packet_status,
        "acceptance_status": "not_applicable",
        "acceptance": {"status": "not_applicable", "reason": reason},
        "skip_reason": reason,
    }


def _compare_pairs(runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_key: dict[tuple[str, str], dict[str, dict[str, Any]]] = {}
    for run in runs:
        key = (str(run.get("task_id")), str(run.get("agent")))
        by_key.setdefault(key, {})[str(run.get("mode"))] = run

    comparisons: list[dict[str, Any]] = []
    for (task_id, agent), modes in sorted(by_key.items()):
        direct = modes.get("direct")
        with_soma = modes.get("with_soma")
        if not direct or not with_soma:
            continue
        comparable = (
            direct.get("status") == "ok"
            and with_soma.get("status") == "ok"
            and with_soma.get("soma_packet_status") == "ok"
            and direct.get("acceptance_status") not in {"failed", "not_applicable"}
            and with_soma.get("acceptance_status") not in {"failed", "not_applicable"}
            and isinstance(direct.get("total_tokens"), int)
            and isinstance(with_soma.get("total_tokens"), int)
        )
        saved = None
        pct = None
        if comparable:
            saved = int(direct["total_tokens"]) - int(with_soma["total_tokens"])
            pct = round(100 * saved / max(int(direct["total_tokens"]), 1), 1)
        comparisons.append(
            {
                "task_id": task_id,
                "agent": agent,
                "status": "ok" if comparable else "unavailable",
                "direct_tokens": direct.get("total_tokens"),
                "with_soma_tokens": with_soma.get("total_tokens"),
                "saved_tokens": saved,
                "savings_pct": pct,
                "direct_usage_source": direct.get("usage_source"),
                "with_soma_usage_source": with_soma.get("usage_source"),
                "direct_duration_ms": direct.get("duration_ms"),
                "with_soma_duration_ms": with_soma.get("duration_ms"),
                "acceptance_status": with_soma.get("acceptance_status"),
                "direct_acceptance_status": direct.get("acceptance_status"),
                "with_soma_acceptance_status": with_soma.get("acceptance_status"),
                "soma_packet_status": with_soma.get("soma_packet_status"),
            }
        )
    return comparisons


def _build_summary(runs: list[dict[str, Any]], comparisons: list[dict[str, Any]]) -> dict[str, Any]:
    ok_pairs = [item for item in comparisons if item.get("status") == "ok"]
    failed_runs = [item for item in runs if item.get("status") != "ok"]
    return {
        "run_count": len(runs),
        "failed_run_count": len(failed_runs),
        "comparison_count": len(comparisons),
        "paired_result_count": len(ok_pairs),
        "total_direct_tokens": sum(item.get("direct_tokens") or 0 for item in ok_pairs),
        "total_with_soma_tokens": sum(item.get("with_soma_tokens") or 0 for item in ok_pairs),
        "total_saved_tokens": sum(item.get("saved_tokens") or 0 for item in ok_pairs),
        "avg_savings_pct": round(sum(item.get("savings_pct") or 0 for item in ok_pairs) / max(len(ok_pairs), 1), 1) if ok_pairs else None,
        "usage_sources": sorted({str(item.get("usage_source")) for item in runs if item.get("usage_source")}),
    }


def run_benchmark(scenario: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    project_root = Path(scenario["project_root"])
    scenario_agents = scenario.get("agents") if isinstance(scenario.get("agents"), list) else None
    selected_agents = [agent.strip() for agent in (args.agents or ",".join(scenario_agents or DEFAULT_AGENTS)).split(",") if agent.strip()]
    model_config = scenario.get("models") if isinstance(scenario.get("models"), dict) else scenario.get("model")
    models = model_config if isinstance(model_config, dict) else {}

    runs: list[dict[str, Any]] = []
    soma_calls: list[dict[str, Any]] = []
    for task in scenario["tasks"]:
        prompt = str(task["prompt"])
        soma = _prepare_soma_packet(project_root, prompt, args.python, args.budget, args.depth, args.soma_timeout, args.model_profile)
        packet = soma.get("packet") or ""
        packet_tokens = estimate_tokens(packet, args.model_profile) if packet else None
        packet_status = soma.get("status")
        soma_calls.append(
            {
                "task_id": str(task.get("id")),
                "status": packet_status,
                "summary": soma.get("summary"),
                "packet_tokens": packet_tokens,
                "packet_quality": soma.get("evidence_quality"),
                "evidence": soma.get("evidence"),
                "operation_savings": soma.get("operation_savings"),
                "estimated_context_reduction": soma.get("estimated_context_reduction"),
            }
        )
        with_soma_prompt = _with_soma_prompt(prompt, packet) if packet else prompt
        for agent in selected_agents:
            model = models.get(agent) if isinstance(models, dict) else None
            runs.append(
                run_agent_once(
                    agent=agent,
                    mode="direct",
                    prompt=prompt,
                    project_root=project_root,
                    task=task,
                    model=model,
                    timeout=args.timeout,
                    model_profile=args.model_profile,
                )
            )
            if packet_status != "ok" or not packet:
                runs.append(
                    skipped_with_soma_run(
                        agent=agent,
                        task=task,
                        model=model,
                        soma_packet_tokens=packet_tokens,
                        soma_packet_status=packet_status,
                        reason="Soma packet was not ok; with-Soma run skipped to avoid fake savings.",
                    )
                )
                continue
            runs.append(
                run_agent_once(
                    agent=agent,
                    mode="with_soma",
                    prompt=with_soma_prompt,
                    project_root=project_root,
                    task=task,
                    model=model,
                    timeout=args.timeout,
                    model_profile=args.model_profile,
                    soma_packet_tokens=packet_tokens,
                    soma_packet_status=packet_status,
                )
            )

    comparisons = _compare_pairs(runs)
    summary = _build_summary(runs, comparisons)
    status = "ok"
    if summary["paired_result_count"] == 0:
        status = "error"
    elif summary["failed_run_count"] > 0:
        status = "degraded"
    return {
        "status": status,
        "generated_at": _now(),
        "scenario_path": scenario.get("scenario_path"),
        "project_root": str(project_root),
        "agents": selected_agents,
        "model_profile": estimate_payload("", args.model_profile)["model_profile"],
        "budget": args.budget,
        "depth": args.depth,
        "mode": "packet_prompt",
        "workflows": ["direct_agent", "with_soma_packet"],
        "experimental_workflows": ["with_soma_mcp_experimental"],
        "summary": summary,
        "comparisons": comparisons,
        "runs": runs,
        "soma_calls": soma_calls,
        "privacy": {
            "raw_prompts_stored": False,
            "raw_transcripts_stored": False,
            "stored_fields": "counts, hashes, statuses, durations, usage tokens, and command shapes only",
        },
    }


def _write_report(report: dict[str, Any]) -> None:
    BENCHMARK_DIR.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(report, indent=2, sort_keys=True)
    (BENCHMARK_DIR / "latest.json").write_text(rendered, encoding="utf-8")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    (BENCHMARK_DIR / f"agent_benchmark_{stamp}.json").write_text(rendered, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run observed direct-vs-Soma agent token benchmarks.")
    parser.add_argument("--scenario", required=True, help="Scenario JSON with project_root and tasks.")
    parser.add_argument("--agents", default=None, help="Comma-separated agents: codex,gemini")
    parser.add_argument("--model-profile", default="gpt-5.5")
    parser.add_argument("--budget", default="fast", choices=["micro", "fast", "balanced", "deep", "full"])
    parser.add_argument("--depth", default="deterministic", choices=["deterministic", "ranked", "analyst"])
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--soma-timeout", type=int, default=90)
    args = parser.parse_args()

    scenario = _load_scenario(args.scenario)
    report = run_benchmark(scenario, args)
    _write_report(report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if report.get("status") == "error" else 0


if __name__ == "__main__":
    raise SystemExit(main())
