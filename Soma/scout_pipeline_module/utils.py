import sys
import json

import os
import re


from pathlib import Path


from .config import *


def fix_path(path, allowed_dirs):
    if path.startswith("/"):
        return path
    for root in allowed_dirs:
        candidate = os.path.join(root, path)
        if os.path.exists(candidate):
            return candidate
    return os.path.join(allowed_dirs[0], path)


def normalize_path(path):
    # Performance: avoid Path instantiation
    return os.path.realpath(os.path.expanduser(path))


def is_noise_path(path):
    if type(path) is str:
        if "__pycache__" in path:
            if "__pycache__" in path.split("/"):
                return True
        name = path.rsplit("/", 1)[(-1)] if ("/" in path) else path
        if name in NOISE_PATH_NAMES:
            return True
        if "." in name:
            suffix = name[name.rfind(".") :].lower()
            if suffix in NOISE_SUFFIXES:
                return True
        return False
    else:
        return (
            (path.name in NOISE_PATH_NAMES) or (path.suffix.lower() in NOISE_SUFFIXES) or ("__pycache__" in path.parts)
        )


def path_parts_for_policy(path, project_root=None):
    try:
        raw = rel_path(path, project_root) if project_root else str(path)
    except Exception:
        raw = str(path)
    return [part for part in raw.replace("\\", "/").split("/") if part]


def is_generated_dependency_path(path, project_root=None):
    parts = path_parts_for_policy(path, project_root)
    rel = "/".join(parts)
    lower_parts = {part.lower() for part in parts}
    lower_rel = rel.lower()
    for marker in GENERATED_DEPENDENCY_PARTS:
        marker_lower = marker.lower()
        if "/" in marker_lower:
            if marker_lower in lower_rel:
                return True
        elif marker_lower in lower_parts:
            return True
    return False


def is_project_owned_path(path, project_root=None, project_type=None):
    parts = path_parts_for_policy(path, project_root)
    if not parts:
        return False
    if project_type == "unity":
        return parts[0] in PROJECT_OWNED_UNITY_PARTS or len(parts) == 1
    return not is_generated_dependency_path(path, project_root)


def rel_path(path, project_root):
    try:
        # Performance: avoid Path instantiation in hot loops
        real_path = os.path.realpath(path)
        real_root = os.path.realpath(project_root)
        if os.path.commonpath([real_path, real_root]) != real_root:
            return str(path)
        return os.path.relpath(real_path, real_root)
    except Exception as exc:
        print(f"rel_path failed: {exc}", file=sys.stderr)
        return str(path)


def dedupe_strings(items):
    return list(dict.fromkeys((item for item in items if item)))


def should_skip_dir(name):
    return (name in SKIP_DIRS) or (name.startswith(".") and (name not in {".config", ".github"}))


def categorize_path(path):
    if type(path) is str:
        name = path.rsplit("/", 1)[(-1)] if ("/" in path) else path
        suffix = name[name.rfind(".") :].lower() if ("." in name) else ""
    else:
        name = path.name
        suffix = path.suffix.lower()
    if (
        (name in MANIFEST_NAMES)
        or (name == "project.pbxproj")
        or name.endswith(".xcodeproj")
        or name.endswith(".xcworkspace")
    ):
        return "manifest"
    if suffix in UNITY_EXTENSIONS:
        return "unity"
    if (suffix in LOG_EXTENSIONS) or name.lower().startswith(("ollama_", "stderr", "stdout")):
        return "log"
    if suffix in NOTE_EXTENSIONS:
        return "notes"
    if (suffix in SOURCE_EXTENSIONS) and (suffix not in {".bat", ".command", ".ps1", ".sh", ".zsh"}):
        return "source"
    if (suffix in SCRIPT_EXTENSIONS) or ((not suffix) and os.access(path, os.X_OK)):
        return "script"
    if suffix in SOURCE_EXTENSIONS:
        return "source"
    if suffix in CONFIG_EXTENSIONS:
        return "config"
    if re.search(r"(^|[_.-])logs?([_.-]|$)", name.lower()):
        return "log"
    return None


def parse_recent_roots(raw_json):
    try:
        decoded = json.loads((raw_json or "[]"))
    except Exception as exc:
        print(f"parse_recent_roots failed: {exc}", file=sys.stderr)
        decoded = []
    roots = []
    for item in decoded:
        if isinstance(item, str) and os.path.isdir(os.path.expanduser(item)):
            roots.append(normalize_path(item))
    return dedupe_strings(roots)
