"""Client MCP configuration helpers.

Codex uses TOML, Gemini/Claude use JSON settings, and Hermes uses YAML. The
install flows keep a backup, install a Soma-only MCP server entry for the
selected project, and verify that direct Unity/Nexus servers are not exposed to
the large model.
"""

from __future__ import annotations

import json
import re
import shutil
import sys
import time
from pathlib import Path
from typing import Any

from soma_logger import log_mcp_event
from scout_pipeline import normalize_path


def server_script_path() -> str:
    return normalize_path(Path(__file__).parent.parent / "soma_mcp_server.py")


def build_client_config(client: str, project_root: str | None = None, python_executable: str | None = None) -> str:
    root = normalize_path(project_root) if project_root else ""
    python = python_executable or sys.executable or "/opt/homebrew/bin/python3"
    script = server_script_path()

    if client == "codex":
        args = f'["{script}", "--project-root", "{root}"]' if root else f'["{script}"]'
        env_line = (
            f'env = {{ SOMA_PROJECT_ROOT = "{root}" }}'
            if root
            else '# env = { SOMA_PROJECT_ROOT = "/absolute/project/root" }'
        )
        return "\n".join(
            [
                "[mcp_servers.soma]",
                f'command = "{python}"',
                f"args = {args}",
                env_line,
                "# Keep Big AI connected to Soma only; remove direct Unity MCP entries for this workflow.",
            ]
        )

    if client == "hermes":
        return _format_hermes_soma_block(root, python, script).strip()

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
    if client == "gemini":
        payload["mcpServers"]["soma"]["trust"] = True
    return json.dumps(payload, indent=2, sort_keys=True)


def codex_config_default_path() -> Path:
    return Path.home() / ".codex" / "config.toml"


def gemini_config_default_path() -> Path:
    return Path.home() / ".gemini" / "settings.json"


def hermes_config_default_path() -> Path:
    return Path.home() / ".hermes" / "config.yaml"


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


def _backup_candidates(config_path: Path) -> list[Path]:
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


def _path_matches(lhs: str | None, rhs: str | None) -> bool | None:
    if not lhs or not rhs:
        return None
    return normalize_path(lhs) == normalize_path(rhs)


def _extract_codex_project_root(text: str) -> str | None:
    env_match = re.search(r'SOMA_PROJECT_ROOT\s*=\s*"([^"]+)"', text)
    if env_match:
        return normalize_path(env_match.group(1))
    arg_match = re.search(r'"--project-root"\s*,\s*"([^"]+)"', text)
    if arg_match:
        return normalize_path(arg_match.group(1))
    return None


def _extract_json_soma_project_root(server: dict[str, Any]) -> str | None:
    env = server.get("env") if isinstance(server.get("env"), dict) else {}
    if env.get("SOMA_PROJECT_ROOT"):
        return normalize_path(str(env["SOMA_PROJECT_ROOT"]))
    args = server.get("args") if isinstance(server.get("args"), list) else []
    for index, value in enumerate(args):
        if value == "--project-root" and index + 1 < len(args):
            return normalize_path(str(args[index + 1]))
    return None


def _yaml_quote(value: str) -> str:
    return json.dumps(value)


def _format_hermes_soma_block(root: str, python: str, script: str | None = None) -> str:
    script = script or server_script_path()
    args = [script] + (["--project-root", root] if root else [])
    lines = [
        "mcp_servers:",
        "  soma:",
        f"    command: {_yaml_quote(python)}",
        f"    args: {json.dumps(args)}",
        "    env:",
    ]
    if root:
        lines.append(f"      SOMA_PROJECT_ROOT: {_yaml_quote(root)}")
    else:
        lines.append('      SOMA_PROJECT_ROOT: "/absolute/project/root"')
    lines.append("    enabled: true")
    return "\n".join(lines) + "\n"


def _split_hermes_mcp_block(text: str) -> tuple[list[str], list[str], list[str]]:
    lines = text.splitlines()
    start: int | None = None
    for index, line in enumerate(lines):
        if re.match(r"^mcp_servers\s*:\s*(?:#.*)?$", line):
            start = index
            break
    if start is None:
        return lines, [], []

    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.strip() and not line.startswith((" ", "\t", "#")):
            end = index
            break
    return lines[:start], lines[start:end], lines[end:]


def _hermes_server_blocks(mcp_block: list[str]) -> list[tuple[str, list[str]]]:
    blocks: list[tuple[str, list[str]]] = []
    current_name: str | None = None
    current_lines: list[str] = []
    for line in mcp_block[1:]:
        match = re.match(r"^\s{2}([A-Za-z0-9_.-]+)\s*:\s*(?:#.*)?$", line)
        if match:
            if current_name is not None:
                blocks.append((current_name, current_lines))
            current_name = match.group(1)
            current_lines = [line]
        elif current_name is not None:
            current_lines.append(line)
    if current_name is not None:
        blocks.append((current_name, current_lines))
    return blocks


def _yaml_scalar(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    if value[0] in {'"', "'"}:
        try:
            return json.loads(value) if value[0] == '"' else value.strip("'")
        except Exception:
            return value.strip("\"'")
    return value.split(" #", 1)[0].strip()


def _parse_hermes_server_block(lines: list[str]) -> dict[str, Any]:
    server: dict[str, Any] = {"env": {}, "args": []}
    index = 1
    while index < len(lines):
        line = lines[index]
        command_match = re.match(r"^\s{4}command\s*:\s*(.+?)\s*$", line)
        args_match = re.match(r"^\s{4}args\s*:\s*(.*)$", line)
        enabled_match = re.match(r"^\s{4}enabled\s*:\s*(.+?)\s*$", line)
        env_root_match = re.match(r"^\s{6}SOMA_PROJECT_ROOT\s*:\s*(.+?)\s*$", line)
        if command_match:
            server["command"] = _yaml_scalar(command_match.group(1))
        elif enabled_match:
            server["enabled"] = _yaml_scalar(enabled_match.group(1)).lower() not in {"false", "0", "no", "off"}
        elif env_root_match:
            server.setdefault("env", {})["SOMA_PROJECT_ROOT"] = _yaml_scalar(env_root_match.group(1))
        elif args_match:
            raw = args_match.group(1).strip()
            if raw.startswith("["):
                try:
                    parsed = json.loads(raw)
                    if isinstance(parsed, list):
                        server["args"] = [str(item) for item in parsed]
                except Exception:
                    server["args"] = re.findall(r'"([^"]+)"|\'([^\']+)\'|([^\s,\[\]]+)', raw)
            elif not raw:
                values: list[str] = []
                lookahead = index + 1
                while lookahead < len(lines):
                    item_match = re.match(r"^\s{6}-\s*(.+?)\s*$", lines[lookahead])
                    if not item_match:
                        break
                    values.append(_yaml_scalar(item_match.group(1)))
                    lookahead += 1
                server["args"] = values
        index += 1
    server.setdefault("enabled", True)
    return server


def _extract_hermes_project_root(server: dict[str, Any]) -> str | None:
    return _extract_json_soma_project_root(server)


def _render_hermes_config_with_soma(
    text: str,
    project_root: str | None,
    python_executable: str | None,
) -> tuple[str, int, int]:
    before, mcp_block, after = _split_hermes_mcp_block(text)
    root = normalize_path(project_root) if project_root else ""
    python = python_executable or sys.executable or "/opt/homebrew/bin/python3"
    soma_lines = _format_hermes_soma_block(root, python).splitlines()[1:]
    kept_blocks: list[list[str]] = []
    old_soma_blocks = 0
    direct_removed = 0
    for name, block_lines in _hermes_server_blocks(mcp_block):
        rendered = "\n".join(block_lines)
        if name == "soma":
            old_soma_blocks += 1
            continue
        if _entry_mentions_direct_unity(name, rendered):
            direct_removed += 1
            continue
        kept_blocks.append(block_lines)

    merged: list[str] = [line for line in before if line.strip()]
    if merged:
        merged.append("")
    merged.append("mcp_servers:")
    for block_lines in kept_blocks:
        merged.extend(block_lines)
    merged.extend(soma_lines)
    if after:
        merged.append("")
        merged.extend(after)
    return "\n".join(merged).rstrip() + "\n", old_soma_blocks, direct_removed


def _entry_mentions_direct_unity(name: str, entry: Any) -> bool:
    rendered = json.dumps(entry, default=str).lower()
    lowered_name = name.lower()
    if name == "soma":
        return False
    return any(
        marker in lowered_name or marker in rendered for marker in ("nexus", "unity", "unity_", "nexus_unity_bridge")
    )


def _remove_direct_unity_servers(settings: dict[str, Any]) -> int:
    servers = settings.get("mcpServers")
    if not isinstance(servers, dict):
        return 0
    removed = 0
    for name in list(servers.keys()):
        if _entry_mentions_direct_unity(name, servers.get(name)):
            servers.pop(name, None)
            removed += 1
    return removed


def _log_client_config(client: str, action: str, result: dict[str, Any], project_root: str | None = None) -> None:
    log_mcp_event(
        event=f"client_config_{action}",
        status=result.get("status", "ok"),
        project_root=project_root,
        extra={
            "client": client,
            "config_path": result.get("config_path"),
            "backup_path": result.get("backup_path"),
            "issues": result.get("issues") or result.get("post_restore_issues") or [],
            "project_matches": result.get("project_matches"),
        },
    )
    if result.get("project_matches") is False:
        log_mcp_event(
            event="client_project_mismatch",
            status="degraded",
            project_root=project_root,
            extra={
                "client": client,
                "config_path": result.get("config_path"),
                "actual_project_root": result.get("actual_project_root"),
                "expected_project_root": result.get("expected_project_root"),
            },
        )


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

    verification = verify_codex_config(path, project_root)
    result = {
        "status": verification["status"],
        "summary": "Installed Codex MCP config for Soma.",
        "config_path": str(path),
        "backup_path": str(backup) if backup else None,
        "soma_installed": verification["soma_installed"],
        "direct_nexus_removed": direct_nexus_blocks > 0,
        "old_soma_blocks_replaced": old_soma_blocks,
        "actual_project_root": verification.get("actual_project_root"),
        "expected_project_root": verification.get("expected_project_root"),
        "project_matches": verification.get("project_matches"),
        "issues": verification["issues"],
    }
    _log_client_config("codex", "install", result, project_root)
    return result


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
    result = {
        "status": "ok",
        "summary": "Restored Codex config from Soma backup.",
        "config_path": str(path),
        "backup_path": str(selected_backup),
        "restored": True,
        "post_restore_status": verification["status"],
        "post_restore_issues": verification["issues"],
    }
    _log_client_config("codex", "rollback", result)
    return result


def verify_codex_config(
    config_path: str | Path | None = None, expected_project_root: str | None = None
) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else codex_config_default_path()
    issues: list[str] = []
    if not path.exists():
        result = {
            "status": "degraded",
            "summary": "Codex config file not found.",
            "config_path": str(path),
            "soma_installed": False,
            "direct_nexus_exposed": False,
            "tool_exposure_clean": False,
            "actual_project_root": None,
            "expected_project_root": normalize_path(expected_project_root) if expected_project_root else None,
            "project_matches": None,
            "issues": ["missing_config"],
        }
        _log_client_config("codex", "verify", result, expected_project_root)
        return result

    text = path.read_text(errors="replace")
    soma_blocks = _count_toml_table(text, "mcp_servers.soma")
    has_soma_script = "soma_mcp_server.py" in text
    direct_nexus_exposed = any(
        marker in text for marker in ("[mcp_servers.nexus-unity]", "nexus_unity_bridge", "nexus-unity")
    )
    unity_tool_exposed = "unity_" in text
    actual_project_root = _extract_codex_project_root(text)
    expected = normalize_path(expected_project_root) if expected_project_root else None
    project_matches = _path_matches(actual_project_root, expected)

    if soma_blocks != 1:
        issues.append(f"soma_table_count={soma_blocks}")
    if not has_soma_script:
        issues.append("soma_script_missing")
    if direct_nexus_exposed:
        issues.append("direct_nexus_exposed")
    if unity_tool_exposed:
        issues.append("unity_tool_marker_found")
    if expected and project_matches is False:
        issues.append("project_root_mismatch")

    clean = not direct_nexus_exposed and not unity_tool_exposed
    status_ok = soma_blocks == 1 and has_soma_script and clean and project_matches is not False
    result = {
        "status": "ok" if status_ok else "degraded",
        "summary": "Codex config points to Soma only." if status_ok else "Codex config needs Soma-only cleanup.",
        "config_path": str(path),
        "soma_installed": soma_blocks == 1 and has_soma_script,
        "direct_nexus_exposed": direct_nexus_exposed,
        "tool_exposure_clean": clean,
        "actual_project_root": actual_project_root,
        "expected_project_root": expected,
        "project_matches": project_matches,
        "issues": issues,
    }
    _log_client_config("codex", "verify", result, expected_project_root)
    return result


def install_gemini_config(
    config_path: str | Path | None = None,
    project_root: str | None = None,
    python_executable: str | None = None,
) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else gemini_config_default_path()
    existing = path.read_text(errors="replace") if path.exists() else ""
    backup: Path | None = None
    settings: dict[str, Any]
    if path.exists():
        backup = _backup_path(path)
        backup.write_text(existing)
        try:
            decoded = json.loads(existing or "{}")
            settings = decoded if isinstance(decoded, dict) else {}
        except json.JSONDecodeError:
            result = {
                "status": "error",
                "summary": "Gemini settings.json is not valid JSON; backup written but config was not changed.",
                "config_path": str(path),
                "backup_path": str(backup),
                "soma_installed": False,
                "direct_nexus_removed": False,
                "actual_project_root": None,
                "expected_project_root": normalize_path(project_root) if project_root else None,
                "project_matches": None,
                "issues": ["invalid_json"],
            }
            _log_client_config("gemini", "install", result, project_root)
            return result
    else:
        settings = {}

    servers = settings.get("mcpServers")
    if not isinstance(servers, dict):
        servers = {}
        settings["mcpServers"] = servers
    direct_removed = _remove_direct_unity_servers(settings)
    snippet = json.loads(build_client_config("gemini", project_root, python_executable))
    servers["soma"] = snippet["mcpServers"]["soma"]

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(settings, indent=2, sort_keys=False) + "\n", encoding="utf-8")

    verification = verify_gemini_config(path, project_root)
    result = {
        "status": verification["status"],
        "summary": "Installed Gemini MCP config for Soma.",
        "config_path": str(path),
        "backup_path": str(backup) if backup else None,
        "soma_installed": verification["soma_installed"],
        "direct_nexus_removed": direct_removed > 0,
        "old_soma_blocks_replaced": 1,
        "actual_project_root": verification.get("actual_project_root"),
        "expected_project_root": verification.get("expected_project_root"),
        "project_matches": verification.get("project_matches"),
        "issues": verification["issues"],
    }
    _log_client_config("gemini", "install", result, project_root)
    return result


def rollback_gemini_config(
    config_path: str | Path | None = None,
    backup_path: str | Path | None = None,
) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else gemini_config_default_path()
    selected_backup = Path(backup_path).expanduser() if backup_path else None
    if selected_backup is None:
        candidates = _backup_candidates(path)
        selected_backup = candidates[0] if candidates else None

    if not selected_backup or not selected_backup.exists():
        result = {
            "status": "degraded",
            "summary": "No Gemini Soma backup found to restore.",
            "config_path": str(path),
            "backup_path": str(selected_backup) if selected_backup else None,
            "restored": False,
            "issues": ["missing_backup"],
        }
        _log_client_config("gemini", "rollback", result)
        return result

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(selected_backup.read_text(errors="replace"), encoding="utf-8")
    verification = verify_gemini_config(path)
    result = {
        "status": "ok",
        "summary": "Restored Gemini config from Soma backup.",
        "config_path": str(path),
        "backup_path": str(selected_backup),
        "restored": True,
        "post_restore_status": verification["status"],
        "post_restore_issues": verification["issues"],
    }
    _log_client_config("gemini", "rollback", result)
    return result


def verify_gemini_config(
    config_path: str | Path | None = None, expected_project_root: str | None = None
) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else gemini_config_default_path()
    expected = normalize_path(expected_project_root) if expected_project_root else None
    if not path.exists():
        result = {
            "status": "degraded",
            "summary": "Gemini settings.json not found.",
            "config_path": str(path),
            "soma_installed": False,
            "direct_nexus_exposed": False,
            "tool_exposure_clean": False,
            "actual_project_root": None,
            "expected_project_root": expected,
            "project_matches": None,
            "issues": ["missing_config"],
        }
        _log_client_config("gemini", "verify", result, expected_project_root)
        return result

    text = path.read_text(errors="replace")
    issues: list[str] = []
    try:
        settings = json.loads(text or "{}")
    except json.JSONDecodeError:
        result = {
            "status": "error",
            "summary": "Gemini settings.json is not valid JSON.",
            "config_path": str(path),
            "soma_installed": False,
            "direct_nexus_exposed": False,
            "tool_exposure_clean": False,
            "actual_project_root": None,
            "expected_project_root": expected,
            "project_matches": None,
            "issues": ["invalid_json"],
        }
        _log_client_config("gemini", "verify", result, expected_project_root)
        return result

    servers = settings.get("mcpServers") if isinstance(settings, dict) else None
    servers = servers if isinstance(servers, dict) else {}
    soma_server = servers.get("soma") if isinstance(servers.get("soma"), dict) else {}
    has_soma_script = "soma_mcp_server.py" in json.dumps(soma_server, default=str)
    direct_nexus_exposed = any(_entry_mentions_direct_unity(name, entry) for name, entry in servers.items())
    unity_tool_exposed = any(
        "unity_" in json.dumps(entry, default=str).lower() for name, entry in servers.items() if name != "soma"
    )
    actual_project_root = _extract_json_soma_project_root(soma_server)
    project_matches = _path_matches(actual_project_root, expected)

    if not soma_server:
        issues.append("soma_server_missing")
    if not has_soma_script:
        issues.append("soma_script_missing")
    if direct_nexus_exposed:
        issues.append("direct_nexus_exposed")
    if unity_tool_exposed:
        issues.append("unity_tool_marker_found")
    if expected and project_matches is False:
        issues.append("project_root_mismatch")

    clean = not direct_nexus_exposed and not unity_tool_exposed
    status_ok = bool(soma_server) and has_soma_script and clean and project_matches is not False
    result = {
        "status": "ok" if status_ok else "degraded",
        "summary": "Gemini config points to Soma only." if status_ok else "Gemini config needs Soma-only cleanup.",
        "config_path": str(path),
        "soma_installed": bool(soma_server) and has_soma_script,
        "direct_nexus_exposed": direct_nexus_exposed,
        "tool_exposure_clean": clean,
        "actual_project_root": actual_project_root,
        "expected_project_root": expected,
        "project_matches": project_matches,
        "issues": issues,
    }
    _log_client_config("gemini", "verify", result, expected_project_root)
    return result


def install_hermes_config(
    config_path: str | Path | None = None,
    project_root: str | None = None,
    python_executable: str | None = None,
) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else hermes_config_default_path()
    existing = path.read_text(errors="replace") if path.exists() else ""
    backup: Path | None = None
    if path.exists():
        backup = _backup_path(path)
        backup.write_text(existing, encoding="utf-8")

    updated, old_soma_blocks, direct_removed = _render_hermes_config_with_soma(
        existing, project_root, python_executable
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(updated, encoding="utf-8")

    verification = verify_hermes_config(path, project_root)
    result = {
        "status": verification["status"],
        "summary": "Installed Hermes MCP config for Soma.",
        "config_path": str(path),
        "backup_path": str(backup) if backup else None,
        "soma_installed": verification["soma_installed"],
        "direct_nexus_removed": direct_removed > 0,
        "old_soma_blocks_replaced": old_soma_blocks,
        "actual_project_root": verification.get("actual_project_root"),
        "expected_project_root": verification.get("expected_project_root"),
        "project_matches": verification.get("project_matches"),
        "issues": verification["issues"],
    }
    _log_client_config("hermes", "install", result, project_root)
    return result


def verify_hermes_config(
    config_path: str | Path | None = None, expected_project_root: str | None = None
) -> dict[str, Any]:
    path = Path(config_path).expanduser() if config_path else hermes_config_default_path()
    expected = normalize_path(expected_project_root) if expected_project_root else None
    hermes_binary = shutil.which("hermes")
    if not path.exists():
        result = {
            "status": "degraded",
            "summary": "Hermes config.yaml not found. Install Hermes or run Soma's Hermes config installer.",
            "config_path": str(path),
            "soma_installed": False,
            "direct_nexus_exposed": False,
            "tool_exposure_clean": False,
            "client_available": bool(hermes_binary),
            "client_path": hermes_binary,
            "actual_project_root": None,
            "expected_project_root": expected,
            "project_matches": None,
            "issues": ["missing_config"] + ([] if hermes_binary else ["hermes_cli_missing"]),
        }
        _log_client_config("hermes", "verify", result, expected_project_root)
        return result

    text = path.read_text(errors="replace")
    _, mcp_block, _ = _split_hermes_mcp_block(text)
    blocks = _hermes_server_blocks(mcp_block)
    servers = {name: _parse_hermes_server_block(lines) for name, lines in blocks}
    soma_server = servers.get("soma") if isinstance(servers.get("soma"), dict) else {}
    soma_rendered = "\n".join(next((lines for name, lines in blocks if name == "soma"), []))
    has_soma_script = "soma_mcp_server.py" in soma_rendered
    soma_enabled = soma_server.get("enabled", True) is not False if soma_server else False
    direct_nexus_exposed = any(_entry_mentions_direct_unity(name, "\n".join(lines)) for name, lines in blocks)
    unity_tool_exposed = any("unity_" in "\n".join(lines).lower() for name, lines in blocks if name != "soma")
    actual_project_root = _extract_hermes_project_root(soma_server)
    project_matches = _path_matches(actual_project_root, expected)

    issues: list[str] = []
    if not soma_server:
        issues.append("soma_server_missing")
    if soma_server and not has_soma_script:
        issues.append("soma_script_missing")
    if soma_server and not soma_enabled:
        issues.append("soma_server_disabled")
    if not hermes_binary:
        issues.append("hermes_cli_missing")
    if direct_nexus_exposed:
        issues.append("direct_nexus_exposed")
    if unity_tool_exposed:
        issues.append("unity_tool_marker_found")
    if expected and project_matches is False:
        issues.append("project_root_mismatch")

    clean = not direct_nexus_exposed and not unity_tool_exposed
    status_ok = (
        bool(soma_server)
        and has_soma_script
        and soma_enabled
        and clean
        and bool(hermes_binary)
        and project_matches is not False
    )
    result = {
        "status": "ok" if status_ok else "degraded",
        "summary": "Hermes config points to Soma only."
        if status_ok
        else (
            "Hermes CLI missing; install Hermes to use this config."
            if not hermes_binary
            else "Hermes config needs Soma-only cleanup."
        ),
        "config_path": str(path),
        "soma_installed": bool(soma_server) and has_soma_script and soma_enabled,
        "direct_nexus_exposed": direct_nexus_exposed,
        "tool_exposure_clean": clean,
        "client_available": bool(hermes_binary),
        "client_path": hermes_binary,
        "actual_project_root": actual_project_root,
        "expected_project_root": expected,
        "project_matches": project_matches,
        "issues": issues,
    }
    _log_client_config("hermes", "verify", result, expected_project_root)
    return result
