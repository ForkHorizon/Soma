"""Evidence quality and repair checks."""
import os
from pathlib import Path

from .gather_select import evidence_item_from_path


def assess_evidence_quality(prompt, evidence_items, preflight=None):
    from .classifier import expanded_prompt_terms, prompt_terms, split_identifier_terms
    from .utils import is_generated_dependency_path, normalize_path
    terms = _quality_terms(prompt, prompt_terms, expanded_prompt_terms)
    refs = _quality_refs(preflight, normalize_path)
    strong, weak, generated = [], [], []
    for item in evidence_items:
        matches = _evidence_matches(item, terms, split_identifier_terms)
        path = item.get('path') or ''
        normalized = normalize_path(path) if path else ''
        if is_generated_dependency_path(path):
            generated.append(path)
        if normalized in refs or matches['original'] or len(matches['expanded']) >= 2:
            strong.append({'path': path, 'matches': (matches['original'] or matches['expanded'])[:8]})
        elif matches['expanded']:
            weak.append({'path': path, 'matches': matches['expanded'][:5]})
    return _quality_payload(strong, weak, generated)


def _quality_terms(prompt, prompt_terms, expanded_prompt_terms):
    return {'original': set(prompt_terms(prompt)), 'expanded': set(expanded_prompt_terms(prompt))}


def _quality_refs(preflight, normalize_path):
    refs = []
    for key in ('explicit_paths', 'changed_paths', 'error_paths'):
        refs.extend((preflight or {}).get(key) or [])
    return {normalize_path(path) for path in refs}


def _evidence_matches(item, terms, split_identifier_terms):
    path = item.get('path') or ''
    raw = ' '.join([path, os.path.basename(path), ' '.join(item.get('symbols') or []), item.get('preview') or ''])
    haystack = raw.lower()
    haystack_terms = set(split_identifier_terms(raw))
    return {
        'original': sorted(term for term in terms['original'] if term in haystack or term in haystack_terms),
        'expanded': sorted(term for term in terms['expanded'] if term in haystack or term in haystack_terms),
    }


def _quality_payload(strong, weak, generated):
    warnings = [] if strong else ['No strongly matched evidence file was selected for this task.']
    if generated:
        warnings.append('Generated/dependency files selected.')
    return {'status': 'ok' if strong else 'degraded', 'strong_match_count': len(strong), 'weak_match_count': len(weak), 'strong_matches': strong[:8], 'weak_matches': weak[:8], 'generated_dependency_count': len(generated), 'generated_dependency_paths': generated[:8], 'warnings': warnings}


def _evidence_satisfies_requirement(item, requirement):
    path = str(item.get('path') or '').replace('\\', '/').lower()
    name = os.path.basename(path)
    kind = item.get('kind')
    if requirement == 'logs':
        return kind == 'log'
    if requirement in {'errors', 'related_source', 'call_sites', 'runtime_state', 'settings_ui'}:
        return kind in {'source', 'script', 'config'}
    if requirement in {'package_manifest', 'readme', 'license', 'changelog'}:
        return _doc_requirement_matches(requirement, name)
    if requirement == 'graphify_integration':
        return 'graphify' in path and kind in {'source', 'script', 'notes', 'config'}
    if requirement == 'graphify_version':
        return _graphify_version_matches(item, name, kind)
    if requirement == 'docs':
        return name in {'documentation.md', 'api_reference.md'} or '/docs/' in path
    if requirement == 'tests':
        return '/test/' in path or '/tests/' in path or name.endswith('tests.cs')
    if requirement == 'core_entrypoints':
        return name in {'mcpserver.cs', 'mcpservermethods.cs', 'nexus_unity_bridge.py', 'server.py', 'main.py'} or '/runtime/' in path
    if requirement in {'changed_files', 'diff_summary'}:
        return True
    return requirement.replace('_', '') in path.replace('_', '').replace('-', '')


def _doc_requirement_matches(requirement, name):
    return {
        'package_manifest': name == 'package.json',
        'readme': name == 'readme.md',
        'license': name in {'license', 'license.md'},
        'changelog': name == 'changelog.md',
    }.get(requirement, False)


def _graphify_version_matches(item, name, kind):
    if kind == 'command' and 'graphify' in ((item.get('preview') or '') + ' ' + (item.get('path') or '')).lower():
        return True
    return name in {'changelog.md', 'readme.md'} and 'graphify' in (item.get('preview') or '').lower()


def assess_plan_alignment(collection_plan, evidence_items, preflight=None):
    from .utils import is_generated_dependency_path, normalize_path
    collection_plan = collection_plan or {}
    missing = _missing_required(collection_plan, evidence_items)
    excluded_selected = _excluded_selected(collection_plan, evidence_items, preflight, is_generated_dependency_path, normalize_path)
    status = 'ok' if not missing and not excluded_selected else 'degraded'
    result = {'plan_alignment_status': status, 'missing_required_evidence': missing[:8], 'excluded_context_selected': excluded_selected[:8]}
    if status == 'degraded':
        result['status'] = 'degraded'
    return result


def _missing_required(collection_plan, evidence_items):
    required = [item for item in collection_plan.get('required_evidence') or [] if item]
    return [requirement for requirement in required if not any(_evidence_satisfies_requirement(item, requirement) for item in evidence_items)]


def _excluded_selected(collection_plan, evidence_items, preflight, is_generated_dependency_path, normalize_path):
    excluded = [str(item).lower() for item in collection_plan.get('excluded_context') or []]
    selected = []
    for item in evidence_items:
        path = str(item.get('path') or '')
        if is_generated_dependency_path(path) or _matches_excluded(path, excluded, preflight, normalize_path):
            selected.append(path)
    return selected


def _matches_excluded(path, excluded, preflight, normalize_path):
    focus_root = (preflight or {}).get('focus_root')
    if focus_root:
        try:
            if normalize_path(path).startswith(normalize_path(focus_root)):
                return False
        except Exception:
            pass
    return any(marker and marker in path.replace('\\', '/').lower() for marker in excluded)


def _candidate_paths_for_requirement(requirement, project_root, focus_root=None):
    roots = [Path(focus_root)] if focus_root else [Path(project_root)]
    result = []
    for root in roots:
        if not root or not root.exists():
            continue
        for pattern in _requirement_patterns().get(requirement, [requirement]):
            result.extend(_paths_for_pattern(root, pattern))
    return list(dict.fromkeys(result))


def _requirement_patterns():
    return {
        'package_manifest': ['package.json'], 'readme': ['README.md', 'README.MD'], 'license': ['LICENSE.md', 'LICENSE.MD', 'LICENSE'], 'changelog': ['CHANGELOG.md', 'CHANGELOG.MD'],
        'graphify_integration': ['Soma/gateway/graphify_adapter.py', 'Soma/gateway/graph_storage.py', 'Soma/scout_pipeline_module/pipeline.py', 'Soma/gateway/tools/context.py', 'README.md', 'docs/**/*.md'],
        'graphify_version': ['CHANGELOG.md', 'CHANGELOG.MD', 'README.md', 'docs/**/*.md'], 'docs': ['DOCUMENTATION.MD', 'Documentation.md', 'API_REFERENCE.MD', 'API_REFERENCE.md', 'docs/**/*.md'],
        'tests': ['Editor/Tests/*.cs', 'Tests/**/*.cs', 'tests/**/*.py', '**/*Tests.cs', '**/*Test.swift'], 'core_entrypoints': ['Editor/MCPServer.cs', 'Editor/MCPServerMethods.cs', 'Editor/nexus_unity_bridge.py', 'server.py', 'main.py', 'Runtime/*.cs'],
        'logs': ['*.log', 'Logs/*.log', 'logs/*.log', '*.jsonl'], 'related_source': ['**/*.swift', '**/*.cs', '**/*.py', '**/*.ts', '**/*.js'], 'call_sites': ['**/*.swift', '**/*.cs', '**/*.py', '**/*.ts', '**/*.js'],
        'runtime_state': ['**/*.swift', '**/*.cs', '**/*.py'], 'settings_ui': ['**/*Settings*.swift', '**/*Settings*.cs', '**/*Settings*.py', '**/*View*.swift'], 'config': ['**/*.json', '**/*.xml', '**/*.yaml', '**/*.yml', '**/*.toml'],
    }


def _paths_for_pattern(root, pattern):
    candidate = root / pattern
    if any(char in pattern for char in '*?['):
        return [str(path) for path in root.glob(pattern) if path.is_file()]
    return [str(candidate)] if candidate.is_file() else []


def repair_evidence_from_plan(project_root, prompt, project_type, evidence_items, collection_plan=None, preflight=None, referee_result=None, repo_index=None, max_additions=3):
    from .classifier import prompt_terms
    from .utils import categorize_path, is_generated_dependency_path, normalize_path
    selected = list(evidence_items or [])
    seen = {normalize_path(item.get('path')) for item in selected if item.get('path')}
    needs = _repair_needs(collection_plan or {}, selected, preflight, referee_result or {})
    indexed_by_path = {item.get('path'): item for item in (repo_index or {}).get('files', []) if item.get('path')}
    additions = _repair_additions(needs, project_root, prompt, preflight, indexed_by_path, seen, max_additions, prompt_terms, categorize_path, is_generated_dependency_path, normalize_path)
    return selected + additions, additions


def _repair_needs(collection_plan, selected, preflight, referee_result):
    alignment = assess_plan_alignment(collection_plan, selected, preflight)
    needs = []
    needs.extend(alignment.get('missing_required_evidence') or [])
    needs.extend(referee_result.get('missing_evidence') or [])
    needs.extend(referee_result.get('recommended_additions') or [])
    return list(dict.fromkeys(str(item).strip() for item in needs if str(item).strip()))


def _repair_additions(needs, project_root, prompt, preflight, indexed_by_path, seen, max_additions, prompt_terms, categorize_path, is_generated_dependency_path, normalize_path):
    additions = []
    for need in needs:
        if len(additions) >= max_additions:
            break
        for candidate in _candidate_paths_for_need(need, project_root, (preflight or {}).get('focus_root')):
            if len(additions) >= max_additions:
                break
            item = _repair_item(candidate, need, project_root, prompt, indexed_by_path, seen, prompt_terms, categorize_path, is_generated_dependency_path, normalize_path)
            if item:
                additions.append(item)
    return additions


def _candidate_paths_for_need(need, project_root, focus_root):
    candidates = [need] if os.path.isabs(need) and os.path.isfile(need) else []
    direct = os.path.join(focus_root or project_root, need)
    if os.path.isfile(direct):
        candidates.append(direct)
    candidates.extend(_candidate_paths_for_requirement(need, project_root, focus_root))
    return candidates


def _repair_item(candidate, need, project_root, prompt, indexed_by_path, seen, prompt_terms, categorize_path, is_generated_dependency_path, normalize_path):
    if not os.path.isfile(candidate) or is_generated_dependency_path(candidate, project_root):
        return None
    normalized = normalize_path(candidate)
    if normalized in seen:
        return None
    category = categorize_path(normalized)
    if not category:
        return None
    seen.add(normalized)
    reason = f'Added during evidence repair for missing `{need}` from the collection plan.'
    return evidence_item_from_path(normalized, category, reason, prompt_terms(prompt), indexed_by_path.get(normalized))
