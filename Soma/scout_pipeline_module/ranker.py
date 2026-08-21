"""Optional local model ranking and analysis.

Ranker and analyst stages may improve packet ordering or add hypotheses, but
their failures must never block deterministic evidence packets.
"""

import json
import time


from pathlib import Path


from .config import *


def _ollama_model_query_func():
    import sys

    public_module = sys.modules.get("scout_pipeline")
    public_func = getattr(public_module, "query_ollama_model", None) if public_module else None
    if public_func:
        return public_func
    from .llama import query_ollama_model

    return query_ollama_model


def fallback_summary(prompt, project_root, project_type, evidence_items, error_lines, packet_mode="debug"):
    assumptions = []
    open_questions = []
    lowered_prompt = (prompt or "").lower()
    wants_log_evidence = packet_mode == "debug" or any(
        term in lowered_prompt
        for term in ("log", "logs", "error", "traceback", "crash", "exception", "fail", "failure")
    )
    script_candidates = [item for item in evidence_items if (item["kind"] == "script")]
    if ("script" in prompt.lower()) and script_candidates:
        assumptions.append(
            f"Assumed `{Path(script_candidates[0]['path']).name}` is the most relevant script based on ranking."
        )
        if len(script_candidates) > 1:
            open_questions.append("Multiple script candidates were found; confirm the exact entry point if needed.")
    if wants_log_evidence and (not error_lines):
        open_questions.append("No explicit error lines were found in the selected excerpts.")
    if wants_log_evidence and (not any(((item["kind"] == "log") for item in evidence_items))):
        open_questions.append("No repo-local logs were found; a runtime log path may still be needed.")
    summary = f"Prepared a {packet_mode} packet with {len(evidence_items)} targeted evidence item(s) from the {project_type} project at `{project_root}`."
    confidence = 0.72 if error_lines else 0.58
    return {
        "summary": summary,
        "assumptions": assumptions[:3],
        "open_questions": open_questions[:3],
        "confidence": confidence,
    }


def should_use_model_summary(model_summary):
    if not model_summary:
        return False
    summary_text = (model_summary.get("summary") or "").lower()
    if model_summary.get("confidence", 0) < 0.35:
        return False
    if ("not working as expected" in summary_text) or ("seems" in summary_text):
        return False
    return True


async def summarize_with_ollama(prompt, project_root, project_type, evidence_items, error_lines):
    from .llama import query_ollama
    from .parser import extract_json_object

    summary_payload = {
        "prompt": prompt,
        "project_root": project_root,
        "project_type": project_type,
        "evidence": [
            {"path": item["path"], "kind": item["kind"], "reason": item["reason"], "preview": item["preview"][:700]}
            for item in evidence_items
        ],
        "error_lines": error_lines[:MAX_ERROR_LINES],
    }
    response = await query_ollama(
        [
            {"role": "system", "content": OLLAMA_SUMMARY_SYSTEM},
            {"role": "user", "content": json.dumps(summary_payload)},
        ],
        timeout=OLLAMA_SUMMARY_TIMEOUT,
        stage="summary",
    )
    if "error" in response:
        return None
    content = response.get("message", {}).get("content", "")
    decoded = extract_json_object(content)
    if not isinstance(decoded, dict):
        return None
    confidence = decoded.get("confidence")
    if not isinstance(confidence, (int, float)):
        confidence = 0.55
    return {
        "summary": (decoded.get("summary") or ""),
        "assumptions": (decoded.get("assumptions") or []),
        "open_questions": (decoded.get("open_questions") or []),
        "confidence": max(0.0, min(1.0, float(confidence))),
    }


def ranker_payload(prompt, preflight, evidence_items):
    return {
        "prompt": prompt,
        "packet_mode": preflight.get("packet_mode"),
        "terms": (preflight.get("terms") or []),
        "candidates": [
            {
                "id": index,
                "path": item.get("path"),
                "kind": item.get("kind"),
                "reason": item.get("reason"),
                "symbols": (item.get("symbols") or []),
                "preview": (item.get("preview") or "")[:220],
            }
            for (index, item) in enumerate(evidence_items)
        ],
    }


def _estimate_stage_tokens(text):
    try:
        from .packet import estimate_tokens

        return estimate_tokens(text or "")
    except Exception:
        return max(0, len(text or "") // 4)


def _string_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item) for item in value if item]
    if isinstance(value, str):
        return [value] if value.strip() else []
    return [str(value)]


def candidate_filter_payload(prompt, preflight, evidence_items):
    return {
        "prompt": prompt,
        "packet_mode": preflight.get("packet_mode"),
        "terms": (preflight.get("terms") or []),
        "selection_policy": "Prefer project-owned files, changed files, tests, manifests/configs, and logs relevant to the task. Avoid generated/dependency files unless explicitly referenced.",
        "candidates": [
            {
                "id": index,
                "path": item.get("path"),
                "kind": item.get("kind"),
                "reason": item.get("reason"),
                "symbols": (item.get("symbols") or [])[:12],
                "preview": (item.get("preview") or "")[:180],
            }
            for (index, item) in enumerate(evidence_items)
        ],
    }


def pinned_evidence_ids(prompt, preflight, evidence_items):
    from .classifier import is_open_source_readiness_prompt
    from .utils import normalize_path

    terms = set((preflight or {}).get("expanded_terms") or (preflight or {}).get("terms") or [])
    lowered_prompt = (prompt or "").lower()
    if is_open_source_readiness_prompt(prompt):
        focus_root = (preflight or {}).get("focus_root")
        focus_root = normalize_path(focus_root) if focus_root else None
        pinned = []
        priority_names = {
            "package.json": 0,
            "readme.md": 1,
            "license.md": 2,
            "changelog.md": 3,
            "api_reference.md": 4,
            "documentation.md": 5,
            "opensourceapicontracttests.cs": 6,
            "mcpserver.cs": 7,
            "mcpservermethods.cs": 8,
            "nexus_unity_bridge.py": 9,
        }
        ranked = []
        for index, item in enumerate(evidence_items):
            raw_path = str(item.get("path") or "")
            path = raw_path.replace("\\", "/").lower()
            try:
                in_focus = (not focus_root) or normalize_path(raw_path).startswith(focus_root)
            except Exception:
                in_focus = True
            if not in_focus:
                continue
            name = Path(path).name.lower()
            if name in priority_names:
                ranked.append((priority_names[name], index))
            elif path.endswith(".asmdef") or "/tests/" in path:
                ranked.append((10, index))
        for _, index in sorted(ranked):
            pinned.append(index)
        if pinned:
            return list(dict.fromkeys(pinned))
    android_icon = bool(terms & {"apk", "android"}) and bool(
        terms & {"icon", "icons", "launcher", "mipmap", "adaptive"}
    )
    if android_icon or ("apk" in lowered_prompt and "icon" in lowered_prompt):
        pinned = []
        for index, item in enumerate(evidence_items):
            path = str(item.get("path") or "").replace("\\", "/").lower()
            if path.endswith("/projectsettings/projectsettings.asset"):
                pinned.append(index)
            if path.endswith("/assets/plugins/android/androidmanifest.xml"):
                pinned.append(index)
            if "/assets/" in path and "/icon" in path and path.endswith((".png.meta", ".png", ".asset", ".meta")):
                pinned.append(index)
        return list(dict.fromkeys(pinned))
    local_ai = (
        "ollama" in terms
        or ("local" in terms and ("ai" in terms or "model" in terms))
        or "local ai" in lowered_prompt
        or "local model" in lowered_prompt
    )
    configurable = bool(terms & {"configurable", "settings", "state", "set", "interval", "time", "application"})
    if not local_ai:
        return []

    pinned = []
    for index, item in enumerate(evidence_items):
        path = str(item.get("path") or "").replace("\\", "/").lower()
        if path.endswith("/ollamamanager.swift"):
            pinned.append(index)
        if configurable and (path.endswith("/globalsettingsbar.swift") or path.endswith("/somaviewmodel.swift")):
            pinned.append(index)
    return list(dict.fromkeys(pinned))


async def filter_candidates_with_model(prompt, preflight, evidence_items, max_items=MAX_EVIDENCE_ITEMS):
    from .parser import extract_json_object

    query_ollama_model = _ollama_model_query_func()
    if len(evidence_items) <= max_items:
        return (
            evidence_items,
            {
                "stage": "candidate_filter",
                "model": RANKER_MODEL,
                "status": "skipped",
                "candidate_count_before": len(evidence_items),
                "candidate_count_after": len(evidence_items),
            },
        )
    pinned_ids = pinned_evidence_ids(prompt, preflight, evidence_items)
    user_payload = json.dumps(candidate_filter_payload(prompt, preflight, evidence_items))
    start = time.monotonic()
    response = await query_ollama_model(
        RANKER_MODEL,
        [
            {
                "role": "system",
                "content": 'Choose the best evidence candidates for a compact code packet. Return JSON only: {"selected_ids":[0,1],"notes":["..."]}. Use only candidate ids.',
            },
            {"role": "user", "content": user_payload},
        ],
        timeout=30,
        num_predict=220,
        json_mode=True,
        stage="candidate_filter",
        metadata={"candidate_count_before": len(evidence_items)},
    )
    base_stage = {
        "stage": "candidate_filter",
        "model": RANKER_MODEL,
        "candidate_count_before": len(evidence_items),
        "candidate_tokens_before": _estimate_stage_tokens(user_payload),
        "duration_ms": (time.monotonic() - start) * 1000,
    }
    if "error" in response:
        return (
            evidence_items[:max_items],
            {
                **base_stage,
                "status": "failed",
                "error": response["error"],
                "candidate_count_after": max_items,
                "candidate_tokens_after": _estimate_stage_tokens(
                    json.dumps(ranker_payload(prompt, preflight, evidence_items[:max_items]))
                ),
            },
        )
    decoded = extract_json_object(response.get("message", {}).get("content", ""))
    if not isinstance(decoded, dict) or not isinstance(decoded.get("selected_ids"), list):
        return (
            evidence_items[:max_items],
            {
                **base_stage,
                "status": "failed",
                "error": "invalid candidate_filter JSON",
                "candidate_count_after": max_items,
                "candidate_tokens_after": _estimate_stage_tokens(
                    json.dumps(ranker_payload(prompt, preflight, evidence_items[:max_items]))
                ),
            },
        )
    selected = []
    seen = set()
    for pinned_id in pinned_ids:
        if 0 <= pinned_id < len(evidence_items):
            selected.append(evidence_items[pinned_id])
            seen.add(pinned_id)
        if len(selected) >= max_items:
            break
    for raw_id in decoded.get("selected_ids", []):
        if isinstance(raw_id, int) and 0 <= raw_id < len(evidence_items) and raw_id not in seen:
            selected.append(evidence_items[raw_id])
            seen.add(raw_id)
        if len(selected) >= max_items:
            break
    if not selected:
        selected = evidence_items[:max_items]
    after_tokens = _estimate_stage_tokens(json.dumps(ranker_payload(prompt, preflight, selected)))
    return (
        selected,
        {
            **base_stage,
            "status": "ok",
            "notes": _string_list(decoded.get("notes")),
            "candidate_count_after": len(selected),
            "candidate_tokens_after": after_tokens,
            "local_ai_net_savings_tokens": max(0, base_stage["candidate_tokens_before"] - after_tokens),
        },
    )


async def rank_evidence_with_model(prompt, preflight, evidence_items):
    from .parser import extract_json_object

    query_ollama_model = _ollama_model_query_func()
    if not evidence_items:
        return (evidence_items, {"stage": "ranker", "model": RANKER_MODEL, "status": "skipped"})
    decoded = None
    last_error = "invalid ranker JSON"
    payload = json.dumps(ranker_payload(prompt, preflight, evidence_items))
    prompts = [
        'Rank small evidence candidates for a Codex packet. Return JSON only: {"ordered_ids":[0,1],"notes":["..."]}. Use only candidate ids.',
        'Return only minified JSON with this exact schema: {"ordered_ids":[0,1]}. Use integer candidate ids only. No notes.',
    ]
    for attempt, system in enumerate(prompts, start=1):
        start = time.monotonic()
        response = await query_ollama_model(
            RANKER_MODEL,
            [{"role": "system", "content": system}, {"role": "user", "content": payload}],
            timeout=25,
            num_predict=(180 if (attempt == 1) else 96),
            json_mode=True,
            stage="ranker",
            metadata={"candidate_count_before": len(evidence_items)},
        )
        duration_ms = (time.monotonic() - start) * 1000
        if "error" in response:
            return (
                evidence_items,
                {
                    "stage": "ranker",
                    "model": RANKER_MODEL,
                    "status": "failed",
                    "error": response["error"],
                    "duration_ms": duration_ms,
                },
            )
        decoded = extract_json_object(response.get("message", {}).get("content", ""))
        if isinstance(decoded, dict) and isinstance(decoded.get("ordered_ids"), list):
            break
        last_error = f"invalid ranker JSON after attempt {attempt}"
    if (not isinstance(decoded, dict)) or (not isinstance(decoded.get("ordered_ids"), list)):
        return (evidence_items, {"stage": "ranker", "model": RANKER_MODEL, "status": "failed", "error": last_error})
    ordered = []
    seen = set()
    for raw_id in decoded.get("ordered_ids", []):
        if (not isinstance(raw_id, int)) or (raw_id < 0) or (raw_id >= len(evidence_items)) or (raw_id in seen):
            continue
        seen.add(raw_id)
        ordered.append(evidence_items[raw_id])
    ordered.extend((item for (index, item) in enumerate(evidence_items) if (index not in seen)))
    return (
        ordered,
        {
            "stage": "ranker",
            "model": RANKER_MODEL,
            "status": "ok",
            "notes": _string_list(decoded.get("notes")),
            "candidate_count_before": len(evidence_items),
            "candidate_count_after": len(ordered),
            "duration_ms": duration_ms if "duration_ms" in locals() else 0,
        },
    )


async def analyze_packet_with_model(prompt, preflight, evidence_items, error_lines):
    from .parser import extract_json_object

    query_ollama_model = _ollama_model_query_func()
    payload = {
        "prompt": prompt,
        "packet_mode": preflight.get("packet_mode"),
        "evidence": [
            {
                "path": item.get("path"),
                "kind": item.get("kind"),
                "reason": item.get("reason"),
                "preview": (item.get("preview") or "")[:500],
            }
            for item in evidence_items
        ],
        "error_lines": error_lines[:MAX_ERROR_LINES],
    }
    decoded = None
    last_error = "invalid analyst JSON"
    user_payload = json.dumps(payload)
    prompts = [
        'Analyze a compact evidence packet. Return JSON only with {"hypotheses":["..."],"missing_context":["..."]}. Do not invent facts.',
        'Return only minified JSON with this exact schema: {"hypotheses":["..."],"missing_context":["..."]}. Use only facts from the provided packet.',
    ]
    for attempt, system in enumerate(prompts, start=1):
        start = time.monotonic()
        response = await query_ollama_model(
            ANALYST_MODEL,
            [{"role": "system", "content": system}, {"role": "user", "content": user_payload}],
            timeout=45,
            num_predict=280,
            json_mode=True,
            stage="analyst",
            metadata={"candidate_count_before": len(evidence_items)},
        )
        duration_ms = (time.monotonic() - start) * 1000
        if "error" in response:
            return (
                None,
                {
                    "stage": "analyst",
                    "model": ANALYST_MODEL,
                    "status": "failed",
                    "error": response["error"],
                    "duration_ms": duration_ms,
                },
            )
        decoded = extract_json_object(response.get("message", {}).get("content", ""))
        if isinstance(decoded, dict):
            break
        last_error = f"invalid analyst JSON after attempt {attempt}"
    if not isinstance(decoded, dict):
        return (None, {"stage": "analyst", "model": ANALYST_MODEL, "status": "failed", "error": last_error})
    decoded["hypotheses"] = _string_list(decoded.get("hypotheses"))
    decoded["missing_context"] = _string_list(decoded.get("missing_context"))
    return (
        decoded,
        {
            "stage": "analyst",
            "model": ANALYST_MODEL,
            "status": "ok",
            "duration_ms": duration_ms if "duration_ms" in locals() else 0,
        },
    )


async def referee_evidence_with_model(prompt, preflight, evidence_items, evidence_quality):
    from .parser import extract_json_object

    query_ollama_model = _ollama_model_query_func()
    payload = {
        "prompt": prompt,
        "packet_mode": preflight.get("packet_mode"),
        "evidence_quality": evidence_quality,
        "evidence": [
            {
                "id": index,
                "path": item.get("path"),
                "kind": item.get("kind"),
                "reason": item.get("reason"),
                "symbols": (item.get("symbols") or [])[:10],
            }
            for (index, item) in enumerate(evidence_items)
        ],
    }
    user_payload = json.dumps(payload)
    start = time.monotonic()
    response = await query_ollama_model(
        RANKER_MODEL,
        [
            {
                "role": "system",
                "content": 'Review selected evidence quality for a code packet. Return JSON only: {"status":"ok|degraded","warnings":["..."],"missing_context":["..."]}. Do not invent files.',
            },
            {"role": "user", "content": user_payload},
        ],
        timeout=25,
        num_predict=180,
        json_mode=True,
        stage="quality_referee",
        metadata={"candidate_count_before": len(evidence_items), "candidate_count_after": len(evidence_items)},
    )
    stage = {
        "stage": "quality_referee",
        "model": RANKER_MODEL,
        "candidate_count_before": len(evidence_items),
        "candidate_count_after": len(evidence_items),
        "candidate_tokens_before": _estimate_stage_tokens(user_payload),
        "candidate_tokens_after": _estimate_stage_tokens(user_payload),
        "duration_ms": (time.monotonic() - start) * 1000,
    }
    if "error" in response:
        return (evidence_quality, {**stage, "status": "failed", "error": response["error"]})
    decoded = extract_json_object(response.get("message", {}).get("content", ""))
    if not isinstance(decoded, dict):
        return (evidence_quality, {**stage, "status": "failed", "error": "invalid quality_referee JSON"})
    updated = dict(evidence_quality or {})
    warnings = list(updated.get("warnings") or [])
    warnings.extend(_string_list(decoded.get("warnings")))
    missing_context = _string_list(decoded.get("missing_context"))
    if missing_context:
        warnings.append("Local AI referee requested more evidence.")
        updated["referee_missing_context"] = missing_context[:6]
    if decoded.get("status") == "degraded":
        updated["status"] = "degraded"
    updated["warnings"] = list(dict.fromkeys(warnings))[:10]
    return (
        updated,
        {
            **stage,
            "status": "ok",
            "referee_status": decoded.get("status") or updated.get("status"),
            "notes": updated["warnings"][:4],
        },
    )


def format_preflight(preflight):
    if not preflight:
        return []
    lines = [
        f"- Mode: {preflight.get('packet_mode', 'direct')}",
        f"- Intent confidence: {preflight.get('confidence', 0):.2f}",
    ]
    if preflight.get("explicit_paths"):
        lines.append(f"- Explicit paths: {len(preflight['explicit_paths'])}")
    if preflight.get("changed_files"):
        lines.append(f"- Changed files considered: {len(preflight['changed_files'])}")
    if preflight.get("log_candidates"):
        lines.append(f"- Log candidates considered: {len(preflight['log_candidates'])}")
    return lines


def format_model_analysis(model_analysis):
    if not model_analysis:
        return []
    lines = []
    hypotheses = _string_list(model_analysis.get("hypotheses"))
    missing = _string_list(model_analysis.get("missing_context"))
    if hypotheses:
        lines.append("Local analyst hypotheses:")
        lines.extend((f"- {item}" for item in hypotheses[:4]))
    if missing:
        lines.append("Local analyst missing context:")
        lines.extend((f"- {item}" for item in missing[:4]))
    return lines


def summarize_local_ai_stages(analysis_stages):
    stages = [stage for stage in (analysis_stages or []) if isinstance(stage, dict) and stage.get("model")]
    input_tokens = sum(int(stage.get("input_tokens") or stage.get("candidate_tokens_before") or 0) for stage in stages)
    output_tokens = sum(int(stage.get("output_tokens") or 0) for stage in stages)
    before = sum(int(stage.get("candidate_tokens_before") or 0) for stage in stages)
    after = sum(int(stage.get("candidate_tokens_after") or 0) for stage in stages)
    latency = sum(float(stage.get("duration_ms") or 0) for stage in stages)
    return {
        "local_ai_policy": "aggressive",
        "local_ai_call_count": len([stage for stage in stages if stage.get("status") != "skipped"]),
        "local_ai_input_tokens": input_tokens or before,
        "local_ai_output_tokens": output_tokens,
        "local_ai_latency_ms": latency,
        "candidate_tokens_before": before,
        "candidate_tokens_after": after,
        "local_ai_net_savings_tokens": max(0, before - after),
    }
