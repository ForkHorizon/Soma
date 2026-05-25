from __future__ import annotations

import json

from gateway.core import (
    _compact_result,
    _json,
    _ok_response,
    _safe_nexus_result,
    _safe_text,
    get_active_project_root,
    graphify,
    nexus,
)
from gateway.tools.context import soma_prepare_context
from gateway.tools.protocol import CODEX_START_NEXT_CALLS, codex_next_calls


async def soma_ask(question: str) -> str:
    """Answer a project question with Graphify context."""
    project_root = get_active_project_root()
    result = graphify.query(question, project_root, budget=1500)
    if result["answers"]:
        return _ok_response(
            "Answered from project graph.",
            answers=result["answers"],
            omitted={"graphs_consulted": result["graphs"], "warnings": result["warnings"][:2]},
            next_calls=codex_next_calls("Call soma_code_context if exact source snippets are needed."),
        )
    return _compact_result(
        "degraded",
        "No graph answer available.",
        omitted={"graphs_consulted": result["graphs"], "warnings": result["warnings"][:3]},
        next_calls=codex_next_calls("Run Graphify for the project or call soma_code_context for deterministic snippets."),
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
    base["next_calls"] = codex_next_calls("Use packet first.", "Call soma_inspect for the object/component named by errors.")
    return _json(base)


async def soma_review(focus: str = "current diff") -> str:
    """Prepare a bug/regression review packet."""
    goal = f"Review {focus} for behavioral regressions. Focus on bugs and missing tests, not style."
    payload = json.loads(await soma_prepare_context(goal=goal, budget="balanced", depth="ranked"))
    payload["next_calls"] = codex_next_calls(*payload.get("next_calls", CODEX_START_NEXT_CALLS))
    return _json(payload)
