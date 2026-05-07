#!/usr/bin/env python3
"""
Soma MCP Server - single gateway for Big AI.

Big AI connects only to Soma. Soma composes Scout Pipeline, Nexus Unity,
Graphify, project memory, and optional local model stages into bounded packets.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# Swift acts as the primary MCP server now.
# This script acts as a CLI runner for the heavy Python tools.

SOMA_DIR = Path(__file__).parent
sys.path.insert(0, str(SOMA_DIR))
from scout_pipeline import (  # noqa: E402
    ANALYSIS_DEPTHS,
    DEFAULT_TOKEN_BUDGET,
    MAX_ERROR_LINES,
    MAX_EVIDENCE_ITEMS,
    TOKEN_BUDGETS,
    analyze_packet_with_model,
    build_codex_packet,
    build_preflight,
    build_repo_index,
    bundle_for_direct_pass,
    classify_prompt_intent,
    dedupe_strings,
    detect_project_type,
    estimate_tokens,
    fallback_summary,
    find_errors,
    gather_external_evidence,
    get_git_diff_summary,
    get_git_status,
    iter_project_files,
    normalize_path,
    prompt_terms,
    rank_evidence_with_model,
    select_evidence,
)


GRAPHIFY_GRAPH_DIR = Path.home() / ".soma" / "graphs"
SOMA_MEMORY_DIR = Path.home() / ".soma"
NEXUS_POLL_INTERVAL = 5
MAX_TEXT_FIELD_CHARS = 8_000
GRAPH_STALE_SECONDS = 24 * 60 * 60

_project_root: str | None = os.environ.get("SOMA_PROJECT_ROOT")
_last_scene_generation: int | None = None


def _json(data: dict[str, Any]) -> str:
    return json.dumps(data, indent=2, sort_keys=True)


def _safe_text(value: Any, limit: int = MAX_TEXT_FIELD_CHARS) -> str:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
    return text[:limit]


def _compact_result(status: str, summary: str, **extra: Any) -> str:
    payload: dict[str, Any] = {
        "status": status,
        "summary": summary,
        "evidence": extra.pop("evidence", []),
        "omitted": extra.pop("omitted", {}),
        "next_calls": extra.pop("next_calls", []),
    }
    payload.update(extra)
    return _json(payload)


def _error_response(summary: str, *, next_calls: list[str] | None = None, **extra: Any) -> str:
    return _compact_result("error", summary, next_calls=next_calls or [], **extra)


def _ok_response(summary: str, **extra: Any) -> str:
    return _compact_result("ok", summary, **extra)


def _parse_ports() -> list[int]:
    raw_values = [
        os.environ.get("NEXUS_PORT"),
        os.environ.get("NEXUS_PORTS"),
        "8081,8090,8091,8092,8093,8094,8095",
    ]
    ports: list[int] = []
    for raw in raw_values:
        if not raw:
            continue
        for item in raw.split(","):
            item = item.strip()
            if not item:
                continue
            try:
                port = int(item)
            except ValueError:
                continue
            if 0 < port < 65536 and port not in ports:
                ports.append(port)
    return ports


@dataclass
class NexusState:
    connected: bool = False
    port: int | None = None
    project_path: str | None = None
    session_id: str | None = None
    session_generation: int | None = None
    unity_version: str | None = None
    busy_reason: str | None = None
    last_error: str | None = None
    polled_at: float = 0

    def as_dict(self) -> dict[str, Any]:
        return {
            "connected": self.connected,
            "port": self.port,
            "project_path": self.project_path,
            "session_id": self.session_id,
            "session_generation": self.session_generation,
            "unity_version": self.unity_version,
            "busy_reason": self.busy_reason,
            "last_error": self.last_error,
        }


class NexusClient:
    def __init__(self, ports: list[int] | None = None):
        self.ports = ports or _parse_ports()
        self.state = NexusState()

    def _url(self, port: int | None = None) -> str:
        selected = port or self.state.port or (self.ports[0] if self.ports else 8081)
        return f"http://127.0.0.1:{selected}/"

    def call(self, method: str, params: dict[str, Any] | None = None, timeout: int = 30, port: int | None = None) -> dict[str, Any]:
        payload = {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": 1}
        req = urllib.request.Request(
            self._url(port),
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                decoded = json.loads(resp.read().decode())
        except Exception as exc:
            return {"error": {"code": -32000, "message": str(exc), "method": method}}
        if "error" in decoded:
            return decoded
        return decoded

    def discover(self, force: bool = False) -> NexusState:
        now = time.time()
        if not force and self.state.connected and now - self.state.polled_at < NEXUS_POLL_INTERVAL:
            return self.state

        for port in self.ports:
            res = self.call("get_server_status", timeout=2, port=port)
            if "result" not in res:
                continue
            result = res.get("result") or {}
            self.state = NexusState(
                connected=True,
                port=port,
                project_path=result.get("projectPath"),
                session_id=result.get("sessionId"),
                session_generation=result.get("sessionGeneration"),
                unity_version=result.get("unityVersion"),
                busy_reason=result.get("busyReason"),
                last_error=result.get("lastError"),
                polled_at=now,
            )
            return self.state

        self.state.connected = False
        self.state.polled_at = now
        return self.state

    def available(self) -> bool:
        return self.discover().connected

    def compact_scene_snapshot(self) -> dict[str, Any]:
        return self.call("compact_scene_snapshot", timeout=30)

    def read_logs(self, count: int = 40) -> dict[str, Any]:
        return self.call("read_logs", {"count": count}, timeout=15)

    def read_logs_since_cursor(self, cursor: int = 0, max_entries: int = 80) -> dict[str, Any]:
        return self.call("read_logs_since_cursor", {"cursor": cursor, "max_entries": max_entries}, timeout=15)

    def timeline(self) -> dict[str, Any]:
        return self.call("get_editor_timeline", timeout=15)

    def lint_project(self) -> dict[str, Any]:
        return self.call("lint_project", timeout=120)

    def scene_delta(self, generation: int | None) -> dict[str, Any]:
        params = {"generation": generation or 0}
        return self.call("scene_delta", params, timeout=30)

    def inspect(self, instance_id: int, component_name: str | None = None, fields: list[str] | None = None) -> dict[str, Any]:
        if component_name and fields:
            return self.call(
                "component_values",
                {"instance_id": instance_id, "component_name": component_name, "fields": fields},
                timeout=20,
            )
        if component_name:
            return self.call("inspect_component", {"instance_id": instance_id, "component_name": component_name}, timeout=20)
        return self.call("get_game_object", {"instance_id": instance_id}, timeout=20)

    def batch_execute(self, requests: list[dict[str, Any]]) -> dict[str, Any]:
        return self.call("batch_execute", {"requests": requests}, timeout=120)

    def apply_code_change(self, files: list[dict[str, Any]]) -> dict[str, Any]:
        return self.call("apply_code_change", {"files": files}, timeout=180)


class GraphifyAdapter:
    def __init__(self, graph_dir: Path = GRAPHIFY_GRAPH_DIR):
        self.graph_dir = graph_dir

    def project_graph_candidates(self, project_root: str | None) -> list[Path]:
        if not project_root:
            return []
        root = Path(project_root)
        return [
            root / "graphify-out" / "graph.json",
            root / "Assets" / "NexusUnity" / "graphify-out" / "graph.json",
            self.graph_dir / root.name / "graph.json",
        ]

    def find_graphs(self, project_root: str | None) -> list[Path]:
        graphs: list[Path] = []
        for candidate in self.project_graph_candidates(project_root):
            if candidate.exists() and candidate not in graphs:
                graphs.append(candidate)

        cross_project = [
            Path("/Users/daliys/Daliys/Swift/Soma/graphify-out/graph.json"),
            Path("/Users/daliys/Daliys/UnityProjects/UnityTestForNexus/graphify-out/graph.json"),
        ]
        for candidate in cross_project:
            if candidate.exists() and candidate not in graphs:
                graphs.append(candidate)
        return graphs

    def status(self, project_root: str | None) -> dict[str, Any]:
        graphs = self.find_graphs(project_root)
        project_graphs = [candidate for candidate in self.project_graph_candidates(project_root) if candidate.exists()]
        now = time.time()
        entries = []
        for graph in graphs[:4]:
            try:
                stat = graph.stat()
                age_seconds = max(0, int(now - stat.st_mtime))
                entries.append(
                    {
                        "path": str(graph),
                        "exists": True,
                        "age_seconds": age_seconds,
                        "stale": age_seconds > GRAPH_STALE_SECONDS,
                        "report_exists": (graph.parent / "GRAPH_REPORT.md").exists(),
                    }
                )
            except OSError as exc:
                entries.append({"path": str(graph), "exists": False, "error": str(exc), "stale": True})
        return {
            "available": bool(graphs),
            "project_graph_available": bool(project_graphs),
            "stale": any(entry.get("stale") for entry in entries) if entries else True,
            "graphs": entries,
            "recommended_action": None if project_graphs else "Run graphify in the project root.",
        }

    def query(self, question: str, project_root: str | None, budget: int = 1500) -> dict[str, Any]:
        graphs = self.find_graphs(project_root)
        answers: list[dict[str, str]] = []
        warnings: list[str] = []
        for graph in graphs[:2]:
            try:
                result = subprocess.run(
                    ["graphify", "query", question, "--graph", str(graph), "--budget", str(budget)],
                    capture_output=True,
                    text=True,
                    timeout=15,
                    check=False,
                )
            except Exception as exc:
                warnings.append(f"{graph}: {exc}")
                continue
            stderr = result.stderr.strip()
            if stderr:
                warnings.append(stderr.splitlines()[0])
            if result.returncode == 0 and result.stdout.strip():
                answers.append({"graph": str(graph), "answer": result.stdout.strip()[: max(400, budget * 5)]})
        return {"graphs": [str(graph) for graph in graphs], "answers": answers, "warnings": warnings}

    def god_nodes_from_report(self, project_root: str | None, limit: int = 8) -> list[str]:
        nodes: list[str] = []
        for graph in self.find_graphs(project_root):
            report = graph.parent / "GRAPH_REPORT.md"
            if not report.exists():
                continue
            in_section = False
            for line in report.read_text(errors="replace").splitlines():
                if line.startswith("## God Nodes"):
                    in_section = True
                    continue
                if in_section and line.startswith("## "):
                    break
                if in_section and line.strip().startswith(tuple(f"{i}." for i in range(1, 10))):
                    nodes.append(line.strip())
                    if len(nodes) >= limit:
                        return nodes
        return nodes


class MemoryStore:
    def project_dir(self, project_root: str | None) -> Path:
        if project_root:
            path = Path(project_root) / ".soma"
        else:
            path = SOMA_MEMORY_DIR / "default"
        path.mkdir(parents=True, exist_ok=True)
        return path

    def _json_file(self, project_root: str | None, name: str) -> Path:
        return self.project_dir(project_root) / name

    def load(self, project_root: str | None) -> dict[str, Any]:
        memory = {"notes": [], "known_issues": [], "patterns": []}
        legacy = self._json_file(project_root, "memory.json")
        if legacy.exists():
            try:
                memory.update(json.loads(legacy.read_text()))
            except Exception:
                pass
        known = self._json_file(project_root, "known_issues.json")
        if known.exists():
            try:
                data = json.loads(known.read_text())
                memory["known_issues"] = data if isinstance(data, list) else data.get("known_issues", [])
            except Exception:
                pass
        return memory

    def save(self, project_root: str | None, memory: dict[str, Any]) -> None:
        self._json_file(project_root, "memory.json").write_text(json.dumps(memory, indent=2, sort_keys=True))
        known = memory.get("known_issues") or []
        self._json_file(project_root, "known_issues.json").write_text(json.dumps(known, indent=2, sort_keys=True))

    def append(self, project_root: str | None, category: str, content: str) -> dict[str, Any]:
        memory = self.load(project_root)
        category = category if category in {"notes", "known_issues", "patterns"} else "notes"
        clean_content = content.strip()[:2000]
        memory.setdefault(category, []).append({"text": clean_content, "timestamp": int(time.time())})
        self.save(project_root, memory)
        return memory

    def write_map(self, project_root: str | None, map_data: dict[str, Any]) -> None:
        self._json_file(project_root, "map.json").write_text(json.dumps(map_data, indent=2, sort_keys=True))
        architecture = self.project_dir(project_root) / "architecture.md"
        if not architecture.exists():
            architecture.write_text("# Architecture\n\nProject architecture notes captured by Soma.\n")


nexus = NexusClient()
graphify = GraphifyAdapter()
memory_store = MemoryStore()


def discover_nexus(force: bool = False) -> dict[str, Any] | None:
    state = nexus.discover(force=force)
    return state.as_dict() if state.connected else None


def get_active_project_root() -> str | None:
    global _project_root
    explicit = os.environ.get("SOMA_PROJECT_ROOT") or _project_root
    if explicit and os.path.isdir(explicit):
        _project_root = normalize_path(explicit)
        return _project_root
    state = nexus.discover()
    if state.connected and state.project_path and os.path.isdir(state.project_path):
        _project_root = normalize_path(state.project_path)
        return _project_root
    return None


def find_graph_json(project_root: str | None) -> Path | None:
    graphs = graphify.find_graphs(project_root)
    return graphs[0] if graphs else None


def query_graph_simple(graph_path: Path, question: str) -> str:
    result = graphify.query(question, str(graph_path.parent.parent), budget=1500)
    if result["answers"]:
        return result["answers"][0]["answer"]
    return ""


def get_memory_dir(project_root: str | None) -> Path:
    return memory_store.project_dir(project_root)


def load_memory(project_root: str | None) -> dict[str, Any]:
    return memory_store.load(project_root)


def save_memory(project_root: str | None, memory: dict[str, Any]):
    memory_store.save(project_root, memory)


def _packet_budget(budget: str) -> str:
    return budget if budget in TOKEN_BUDGETS else DEFAULT_TOKEN_BUDGET


def _analysis_depth(depth: str) -> str:
    return depth if depth in ANALYSIS_DEPTHS else "deterministic"


def _evidence_summary(evidence_items: list[dict[str, Any]], limit: int = 5) -> list[dict[str, Any]]:
    compact = []
    for item in evidence_items[:limit]:
        compact.append(
            {
                "path": item.get("path"),
                "kind": item.get("kind"),
                "reason": item.get("reason"),
                "symbols": (item.get("symbols") or [])[:6],
            }
        )
    return compact


def _append_graph_context(packet: str, graph_context: str, budget: str) -> str:
    if not graph_context:
        return packet
    max_tokens = TOKEN_BUDGETS.get(budget, TOKEN_BUDGETS[DEFAULT_TOKEN_BUDGET])
    remaining = max(0, max_tokens - estimate_tokens(packet))
    if remaining < 120:
        return packet
    graph_chars = min(1500, remaining * 4)
    enriched = f"{packet}\n\nGraph context (from Graphify):\n{graph_context[:graph_chars]}"
    while estimate_tokens(enriched) > max_tokens and graph_chars > 300:
        graph_chars -= 200
        enriched = f"{packet}\n\nGraph context (from Graphify):\n{graph_context[:graph_chars]}"
    return enriched if estimate_tokens(enriched) <= max_tokens else packet


def _enforce_packet_budget(goal: str, bundle: dict[str, Any], packet: str, budget: str) -> str:
    max_tokens = TOKEN_BUDGETS.get(budget, TOKEN_BUDGETS[DEFAULT_TOKEN_BUDGET])
    if estimate_tokens(packet) <= max_tokens:
        return packet

    evidence_items = bundle.get("evidence_items") or []
    lines = [
        "Goal:",
        goal.strip(),
        "",
        "Use only this bounded Soma packet first. Ask for 1-3 exact missing files/commands if insufficient.",
        "",
        "Known facts:",
        f"- Project root: {bundle.get('project_root') or '[not selected]'}",
        f"- Project type: {bundle.get('project_type') or 'unknown'}",
        f"- Packet mode: {bundle.get('packet_mode', 'direct')}",
        f"- Analysis depth: {bundle.get('analysis_depth', 'deterministic')}",
        f"- Token budget: {budget} <= {max_tokens} estimated tokens",
        "",
        "Evidence index:",
    ]
    for item in evidence_items[:5]:
        lines.append(f"- {item.get('path', '[unknown]')} [{item.get('kind', 'file')}]: {item.get('reason', '')}")

    omitted = dict(bundle.get("omitted_context") or {})
    omitted["budget_guard"] = "Soma replaced verbose snippets with evidence index to stay within budget"
    lines.extend(["", "Omitted context:"])
    lines.extend(f"- {key}: {value}" for key, value in omitted.items())
    lines.extend(["", "Expected Codex behavior:", "- Use the evidence index first.", "- Request only the exact missing context."])

    bounded = "\n".join(lines).strip()
    while estimate_tokens(bounded) > max_tokens and len(lines) > 14:
        lines.pop(-4)
        bounded = "\n".join(lines).strip()
    return bounded


def _safe_nexus_result(res: dict[str, Any], label: str) -> tuple[bool, Any, dict[str, Any]]:
    if "error" in res:
        return False, None, {"source": label, "error": res["error"]}
    return True, res.get("result"), {}


def _server_script_path() -> str:
    return normalize_path(Path(__file__))


def build_client_config(client: str, project_root: str | None = None, python_executable: str | None = None) -> str:
    root = normalize_path(project_root) if project_root else ""
    python = python_executable or sys.executable or "/opt/homebrew/bin/python3"
    script = _server_script_path()

    if client == "codex":
        args = f'["{script}", "--project-root", "{root}"]' if root else f'["{script}"]'
        env_line = f'env = {{ SOMA_PROJECT_ROOT = "{root}" }}' if root else "# env = { SOMA_PROJECT_ROOT = \"/absolute/project/root\" }"
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
    selected_backup: Path | None
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


def build_status_payload(project_root: str | None = None) -> dict[str, Any]:
    root = normalize_path(project_root) if project_root else get_active_project_root()
    state = nexus.discover(force=True)
    # In migration phase, hardcode the known tools since FastMCP is removed
    tools = [
        "soma_prepare_context", "soma_get_map", "soma_ask", "soma_inspect",
        "soma_scene", "soma_execute", "soma_debug", "soma_delta",
        "soma_apply", "soma_remember", "soma_review", "soma_code_context"
    ]
    return {
        "status": "ok",
        "server": {
            "transport": "stdio",
            "script": _server_script_path(),
            "tool_count": len(tools),
            "tool_names": tools,
        },
        "project_root": root,
        "nexus": state.as_dict(),
        "graph": graphify.status(root),
        "python": sys.executable,
    }


async def soma_prepare_context(goal: str, budget: str = "balanced", depth: str = "deterministic") -> str:
    """Compile a bounded evidence packet for implementation, debug, or review work."""
    project_root = get_active_project_root()
    if not project_root or not os.path.isdir(project_root):
        return _error_response(
            "No project root configured.",
            next_calls=["Set SOMA_PROJECT_ROOT or start Nexus Unity so Soma can discover projectPath."],
        )

    budget = _packet_budget(budget)
    depth = _analysis_depth(depth)

    try:
        project_root = normalize_path(project_root)
        intent = classify_prompt_intent(goal)

        if not intent["needs_gather"]:
            bundle = bundle_for_direct_pass(goal, intent["reason"], project_root, budget, depth)
            packet = bundle["codex_packet"]
            return _ok_response(
                "Direct prompt does not need local evidence.",
                packet=packet,
                mode="direct",
                budget=budget,
                estimated_tokens=estimate_tokens(packet),
                omitted={"reason": intent["reason"]},
                next_calls=["Call soma_prepare_context again with a concrete code/debug/review goal if evidence is needed."],
            )

        terms = prompt_terms(goal)
        project_type, type_reason = detect_project_type(project_root)
        git_status = get_git_status(project_root)
        git_diff_summary = get_git_diff_summary(project_root, terms)
        discovered = iter_project_files(project_root)
        repo_index = build_repo_index(project_root, discovered)
        preflight = build_preflight(goal, project_root, project_type, discovered, repo_index, git_status, git_diff_summary)

        explicit_items = gather_external_evidence(goal, project_root, terms)
        evidence_items = explicit_items + select_evidence(project_root, goal, project_type, repo_index, preflight)
        seen: set[str] = set()
        deduped: list[dict[str, Any]] = []
        for item in evidence_items:
            path = item.get("path")
            if path and path not in seen:
                seen.add(path)
                deduped.append(item)
                if len(deduped) >= MAX_EVIDENCE_ITEMS:
                    break
        evidence_items = deduped

        error_lines = dedupe_strings(
            [
                error
                for item in evidence_items
                if item.get("kind") == "log"
                for error in find_errors(item.get("preview", ""))
            ]
        )[:MAX_ERROR_LINES]

        stages = [{"stage": "preflight", "status": "ok"}, {"stage": "deterministic", "status": "ok"}]
        if depth in {"ranked", "analyst"}:
            evidence_items, rank_stage = await rank_evidence_with_model(goal, preflight, evidence_items)
            stages.append(rank_stage)

        model_analysis = None
        if depth == "analyst":
            model_analysis, analyst_stage = await analyze_packet_with_model(goal, preflight, evidence_items, error_lines)
            stages.append(analyst_stage)

        graph_result = graphify.query(goal, project_root, budget=1200)
        graph_context = "\n\n".join(answer["answer"] for answer in graph_result["answers"])
        summary = fallback_summary(goal, project_root, project_type, evidence_items, error_lines, preflight["packet_mode"])

        bundle = {
            "mode": "gather",
            "original_prompt": goal,
            "project_root": project_root,
            "project_type": project_type,
            "routing_decision": "gathered_and_relayed",
            "packet_mode": preflight["packet_mode"],
            "analysis_depth": depth,
            "analysis_stages": stages,
            "preflight": {k: v for k, v in preflight.items() if k not in {"changed_paths", "error_paths", "candidate_paths"}},
            "model_analysis": model_analysis,
            "gather_reason": intent["reason"],
            "confidence": summary.get("confidence", 0.55),
            "git_status": git_status,
            "git_diff": None,
            "git_diff_summary": git_diff_summary,
            "repo_index": {"indexed_file_count": repo_index.get("indexed_file_count")},
            "token_budget": budget,
            "evidence_items": evidence_items,
            "error_lines": error_lines,
            "context_summary": summary.get("summary", ""),
            "open_questions": dedupe_strings(summary.get("open_questions", []))[:3],
            "assumptions": [type_reason] + dedupe_strings(summary.get("assumptions", []))[:3],
            "omitted_context": {
                "discovered_files": len(discovered),
                "selected_evidence_items": len(evidence_items),
                "analysis_depth": depth,
                "graph_answers": len(graph_result["answers"]),
                "graph_warnings": graph_result["warnings"][:2],
            },
        }

        packet = _append_graph_context(build_codex_packet(goal, bundle, budget), graph_context, budget)
        packet = _enforce_packet_budget(goal, bundle, packet, budget)
        estimated = estimate_tokens(packet)
        omitted = {
            **bundle["omitted_context"],
            "budget_tokens": TOKEN_BUDGETS[budget],
            "estimated_tokens": estimated,
            "raw_git_diff_chars": (git_diff_summary or {}).get("raw_diff_chars_omitted", 0),
            "graphs_consulted": graph_result["graphs"][:3],
        }
        return _ok_response(
            f"Prepared {preflight['packet_mode']} packet within {budget} budget.",
            packet=packet,
            mode=preflight["packet_mode"],
            budget=budget,
            depth=depth,
            confidence=summary.get("confidence", 0.55),
            estimated_tokens=estimated,
            evidence=_evidence_summary(evidence_items),
            omitted=omitted,
            analysis_stages=stages,
            next_calls=["Use packet first.", "Call soma_code_context for 1 focused missing area.", "Call soma_inspect for 1 Unity object/component."],
        )
    except Exception as exc:
        return _error_response(f"soma_prepare_context failed: {exc}")


async def soma_get_map() -> str:
    """Return a compact living project map from git, Graphify, Nexus, and memory."""
    project_root = get_active_project_root()
    if not project_root:
        return _error_response("No project root configured.", next_calls=["Set SOMA_PROJECT_ROOT or start Nexus Unity."])

    project_type, type_reason = detect_project_type(project_root)
    state = nexus.discover()
    git_status = get_git_status(project_root)
    changed_count = len([line for line in git_status.splitlines() if line and not line.startswith("##")]) if git_status else 0
    graph_nodes = graphify.god_nodes_from_report(project_root)
    graph_status = graphify.status(project_root)
    memory = memory_store.load(project_root)

    scene_summary: dict[str, Any] = {"available": False}
    health: dict[str, Any] = {"available": False}
    omitted: dict[str, Any] = {
        "graph_nodes_available": len(graph_nodes),
        "graph_stale": graph_status["stale"],
        "graph_recommended_action": graph_status["recommended_action"],
    }

    if state.connected:
        ok, scene, err = _safe_nexus_result(nexus.compact_scene_snapshot(), "compact_scene_snapshot")
        if ok:
            scene_text = _safe_text(scene, 900)
            scene_summary = {"available": True, "summary": scene_text}
            omitted["scene_snapshot_truncated"] = len(_safe_text(scene)) > len(scene_text)
        else:
            health["scene_error"] = err

        ok, logs, err = _safe_nexus_result(nexus.read_logs(count=40), "read_logs")
        if ok:
            log_items = logs.get("logs", []) if isinstance(logs, dict) else []
            errors = [
                item
                for item in log_items
                if isinstance(item, dict) and str(item.get("Type") or item.get("type") or "").lower() in {"error", "exception"}
            ][:5]
            health = {"available": True, "error_count": len(errors), "errors": [_safe_text(e.get("Message") or e.get("message"), 160) for e in errors]}
            omitted["logs_returned"] = len(log_items)
        else:
            health = {"available": False, "error": err}

    map_data = {
        "project": {"name": Path(project_root).name, "path": project_root, "type": project_type, "type_reason": type_reason},
        "nexus": state.as_dict(),
        "git": {"status": git_status.splitlines()[:20] if git_status else [], "changed_count": changed_count},
        "graph": {"god_nodes": graph_nodes[:8], **graph_status},
        "scene": scene_summary,
        "health": health,
        "memory": {
            "known_issues": memory.get("known_issues", [])[:5],
            "patterns": memory.get("patterns", [])[:5],
            "notes": memory.get("notes", [])[-3:],
        },
    }
    serializable_map = json.loads(json.dumps(map_data, default=str))
    memory_store.write_map(project_root, serializable_map)

    return _ok_response(
        f"Living map for {Path(project_root).name}.",
        map=serializable_map,
        omitted=omitted,
        next_calls=["Call soma_prepare_context with the concrete task.", "Call soma_code_context for a focused subsystem."],
    )


async def soma_ask(question: str) -> str:
    """Answer a project question with Graphify context."""
    project_root = get_active_project_root()
    result = graphify.query(question, project_root, budget=1500)
    if result["answers"]:
        return _ok_response(
            "Answered from project graph.",
            answers=result["answers"],
            omitted={"graphs_consulted": result["graphs"], "warnings": result["warnings"][:2]},
            next_calls=["Call soma_code_context if exact source snippets are needed."],
        )
    return _compact_result(
        "degraded",
        "No graph answer available.",
        omitted={"graphs_consulted": result["graphs"], "warnings": result["warnings"][:3]},
        next_calls=["Run graphify in the project or call soma_code_context for deterministic snippets."],
    )


async def soma_inspect(instance_id: int, component_name: str | None = None, fields: list[str] | None = None) -> str:
    """Inspect a Unity object or component through filtered Nexus calls."""
    if not nexus.available():
        return _error_response("Nexus Unity not connected.", next_calls=["Start Nexus Unity server from the Unity editor."])

    res = nexus.inspect(instance_id, component_name, fields)
    ok, result, err = _safe_nexus_result(res, "inspect")
    if not ok:
        return _error_response("Nexus inspect failed.", omitted=err, next_calls=["Call soma_scene to locate a valid instance_id."])

    compact = _safe_text(result, 6000)
    return _ok_response(
        "Filtered Unity inspection result.",
        result=json.loads(compact) if compact.strip().startswith(("{", "[")) else compact,
        omitted={"truncated": len(_safe_text(result)) > len(compact), "used_component_values": bool(component_name and fields)},
        next_calls=["Use this result first.", "Call soma_inspect again with fields for a narrower component read."],
    )


async def soma_scene() -> str:
    """Return a compact Unity scene snapshot."""
    if not nexus.available():
        return _error_response("Nexus Unity not connected.", next_calls=["Start Nexus Unity server from the Unity editor."])

    ok, result, err = _safe_nexus_result(nexus.compact_scene_snapshot(), "compact_scene_snapshot")
    if not ok:
        return _error_response("Scene snapshot failed.", omitted=err)
    compact = _safe_text(result, 7000)
    return _ok_response(
        "Compact scene snapshot.",
        scene=json.loads(compact) if compact.strip().startswith(("{", "[")) else compact,
        omitted={"truncated": len(_safe_text(result)) > len(compact)},
        next_calls=["Call soma_inspect for one object/component from this scene."],
    )


async def soma_execute(requests: list[dict[str, Any]]) -> str:
    """Advanced escape hatch for restricted Nexus batch operations."""
    if not nexus.available():
        return _error_response("Nexus Unity not connected.", next_calls=["Start Nexus Unity server from the Unity editor."])
    if not requests:
        return _error_response("No requests supplied.")
    if len(requests) > 12:
        return _error_response("Batch too large for Soma gateway.", omitted={"requested": len(requests), "max": 12})
    forbidden = {"batch_execute", "shutdown_server"}
    methods = [str(req.get("method") or "") for req in requests]
    blocked = [method for method in methods if method in forbidden]
    if blocked:
        return _error_response("Soma blocked unsafe or recursive Nexus method.", omitted={"blocked": blocked})

    ok, result, err = _safe_nexus_result(nexus.batch_execute(requests), "batch_execute")
    if not ok:
        return _error_response("Nexus batch failed.", omitted=err)
    return _ok_response(
        "Nexus batch executed.",
        result=result,
        omitted={"request_count": len(requests), "methods": methods},
        next_calls=["Call soma_delta to verify editor-side changes."],
    )


async def soma_debug(symptom: str) -> str:
    """Gather debug evidence from code, git, Nexus logs, and health."""
    base = json.loads(await soma_prepare_context(goal=symptom, budget="balanced", depth="ranked"))
    if nexus.available():
        ok, logs, err = _safe_nexus_result(nexus.read_logs_since_cursor(0, 80), "read_logs_since_cursor")
        if ok:
            base.setdefault("nexus", {})["logs"] = _safe_text(logs, 3000)
        else:
            base.setdefault("omitted", {})["nexus_logs_error"] = err
        ok, lint, err = _safe_nexus_result(nexus.lint_project(), "lint_project")
        if ok:
            base.setdefault("nexus", {})["lint"] = _safe_text(lint, 3000)
        else:
            base.setdefault("omitted", {})["nexus_lint_error"] = err
    base["summary"] = f"Debug packet for: {symptom}"
    base["next_calls"] = ["Use packet first.", "Call soma_inspect for the object/component named by errors."]
    return _json(base)


async def soma_delta() -> str:
    """Return git changes plus Unity timeline and scene delta."""
    global _last_scene_generation
    project_root = get_active_project_root()
    evidence: list[dict[str, Any]] = []
    omitted: dict[str, Any] = {}
    if not project_root:
        return _error_response("No project root configured.", next_calls=["Set SOMA_PROJECT_ROOT or start Nexus Unity."])

    terms = prompt_terms("what changed")
    git_status = get_git_status(project_root)
    diff_summary = get_git_diff_summary(project_root, terms)
    changed = (diff_summary or {}).get("changed_files", [])[:20]
    evidence.extend({"path": item.get("path"), "kind": "git", "reason": item.get("status")} for item in changed)
    omitted["raw_git_diff_chars"] = (diff_summary or {}).get("raw_diff_chars_omitted", 0)

    nexus_payload: dict[str, Any] = {}
    state = nexus.discover()
    if state.connected:
        ok, timeline, err = _safe_nexus_result(nexus.timeline(), "get_editor_timeline")
        nexus_payload["timeline"] = _safe_text(timeline, 2500) if ok else err
        ok, scene_delta, err = _safe_nexus_result(nexus.scene_delta(_last_scene_generation), "scene_delta")
        nexus_payload["scene_delta"] = _safe_text(scene_delta, 2500) if ok else err
        _last_scene_generation = state.session_generation

    return _ok_response(
        "Git and Unity delta.",
        git_status=git_status.splitlines()[:40] if git_status else [],
        git_diff_summary=diff_summary,
        nexus=nexus_payload,
        evidence=evidence[:10],
        omitted=omitted,
        next_calls=["Call soma_prepare_context if these changes need review.", "Call soma_scene if scene_delta is unclear."],
    )


async def soma_apply(files: list[dict[str, Any]]) -> str:
    """Write Unity code files, wait for compilation, and return compiler errors."""
    if not nexus.available():
        return _error_response("Nexus Unity not connected.", next_calls=["Start Nexus Unity server from the Unity editor."])
    if not files:
        return _error_response("No files supplied.")
    sanitized = []
    for item in files:
        path = str(item.get("path") or "")
        content = item.get("content")
        if not path or content is None:
            return _error_response("Each file must include path and content.")
        sanitized.append({"path": path, "content": str(content)})

    ok, result, err = _safe_nexus_result(nexus.apply_code_change(sanitized), "apply_code_change")
    if not ok:
        return _error_response("Nexus apply_code_change failed.", omitted=err)
    compiler_errors = result.get("compiler_errors", []) if isinstance(result, dict) else []
    status = "ok" if not compiler_errors else "degraded"
    return _compact_result(
        status,
        "Applied files and checked Unity compilation.",
        result=result,
        evidence=[{"path": item["path"], "kind": "write", "reason": "soma_apply input"} for item in sanitized],
        omitted={"file_count": len(sanitized), "compiler_error_count": len(compiler_errors)},
        next_calls=["Fix compiler_errors if present.", "Call soma_delta to verify changes."],
    )


async def soma_remember(action: str, content: str = "", category: str = "notes") -> str:
    """Save, list, or clear structured project memory."""
    project_root = get_active_project_root()
    action = action.lower().strip()
    if action == "save":
        if not content.strip():
            return _error_response("No memory content supplied.")
        memory = memory_store.append(project_root, category, content)
        return _ok_response(
            "Saved structured project memory.",
            memory_counts={key: len(memory.get(key, [])) for key in ("notes", "known_issues", "patterns")},
            omitted={"max_saved_chars": 2000, "category": category},
        )
    if action == "list":
        memory = memory_store.load(project_root)
        return _ok_response(
            "Loaded project memory.",
            memory={
                "notes": memory.get("notes", [])[-5:],
                "known_issues": memory.get("known_issues", [])[-5:],
                "patterns": memory.get("patterns", [])[-5:],
            },
        )
    if action == "clear":
        memory_store.save(project_root, {"notes": [], "known_issues": [], "patterns": []})
        return _ok_response("Project memory cleared.")
    return _error_response("Unknown memory action.", next_calls=["Use action save, list, or clear."])


async def soma_review(focus: str = "current diff") -> str:
    """Prepare a bug/regression review packet."""
    goal = f"Review {focus} for behavioral regressions. Focus on bugs and missing tests, not style."
    return await soma_prepare_context(goal=goal, budget="balanced", depth="ranked")


async def soma_code_context(query: str) -> str:
    """Return Graphify context plus deterministic source snippets for a focused query."""
    project_root = get_active_project_root()
    if not project_root:
        return _error_response("No project root configured.", next_calls=["Set SOMA_PROJECT_ROOT or start Nexus Unity."])

    terms = prompt_terms(query)
    discovered = iter_project_files(project_root)
    repo_index = build_repo_index(project_root, discovered)
    project_type, _ = detect_project_type(project_root)
    git_diff_summary = get_git_diff_summary(project_root, terms)
    git_status = get_git_status(project_root)
    preflight = build_preflight(query, project_root, project_type, discovered, repo_index, git_status, git_diff_summary)
    evidence = select_evidence(project_root, query, project_type, repo_index, preflight)[:5]
    graph_result = graphify.query(query, project_root, budget=1200)

    snippets = []
    for item in evidence:
        snippets.append(
            {
                "path": item.get("path"),
                "kind": item.get("kind"),
                "reason": item.get("reason"),
                "symbols": (item.get("symbols") or [])[:8],
                "snippet": (item.get("preview") or "")[:900],
            }
        )

    packet_parts = []
    if graph_result["answers"]:
        packet_parts.append("Graph context:")
        packet_parts.extend(answer["answer"] for answer in graph_result["answers"][:2])
    if snippets:
        packet_parts.append("Relevant snippets:")
        for item in snippets:
            packet_parts.append(f"{item['path']} [{item['kind']}]\nReason: {item['reason']}\n{item['snippet']}")
    packet = "\n\n".join(packet_parts)

    return _ok_response(
        "Focused code context.",
        packet=packet[: TOKEN_BUDGETS["balanced"] * 4],
        evidence=_evidence_summary(evidence),
        snippets=snippets,
        omitted={
            "discovered_files": len(discovered),
            "selected_snippets": len(snippets),
            "graphs_consulted": graph_result["graphs"][:3],
            "graph_warnings": graph_result["warnings"][:2],
        },
        next_calls=["Use these snippets first.", "Call soma_prepare_context if this becomes an implementation task."],
    )


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Soma MCP Server")
    parser.add_argument("--transport", default="stdio", choices=["stdio", "sse"])
    parser.add_argument("--port", type=int, default=8090, help="Port for SSE mode")
    parser.add_argument("--project-root", default=None, help="Override project root")
    parser.add_argument("--print-client-config", choices=["codex", "gemini", "claude"], default=None)
    parser.add_argument("--status-json", action="store_true", help="Print compact Soma/Nexus/Graphify status and exit")
    parser.add_argument("--install-codex-config", action="store_true", help="Back up and install a Soma-only Codex MCP config")
    parser.add_argument("--rollback-codex-config", action="store_true", help="Restore Codex config from the newest Soma backup")
    parser.add_argument("--verify-client-config", choices=["codex"], default=None, help="Verify a client config points to Soma only")
    parser.add_argument("--config-path", default=None, help="Override client config path for install/verify")
    parser.add_argument("--backup-path", default=None, help="Explicit backup path for Codex rollback")
    parser.add_argument("--run-tool", default=None, help="Tool to run")
    parser.add_argument("tool_args", nargs="*", help="Arguments for the tool (JSON)")
    args = parser.parse_args()

    if args.project_root:
        _project_root = normalize_path(args.project_root)

    if args.print_client_config:
        print(build_client_config(args.print_client_config, _project_root, sys.executable))
        raise SystemExit(0)

    if args.status_json:
        print(json.dumps(build_status_payload(_project_root), indent=2, sort_keys=True))
        raise SystemExit(0)

    if args.verify_client_config == "codex":
        print(json.dumps(verify_codex_config(args.config_path), indent=2, sort_keys=True))
        raise SystemExit(0)

    if args.install_codex_config:
        print(json.dumps(install_codex_config(args.config_path, _project_root, sys.executable), indent=2, sort_keys=True))
        raise SystemExit(0)

    if args.rollback_codex_config:
        print(json.dumps(rollback_codex_config(args.config_path, args.backup_path), indent=2, sort_keys=True))
        raise SystemExit(0)

    import asyncio

    if args.run_tool:
        tool_name = args.run_tool
        tool_params = {}
        if args.tool_args:
            try:
                tool_params = json.loads(args.tool_args[0])
            except Exception:
                pass

        async def run_requested_tool():
            try:
                if tool_name == "soma_prepare_context":
                    res = await soma_prepare_context(**tool_params)
                elif tool_name == "soma_get_map":
                    res = await soma_get_map(**tool_params)
                elif tool_name == "soma_ask":
                    res = await soma_ask(**tool_params)
                elif tool_name == "soma_inspect":
                    res = await soma_inspect(**tool_params)
                elif tool_name == "soma_scene":
                    res = await soma_scene(**tool_params)
                elif tool_name == "soma_execute":
                    res = await soma_execute(**tool_params)
                elif tool_name == "soma_debug":
                    res = await soma_debug(**tool_params)
                elif tool_name == "soma_delta":
                    res = await soma_delta(**tool_params)
                elif tool_name == "soma_apply":
                    res = await soma_apply(**tool_params)
                elif tool_name == "soma_remember":
                    res = await soma_remember(**tool_params)
                elif tool_name == "soma_review":
                    res = await soma_review(**tool_params)
                elif tool_name == "soma_code_context":
                    res = await soma_code_context(**tool_params)
                else:
                    res = json.dumps({"error": f"Unknown tool {tool_name}"})
                print(res)
            except Exception as e:
                print(json.dumps({"error": str(e)}))
                sys.exit(1)

        asyncio.run(run_requested_tool())
        raise SystemExit(0)

    print(json.dumps({"error": "FastMCP removed. Run tools via python script directly using --run-tool or use Swift MCP Server."}))
