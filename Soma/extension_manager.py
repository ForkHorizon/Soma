#!/usr/bin/env python3
"""Small extension/tool updater used by the Soma UI and CLI."""
from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any

from gateway.client_config import (
    _entry_mentions_direct_unity,
    _extract_json_soma_project_root,
    build_client_config,
    install_codex_config,
    install_hermes_config,
    verify_codex_config,
    verify_hermes_config,
)
from scout_pipeline import normalize_path


SKIP_DIRS = {
    ".build",
    ".git",
    ".gradle",
    ".next",
    ".venv",
    "DerivedData",
    "Library",
    "node_modules",
    "Packages",
    "build",
    "dist",
    "target",
}
PROJECT_MARKERS = ("GEMINI.md", "AGENTS.md", "CLAUDE.md", ".mcp.json", ".git")
MEMORY_BLOCK_START = "<!-- SOMA_MEMORY_TOOLS_START -->"
MEMORY_BLOCK_END = "<!-- SOMA_MEMORY_TOOLS_END -->"
MEMORY_TOOL_DOC_ORDER = ("codebase-memory", "projectmem")
MEMORY_TOOL_DOC_LINES = {
    "codebase-memory": "- Codebase-Memory: use only for unknown code discovery, call graph/impact checks, or broad refactors. For known files, strings, or configs, read files or use `rg` directly.",
    "projectmem": "- projectmem: use for bugs, regressions, multi-step changes, repeated attempts, or architecture decisions. For small self-contained edits, skip full memory startup and use targeted history checks only when useful.",
}
MANAGED_TOOLS = {
    "codebase-memory": {
        "name": "Codebase-Memory",
        "kind": "MCP",
        "detail": "Persistent Tree-sitter code graph for coding agents.",
        "latest": "https://api.github.com/repos/DeusData/codebase-memory-mcp/releases/latest",
        "command": 'if command -v codebase-memory-mcp >/dev/null 2>&1; then codebase-memory-mcp update; else curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash; fi',
    },
    "graphify": {
        "name": "Graphify",
        "kind": "Skill",
        "detail": "Knowledge graph skill and CLI.",
        "latest": "https://pypi.org/pypi/graphifyy/json",
        "command": "uv tool upgrade graphifyy && graphify install",
    },
    "ponytail": {
        "name": "Ponytail",
        "kind": "Plugin",
        "detail": "Claude/Gemini/Codex style plugin.",
        "latest": "https://api.github.com/repos/DietrichGebert/ponytail/releases/latest",
        "command": 'git -C "$HOME/.claude/plugins/marketplaces/ponytail" pull --ff-only',
    },
    "projectmem": {
        "name": "projectmem",
        "kind": "MCP",
        "detail": "Local-first project memory and failed-fix governance.",
        "latest": "https://pypi.org/pypi/projectmem/json",
        "command": '"$SOMA_PYTHON" -m pip install --user --upgrade --break-system-packages projectmem',
    },
}


def tool_status(tool_id: str | None = None, *, home: Path | None = None, latest: bool = True) -> dict[str, Any]:
    ids = [tool_id] if tool_id and tool_id != "all" else list(MANAGED_TOOLS)
    tools = [_tool_status_one(item, home=home, latest=latest) for item in ids if item in MANAGED_TOOLS]
    return {"status": "ok", "tools": tools}


def update_tool(tool_id: str, project_root: str | None = None, recent_roots: list[str] | None = None, *, home: Path | None = None) -> dict[str, Any]:
    if tool_id not in MANAGED_TOOLS:
        return {"status": "error", "summary": f"Unknown tool: {tool_id}", "tool_id": tool_id, "issues": ["unknown_tool"]}
    before = _tool_status_one(tool_id, home=home)
    result = _run_shell(MANAGED_TOOLS[tool_id]["command"], home=home)
    after = _tool_status_one(tool_id, home=home)
    updated = result.returncode == 0 and _version_ok(after.get("installed_version"), after.get("latest_version"))
    sync = {"issues": [], "clients": [], "projects": [], "restart_needed": []}
    smoke = {"status": "skipped", "summary": "Update did not complete."}
    if updated:
        sync = sync_ai_clients(project_root, recent_roots or [], home=home)
        if tool_id == "projectmem" and project_root:
            memory_sync = _sync_projectmem_clients(project_root, home or Path.home())
            sync["clients"] = sync.get("clients", []) + memory_sync.get("clients", [])
            sync["issues"] = sorted(set(sync.get("issues", []) + memory_sync.get("issues", [])))
            sync["restart_needed"] = sorted(set(sync.get("restart_needed", []) + memory_sync.get("restart_needed", [])))
        smoke = _smoke_project(project_root)
    issues = ([] if result.returncode == 0 else ["update_command_failed"]) + ([] if updated else ["installed_version_not_latest"])
    issues += sync.get("issues", [])
    if smoke.get("status") not in {None, "ok", "skipped"}:
        issues.append("smoke_failed")
    restart = sorted(set(sync.get("restart_needed", []) + (_visible_clients() if updated else [])))
    return {
        **after,
        "status": "ok" if not issues else "degraded",
        "updated": updated,
        "before_version": before.get("installed_version"),
        "output": (result.stdout + result.stderr).strip()[-4000:],
        "issues": sorted(set(issues)),
        "clients": sync.get("clients", []),
        "projects": sync.get("projects", []),
        "smoke": smoke,
        "restart_needed": restart,
    }


def setup_memory_tools(project_root: str, *, home: Path | None = None) -> dict[str, Any]:
    home = home or Path.home()
    root = normalize_path(project_root)
    root_path = Path(root)
    issues: list[str] = []
    steps: list[dict[str, Any]] = []
    clients: dict[str, Any] = {"clients": [], "restart_needed": [], "issues": []}

    if not root_path.exists():
        return {"status": "error", "summary": "Project root does not exist.", "project_root": root, "issues": ["missing_project_root"], "steps": steps}

    for tool_id in ("codebase-memory", "projectmem"):
        if not _installed_version(tool_id, home):
            install = update_tool(tool_id, root, [], home=home)
            steps.append({"tool": tool_id, "action": "install", "status": install.get("status"), "issues": install.get("issues", [])})
            issues.extend(install.get("issues", []))

    cbm = _setup_codebase_memory(root, home)
    pjm = _setup_projectmem(root, home)
    docs = _write_memory_tools_doc(root_path, {"codebase-memory", "projectmem"})
    steps.extend([cbm, pjm, docs])
    for item in steps:
        issues.extend(item.get("issues", []) or [])

    clients = _sync_projectmem_clients(root, home)
    steps.append({"tool": "projectmem", "action": "sync_mcp_clients", "status": clients.get("status"), "issues": clients.get("issues", [])})
    issues.extend(clients.get("issues", []))

    status = "ok" if not issues else "degraded"
    return {
        "status": status,
        "summary": "Memory tools are installed for the selected project." if status == "ok" else "Memory tools setup finished with issues.",
        "project_root": root,
        "tools": tool_status("all", home=home, latest=True)["tools"],
        "clients": clients.get("clients", []),
        "steps": steps,
        "issues": sorted(set(issues)),
        "restart_needed": clients.get("restart_needed", []),
    }


def setup_project_tool(tool_id: str, project_root: str, *, home: Path | None = None) -> dict[str, Any]:
    home = home or Path.home()
    root = normalize_path(project_root)
    root_path = Path(root)
    issues: list[str] = []
    steps: list[dict[str, Any]] = []
    clients: dict[str, Any] = {"clients": [], "restart_needed": [], "issues": []}

    if not root_path.exists():
        return {"status": "error", "summary": "Project root does not exist.", "tool_id": tool_id, "project_root": root, "issues": ["missing_project_root"], "steps": steps}
    if tool_id not in {"codebase-memory", "projectmem"}:
        return {"status": "error", "summary": f"{tool_id} is not project-installable.", "tool_id": tool_id, "project_root": root, "issues": ["unsupported_project_tool"], "steps": steps}

    if not _installed_version(tool_id, home):
        install = update_tool(tool_id, root, [], home=home)
        steps.append({"tool": tool_id, "action": "install", "status": install.get("status"), "issues": install.get("issues", [])})
        issues.extend(install.get("issues", []))

    if tool_id == "codebase-memory":
        steps.extend([_setup_codebase_memory(root, home), _write_memory_tools_doc(root_path, {tool_id})])
    else:
        pjm = _setup_projectmem(root, home)
        docs = _write_memory_tools_doc(root_path, {tool_id})
        clients = _sync_projectmem_clients(root, home)
        steps.extend([pjm, docs, {"tool": "projectmem", "action": "sync_mcp_clients", "status": clients.get("status"), "issues": clients.get("issues", []), "restart_needed": clients.get("restart_needed", [])}])

    for item in steps:
        issues.extend(item.get("issues", []) or [])

    status = "ok" if not issues else "degraded"
    return {
        "status": status,
        "summary": f"{MANAGED_TOOLS[tool_id]['name']} is installed for the selected project." if status == "ok" else f"{MANAGED_TOOLS[tool_id]['name']} setup finished with issues.",
        "tool_id": tool_id,
        "name": MANAGED_TOOLS[tool_id]["name"],
        "project_root": root,
        "clients": clients.get("clients", []),
        "steps": steps,
        "issues": sorted(set(issues)),
        "restart_needed": clients.get("restart_needed", []),
    }


def project_overview(project_root: str | None, recent_roots: list[str] | None = None, *, home: Path | None = None, graph_status: dict[str, Any] | None = None) -> dict[str, Any]:
    home = home or Path.home()
    root = normalize_path(project_root) if project_root else ""
    root_path = Path(root) if root else None
    root_exists = bool(root_path and root_path.exists() and root_path.is_dir())
    tools = tool_status("all", home=home, latest=True)["tools"]
    clients = verify_project_clients(root, home=home).get("clients", []) if root_exists else []
    memory = _memory_overview(root, tools, graph_status or {}, home, root_exists)
    issues = ([] if root_exists else ["missing_project_root"]) + memory.get("issues", [])
    issues.extend(issue for item in clients for issue in item.get("issues", []))
    return {
        "status": "ok" if not issues else "degraded",
        "project_root": root,
        "display_name": root_path.name if root_path else "Project",
        "git": _git_overview(root if root_exists else ""),
        "graph": graph_status or {},
        "clients": clients,
        "memory": memory,
        "issues": sorted(set(issues)),
    }


def verify_project_clients(project_root: str, *, home: Path | None = None) -> dict[str, Any]:
    home = home or Path.home()
    root = Path(normalize_path(project_root))
    clients = [_verify_config(config) for config in _project_configs([root])]
    issues = sorted({issue for item in clients for issue in item.get("issues", [])})
    return {"status": "ok" if not issues else "degraded", "project_root": str(root), "clients": clients, "issues": issues}


def sync_project_clients(project_root: str, *, home: Path | None = None) -> dict[str, Any]:
    home = home or Path.home()
    root = Path(normalize_path(project_root))
    clients = [_sync_config(config) for config in _project_configs([root])]
    issues = sorted({issue for item in clients for issue in item.get("issues", [])})
    return {
        "status": "ok" if not issues else "degraded",
        "project_root": str(root),
        "clients": clients,
        "issues": issues,
        "restart_needed": sorted({item["client"] for item in clients if item.get("restart_needed")}),
        "summary": "Project-local client configs synced." if clients else "No project-local AI client configs found.",
    }


def scan_ai_clients(project_root: str | None = None, recent_roots: list[str] | None = None, *, home: Path | None = None) -> dict[str, Any]:
    home = home or Path.home()
    projects = _project_roots(project_root, recent_roots or [], home)
    configs = _global_configs(home) + _project_configs(projects)
    return {
        "status": "ok",
        "projects": [{"project_root": str(path)} for path in projects],
        "configs": [{"client": c["client"], "config_path": str(c["path"]), "project_root": c.get("project_root")} for c in configs],
    }


def verify_ai_clients(project_root: str | None = None, recent_roots: list[str] | None = None, *, home: Path | None = None) -> dict[str, Any]:
    home = home or Path.home()
    projects = _project_roots(project_root, recent_roots or [], home)
    configs = _global_configs(home) + _project_configs(projects)
    clients = [_verify_config(c) for c in configs]
    issues = sorted({issue for item in clients for issue in item.get("issues", [])})
    return {
        "status": "ok" if not issues else "degraded",
        "projects": [{"project_root": str(path)} for path in projects],
        "clients": clients,
        "issues": issues,
        "restart_needed": sorted({item["client"] for item in clients if item.get("restart_needed")}),
    }


def sync_ai_clients(project_root: str | None = None, recent_roots: list[str] | None = None, *, home: Path | None = None) -> dict[str, Any]:
    home = home or Path.home()
    projects = _project_roots(project_root, recent_roots or [], home)
    configs = _global_configs(home) + _project_configs(projects)
    clients = [_sync_config(c) for c in configs]
    issues = sorted({issue for item in clients for issue in item.get("issues", [])})
    return {
        "status": "ok" if not issues else "degraded",
        "projects": [{"project_root": str(path)} for path in projects],
        "clients": clients,
        "issues": issues,
        "restart_needed": sorted({item["client"] for item in clients if item.get("restart_needed")}),
    }


def _git_overview(project_root: str) -> dict[str, Any]:
    if not project_root:
        return {"is_repo": False, "summary": "Project root is missing."}
    if _run(["git", "rev-parse", "--is-inside-work-tree"], timeout=5, cwd=project_root).returncode != 0:
        return {"is_repo": False, "summary": "Not a Git repository."}
    status = _run(["git", "status", "--porcelain=v1", "-b"], timeout=10, cwd=project_root)
    lines = [line for line in status.stdout.splitlines() if line]
    branch, ahead, behind = _parse_git_branch(lines[0] if lines else "")
    staged = unstaged = untracked = tracked = 0
    for line in lines[1:]:
        if line.startswith("??"):
            untracked += 1
            continue
        if len(line) >= 2:
            tracked += 1
            if line[0] not in {" ", "?"}:
                staged += 1
            if line[1] not in {" ", "?"}:
                unstaged += 1
    last = _run(["git", "log", "-1", "--format=%h %s"], timeout=5, cwd=project_root)
    dirty = tracked + untracked
    return {
        "is_repo": True,
        "branch": branch,
        "ahead": ahead,
        "behind": behind,
        "changed_count": dirty,
        "staged_count": staged,
        "unstaged_count": unstaged,
        "untracked_count": untracked,
        "dirty": dirty > 0,
        "last_commit": last.stdout.strip() if last.returncode == 0 else None,
        "summary": "Clean" if dirty == 0 else f"{dirty} changed files",
    }


def _parse_git_branch(line: str) -> tuple[str | None, int | None, int | None]:
    if not line.startswith("## "):
        return None, None, None
    body = line[3:]
    status = ""
    if " [" in body:
        body, status = body.split(" [", 1)
        status = status.rstrip("]")
    branch = body.split("...", 1)[0]
    ahead = behind = None
    for part in status.split(", "):
        if part.startswith("ahead "):
            ahead = int(part.removeprefix("ahead "))
        elif part.startswith("behind "):
            behind = int(part.removeprefix("behind "))
    return branch or None, ahead, behind


def _memory_overview(project_root: str, tools: list[dict[str, Any]], graph_status: dict[str, Any], home: Path, root_exists: bool) -> dict[str, Any]:
    tool_map = {item["tool_id"]: item for item in tools}
    root = Path(project_root) if project_root else Path()
    summary_path = root / ".projectmem/summary.md"
    agents_path = root / "AGENTS.md"
    codebase_binary = bool(tool_map.get("codebase-memory", {}).get("installed_version"))
    indexed = _codebase_memory_indexed(project_root, home) if root_exists and codebase_binary else None
    agents_block = root_exists and agents_path.exists() and MEMORY_BLOCK_START in agents_path.read_text(encoding="utf-8", errors="replace")
    projectmem_initialized = root_exists and (root / ".projectmem").exists()
    codebase_project_installed = bool(root_exists and codebase_binary and (agents_block or indexed is True))
    graph_available = bool(graph_status.get("project_graph_available") or graph_status.get("available"))
    issues: list[str] = []
    installed_tools: list[dict[str, Any]] = []
    if codebase_project_installed and indexed is False:
        issues.append("codebase_memory_not_indexed")
    setup_mode = _projectmem_setup_mode(summary_path)
    if projectmem_initialized and setup_mode:
        issues.append("projectmem_setup_mode")
    if projectmem_initialized and not agents_block:
        issues.append("agents_memory_block_missing")
    if codebase_project_installed:
        installed_tools.append({"id": "codebase-memory", "name": "Codebase-Memory", "status": "Indexed" if indexed else "Needs index"})
    if projectmem_initialized:
        installed_tools.append({"id": "projectmem", "name": "projectmem", "status": "Setup mode" if setup_mode else "Initialized"})
    if graph_available:
        installed_tools.append({"id": "graphify", "name": "Graphify", "status": "Stale" if graph_status.get("stale") else "Fresh"})
    return {
        "status": "degraded" if issues else ("ok" if installed_tools else "none"),
        "installed_tools": installed_tools,
        "codebase_memory_installed": codebase_project_installed,
        "codebase_memory_indexed": indexed if codebase_project_installed else None,
        "projectmem_installed": projectmem_initialized,
        "projectmem_initialized": projectmem_initialized,
        "projectmem_setup_mode": setup_mode,
        "agents_memory_block": agents_block,
        "graph_available": graph_available,
        "graph_stale": bool(graph_status.get("stale")),
        "issues": issues,
    }


def _codebase_memory_indexed(project_root: str, home: Path) -> bool | None:
    binary = _codebase_memory_bin(home)
    if not binary:
        return False
    result = _run([binary, "cli", "list_projects"], timeout=20)
    text = result.stdout + result.stderr
    start = text.find("{")
    end = text.rfind("}")
    if result.returncode != 0 or start < 0 or end < start:
        return None
    try:
        payload = json.loads(text[start:end + 1])
    except Exception:
        return None
    for item in payload.get("projects", []):
        if normalize_path(item.get("root_path", "")) == project_root:
            return True
    return False


def _projectmem_setup_mode(summary_path: Path) -> bool:
    if not summary_path.exists():
        return False
    text = summary_path.read_text(encoding="utf-8", errors="replace")
    return "Replace this placeholder with a concise description" in text or "None logged yet." in text


def _tool_status_one(tool_id: str, *, home: Path | None = None, latest: bool = True) -> dict[str, Any]:
    home = home or Path.home()
    latest_version = _latest_version(tool_id) if latest else None
    installed = _installed_version(tool_id, home)
    issues = [] if installed else ["not_installed"]
    if installed and latest_version and not _version_ok(installed, latest_version):
        issues.append("update_available")
    return {
        "tool_id": tool_id,
        "name": MANAGED_TOOLS[tool_id]["name"],
        "kind": MANAGED_TOOLS[tool_id]["kind"],
        "detail": MANAGED_TOOLS[tool_id]["detail"],
        "installed_version": installed,
        "latest_version": latest_version,
        "up_to_date": _version_ok(installed, latest_version) if installed and latest_version else None,
        "status": "ok" if not issues else "degraded",
        "updated": False,
        "issues": issues,
        "restart_needed": [],
    }


def _installed_version(tool_id: str, home: Path) -> str | None:
    if tool_id == "codebase-memory":
        binary = _codebase_memory_bin(home)
        if binary:
            out = _run([binary, "--version"], timeout=5)
            return _first_version(out.stdout + out.stderr)
    if tool_id == "graphify":
        version_file = home / ".claude/skills/graphify/.graphify_version"
        if version_file.exists():
            return version_file.read_text(errors="replace").strip() or None
        out = _run(["graphify", "--version"], timeout=5)
        return _first_version(out.stdout + out.stderr)
    if tool_id == "ponytail":
        for path in [
            home / ".claude/plugins/marketplaces/ponytail/.claude-plugin/plugin.json",
            home / ".gemini/extensions/ponytail/gemini-extension.json",
            home / ".codex/plugins/marketplaces/ponytail/.codex-plugin/plugin.json",
        ]:
            version = _json_version(path)
            if version:
                return version
    if tool_id == "projectmem":
        out = _run([sys.executable, "-c", "import importlib.metadata as m; print(m.version('projectmem'))"], timeout=5)
        if out.returncode == 0:
            return _first_version(out.stdout)
    return None


def _latest_version(tool_id: str) -> str | None:
    try:
        req = urllib.request.Request(MANAGED_TOOLS[tool_id]["latest"], headers={"User-Agent": "Soma"})
        with urllib.request.urlopen(req, timeout=12) as response:
            data = json.loads(response.read().decode("utf-8"))
    except Exception:
        return None
    if tool_id in {"graphify", "projectmem"}:
        return data.get("info", {}).get("version")
    tag = data.get("tag_name")
    return tag[1:] if isinstance(tag, str) and tag.startswith("v") else tag


def _setup_codebase_memory(project_root: str, home: Path) -> dict[str, Any]:
    binary = _codebase_memory_bin(home)
    if not binary:
        return {"tool": "codebase-memory", "action": "index", "status": "degraded", "issues": ["not_installed"]}
    config = _run([binary, "config", "set", "auto_index", "true"], timeout=20)
    indexed = _run([binary, "cli", "index_repository", json.dumps({"repo_path": project_root})], timeout=600)
    issues = []
    if config.returncode != 0:
        issues.append("auto_index_config_failed")
    if indexed.returncode != 0:
        issues.append("index_failed")
    return {
        "tool": "codebase-memory",
        "action": "auto_index_and_index",
        "status": "ok" if not issues else "degraded",
        "issues": issues,
        "output": (indexed.stdout + indexed.stderr).strip()[-1200:],
    }


def _setup_projectmem(project_root: str, home: Path) -> dict[str, Any]:
    _ensure_projectmem_cli_links(home)
    pjm = _projectmem_cli(home)
    if not pjm:
        return {"tool": "projectmem", "action": "init", "status": "degraded", "issues": ["not_installed"]}
    result = _run([pjm, "init"], timeout=120, cwd=project_root)
    issues = [] if result.returncode == 0 else ["pjm_init_failed"]
    return {
        "tool": "projectmem",
        "action": "pjm_init",
        "status": "ok" if not issues else "degraded",
        "issues": issues,
        "output": (result.stdout + result.stderr).strip()[-1200:],
    }


def _write_memory_tools_doc(root: Path, tool_ids: set[str] | None = None) -> dict[str, Any]:
    path = root / "AGENTS.md"
    old = path.read_text(encoding="utf-8", errors="replace") if path.exists() else "# Project Instructions\n"
    enabled = _memory_doc_tool_ids(old) | set(tool_ids or MEMORY_TOOL_DOC_ORDER)
    lines = [
        MEMORY_BLOCK_START,
        "## Memory Tools",
        "",
        "Default mode: light. Do not spend tokens on memory tools for small, obvious, single-file tasks.",
        "",
    ]
    lines.extend(MEMORY_TOOL_DOC_LINES[tool_id] for tool_id in MEMORY_TOOL_DOC_ORDER if tool_id in enabled)
    lines.extend([
        "- Keep generated memory/tool state local unless the project explicitly decides to commit it.",
        MEMORY_BLOCK_END,
        "",
    ])
    block = "\n".join(lines)
    if MEMORY_BLOCK_START in old and MEMORY_BLOCK_END in old:
        updated = re.sub(rf"{re.escape(MEMORY_BLOCK_START)}.*?{re.escape(MEMORY_BLOCK_END)}", block.strip(), old, flags=re.DOTALL)
    else:
        updated = old.rstrip() + "\n\n" + block
    if updated == old:
        return {"tool": "memory-tools", "action": "write_docs", "status": "ok", "issues": [], "path": str(path), "changed": False}
    backup = _backup(path) if path.exists() else None
    if backup:
        backup.write_text(old, encoding="utf-8")
    path.write_text(updated, encoding="utf-8")
    return {"tool": "memory-tools", "action": "write_docs", "status": "ok", "issues": [], "path": str(path), "backup_path": str(backup) if backup else None, "changed": True}


def _memory_doc_tool_ids(text: str) -> set[str]:
    match = re.search(rf"{re.escape(MEMORY_BLOCK_START)}(.*?){re.escape(MEMORY_BLOCK_END)}", text, flags=re.DOTALL)
    block = match.group(1) if match else ""
    enabled: set[str] = set()
    if "Codebase-Memory" in block:
        enabled.add("codebase-memory")
    if "projectmem" in block:
        enabled.add("projectmem")
    return enabled


def _sync_projectmem_clients(project_root: str, home: Path) -> dict[str, Any]:
    clients: list[dict[str, Any]] = []
    issues: list[str] = []
    for config in _global_configs(home):
        if config["kind"] == "codex":
            result = _install_projectmem_codex_config(config["path"], project_root)
        elif config["kind"] == "json":
            result = _install_projectmem_json_config(config["path"], project_root)
        else:
            continue
        clients.append(_client_result(config["client"], result, config["path"], project_root, restart=True))
        issues.extend(result.get("issues", []))
    return {
        "status": "ok" if not issues else "degraded",
        "clients": clients,
        "issues": sorted(set(issues)),
        "restart_needed": sorted({item["client"] for item in clients if item.get("restart_needed")}),
    }


def _install_projectmem_codex_config(path: Path, project_root: str) -> dict[str, Any]:
    existing = path.read_text(errors="replace") if path.exists() else ""
    backup = _backup(path) if path.exists() else None
    if backup:
        backup.write_text(existing, encoding="utf-8")
    cleaned, _ = _remove_projectmem_toml_block(existing)
    root = normalize_path(project_root)
    block = "\n".join(
        [
            "[mcp_servers.projectmem]",
            f"command = {json.dumps(sys.executable)}",
            f"args = {json.dumps(['-m', 'projectmem.mcp_server', '--root', root])}",
            f"cwd = {json.dumps(root)}",
        ]
    )
    updated = f"{cleaned.strip()}\n\n{block}\n" if cleaned.strip() else f"{block}\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(updated, encoding="utf-8")
    return {"status": "ok", "summary": "Installed projectmem MCP config.", "config_path": str(path), "backup_path": str(backup) if backup else None, "issues": []}


def _install_projectmem_json_config(path: Path, project_root: str) -> dict[str, Any]:
    existing = path.read_text(errors="replace") if path.exists() else ""
    backup = _backup(path) if path.exists() else None
    if backup:
        backup.write_text(existing, encoding="utf-8")
    try:
        settings = json.loads(existing or "{}")
        if not isinstance(settings, dict):
            settings = {}
    except Exception:
        return {"status": "error", "summary": "JSON config is invalid.", "config_path": str(path), "backup_path": str(backup) if backup else None, "issues": ["invalid_json"]}
    servers = settings.get("mcpServers")
    if not isinstance(servers, dict):
        servers = {}
        settings["mcpServers"] = servers
    root = normalize_path(project_root)
    servers["projectmem"] = {"command": sys.executable, "args": ["-m", "projectmem.mcp_server", "--root", root], "cwd": root}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(settings, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    return {"status": "ok", "summary": "Installed projectmem MCP config.", "config_path": str(path), "backup_path": str(backup) if backup else None, "issues": []}


def _remove_projectmem_toml_block(text: str) -> tuple[str, int]:
    header = re.compile(r"^\s*\[mcp_servers\.projectmem\]\s*(?:#.*)?$")
    any_header = re.compile(r"^\s*\[")
    kept: list[str] = []
    removed = 0
    skipping = False
    for line in text.splitlines():
        if header.match(line):
            skipping = True
            removed += 1
            continue
        if skipping and any_header.match(line):
            skipping = False
        if not skipping:
            kept.append(line)
    return "\n".join(kept).strip(), removed


def _global_configs(home: Path) -> list[dict[str, Any]]:
    return [
        {"client": "codex", "kind": "codex", "path": home / ".codex/config.toml"},
        {"client": "gemini", "kind": "json", "path": home / ".gemini/settings.json", "json_client": "gemini"},
        {"client": "gemini", "kind": "json", "path": home / ".gemini/config/mcp_config.json", "json_client": "gemini"},
        {"client": "antigravity", "kind": "json", "path": home / ".gemini/antigravity-ide/mcp_config.json", "json_client": "gemini"},
        {"client": "antigravity", "kind": "antigravity_tools", "path": home / ".gemini/antigravity/mcp"},
        {"client": "claude", "kind": "json", "path": home / ".claude.json", "json_client": "claude"},
        {"client": "claude", "kind": "json", "path": home / "Library/Application Support/Claude/claude_desktop_config.json", "json_client": "claude"},
        {"client": "hermes", "kind": "hermes", "path": home / ".hermes/config.yaml"},
    ]


def _project_configs(projects: list[Path]) -> list[dict[str, Any]]:
    configs: list[dict[str, Any]] = []
    for root in projects:
        configs.extend(
            [
                {"client": "codex", "kind": "codex", "path": root / ".codex/config.toml", "project_root": str(root), "only_existing": True},
                {"client": "gemini", "kind": "json", "path": root / ".gemini/settings.json", "project_root": str(root), "json_client": "gemini", "only_existing": True},
                {"client": "claude", "kind": "json", "path": root / ".mcp.json", "project_root": str(root), "json_client": "claude", "only_existing": True},
            ]
        )
    return [item for item in configs if not item.get("only_existing") or item["path"].exists()]


def _verify_config(config: dict[str, Any]) -> dict[str, Any]:
    client = config["client"]
    path = config["path"]
    expected = config.get("project_root")
    if config["kind"] == "codex":
        result = verify_codex_config(path, expected)
    elif config["kind"] == "hermes":
        result = verify_hermes_config(path, expected)
    elif config["kind"] == "antigravity_tools":
        result = _verify_antigravity_tools(path)
    else:
        result = _verify_json_config(path, expected)
    return _client_result(client, result, path, expected)


def _sync_config(config: dict[str, Any]) -> dict[str, Any]:
    client = config["client"]
    path = config["path"]
    expected = config.get("project_root")
    if config["kind"] == "codex":
        result = install_codex_config(path, expected, sys.executable)
    elif config["kind"] == "hermes":
        result = install_hermes_config(path, expected, sys.executable)
    elif config["kind"] == "antigravity_tools":
        result = _sync_antigravity_tools(path)
    else:
        result = _install_json_config(path, expected, config.get("json_client", "gemini"))
    return _client_result(client, result, path, expected, restart=True)


def _verify_json_config(path: Path, expected_project_root: str | None = None) -> dict[str, Any]:
    expected = normalize_path(expected_project_root) if expected_project_root else None
    if not path.exists():
        return _json_result(path, expected, ["missing_config"], None, {}, False)
    try:
        settings = json.loads(path.read_text(errors="replace") or "{}")
    except Exception:
        return _json_result(path, expected, ["invalid_json"], None, {}, False)
    servers = settings.get("mcpServers") if isinstance(settings, dict) else {}
    servers = servers if isinstance(servers, dict) else {}
    soma = servers.get("soma") if isinstance(servers.get("soma"), dict) else {}
    actual = _extract_json_soma_project_root(soma)
    direct = any(_entry_mentions_direct_unity(name, entry) for name, entry in servers.items())
    unity = any("unity_" in json.dumps(entry, default=str).lower() for name, entry in servers.items() if name != "soma")
    issues: list[str] = []
    if not soma:
        issues.append("soma_server_missing")
    if soma and "soma_mcp_server.py" not in json.dumps(soma, default=str):
        issues.append("soma_script_missing")
    if direct:
        issues.append("direct_nexus_exposed")
    if unity:
        issues.append("unity_tool_marker_found")
    if expected and not actual:
        issues.append("project_root_missing")
    elif expected and actual != expected:
        issues.append("project_root_mismatch")
    return _json_result(path, expected, issues, actual, soma, not direct and not unity)


def _install_json_config(path: Path, project_root: str | None, client: str) -> dict[str, Any]:
    existing = path.read_text(errors="replace") if path.exists() else ""
    backup = _backup(path) if path.exists() else None
    if backup:
        backup.write_text(existing, encoding="utf-8")
    try:
        settings = json.loads(existing or "{}")
        if not isinstance(settings, dict):
            settings = {}
    except Exception:
        return {"status": "error", "summary": "JSON config is invalid.", "config_path": str(path), "backup_path": str(backup) if backup else None, "issues": ["invalid_json"]}
    servers = settings.get("mcpServers")
    if not isinstance(servers, dict):
        servers = {}
        settings["mcpServers"] = servers
    removed = 0
    for name in list(servers):
        if _entry_mentions_direct_unity(name, servers[name]):
            removed += 1
            servers.pop(name, None)
    snippet = json.loads(build_client_config(client, project_root, sys.executable))
    servers["soma"] = snippet["mcpServers"]["soma"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(settings, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    result = _verify_json_config(path, project_root)
    result.update({"summary": "Installed Soma MCP config.", "backup_path": str(backup) if backup else None, "direct_nexus_removed": removed > 0})
    return result


def _verify_antigravity_tools(path: Path) -> dict[str, Any]:
    issues = []
    if (path / "nexus-unity").exists():
        issues.append("direct_tool_dir_exposed")
    if not (path / "soma").exists():
        issues.append("soma_tool_dir_missing")
    return {"status": "ok" if not issues else "degraded", "summary": "Antigravity tool dirs checked.", "config_path": str(path), "issues": issues}


def _sync_antigravity_tools(path: Path) -> dict[str, Any]:
    result = _verify_antigravity_tools(path)
    direct = path / "nexus-unity"
    if direct.exists():
        backup = _unused_path(path / f"nexus-unity.disabled-soma-backup-{_stamp()}")
        direct.rename(backup)
        result = _verify_antigravity_tools(path)
        result["backup_path"] = str(backup)
    return result


def _json_result(path: Path, expected: str | None, issues: list[str], actual: str | None, soma: dict[str, Any], clean: bool) -> dict[str, Any]:
    root_ok = "project_root_missing" not in issues and "project_root_mismatch" not in issues
    status_ok = bool(soma) and clean and "soma_script_missing" not in issues and root_ok
    return {
        "status": "ok" if status_ok else "degraded",
        "summary": "Config points to Soma only." if status_ok else "Config needs Soma-only cleanup.",
        "config_path": str(path),
        "soma_installed": bool(soma),
        "direct_nexus_exposed": not clean,
        "tool_exposure_clean": clean,
        "actual_project_root": actual,
        "expected_project_root": expected,
        "project_matches": None if not expected or not actual else actual == expected,
        "issues": issues,
    }


def _client_result(client: str, result: dict[str, Any], path: Path, project_root: str | None, restart: bool = False) -> dict[str, Any]:
    return {
        **result,
        "client": client,
        "config_path": str(path),
        "project_root": project_root,
        "restart_needed": restart and client in {"codex", "gemini", "antigravity", "claude", "hermes"},
    }


def _project_roots(project_root: str | None, recent_roots: list[str], home: Path) -> list[Path]:
    roots: list[Path] = []
    for value in [project_root, *recent_roots, *_roots_from_existing_configs(home)]:
        if value:
            _append_root(roots, Path(value).expanduser())
    for base in [home / "Daliys", home / "Documents", home / "Projects"]:
        if base.exists():
            _scan_projects(base, roots)
    return roots


def _scan_projects(base: Path, roots: list[Path], max_depth: int = 4) -> None:
    base = base.resolve()
    for current, dirs, files in os.walk(base):
        path = Path(current)
        depth = len(path.relative_to(base).parts)
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".") and depth < max_depth]
        if any(marker in files or (path / marker).exists() for marker in PROJECT_MARKERS) or (path / ".codex/config.toml").exists() or (path / ".gemini/settings.json").exists():
            _append_root(roots, path)


def _roots_from_existing_configs(home: Path) -> list[str]:
    roots: list[str] = []
    for path in [home / ".codex/config.toml", home / ".gemini/settings.json", home / ".gemini/config/mcp_config.json", home / ".gemini/antigravity-ide/mcp_config.json"]:
        if path.exists():
            text = path.read_text(errors="replace")
            roots.extend(re.findall(r'"--project-root"\s*,\s*"([^"]+)"', text))
            roots.extend(re.findall(r'SOMA_PROJECT_ROOT"?\s*[:=]\s*"([^"]+)"', text))
    return roots


def _append_root(roots: list[Path], value: Path) -> None:
    try:
        resolved = value.resolve()
    except Exception:
        return
    if resolved.exists() and resolved.is_dir() and resolved not in roots:
        roots.append(resolved)


def _smoke_project(project_root: str | None) -> dict[str, Any]:
    if not project_root:
        return {"status": "skipped", "summary": "No selected project root."}
    try:
        from gateway.tool_registry import call_tool

        raw = asyncio.run(call_tool("soma_prepare_context", {"goal": "Soma extension update verification smoke.", "budget": "micro", "depth": "deterministic", "client": "swift", "workflow": "extension_update"}))
        payload = json.loads(raw)
        return {"status": payload.get("status", "ok"), "summary": "soma_prepare_context smoke completed."}
    except Exception as exc:
        return {"status": "degraded", "summary": str(exc)[:300]}


def _visible_clients() -> list[str]:
    out = _run(["/bin/zsh", "-lc", "osascript -e 'tell application \"System Events\" to get name of every application process whose background only is false' 2>/dev/null"], timeout=5)
    names = out.stdout.lower()
    return [name for name in ["codex", "antigravity", "claude"] if name in names]


def _backup(path: Path) -> Path:
    return _unused_path(path.with_name(f"{path.name}.soma-backup-{_stamp()}"))


def _unused_path(path: Path) -> Path:
    if not path.exists():
        return path
    for index in range(1, 1000):
        candidate = path.with_name(f"{path.name}.{index}")
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"No free backup path for {path}")


def _stamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S")


def _run_shell(command: str, *, home: Path | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    user_bin = _python_user_bin()
    env["PATH"] = f"{env.get('PATH', '')}:/opt/homebrew/bin:/usr/local/bin:{Path.home() / '.local/bin'}:{user_bin}"
    env["SOMA_PYTHON"] = sys.executable
    if home:
        env["HOME"] = str(home)
    return subprocess.run(["/bin/zsh", "-lc", command], text=True, capture_output=True, env=env, timeout=300)


def _run(cmd: list[str], timeout: int = 10, cwd: str | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(cmd, text=True, capture_output=True, timeout=timeout, cwd=cwd)
    except Exception as exc:
        return subprocess.CompletedProcess(cmd, 1, "", str(exc))


def _codebase_memory_bin(home: Path) -> str | None:
    for value in [shutil.which("codebase-memory-mcp"), str(home / ".local/bin/codebase-memory-mcp"), "/opt/homebrew/bin/codebase-memory-mcp", "/usr/local/bin/codebase-memory-mcp"]:
        if value and Path(value).exists():
            return value
    return None


def _projectmem_cli(home: Path) -> str | None:
    for value in [shutil.which("pjm"), str(_python_user_bin() / "pjm"), str(home / ".local/bin/pjm")]:
        if value and Path(value).exists():
            return value
    return None


def _ensure_projectmem_cli_links(home: Path) -> None:
    source_dir = _python_user_bin()
    target_dir = home / ".local/bin"
    for name in ("pjm", "projectmem", "pjm-mcp"):
        source = source_dir / name
        target = target_dir / name
        if not source.exists() or target.exists():
            continue
        try:
            target_dir.mkdir(parents=True, exist_ok=True)
            target.symlink_to(source)
        except Exception:
            pass


def _python_user_bin() -> Path:
    out = subprocess.run([sys.executable, "-m", "site", "--user-base"], text=True, capture_output=True, timeout=5)
    base = out.stdout.strip() if out.returncode == 0 else str(Path.home() / "Library/Python")
    return Path(base) / "bin"


def _json_version(path: Path) -> str | None:
    try:
        data = json.loads(path.read_text(errors="replace"))
    except Exception:
        return None
    return data.get("version") or data.get("tag") or data.get("installedVersion")


def _first_version(text: str) -> str | None:
    match = re.search(r"\d+(?:\.\d+)+(?:[-a-zA-Z0-9.]*)?", text or "")
    return match.group(0) if match else None


def _version_ok(installed: str | None, latest: str | None) -> bool:
    return bool(installed and latest and installed == latest)
