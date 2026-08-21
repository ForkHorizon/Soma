from __future__ import annotations

import json
import hashlib
from typing import Any

from scout_pipeline import get_git_diff_summary, get_git_status, prompt_terms
from scout_pipeline import estimate_tokens
from soma_audit import raw_capture_enabled

from gateway.core import (
    _compact_result,
    _error_response,
    _ok_response,
    _safe_nexus_result,
    _safe_text,
    get_active_project_root,
    nexus,
)
from gateway.tools.protocol import codex_next_calls


async def soma_inspect(instance_id: int, component_name: str | None = None, fields: list[str] | None = None) -> str:
    """Inspect a Unity object or component through filtered Nexus calls."""
    if not nexus.available():
        return _error_response(
            "Nexus Unity not connected.", next_calls=codex_next_calls("Start Nexus Unity server from the Unity editor.")
        )

    res = nexus.inspect(instance_id, component_name, fields)
    ok, result, err = _safe_nexus_result(res, "inspect")
    if not ok:
        return _error_response(
            "Nexus inspect failed.",
            omitted=err,
            next_calls=codex_next_calls("Call soma_scene to locate a valid instance_id."),
        )

    compact = _safe_text(result, 6000)
    return _ok_response(
        "Filtered Unity inspection result.",
        result=json.loads(compact) if compact.strip().startswith(("{", "[")) else compact,
        omitted={
            "truncated": len(_safe_text(result)) > len(compact),
            "used_component_values": bool(component_name and fields),
        },
        next_calls=codex_next_calls(
            "Use this result first.", "Call soma_inspect again with fields for a narrower component read."
        ),
    )


async def soma_scene() -> str:
    """Return a compact Unity scene snapshot."""
    if not nexus.available():
        return _error_response(
            "Nexus Unity not connected.", next_calls=codex_next_calls("Start Nexus Unity server from the Unity editor.")
        )

    ok, result, err = _safe_nexus_result(nexus.compact_scene_snapshot(), "compact_scene_snapshot")
    if not ok:
        return _error_response("Scene snapshot failed.", omitted=err)
    compact = _safe_text(result, 7000)
    return _ok_response(
        "Compact scene snapshot.",
        scene=json.loads(compact) if compact.strip().startswith(("{", "[")) else compact,
        omitted={"truncated": len(_safe_text(result)) > len(compact)},
        next_calls=codex_next_calls("Call soma_inspect for one object/component from this scene."),
    )


def _compact_execute_result(result: Any, *, include_raw: bool = False) -> tuple[Any, dict[str, Any]]:
    raw_text = json.dumps(result, default=str, ensure_ascii=False) if not isinstance(result, str) else result
    raw_chars = len(raw_text)
    raw_tokens = estimate_tokens(raw_text)
    digest = "sha256:" + hashlib.sha256(raw_text.encode("utf-8", errors="replace")).hexdigest()
    max_chars = 8000
    omitted = {
        "raw_output_chars": raw_chars,
        "raw_output_tokens": raw_tokens,
        "raw_output_hash": digest,
        "output_truncated": False,
        "omitted_output_tokens": 0,
    }
    if include_raw and raw_capture_enabled():
        return result, omitted
    if raw_chars <= max_chars:
        return result, omitted
    omitted["output_truncated"] = True
    omitted["omitted_output_tokens"] = max(0, raw_tokens - estimate_tokens(raw_text[:max_chars]))
    summary = {
        "summary": "Nexus result compacted by Soma because output exceeded the default safe limit.",
        "raw_output_chars": raw_chars,
        "raw_output_tokens": raw_tokens,
        "raw_output_hash": digest,
    }
    return summary, omitted


async def soma_execute(requests: list[dict[str, Any]], include_raw: bool = False, raw_capture: bool = False) -> str:
    """Advanced escape hatch for restricted Nexus batch operations."""
    if not nexus.available():
        return _error_response(
            "Nexus Unity not connected.", next_calls=codex_next_calls("Start Nexus Unity server from the Unity editor.")
        )
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
    compact_result, compact_omitted = _compact_execute_result(result, include_raw=bool(include_raw or raw_capture))
    return _ok_response(
        "Nexus batch executed.",
        result=compact_result,
        omitted={"request_count": len(requests), "methods": methods, **compact_omitted},
        next_calls=codex_next_calls("Call soma_delta to verify editor-side changes."),
    )


async def soma_delta() -> str:
    """Return git changes plus Unity timeline and scene delta."""
    import importlib

    gateway_core = importlib.import_module("gateway.core")
    project_root = get_active_project_root()
    evidence: list[dict[str, Any]] = []
    omitted: dict[str, Any] = {}
    if not project_root:
        return _error_response(
            "No project root configured.",
            next_calls=codex_next_calls("Set SOMA_PROJECT_ROOT or select a project in Soma."),
        )

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
        ok, scene_delta, err = _safe_nexus_result(nexus.scene_delta(gateway_core._last_scene_generation), "scene_delta")
        nexus_payload["scene_delta"] = _safe_text(scene_delta, 2500) if ok else err
        gateway_core._last_scene_generation = state.session_generation

    return _ok_response(
        "Git and Unity delta.",
        git_status=git_status.splitlines()[:40] if git_status else [],
        git_diff_summary=diff_summary,
        nexus=nexus_payload,
        evidence=evidence[:10],
        omitted=omitted,
        next_calls=codex_next_calls(
            "Call soma_prepare_context if these changes need review.", "Call soma_scene if scene_delta is unclear."
        ),
    )


async def soma_apply(files: list[dict[str, Any]]) -> str:
    """Write Unity code files, wait for compilation, and return compiler errors."""
    if not nexus.available():
        return _error_response(
            "Nexus Unity not connected.", next_calls=codex_next_calls("Start Nexus Unity server from the Unity editor.")
        )
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
        next_calls=codex_next_calls("Fix compiler_errors if present.", "Call soma_delta to verify changes."),
    )
