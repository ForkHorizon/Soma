



import json

import os





from pathlib import Path




from .config import *


def fix_path(path, allowed_dirs):
    if path.startswith('/'):
        return path
    for root in allowed_dirs:
        candidate = os.path.join(root, path)
        if os.path.exists(candidate):
            return candidate
    return os.path.join(allowed_dirs[0], path)


def normalize_path(path):
    return str(Path(path).expanduser().resolve())


def is_noise_path(path):
    if (type(path) is str):
        if ('__pycache__' in path):
            if ('__pycache__' in path.split('/')):
                return True
        name = (path.rsplit('/', 1)[(- 1)] if ('/' in path) else path)
        if (name in NOISE_PATH_NAMES):
            return True
        if ('.' in name):
            suffix = name[name.rfind('.'):].lower()
            if (suffix in NOISE_SUFFIXES):
                return True
        return False
    else:
        return ((path.name in NOISE_PATH_NAMES) or (path.suffix.lower() in NOISE_SUFFIXES) or ('__pycache__' in path.parts))


def rel_path(path, project_root):
    try:
        return str(Path(path).resolve().relative_to(Path(project_root).resolve()))
    except Exception:
        return str(path)


def dedupe_strings(items):
    return list(dict.fromkeys((item for item in items if item)))


def should_skip_dir(name):
    return ((name in SKIP_DIRS) or (name.startswith('.') and (name not in {'.config', '.github'})))


def categorize_path(path):
    if (type(path) is str):
        name = (path.rsplit('/', 1)[(- 1)] if ('/' in path) else path)
        suffix = (name[name.rfind('.'):].lower() if ('.' in name) else '')
    else:
        name = path.name
        suffix = path.suffix.lower()
    if ((name in MANIFEST_NAMES) or (name == 'project.pbxproj') or name.endswith('.xcodeproj') or name.endswith('.xcworkspace')):
        return 'manifest'
    if (suffix in UNITY_EXTENSIONS):
        return 'unity'
    if ((suffix in LOG_EXTENSIONS) or ('log' in name.lower()) or name.lower().startswith(('ollama_', 'stderr', 'stdout'))):
        return 'log'
    if ((suffix in SCRIPT_EXTENSIONS) or ((not suffix) and os.access(path, os.X_OK))):
        return 'script'
    if (suffix in SOURCE_EXTENSIONS):
        return 'source'
    if (suffix in CONFIG_EXTENSIONS):
        return 'config'
    return None


def parse_recent_roots(raw_json):
    try:
        decoded = json.loads((raw_json or '[]'))
    except Exception:
        decoded = []
    roots = []
    for item in decoded:
        if (isinstance(item, str) and os.path.isdir(os.path.expanduser(item))):
            roots.append(normalize_path(item))
    return dedupe_strings(roots)
