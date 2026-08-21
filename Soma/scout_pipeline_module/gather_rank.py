"""Evidence ranking heuristics."""

import os
import re

from .gather_scope import _is_under_path


def file_rank(
    item,
    terms,
    intent,
    project_type,
    packet_mode="debug",
    changed_paths=None,
    explicit_paths=None,
    error_paths=None,
    project_root=None,
    focus_root=None,
    open_source_review=False,
    collection_plan=None,
):
    from .classifier import split_identifier_terms
    from .utils import is_generated_dependency_path, is_project_owned_path, normalize_path

    context = _rank_context(
        item,
        terms,
        intent,
        packet_mode,
        changed_paths,
        explicit_paths,
        error_paths,
        project_root,
        collection_plan,
        split_identifier_terms,
        normalize_path,
    )
    generated_dependency = is_generated_dependency_path(item["path"], project_root)
    project_owned = is_project_owned_path(item["path"], project_root, project_type)
    score = _direct_match_score(context)
    score += _category_score(context, project_type, packet_mode)
    score += _project_type_score(context, project_type, project_owned, generated_dependency)
    score += _term_score(context)
    score += _focus_score(item, focus_root, open_source_review)
    score += _prompt_specific_score(context, project_type, open_source_review)
    score += _plan_required_score(context)
    score += _local_ai_score(context)
    score += _quiet_hours_score(context)
    if (
        generated_dependency
        and context["normalized"] not in context["explicit_paths"]
        and item["path"] not in context["explicit_paths"]
    ):
        score -= 70
    return score + min(int(max(0, item["mtime"]) / 10000000), 15)


def _rank_context(
    item,
    terms,
    intent,
    packet_mode,
    changed_paths,
    explicit_paths,
    error_paths,
    project_root,
    collection_plan,
    split_identifier_terms,
    normalize_path,
):
    rel = item.get("relative_path") or item["path"]
    return {
        "item": item,
        "terms": terms,
        "term_set": set(terms),
        "intent": intent,
        "packet_mode": packet_mode,
        "changed_paths": changed_paths or set(),
        "explicit_paths": explicit_paths or set(),
        "error_paths": error_paths or set(),
        "project_root": project_root,
        "collection_plan": collection_plan or {},
        "lowered_name": item["name"].lower(),
        "lowered_path": item["path"].lower(),
        "rel": rel,
        "rel_lower": rel.lower(),
        "category": item["category"],
        "normalized": normalize_path(item["path"]),
        "symbol_text": " ".join(item.get("symbols") or []).lower(),
        "search_terms": set(item.get("search_terms") or []),
        "name_terms": set(split_identifier_terms(item.get("name", ""))),
    }


def _direct_match_score(ctx):
    item = ctx["item"]
    score = 240 if ctx["normalized"] in ctx["explicit_paths"] or item["path"] in ctx["explicit_paths"] else 0
    if (
        ctx["rel"] in ctx["changed_paths"]
        or item["path"] in ctx["changed_paths"]
        or ctx["normalized"] in ctx["changed_paths"]
    ):
        score += 120 if ctx["packet_mode"] in {"changes", "review", "implementation"} else 50
    if item["path"] in ctx["error_paths"] or ctx["normalized"] in ctx["error_paths"]:
        score += 130 if ctx["packet_mode"] == "debug" else 45
    return score


def _category_score(ctx, project_type, packet_mode):
    category = ctx["category"]
    score = {"manifest": 18 if packet_mode in {"changes", "review"} else 28, "config": 18}.get(category, 0)
    score += 70 if category == "log" and packet_mode == "debug" else (18 if category == "log" else 0)
    score += 35 if category == "notes" and packet_mode in {"debug", "review"} else (16 if category == "notes" else 0)
    score += 60 if category == "unity" and project_type == "unity" else (20 if category == "unity" else 0)
    score += (
        45
        if category == "script" and ("script" in ctx["terms"] or "script" in ctx["intent"]["reason"].lower())
        else (25 if category == "script" else 0)
    )
    score += (
        45
        if category == "source" and packet_mode in {"changes", "review", "implementation"}
        else (25 if category == "source" else 0)
    )
    return score


def _project_type_score(ctx, project_type, project_owned, generated_dependency):
    if project_type == "unity":
        return _unity_score(ctx, project_owned, generated_dependency)
    suffix_scores = {
        "swift": ({"package.swift"}, (".swift",), 36),
        "python": ({"pyproject.toml", "requirements.txt", "setup.py"}, (".py",), 18),
        "javascript": ({"package.json", "pnpm-lock.yaml", "yarn.lock"}, (".js", ".jsx", ".ts", ".tsx"), 18),
        "go": ({"go.mod", "go.sum"}, (".go",), 18),
        "rust": ({"cargo.toml", "cargo.lock"}, (".rs",), 18),
        "cpp": ({"cmakelists.txt", "makefile"}, (".c", ".cc", ".cpp", ".h", ".hpp"), 18),
        "java_kotlin": ({"pom.xml", "build.gradle", "build.gradle.kts"}, (".java", ".kt"), 18),
        "php": ({"composer.json", "composer.lock"}, (".php",), 18),
        "ruby": ({"gemfile", "rakefile"}, (".rb",), 18),
    }
    names, suffixes, suffix_score = suffix_scores.get(project_type, (set(), tuple(), 0))
    score = (
        25
        if ctx["lowered_name"] in names or (project_type == "swift" and ctx["lowered_name"].endswith(".xcodeproj"))
        else 0
    )
    score += suffix_score if ctx["item"]["path"].endswith(suffixes) else 0
    score -= (
        90
        if project_type == "swift" and ctx["category"] == "source" and not ctx["item"]["path"].endswith(".swift")
        else 0
    )
    return score


def _unity_score(ctx, project_owned, generated_dependency):
    score = 55 if project_owned else 0
    if (
        generated_dependency
        and ctx["normalized"] not in ctx["explicit_paths"]
        and ctx["item"]["path"] not in ctx["explicit_paths"]
    ):
        score -= 140
    score += 28 if ctx["item"]["path"].endswith((".cs", ".asmdef", ".unity", ".prefab")) else 0
    score += 65 if ctx["rel_lower"].startswith("assets/") else 0
    score += 58 if ctx["rel_lower"] == "packages/manifest.json" else 0
    score += 48 if ctx["rel_lower"].startswith("projectsettings/") else 0
    return score


def _term_score(ctx):
    score = 0
    for term in ctx["terms"]:
        score += 34 if term in ctx["name_terms"] else (24 if term in ctx["lowered_name"] else 0)
        score += 11 if term in ctx["rel_lower"] or term in ctx["lowered_path"] else 0
        score += 28 if term in ctx["symbol_text"] else 0
        score += 14 if term in ctx["search_terms"] else 0
    if ctx["packet_mode"] in {"debug", "review"} and re.search(r"(^|/)(tests?|fixtures?)(/|$)", ctx["rel_lower"]):
        score += 24
    if ctx["packet_mode"] == "debug" and {"error", "fail", "failure"} & ctx["search_terms"]:
        score += 18
    return score


def _focus_score(item, focus_root, open_source_review):
    if not focus_root:
        return 0
    return 190 if _is_under_path(item["path"], focus_root) else (-700 if open_source_review else 0)


def _prompt_specific_score(ctx, project_type, open_source_review):
    score = _android_icon_score(ctx, project_type)
    if ctx["packet_mode"] == "implementation" and not (ctx["term_set"] & {"test", "tests", "fixture", "fixtures"}):
        score -= 90 if re.search(r"(^|/)(tests?|fixtures?)(/|$)", ctx["rel_lower"]) else 0
    if open_source_review:
        score += _open_source_score(ctx)
    return score


def _android_icon_score(ctx, project_type):
    if project_type != "unity" or not (
        (ctx["term_set"] & {"apk", "android"})
        and (ctx["term_set"] & {"icon", "icons", "launcher", "mipmap", "adaptive"})
    ):
        return 0
    rel_lower = ctx["rel_lower"]
    score = 240 if rel_lower == "projectsettings/projectsettings.asset" else 0
    score += 230 if rel_lower == "assets/plugins/android/androidmanifest.xml" else 0
    score += (
        220
        if rel_lower.startswith("assets/")
        and "icon" in rel_lower
        and rel_lower.endswith((".png.meta", ".png", ".asset", ".meta"))
        else 0
    )
    score += 80 if rel_lower == "projectsettings/androidresolverdependencies.xml" else 0
    return score


def _open_source_score(ctx):
    release_doc_names = {
        "package.json",
        "readme.md",
        "license.md",
        "license",
        "changelog.md",
        "documentation.md",
        "api_reference.md",
    }
    rel_lower = ctx["rel_lower"]
    name = ctx["lowered_name"]
    score = 560 if name in release_doc_names else 0
    score += 140 if name == "package.json" else 0
    score += 130 if rel_lower.endswith(".asmdef") else 0
    score += 80 if re.search(r"(^|/)(tests?|test)(/|$)", rel_lower) else 0
    score += 60 if "/editor/" in rel_lower or "/runtime/" in rel_lower else 0
    score += (
        110
        if name
        in {"mcpserver.cs", "mcpservermethods.cs", "nexus_unity_bridge.py", "schemas.py", "routing.py", "client.py"}
        else 0
    )
    score -= 260 if rel_lower.endswith((".unity", "autosavedscene.unity")) else 0
    score -= (
        240
        if rel_lower.startswith("projectsettings/")
        or name in {"unityconnectsettings.asset", "scenetemplatesettings.json"}
        else 0
    )
    return score


def _plan_required_score(ctx):
    required = set(ctx["collection_plan"].get("required_evidence") or [])
    score = 0
    score += 110 if "logs" in required and ctx["category"] == "log" else 0
    score += 180 if "package_manifest" in required and ctx["lowered_name"] == "package.json" else 0
    score += 180 if "readme" in required and ctx["lowered_name"] == "readme.md" else 0
    score += 180 if "license" in required and ctx["lowered_name"] in {"license", "license.md"} else 0
    score += 160 if "changelog" in required and ctx["lowered_name"] == "changelog.md" else 0
    score += 120 if "tests" in required and re.search(r"(^|/)(tests?|test)(/|$)", ctx["rel_lower"]) else 0
    score += (
        140
        if "core_entrypoints" in required
        and ctx["lowered_name"]
        in {"mcpserver.cs", "mcpservermethods.cs", "nexus_unity_bridge.py", "main.py", "server.py"}
        else 0
    )
    return score


def _local_ai_score(ctx):
    if not ("ollama" in ctx["term_set"] or ("local" in ctx["term_set"] and {"ai", "model"} & ctx["term_set"])):
        return 0
    haystack = " ".join(
        [ctx["lowered_name"], ctx["rel_lower"], ctx["lowered_path"], ctx["symbol_text"], " ".join(ctx["search_terms"])]
    )
    score = 130 if "ollama" in haystack else 0
    score += 90 if "ollama" in haystack and (ctx["term_set"] & {"call", "calling", "points", "conditions"}) else 0
    score += (
        160
        if ctx["term_set"] & {"configurable", "settings", "state", "set", "interval", "time", "application"}
        and ctx["lowered_name"] in {"globalsettingsbar.swift", "somaviewmodel.swift"}
        else 0
    )
    signals = (
        "ismodelloaded",
        "isollamarunning",
        "startmodel",
        "start model",
        "launchollama",
        "launch ollama",
        "ollamaaction",
        "ollama action",
        "sendkeepalive",
        "keep_alive",
    )
    return score + (80 if any(signal in haystack for signal in signals) else 0)


def _quiet_hours_score(ctx):
    if not ("quiet" in ctx["term_set"] and {"hours", "hour", "midnight"} & ctx["term_set"]):
        return 0
    names = {
        "appstate.swift",
        "cooldownpolicy.swift",
        "nudgescheduler.swift",
        "moodlingsettings.swift",
        "settingsview.swift",
        "cooldownpolicytests.swift",
    }
    score = 95 if ctx["lowered_name"] in names else 0
    score += 180 if ctx["rel_lower"].endswith("docs/behavior.md") or ctx["rel_lower"].endswith("behavior.md") else 0
    score += 95 if "quiet_hours" in ctx["rel_lower"] or "quiet-hours" in ctx["rel_lower"] else 0
    score += (
        35
        if any(term in ctx["rel_lower"] for term in ("cooldown", "nudge", "scheduler", "settings", "appstate"))
        else 0
    )
    return score
