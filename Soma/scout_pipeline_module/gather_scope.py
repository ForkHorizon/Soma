"""Scope inference and explicit path extraction for evidence gathering."""
import json
import os
import re
from pathlib import Path


def _prompt_reference_fragments(prompt):
    fragments = []
    for match in re.findall(r'`([^`]+)`|"([^"]+)"|\'([^\']+)\'', prompt or ''):
        fragments.extend([part.strip() for part in match if part and part.strip()])
    fragments.extend(re.findall(r'[A-Za-z0-9_./-]+\.[A-Za-z0-9_./-]+', prompt or ''))
    fragments.extend(re.findall(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+', prompt or ''))
    fragments.extend(re.findall(r'\b[A-Z][A-Za-z0-9_]{2,}\b', prompt or ''))
    return list(dict.fromkeys(fragment.strip('.,:)(') for fragment in fragments if fragment.strip('.,:)(')))


def _candidate_items(discovered=None, repo_index=None):
    if repo_index:
        files = repo_index.get('files') or []
        if files:
            return files
    return discovered or []


def extract_explicit_paths(prompt, project_root, discovered=None, repo_index=None):
    from .utils import dedupe_strings, is_noise_path, normalize_path
    project_root = normalize_path(project_root)
    candidates = _absolute_prompt_paths(prompt, is_noise_path, normalize_path)
    candidates.extend(_relative_prompt_paths(prompt, project_root, is_noise_path, normalize_path))
    candidates.extend(_indexed_prompt_paths(prompt, project_root, discovered, repo_index, is_noise_path, normalize_path))
    return dedupe_strings(candidates)


def _absolute_prompt_paths(prompt, is_noise_path, normalize_path):
    candidates = []
    for match in re.findall('(/[A-Za-z0-9._/\\-]+)', prompt or ''):
        path = os.path.expanduser(match.rstrip('.,:)'))
        if os.path.exists(path) and not is_noise_path(path):
            candidates.append(normalize_path(path))
    return candidates


def _relative_prompt_paths(prompt, project_root, is_noise_path, normalize_path):
    candidates = []
    for fragment in _prompt_reference_fragments(prompt):
        if not fragment or fragment.startswith('/') or ('/' not in fragment and '.' not in fragment):
            continue
        path = os.path.join(project_root, fragment)
        if os.path.isfile(path) and not is_noise_path(path):
            candidates.append(normalize_path(path))
    return candidates


def _indexed_prompt_paths(prompt, project_root, discovered, repo_index, is_noise_path, normalize_path):
    fragments = {fragment.lower() for fragment in _prompt_reference_fragments(prompt) if fragment}
    if not fragments:
        return []
    candidates = []
    for item in _candidate_items(discovered, repo_index):
        path = item.get('path')
        if not path:
            continue
        normalized = normalize_path(path)
        if is_noise_path(normalized):
            continue
        if fragments & _item_exact_names(path, normalized, project_root, item):
            candidates.append(normalized)
    return candidates


def _item_exact_names(path, normalized, project_root, item):
    name = os.path.basename(path)
    stem = os.path.splitext(name)[0]
    try:
        rel = os.path.relpath(normalized, project_root)
    except Exception:
        rel = path
    exacts = {name.lower(), stem.lower(), rel.lower(), path.lower()}
    exacts.update(str(symbol).lower() for symbol in item.get('symbols') or [])
    return exacts


def _is_under_path(path, parent):
    if not path or not parent:
        return False
    try:
        path_real = os.path.realpath(path)
        parent_real = os.path.realpath(parent)
        return os.path.commonpath([path_real, parent_real]) == parent_real
    except Exception:
        return False


def _package_json_metadata(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            decoded = json.load(handle)
    except Exception:
        return {}
    return decoded if isinstance(decoded, dict) else {}


def infer_focus_scope(prompt, project_root, project_type, discovered=None, repo_index=None, collection_plan=None):
    if project_type != 'unity':
        return {}
    collection_plan = collection_plan or {}
    if not _wants_package_review(prompt, collection_plan):
        return {}
    from .classifier import prompt_terms, split_identifier_terms
    term_set = set(prompt_terms(prompt))
    hint_terms = _scope_hint_terms(collection_plan, split_identifier_terms)
    wrapper_hint = _wrapper_hint(prompt)
    candidates = _package_candidates(project_root, term_set, hint_terms, wrapper_hint, split_identifier_terms)
    if not candidates:
        return {}
    score, package_root, rel, metadata = max(candidates, key=lambda item: item[0])
    if score < 45:
        return {}
    return _focus_scope_payload(package_root, rel, metadata)


def _wants_package_review(prompt, collection_plan):
    from .classifier import is_open_source_readiness_prompt
    lowered = (prompt or '').lower()
    return (
        is_open_source_readiness_prompt(prompt)
        or ('nexus' in lowered and 'unity' in lowered)
        or collection_plan.get('target_scope') == 'unity_package'
        or collection_plan.get('task_type') == 'release_readiness'
    )


def _scope_hint_terms(collection_plan, split_identifier_terms):
    hints = set()
    for hint in collection_plan.get('scope_hints') or []:
        hints.update(split_identifier_terms(hint))
        hints.add(str(hint).lower())
    return hints


def _wrapper_hint(prompt):
    lowered = (prompt or '').lower()
    markers = ('root is', 'root -', 'wrapper', 'shell', 'test wrapper', 'testing', 'оболочка', 'тестировать', 'тестовый', 'лежит root')
    return any(marker in lowered for marker in markers)


def _package_candidates(project_root, term_set, hint_terms, wrapper_hint, split_identifier_terms):
    from .utils import rel_path
    candidates = []
    for package_json in _package_json_paths(project_root):
        metadata = _package_json_metadata(str(package_json))
        package_root = package_json.parent
        rel = rel_path(str(package_root), project_root)
        score = _score_package_candidate(package_root, rel, metadata, term_set, hint_terms, wrapper_hint, split_identifier_terms)
        candidates.append((score, package_root, rel, metadata))
    return candidates


def _package_json_paths(project_root):
    paths = []
    for relative in ('package.json', 'Assets/*/package.json', 'Packages/*/package.json'):
        paths.extend(path for path in Path(project_root).glob(relative) if path.is_file())
    return paths


def _score_package_candidate(package_root, rel, metadata, term_set, hint_terms, wrapper_hint, split_identifier_terms):
    rel_lower = rel.replace('\\', '/').lower()
    haystack = _package_haystack(package_root, rel_lower, metadata)
    haystack_terms = set(split_identifier_terms(haystack))
    score = sum(18 for term in term_set if term in haystack or term in haystack_terms)
    score += sum(45 for hint in hint_terms if hint and hint in haystack)
    score += 70 if 'nexus' in haystack else 0
    score += 25 if 'unity' in haystack else 0
    score += 30 if 'open source' in haystack or metadata.get('license') else 0
    score += _package_doc_score(package_root)
    score += 40 if rel_lower.startswith(('assets/', 'packages/')) else 0
    score += 120 if wrapper_hint and rel_lower not in {'.', ''} else 0
    score -= 120 if wrapper_hint and rel_lower in {'.', ''} else 0
    return score


def _package_haystack(package_root, rel_lower, metadata):
    fields = [
        rel_lower,
        package_root.name.lower(),
        str(metadata.get('name') or '').lower(),
        str(metadata.get('displayName') or metadata.get('display_name') or '').lower(),
        str(metadata.get('description') or '').lower(),
        ' '.join(str(item).lower() for item in (metadata.get('keywords') or []) if item),
    ]
    return ' '.join(fields)


def _package_doc_score(package_root):
    names = ('README.md', 'README.MD', 'LICENSE.md', 'LICENSE.MD', 'CHANGELOG.md', 'CHANGELOG.MD')
    return sum(18 for doc_name in names if (package_root / doc_name).exists())


def _focus_scope_payload(package_root, rel, metadata):
    display = metadata.get('displayName') or metadata.get('display_name') or metadata.get('name') or package_root.name
    return {
        'focus_root': os.path.realpath(str(package_root)),
        'focus_relative_root': rel,
        'focus_kind': 'unity_package',
        'focus_name': str(display),
        'focus_reason': f"Prompt targets the Unity package `{display}` instead of the wrapper project root.",
    }


def focus_seed_paths(focus_root):
    if not focus_root:
        return []
    root = Path(focus_root)
    seeds = []
    seen = set()
    for path in _seed_path_candidates(root):
        _add_seed(path, seeds, seen)
    return seeds


def _seed_path_candidates(root):
    names = ('package.json', 'README.md', 'README.MD', 'LICENSE.md', 'LICENSE.MD', 'CHANGELOG.md', 'CHANGELOG.MD', 'DOCUMENTATION.MD', 'Documentation.md', 'API_REFERENCE.MD', 'API_REFERENCE.md')
    patterns = ('*.asmdef', 'Editor/*.asmdef', 'Runtime/*.asmdef', 'Editor/MCPServer.cs', 'Editor/MCPServerMethods.cs', 'Editor/nexus_unity_bridge.py', 'Editor/nexus_bridge/*.py', 'Editor/Tests/*.cs', 'Runtime/*.cs')
    for name in names:
        yield root / name
    for pattern in patterns:
        yield from root.glob(pattern)


def _add_seed(path, seeds, seen):
    try:
        key = os.path.realpath(str(path)).lower()
    except Exception:
        key = str(path).lower()
    if key in seen or not path.is_file():
        return
    seen.add(key)
    seeds.append(str(path))
