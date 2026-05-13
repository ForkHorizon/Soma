import os
import time
from dataclasses import dataclass

import json
import urllib.request
from typing import Any

from scout_pipeline import DEFAULT_TOKEN_BUDGET, TOKEN_BUDGETS, estimate_tokens

from gateway.graphify_adapter import GraphifyAdapter
from gateway.memory_store import MemoryStore

MAX_TEXT_FIELD_CHARS = 4000
NEXUS_POLL_INTERVAL = 5
ANALYSIS_DEPTHS = {'deterministic', 'ranked', 'analyst'}


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

nexus = NexusClient()
graphify = GraphifyAdapter()
memory_store = MemoryStore()
def _packet_budget(budget: str) -> str:
    return budget if budget in TOKEN_BUDGETS else DEFAULT_TOKEN_BUDGET


def _analysis_depth(depth: str) -> str:
    return depth if depth in ANALYSIS_DEPTHS else "deterministic"


def _evidence_summary(evidence_items: list[dict[str, Any]], limit: int = 8) -> list[dict[str, Any]]:
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


def get_active_project_root() -> str | None:
    import os

    from scout_pipeline import normalize_path
    explicit = os.environ.get("SOMA_PROJECT_ROOT")
    if explicit and os.path.isdir(explicit):
        return normalize_path(explicit)
    state = nexus.discover()
    if state.connected and state.project_path and os.path.isdir(state.project_path):
        return normalize_path(state.project_path)
    return None

_last_scene_generation: int | None = None
