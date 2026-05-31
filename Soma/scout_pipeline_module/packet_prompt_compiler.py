"""Prompt compiler packet construction."""
import re

from .config import DEFAULT_TOKEN_BUDGET, TOKEN_BUDGETS
from .packet_utils import _as_string_list, estimate_tokens, indent_block


def build_prompt_compiler_packet(user_prompt, bundle, token_budget=DEFAULT_TOKEN_BUDGET):
    max_tokens = TOKEN_BUDGETS.get(token_budget, TOKEN_BUDGETS[DEFAULT_TOKEN_BUDGET])
    evidence_items = _focused_prompt_compiler_evidence(user_prompt, bundle)
    preview_chars = 1100
    while True:
        parts = _compiler_parts(user_prompt, bundle, evidence_items, preview_chars)
        packet = '\n'.join(parts).strip()
        if estimate_tokens(packet) <= max_tokens or preview_chars <= 500:
            return packet
        preview_chars -= 150


def _compiler_parts(user_prompt, bundle, evidence_items, preview_chars):
    from .ranker import format_model_analysis
    task_lines, expected_lines = _task_and_expected_lines(user_prompt)
    parts = _compiler_header(user_prompt, bundle, task_lines)
    _append_focus(parts, bundle)
    _append_collection_plan(parts, bundle)
    _append_compiler_evidence(parts, evidence_items, preview_chars)
    _extend_named(parts, 'Local Analyst Notes:', format_model_analysis(bundle.get('model_analysis')))
    _append_missing_and_warnings(parts, bundle)
    parts.extend(['', 'Expected answer:', *expected_lines])
    return parts


def _task_and_expected_lines(user_prompt):
    from .classifier import is_open_source_readiness_prompt
    if is_open_source_readiness_prompt(user_prompt):
        return [
            '- Perform an open-source readiness review of the inferred package scope first.',
            '- Treat the wrapper Unity project as context only unless evidence shows it affects the package release.',
            '- Identify strengths, weak points, release blockers, and missing docs/tests/security/licensing work.',
            '- If this is still insufficient, ask for exactly 1-3 missing files or commands.',
        ], ['- Confirm the package scope being reviewed.', '- List strengths and weak spots separately.', '- Give a prioritized pre-release checklist.', '- Point to the exact evidence lines/files used.']
    return [
        '- Diagnose this using only the focused local evidence below first.',
        '- If this is still insufficient, ask for exactly 1-3 missing files or commands.',
        '- Ignore unrelated repository changes unless they directly affect this issue.',
    ], ['- Explain the most likely cause.', '- Point to the exact evidence lines/files used.', '- Give the smallest verification or fix plan.']


def _compiler_header(user_prompt, bundle, task_lines):
    return [
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


def _append_focus(parts, bundle):
    preflight = bundle.get('preflight') or {}
    if not preflight.get('focus_root'):
        return
    parts.extend([f"- Focus: {preflight.get('focus_root')}", f"- Focus type: {preflight.get('focus_kind') or 'package'}"])
    if preflight.get('focus_reason'):
        parts.append(f"- Focus reason: {preflight.get('focus_reason')}")


def _append_collection_plan(parts, bundle):
    plan_lines = _format_collection_plan(bundle.get('collection_plan'), bundle.get('collection_plan_source'))
    if plan_lines:
        parts.extend(['', 'Collection Plan:'])
        parts.extend(plan_lines)


def _append_compiler_evidence(parts, evidence_items, preview_chars):
    if not evidence_items:
        return
    from .parser import format_line_range
    parts.extend(['', 'Focused Evidence:'])
    for index, item in enumerate(evidence_items, start=1):
        _append_compiler_item(parts, item, index, preview_chars, format_line_range)


def _append_compiler_item(parts, item, index, preview_chars, format_line_range):
    parts.append(f"{index}. {item.get('path', '[unknown]')}{format_line_range(item)}")
    reason = (item.get('reason') or '').strip()
    if reason:
        parts.append(f"   Why it matters: {reason}")
    _append_unity_meta(parts, item)
    if item.get('unity_refs'):
        parts.append(f"   Unity refs: {', '.join(item['unity_refs'][:5])}")
    preview = (item.get('preview') or '')[:preview_chars].strip()
    parts.extend(['   Relevant excerpt:', indent_block(preview or '[No preview available]', '   ')])


def _append_unity_meta(parts, item):
    path = str(item.get('path') or '')
    if not path.lower().endswith('.png.meta'):
        return
    parts.append(f"   Asset file: {path[:-5]}")
    meta_guid = _unity_meta_guid(path)
    if meta_guid:
        parts.append(f"   Meta GUID: {meta_guid}")


def _extend_named(parts, title, lines):
    if lines:
        parts.extend(['', title])
        parts.extend(lines)


def _append_missing_and_warnings(parts, bundle):
    missing = _prompt_compiler_missing_context(bundle)
    warnings = _prompt_compiler_warnings(bundle)
    if missing or warnings:
        parts.extend(['', 'Missing / Warnings:'])
        parts.extend(f'- {item}' for item in list(dict.fromkeys(warnings + missing))[:8])


def _prompt_compiler_missing_context(bundle):
    model_analysis = bundle.get('model_analysis') or {}
    missing = _as_string_list(model_analysis.get('missing_context'))
    open_questions = _as_string_list(bundle.get('open_questions'))
    return list(dict.fromkeys(str(item) for item in missing + open_questions if item))[:6]


def _format_collection_plan(plan, source=None):
    if not isinstance(plan, dict):
        return []
    lines = []
    _append_plan_line(lines, source, "Source")
    _append_plan_line(lines, plan.get('task_type'), "Task type")
    _append_plan_line(lines, plan.get('target_scope'), "Target scope")
    _append_plan_list(lines, plan.get('scope_hints'), "Scope hints", 5)
    _append_plan_list(lines, plan.get('required_evidence'), "Required evidence", 8)
    _append_plan_list(lines, plan.get('excluded_context'), "Excluded context", 6)
    return lines


def _append_plan_line(lines, value, label):
    if value:
        lines.append(f"- {label}: {value}")


def _append_plan_list(lines, value, label, limit):
    values = _as_string_list(value)[:limit]
    if values:
        lines.append(f"- {label}: {', '.join(values)}")


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
    evidence_items = list(bundle.get('evidence_items') or [])
    if is_open_source_readiness_prompt(user_prompt):
        focused = _open_source_evidence(evidence_items, bundle.get('preflight') or {})
        if focused:
            return focused[:8]
    focused = _android_icon_evidence(evidence_items, user_prompt)
    return focused[:5] if focused else evidence_items[:5]


def _open_source_evidence(evidence_items, preflight):
    from .utils import normalize_path
    focus_root = preflight.get('focus_root')
    focused = []
    for item in evidence_items:
        path = str(item.get('path') or '')
        path_lower = path.replace('\\', '/').lower()
        if path_lower.endswith(('.unity', '/projectsettings.asset', '/unityconnectsettings.asset', '/scenetemplatesettings.json')):
            continue
        if focus_root and not _under_focus(path, focus_root, normalize_path):
            continue
        focused.append(item)
    return focused


def _under_focus(path, focus_root, normalize_path):
    try:
        return normalize_path(path).startswith(normalize_path(focus_root))
    except Exception:
        return False


def _android_icon_evidence(evidence_items, user_prompt):
    lowered = (user_prompt or '').lower()
    if not (('apk' in lowered or 'android' in lowered) and ('icon' in lowered or 'icons' in lowered)):
        return []
    return [item for item in evidence_items if _android_icon_path(str(item.get('path') or '').replace('\\', '/').lower())]


def _android_icon_path(path):
    return (
        path.endswith('/projectsettings/projectsettings.asset')
        or path.endswith('/assets/plugins/android/androidmanifest.xml')
        or ('/assets/' in path and '/icon' in path and path.endswith(('.png.meta', '.png', '.asset', '.meta')))
    )


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
