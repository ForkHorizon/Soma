"""Preflight metadata collection for gather packets."""
import os

from .config import MAX_ERROR_LINES
from .gather_scope import extract_explicit_paths, infer_focus_scope


def build_preflight(prompt, project_root, project_type, discovered, repo_index, git_status, git_diff_summary, collection_plan=None):
    from .classifier import classify_prompt_intent, expanded_prompt_terms, prompt_terms
    from .collection_plan import plan_packet_mode
    from .parser import excerpt_for_log, find_errors, get_unity_logs, group_compile_errors, read_text_file
    from .utils import is_generated_dependency_path, is_noise_path, normalize_path
    intent = classify_prompt_intent(prompt)
    collection_plan = collection_plan or {}
    explicit_paths = extract_explicit_paths(prompt, project_root, discovered, repo_index)
    changed_paths = _changed_paths(project_root, git_diff_summary, is_noise_path, normalize_path)
    error_paths, log_candidates = _log_candidates(prompt, project_root, discovered, prompt_terms, get_unity_logs, excerpt_for_log, read_text_file, find_errors, group_compile_errors, is_generated_dependency_path, normalize_path)
    candidate_paths = _candidate_paths(repo_index, is_noise_path)
    packet_mode = plan_packet_mode(collection_plan, intent['packet_mode'])
    focus_scope = infer_focus_scope(prompt, project_root, project_type, discovered, repo_index, collection_plan)
    return {
        'intent': intent,
        'packet_mode': packet_mode,
        'confidence': intent['confidence'],
        'terms': prompt_terms(prompt),
        'expanded_terms': expanded_prompt_terms(prompt),
        'explicit_paths': explicit_paths,
        'changed_files': (git_diff_summary or {}).get('changed_files') or [],
        'changed_paths': sorted(changed_paths),
        'git_status': git_status,
        'git_diff_summary': git_diff_summary,
        'log_candidates': log_candidates[:5],
        'error_paths': sorted(error_paths),
        'candidate_paths': candidate_paths,
        'project_type': project_type,
        'collection_plan': collection_plan,
        **focus_scope,
    }


def _changed_paths(project_root, git_diff_summary, is_noise_path, normalize_path):
    changed_files = (git_diff_summary or {}).get('changed_files') or []
    changed = {item.get('path') for item in changed_files if item.get('path') and not is_noise_path(item.get('path'))}
    changed.update(normalize_path(os.path.join(project_root, path)) for path in list(changed) if path and not str(path).startswith('/'))
    return changed


def _log_candidates(prompt, project_root, discovered, prompt_terms, get_unity_logs, excerpt_for_log, read_text_file, find_errors, group_compile_errors, is_generated_dependency_path, normalize_path):
    error_paths = set()
    candidates = []
    for item in discovered:
        if item.get('category') != 'log' or is_generated_dependency_path(item.get('path') or '', project_root):
            continue
        errors = get_unity_logs(item['path'])
        if not errors:
            preview = excerpt_for_log(read_text_file(item['path']), prompt_terms(prompt))[0]
            errors = find_errors(preview)
        error_paths, candidates = _append_log_candidate(item, errors, error_paths, candidates, group_compile_errors, normalize_path)
    return error_paths, candidates


def _append_log_candidate(item, errors, error_paths, candidates, group_compile_errors, normalize_path):
    if errors:
        error_paths.add(normalize_path(item['path']))
        candidates.append({'path': item['path'], 'errors': group_compile_errors(errors)[:MAX_ERROR_LINES]})
    else:
        candidates.append({'path': item['path'], 'errors': []})
    return error_paths, candidates


def _candidate_paths(repo_index, is_noise_path):
    files = sorted((repo_index or {}).get('files', []), key=lambda entry: entry.get('mtime') or 0, reverse=True)
    return [path for path in (item.get('path') for item in files[:30]) if path and not is_noise_path(path)]
