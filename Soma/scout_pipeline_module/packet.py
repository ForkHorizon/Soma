











"""Packet construction and token budget enforcement.

This stage converts selected evidence into the compact prompt packet sent to
Big AI, tracks omitted context, and falls back to approximate token estimates.
"""
from .config import *
import re
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


def _source_match_terms(user_prompt, item):
    terms = []
    terms.extend(re.findall(r'[A-Za-z_][A-Za-z0-9_]{2,}', user_prompt or ''))
    terms.extend(_as_string_list(item.get('symbols')))
    path = str(item.get('path') or '')
    if path:
        terms.append(path.rsplit('/', 1)[-1].split('.', 1)[0])
    seen = set()
    cleaned = []
    for term in terms:
        lowered = str(term).lower()
        if len(lowered) < 3 or lowered in seen:
            continue
        seen.add(lowered)
        cleaned.append(lowered)
    return cleaned


def _source_declaration_line(line):
    return bool(re.search(r'\b(func|function|def|class|struct|enum|protocol|extension|actor)\b', line))


def _line_indent(line):
    return len(line) - len(line.lstrip(' '))


def _extract_python_block(lines, start, limit):
    base_indent = _line_indent(lines[start])
    end = start + 1
    while end < len(lines) and end - start < 160:
        line = lines[end]
        if line.strip() and _line_indent(line) <= base_indent and not line.lstrip().startswith(('#', '@')):
            break
        end += 1
    return '\n'.join(lines[start:end])[:limit].strip()


def _extract_brace_block(lines, start, limit):
    balance = 0
    seen_open = False
    collected = []
    for index in range(start, min(len(lines), start + 180)):
        line = lines[index]
        collected.append(line)
        for char in line:
            if char == '{':
                balance += 1
                seen_open = True
            elif char == '}' and seen_open:
                balance -= 1
        if seen_open and balance <= 0:
            rendered = '\n'.join(collected).strip()
            return rendered if len(rendered) <= limit else rendered[:limit].rstrip()
    return None


def _focused_source_preview(user_prompt, item, limit):
    path = item.get('path')
    if not path:
        return None
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            text = handle.read(120000)
    except Exception:
        return None
    lines = text.splitlines()
    if not lines:
        return None
    terms = _source_match_terms(user_prompt, item)
    match_index = None
    for index, line in enumerate(lines):
        lowered = line.lower()
        if any(term in lowered for term in terms):
            match_index = index
            break
    if match_index is None:
        start = max(0, int(item.get('start_line') or 1) - 1)
        match_index = min(start, len(lines) - 1)

    declaration_start = None
    for index in range(match_index, max(-1, match_index - 60), -1):
        if _source_declaration_line(lines[index]):
            declaration_start = index
            break
    if declaration_start is not None:
        if re.search(r'^\s*(?:async\s+)?def\b', lines[declaration_start]):
            block = _extract_python_block(lines, declaration_start, limit)
        else:
            block = _extract_brace_block(lines, declaration_start, limit)
        if block:
            return block

    start = max(0, match_index - 30)
    end = min(len(lines), match_index + 70)
    return '\n'.join(lines[start:end])[:limit].strip()


def build_codex_packet(user_prompt, bundle, token_budget=DEFAULT_TOKEN_BUDGET):
    from .parser import format_line_range
    from .git import format_git_diff_summary
    from .ranker import format_model_analysis, format_preflight
    max_tokens = TOKEN_BUDGETS.get(token_budget, TOKEN_BUDGETS[DEFAULT_TOKEN_BUDGET])
    evidence_items = list((bundle.get('evidence_items') or []))
    preview_chars = 900
    while True:
        language_optimization = bundle.get('language_optimization') or {}
        parts = ['Goal:', user_prompt.strip(), '', 'Use only the evidence below first. If insufficient, ask for exactly 1-3 missing files or commands.', '', 'Known facts:', f"- Project root: {(bundle.get('project_root') or '[not selected]')}", f"- Project type: {(bundle.get('project_type') or 'unknown')}", f"- Route: {bundle.get('routing_decision')}", f"- Packet mode: {bundle.get('packet_mode', 'direct')}", f"- Analysis depth: {bundle.get('analysis_depth', 'deterministic')}", f"- Confidence: {bundle.get('confidence', 0):.2f}", f'- Token budget: {token_budget} <= {max_tokens} estimated tokens']
        if language_optimization:
            source_language = language_optimization.get('source_language')
            status = language_optimization.get('status')
            if source_language and source_language != 'en':
                parts.extend([
                    f"- Original language: {source_language}",
                    f"- Language optimization: {status}",
                    "- Expected answer language: English",
                ])
        preflight_lines = format_preflight(bundle.get('preflight'))
        if preflight_lines:
            parts.extend(['', 'Preflight:'])
            parts.extend(preflight_lines)
        if bundle.get('context_summary'):
            parts.extend(['', 'Summary:', bundle['context_summary']])
        graph_suggestions = [str(item).strip() for item in (bundle.get('graph_suggestions') or []) if str(item).strip()]
        graph_suggested_files = [
            str(path).strip()
            for path in ((bundle.get('omitted_context') or {}).get('graph_suggested_files') or [])
            if str(path).strip()
        ]
        if graph_suggestions or graph_suggested_files:
            parts.extend(['', 'Graph suggested:'])
            if graph_suggested_files:
                selected_total = len(evidence_items)
                parts.append(f"- Files {min(len(graph_suggested_files), selected_total)}/{selected_total}: graph query/affected hints boosted project-local evidence only.")
            parts.extend((f'- {item}' for item in graph_suggestions[:3]))
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
            source_preview_count = 0
            for (index, item) in enumerate(evidence_items, start=1):
                line_range = format_line_range(item)
                parts.extend([f"{index}. {item.get('path', '[unknown]')}{line_range} [{item.get('kind', 'file')}]", f"   Reason: {item.get('reason', '')}"])
                if item.get('symbols'):
                    parts.append(f"   Symbols: {', '.join(item['symbols'][:8])}")
                if item.get('unity_refs'):
                    parts.append(f"   Unity refs: {', '.join(item['unity_refs'][:5])}")
                preview_limit = preview_chars
                preview = None
                if item.get('kind') == 'source':
                    source_preview_count += 1
                    if source_preview_count <= 3:
                        preview_limit = preview_chars + 700
                        preview = _focused_source_preview(user_prompt, item, preview_limit)
                if not preview:
                    preview = (item.get('preview') or '')[:preview_limit].strip()
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
        parts.extend(['', 'Expected Codex behavior:', '- Diagnose from this packet first.', '- Answer in English.', '- Request at most 1-3 extra files/commands if blocked.', '- Do not refactor unrelated code.'])
        packet = '\n'.join(parts).strip()
        if ((estimate_tokens(packet) <= max_tokens) or ((len(evidence_items) <= 3) and (preview_chars <= 450))):
            return packet
        if (preview_chars > 450):
            preview_chars -= 150
        else:
            evidence_items = evidence_items[:max(3, (len(evidence_items) - 1))]


def build_prompt_compiler_packet(user_prompt, bundle, token_budget=DEFAULT_TOKEN_BUDGET):
    from .parser import format_line_range
    from .ranker import format_model_analysis
    from .classifier import is_open_source_readiness_prompt

    max_tokens = TOKEN_BUDGETS.get(token_budget, TOKEN_BUDGETS[DEFAULT_TOKEN_BUDGET])
    open_source_review = is_open_source_readiness_prompt(user_prompt)
    evidence_items = _focused_prompt_compiler_evidence(user_prompt, bundle)
    preview_chars = 1100
    while True:
        if open_source_review:
            task_lines = [
                '- Perform an open-source readiness review of the inferred package scope first.',
                '- Treat the wrapper Unity project as context only unless evidence shows it affects the package release.',
                '- Identify strengths, weak points, release blockers, and missing docs/tests/security/licensing work.',
                '- If this is still insufficient, ask for exactly 1-3 missing files or commands.',
            ]
            expected_lines = [
                '- Confirm the package scope being reviewed.',
                '- List strengths and weak spots separately.',
                '- Give a prioritized pre-release checklist.',
                '- Point to the exact evidence lines/files used.',
            ]
        else:
            task_lines = [
                '- Diagnose this using only the focused local evidence below first.',
                '- If this is still insufficient, ask for exactly 1-3 missing files or commands.',
                '- Ignore unrelated repository changes unless they directly affect this issue.',
            ]
            expected_lines = [
                '- Explain the most likely cause.',
                '- Point to the exact evidence lines/files used.',
                '- Give the smallest verification or fix plan.',
            ]
        parts = [
            'Goal:',
            user_prompt.strip(),
            '',
            'Task for the large model:',
            *task_lines,
            '',
            'Project:',
            f"- Root: {bundle.get('project_root') or '[not selected]'}",
            f"- Type: {bundle.get('project_type') or 'unknown'}",
        ]
        preflight = bundle.get('preflight') or {}
        if preflight.get('focus_root'):
            parts.extend([
                f"- Focus: {preflight.get('focus_root')}",
                f"- Focus type: {preflight.get('focus_kind') or 'package'}",
            ])
            if preflight.get('focus_reason'):
                parts.append(f"- Focus reason: {preflight.get('focus_reason')}")
        plan_lines = _format_collection_plan(bundle.get('collection_plan'), bundle.get('collection_plan_source'))
        if plan_lines:
            parts.extend(['', 'Collection Plan:'])
            parts.extend(plan_lines)
        if evidence_items:
            parts.extend(['', 'Focused Evidence:'])
            for (index, item) in enumerate(evidence_items, start=1):
                line_range = format_line_range(item)
                parts.append(f"{index}. {item.get('path', '[unknown]')}{line_range}")
                reason = (item.get('reason') or '').strip()
                if reason:
                    parts.append(f"   Why it matters: {reason}")
                if str(item.get('path') or '').lower().endswith('.png.meta'):
                    parts.append(f"   Asset file: {str(item.get('path'))[:-5]}")
                    meta_guid = _unity_meta_guid(item.get('path'))
                    if meta_guid:
                        parts.append(f"   Meta GUID: {meta_guid}")
                if item.get('unity_refs'):
                    parts.append(f"   Unity refs: {', '.join(item['unity_refs'][:5])}")
                preview = (item.get('preview') or '')[:preview_chars].strip()
                parts.extend(['   Relevant excerpt:', indent_block((preview or '[No preview available]'), '   ')])
        analysis_lines = format_model_analysis(bundle.get('model_analysis'))
        if analysis_lines:
            parts.extend(['', 'Local Analyst Notes:'])
            parts.extend(analysis_lines)
        missing = _prompt_compiler_missing_context(bundle)
        warnings = _prompt_compiler_warnings(bundle)
        if missing or warnings:
            parts.extend(['', 'Missing / Warnings:'])
            parts.extend((f'- {item}' for item in list(dict.fromkeys((warnings + missing)))[:8]))
        parts.extend([
            '',
            'Expected answer:',
            *expected_lines,
        ])
        packet = '\n'.join(parts).strip()
        if ((estimate_tokens(packet) <= max_tokens) or preview_chars <= 500):
            return packet
        preview_chars -= 150


def _prompt_compiler_missing_context(bundle):
    model_analysis = bundle.get('model_analysis') or {}
    missing = _as_string_list(model_analysis.get('missing_context'))
    open_questions = _as_string_list(bundle.get('open_questions'))
    return list(dict.fromkeys([str(item) for item in (missing + open_questions) if item]))[:6]


def _format_collection_plan(plan, source=None):
    if not isinstance(plan, dict):
        return []
    lines = []
    if source:
        lines.append(f"- Source: {source}")
    if plan.get('task_type'):
        lines.append(f"- Task type: {plan.get('task_type')}")
    if plan.get('target_scope'):
        lines.append(f"- Target scope: {plan.get('target_scope')}")
    if plan.get('scope_hints'):
        lines.append(f"- Scope hints: {', '.join(_as_string_list(plan.get('scope_hints'))[:5])}")
    if plan.get('required_evidence'):
        lines.append(f"- Required evidence: {', '.join(_as_string_list(plan.get('required_evidence'))[:8])}")
    if plan.get('excluded_context'):
        lines.append(f"- Excluded context: {', '.join(_as_string_list(plan.get('excluded_context'))[:6])}")
    return lines


def _prompt_compiler_warnings(bundle):
    warnings = []
    warnings.extend(_as_string_list(bundle.get('collection_plan_warnings')))
    evidence_quality = bundle.get('evidence_quality') or {}
    warnings.extend(_as_string_list(evidence_quality.get('warnings')))
    for key in ('missing_required_evidence', 'excluded_context_selected'):
        values = _as_string_list(evidence_quality.get(key))
        if values:
            warnings.append(f"{key}: {', '.join(values[:5])}")
    return warnings[:8]


def _focused_prompt_compiler_evidence(user_prompt, bundle):
    from .classifier import is_open_source_readiness_prompt
    from .utils import normalize_path
    evidence_items = list((bundle.get('evidence_items') or []))
    lowered = (user_prompt or '').lower()
    if is_open_source_readiness_prompt(user_prompt):
        preflight = bundle.get('preflight') or {}
        focus_root = preflight.get('focus_root')
        focused = []
        for item in evidence_items:
            path = str(item.get('path') or '')
            path_lower = path.replace('\\', '/').lower()
            if path_lower.endswith(('.unity', '/projectsettings.asset', '/unityconnectsettings.asset', '/scenetemplatesettings.json')):
                continue
            if focus_root:
                try:
                    if not normalize_path(path).startswith(normalize_path(focus_root)):
                        continue
                except Exception:
                    pass
            focused.append(item)
        if focused:
            return focused[:8]
    android_icon = ('apk' in lowered or 'android' in lowered) and ('icon' in lowered or 'icons' in lowered)
    if android_icon:
        focused = []
        for item in evidence_items:
            path = str(item.get('path') or '').replace('\\', '/').lower()
            if (
                path.endswith('/projectsettings/projectsettings.asset')
                or path.endswith('/assets/plugins/android/androidmanifest.xml')
                or ('/assets/' in path and '/icon' in path and path.endswith(('.png.meta', '.png', '.asset', '.meta')))
            ):
                focused.append(item)
        if focused:
            return focused[:5]
    return evidence_items[:5]


def _unity_meta_guid(path):
    if not path:
        return None
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            text = handle.read(2048)
    except Exception:
        return None
    match = re.search(r'(?m)^guid:\s*([A-Za-z0-9]+)\s*$', text)
    return match.group(1) if match else None


def _as_string_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item) for item in value if item]
    if isinstance(value, str):
        return [value] if value.strip() else []
    return [str(value)]


def indent_block(text, prefix):
    return '\n'.join(((prefix + line) for line in text.splitlines()))


def build_enriched_prompt(user_prompt, bundle):
    return build_codex_packet(user_prompt, bundle, bundle.get('token_budget', DEFAULT_TOKEN_BUDGET))


def bundle_for_direct_pass(prompt, reason, project_root=None, token_budget=DEFAULT_TOKEN_BUDGET, analysis_depth='deterministic', preflight=None):
    packet = prompt.strip()
    return {'mode': 'gather', 'original_prompt': prompt, 'normalized_prompt': prompt, 'project_root': project_root, 'project_type': None, 'routing_decision': 'direct_pass_through', 'packet_mode': 'direct', 'analysis_depth': analysis_depth, 'analysis_stages': [{'stage': 'preflight', 'status': 'direct'}], 'preflight': preflight, 'gather_reason': reason, 'confidence': 1.0, 'gathered_files': {}, 'evidence_items': [], 'error_lines': [], 'context_summary': 'No evidence gathered; packet contains only the prompt.', 'open_questions': [], 'assumptions': [], 'git_status': None, 'git_diff': None, 'git_diff_summary': None, 'repo_index': None, 'token_budget': token_budget, 'estimated_tokens': estimate_tokens(packet), 'omitted_context': {}, 'codex_packet': packet, 'enriched_prompt': packet}
