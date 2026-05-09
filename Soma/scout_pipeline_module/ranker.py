



import json






from pathlib import Path




from .config import *


def fallback_summary(prompt, project_root, project_type, evidence_items, error_lines, packet_mode='debug'):
    assumptions = []
    open_questions = []
    script_candidates = [item for item in evidence_items if (item['kind'] == 'script')]
    if (('script' in prompt.lower()) and script_candidates):
        assumptions.append(f"Assumed `{Path(script_candidates[0]['path']).name}` is the most relevant script based on ranking.")
        if (len(script_candidates) > 1):
            open_questions.append('Multiple script candidates were found; confirm the exact entry point if needed.')
    if (not error_lines):
        open_questions.append('No explicit error lines were found in the selected excerpts.')
    if (not any(((item['kind'] == 'log') for item in evidence_items))):
        open_questions.append('No repo-local logs were found; a runtime log path may still be needed.')
    summary = f'Prepared a {packet_mode} packet with {len(evidence_items)} targeted evidence item(s) from the {project_type} project at `{project_root}`.'
    confidence = (0.72 if error_lines else 0.58)
    return {'summary': summary, 'assumptions': assumptions[:3], 'open_questions': open_questions[:3], 'confidence': confidence}


def should_use_model_summary(model_summary):
    if (not model_summary):
        return False
    summary_text = (model_summary.get('summary') or '').lower()
    if (model_summary.get('confidence', 0) < 0.35):
        return False
    if (('not working as expected' in summary_text) or ('seems' in summary_text)):
        return False
    return True


async def summarize_with_ollama(prompt, project_root, project_type, evidence_items, error_lines):
    from .llama import query_ollama
    from .parser import extract_json_object
    summary_payload = {'prompt': prompt, 'project_root': project_root, 'project_type': project_type, 'evidence': [{'path': item['path'], 'kind': item['kind'], 'reason': item['reason'], 'preview': item['preview'][:700]} for item in evidence_items], 'error_lines': error_lines[:MAX_ERROR_LINES]}
    response = (await query_ollama([{'role': 'system', 'content': OLLAMA_SUMMARY_SYSTEM}, {'role': 'user', 'content': json.dumps(summary_payload)}], timeout=OLLAMA_SUMMARY_TIMEOUT))
    if ('error' in response):
        return None
    content = response.get('message', {}).get('content', '')
    decoded = extract_json_object(content)
    if (not isinstance(decoded, dict)):
        return None
    confidence = decoded.get('confidence')
    if (not isinstance(confidence, (int, float))):
        confidence = 0.55
    return {'summary': (decoded.get('summary') or ''), 'assumptions': (decoded.get('assumptions') or []), 'open_questions': (decoded.get('open_questions') or []), 'confidence': max(0.0, min(1.0, float(confidence)))}


def ranker_payload(prompt, preflight, evidence_items):
    return {'prompt': prompt, 'packet_mode': preflight.get('packet_mode'), 'terms': (preflight.get('terms') or []), 'candidates': [{'id': index, 'path': item.get('path'), 'kind': item.get('kind'), 'reason': item.get('reason'), 'symbols': (item.get('symbols') or []), 'preview': (item.get('preview') or '')[:220]} for (index, item) in enumerate(evidence_items)]}


async def rank_evidence_with_model(prompt, preflight, evidence_items):
    from .llama import query_ollama_model
    from .parser import extract_json_object
    if (not evidence_items):
        return (evidence_items, {'stage': 'ranker', 'model': RANKER_MODEL, 'status': 'skipped'})
    decoded = None
    last_error = 'invalid ranker JSON'
    payload = json.dumps(ranker_payload(prompt, preflight, evidence_items))
    prompts = ['Rank small evidence candidates for a Codex packet. Return JSON only: {"ordered_ids":[0,1],"notes":["..."]}. Use only candidate ids.', 'Return only minified JSON with this exact schema: {"ordered_ids":[0,1]}. Use integer candidate ids only. No notes.']
    for (attempt, system) in enumerate(prompts, start=1):
        response = (await query_ollama_model(RANKER_MODEL, [{'role': 'system', 'content': system}, {'role': 'user', 'content': payload}], timeout=25, num_predict=(180 if (attempt == 1) else 96), json_mode=True))
        if ('error' in response):
            return (evidence_items, {'stage': 'ranker', 'model': RANKER_MODEL, 'status': 'failed', 'error': response['error']})
        decoded = extract_json_object(response.get('message', {}).get('content', ''))
        if (isinstance(decoded, dict) and isinstance(decoded.get('ordered_ids'), list)):
            break
        last_error = f'invalid ranker JSON after attempt {attempt}'
    if ((not isinstance(decoded, dict)) or (not isinstance(decoded.get('ordered_ids'), list))):
        return (evidence_items, {'stage': 'ranker', 'model': RANKER_MODEL, 'status': 'failed', 'error': last_error})
    ordered = []
    seen = set()
    for raw_id in decoded.get('ordered_ids', []):
        if ((not isinstance(raw_id, int)) or (raw_id < 0) or (raw_id >= len(evidence_items)) or (raw_id in seen)):
            continue
        seen.add(raw_id)
        ordered.append(evidence_items[raw_id])
    ordered.extend((item for (index, item) in enumerate(evidence_items) if (index not in seen)))
    return (ordered, {'stage': 'ranker', 'model': RANKER_MODEL, 'status': 'ok', 'notes': (decoded.get('notes') or [])})


async def analyze_packet_with_model(prompt, preflight, evidence_items, error_lines):
    from .llama import query_ollama_model
    from .parser import extract_json_object
    payload = {'prompt': prompt, 'packet_mode': preflight.get('packet_mode'), 'evidence': [{'path': item.get('path'), 'kind': item.get('kind'), 'reason': item.get('reason'), 'preview': (item.get('preview') or '')[:500]} for item in evidence_items], 'error_lines': error_lines[:MAX_ERROR_LINES]}
    decoded = None
    last_error = 'invalid analyst JSON'
    user_payload = json.dumps(payload)
    prompts = ['Analyze a compact evidence packet. Return JSON only with {"hypotheses":["..."],"missing_context":["..."]}. Do not invent facts.', 'Return only minified JSON with this exact schema: {"hypotheses":["..."],"missing_context":["..."]}. Use only facts from the provided packet.']
    for (attempt, system) in enumerate(prompts, start=1):
        response = (await query_ollama_model(ANALYST_MODEL, [{'role': 'system', 'content': system}, {'role': 'user', 'content': user_payload}], timeout=45, num_predict=280, json_mode=True))
        if ('error' in response):
            return (None, {'stage': 'analyst', 'model': ANALYST_MODEL, 'status': 'failed', 'error': response['error']})
        decoded = extract_json_object(response.get('message', {}).get('content', ''))
        if isinstance(decoded, dict):
            break
        last_error = f'invalid analyst JSON after attempt {attempt}'
    if (not isinstance(decoded, dict)):
        return (None, {'stage': 'analyst', 'model': ANALYST_MODEL, 'status': 'failed', 'error': last_error})
    return (decoded, {'stage': 'analyst', 'model': ANALYST_MODEL, 'status': 'ok'})


def format_preflight(preflight):
    if (not preflight):
        return []
    lines = [f"- Mode: {preflight.get('packet_mode', 'direct')}", f"- Intent confidence: {preflight.get('confidence', 0):.2f}"]
    if preflight.get('explicit_paths'):
        lines.append(f"- Explicit paths: {len(preflight['explicit_paths'])}")
    if preflight.get('changed_files'):
        lines.append(f"- Changed files considered: {len(preflight['changed_files'])}")
    if preflight.get('log_candidates'):
        lines.append(f"- Log candidates considered: {len(preflight['log_candidates'])}")
    return lines


def format_model_analysis(model_analysis):
    if (not model_analysis):
        return []
    lines = []
    hypotheses = (model_analysis.get('hypotheses') or [])
    missing = (model_analysis.get('missing_context') or [])
    if hypotheses:
        lines.append('Local analyst hypotheses:')
        lines.extend((f'- {item}' for item in hypotheses[:4]))
    if missing:
        lines.append('Local analyst missing context:')
        lines.extend((f'- {item}' for item in missing[:4]))
    return lines
