"""Scout pipeline orchestration helpers."""

import os
import re

from .config import DEFAULT_TOKEN_BUDGET, TOKEN_BUDGETS


def _query_graphify_context(goal, project_root, budget=1200):
    try:
        from gateway.graphify_adapter import GraphifyAdapter

        result = GraphifyAdapter().query(goal, project_root, budget=budget, project_only=True)
    except Exception as exc:
        return {"graphs": [], "answers": [], "warnings": [f"graphify unavailable: {exc}"], "project_only": True}
    if not isinstance(result, dict):
        return {
            "graphs": [],
            "answers": [],
            "warnings": ["graphify unavailable: invalid response"],
            "project_only": True,
        }
    return {
        "graphs": [str(graph) for graph in result.get("graphs") or []],
        "answers": [answer for answer in result.get("answers") or [] if isinstance(answer, dict)],
        "affected": [answer for answer in result.get("affected") or [] if isinstance(answer, dict)],
        "warnings": [str(warning) for warning in result.get("warnings") or []],
        "project_only": result.get("project_only", True),
    }


def _graph_context_text(graph_result):
    parts = []
    for answer in list(graph_result.get("answers") or []) + list(graph_result.get("affected") or []):
        text = str(answer.get("answer") or "").strip()
        if text:
            parts.append(text)
    return "\n\n".join(parts)


def _graph_suggestion_lines(graph_result, limit=3):
    suggestions = _answer_suggestions(graph_result.get("answers") or [], limit)
    if len(suggestions) < limit:
        suggestions.extend(_affected_suggestions(graph_result.get("affected") or [], limit - len(suggestions)))
    return suggestions[:limit]


def _answer_suggestions(answers, limit):
    suggestions = []
    for answer in answers:
        text = str(answer.get("answer") or "").strip()
        if not text:
            continue
        for line in text.splitlines():
            cleaned = line.strip().lstrip("-*0123456789. ")
            if cleaned:
                suggestions.append(cleaned[:180])
                break
        if len(suggestions) >= limit:
            break
    return suggestions


def _affected_suggestions(answers, limit):
    suggestions = []
    for answer in answers:
        text = str(answer.get("answer") or "").strip()
        term = str(answer.get("term") or "").strip()
        if text:
            prefix = f"Affected hints for {term}: " if term else "Affected hints: "
            suggestions.append((prefix + text.splitlines()[0].strip()[:150])[:180])
        if len(suggestions) >= limit:
            break
    return suggestions


def _graph_suggested_project_paths(graph_result, project_root, max_paths=3):
    if not project_root:
        return []
    root = os.path.normpath(project_root)
    pattern = re.compile(
        r"(?<![\w/.-])((?:[\w@+.-]+/)*[\w@+.-]+\.(?:swift|py|ts|tsx|js|jsx|cs|md|json|toml|yaml|yml))(?![\w.-])"
    )
    paths = []
    for answer in list(graph_result.get("answers") or []) + list(graph_result.get("affected") or []):
        paths.extend(_paths_from_graph_text(str(answer.get("answer") or ""), pattern, root, max_paths - len(paths)))
        if len(paths) >= max_paths:
            break
    return paths[:max_paths]


def _paths_from_graph_text(text, pattern, root, remaining):
    paths = []
    for match in pattern.findall(text):
        candidate = match.strip().strip("`\"'.,:;()[]{}").replace("\\", "/")
        full_path = candidate if os.path.isabs(candidate) else os.path.join(root, candidate)
        full_path = os.path.normpath(full_path)
        if (full_path == root or full_path.startswith(root + os.sep)) and os.path.isfile(full_path):
            if full_path not in paths:
                paths.append(full_path)
        if len(paths) >= remaining:
            break
    return paths


def _graph_hints_allowed_for_plan(collection_plan):
    required = set((collection_plan or {}).get("required_evidence") or [])
    if {"graphify_version", "changelog"} & required:
        return (
            False,
            "graphify skipped: version/changelog tasks need command or changelog evidence, not graph node hints",
        )
    return True, None


def _append_graph_context(packet, graph_context, token_budget, estimate_tokens_func):
    if not graph_context:
        return packet
    max_tokens = TOKEN_BUDGETS.get(token_budget, TOKEN_BUDGETS[DEFAULT_TOKEN_BUDGET])
    remaining = max(0, max_tokens - estimate_tokens_func(packet))
    if remaining < 120:
        return packet
    graph_chars = min(1500, remaining * 4)
    enriched = f"{packet}\n\nGraph context (from Graphify):\n{graph_context[:graph_chars]}"
    while estimate_tokens_func(enriched) > max_tokens and graph_chars > 300:
        graph_chars -= 200
        enriched = f"{packet}\n\nGraph context (from Graphify):\n{graph_context[:graph_chars]}"
    return enriched if estimate_tokens_func(enriched) <= max_tokens else packet


def _graph_matches_collection_scope(graph_result, collection_plan=None, preflight=None):
    from .utils import is_generated_dependency_path, normalize_path

    collection_plan = collection_plan or {}
    preflight = preflight or {}
    target_scope = collection_plan.get("target_scope")
    if not target_scope or target_scope == "unknown":
        return False, ["graphify skipped: collection scope was unknown"]
    graphs = graph_result.get("graphs") or []
    if not graphs:
        return False, graph_result.get("warnings") or []
    return _graph_scope_match(
        graphs, target_scope, preflight.get("focus_root"), graph_result, normalize_path, is_generated_dependency_path
    )


def _graph_scope_match(graphs, target_scope, focus_root, graph_result, normalize_path, is_generated_dependency_path):
    for graph in graphs:
        graph_path = str(graph)
        if is_generated_dependency_path(graph_path):
            continue
        if "/.soma/graphs/projects/" in graph_path.replace("\\", "/"):
            return True, graph_result.get("warnings") or []
        if focus_root and _graph_parent_matches_focus(graph_path, focus_root, normalize_path):
            return True, graph_result.get("warnings") or []
        if not focus_root and target_scope == "whole_project":
            return True, graph_result.get("warnings") or []
    return False, ["graphify skipped: graph scope did not match collection plan"]


def _graph_parent_matches_focus(graph_path, focus_root, normalize_path):
    try:
        return normalize_path(os.path.dirname(os.path.dirname(graph_path))) == normalize_path(focus_root)
    except Exception:
        return False


async def run_gather(
    user_prompt,
    project_root,
    recent_roots_json,
    token_budget=DEFAULT_TOKEN_BUDGET,
    use_local_summary=False,
    analysis_depth="deterministic",
    packet_profile="standard",
    planning_mode="auto",
):
    from .pipeline_runner import run_gather_impl

    await run_gather_impl(
        user_prompt,
        project_root,
        recent_roots_json,
        token_budget=token_budget,
        use_local_summary=use_local_summary,
        analysis_depth=analysis_depth,
        packet_profile=packet_profile,
        planning_mode=planning_mode,
        graph_query=_query_graphify_context,
        graph_suggestion_lines=_graph_suggestion_lines,
        graph_suggested_paths=_graph_suggested_project_paths,
        graph_hints_allowed=_graph_hints_allowed_for_plan,
        graph_matches_scope=_graph_matches_collection_scope,
    )
