"""Packet construction facade."""

from .config import DEFAULT_TOKEN_BUDGET
from .packet_codex import build_codex_packet
from .packet_prompt_compiler import (
    _as_string_list,
    _focused_prompt_compiler_evidence,
    _format_collection_plan,
    _prompt_compiler_missing_context,
    _prompt_compiler_warnings,
    _unity_meta_guid,
    build_prompt_compiler_packet,
)
from .packet_utils import (
    _extract_brace_block,
    _extract_python_block,
    _focused_source_preview,
    _line_indent,
    _source_declaration_line,
    _source_match_terms,
    build_omitted_context,
    bundle_for_direct_pass,
    estimate_tokens,
    indent_block,
)


def build_enriched_prompt(user_prompt, bundle):
    return build_codex_packet(user_prompt, bundle, bundle.get('token_budget', DEFAULT_TOKEN_BUDGET))


__all__ = [
    "build_codex_packet",
    "build_enriched_prompt",
    "build_omitted_context",
    "build_prompt_compiler_packet",
    "bundle_for_direct_pass",
    "estimate_tokens",
    "indent_block",
]
