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
MANAGED_TOOLS = {
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
    "serena": {
        "name": "Serena",
        "kind": "MCP",
        "detail": "MCP code retrieval server.",
        "latest": "https://pypi.org/pypi/serena-agent/json",
        "command": "uv tool upgrade serena-agent",
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
    if tool_id == "serena":
        for dist in (home / ".local/share/uv/tools/serena-agent/lib").glob("python*/site-packages/serena_agent-*.dist-info"):
            return dist.name.removeprefix("serena_agent-").removesuffix(".dist-info")
        out = _run(["serena", "--version"], timeout=5)
        return _first_version(out.stdout + out.stderr)
    return None


def _latest_version(tool_id: str) -> str | None:
    try:
        req = urllib.request.Request(MANAGED_TOOLS[tool_id]["latest"], headers={"User-Agent": "Soma"})
        with urllib.request.urlopen(req, timeout=12) as response:
            data = json.loads(response.read().decode("utf-8"))
    except Exception:
        return None
    if tool_id in {"graphify", "serena"}:
        return data.get("info", {}).get("version")
    tag = data.get("tag_name")
    return tag[1:] if isinstance(tag, str) and tag.startswith("v") else tag


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
    env["PATH"] = f"{env.get('PATH', '')}:/opt/homebrew/bin:/usr/local/bin:{Path.home() / '.local/bin'}"
    if home:
        env["HOME"] = str(home)
    return subprocess.run(["/bin/zsh", "-lc", command], text=True, capture_output=True, env=env, timeout=300)


def _run(cmd: list[str], timeout: int = 10) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(cmd, text=True, capture_output=True, timeout=timeout)
    except Exception as exc:
        return subprocess.CompletedProcess(cmd, 1, "", str(exc))


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
