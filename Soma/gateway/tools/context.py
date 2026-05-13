from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from scout_pipeline import (
    MAX_ERROR_LINES,
    MAX_EVIDENCE_ITEMS,
    TOKEN_BUDGETS,
    analyze_packet_with_model,
    assess_evidence_quality,
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
from soma_token_savings import (
    build_estimated_context_reduction,
    build_operation_savings,
    build_task_candidate_baseline,
    build_token_savings,
    finalize_operation_savings_response_tokens,
    unavailable_token_savings,
)

from gateway.core import (
    _analysis_depth,
    _append_graph_context,
    _compact_result,
    _enforce_packet_budget,
    _error_response,
    _evidence_summary,
    _ok_response,
    _packet_budget,
    _safe_nexus_result,
    _safe_text,
    get_active_project_root,
    graphify,
    memory_store,
    nexus,
)


async def soma_prepare_context(goal: str, budget: str = "balanced", depth: str = "deterministic") -> str:
    """Compile a bounded evidence packet for implementation, debug, or review work."""
    budget = _packet_budget(budget)
    depth = _analysis_depth(depth)
    token_model_profile = os.environ.get("SOMA_TOKEN_MODEL_PROFILE", "gpt-5.5")
    project_root = get_active_project_root()
    if not project_root or not os.path.isdir(project_root):
        token_savings = unavailable_token_savings(
            reason="No project root configured.",
            budget=budget,
            budget_tokens=TOKEN_BUDGETS[budget],
            model_profile=token_model_profile,
        )
        return _error_response(
            "No project root configured.",
            budget=budget,
            token_savings=token_savings,
            estimated_context_reduction=token_savings.get("estimated_context_reduction"),
            operation_savings=token_savings.get("operation_savings"),
            next_calls=["Set SOMA_PROJECT_ROOT or start Nexus Unity so Soma can discover projectPath."],
        )

    try:
        project_root = normalize_path(project_root)
        intent = classify_prompt_intent(goal)

        if not intent["needs_gather"]:
            bundle = bundle_for_direct_pass(goal, intent["reason"], project_root, budget, depth)
            packet = bundle["codex_packet"]
            token_savings = build_token_savings(
                packet=packet,
                budget=budget,
                budget_tokens=TOKEN_BUDGETS[budget],
                model_profile=token_model_profile,
                warnings=["Direct prompt did not need local evidence, so no raw-context baseline was available."],
            )
            estimated_context_reduction = token_savings.get("estimated_context_reduction")
            operation_savings = token_savings.get("operation_savings")
            return _ok_response(
                "Direct prompt does not need local evidence.",
                packet=packet,
                mode="direct",
                budget=budget,
                estimated_tokens=estimate_tokens(packet),
                token_savings=token_savings,
                estimated_context_reduction=estimated_context_reduction,
                operation_savings=operation_savings,
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

        explicit_items = gather_external_evidence(goal, project_root, terms, discovered, repo_index)
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

        graph_result = graphify.query(goal, project_root, budget=1200, project_only=True)
        graph_context = "\n\n".join(answer["answer"] for answer in graph_result["answers"])
        summary = fallback_summary(goal, project_root, project_type, evidence_items, error_lines, preflight["packet_mode"])
        evidence_quality = assess_evidence_quality(goal, evidence_items, preflight)

        bundle = {
            "mode": "gather",
            "status": evidence_quality["status"],
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
            "evidence_quality": evidence_quality,
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
                "graphify": "project_only" if graph_result.get("graphs") else "skipped",
                "evidence_quality": evidence_quality,
            },
        }

        packet = _append_graph_context(build_codex_packet(goal, bundle, budget), graph_context, budget)
        packet = _enforce_packet_budget(goal, bundle, packet, budget)
        estimated = estimate_tokens(packet)
        task_baseline = build_task_candidate_baseline(
            project_root=project_root,
            discovered=discovered,
            preflight=preflight,
            evidence_items=evidence_items,
            git_status=git_status,
            git_diff_summary=git_diff_summary,
            model_profile=token_model_profile,
            packet_tokens=estimated,
        )
        estimated_context_reduction = build_estimated_context_reduction(
            packet=packet,
            budget=budget,
            budget_tokens=TOKEN_BUDGETS[budget],
            model_profile=token_model_profile,
            task_candidate_baseline=task_baseline,
        )
        operation_savings = build_operation_savings(
            packet=packet,
            project_root=project_root,
            git_status=git_status,
            evidence_items=evidence_items,
            budget=budget,
            budget_tokens=TOKEN_BUDGETS[budget],
            model_profile=token_model_profile,
        )
        token_savings = build_token_savings(
            packet=packet,
            budget=budget,
            budget_tokens=TOKEN_BUDGETS[budget],
            model_profile=token_model_profile,
            estimated_context_reduction=estimated_context_reduction,
            operation_savings=operation_savings,
        )
        omitted = {
            **bundle["omitted_context"],
            "budget_tokens": TOKEN_BUDGETS[budget],
            "estimated_tokens": estimated,
            "raw_git_diff_chars": (git_diff_summary or {}).get("raw_diff_chars_omitted", 0),
            "git_changed_file_count": (git_diff_summary or {}).get("changed_file_count", 0),
            "graphs_consulted": graph_result["graphs"][:3],
            "graphify": "project_only" if graph_result.get("graphs") else "skipped",
        }
        summary_text = f"Prepared {preflight['packet_mode']} packet within {budget} budget."
        response_kwargs = {
            "packet": packet,
            "project_type": project_type,
            "packet_mode": preflight["packet_mode"],
            "mode": preflight["packet_mode"],
            "budget": budget,
            "depth": depth,
            "confidence": summary.get("confidence", 0.55),
            "estimated_tokens": estimated,
            "token_savings": token_savings,
            "estimated_context_reduction": estimated_context_reduction,
            "operation_savings": operation_savings,
            "evidence": _evidence_summary(evidence_items),
            "omitted": omitted,
            "evidence_quality": evidence_quality,
            "analysis_stages": stages,
            "next_calls": ["Use packet first.", "Call soma_code_context for 1 focused missing area.", "Call soma_inspect for 1 Unity object/component."],
        }
        if evidence_quality["status"] == "ok":
            first_render = _ok_response(summary_text, **response_kwargs)
        else:
            first_render = _compact_result("degraded", summary_text, **response_kwargs)
        operation_savings = finalize_operation_savings_response_tokens(operation_savings, estimate_tokens(first_render))
        token_savings = build_token_savings(
            packet=packet,
            budget=budget,
            budget_tokens=TOKEN_BUDGETS[budget],
            model_profile=token_model_profile,
            estimated_context_reduction=estimated_context_reduction,
            operation_savings=operation_savings,
        )
        response_kwargs["operation_savings"] = operation_savings
        response_kwargs["token_savings"] = token_savings
        if evidence_quality["status"] == "ok":
            return _ok_response(summary_text, **response_kwargs)
        return _compact_result("degraded", summary_text, **response_kwargs)
    except Exception as exc:
        token_savings = unavailable_token_savings(
            reason=str(exc),
            budget=budget,
            budget_tokens=TOKEN_BUDGETS[budget],
            model_profile=token_model_profile,
        )
        return _error_response(
            f"soma_prepare_context failed: {exc}",
            budget=budget,
            token_savings=token_savings,
            estimated_context_reduction=token_savings.get("estimated_context_reduction"),
            operation_savings=token_savings.get("operation_savings"),
        )


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
    graph_result = graphify.query(query, project_root, budget=1200, project_only=True)

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
