"""Client MCP configuration helpers.

Codex can be installed/rolled back directly. Gemini and Claude remain copy-only
config snippets until their mutation flows are proven.
"""
from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path
from typing import Any

from scout_pipeline import normalize_path


def server_script_path() -> str:
    return normalize_path(Path(__file__).parent.parent / "soma_mcp_server.py")


def build_client_config(client: str, project_root: str | None = None, python_executable: str | None = None) -> str:
    root = normalize_path(project_root) if project_root else ""
    python = python_executable or sys.executable or "/opt/homebrew/bin/python3"
    script = server_script_path()

    if client == "codex":
        args = f'["{script}", "--project-root", "{root}"]' if root else f'["{script}"]'
        env_line = f'env = {{ SOMA_PROJECT_ROOT = "{root}" }}' if root else '# env = { SOMA_PROJECT_ROOT = "/absolute/project/root" }'
        return "\n".join(
            [
                "[mcp_servers.soma]",
                f'command = "{python}"',
                f"args = {args}",
                env_line,
                "# Keep Big AI connected to Soma only; remove direct Unity MCP entries for this workflow.",
            ]
        )

    if client not in {"gemini", "claude"}:
        raise ValueError(f"unknown client: {client}")

    payload = {
        "mcpServers": {
            "soma": {
                "command": python,
                "args": [script] + (["--project-root", root] if root else []),
                "env": {"SOMA_PROJECT_ROOT": root} if root else {},
            }
        },
        "_note": f"Merge this into {client} MCP settings. Keep Big AI connected only to Soma.",
    }
    return json.dumps(payload, indent=2, sort_keys=True)


def codex_config_default_path() -> Path:
    return Path.home() / ".codex" / "config.toml"


def _timestamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S")


def _backup_path(config_path: Path) -> Path:
    base = config_path.with_name(f"{config_path.name}.soma-backup-{_timestamp()}")
    if not base.exists():
        return base
    index = 1
    while True:
        candidate = config_path.with_name(f"{config_path.name}.soma-backup-{_timestamp()}-{index}")
        if not candidate.exists():
            return candidate
        index += 1


def _codex_backup_candidates(config_path: Path) -> list[Path]:
    return sorted(
        config_path.parent.glob(f"{config_path.name}.soma-backup-*"),
        key=lambda path: (path.stat().st_mtime, path.name),
        reverse=True,
    )


def _remove_toml_table_block(text: str, table_name: str) -> tuple[str, int]:
    header_pattern = re.compile(rf"^\s*\[{re.escape(table_name)}\]\s*(?:#.*)?$")
    any_header_pattern = re.compile(r"^\s*\[")
    lines = text.splitlines()
    kept: list[str] = []
    removed = 0
    skipping = False

    for line in lines:
        if header_pattern.match(line):
            skipping = True
            removed += 1
            continue
        if skipping and any_header_pattern.match(line):
            skipping = False
        if skipping:
            continue
        kept.append(line)

    return "\n".join(kept).strip(), removed


def _count_toml_table(text: str, table_name: str) -> int:
    pattern = re.compile(rf"^\s*\[{re.escape(table_name)}\]\s*(?:#.*)?$", re.MULTILINE)
    return len(pattern.findall(text))


def install_codex_config(
    config_path: str | Path | None = None,
    project_root: str | None = None,
    python_executable: str | None = None,
) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else codex_config_default_path()
    existing = path.read_text(errors="replace") if path.exists() else ""
    backup: Path | None = None
    if path.exists():
        backup = _backup_path(path)
        backup.write_text(existing)

    cleaned, old_soma_blocks = _remove_toml_table_block(existing, "mcp_servers.soma")
    cleaned, direct_nexus_blocks = _remove_toml_table_block(cleaned, "mcp_servers.nexus-unity")
    cleaned = cleaned.strip()
    soma_config = build_client_config("codex", project_root, python_executable).strip()
    updated = f"{cleaned}\n\n{soma_config}\n" if cleaned else f"{soma_config}\n"

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(updated)

    verification = verify_codex_config(path)
    return {
        "status": verification["status"],
        "summary": "Installed Codex MCP config for Soma.",
        "config_path": str(path),
        "backup_path": str(backup) if backup else None,
        "soma_installed": verification["soma_installed"],
        "direct_nexus_removed": direct_nexus_blocks > 0,
        "old_soma_blocks_replaced": old_soma_blocks,
        "issues": verification["issues"],
    }


def rollback_codex_config(
    config_path: str | Path | None = None,
    backup_path: str | Path | None = None,
) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else codex_config_default_path()
    if backup_path:
        selected_backup = Path(backup_path).expanduser()
    else:
        candidates = _codex_backup_candidates(path)
        selected_backup = candidates[0] if candidates else None

    if not selected_backup or not selected_backup.exists():
        return {
            "status": "degraded",
            "summary": "No Codex Soma backup found to restore.",
            "config_path": str(path),
            "backup_path": str(selected_backup) if selected_backup else None,
            "restored": False,
            "issues": ["missing_backup"],
        }

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(selected_backup.read_text(errors="replace"))
    verification = verify_codex_config(path)
    return {
        "status": "ok",
        "summary": "Restored Codex config from Soma backup.",
        "config_path": str(path),
        "backup_path": str(selected_backup),
        "restored": True,
        "post_restore_status": verification["status"],
        "post_restore_issues": verification["issues"],
    }


def verify_codex_config(config_path: str | Path | None = None) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else codex_config_default_path()
    issues: list[str] = []
    if not path.exists():
        return {
            "status": "degraded",
            "summary": "Codex config file not found.",
            "config_path": str(path),
            "soma_installed": False,
            "direct_nexus_exposed": False,
            "tool_exposure_clean": False,
            "issues": ["missing_config"],
        }

    text = path.read_text(errors="replace")
    soma_blocks = _count_toml_table(text, "mcp_servers.soma")
    has_soma_script = "soma_mcp_server.py" in text
    direct_nexus_exposed = any(marker in text for marker in ("[mcp_servers.nexus-unity]", "nexus_unity_bridge", "nexus-unity"))
    unity_tool_exposed = "unity_" in text

    if soma_blocks != 1:
        issues.append(f"soma_table_count={soma_blocks}")
    if not has_soma_script:
        issues.append("soma_script_missing")
    if direct_nexus_exposed:
        issues.append("direct_nexus_exposed")
    if unity_tool_exposed:
        issues.append("unity_tool_marker_found")

    clean = not direct_nexus_exposed and not unity_tool_exposed
    return {
        "status": "ok" if soma_blocks == 1 and has_soma_script and clean else "degraded",
        "summary": "Codex config points to Soma only." if soma_blocks == 1 and has_soma_script and clean else "Codex config needs Soma-only cleanup.",
        "config_path": str(path),
        "soma_installed": soma_blocks == 1 and has_soma_script,
        "direct_nexus_exposed": direct_nexus_exposed,
        "tool_exposure_clean": clean,
        "issues": issues,
    }
