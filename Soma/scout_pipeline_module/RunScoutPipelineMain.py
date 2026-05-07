
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


async def run_gather(user_prompt, project_root, recent_roots_json, token_budget=DEFAULT_TOKEN_BUDGET, use_local_summary=False, analysis_depth='deterministic'):
    from .GatherExternalEvidence import select_evidence, gather_external_evidence, build_preflight
    from .ParseTextAndLogFiles import find_errors
    from .BuildCodexPacketForAnalysis import bundle_for_direct_pass, estimate_tokens, build_codex_packet
    from .ClassifyPromptIntentWithLlama import classify_prompt_intent, prompt_terms
    from .DiscoverAndParseFiles import build_repo_index, iter_project_files, detect_project_type
    from .GitAndVersionControlOperations import get_git_diff_summary, get_git_status
    from .AnalyzeAndRankEvidenceWithModels import rank_evidence_with_model, fallback_summary, analyze_packet_with_model, summarize_with_ollama, should_use_model_summary
    from .FileAndPathUtilities import dedupe_strings, parse_recent_roots, normalize_path
    if (analysis_depth not in ANALYSIS_DEPTHS):
        analysis_depth = 'deterministic'
    intent = classify_prompt_intent(user_prompt)
    recent_roots = parse_recent_roots(recent_roots_json)
    if (not intent['needs_gather']):
        preflight = {'intent': intent, 'packet_mode': 'direct', 'confidence': intent['confidence'], 'terms': prompt_terms(user_prompt), 'explicit_paths': [], 'changed_files': [], 'changed_paths': [], 'log_candidates': [], 'error_paths': [], 'candidate_paths': []}
        print(json.dumps(bundle_for_direct_pass(user_prompt, intent['reason'], project_root, token_budget, analysis_depth, preflight)))
        return
    if (not project_root):
        print(json.dumps({'error': 'This prompt needs project context. Select a project root before relaying it.'}))
        return
    try:
        project_root = normalize_path(project_root)
    except Exception as exc:
        print(json.dumps({'error': f'Invalid project root: {exc}'}))
        return
    if (not os.path.isdir(project_root)):
        print(json.dumps({'error': f'Project root does not exist: {project_root}'}))
        return
    terms = prompt_terms(user_prompt)
    (project_type, type_reason) = detect_project_type(project_root)
    git_status = get_git_status(project_root)
    git_diff_summary = get_git_diff_summary(project_root, terms)
    discovered = iter_project_files(project_root)
    repo_index = build_repo_index(project_root, discovered)
    preflight = build_preflight(user_prompt, project_root, project_type, discovered, repo_index, git_status, git_diff_summary)
    explicit_items = gather_external_evidence(user_prompt, project_root, terms)
    evidence_items = (explicit_items + select_evidence(project_root, user_prompt, project_type, repo_index, preflight))
    deduped_evidence = []
    seen = set()
    for item in evidence_items:
        if (item['path'] in seen):
            continue
        seen.add(item['path'])
        deduped_evidence.append(item)
        if (len(deduped_evidence) >= MAX_EVIDENCE_ITEMS):
            break
    evidence_items = deduped_evidence
    error_lines = dedupe_strings([error for item in evidence_items if (item.get('kind') == 'log') for error in find_errors(item.get('preview', ''))])[:MAX_ERROR_LINES]
    analysis_stages = [{'stage': 'preflight', 'status': 'ok'}, {'stage': 'deterministic', 'status': 'ok'}]
    if (analysis_depth in {'ranked', 'analyst'}):
        (ranked_items, rank_stage) = (await rank_evidence_with_model(user_prompt, preflight, evidence_items))
        evidence_items = ranked_items
        analysis_stages.append(rank_stage)
    model_analysis = None
    if (analysis_depth == 'analyst'):
        (model_analysis, analyst_stage) = (await analyze_packet_with_model(user_prompt, preflight, evidence_items, error_lines))
        analysis_stages.append(analyst_stage)
    summary = fallback_summary(user_prompt, project_root, project_type, evidence_items, error_lines, preflight['packet_mode'])
    if use_local_summary:
        model_summary = (await summarize_with_ollama(user_prompt, project_root, project_type, evidence_items, error_lines))
        if should_use_model_summary(model_summary):
            summary['summary'] = (model_summary.get('summary') or summary['summary'])
            summary['assumptions'] = dedupe_strings((summary.get('assumptions', []) + list((model_summary.get('assumptions') or []))))[:4]
            summary['open_questions'] = dedupe_strings((summary.get('open_questions', []) + list((model_summary.get('open_questions') or []))))[:4]
            summary['confidence'] = max(summary.get('confidence', 0.55), model_summary.get('confidence', 0.55))
    if (type_reason not in summary['assumptions']):
        summary['assumptions'] = ([type_reason] + list((summary.get('assumptions') or [])))
    if (recent_roots and (project_root not in recent_roots)):
        summary['assumptions'].append('Selected project root was used as the authoritative scope for gathering.')
    bundle = {'mode': 'gather', 'original_prompt': user_prompt, 'project_root': project_root, 'project_type': project_type, 'routing_decision': 'gathered_and_relayed', 'packet_mode': preflight['packet_mode'], 'analysis_depth': analysis_depth, 'analysis_stages': analysis_stages, 'preflight': {key: value for (key, value) in preflight.items() if (key not in {'changed_paths', 'error_paths', 'candidate_paths'})}, 'model_analysis': model_analysis, 'gather_reason': intent['reason'], 'confidence': summary.get('confidence', 0.55), 'git_status': git_status, 'git_diff': None, 'git_diff_summary': git_diff_summary, 'repo_index': {'cache_path': repo_index.get('cache_path'), 'indexed_file_count': repo_index.get('indexed_file_count'), 'changed_index_entries': repo_index.get('changed_index_entries')}, 'token_budget': token_budget, 'gathered_files': {item['path']: {'tool': item['kind'], 'preview': item['preview'][:300]} for item in evidence_items}, 'evidence_items': evidence_items, 'error_lines': error_lines, 'context_summary': (summary.get('summary') or ''), 'open_questions': dedupe_strings((summary.get('open_questions') or []))[:3], 'assumptions': dedupe_strings((summary.get('assumptions') or []))[:4], 'omitted_context': {'discovered_files': len(discovered), 'selected_evidence_items': len(evidence_items), 'local_summary_model_used': bool(use_local_summary), 'analysis_depth': analysis_depth}}
    bundle['codex_packet'] = build_codex_packet(user_prompt, bundle, token_budget)
    bundle['estimated_tokens'] = estimate_tokens(bundle['codex_packet'])
    bundle['enriched_prompt'] = bundle['codex_packet']
    print(json.dumps(bundle))
