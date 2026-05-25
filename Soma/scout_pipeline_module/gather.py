


"""Evidence selection and preflight scoring.

This stage ranks discovered files for a user goal, prioritizing changed files,
logs, manifests, configs, and source excerpts according to packet mode.
"""
import os

import re




from pathlib import Path




from .config import *


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
    from .utils import dedupe_strings, normalize_path, is_noise_path
    project_root = normalize_path(project_root)
    candidates = []
    for match in re.findall('(/[A-Za-z0-9._/\\-]+)', prompt):
        path = os.path.expanduser(match.rstrip('.,:)'))
        if (not os.path.exists(path)):
            continue
        normalized = normalize_path(path)
        if is_noise_path(normalized):
            continue
        candidates.append(normalized)

    fragments = _prompt_reference_fragments(prompt)
    for fragment in fragments:
        if not fragment or fragment.startswith('/'):
            continue
        if ('/' in fragment) or ('.' in fragment):
            path = os.path.join(project_root, fragment)
            if os.path.isfile(path):
                normalized = normalize_path(path)
                if not is_noise_path(normalized):
                    candidates.append(normalized)

    lowered_fragments = {fragment.lower() for fragment in fragments if fragment}
    if lowered_fragments:
        for item in _candidate_items(discovered, repo_index):
            path = item.get('path')
            if not path:
                continue
            normalized = normalize_path(path)
            if is_noise_path(normalized):
                continue
            name = os.path.basename(path)
            stem = os.path.splitext(name)[0]
            try:
                rel = os.path.relpath(normalized, project_root)
            except Exception:
                rel = path
            symbols = item.get('symbols') or []
            exacts = {name.lower(), stem.lower(), rel.lower(), path.lower()}
            exacts.update(str(symbol).lower() for symbol in symbols)
            if lowered_fragments & exacts:
                candidates.append(normalized)
    return dedupe_strings(candidates)


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
    import json
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            decoded = json.load(handle)
    except Exception:
        return {}
    return decoded if isinstance(decoded, dict) else {}


def infer_focus_scope(prompt, project_root, project_type, discovered=None, repo_index=None, collection_plan=None):
    from .classifier import is_open_source_readiness_prompt, prompt_terms, split_identifier_terms
    from .utils import rel_path
    if project_type != 'unity':
        return {}
    lowered = (prompt or '').lower()
    collection_plan = collection_plan or {}
    wants_package_review = (
        is_open_source_readiness_prompt(prompt)
        or ('nexus' in lowered and 'unity' in lowered)
        or collection_plan.get('target_scope') == 'unity_package'
        or collection_plan.get('task_type') == 'release_readiness'
    )
    if not wants_package_review:
        return {}

    term_set = set(prompt_terms(prompt))
    hint_terms = set()
    for hint in collection_plan.get('scope_hints') or []:
        hint_terms.update(split_identifier_terms(hint))
        hint_terms.add(str(hint).lower())
    wrapper_hint = any(marker in lowered for marker in (
        'root is', 'root -', 'wrapper', 'shell', 'test wrapper', 'testing',
        'оболочка', 'тестировать', 'тестовый', 'лежит root',
    ))
    package_paths = []
    for relative in ('package.json', 'Assets/*/package.json', 'Packages/*/package.json'):
        package_paths.extend(Path(project_root).glob(relative))

    candidates = []
    for package_json in package_paths:
        if not package_json.is_file():
            continue
        package_root = package_json.parent
        metadata = _package_json_metadata(str(package_json))
        rel = rel_path(str(package_root), project_root)
        rel_lower = rel.replace('\\', '/').lower()
        haystack = ' '.join([
            rel_lower,
            package_root.name.lower(),
            str(metadata.get('name') or '').lower(),
            str(metadata.get('displayName') or metadata.get('display_name') or '').lower(),
            str(metadata.get('description') or '').lower(),
            ' '.join(str(item).lower() for item in (metadata.get('keywords') or []) if item),
        ])
        score = 0
        for term in term_set:
            if term in haystack or term in set(split_identifier_terms(haystack)):
                score += 18
        for hint in hint_terms:
            if hint and hint in haystack:
                score += 45
        if 'nexus' in haystack:
            score += 70
        if 'unity' in haystack:
            score += 25
        if 'open source' in haystack or metadata.get('license'):
            score += 30
        for doc_name in ('README.md', 'README.MD', 'LICENSE.md', 'LICENSE.MD', 'CHANGELOG.md', 'CHANGELOG.MD'):
            if (package_root / doc_name).exists():
                score += 18
        if rel_lower.startswith('assets/') or rel_lower.startswith('packages/'):
            score += 40
        if wrapper_hint and rel_lower not in {'.', ''}:
            score += 120
        if wrapper_hint and rel_lower in {'.', ''}:
            score -= 120
        candidates.append((score, package_root, rel, metadata))

    if not candidates:
        return {}
    (score, package_root, rel, metadata) = max(candidates, key=lambda item: item[0])
    if score < 45:
        return {}
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
    def add_seed(path):
        try:
            key = os.path.realpath(str(path)).lower()
        except Exception:
            key = str(path).lower()
        if key in seen or not path.is_file():
            return
        seen.add(key)
        seeds.append(str(path))
    for name in (
        'package.json',
        'README.md',
        'README.MD',
        'LICENSE.md',
        'LICENSE.MD',
        'CHANGELOG.md',
        'CHANGELOG.MD',
        'DOCUMENTATION.MD',
        'Documentation.md',
        'API_REFERENCE.MD',
        'API_REFERENCE.md',
    ):
        path = root / name
        add_seed(path)
    for pattern in (
        '*.asmdef',
        'Editor/*.asmdef',
        'Runtime/*.asmdef',
        'Editor/MCPServer.cs',
        'Editor/MCPServerMethods.cs',
        'Editor/nexus_unity_bridge.py',
        'Editor/nexus_bridge/*.py',
        'Editor/Tests/*.cs',
        'Runtime/*.cs',
    ):
        for path in root.glob(pattern):
            add_seed(path)
    return seeds


def file_rank(item, terms, intent, project_type, packet_mode='debug', changed_paths=None, explicit_paths=None, error_paths=None, project_root=None, focus_root=None, open_source_review=False, collection_plan=None):
    from .utils import normalize_path, is_generated_dependency_path, is_project_owned_path
    from .classifier import split_identifier_terms
    score = 0
    changed_paths = (changed_paths or set())
    explicit_paths = (explicit_paths or set())
    error_paths = (error_paths or set())
    lowered_name = item['name'].lower()
    lowered_path = item['path'].lower()
    category = item['category']
    normalized = normalize_path(item['path'])
    rel = (item.get('relative_path') or item['path'])
    rel_lower = rel.lower()
    symbol_text = ' '.join((item.get('symbols') or [])).lower()
    search_terms = set((item.get('search_terms') or []))
    name_terms = set(split_identifier_terms(item.get('name', '')))
    if ((normalized in explicit_paths) or (item['path'] in explicit_paths)):
        score += 240
    generated_dependency = is_generated_dependency_path(item['path'], project_root)
    project_owned = is_project_owned_path(item['path'], project_root, project_type)
    if ((rel in changed_paths) or (item['path'] in changed_paths) or (normalized in changed_paths)):
        score += (120 if (packet_mode in {'changes', 'review', 'implementation'}) else 50)
    if ((item['path'] in error_paths) or (normalized in error_paths)):
        score += (130 if (packet_mode == 'debug') else 45)
    if (category == 'manifest'):
        score += (18 if (packet_mode in {'changes', 'review'}) else 28)
    if (category == 'log'):
        score += (70 if (packet_mode == 'debug') else 18)
    if (category == 'notes'):
        score += (35 if (packet_mode in {'debug', 'review'}) else 16)
    if (category == 'unity'):
        score += (60 if (project_type == 'unity') else 20)
    if (category == 'script'):
        score += (45 if (('script' in terms) or ('script' in intent['reason'].lower())) else 25)
    if (category == 'source'):
        score += (45 if (packet_mode in {'changes', 'review', 'implementation'}) else 25)
    if (category == 'config'):
        score += 18
    if (project_type == 'unity'):
        if project_owned:
            score += 55
        if generated_dependency and normalized not in explicit_paths and item['path'] not in explicit_paths:
            score -= 140
        if item['path'].endswith(('.cs', '.asmdef', '.unity', '.prefab')):
            score += 28
        if rel_lower.startswith('assets/'):
            score += 65
        elif rel_lower == 'packages/manifest.json':
            score += 58
        elif rel_lower.startswith('projectsettings/'):
            score += 48
    elif (project_type == 'swift'):
        if ((lowered_name == 'package.swift') or lowered_name.endswith('.xcodeproj')):
            score += 25
        if item['path'].endswith('.swift'):
            score += 36
        elif category == 'source':
            score -= 90
    elif (project_type == 'python'):
        if (lowered_name in {'pyproject.toml', 'requirements.txt', 'setup.py'}):
            score += 25
        if item['path'].endswith('.py'):
            score += 18
    elif (project_type == 'javascript'):
        if (lowered_name in {'package.json', 'pnpm-lock.yaml', 'yarn.lock'}):
            score += 25
        if item['path'].endswith(('.js', '.jsx', '.ts', '.tsx')):
            score += 18
    elif (project_type == 'go'):
        if lowered_name in {'go.mod', 'go.sum'}:
            score += 25
        if item['path'].endswith('.go'):
            score += 18
    elif (project_type == 'rust'):
        if lowered_name in {'cargo.toml', 'cargo.lock'}:
            score += 25
        if item['path'].endswith('.rs'):
            score += 18
    elif (project_type == 'cpp'):
        if lowered_name in {'cmakelists.txt', 'makefile'}:
            score += 25
        if item['path'].endswith(('.c', '.cc', '.cpp', '.h', '.hpp')):
            score += 18
    elif (project_type == 'java_kotlin'):
        if lowered_name in {'pom.xml', 'build.gradle', 'build.gradle.kts'}:
            score += 25
        if item['path'].endswith(('.java', '.kt')):
            score += 18
    elif (project_type == 'php'):
        if lowered_name in {'composer.json', 'composer.lock'}:
            score += 25
        if item['path'].endswith('.php'):
            score += 18
    elif (project_type == 'ruby'):
        if lowered_name in {'gemfile', 'rakefile'}:
            score += 25
        if item['path'].endswith('.rb'):
            score += 18
    for term in terms:
        if (term in name_terms):
            score += 34
        elif (term in lowered_name):
            score += 24
        elif ((term in rel_lower) or (term in lowered_path)):
            score += 11
        if (term in symbol_text):
            score += 28
        if (term in search_terms):
            score += 14
    if packet_mode in {'debug', 'review'} and re.search(r'(^|/)(tests?|fixtures?)(/|$)', rel_lower):
        score += 24
    if packet_mode == 'debug' and ('error' in search_terms or 'fail' in search_terms or 'failure' in search_terms):
        score += 18
    term_set = set(terms)
    plan_required = set((collection_plan or {}).get('required_evidence') or [])
    in_focus = _is_under_path(item['path'], focus_root)
    if focus_root:
        if in_focus:
            score += 190
        elif open_source_review:
            score -= 700
    android_icon_prompt = (term_set & {'apk', 'android'}) and (term_set & {'icon', 'icons', 'launcher', 'mipmap', 'adaptive'})
    if project_type == 'unity' and android_icon_prompt:
        if rel_lower == 'projectsettings/projectsettings.asset':
            score += 240
        if rel_lower == 'assets/plugins/android/androidmanifest.xml':
            score += 230
        if rel_lower.startswith('assets/') and ('icon' in rel_lower) and rel_lower.endswith(('.png.meta', '.png', '.asset', '.meta')):
            score += 220
        if rel_lower == 'projectsettings/androidresolverdependencies.xml':
            score += 80
    if packet_mode == 'implementation' and not (term_set & {'test', 'tests', 'fixture', 'fixtures'}) and re.search(r'(^|/)(tests?|fixtures?)(/|$)', rel_lower):
        score -= 90
    if ('ollama' in term_set) or ('local' in term_set and (('ai' in term_set) or ('model' in term_set))):
        local_ai_haystack = ' '.join([
            lowered_name,
            rel_lower,
            lowered_path,
            symbol_text,
            ' '.join(search_terms),
        ])
        if 'ollama' in local_ai_haystack:
            score += 130
            if term_set & {'call', 'calling', 'points', 'conditions'}:
                score += 90
        if term_set & {'configurable', 'settings', 'state', 'set', 'interval', 'time', 'application'}:
            if lowered_name in {'globalsettingsbar.swift', 'somaviewmodel.swift'}:
                score += 160
        if any(signal in local_ai_haystack for signal in ('ismodelloaded', 'isollamarunning', 'startmodel', 'start model', 'launchollama', 'launch ollama', 'ollamaaction', 'ollama action', 'sendkeepalive', 'keep_alive')):
            score += 80
    if 'logs' in plan_required and category == 'log':
        score += 110
    if 'package_manifest' in plan_required and lowered_name == 'package.json':
        score += 180
    if 'readme' in plan_required and lowered_name == 'readme.md':
        score += 180
    if 'license' in plan_required and lowered_name in {'license', 'license.md'}:
        score += 180
    if 'changelog' in plan_required and lowered_name == 'changelog.md':
        score += 160
    if 'tests' in plan_required and re.search(r'(^|/)(tests?|test)(/|$)', rel_lower):
        score += 120
    if 'core_entrypoints' in plan_required and lowered_name in {'mcpserver.cs', 'mcpservermethods.cs', 'nexus_unity_bridge.py', 'main.py', 'server.py'}:
        score += 140
    if open_source_review:
        release_doc_names = {
            'package.json', 'readme.md', 'readme.mD'.lower(), 'license.md',
            'license', 'changelog.md', 'documentation.md', 'documentation.mD'.lower(),
            'api_reference.md', 'api_reference.mD'.lower(),
        }
        if lowered_name in release_doc_names:
            score += 560
        if lowered_name == 'package.json':
            score += 140
        if rel_lower.endswith('.asmdef'):
            score += 130
        if re.search(r'(^|/)(tests?|test)(/|$)', rel_lower):
            score += 80
        if '/editor/' in rel_lower or '/runtime/' in rel_lower:
            score += 60
        if lowered_name in {'mcpserver.cs', 'mcpservermethods.cs', 'nexus_unity_bridge.py', 'schemas.py', 'routing.py', 'client.py'}:
            score += 110
        if rel_lower.endswith(('.unity', 'autosavedscene.unity')):
            score -= 260
        if rel_lower.startswith('projectsettings/') or lowered_name in {'unityconnectsettings.asset', 'scenetemplatesettings.json'}:
            score -= 240
    if 'quiet' in term_set and (('hours' in term_set) or ('hour' in term_set) or ('midnight' in term_set)):
        quiet_chain_names = {
            'appstate.swift',
            'cooldownpolicy.swift',
            'nudgescheduler.swift',
            'moodlingsettings.swift',
            'settingsview.swift',
            'cooldownpolicytests.swift',
        }
        if lowered_name in quiet_chain_names:
            score += 95
        if rel_lower.endswith('docs/behavior.md') or rel_lower.endswith('behavior.md'):
            score += 180
        if 'quiet_hours' in rel_lower or 'quiet-hours' in rel_lower:
            score += 95
        if any(term in rel_lower for term in ('cooldown', 'nudge', 'scheduler', 'settings', 'appstate')):
            score += 35
    if generated_dependency and normalized not in explicit_paths and item['path'] not in explicit_paths:
        score -= 70
    recency = max(0, item['mtime'])
    score += min(int((recency / 10000000)), 15)
    return score


def build_reason(item, project_type, terms):
    name = item['name']
    category = item['category']
    if (category == 'manifest'):
        return f'Included as a primary project manifest for the detected {project_type} project.'
    if (category == 'log'):
        return 'Included because recent logs are often the fastest signal for debugging prompts.'
    if (category == 'unity'):
        return f'Included as Unity serialized/project evidence (`{name}`).'
    if (category == 'script'):
        return f'Included as a likely execution entry point or script candidate (`{name}`).'
    if (category == 'config'):
        return f'Included as a configuration file that may control runtime behavior (`{name}`).'
    for term in terms:
        if (term in name.lower()):
            return f'Included because its filename matches the prompt term `{term}`.'
    return 'Included as a likely relevant source file based on project type and recency.'


def build_open_source_reason(item, focus_root=None):
    path = str(item.get('path') or '')
    name = os.path.basename(path)
    lowered = name.lower()
    if lowered == 'package.json':
        return 'Included as Unity package metadata for open-source release readiness.'
    if lowered in {'readme.md', 'documentation.md', 'api_reference.md'}:
        return 'Included as public documentation evidence for open-source readiness.'
    if lowered in {'license.md', 'license'}:
        return 'Included to verify public license packaging.'
    if lowered == 'changelog.md':
        return 'Included to verify public release history and versioning.'
    rel_lower = path.replace('\\', '/').lower()
    if rel_lower.endswith('.asmdef'):
        return 'Included to verify Unity assembly/package boundaries.'
    if '/tests/' in rel_lower:
        return 'Included as package test coverage evidence.'
    if '/editor/' in rel_lower or '/runtime/' in rel_lower:
        return 'Included as core package implementation evidence.'
    return 'Included because it is inside the inferred package scope for the open-source review.'


def evidence_policy_summary(evidence_items, project_root, project_type):
    from .utils import is_generated_dependency_path, is_project_owned_path
    generated = []
    project_owned = []
    for item in evidence_items:
        path = item.get('path') or ''
        if is_generated_dependency_path(path, project_root):
            generated.append(path)
        if is_project_owned_path(path, project_root, project_type):
            project_owned.append(path)
    warnings = []
    if generated:
        warnings.append('Generated/dependency files selected.')
    if not project_owned:
        warnings.append('No project-owned source selected.')
    return {
        'generated_dependency_count': len(generated),
        'generated_dependency_paths': generated[:8],
        'project_owned_count': len(project_owned),
        'project_owned_paths': project_owned[:8],
        'warnings': warnings,
    }


def evidence_item_from_path(path, category, reason, terms, indexed=None):
    from .symbols import extract_unity_refs, extract_symbols
    from .parser import excerpt_for_text, read_text_file, excerpt_for_log
    text = read_text_file(path)
    (preview, start_line, end_line) = (excerpt_for_log(text, terms) if (category == 'log') else excerpt_for_text(text, terms))
    return {'path': path, 'kind': category, 'reason': reason, 'preview': preview, 'start_line': start_line, 'end_line': end_line, 'symbols': ((indexed or {}).get('symbols') or extract_symbols(path, text)), 'unity_refs': ((indexed or {}).get('unity_refs') or extract_unity_refs(path, text))}


def select_evidence(project_root, prompt, project_type, repo_index=None, preflight=None, max_items=None, include_generated=False):
    from .classifier import classify_prompt_intent, expanded_prompt_terms, is_open_source_readiness_prompt, prompt_terms
    from .discovery import iter_project_files
    from .utils import categorize_path, is_noise_path, normalize_path, rel_path
    terms = expanded_prompt_terms(prompt)
    preview_terms = prompt_terms(prompt)
    term_set = set(terms)
    if project_type == 'unity' and (term_set & {'apk', 'android'}) and (term_set & {'icon', 'icons', 'launcher', 'mipmap', 'adaptive'}):
        preview_terms = ['m_icons', 'buildtarget: android', 'android:icon', 'launcher', 'mipmap', 'platformsettings', 'icon', 'icons', 'android'] + preview_terms
    intent = classify_prompt_intent(prompt)
    packet_mode = ((preflight or {}).get('packet_mode') or intent['packet_mode'])
    focus_root = ((preflight or {}).get('focus_root') or None)
    collection_plan = (preflight or {}).get('collection_plan') or {}
    open_source_review = is_open_source_readiness_prompt(prompt) or collection_plan.get('task_type') == 'release_readiness'
    changed_paths = set(((preflight or {}).get('changed_paths') or []))
    explicit_paths = set(((preflight or {}).get('explicit_paths') or []))
    error_paths = set(((preflight or {}).get('error_paths') or []))
    if repo_index:
        discovered = [{'path': item['path'], 'relative_path': rel_path(item['path'], project_root), 'name': os.path.basename(item['path']), 'category': item['category'], 'mtime': item.get('mtime', 0), 'symbols': (item.get('symbols') or []), 'unity_refs': (item.get('unity_refs') or []), 'search_terms': (item.get('search_terms') or [])} for item in repo_index.get('files', [])]
        indexed_by_path = {item['path']: item for item in repo_index.get('files', [])}
    else:
        discovered = iter_project_files(project_root)
        indexed_by_path = {}
    known_paths = {normalize_path(item['path']) for item in discovered if item.get('path')}
    for changed_path in changed_paths:
        if not changed_path:
            continue
        path = changed_path if os.path.isabs(changed_path) else os.path.join(project_root, changed_path)
        if not os.path.isfile(path) or is_noise_path(path):
            continue
        normalized = normalize_path(path)
        if normalized in known_paths:
            continue
        category = categorize_path(path)
        if not category:
            continue
        try:
            stat = os.stat(path)
            mtime = stat.st_mtime
        except OSError:
            mtime = 0
        discovered.append({
            'path': normalized,
            'relative_path': rel_path(normalized, project_root),
            'name': os.path.basename(normalized),
            'category': category,
            'mtime': mtime,
            'symbols': [],
            'unity_refs': [],
            'search_terms': [],
        })
        known_paths.add(normalized)
    if open_source_review and focus_root:
        for seed_path in focus_seed_paths(focus_root):
            if not os.path.isfile(seed_path) or is_noise_path(seed_path):
                continue
            normalized = normalize_path(seed_path)
            if normalized in known_paths:
                continue
            category = categorize_path(seed_path)
            if not category:
                continue
            try:
                stat = os.stat(seed_path)
                mtime = stat.st_mtime
            except OSError:
                mtime = 0
            discovered.append({
                'path': normalized,
                'relative_path': rel_path(normalized, project_root),
                'name': os.path.basename(normalized),
                'category': category,
                'mtime': mtime,
                'symbols': [],
                'unity_refs': [],
                'search_terms': [],
            })
            known_paths.add(normalized)
    scored = sorted(discovered, key=(lambda item: file_rank(item, terms, intent, project_type, packet_mode=packet_mode, changed_paths=changed_paths, explicit_paths=explicit_paths, error_paths=error_paths, project_root=project_root, focus_root=focus_root, open_source_review=open_source_review, collection_plan=collection_plan)), reverse=True)
    evidence = []
    seen_paths = set()
    wants_log_evidence = (packet_mode == 'debug') or bool(set(terms) & {'log', 'logs', 'error', 'errors', 'traceback', 'crash', 'exception', 'fail', 'failure'})
    category_limits = {
        'manifest': 2,
        'log': 2 if packet_mode == 'debug' else (1 if wants_log_evidence else 0),
        'script': 2,
        'source': 6 if packet_mode in {'debug', 'review', 'implementation'} else 4,
        'config': 2,
        'unity': 3,
        'notes': 2,
    }
    if open_source_review:
        category_limits.update({
            'manifest': 4,
            'log': 0,
            'script': 3,
            'source': 4,
            'config': 3,
            'unity': 2,
            'notes': 4,
        })
    category_counts = {key: 0 for key in category_limits}
    from .utils import is_generated_dependency_path
    limit = max_items or MAX_EVIDENCE_ITEMS
    excluded_markers = [str(item).lower() for item in (collection_plan.get('excluded_context') or [])]
    for item in scored:
        if (not include_generated) and is_generated_dependency_path(item['path'], project_root) and item['path'] not in explicit_paths:
            continue
        path_lower = item['path'].replace('\\', '/').lower()
        if ('/fixtures/' in path_lower) and any(marker in {'fixtures', 'fixture projects'} for marker in excluded_markers):
            continue
        category = item['category']
        if (category_counts.get(category, 0) >= category_limits.get(category, 0)):
            continue
        if (item['path'] in seen_paths):
            continue
        seen_paths.add(item['path'])
        category_counts[category] = (category_counts.get(category, 0) + 1)
        reason = build_reason(item, project_type, terms)
        if open_source_review and (not focus_root or _is_under_path(item['path'], focus_root)):
            reason = build_open_source_reason(item, focus_root)
        evidence.append(evidence_item_from_path(item['path'], category, reason, preview_terms, indexed_by_path.get(item['path'])))
        if (len(evidence) >= limit):
            break
    return evidence


def gather_external_evidence(prompt, project_root, terms, discovered=None, repo_index=None):
    from .utils import categorize_path
    extras = []
    for path in extract_explicit_paths(prompt, project_root, discovered, repo_index):
        if (not os.path.isfile(path)):
            continue
        category = (categorize_path(path) or 'notes')
        extras.append(evidence_item_from_path(path, category, 'Included because the prompt explicitly referenced this external path.', terms))
    return extras


def build_preflight(prompt, project_root, project_type, discovered, repo_index, git_status, git_diff_summary, collection_plan=None):
    from .parser import find_errors, get_unity_logs, read_text_file, group_compile_errors, excerpt_for_log
    from .classifier import classify_prompt_intent, prompt_terms, expanded_prompt_terms
    from .collection_plan import plan_packet_mode
    from .utils import normalize_path, is_noise_path, is_generated_dependency_path
    intent = classify_prompt_intent(prompt)
    collection_plan = collection_plan or {}
    focus_scope = infer_focus_scope(prompt, project_root, project_type, discovered, repo_index, collection_plan)
    explicit_paths = extract_explicit_paths(prompt, project_root, discovered, repo_index)
    changed_files = ((git_diff_summary or {}).get('changed_files') or [])
    changed_paths = {item.get('path') for item in changed_files if (item.get('path') and (not is_noise_path(item.get('path'))))}
    changed_paths.update((normalize_path(os.path.join(project_root, path)) for path in list(changed_paths) if (path and (not str(path).startswith('/')))))
    error_paths = set()
    log_candidates = []
    for item in discovered:
        if (item.get('category') != 'log'):
            continue
        if is_generated_dependency_path(item.get('path') or '', project_root):
            continue
        errors = get_unity_logs(item['path'])
        if (not errors):
            preview = excerpt_for_log(read_text_file(item['path']), prompt_terms(prompt))[0]
            errors = find_errors(preview)
        if errors:
            error_paths.add(normalize_path(item['path']))
            grouped_errors = group_compile_errors(errors)
            log_candidates.append({'path': item['path'], 'errors': grouped_errors[:MAX_ERROR_LINES]})
        else:
            log_candidates.append({'path': item['path'], 'errors': []})
    candidate_paths = [item.get('path') for item in sorted(repo_index.get('files', []), key=(lambda entry: (entry.get('mtime') or 0)), reverse=True)[:30]]
    packet_mode = plan_packet_mode(collection_plan, intent['packet_mode'])
    return {'intent': intent, 'packet_mode': packet_mode, 'confidence': intent['confidence'], 'terms': prompt_terms(prompt), 'expanded_terms': expanded_prompt_terms(prompt), 'explicit_paths': explicit_paths, 'changed_files': changed_files, 'changed_paths': sorted(changed_paths), 'git_status': git_status, 'git_diff_summary': git_diff_summary, 'log_candidates': log_candidates[:5], 'error_paths': sorted(error_paths), 'candidate_paths': [path for path in candidate_paths if (path and (not is_noise_path(path)))], 'project_type': project_type, 'collection_plan': collection_plan, **focus_scope}


def assess_evidence_quality(prompt, evidence_items, preflight=None):
    from .classifier import prompt_terms, expanded_prompt_terms, split_identifier_terms
    from .utils import normalize_path, is_generated_dependency_path
    original_terms = set(prompt_terms(prompt))
    expanded_terms = set(expanded_prompt_terms(prompt))
    explicit_paths = {normalize_path(path) for path in ((preflight or {}).get('explicit_paths') or [])}
    changed_paths = {normalize_path(path) for path in ((preflight or {}).get('changed_paths') or [])}
    error_paths = {normalize_path(path) for path in ((preflight or {}).get('error_paths') or [])}
    strong = []
    weak = []
    generated = []
    for item in evidence_items:
        path = item.get('path') or ''
        if is_generated_dependency_path(path):
            generated.append(path)
        raw_haystack = ' '.join([
            path,
            os.path.basename(path),
            ' '.join(item.get('symbols') or []),
            item.get('preview') or '',
        ])
        haystack = raw_haystack.lower()
        haystack_terms = set(split_identifier_terms(raw_haystack))
        original_matches = sorted(term for term in original_terms if (term in haystack or term in haystack_terms))
        expanded_matches = sorted(term for term in expanded_terms if (term in haystack or term in haystack_terms))
        normalized = normalize_path(path) if path else ''
        if normalized in explicit_paths or normalized in changed_paths or normalized in error_paths or original_matches or len(expanded_matches) >= 2:
            strong.append({'path': path, 'matches': (original_matches or expanded_matches)[:8]})
        elif expanded_matches:
            weak.append({'path': path, 'matches': expanded_matches[:5]})
    status = 'ok' if strong else 'degraded'
    warnings = [] if strong else ['No strongly matched evidence file was selected for this task.']
    if generated:
        warnings.append('Generated/dependency files selected.')
    return {
        'status': status,
        'strong_match_count': len(strong),
        'weak_match_count': len(weak),
        'strong_matches': strong[:8],
        'weak_matches': weak[:8],
        'generated_dependency_count': len(generated),
        'generated_dependency_paths': generated[:8],
        'warnings': warnings,
    }


def _evidence_satisfies_requirement(item, requirement):
    path = str(item.get('path') or '').replace('\\', '/').lower()
    name = os.path.basename(path)
    kind = item.get('kind')
    if requirement == 'logs':
        return kind == 'log'
    if requirement in {'errors', 'related_source', 'call_sites', 'runtime_state', 'settings_ui'}:
        return kind in {'source', 'script', 'config'}
    if requirement == 'package_manifest':
        return name == 'package.json'
    if requirement == 'readme':
        return name == 'readme.md'
    if requirement == 'license':
        return name in {'license', 'license.md'}
    if requirement == 'changelog':
        return name == 'changelog.md'
    if requirement == 'graphify_integration':
        return 'graphify' in path and kind in {'source', 'script', 'notes', 'config'}
    if requirement == 'graphify_version':
        return name in {'changelog.md', 'readme.md'} and 'graphify' in (item.get('preview') or '').lower()
    if requirement == 'docs':
        return name in {'documentation.md', 'api_reference.md'} or '/docs/' in path
    if requirement == 'tests':
        return '/test/' in path or '/tests/' in path or name.endswith('tests.cs')
    if requirement == 'core_entrypoints':
        return name in {'mcpserver.cs', 'mcpservermethods.cs', 'nexus_unity_bridge.py', 'server.py', 'main.py'} or '/runtime/' in path
    if requirement in {'changed_files', 'diff_summary'}:
        return True
    return requirement.replace('_', '') in path.replace('_', '').replace('-', '')


def assess_plan_alignment(collection_plan, evidence_items, preflight=None):
    from .utils import is_generated_dependency_path, normalize_path
    collection_plan = collection_plan or {}
    required = [item for item in (collection_plan.get('required_evidence') or []) if item]
    missing = []
    for requirement in required:
        if not any(_evidence_satisfies_requirement(item, requirement) for item in evidence_items):
            missing.append(requirement)

    excluded_selected = []
    excluded = [str(item).lower() for item in (collection_plan.get('excluded_context') or [])]
    focus_root = (preflight or {}).get('focus_root')
    for item in evidence_items:
        path = str(item.get('path') or '')
        path_lower = path.replace('\\', '/').lower()
        if is_generated_dependency_path(path):
            excluded_selected.append(path)
            continue
        if focus_root:
            try:
                if normalize_path(path).startswith(normalize_path(focus_root)):
                    continue
            except Exception:
                pass
        for marker in excluded:
            if marker and marker in path_lower:
                excluded_selected.append(path)
                break

    status = 'ok' if not missing and not excluded_selected else 'degraded'
    result = {
        'plan_alignment_status': status,
        'missing_required_evidence': missing[:8],
        'excluded_context_selected': excluded_selected[:8],
    }
    if status == 'degraded':
        result['status'] = 'degraded'
    return result


def _candidate_paths_for_requirement(requirement, project_root, focus_root=None):
    roots = [Path(focus_root)] if focus_root else [Path(project_root)]
    patterns = {
        'package_manifest': ['package.json'],
        'readme': ['README.md', 'README.MD'],
        'license': ['LICENSE.md', 'LICENSE.MD', 'LICENSE'],
        'changelog': ['CHANGELOG.md', 'CHANGELOG.MD'],
        'graphify_integration': ['Soma/gateway/graphify_adapter.py', 'Soma/gateway/graph_storage.py', 'Soma/scout_pipeline_module/pipeline.py', 'Soma/gateway/tools/context.py', 'README.md', 'docs/**/*.md'],
        'graphify_version': ['CHANGELOG.md', 'CHANGELOG.MD', 'README.md', 'docs/**/*.md'],
        'docs': ['DOCUMENTATION.MD', 'Documentation.md', 'API_REFERENCE.MD', 'API_REFERENCE.md', 'docs/**/*.md'],
        'tests': ['Editor/Tests/*.cs', 'Tests/**/*.cs', 'tests/**/*.py', '**/*Tests.cs', '**/*Test.swift'],
        'core_entrypoints': ['Editor/MCPServer.cs', 'Editor/MCPServerMethods.cs', 'Editor/nexus_unity_bridge.py', 'server.py', 'main.py', 'Runtime/*.cs'],
        'logs': ['*.log', 'Logs/*.log', 'logs/*.log', '*.jsonl'],
        'related_source': ['**/*.swift', '**/*.cs', '**/*.py', '**/*.ts', '**/*.js'],
        'call_sites': ['**/*.swift', '**/*.cs', '**/*.py', '**/*.ts', '**/*.js'],
        'runtime_state': ['**/*.swift', '**/*.cs', '**/*.py'],
        'settings_ui': ['**/*Settings*.swift', '**/*Settings*.cs', '**/*Settings*.py', '**/*View*.swift'],
        'config': ['**/*.json', '**/*.xml', '**/*.yaml', '**/*.yml', '**/*.toml'],
    }
    result = []
    for root in roots:
        if not root or not root.exists():
            continue
        for pattern in patterns.get(requirement, [requirement]):
            candidate = root / pattern
            if any(char in pattern for char in '*?['):
                result.extend(str(path) for path in root.glob(pattern) if path.is_file())
            elif candidate.is_file():
                result.append(str(candidate))
    return list(dict.fromkeys(result))


def repair_evidence_from_plan(project_root, prompt, project_type, evidence_items, collection_plan=None, preflight=None, referee_result=None, repo_index=None, max_additions=3):
    from .utils import categorize_path, is_generated_dependency_path, normalize_path
    from .classifier import prompt_terms
    collection_plan = collection_plan or {}
    referee_result = referee_result or {}
    selected = list(evidence_items or [])
    seen = {normalize_path(item.get('path')) for item in selected if item.get('path')}
    focus_root = (preflight or {}).get('focus_root')
    alignment = assess_plan_alignment(collection_plan, selected, preflight)
    needs = []
    needs.extend(alignment.get('missing_required_evidence') or [])
    needs.extend(referee_result.get('missing_evidence') or [])
    needs.extend(referee_result.get('recommended_additions') or [])
    needs = list(dict.fromkeys(str(item).strip() for item in needs if str(item).strip()))
    if not needs:
        return selected, []

    indexed_by_path = {item.get('path'): item for item in (repo_index or {}).get('files', []) if item.get('path')}
    additions = []
    for need in needs:
        if len(additions) >= max_additions:
            break
        candidate_paths = []
        if os.path.isabs(need) and os.path.isfile(need):
            candidate_paths.append(need)
        else:
            direct = os.path.join(focus_root or project_root, need)
            if os.path.isfile(direct):
                candidate_paths.append(direct)
            candidate_paths.extend(_candidate_paths_for_requirement(need, project_root, focus_root))
        for candidate in candidate_paths:
            if len(additions) >= max_additions:
                break
            if not os.path.isfile(candidate) or is_generated_dependency_path(candidate, project_root):
                continue
            normalized = normalize_path(candidate)
            if normalized in seen:
                continue
            category = categorize_path(normalized)
            if not category:
                continue
            reason = f'Added during evidence repair for missing `{need}` from the collection plan.'
            additions.append(evidence_item_from_path(normalized, category, reason, prompt_terms(prompt), indexed_by_path.get(normalized)))
            seen.add(normalized)
    return selected + additions, additions
