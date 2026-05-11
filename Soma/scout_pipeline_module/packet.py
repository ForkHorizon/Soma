











"""Packet construction and token budget enforcement.

This stage converts selected evidence into the compact prompt packet sent to
Big AI, tracks omitted context, and falls back to approximate token estimates.
"""
from .config import *
try:
    from token_calculator import estimate_tokens as _profile_estimate_tokens
except Exception:
    _profile_estimate_tokens = None


try:
    import tiktoken
    _enc = tiktoken.get_encoding("cl100k_base")
except Exception:
    _enc = None


def estimate_tokens(text):
    if _enc is not None:
        try:
            return max(1, len(_enc.encode(text, allowed_special="all")))
        except Exception:
            pass
    if _profile_estimate_tokens is not None:
        try:
            return _profile_estimate_tokens(text, 'fallback')
        except Exception:
            pass
    return max(1, int((len(text) / 4)))


def build_omitted_context(bundle):
    omitted = dict((bundle.get('omitted_context') or {}))
    diff_summary = (bundle.get('git_diff_summary') or {})
    if diff_summary.get('raw_diff_chars_omitted'):
        omitted['raw_git_diff_chars'] = diff_summary['raw_diff_chars_omitted']
    repo_index = (bundle.get('repo_index') or {})
    indexed_count = repo_index.get('indexed_file_count')
    evidence_count = len((bundle.get('evidence_items') or []))
    if (indexed_count is not None):
        omitted['indexed_files_not_in_packet'] = max(0, (indexed_count - evidence_count))
    return omitted


def build_codex_packet(user_prompt, bundle, token_budget=DEFAULT_TOKEN_BUDGET):
    from .parser import format_line_range
    from .git import format_git_diff_summary
    from .ranker import format_model_analysis, format_preflight
    max_tokens = TOKEN_BUDGETS.get(token_budget, TOKEN_BUDGETS[DEFAULT_TOKEN_BUDGET])
    evidence_items = list((bundle.get('evidence_items') or []))
    preview_chars = 900
    while True:
        parts = ['Goal:', user_prompt.strip(), '', 'Use only the evidence below first. If insufficient, ask for exactly 1-3 missing files or commands.', '', 'Known facts:', f"- Project root: {(bundle.get('project_root') or '[not selected]')}", f"- Project type: {(bundle.get('project_type') or 'unknown')}", f"- Route: {bundle.get('routing_decision')}", f"- Packet mode: {bundle.get('packet_mode', 'direct')}", f"- Analysis depth: {bundle.get('analysis_depth', 'deterministic')}", f"- Confidence: {bundle.get('confidence', 0):.2f}", f'- Token budget: {token_budget} <= {max_tokens} estimated tokens']
        preflight_lines = format_preflight(bundle.get('preflight'))
        if preflight_lines:
            parts.extend(['', 'Preflight:'])
            parts.extend(preflight_lines)
        if bundle.get('context_summary'):
            parts.extend(['', 'Summary:', bundle['context_summary']])
        assumptions = (bundle.get('assumptions') or [])
        if assumptions:
            parts.append('')
            parts.append('Assumptions:')
            parts.extend((f'- {item}' for item in assumptions[:5]))
        git_status = bundle.get('git_status')
        if git_status:
            parts.extend(['', 'Git status:', git_status])
        diff_lines = format_git_diff_summary(bundle.get('git_diff_summary'))
        if diff_lines:
            parts.extend(['', 'Git diff summary:'])
            parts.extend(diff_lines)
        error_lines = (bundle.get('error_lines') or [])
        if error_lines:
            parts.extend(['', 'Normalized errors:'])
            parts.extend((f'- {line}' for line in error_lines[:MAX_ERROR_LINES]))
        if evidence_items:
            parts.extend(['', 'Evidence:'])
            for (index, item) in enumerate(evidence_items, start=1):
                line_range = format_line_range(item)
                parts.extend([f"{index}. {item.get('path', '[unknown]')}{line_range} [{item.get('kind', 'file')}]", f"   Reason: {item.get('reason', '')}"])
                if item.get('symbols'):
                    parts.append(f"   Symbols: {', '.join(item['symbols'][:8])}")
                if item.get('unity_refs'):
                    parts.append(f"   Unity refs: {', '.join(item['unity_refs'][:5])}")
                preview = (item.get('preview') or '')[:preview_chars].strip()
                parts.extend(['   Snippet:', indent_block((preview or '[No preview available]'), '   ')])
        analysis_lines = format_model_analysis(bundle.get('model_analysis'))
        if analysis_lines:
            parts.extend(['', 'Optional local analysis:'])
            parts.extend(analysis_lines)
        open_questions = (bundle.get('open_questions') or [])
        if open_questions:
            parts.extend(['', 'Open questions:'])
            parts.extend((f'- {item}' for item in open_questions[:4]))
        omitted = build_omitted_context(bundle)
        if omitted:
            parts.extend(['', 'Omitted context:'])
            parts.extend((f'- {key}: {value}' for (key, value) in omitted.items()))
        parts.extend(['', 'Expected Codex behavior:', '- Diagnose from this packet first.', '- Request at most 1-3 extra files/commands if blocked.', '- Do not refactor unrelated code.'])
        packet = '\n'.join(parts).strip()
        if ((estimate_tokens(packet) <= max_tokens) or ((len(evidence_items) <= 3) and (preview_chars <= 450))):
            return packet
        if (preview_chars > 450):
            preview_chars -= 150
        else:
            evidence_items = evidence_items[:max(3, (len(evidence_items) - 1))]


def indent_block(text, prefix):
    return '\n'.join(((prefix + line) for line in text.splitlines()))


def build_enriched_prompt(user_prompt, bundle):
    return build_codex_packet(user_prompt, bundle, bundle.get('token_budget', DEFAULT_TOKEN_BUDGET))


def bundle_for_direct_pass(prompt, reason, project_root=None, token_budget=DEFAULT_TOKEN_BUDGET, analysis_depth='deterministic', preflight=None):
    packet = prompt.strip()
    return {'mode': 'gather', 'original_prompt': prompt, 'project_root': project_root, 'project_type': None, 'routing_decision': 'direct_pass_through', 'packet_mode': 'direct', 'analysis_depth': analysis_depth, 'analysis_stages': [{'stage': 'preflight', 'status': 'direct'}], 'preflight': preflight, 'gather_reason': reason, 'confidence': 1.0, 'gathered_files': {}, 'evidence_items': [], 'error_lines': [], 'context_summary': 'No evidence gathered; packet contains only the prompt.', 'open_questions': [], 'assumptions': [], 'git_status': None, 'git_diff': None, 'git_diff_summary': None, 'repo_index': None, 'token_budget': token_budget, 'estimated_tokens': estimate_tokens(packet), 'omitted_context': {}, 'codex_packet': packet, 'enriched_prompt': packet}
