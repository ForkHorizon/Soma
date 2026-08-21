"""Local collection planning for evidence gathering.

The planner is advisory: it may guide scope and evidence requirements, but
all paths are validated by deterministic collectors before any evidence is read.
"""

import json
import os
import time
from pathlib import Path

from .config import *


TASK_TYPES = {"debug", "implementation", "review", "release_readiness", "architecture_audit", "changes", "direct"}
TARGET_SCOPES = {"whole_project", "unity_package", "app_module", "file_area", "unknown"}
PACKET_STYLES = {"debug_packet", "implementation_packet", "readiness_review_packet", "review_packet", "changes_packet"}


def _string_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item) for item in value if str(item).strip()]
    if isinstance(value, str):
        return [value] if value.strip() else []
    return [str(value)]


def _safe_float(value, default=0.0):
    try:
        return float(value)
    except Exception:
        return default


def _compact_package_metadata(path):
    try:
        decoded = json.loads(Path(path).read_text(encoding="utf-8", errors="replace"))
    except Exception:
        decoded = {}
    if not isinstance(decoded, dict):
        decoded = {}
    return {
        "path": path,
        "root": str(Path(path).parent),
        "name": decoded.get("name"),
        "displayName": decoded.get("displayName") or decoded.get("display_name"),
        "description": decoded.get("description"),
        "version": decoded.get("version"),
        "license": decoded.get("license"),
        "keywords": decoded.get("keywords") if isinstance(decoded.get("keywords"), list) else [],
    }


def _is_interesting_doc_name(name):
    return name.lower() in {
        "readme.md",
        "readme.mD".lower(),
        "license",
        "license.md",
        "license.mD".lower(),
        "changelog.md",
        "documentation.md",
        "documentation.mD".lower(),
        "api_reference.md",
        "api_reference.mD".lower(),
    }


def build_project_map(project_root, project_type, discovered=None, repo_index=None, max_paths=80):
    from .utils import rel_path, is_generated_dependency_path

    root = Path(project_root)
    top_level = []
    try:
        for entry in sorted(root.iterdir(), key=lambda item: item.name.lower())[:80]:
            top_level.append({"name": entry.name, "kind": "dir" if entry.is_dir() else "file"})
    except Exception:
        pass

    package_manifests = []
    for pattern in ("package.json", "Assets/*/package.json", "Packages/*/package.json"):
        for path in root.glob(pattern):
            if path.is_file():
                package_manifests.append(_compact_package_metadata(str(path)))

    files = (repo_index or {}).get("files") or discovered or []
    docs = []
    manifests = []
    candidate_paths = []
    for item in files:
        path = item.get("path") if isinstance(item, dict) else None
        if not path or is_generated_dependency_path(path, project_root):
            continue
        name = os.path.basename(path)
        relative = rel_path(path, project_root)
        if _is_interesting_doc_name(name):
            docs.append(relative)
        if name in MANIFEST_NAMES or name.endswith(".asmdef"):
            manifests.append(relative)
        if len(candidate_paths) < max_paths:
            candidate_paths.append(relative)

    return {
        "project_type": project_type,
        "top_level": top_level[:60],
        "package_manifests": package_manifests[:12],
        "docs": docs[:30],
        "manifests": manifests[:40],
        "candidate_paths": candidate_paths[:max_paths],
    }


def deterministic_collection_plan(prompt, project_root, project_type, project_map=None):
    from .classifier import classify_prompt_intent, is_open_source_readiness_prompt, prompt_terms

    lowered = (prompt or "").lower()
    terms = set(prompt_terms(prompt))
    intent = classify_prompt_intent(prompt)
    task_type = intent.get("packet_mode") or "review"
    target_scope = "whole_project"
    required = []
    excluded = ["generated files", "dependency caches"]
    style = "review_packet"
    warnings = []
    scope_hints = []

    graphify_update_review = ("graphify" in lowered or "граффити" in lowered or "графити" in lowered) and (
        terms
        & {
            "version",
            "versions",
            "changelog",
            "changelogs",
            "release",
            "releases",
            "latest",
            "update",
            "updates",
            "features",
            "feature",
        }
        or any(marker in lowered for marker in ("version", "changelog", "release", "latest", "update", "feature"))
    )

    if graphify_update_review:
        task_type = "review"
        required = ["graphify_integration", "graphify_version", "changelog"]
        excluded.extend(["fixtures", "fixture projects", "generated graph output"])
        style = "review_packet"
        warnings.append(
            "Graphify update/version review needs command or changelog evidence; request it if local files are insufficient."
        )
    elif is_open_source_readiness_prompt(prompt):
        task_type = "release_readiness"
        target_scope = "unity_package" if project_type == "unity" else "whole_project"
        required = ["package_manifest", "readme", "license", "changelog", "docs", "tests", "core_entrypoints"]
        excluded.extend(["wrapper scenes", "Unity Library cache", "Temp"])
        style = "readiness_review_packet"
    elif intent.get("packet_mode") == "debug" or terms & {
        "error",
        "errors",
        "log",
        "logs",
        "traceback",
        "crash",
        "broken",
    }:
        task_type = "debug"
        required = ["logs", "errors", "related_source", "config"]
        style = "debug_packet"
    elif intent.get("packet_mode") == "implementation":
        task_type = "implementation"
        required = ["runtime_state", "settings_ui", "call_sites", "tests"]
        style = "implementation_packet"
    elif intent.get("packet_mode") == "changes":
        task_type = "changes"
        required = ["changed_files", "diff_summary"]
        style = "changes_packet"

    if project_map:
        for package in project_map.get("package_manifests") or []:
            haystack = " ".join(
                str(package.get(key) or "") for key in ("root", "name", "displayName", "description")
            ).lower()
            if any(term in haystack for term in terms):
                scope_hints.extend([package.get("root"), package.get("displayName"), package.get("name")])
        if target_scope == "unity_package" and not scope_hints and (project_map.get("package_manifests") or []):
            package = (project_map.get("package_manifests") or [])[0]
            scope_hints.extend([package.get("root"), package.get("displayName"), package.get("name")])

    plan = {
        "task_type": task_type if task_type in TASK_TYPES else "review",
        "target_scope": target_scope,
        "scope_hints": list(dict.fromkeys(item for item in scope_hints if item)),
        "required_evidence": list(dict.fromkeys(required)),
        "excluded_context": list(dict.fromkeys(excluded)),
        "expected_packet_style": style if style in PACKET_STYLES else "review_packet",
        "confidence": max(0.35, intent.get("confidence") or 0.5),
        "warnings": warnings,
    }
    return plan


def normalize_collection_plan(raw_plan, fallback_plan=None):
    fallback_plan = fallback_plan or {}
    if not isinstance(raw_plan, dict):
        raw_plan = {}
    task_type = str(raw_plan.get("task_type") or fallback_plan.get("task_type") or "review")
    target_scope = str(raw_plan.get("target_scope") or fallback_plan.get("target_scope") or "unknown")
    expected_style = str(
        raw_plan.get("expected_packet_style") or fallback_plan.get("expected_packet_style") or "review_packet"
    )
    plan = {
        "task_type": task_type if task_type in TASK_TYPES else fallback_plan.get("task_type", "review"),
        "target_scope": target_scope if target_scope in TARGET_SCOPES else fallback_plan.get("target_scope", "unknown"),
        "scope_hints": _string_list(raw_plan.get("scope_hints")) or _string_list(fallback_plan.get("scope_hints")),
        "required_evidence": _string_list(raw_plan.get("required_evidence"))
        or _string_list(fallback_plan.get("required_evidence")),
        "excluded_context": _string_list(raw_plan.get("excluded_context"))
        or _string_list(fallback_plan.get("excluded_context")),
        "expected_packet_style": expected_style
        if expected_style in PACKET_STYLES
        else fallback_plan.get("expected_packet_style", "review_packet"),
        "confidence": max(0.0, min(1.0, _safe_float(raw_plan.get("confidence"), fallback_plan.get("confidence", 0.5)))),
        "warnings": _string_list(raw_plan.get("warnings")) + _string_list(fallback_plan.get("warnings")),
    }
    plan["scope_hints"] = list(dict.fromkeys(plan["scope_hints"]))[:8]
    plan["required_evidence"] = list(dict.fromkeys(plan["required_evidence"]))[:12]
    plan["excluded_context"] = list(dict.fromkeys(plan["excluded_context"]))[:12]
    plan["warnings"] = list(dict.fromkeys(plan["warnings"]))[:8]
    return plan


async def plan_collection_with_local_model(
    prompt, project_root, project_type, discovered=None, repo_index=None, planning_mode="auto"
):
    from .llama import query_ollama_model
    from .parser import extract_json_object
    from .ranker import _estimate_stage_tokens

    project_map = build_project_map(project_root, project_type, discovered, repo_index)
    fallback = deterministic_collection_plan(prompt, project_root, project_type, project_map)
    if planning_mode == "off":
        return (
            fallback,
            {
                "stage": "collection_plan",
                "status": "skipped",
                "source": "deterministic_fallback",
                "notes": ["planning-mode off"],
            },
            "deterministic_fallback",
            fallback.get("warnings", []),
        )

    payload = {
        "prompt": prompt,
        "project_root": project_root,
        "project_type": project_type,
        "project_map": project_map,
        "allowed_task_types": sorted(TASK_TYPES),
        "allowed_target_scopes": sorted(TARGET_SCOPES),
    }
    system = (
        "Plan local evidence collection. Return JSON only with: "
        '{"task_type":"debug|implementation|review|release_readiness|architecture_audit|changes|direct",'
        '"target_scope":"whole_project|unity_package|app_module|file_area|unknown",'
        '"scope_hints":["..."],"required_evidence":["..."],"excluded_context":["..."],'
        '"expected_packet_style":"debug_packet|implementation_packet|readiness_review_packet|review_packet|changes_packet",'
        '"confidence":0.0,"warnings":["..."]}. '
        "Do not invent files. Prefer package roots over wrapper Unity projects when the prompt says root is only a test shell."
    )
    start = time.monotonic()
    user_payload = json.dumps(payload)
    response = await query_ollama_model(
        RANKER_MODEL,
        [{"role": "system", "content": system}, {"role": "user", "content": user_payload}],
        timeout=25,
        num_predict=260,
        json_mode=True,
        stage="collection_plan",
        metadata={"project_map_paths": len(project_map.get("candidate_paths") or [])},
    )
    base_stage = {
        "stage": "collection_plan",
        "model": RANKER_MODEL,
        "candidate_tokens_before": _estimate_stage_tokens(user_payload),
        "duration_ms": (time.monotonic() - start) * 1000,
    }
    if "error" in response:
        warnings = [f"Local collection planner unavailable: {response['error']}"]
        plan = normalize_collection_plan(fallback, fallback)
        plan["warnings"] = list(dict.fromkeys(plan.get("warnings", []) + warnings))
        return (
            plan,
            {
                **base_stage,
                "status": "failed",
                "source": "deterministic_fallback",
                "error": response["error"],
                "notes": warnings,
            },
            "deterministic_fallback",
            warnings,
        )

    decoded = extract_json_object(response.get("message", {}).get("content", ""))
    if not isinstance(decoded, dict):
        warnings = ["Local collection planner returned invalid JSON; using deterministic fallback."]
        plan = normalize_collection_plan(fallback, fallback)
        plan["warnings"] = list(dict.fromkeys(plan.get("warnings", []) + warnings))
        return (
            plan,
            {
                **base_stage,
                "status": "failed",
                "source": "deterministic_fallback",
                "error": "invalid planner JSON",
                "notes": warnings,
            },
            "deterministic_fallback",
            warnings,
        )

    plan = normalize_collection_plan(decoded, fallback)
    if plan.get("confidence", 0) < 0.35:
        warnings = ["Local collection planner confidence was low; using deterministic fallback."]
        plan = normalize_collection_plan(fallback, fallback)
        plan["warnings"] = list(dict.fromkeys(plan.get("warnings", []) + warnings))
        return (
            plan,
            {**base_stage, "status": "degraded", "source": "deterministic_fallback", "notes": warnings},
            "deterministic_fallback",
            warnings,
        )

    return (
        plan,
        {**base_stage, "status": "ok", "source": "local_model", "notes": plan.get("warnings", [])[:4]},
        "local_model",
        plan.get("warnings", []),
    )


def plan_packet_mode(collection_plan, fallback_mode):
    task_type = (collection_plan or {}).get("task_type")
    if task_type == "debug":
        return "debug"
    if task_type == "implementation":
        return "implementation"
    if task_type == "changes":
        return "changes"
    if task_type in {"release_readiness", "architecture_audit", "review"}:
        return "review"
    if task_type == "direct":
        return "direct"
    return fallback_mode


def evidence_referee_payload(prompt, collection_plan, evidence_items, evidence_quality):
    return {
        "prompt": prompt,
        "collection_plan": collection_plan or {},
        "evidence_quality": evidence_quality or {},
        "evidence": [
            {
                "id": index,
                "path": item.get("path"),
                "kind": item.get("kind"),
                "reason": item.get("reason"),
                "symbols": (item.get("symbols") or [])[:10],
            }
            for index, item in enumerate(evidence_items or [])
        ],
    }


async def referee_evidence_with_plan_model(prompt, collection_plan, evidence_items, evidence_quality):
    from .llama import query_ollama_model
    from .parser import extract_json_object
    from .ranker import _estimate_stage_tokens

    payload = evidence_referee_payload(prompt, collection_plan, evidence_items, evidence_quality)
    user_payload = json.dumps(payload)
    start = time.monotonic()
    response = await query_ollama_model(
        RANKER_MODEL,
        [
            {
                "role": "system",
                "content": (
                    "Review whether selected local evidence satisfies the collection plan. "
                    'Return JSON only: {"status":"ok|degraded","missing_evidence":["..."],'
                    '"bad_evidence":["..."],"recommended_additions":["..."],"warnings":["..."]}. '
                    "Recommend evidence kinds or concrete repo-relative paths only. Do not invent facts."
                ),
            },
            {"role": "user", "content": user_payload},
        ],
        timeout=25,
        num_predict=220,
        json_mode=True,
        stage="evidence_referee",
        metadata={"candidate_count_after": len(evidence_items or [])},
    )
    stage = {
        "stage": "evidence_referee",
        "model": RANKER_MODEL,
        "candidate_count_after": len(evidence_items or []),
        "candidate_tokens_before": _estimate_stage_tokens(user_payload),
        "duration_ms": (time.monotonic() - start) * 1000,
    }
    if "error" in response:
        return {}, {**stage, "status": "failed", "error": response["error"]}
    decoded = extract_json_object(response.get("message", {}).get("content", ""))
    if not isinstance(decoded, dict):
        return {}, {**stage, "status": "failed", "error": "invalid evidence_referee JSON"}
    result = {
        "status": str(decoded.get("status") or "ok"),
        "missing_evidence": _string_list(decoded.get("missing_evidence")),
        "bad_evidence": _string_list(decoded.get("bad_evidence")),
        "recommended_additions": _string_list(decoded.get("recommended_additions")),
        "warnings": _string_list(decoded.get("warnings")),
    }
    return result, {
        **stage,
        "status": "ok",
        "referee_status": result["status"],
        "notes": (result["warnings"] + result["missing_evidence"])[:4],
    }
