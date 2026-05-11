"""Stable public Soma MCP tool registry.

The registry is intentionally small: Big AI clients see Soma tools only, while
Unity/Nexus and other verbose integrations remain hidden behind these wrappers.
"""
from __future__ import annotations

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
