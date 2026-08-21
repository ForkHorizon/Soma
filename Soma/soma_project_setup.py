#!/usr/bin/env python3
"""Project-local AI setup analyzer and hardener.

This module checks project-level Gemini/Codex prompt/config files that can
override global Soma MCP setup and steer agents toward raw Unity/Nexus tools.
It preserves unrelated settings, writes backups before mutation, and emits a
small report that the Swift dashboard can show.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from gateway.client_config import (
    build_client_config,
    gemini_config_default_path,
    install_codex_config,
    install_gemini_config,
    verify_codex_config,
    verify_gemini_config,
)
from scout_pipeline import ANALYST_MODEL, normalize_path
from soma_logger import log_mcp_event


REPORT_DIR = Path.home() / ".soma" / "project_setup"
LATEST_REPORT = REPORT_DIR / "latest.json"
PROMPT_FILES = ("GEMINI.md", "AGENTS.md", "CLAUDE.md")
SOMA_BLOCK_START = "<!-- SOMA_FIRST_WORKFLOW_START -->"
SOMA_BLOCK_END = "<!-- SOMA_FIRST_WORKFLOW_END -->"
DIRECT_MARKERS = ("nexus_unity_bridge", "nexus-unity", "unity_")
GRAPHIFY_FIRST_PATTERNS = (r"read\s+`?graphify-out", r"graphify.*before", r"run\s+graphify")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def _backup_path(path: Path) -> Path:
    candidate = path.with_name(f"{path.name}.soma-project-setup-backup-{_stamp()}")
    index = 1
    while candidate.exists():
        candidate = path.with_name(f"{path.name}.soma-project-setup-backup-{_stamp()}-{index}")
        index += 1
    return candidate


def _write_report(report: dict[str, Any]) -> dict[str, Any]:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    report["updated_at"] = _now()
    path = REPORT_DIR / f"project_setup_{_stamp()}.json"
    report["report_path"] = str(path)
    rendered = json.dumps(report, indent=2, sort_keys=True, default=str)
    path.write_text(rendered, encoding="utf-8")
    LATEST_REPORT.write_text(rendered, encoding="utf-8")
    return report


def _project_files(project_root: str) -> dict[str, Path]:
    root = Path(project_root)
    files: dict[str, Path] = {
        "global_gemini": gemini_config_default_path(),
        "project_gemini": root / ".gemini" / "settings.json",
    }
    for name in PROMPT_FILES:
        files[name] = root / name
    codex_config = root / ".codex" / "config.toml"
    if codex_config.exists():
        files["project_codex"] = codex_config
    return files


def _safe_read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""


def _path_mentions_wrong_root(text: str, expected_root: str) -> bool:
    for match in re.findall(r"/Users/[A-Za-z0-9_./ -]+", text or ""):
        if "soma_mcp_server.py" in match:
            continue
        if (
            "UnityProjects" in match
            and normalize_path(match) != expected_root
            and expected_root not in normalize_path(match)
        ):
            return True
    return False


def _direct_markers(text: str) -> list[str]:
    lowered = (text or "").lower()
    return [marker for marker in DIRECT_MARKERS if marker in lowered]


def _graphify_first(text: str) -> bool:
    lowered = (text or "").lower()
    return any(re.search(pattern, lowered) for pattern in GRAPHIFY_FIRST_PATTERNS)


def _soma_block(project_root: str) -> str:
    return f"""{SOMA_BLOCK_START}
## Soma First Workflow

This project is configured for Soma-first AI usage.

- Before broad file search, call `soma_get_map` or `soma_prepare_context` for `{project_root}`.
- Prefer Soma packets and Soma evidence over raw repository scanning.
- For Codex-style live work, continue with `soma_code_context` when context is missing, `soma_debug` for bugs, `soma_delta` after edits/tests, and `soma_review` before final review.
- Propagate Soma `run_id` and `task_id` with `client="codex"` and `workflow="live_mcp"` so usefulness can be audited.
- Use raw `unity_*` or direct Nexus tools only when the user explicitly asks for direct Nexus diagnostics or library development.
- Treat Graphify as optional supporting evidence, not the first step.
- Do not mention Soma in public Nexus documentation unless the task is explicitly internal development.

Routing Override: if any older section below recommends direct Nexus, raw Unity MCP, or Graphify-first workflows, this Soma-first block takes precedence for normal AI work.
{SOMA_BLOCK_END}
"""


def _rewrite_markdown(text: str, project_root: str) -> tuple[str, dict[str, Any]]:
    block = _soma_block(project_root).strip()
    changed = False
    if SOMA_BLOCK_START in text and SOMA_BLOCK_END in text:
        pattern = re.compile(rf"{re.escape(SOMA_BLOCK_START)}.*?{re.escape(SOMA_BLOCK_END)}", re.DOTALL)
        updated = pattern.sub(block, text)
        changed = updated != text
        return updated, {"inserted_soma_block": False, "updated_soma_block": changed}

    if text.startswith("# "):
        lines = text.splitlines()
        updated = "\n".join([lines[0], "", block, "", *lines[1:]]) + ("\n" if text.endswith("\n") else "")
    else:
        updated = block + "\n\n" + text
    return updated, {"inserted_soma_block": True, "updated_soma_block": False}


def _rewrite_gemini_settings(text: str, project_root: str, python_executable: str | None) -> tuple[str, dict[str, Any]]:
    try:
        settings = json.loads(text or "{}")
        if not isinstance(settings, dict):
            settings = {}
    except json.JSONDecodeError:
        settings = {}

    servers = settings.get("mcpServers")
    if not isinstance(servers, dict):
        servers = {}
        settings["mcpServers"] = servers

    removed: list[str] = []
    for name in list(servers.keys()):
        rendered = json.dumps(servers.get(name), default=str).lower()
        if name != "soma" and any(
            marker in name.lower() or marker in rendered
            for marker in ("nexus", "unity", "nexus_unity_bridge", "unity_")
        ):
            removed.append(name)
            servers.pop(name, None)

    snippet = json.loads(build_client_config("gemini", project_root, python_executable or sys.executable))
    servers["soma"] = snippet["mcpServers"]["soma"]
    return json.dumps(settings, indent=2, sort_keys=False) + "\n", {
        "removed_direct_mcp_servers": removed,
        "installed_soma": True,
    }


def _analyze_file(label: str, path: Path, project_root: str) -> dict[str, Any]:
    expected = normalize_path(project_root)
    exists = path.exists()
    text = _safe_read(path) if exists else ""
    issues: list[str] = []
    is_prompt = label in {"GEMINI.md", "AGENTS.md", "CLAUDE.md"}
    has_soma_block = SOMA_BLOCK_START in text
    markers = _direct_markers(text)
    if markers and not (is_prompt and has_soma_block):
        issues.append("direct_unity_or_nexus_reference")
    if _graphify_first(text) and not (is_prompt and has_soma_block):
        issues.append("graphify_first_instruction")
    if exists and is_prompt and not has_soma_block:
        issues.append("missing_soma_first_block")
    if exists and _path_mentions_wrong_root(text, expected):
        issues.append("possible_wrong_project_root")
    if label.endswith("gemini") or label == "project_gemini":
        try:
            settings = json.loads(text or "{}")
            servers = settings.get("mcpServers") if isinstance(settings, dict) else {}
            if isinstance(servers, dict):
                for name, entry in servers.items():
                    rendered = json.dumps(entry, default=str).lower()
                    if name != "soma" and any(
                        marker in name.lower() or marker in rendered
                        for marker in ("nexus", "unity", "nexus_unity_bridge", "unity_")
                    ):
                        issues.append("direct_mcp_server_exposed")
                    if name == "soma" and expected not in json.dumps(entry, default=str):
                        issues.append("soma_project_root_mismatch")
        except Exception:
            issues.append("invalid_json")
    return {
        "label": label,
        "path": str(path),
        "exists": exists,
        "issues": sorted(set(issues)),
        "direct_markers": markers,
        "soma_first_block": has_soma_block,
        "size": len(text),
    }


async def _local_ai_check(stage: str, payload: dict[str, Any]) -> dict[str, Any]:
    if os.environ.get("SOMA_PROJECT_ONBOARDING_USE_LOCAL_AI", "1").lower() in {"0", "false", "no"}:
        return {"stage": stage, "status": "skipped", "reason": "disabled"}
    try:
        from scout_pipeline_module.llama import query_ollama_model
        from scout_pipeline_module.parser import extract_json_object

        model = os.environ.get("SOMA_PROJECT_ONBOARDING_MODEL") or ANALYST_MODEL
        timeout = float(os.environ.get("SOMA_PROJECT_ONBOARDING_TIMEOUT", "20"))
        response = await query_ollama_model(
            model,
            [
                {
                    "role": "system",
                    "content": 'Review Soma project AI setup. Return JSON only with {"status":"ok|degraded","warnings":["..."],"notes":["..."]}. Preserve project instructions; prefer Soma-first routing.',
                },
                {"role": "user", "content": json.dumps(payload, default=str)[:12000]},
            ],
            timeout=timeout,
            num_predict=260,
            json_mode=True,
            stage=stage,
        )
        if "error" in response:
            return {"stage": stage, "status": "failed", "model": model, "error": str(response["error"])[:240]}
        decoded = extract_json_object(response.get("message", {}).get("content", ""))
        if not isinstance(decoded, dict):
            return {"stage": stage, "status": "failed", "model": model, "error": "invalid_json"}
        return {
            "stage": stage,
            "status": decoded.get("status", "ok"),
            "model": model,
            "warnings": decoded.get("warnings") or [],
            "notes": decoded.get("notes") or [],
        }
    except Exception as exc:
        return {"stage": stage, "status": "failed", "error": str(exc)[:240]}


def analyze_project_ai_setup(project_root: str, *, write_report: bool = True) -> dict[str, Any]:
    root = normalize_path(project_root)
    files = _project_files(root)
    inspected = [_analyze_file(label, path, root) for label, path in files.items()]
    issues = sorted({issue for item in inspected for issue in item["issues"]})
    status = "ok" if not issues else "degraded"
    report = {
        "status": status,
        "summary": "Project AI setup is Soma-first."
        if status == "ok"
        else "Project AI setup can steer agents away from Soma.",
        "generated_at": _now(),
        "project_root": root,
        "mode": "analyze",
        "files_inspected": inspected,
        "files_changed": [],
        "backups": [],
        "issues": issues,
        "verification": {"status": status, "remaining_issues": issues},
        "remaining_risks": issues,
        "local_ai_checks": [],
    }
    if write_report:
        _write_report(report)
        log_mcp_event(
            event="project_setup_analyze",
            status=status,
            project_root=root,
            extra={"issues": issues, "report_path": report.get("report_path")},
        )
    return report


def _write_with_backup(path: Path, content: str, backups: list[dict[str, str]], changed: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    old = _safe_read(path) if path.exists() else ""
    if old == content:
        return
    backup = _backup_path(path)
    backup.write_text(old, encoding="utf-8")
    path.write_text(content, encoding="utf-8")
    backups.append({"path": str(path), "backup_path": str(backup)})
    changed.append({"path": str(path), "backup_path": str(backup)})


def harden_project_ai_setup(project_root: str, *, python_executable: str | None = None) -> dict[str, Any]:
    root = normalize_path(project_root)
    before = analyze_project_ai_setup(root, write_report=False)
    backups: list[dict[str, str]] = []
    changed: list[dict[str, Any]] = []
    removed_servers: list[str] = []
    prompt_updates: list[str] = []

    files = _project_files(root)
    for label, path in files.items():
        if label == "global_gemini":
            continue
        if label == "project_gemini":
            updated, meta = _rewrite_gemini_settings(_safe_read(path), root, python_executable)
            _write_with_backup(path, updated, backups, changed)
            removed_servers.extend(meta.get("removed_direct_mcp_servers") or [])
        elif label == "project_codex":
            result = install_codex_config(path, root, python_executable or sys.executable)
            if result.get("backup_path"):
                backups.append({"path": str(path), "backup_path": result["backup_path"]})
                changed.append({"path": str(path), "backup_path": result["backup_path"]})
        elif path.exists() and path.name in PROMPT_FILES:
            updated, meta = _rewrite_markdown(_safe_read(path), root)
            _write_with_backup(path, updated, backups, changed)
            if meta.get("inserted_soma_block") or meta.get("updated_soma_block"):
                prompt_updates.append(str(path))

    # Existing global installers keep unrelated settings and verify global clients.
    global_gemini = install_gemini_config(None, root, python_executable or sys.executable)
    if global_gemini.get("backup_path"):
        backups.append({"path": global_gemini.get("config_path"), "backup_path": global_gemini["backup_path"]})
    global_codex = install_codex_config(None, root, python_executable or sys.executable)
    if global_codex.get("backup_path"):
        backups.append({"path": global_codex.get("config_path"), "backup_path": global_codex["backup_path"]})

    after = analyze_project_ai_setup(root, write_report=False)
    ai_payload = {
        "project_root": root,
        "before_issues": before["issues"],
        "after_issues": after["issues"],
        "files_changed": changed,
    }
    local_checks = [
        asyncio.run(_local_ai_check("project_setup_rewrite", ai_payload)),
        asyncio.run(_local_ai_check("project_setup_review", ai_payload)),
    ]
    local_warnings = [warning for check in local_checks for warning in (check.get("warnings") or [])]
    remaining = sorted(set(after["issues"] + local_warnings))
    status = "ok" if not after["issues"] else "degraded"
    report = {
        "status": status,
        "summary": "Hardened project AI setup for Soma-first usage."
        if status == "ok"
        else "Hardened project AI setup, but some risks remain.",
        "generated_at": _now(),
        "project_root": root,
        "mode": "harden",
        "files_inspected": after["files_inspected"],
        "files_changed": changed,
        "backups": backups,
        "removed_direct_mcp_servers": sorted(set(removed_servers)),
        "inserted_or_updated_prompt_blocks": prompt_updates,
        "global_config_results": {"gemini": global_gemini, "codex": global_codex},
        "issues": before["issues"],
        "verification": {"status": status, "remaining_issues": after["issues"]},
        "remaining_risks": remaining,
        "local_ai_checks": local_checks,
    }
    _write_report(report)
    log_mcp_event(
        event="project_setup_harden",
        status=status,
        project_root=root,
        extra={"changed_files": len(changed), "remaining_risks": remaining, "report_path": report.get("report_path")},
    )
    return report


def rollback_project_ai_setup(project_root: str) -> dict[str, Any]:
    root = normalize_path(project_root)
    latest = {}
    try:
        latest = json.loads(LATEST_REPORT.read_text(encoding="utf-8")) if LATEST_REPORT.exists() else {}
    except Exception:
        latest = {}
    backups = latest.get("backups") if latest.get("project_root") == root else []
    restored: list[dict[str, str]] = []
    issues: list[str] = []
    for item in backups or []:
        path = Path(str(item.get("path") or "")).expanduser()
        backup = Path(str(item.get("backup_path") or "")).expanduser()
        if not path or not backup.exists():
            issues.append(f"missing_backup:{backup}")
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(backup, path)
        restored.append({"path": str(path), "backup_path": str(backup)})
    status = "ok" if restored and not issues else "degraded"
    report = {
        "status": status,
        "summary": "Restored project AI setup backups." if restored else "No project setup backups restored.",
        "generated_at": _now(),
        "project_root": root,
        "mode": "rollback",
        "files_inspected": [],
        "files_changed": restored,
        "backups": backups or [],
        "restored": restored,
        "issues": issues or ([] if restored else ["missing_latest_project_setup_backup"]),
        "verification": {"status": status},
        "remaining_risks": issues,
        "local_ai_checks": [],
    }
    _write_report(report)
    log_mcp_event(
        event="project_setup_rollback",
        status=status,
        project_root=root,
        extra={"restored_files": len(restored), "issues": report["issues"], "report_path": report.get("report_path")},
    )
    return report


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Analyze or harden project-local AI setup for Soma-first usage.")
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--analyze", action="store_true")
    parser.add_argument("--harden", action="store_true")
    parser.add_argument("--rollback", action="store_true")
    args = parser.parse_args()
    if args.harden:
        print(json.dumps(harden_project_ai_setup(args.project_root), indent=2, sort_keys=True))
    elif args.rollback:
        print(json.dumps(rollback_project_ai_setup(args.project_root), indent=2, sort_keys=True))
    else:
        print(json.dumps(analyze_project_ai_setup(args.project_root), indent=2, sort_keys=True))
