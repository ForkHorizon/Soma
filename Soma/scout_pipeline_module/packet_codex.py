"""Standard Codex packet construction."""

from .config import DEFAULT_TOKEN_BUDGET, MAX_ERROR_LINES, TOKEN_BUDGETS
from .packet_utils import build_omitted_context, estimate_tokens, indent_block, _focused_source_preview


def build_codex_packet(user_prompt, bundle, token_budget=DEFAULT_TOKEN_BUDGET):
    max_tokens = TOKEN_BUDGETS.get(token_budget, TOKEN_BUDGETS[DEFAULT_TOKEN_BUDGET])
    evidence_items = list(bundle.get("evidence_items") or [])
    preview_chars = 900
    while True:
        parts = _codex_parts(user_prompt, bundle, token_budget, max_tokens, evidence_items, preview_chars)
        packet = "\n".join(parts).strip()
        if estimate_tokens(packet) <= max_tokens or (len(evidence_items) <= 3 and preview_chars <= 450):
            return packet
        preview_chars, evidence_items = _shrink_packet(preview_chars, evidence_items)


def _codex_parts(user_prompt, bundle, token_budget, max_tokens, evidence_items, preview_chars):
    from .git import format_git_diff_summary
    from .ranker import format_model_analysis, format_preflight

    parts = _header(user_prompt, bundle, token_budget, max_tokens)
    _append_language_optimization(parts, bundle)
    _extend_named(parts, "Preflight:", format_preflight(bundle.get("preflight")))
    _append_optional_text(parts, "Summary:", bundle.get("context_summary"))
    _append_graph_suggestions(parts, bundle, evidence_items)
    _extend_named(parts, "Assumptions:", [f"- {item}" for item in (bundle.get("assumptions") or [])[:5]])
    _append_optional_text(parts, "Git status:", bundle.get("git_status"))
    _extend_named(parts, "Git diff summary:", format_git_diff_summary(bundle.get("git_diff_summary")))
    _extend_named(
        parts, "Normalized errors:", [f"- {line}" for line in (bundle.get("error_lines") or [])[:MAX_ERROR_LINES]]
    )
    _append_evidence(parts, user_prompt, evidence_items, preview_chars)
    _extend_named(parts, "Optional local analysis:", format_model_analysis(bundle.get("model_analysis")))
    _extend_named(parts, "Open questions:", [f"- {item}" for item in (bundle.get("open_questions") or [])[:4]])
    _append_omitted(parts, bundle)
    parts.extend(
        [
            "",
            "Expected Codex behavior:",
            "- Diagnose from this packet first.",
            "- Answer in English.",
            "- Request at most 1-3 extra files/commands if blocked.",
            "- Do not refactor unrelated code.",
        ]
    )
    return parts


def _header(user_prompt, bundle, token_budget, max_tokens):
    return [
        "Goal:",
        user_prompt.strip(),
        "",
        "Use only the evidence below first. If insufficient, ask for exactly 1-3 missing files or commands.",
        "",
        "Known facts:",
        f"- Project root: {bundle.get('project_root') or '[not selected]'}",
        f"- Project type: {bundle.get('project_type') or 'unknown'}",
        f"- Route: {bundle.get('routing_decision')}",
        f"- Packet mode: {bundle.get('packet_mode', 'direct')}",
        f"- Analysis depth: {bundle.get('analysis_depth', 'deterministic')}",
        f"- Confidence: {bundle.get('confidence', 0):.2f}",
        f"- Token budget: {token_budget} <= {max_tokens} estimated tokens",
    ]


def _append_language_optimization(parts, bundle):
    info = bundle.get("language_optimization") or {}
    source_language = info.get("source_language")
    if source_language and source_language != "en":
        parts.extend(
            [
                f"- Original language: {source_language}",
                f"- Language optimization: {info.get('status')}",
                "- Expected answer language: English",
            ]
        )


def _append_optional_text(parts, title, value):
    if value:
        parts.extend(["", title, value])


def _extend_named(parts, title, lines):
    if lines:
        parts.extend(["", title])
        parts.extend(lines)


def _append_graph_suggestions(parts, bundle, evidence_items):
    suggestions = [str(item).strip() for item in (bundle.get("graph_suggestions") or []) if str(item).strip()]
    files = [
        str(path).strip()
        for path in ((bundle.get("omitted_context") or {}).get("graph_suggested_files") or [])
        if str(path).strip()
    ]
    if not (suggestions or files):
        return
    parts.extend(["", "Graph suggested:"])
    if files:
        selected_total = len(evidence_items)
        parts.append(
            f"- Files {min(len(files), selected_total)}/{selected_total}: graph query/affected hints boosted project-local evidence only."
        )
    parts.extend(f"- {item}" for item in suggestions[:3])


def _append_evidence(parts, user_prompt, evidence_items, preview_chars):
    if not evidence_items:
        return
    from .parser import format_line_range

    parts.extend(["", "Evidence:"])
    source_preview_count = 0
    for index, item in enumerate(evidence_items, start=1):
        source_preview_count = _append_evidence_item(
            parts, user_prompt, item, index, preview_chars, source_preview_count, format_line_range
        )


def _append_evidence_item(parts, user_prompt, item, index, preview_chars, source_preview_count, format_line_range):
    line_range = format_line_range(item)
    parts.extend(
        [
            f"{index}. {item.get('path', '[unknown]')}{line_range} [{item.get('kind', 'file')}]",
            f"   Reason: {item.get('reason', '')}",
        ]
    )
    if item.get("symbols"):
        parts.append(f"   Symbols: {', '.join(item['symbols'][:8])}")
    if item.get("unity_refs"):
        parts.append(f"   Unity refs: {', '.join(item['unity_refs'][:5])}")
    preview, source_preview_count = _evidence_preview(user_prompt, item, preview_chars, source_preview_count)
    parts.extend(["   Snippet:", indent_block(preview or "[No preview available]", "   ")])
    return source_preview_count


def _evidence_preview(user_prompt, item, preview_chars, source_preview_count):
    preview_limit = preview_chars
    preview = None
    if item.get("kind") == "source":
        source_preview_count += 1
        if source_preview_count <= 3:
            preview_limit = preview_chars + 700
            preview = _focused_source_preview(user_prompt, item, preview_limit)
    return (preview or (item.get("preview") or "")[:preview_limit].strip()), source_preview_count


def _append_omitted(parts, bundle):
    omitted = build_omitted_context(bundle)
    if omitted:
        parts.extend(["", "Omitted context:"])
        parts.extend(f"- {key}: {value}" for key, value in omitted.items())


def _shrink_packet(preview_chars, evidence_items):
    if preview_chars > 450:
        return preview_chars - 150, evidence_items
    return preview_chars, evidence_items[: max(3, len(evidence_items) - 1)]
