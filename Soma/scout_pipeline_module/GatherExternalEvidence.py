
import argparse

import asyncio

import hashlib

import json

import os

import re

import shutil

import subprocess

import urllib.request

from pathlib import Path

from mcp import ClientSession, StdioServerParameters

from mcp.client.stdio import stdio_client

import uuid

from .ScoutConfigAndConstants import *


def extract_explicit_paths(prompt, project_root):
    from .ExtractSymbolsAndUnityRefs import extract_unity_refs, extract_symbols
    from .ParseTextAndLogFiles import find_errors, get_unity_logs, excerpt_for_text, read_text_file, group_compile_errors, excerpt_for_log
    from .ClassifyPromptIntentWithLlama import classify_prompt_intent, prompt_terms
    from .DiscoverAndParseFiles import iter_project_files
    from .FileAndPathUtilities import categorize_path, dedupe_strings, rel_path, normalize_path, is_noise_path
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
    return dedupe_strings(candidates)


def file_rank(item, terms, intent, project_type, packet_mode='debug', changed_paths=None, explicit_paths=None, error_paths=None):
    from .ExtractSymbolsAndUnityRefs import extract_unity_refs, extract_symbols
    from .ParseTextAndLogFiles import find_errors, get_unity_logs, excerpt_for_text, read_text_file, group_compile_errors, excerpt_for_log
    from .ClassifyPromptIntentWithLlama import classify_prompt_intent, prompt_terms
    from .DiscoverAndParseFiles import iter_project_files
    from .FileAndPathUtilities import categorize_path, dedupe_strings, rel_path, normalize_path, is_noise_path
    score = 0
    changed_paths = (changed_paths or set())
    explicit_paths = (explicit_paths or set())
    error_paths = (error_paths or set())
    lowered_name = item['name'].lower()
    lowered_path = item['path'].lower()
    category = item['category']
    normalized = normalize_path(item['path'])
    rel = (item.get('relative_path') or item['path'])
    if ((normalized in explicit_paths) or (item['path'] in explicit_paths)):
        score += 200
    if ((rel in changed_paths) or (item['path'] in changed_paths) or (normalized in changed_paths)):
        score += (120 if (packet_mode in {'changes', 'review', 'implementation'}) else 50)
    if ((item['path'] in error_paths) or (normalized in error_paths)):
        score += (130 if (packet_mode == 'debug') else 45)
    if (category == 'manifest'):
        score += (18 if (packet_mode in {'changes', 'review'}) else 70)
    if (category == 'log'):
        score += (60 if (packet_mode == 'debug') else 18)
    if (category == 'unity'):
        score += (60 if (project_type == 'unity') else 20)
    if (category == 'script'):
        score += (45 if (('script' in terms) or ('script' in intent['reason'].lower())) else 25)
    if (category == 'source'):
        score += (45 if (packet_mode in {'changes', 'review', 'implementation'}) else 25)
    if (category == 'config'):
        score += 18
    if (project_type == 'unity'):
        if item['path'].endswith(('.cs', '.asmdef', '.unity', '.prefab')):
            score += 28
    elif (project_type == 'swift'):
        if ((lowered_name == 'package.swift') or lowered_name.endswith('.xcodeproj')):
            score += 25
        if item['path'].endswith('.swift'):
            score += 18
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
    for term in terms:
        if (term in lowered_name):
            score += 18
        elif (term in lowered_path):
            score += 8
        if (term in ' '.join((item.get('symbols') or [])).lower()):
            score += 22
    recency = max(0, item['mtime'])
    score += min(int((recency / 10000000)), 15)
    return score


def build_reason(item, project_type, terms):
    from .ExtractSymbolsAndUnityRefs import extract_unity_refs, extract_symbols
    from .ParseTextAndLogFiles import find_errors, get_unity_logs, excerpt_for_text, read_text_file, group_compile_errors, excerpt_for_log
    from .ClassifyPromptIntentWithLlama import classify_prompt_intent, prompt_terms
    from .DiscoverAndParseFiles import iter_project_files
    from .FileAndPathUtilities import categorize_path, dedupe_strings, rel_path, normalize_path, is_noise_path
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


def evidence_item_from_path(path, category, reason, terms, indexed=None):
    from .ExtractSymbolsAndUnityRefs import extract_unity_refs, extract_symbols
    from .ParseTextAndLogFiles import find_errors, get_unity_logs, excerpt_for_text, read_text_file, group_compile_errors, excerpt_for_log
    from .ClassifyPromptIntentWithLlama import classify_prompt_intent, prompt_terms
    from .DiscoverAndParseFiles import iter_project_files
    from .FileAndPathUtilities import categorize_path, dedupe_strings, rel_path, normalize_path, is_noise_path
    text = read_text_file(path)
    (preview, start_line, end_line) = (excerpt_for_log(text, terms) if (category == 'log') else excerpt_for_text(text, terms))
    return {'path': path, 'kind': category, 'reason': reason, 'preview': preview, 'start_line': start_line, 'end_line': end_line, 'symbols': ((indexed or {}).get('symbols') or extract_symbols(path, text)), 'unity_refs': ((indexed or {}).get('unity_refs') or extract_unity_refs(path, text))}


def select_evidence(project_root, prompt, project_type, repo_index=None, preflight=None):
    from .ExtractSymbolsAndUnityRefs import extract_unity_refs, extract_symbols
    from .ParseTextAndLogFiles import find_errors, get_unity_logs, excerpt_for_text, read_text_file, group_compile_errors, excerpt_for_log
    from .ClassifyPromptIntentWithLlama import classify_prompt_intent, prompt_terms
    from .DiscoverAndParseFiles import iter_project_files
    from .FileAndPathUtilities import categorize_path, dedupe_strings, rel_path, normalize_path, is_noise_path
    terms = prompt_terms(prompt)
    intent = classify_prompt_intent(prompt)
    packet_mode = ((preflight or {}).get('packet_mode') or intent['packet_mode'])
    changed_paths = set(((preflight or {}).get('changed_paths') or []))
    explicit_paths = set(((preflight or {}).get('explicit_paths') or []))
    error_paths = set(((preflight or {}).get('error_paths') or []))
    if repo_index:
        discovered = [{'path': item['path'], 'relative_path': rel_path(item['path'], project_root), 'name': Path(item['path']).name, 'category': item['category'], 'mtime': item.get('mtime', 0), 'symbols': (item.get('symbols') or []), 'unity_refs': (item.get('unity_refs') or [])} for item in repo_index.get('files', [])]
        indexed_by_path = {item['path']: item for item in repo_index.get('files', [])}
    else:
        discovered = iter_project_files(project_root)
        indexed_by_path = {}
    scored = sorted(discovered, key=(lambda item: file_rank(item, terms, intent, project_type, packet_mode=packet_mode, changed_paths=changed_paths, explicit_paths=explicit_paths, error_paths=error_paths)), reverse=True)
    evidence = []
    seen_paths = set()
    category_limits = {'manifest': 2, 'log': 2, 'script': 2, 'source': 3, 'config': 2, 'unity': 3, 'notes': 1}
    category_counts = {key: 0 for key in category_limits}
    for item in scored:
        category = item['category']
        if (category_counts.get(category, 0) >= category_limits.get(category, 0)):
            continue
        if (item['path'] in seen_paths):
            continue
        seen_paths.add(item['path'])
        category_counts[category] = (category_counts.get(category, 0) + 1)
        evidence.append(evidence_item_from_path(item['path'], category, build_reason(item, project_type, terms), terms, indexed_by_path.get(item['path'])))
        if (len(evidence) >= MAX_EVIDENCE_ITEMS):
            break
    return evidence


def gather_external_evidence(prompt, project_root, terms):
    from .ExtractSymbolsAndUnityRefs import extract_unity_refs, extract_symbols
    from .ParseTextAndLogFiles import find_errors, get_unity_logs, excerpt_for_text, read_text_file, group_compile_errors, excerpt_for_log
    from .ClassifyPromptIntentWithLlama import classify_prompt_intent, prompt_terms
    from .DiscoverAndParseFiles import iter_project_files
    from .FileAndPathUtilities import categorize_path, dedupe_strings, rel_path, normalize_path, is_noise_path
    extras = []
    for path in extract_explicit_paths(prompt, project_root):
        if (not os.path.isfile(path)):
            continue
        category = (categorize_path(Path(path)) or 'notes')
        extras.append(evidence_item_from_path(path, category, 'Included because the prompt explicitly referenced this external path.', terms))
    return extras


def build_preflight(prompt, project_root, project_type, discovered, repo_index, git_status, git_diff_summary):
    from .ExtractSymbolsAndUnityRefs import extract_unity_refs, extract_symbols
    from .ParseTextAndLogFiles import find_errors, get_unity_logs, excerpt_for_text, read_text_file, group_compile_errors, excerpt_for_log
    from .ClassifyPromptIntentWithLlama import classify_prompt_intent, prompt_terms
    from .DiscoverAndParseFiles import iter_project_files
    from .FileAndPathUtilities import categorize_path, dedupe_strings, rel_path, normalize_path, is_noise_path
    intent = classify_prompt_intent(prompt)
    explicit_paths = extract_explicit_paths(prompt, project_root)
    changed_files = ((git_diff_summary or {}).get('changed_files') or [])
    changed_paths = {item.get('path') for item in changed_files if (item.get('path') and (not is_noise_path(item.get('path'))))}
    changed_paths.update((normalize_path((Path(project_root) / path)) for path in list(changed_paths) if (path and (not str(path).startswith('/')))))
    error_paths = set()
    log_candidates = []
    for item in discovered:
        if (item.get('category') != 'log'):
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
    return {'intent': intent, 'packet_mode': intent['packet_mode'], 'confidence': intent['confidence'], 'terms': prompt_terms(prompt), 'explicit_paths': explicit_paths, 'changed_files': changed_files, 'changed_paths': sorted(changed_paths), 'git_status': git_status, 'git_diff_summary': git_diff_summary, 'log_candidates': log_candidates[:5], 'error_paths': sorted(error_paths), 'candidate_paths': [path for path in candidate_paths if (path and (not is_noise_path(path)))], 'project_type': project_type}
