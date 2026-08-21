"""Evidence item construction and deterministic selection."""

import os
import subprocess
import sys

from .config import MAX_ERROR_LINES, MAX_EVIDENCE_ITEMS
from .gather_rank import file_rank
from .gather_scope import _is_under_path, extract_explicit_paths, focus_seed_paths


def build_reason(item, project_type, terms):
    name = item["name"]
    category = item["category"]
    reasons = {
        "manifest": f"Included as a primary project manifest for the detected {project_type} project.",
        "log": "Included because recent logs are often the fastest signal for debugging prompts.",
        "unity": f"Included as Unity serialized/project evidence (`{name}`).",
        "script": f"Included as a likely execution entry point or script candidate (`{name}`).",
        "config": f"Included as a configuration file that may control runtime behavior (`{name}`).",
    }
    if category in reasons:
        return reasons[category]
    for term in terms:
        if term in name.lower():
            return f"Included because its filename matches the prompt term `{term}`."
    return "Included as a likely relevant source file based on project type and recency."


def build_open_source_reason(item, focus_root=None):
    path = str(item.get("path") or "")
    lowered = os.path.basename(path).lower()
    doc_reasons = {
        "package.json": "Included as Unity package metadata for open-source release readiness.",
        "license.md": "Included to verify public license packaging.",
        "license": "Included to verify public license packaging.",
        "changelog.md": "Included to verify public release history and versioning.",
    }
    if lowered in doc_reasons:
        return doc_reasons[lowered]
    if lowered in {"readme.md", "documentation.md", "api_reference.md"}:
        return "Included as public documentation evidence for open-source readiness."
    rel_lower = path.replace("\\", "/").lower()
    if rel_lower.endswith(".asmdef"):
        return "Included to verify Unity assembly/package boundaries."
    if "/tests/" in rel_lower:
        return "Included as package test coverage evidence."
    if "/editor/" in rel_lower or "/runtime/" in rel_lower:
        return "Included as core package implementation evidence."
    return "Included because it is inside the inferred package scope for the open-source review."


def evidence_policy_summary(evidence_items, project_root, project_type):
    from .utils import is_generated_dependency_path, is_project_owned_path

    generated = [
        item.get("path") or ""
        for item in evidence_items
        if is_generated_dependency_path(item.get("path") or "", project_root)
    ]
    owned = [
        item.get("path") or ""
        for item in evidence_items
        if is_project_owned_path(item.get("path") or "", project_root, project_type)
    ]
    warnings = []
    if generated:
        warnings.append("Generated/dependency files selected.")
    if not owned:
        warnings.append("No project-owned source selected.")
    return {
        "generated_dependency_count": len(generated),
        "generated_dependency_paths": generated[:8],
        "project_owned_count": len(owned),
        "project_owned_paths": owned[:8],
        "warnings": warnings,
    }


def evidence_item_from_path(path, category, reason, terms, indexed=None):
    from .parser import excerpt_for_log, excerpt_for_text, read_text_file
    from .symbols import extract_symbols, extract_unity_refs

    text = read_text_file(path)
    preview, start_line, end_line = excerpt_for_log(text, terms) if category == "log" else excerpt_for_text(text, terms)
    return {
        "path": path,
        "kind": category,
        "reason": reason,
        "preview": preview,
        "start_line": start_line,
        "end_line": end_line,
        "symbols": (indexed or {}).get("symbols") or extract_symbols(path, text),
        "unity_refs": (indexed or {}).get("unity_refs") or extract_unity_refs(path, text),
    }


def select_evidence(
    project_root, prompt, project_type, repo_index=None, preflight=None, max_items=None, include_generated=False
):
    context = _selection_context(project_root, prompt, project_type, repo_index, preflight, max_items)
    discovered, indexed_by_path = _selection_candidates(project_root, repo_index)
    _add_changed_candidates(discovered, context)
    _add_focus_seed_candidates(discovered, context)
    scored = sorted(discovered, key=lambda item: file_rank(item, **context["rank_args"]), reverse=True)
    return _select_scored_evidence(scored, indexed_by_path, context, include_generated)


def _selection_context(project_root, prompt, project_type, repo_index, preflight, max_items):
    from .classifier import classify_prompt_intent, expanded_prompt_terms, is_open_source_readiness_prompt, prompt_terms

    terms = expanded_prompt_terms(prompt)
    term_set = set(terms)
    preview_terms = _preview_terms(prompt, terms, term_set, project_type, prompt_terms)
    intent = classify_prompt_intent(prompt)
    collection_plan = (preflight or {}).get("collection_plan") or {}
    packet_mode = (preflight or {}).get("packet_mode") or intent["packet_mode"]
    open_source_review = (
        is_open_source_readiness_prompt(prompt) or collection_plan.get("task_type") == "release_readiness"
    )
    rank_args = {
        "terms": terms,
        "intent": intent,
        "project_type": project_type,
        "packet_mode": packet_mode,
        "changed_paths": set((preflight or {}).get("changed_paths") or []),
        "explicit_paths": set((preflight or {}).get("explicit_paths") or []),
        "error_paths": set((preflight or {}).get("error_paths") or []),
        "project_root": project_root,
        "focus_root": (preflight or {}).get("focus_root"),
        "open_source_review": open_source_review,
        "collection_plan": collection_plan,
    }
    return {
        "project_root": project_root,
        "project_type": project_type,
        "prompt": prompt,
        "terms": terms,
        "preview_terms": preview_terms,
        "packet_mode": packet_mode,
        "collection_plan": collection_plan,
        "open_source_review": open_source_review,
        "limit": max_items or MAX_EVIDENCE_ITEMS,
        "rank_args": rank_args,
    }


def _preview_terms(prompt, terms, term_set, project_type, prompt_terms):
    preview_terms = prompt_terms(prompt)
    android_icon = (
        project_type == "unity"
        and (term_set & {"apk", "android"})
        and (term_set & {"icon", "icons", "launcher", "mipmap", "adaptive"})
    )
    if android_icon:
        return [
            "m_icons",
            "buildtarget: android",
            "android:icon",
            "launcher",
            "mipmap",
            "platformsettings",
            "icon",
            "icons",
            "android",
        ] + preview_terms
    return preview_terms


def _selection_candidates(project_root, repo_index):
    from .discovery import iter_project_files
    from .utils import rel_path

    if not repo_index:
        return iter_project_files(project_root), {}
    discovered = [
        {
            "path": item["path"],
            "relative_path": rel_path(item["path"], project_root),
            "name": os.path.basename(item["path"]),
            "category": item["category"],
            "mtime": item.get("mtime", 0),
            "symbols": item.get("symbols") or [],
            "unity_refs": item.get("unity_refs") or [],
            "search_terms": item.get("search_terms") or [],
        }
        for item in repo_index.get("files", [])
    ]
    return discovered, {item["path"]: item for item in repo_index.get("files", [])}


def _add_changed_candidates(discovered, context):
    for path in context["rank_args"]["changed_paths"]:
        _append_candidate(path, discovered, context)


def _add_focus_seed_candidates(discovered, context):
    if not (context["open_source_review"] and context["rank_args"]["focus_root"]):
        return
    for path in focus_seed_paths(context["rank_args"]["focus_root"]):
        _append_candidate(path, discovered, context)


def _append_candidate(path, discovered, context):
    from .utils import categorize_path, is_noise_path, normalize_path, rel_path

    project_root = context["project_root"]
    path = path if os.path.isabs(path) else os.path.join(project_root, path)
    if not os.path.isfile(path) or is_noise_path(path):
        return
    known_paths = {normalize_path(item["path"]) for item in discovered if item.get("path")}
    normalized = normalize_path(path)
    if normalized in known_paths:
        return
    category = categorize_path(path)
    if not category:
        return
    discovered.append(_discovered_item(normalized, rel_path(normalized, project_root), category))


def _discovered_item(path, relative_path, category):
    try:
        mtime = os.stat(path).st_mtime
    except OSError:
        mtime = 0
    return {
        "path": path,
        "relative_path": relative_path,
        "name": os.path.basename(path),
        "category": category,
        "mtime": mtime,
        "symbols": [],
        "unity_refs": [],
        "search_terms": [],
    }


def _select_scored_evidence(scored, indexed_by_path, context, include_generated):
    from .utils import is_generated_dependency_path

    evidence = []
    seen_paths = set()
    category_counts = {key: 0 for key in _category_limits(context).keys()}
    excluded_markers = [str(item).lower() for item in context["collection_plan"].get("excluded_context") or []]
    for item in scored:
        if _skip_scored_item(
            item,
            context,
            include_generated,
            category_counts,
            seen_paths,
            excluded_markers,
            is_generated_dependency_path,
        ):
            continue
        category_counts[item["category"]] += 1
        seen_paths.add(item["path"])
        evidence.append(_evidence_from_item(item, context, indexed_by_path))
        if len(evidence) >= context["limit"]:
            break
    return evidence


def _category_limits(context):
    wants_log = context["packet_mode"] == "debug" or bool(
        set(context["terms"]) & {"log", "logs", "error", "errors", "traceback", "crash", "exception", "fail", "failure"}
    )
    limits = {
        "manifest": 2,
        "log": 2 if context["packet_mode"] == "debug" else (1 if wants_log else 0),
        "script": 2,
        "source": 6 if context["packet_mode"] in {"debug", "review", "implementation"} else 4,
        "config": 2,
        "unity": 3,
        "notes": 2,
    }
    if context["open_source_review"]:
        limits.update({"manifest": 4, "log": 0, "script": 3, "source": 4, "config": 3, "unity": 2, "notes": 4})
    return limits


def _skip_scored_item(
    item, context, include_generated, category_counts, seen_paths, excluded_markers, is_generated_dependency_path
):
    category_limits = _category_limits(context)
    if (
        not include_generated
        and is_generated_dependency_path(item["path"], context["project_root"])
        and item["path"] not in context["rank_args"]["explicit_paths"]
    ):
        return True
    path_lower = item["path"].replace("\\", "/").lower()
    if "/fixtures/" in path_lower and any(marker in {"fixtures", "fixture projects"} for marker in excluded_markers):
        return True
    category = item["category"]
    return category_counts.get(category, 0) >= category_limits.get(category, 0) or item["path"] in seen_paths


def _evidence_from_item(item, context, indexed_by_path):
    reason = build_reason(item, context["project_type"], context["terms"])
    focus_root = context["rank_args"]["focus_root"]
    if context["open_source_review"] and (not focus_root or _is_under_path(item["path"], focus_root)):
        reason = build_open_source_reason(item, focus_root)
    return evidence_item_from_path(
        item["path"], item["category"], reason, context["preview_terms"], indexed_by_path.get(item["path"])
    )


def gather_external_evidence(prompt, project_root, terms, discovered=None, repo_index=None):
    from .utils import categorize_path

    extras = []
    for path in extract_explicit_paths(prompt, project_root, discovered, repo_index):
        if os.path.isfile(path):
            category = categorize_path(path) or "notes"
            extras.append(
                evidence_item_from_path(
                    path, category, "Included because the prompt explicitly referenced this external path.", terms
                )
            )
    if _is_graphify_update_review_prompt(prompt, terms):
        extras.extend(_graphify_command_evidence(terms))
    return extras


def _is_graphify_update_review_prompt(prompt, terms):
    lowered = (prompt or "").lower()
    term_set = set(terms or [])
    update_terms = {
        "version",
        "versions",
        "changelog",
        "changelogs",
        "latest",
        "update",
        "updates",
        "release",
        "releases",
        "feature",
        "features",
    }
    return ("graphify" in lowered or "граффити" in lowered or "графити" in lowered) and bool(term_set & update_terms)


def _command_evidence_item(command, preview, reason):
    return {
        "path": f"command: {command}",
        "kind": "command",
        "reason": reason,
        "preview": preview.strip()[:1800] or "[No output]",
        "start_line": None,
        "end_line": None,
        "symbols": [],
        "unity_refs": [],
    }


def _run_command(command, timeout=12):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except Exception as exc:
        return f"Command failed before execution: {exc}"
    output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part and part.strip())
    return output or f"[exit {result.returncode}, no output]"


def _graphify_command_evidence(terms):
    evidence = [
        _command_evidence_item(
            "graphify --version",
            _run_command(["graphify", "--version"], timeout=5),
            "Included because Graphify version/update tasks need command evidence, not fixture guesses.",
        ),
        _command_evidence_item(
            f"{sys.executable} -m pip index versions graphifyy",
            "\n".join(
                _run_command([sys.executable, "-m", "pip", "index", "versions", "graphifyy"], timeout=12).splitlines()[
                    :4
                ]
            ),
            "Included to compare the installed Graphify package with the latest package index version.",
        ),
    ]
    if {"changelog", "changelogs", "release", "releases", "feature", "features"} & set(terms or []):
        evidence.append(
            _command_evidence_item(
                "missing: Graphify changelog/release notes",
                "No repo-local Graphify changelog is available inside the selected Soma project. Ask for the upstream Graphify changelog/release notes or browse the official repository before making feature-integration claims.",
                "Included as explicit missing-context guidance for Graphify changelog/release review.",
            )
        )
    return evidence
