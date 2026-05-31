

"""Scout pipeline orchestration.

The pipeline runs prompt classification, project discovery, git summaries,
evidence selection, optional local model stages, and final packet construction.
"""
import json

import os
import re









from .config import *
from soma_token_savings import (
    build_estimated_context_reduction,
    build_operation_savings,
    build_task_candidate_baseline,
    build_token_savings,
    finalize_operation_savings_response_tokens,
)
from soma_language_optimizer import optimize_prompt_language
from soma_audit import (
    build_missing_evidence,
    build_prepare_audit,
    compact_response_audit,
    ensure_context,
    hash_text,
    write_audit_log_event,
    write_prepare_audit,
)


def _query_graphify_context(goal, project_root, budget=1200):
    try:
        from gateway.graphify_adapter import GraphifyAdapter

        result = GraphifyAdapter().query(goal, project_root, budget=budget, project_only=True)
    except Exception as exc:
        return {
            'graphs': [],
            'answers': [],
            'warnings': [f'graphify unavailable: {exc}'],
            'project_only': True,
        }
    if not isinstance(result, dict):
        return {
            'graphs': [],
            'answers': [],
            'warnings': ['graphify unavailable: invalid response'],
            'project_only': True,
        }
    return {
        'graphs': [str(graph) for graph in (result.get('graphs') or [])],
        'answers': [answer for answer in (result.get('answers') or []) if isinstance(answer, dict)],
        'affected': [answer for answer in (result.get('affected') or []) if isinstance(answer, dict)],
        'warnings': [str(warning) for warning in (result.get('warnings') or [])],
        'project_only': result.get('project_only', True),
    }


def _graph_context_text(graph_result):
    parts = []
    for answer in (graph_result.get('answers') or []):
        text = str(answer.get('answer') or '').strip()
        if text:
            parts.append(text)
    for answer in (graph_result.get('affected') or []):
        text = str(answer.get('answer') or '').strip()
        if text:
            parts.append(text)
    return '\n\n'.join(parts)


def _graph_suggestion_lines(graph_result, limit=3):
    suggestions = []
    for answer in (graph_result.get('answers') or []):
        text = str(answer.get('answer') or '').strip()
        if not text:
            continue
        for line in text.splitlines():
            cleaned = line.strip().lstrip('-*0123456789. ')
            if not cleaned:
                continue
            suggestions.append(cleaned[:180])
            break
        if len(suggestions) >= limit:
            break
    for answer in (graph_result.get('affected') or []):
        if len(suggestions) >= limit:
            break
        text = str(answer.get('answer') or '').strip()
        term = str(answer.get('term') or '').strip()
        if text:
            first_line = text.splitlines()[0].strip()[:150]
            prefix = f"Affected hints for {term}: " if term else "Affected hints: "
            suggestions.append((prefix + first_line)[:180])
    return suggestions[:limit]


def _graph_suggested_project_paths(graph_result, project_root, max_paths=3):
    if not project_root:
        return []
    root = os.path.normpath(project_root)
    pattern = re.compile(r'(?<![\w/.-])((?:[\w@+.-]+/)*[\w@+.-]+\.(?:swift|py|ts|tsx|js|jsx|cs|md|json|toml|yaml|yml))(?![\w.-])')
    paths = []
    for answer in list(graph_result.get('answers') or []) + list(graph_result.get('affected') or []):
        text = str(answer.get('answer') or '')
        for match in pattern.findall(text):
            candidate = match.strip().strip('`"\'.,:;()[]{}')
            candidate = candidate.replace('\\', '/')
            if not candidate:
                continue
            full_path = candidate if os.path.isabs(candidate) else os.path.join(root, candidate)
            full_path = os.path.normpath(full_path)
            if not (full_path == root or full_path.startswith(root + os.sep)):
                continue
            if os.path.isfile(full_path) and full_path not in paths:
                paths.append(full_path)
                if len(paths) >= max_paths:
                    return paths
    return paths


def _graph_hints_allowed_for_plan(collection_plan):
    required = set((collection_plan or {}).get('required_evidence') or [])
    if {'graphify_version', 'changelog'} & required:
        return False, 'graphify skipped: version/changelog tasks need command or changelog evidence, not graph node hints'
    return True, None


def _append_graph_context(packet, graph_context, token_budget, estimate_tokens_func):
    if not graph_context:
        return packet
    max_tokens = TOKEN_BUDGETS.get(token_budget, TOKEN_BUDGETS[DEFAULT_TOKEN_BUDGET])
    remaining = max(0, max_tokens - estimate_tokens_func(packet))
    if remaining < 120:
        return packet
    graph_chars = min(1500, remaining * 4)
    enriched = f'{packet}\n\nGraph context (from Graphify):\n{graph_context[:graph_chars]}'
    while estimate_tokens_func(enriched) > max_tokens and graph_chars > 300:
        graph_chars -= 200
        enriched = f'{packet}\n\nGraph context (from Graphify):\n{graph_context[:graph_chars]}'
    return enriched if estimate_tokens_func(enriched) <= max_tokens else packet


def _graph_matches_collection_scope(graph_result, collection_plan=None, preflight=None):
    from .utils import normalize_path, is_generated_dependency_path
    collection_plan = collection_plan or {}
    preflight = preflight or {}
    target_scope = collection_plan.get('target_scope')
    if not target_scope or target_scope == 'unknown':
        return False, ['graphify skipped: collection scope was unknown']
    focus_root = preflight.get('focus_root')
    graphs = graph_result.get('graphs') or []
    if not graphs:
        return False, graph_result.get('warnings') or []
    for graph in graphs:
        graph_path = str(graph)
        if is_generated_dependency_path(graph_path):
            continue
        if '/.soma/graphs/projects/' in graph_path.replace('\\', '/'):
            return True, graph_result.get('warnings') or []
        if focus_root:
            try:
                graph_parent = normalize_path(os.path.dirname(os.path.dirname(graph_path)))
                if graph_parent == normalize_path(focus_root):
                    return True, graph_result.get('warnings') or []
            except Exception:
                continue
        elif target_scope == 'whole_project':
            return True, graph_result.get('warnings') or []
    return False, ['graphify skipped: graph scope did not match collection plan']


async def run_gather(user_prompt, project_root, recent_roots_json, token_budget=DEFAULT_TOKEN_BUDGET, use_local_summary=False, analysis_depth='deterministic', packet_profile='standard', planning_mode='auto'):
    from .gather import select_evidence, gather_external_evidence, build_preflight, assess_evidence_quality, evidence_policy_summary, assess_plan_alignment, repair_evidence_from_plan, evidence_item_from_path
    from .parser import find_errors
    from .packet import bundle_for_direct_pass, estimate_tokens, build_codex_packet, build_prompt_compiler_packet
    from .classifier import classify_prompt_intent, prompt_terms
    from .collection_plan import plan_collection_with_local_model, referee_evidence_with_plan_model
    from .cloud_referee import apply_cloud_referee_to_quality, cloud_referee_should_run, referee_evidence_with_cloud_model
    from .discovery import build_repo_index, iter_project_files, detect_project_type
    from .git import get_git_diff_summary, get_git_status
    from .ranker import rank_evidence_with_model, fallback_summary, analyze_packet_with_model, summarize_with_ollama, should_use_model_summary, filter_candidates_with_model, referee_evidence_with_model, summarize_local_ai_stages
    from .utils import categorize_path, dedupe_strings, is_generated_dependency_path, parse_recent_roots, normalize_path
    if (analysis_depth not in ANALYSIS_DEPTHS):
        analysis_depth = 'deterministic'
    if packet_profile not in {'standard', 'prompt_compiler'}:
        packet_profile = 'standard'
    if planning_mode not in {'off', 'local', 'auto'}:
        planning_mode = 'auto'
    token_model_profile = os.environ.get('SOMA_TOKEN_MODEL_PROFILE', 'gpt-5.5')
    audit_context = ensure_context(workflow='packet_mode')
    (normalized_prompt, language_optimization) = optimize_prompt_language(user_prompt, token_model_profile)
    selection_prompt = ((normalized_prompt + '\n' + user_prompt) if (normalized_prompt != user_prompt) else normalized_prompt)
    write_audit_log_event('audit_start', status='ok', run_id=audit_context['run_id'], task_id=audit_context['task_id'], workflow=audit_context['workflow'], project_root=project_root, extra={'prompt_hash': hash_text(user_prompt)})
    intent = classify_prompt_intent(normalized_prompt)
    recent_roots = parse_recent_roots(recent_roots_json)
    if (not intent['needs_gather']):
        preflight = {'intent': intent, 'packet_mode': 'direct', 'confidence': intent['confidence'], 'terms': prompt_terms(selection_prompt), 'explicit_paths': [], 'changed_files': [], 'changed_paths': [], 'log_candidates': [], 'error_paths': [], 'candidate_paths': []}
        direct_bundle = bundle_for_direct_pass(normalized_prompt, intent['reason'], project_root, token_budget, analysis_depth, preflight)
        direct_bundle['language_optimization'] = language_optimization
        direct_bundle['token_savings'] = build_token_savings(
            packet=direct_bundle.get('codex_packet') or '',
            budget=token_budget,
            budget_tokens=TOKEN_BUDGETS[token_budget],
            model_profile=token_model_profile,
            warnings=['Direct prompt did not need local evidence, so no raw-context baseline was available.'],
        )
        direct_bundle['estimated_context_reduction'] = direct_bundle['token_savings'].get('estimated_context_reduction')
        direct_bundle['operation_savings'] = direct_bundle['token_savings'].get('operation_savings')
        audit_report = write_prepare_audit(build_prepare_audit(context=audit_context, status='ok', project_root=project_root, project_type=None, original_prompt=user_prompt, normalized_prompt=normalized_prompt, packet=(direct_bundle.get('codex_packet') or ''), estimated_tokens=direct_bundle.get('estimated_tokens'), evidence_items=[], missing_evidence={'status': 'ok', 'reason': intent['reason'], 'unresolved_references': [], 'found_not_selected': []}, evidence_quality={'status': 'ok', 'warnings': []}, tool_calls_expected=['Run gather again with a concrete code/debug/review goal if evidence is needed.'], language_optimization=language_optimization))
        direct_bundle['audit'] = compact_response_audit(audit_report)
        print(json.dumps(direct_bundle))
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
    terms = prompt_terms(selection_prompt)
    (project_type, type_reason) = detect_project_type(project_root)
    git_status = get_git_status(project_root)
    git_diff_summary = get_git_diff_summary(project_root, terms)
    discovered = iter_project_files(project_root)
    repo_index = build_repo_index(project_root, discovered)
    (collection_plan, collection_stage, collection_plan_source, collection_plan_warnings) = await plan_collection_with_local_model(selection_prompt, project_root, project_type, discovered, repo_index, planning_mode)
    analysis_stages = [collection_stage, {'stage': 'preflight', 'status': 'ok'}, {'stage': 'deterministic', 'status': 'ok'}]
    preflight = build_preflight(selection_prompt, project_root, project_type, discovered, repo_index, git_status, git_diff_summary, collection_plan)
    explicit_items = gather_external_evidence(selection_prompt, project_root, terms, discovered, repo_index)
    selection_limit = (MAX_EVIDENCE_ITEMS * 3) if analysis_depth in {'ranked', 'analyst'} else MAX_EVIDENCE_ITEMS
    evidence_items = (explicit_items + select_evidence(project_root, selection_prompt, project_type, repo_index, preflight, max_items=selection_limit))
    deduped_evidence = []
    seen = set()
    for item in evidence_items:
        if (item['path'] in seen):
            continue
        seen.add(item['path'])
        deduped_evidence.append(item)
        if (len(deduped_evidence) >= selection_limit):
            break
    evidence_items = deduped_evidence
    if (analysis_depth in {'ranked', 'analyst'}):
        (evidence_items, filter_stage) = (await filter_candidates_with_model(normalized_prompt, preflight, evidence_items, MAX_EVIDENCE_ITEMS))
        analysis_stages.append(filter_stage)
        (ranked_items, rank_stage) = (await rank_evidence_with_model(normalized_prompt, preflight, evidence_items))
        evidence_items = ranked_items[:MAX_EVIDENCE_ITEMS]
        analysis_stages.append(rank_stage)
    error_lines = dedupe_strings([error for item in evidence_items if (item.get('kind') == 'log') for error in find_errors(item.get('preview', ''))])[:MAX_ERROR_LINES]
    evidence_quality = assess_evidence_quality(selection_prompt, evidence_items, preflight)
    evidence_quality.update(assess_plan_alignment(collection_plan, evidence_items, preflight))
    if planning_mode in {'local', 'auto'}:
        (evidence_referee, evidence_referee_stage) = await referee_evidence_with_plan_model(selection_prompt, collection_plan, evidence_items, evidence_quality)
        analysis_stages.append(evidence_referee_stage)
        (repaired_items, repair_additions) = repair_evidence_from_plan(project_root, selection_prompt, project_type, evidence_items, collection_plan, preflight, evidence_referee, repo_index, max_additions=3)
        if repair_additions:
            evidence_items = (evidence_items[:max(0, MAX_EVIDENCE_ITEMS - len(repair_additions))] + repair_additions)[:MAX_EVIDENCE_ITEMS]
            error_lines = dedupe_strings([error for item in evidence_items if (item.get('kind') == 'log') for error in find_errors(item.get('preview', ''))])[:MAX_ERROR_LINES]
            evidence_quality = assess_evidence_quality(selection_prompt, evidence_items, preflight)
            evidence_quality.update(assess_plan_alignment(collection_plan, evidence_items, preflight))
            analysis_stages.append({
                'stage': 'evidence_repair',
                'status': 'ok',
                'candidate_count_after': len(evidence_items),
                'notes': [f"Added {len(repair_additions)} evidence item(s) from collection plan repair."],
            })
    if cloud_referee_should_run(evidence_quality):
        (cloud_referee, cloud_referee_stage) = await referee_evidence_with_cloud_model(selection_prompt, collection_plan, preflight, evidence_items, evidence_quality)
        analysis_stages.append(cloud_referee_stage)
        if cloud_referee:
            (repaired_items, repair_additions) = repair_evidence_from_plan(project_root, selection_prompt, project_type, evidence_items, collection_plan, preflight, cloud_referee, repo_index, max_additions=3)
            if repair_additions:
                evidence_items = (evidence_items[:max(0, MAX_EVIDENCE_ITEMS - len(repair_additions))] + repair_additions)[:MAX_EVIDENCE_ITEMS]
                error_lines = dedupe_strings([error for item in evidence_items if (item.get('kind') == 'log') for error in find_errors(item.get('preview', ''))])[:MAX_ERROR_LINES]
                evidence_quality = assess_evidence_quality(selection_prompt, evidence_items, preflight)
                evidence_quality.update(assess_plan_alignment(collection_plan, evidence_items, preflight))
                analysis_stages.append({
                    'stage': 'cloud_evidence_repair',
                    'status': 'ok',
                    'candidate_count_after': len(evidence_items),
                    'notes': [f"Added {len(repair_additions)} evidence item(s) from cloud referee repair."],
                })
            evidence_quality = apply_cloud_referee_to_quality(evidence_quality, cloud_referee)
    model_analysis = None
    if (analysis_depth == 'analyst'):
        (model_analysis, analyst_stage) = (await analyze_packet_with_model(normalized_prompt, preflight, evidence_items, error_lines))
        analysis_stages.append(analyst_stage)
    summary = fallback_summary(normalized_prompt, project_root, project_type, evidence_items, error_lines, preflight['packet_mode'])
    if use_local_summary:
        model_summary = (await summarize_with_ollama(normalized_prompt, project_root, project_type, evidence_items, error_lines))
        if should_use_model_summary(model_summary):
            summary['summary'] = (model_summary.get('summary') or summary['summary'])
            summary['assumptions'] = dedupe_strings((summary.get('assumptions', []) + list((model_summary.get('assumptions') or []))))[:4]
            summary['open_questions'] = dedupe_strings((summary.get('open_questions', []) + list((model_summary.get('open_questions') or []))))[:4]
            summary['confidence'] = max(summary.get('confidence', 0.55), model_summary.get('confidence', 0.55))
    if (type_reason not in summary['assumptions']):
        summary['assumptions'] = ([type_reason] + list((summary.get('assumptions') or [])))
    if (recent_roots and (project_root not in recent_roots)):
        summary['assumptions'].append('Selected project root was used as the authoritative scope for gathering.')
    policy_summary = evidence_policy_summary(evidence_items, project_root, project_type)
    if policy_summary['warnings']:
        evidence_quality['warnings'] = dedupe_strings((evidence_quality.get('warnings') or []) + policy_summary['warnings'])[:10]
    if analysis_depth in {'ranked', 'analyst'} and not any(stage.get('stage') == 'ranker' and stage.get('status') == 'failed' for stage in analysis_stages if isinstance(stage, dict)):
        (evidence_quality, referee_stage) = (await referee_evidence_with_model(normalized_prompt, preflight, evidence_items, evidence_quality))
        analysis_stages.append(referee_stage)
    local_ai_metrics = summarize_local_ai_stages(analysis_stages)
    graph_result = _query_graphify_context(normalized_prompt, project_root, budget=1200)
    (graph_allowed, graph_policy_warning) = _graph_hints_allowed_for_plan(collection_plan)
    graph_scope_warnings = []
    if graph_allowed:
        (graph_allowed, graph_scope_warnings) = _graph_matches_collection_scope(graph_result, collection_plan, preflight)
    if not graph_allowed:
        graph_result = {
            **graph_result,
            'answers': [],
            'warnings': dedupe_strings((graph_result.get('warnings') or []) + ([graph_policy_warning] if graph_policy_warning else []) + graph_scope_warnings),
        }
    graph_suggestions = _graph_suggestion_lines(graph_result) if graph_allowed and packet_profile != 'prompt_compiler' else []
    graph_suggested_paths = []
    if graph_allowed and packet_profile != 'prompt_compiler':
        selected_paths = {normalize_path(item.get('path')) for item in evidence_items if item.get('path')}
        for path in _graph_suggested_project_paths(graph_result, project_root, max_paths=3):
            if is_generated_dependency_path(path, project_root):
                continue
            normalized_path = normalize_path(path)
            if normalized_path in selected_paths:
                graph_suggested_paths.append(normalized_path)
                continue
            category = categorize_path(normalized_path)
            if not category:
                continue
            item = evidence_item_from_path(
                normalized_path,
                category,
                'Included because Graphify suggested this file as related to the task.',
                prompt_terms(normalized_prompt),
            )
            if len(evidence_items) >= MAX_EVIDENCE_ITEMS:
                evidence_items = evidence_items[:-1] + [item]
            else:
                evidence_items.append(item)
            selected_paths.add(normalized_path)
            graph_suggested_paths.append(normalized_path)
        if graph_suggested_paths:
            error_lines = dedupe_strings([error for item in evidence_items if (item.get('kind') == 'log') for error in find_errors(item.get('preview', ''))])[:MAX_ERROR_LINES]
            evidence_quality = assess_evidence_quality(selection_prompt, evidence_items, preflight)
            evidence_quality.update(assess_plan_alignment(collection_plan, evidence_items, preflight))
            policy_summary = evidence_policy_summary(evidence_items, project_root, project_type)
    bundle = {
        'mode': 'gather',
        'status': evidence_quality['status'],
        'original_prompt': (user_prompt if language_optimization.get('source_language') == 'en' else None),
        'normalized_prompt': normalized_prompt,
        'language_optimization': language_optimization,
        'project_root': project_root,
        'project_type': project_type,
        'routing_decision': 'gathered_and_relayed',
        'packet_profile': packet_profile,
        'packet_mode': preflight['packet_mode'],
        'analysis_depth': analysis_depth,
        'analysis_stages': analysis_stages,
        'local_ai_metrics': local_ai_metrics,
        'collection_plan': collection_plan,
        'collection_plan_source': collection_plan_source,
        'collection_plan_warnings': collection_plan_warnings,
        'preflight': {key: value for (key, value) in preflight.items() if (key not in {'changed_paths', 'error_paths', 'candidate_paths'})},
        'model_analysis': model_analysis,
        'gather_reason': intent['reason'],
        'confidence': summary.get('confidence', 0.55),
        'git_status': git_status,
        'git_diff': None,
        'git_diff_summary': git_diff_summary,
        'repo_index': {
            'cache_path': repo_index.get('cache_path'),
            'indexed_file_count': repo_index.get('indexed_file_count'),
            'changed_index_entries': repo_index.get('changed_index_entries'),
        },
        'token_budget': token_budget,
        'gathered_files': {item['path']: {'tool': item['kind'], 'preview': item['preview'][:300]} for item in evidence_items},
        'evidence_items': evidence_items,
        'evidence_quality': evidence_quality,
        'error_lines': error_lines,
        'context_summary': (summary.get('summary') or ''),
        'graph_suggestions': graph_suggestions,
        'open_questions': dedupe_strings(
            ([f"Missing required evidence: {', '.join((evidence_quality.get('missing_required_evidence') or [])[:3])}."]
             if evidence_quality.get('missing_required_evidence') else [])
            + (summary.get('open_questions') or [])
        )[:3],
        'assumptions': dedupe_strings((summary.get('assumptions') or []))[:4],
        'omitted_context': {
            'discovered_files': len(discovered),
            'selected_evidence_items': len(evidence_items),
            'local_summary_model_used': bool(use_local_summary),
            'analysis_depth': analysis_depth,
            'graph_answers': len(graph_result.get('answers') or []),
            'graph_suggested_files': graph_suggested_paths[:5],
            'graph_warnings': (graph_result.get('warnings') or [])[:2],
            'graphify': 'project_only' if graph_result.get('graphs') else 'skipped',
            'evidence_quality': evidence_quality,
            'evidence_policy': policy_summary,
            **local_ai_metrics,
        },
    }
    bundle['omitted_context']['graphify'] = 'project_only' if graph_allowed and graph_result.get('graphs') else 'skipped'
    bundle.update(local_ai_metrics)
    if packet_profile == 'prompt_compiler':
        bundle['codex_packet'] = build_prompt_compiler_packet(normalized_prompt, bundle, token_budget)
    else:
        bundle['codex_packet'] = build_codex_packet(normalized_prompt, bundle, token_budget)
    bundle['estimated_tokens'] = estimate_tokens(bundle['codex_packet'])
    task_baseline = build_task_candidate_baseline(
        project_root=project_root,
        discovered=discovered,
        preflight=preflight,
        evidence_items=evidence_items,
        git_status=git_status,
        git_diff_summary=git_diff_summary,
        model_profile=token_model_profile,
        packet_tokens=bundle['estimated_tokens'],
    )
    estimated_context_reduction = build_estimated_context_reduction(
        packet=bundle['codex_packet'],
        budget=token_budget,
        budget_tokens=TOKEN_BUDGETS[token_budget],
        model_profile=token_model_profile,
        task_candidate_baseline=task_baseline,
    )
    operation_savings = build_operation_savings(
        packet=bundle['codex_packet'],
        project_root=project_root,
        git_status=git_status,
        evidence_items=evidence_items,
        budget=token_budget,
        budget_tokens=TOKEN_BUDGETS[token_budget],
        model_profile=token_model_profile,
    )
    bundle['token_savings'] = build_token_savings(
        packet=bundle['codex_packet'],
        budget=token_budget,
        budget_tokens=TOKEN_BUDGETS[token_budget],
        model_profile=token_model_profile,
        estimated_context_reduction=estimated_context_reduction,
        operation_savings=operation_savings,
    )
    bundle['estimated_context_reduction'] = estimated_context_reduction
    bundle['operation_savings'] = operation_savings
    next_calls = ['Use packet first.', 'Call soma_code_context for 1 focused missing area.']
    missing_evidence = build_missing_evidence(original_prompt=user_prompt, normalized_prompt=normalized_prompt, project_root=project_root, discovered=discovered, repo_index=repo_index, evidence_items=evidence_items, preflight=preflight, evidence_quality=evidence_quality, graph_result=graph_result, analysis_stages=analysis_stages, next_calls=next_calls)
    audit_report = write_prepare_audit(build_prepare_audit(context=audit_context, status=('ok' if (evidence_quality['status'] == 'ok' and missing_evidence['status'] == 'ok') else 'degraded'), project_root=project_root, project_type=project_type, original_prompt=user_prompt, normalized_prompt=normalized_prompt, packet=bundle['codex_packet'], estimated_tokens=bundle.get('estimated_tokens'), evidence_items=evidence_items, missing_evidence=missing_evidence, evidence_quality=evidence_quality, tool_calls_expected=next_calls, language_optimization=language_optimization))
    bundle['audit'] = compact_response_audit(audit_report)
    bundle['enriched_prompt'] = bundle['codex_packet']
    operation_savings = finalize_operation_savings_response_tokens(operation_savings, estimate_tokens(json.dumps(bundle)))
    bundle['operation_savings'] = operation_savings
    bundle['token_savings'] = build_token_savings(
        packet=bundle['codex_packet'],
        budget=token_budget,
        budget_tokens=TOKEN_BUDGETS[token_budget],
        model_profile=token_model_profile,
        estimated_context_reduction=estimated_context_reduction,
        operation_savings=operation_savings,
    )
    print(json.dumps(bundle))
