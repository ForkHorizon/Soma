"""Stable public Soma MCP tool registry.

The registry is intentionally small: Big AI clients see Soma tools only, while
Unity/Nexus and other verbose integrations remain hidden behind these wrappers.
"""
from __future__ import annotations

import inspect
import json
from typing import Any

from gateway.tools.context import soma_code_context, soma_get_map, soma_prepare_context
from gateway.tools.memory import soma_remember
from gateway.tools.nexus import (
    soma_apply,
    soma_delta,
    soma_execute,
    soma_inspect,
    soma_scene,
)
from gateway.tools.query import soma_ask, soma_debug, soma_review
from soma_audit import AUDIT_ARGUMENT_KEYS, context_from_arguments, scoped_context
from soma_logger import log_tool_call


TOOL_ORDER = [
    "soma_prepare_context",
    "soma_get_map",
    "soma_ask",
    "soma_inspect",
    "soma_scene",
    "soma_execute",
    "soma_debug",
    "soma_delta",
    "soma_apply",
    "soma_remember",
    "soma_review",
    "soma_code_context",
]


TOOL_CATALOG = {
    "soma_prepare_context": log_tool_call(soma_prepare_context),
    "soma_get_map": log_tool_call(soma_get_map),
    "soma_ask": log_tool_call(soma_ask),
    "soma_inspect": log_tool_call(soma_inspect),
    "soma_scene": log_tool_call(soma_scene),
    "soma_execute": log_tool_call(soma_execute),
    "soma_debug": log_tool_call(soma_debug),
    "soma_delta": log_tool_call(soma_delta),
    "soma_apply": log_tool_call(soma_apply),
    "soma_remember": log_tool_call(soma_remember),
    "soma_review": log_tool_call(soma_review),
    "soma_code_context": log_tool_call(soma_code_context),
}


TOOL_SCHEMAS: dict[str, dict[str, Any]] = {
    "soma_prepare_context": {
        "type": "object",
        "properties": {
            "goal": {"type": "string", "description": "Concrete implementation, debug, review, or investigation goal."},
            "budget": {"type": "string", "enum": ["micro", "fast", "balanced", "deep", "full"], "default": "balanced"},
            "depth": {"type": "string", "enum": ["deterministic", "ranked", "analyst"], "default": "deterministic"},
        },
        "required": ["goal"],
        "additionalProperties": False,
    },
    "soma_get_map": {"type": "object", "properties": {}, "additionalProperties": False},
    "soma_ask": {
        "type": "object",
        "properties": {"question": {"type": "string"}},
        "required": ["question"],
        "additionalProperties": False,
    },
    "soma_code_context": {
        "type": "object",
        "properties": {"query": {"type": "string"}},
        "required": ["query"],
        "additionalProperties": False,
    },
    "soma_debug": {
        "type": "object",
        "properties": {"symptom": {"type": "string"}},
        "required": ["symptom"],
        "additionalProperties": False,
    },
    "soma_review": {
        "type": "object",
        "properties": {"focus": {"type": "string", "default": "current diff"}},
        "additionalProperties": False,
    },
    "soma_remember": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["save", "list", "clear"]},
            "content": {"type": "string", "default": ""},
            "category": {"type": "string", "enum": ["notes", "known_issues", "patterns"], "default": "notes"},
        },
        "required": ["action"],
        "additionalProperties": False,
    },
    "soma_scene": {"type": "object", "properties": {}, "additionalProperties": False},
    "soma_delta": {"type": "object", "properties": {}, "additionalProperties": False},
    "soma_inspect": {
        "type": "object",
        "properties": {
            "instance_id": {"type": "integer"},
            "component_name": {"type": "string"},
            "fields": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["instance_id"],
        "additionalProperties": False,
    },
    "soma_execute": {
        "type": "object",
        "properties": {
            "requests": {"type": "array", "items": {"type": "object"}},
            "include_raw": {"type": "boolean", "default": False},
            "raw_capture": {"type": "boolean", "default": False},
        },
        "required": ["requests"],
        "additionalProperties": False,
    },
    "soma_apply": {
        "type": "object",
        "properties": {
            "files": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
                    "required": ["path", "content"],
                },
            }
        },
        "required": ["files"],
        "additionalProperties": False,
    },
}


def tool_schema(name: str) -> dict[str, Any]:
    schema = json.loads(json.dumps(TOOL_SCHEMAS.get(name, {"type": "object", "properties": {}, "additionalProperties": True})))
    properties = schema.setdefault("properties", {})
    properties.setdefault("run_id", {"type": "string", "description": "Optional Soma audit run correlation id."})
    properties.setdefault("task_id", {"type": "string", "description": "Optional Soma audit task correlation id."})
    properties.setdefault("client", {"type": "string", "description": "Optional client name such as codex or gemini."})
    properties.setdefault("workflow", {"type": "string", "description": "Optional workflow label such as packet_mode or live_mcp."})
    return schema


def sanitize_tool_arguments(name: str, arguments: dict[str, Any] | None) -> dict[str, Any]:
    """Ignore client-added fields such as Gemini's wait_for_previous."""
    if name not in TOOL_CATALOG:
        return {}
    raw = arguments if isinstance(arguments, dict) else {}
    signature = inspect.signature(TOOL_CATALOG[name])
    allowed = {
        param_name
        for param_name, param in signature.parameters.items()
        if param.kind in {inspect.Parameter.POSITIONAL_OR_KEYWORD, inspect.Parameter.KEYWORD_ONLY}
    }
    if not allowed:
        return {}
    return {key: value for key, value in raw.items() if key in allowed and key not in AUDIT_ARGUMENT_KEYS}


async def call_tool(name: str, arguments: dict[str, Any] | None = None) -> str:
    if name not in TOOL_CATALOG:
        return json.dumps({"error": f"Unknown tool {name}"})
    with scoped_context(**context_from_arguments(arguments)):
        return await TOOL_CATALOG[name](**sanitize_tool_arguments(name, arguments))
