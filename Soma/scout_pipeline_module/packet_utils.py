"""Shared packet helpers."""

import re

from .config import DEFAULT_TOKEN_BUDGET

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
            return _profile_estimate_tokens(text, "fallback")
        except Exception:
            pass
    return max(1, int(len(text) / 4))


def build_omitted_context(bundle):
    omitted = dict(bundle.get("omitted_context") or {})
    diff_summary = bundle.get("git_diff_summary") or {}
    if diff_summary.get("raw_diff_chars_omitted"):
        omitted["raw_git_diff_chars"] = diff_summary["raw_diff_chars_omitted"]
    repo_index = bundle.get("repo_index") or {}
    indexed_count = repo_index.get("indexed_file_count")
    evidence_count = len(bundle.get("evidence_items") or [])
    if indexed_count is not None:
        omitted["indexed_files_not_in_packet"] = max(0, indexed_count - evidence_count)
    return omitted


def _source_match_terms(user_prompt, item):
    terms = re.findall(r"[A-Za-z_][A-Za-z0-9_]{2,}", user_prompt or "")
    terms.extend(_as_string_list(item.get("symbols")))
    path = str(item.get("path") or "")
    if path:
        terms.append(path.rsplit("/", 1)[-1].split(".", 1)[0])
    return _clean_terms(terms)


def _as_string_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item) for item in value if item]
    if isinstance(value, str):
        return [value] if value.strip() else []
    return [str(value)]


def _clean_terms(terms):
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
    return bool(re.search(r"\b(func|function|def|class|struct|enum|protocol|extension|actor)\b", line))


def _line_indent(line):
    return len(line) - len(line.lstrip(" "))


def _extract_python_block(lines, start, limit):
    base_indent = _line_indent(lines[start])
    end = start + 1
    while end < len(lines) and end - start < 160:
        line = lines[end]
        if line.strip() and _line_indent(line) <= base_indent and not line.lstrip().startswith(("#", "@")):
            break
        end += 1
    return "\n".join(lines[start:end])[:limit].strip()


def _extract_brace_block(lines, start, limit):
    balance = 0
    seen_open = False
    collected = []
    for index in range(start, min(len(lines), start + 180)):
        line = lines[index]
        collected.append(line)
        balance, seen_open = _brace_balance(line, balance, seen_open)
        if seen_open and balance <= 0:
            rendered = "\n".join(collected).strip()
            return rendered if len(rendered) <= limit else rendered[:limit].rstrip()
    return None


def _brace_balance(line, balance, seen_open):
    for char in line:
        if char == "{":
            balance += 1
            seen_open = True
        elif char == "}" and seen_open:
            balance -= 1
    return balance, seen_open


def _focused_source_preview(user_prompt, item, limit):
    lines = _read_source_lines(item.get("path"))
    if not lines:
        return None
    match_index = _source_match_index(lines, _source_match_terms(user_prompt, item), item)
    block = _declaration_block(lines, match_index, limit)
    if block:
        return block
    start = max(0, match_index - 30)
    end = min(len(lines), match_index + 70)
    return "\n".join(lines[start:end])[:limit].strip()


def _read_source_lines(path):
    if not path:
        return []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read(120000).splitlines()
    except Exception:
        return []


def _source_match_index(lines, terms, item):
    for index, line in enumerate(lines):
        lowered = line.lower()
        if any(term in lowered for term in terms):
            return index
    start = max(0, int(item.get("start_line") or 1) - 1)
    return min(start, len(lines) - 1)


def _declaration_block(lines, match_index, limit):
    for index in range(match_index, max(-1, match_index - 60), -1):
        if not _source_declaration_line(lines[index]):
            continue
        if re.search(r"^\s*(?:async\s+)?def\b", lines[index]):
            return _extract_python_block(lines, index, limit)
        return _extract_brace_block(lines, index, limit)
    return None


def indent_block(text, prefix):
    return "\n".join(prefix + line for line in text.splitlines())


def build_enriched_prompt(user_prompt, bundle):
    return bundle["codex_packet"] if bundle.get("codex_packet") else user_prompt


def bundle_for_direct_pass(
    prompt, reason, project_root=None, token_budget=DEFAULT_TOKEN_BUDGET, analysis_depth="deterministic", preflight=None
):
    packet = prompt.strip()
    return {
        "mode": "gather",
        "original_prompt": prompt,
        "normalized_prompt": prompt,
        "project_root": project_root,
        "project_type": None,
        "routing_decision": "direct_pass_through",
        "packet_mode": "direct",
        "analysis_depth": analysis_depth,
        "analysis_stages": [{"stage": "preflight", "status": "direct"}],
        "preflight": preflight,
        "gather_reason": reason,
        "confidence": 1.0,
        "gathered_files": {},
        "evidence_items": [],
        "error_lines": [],
        "context_summary": "No evidence gathered; packet contains only the prompt.",
        "open_questions": [],
        "assumptions": [],
        "git_status": None,
        "git_diff": None,
        "git_diff_summary": None,
        "repo_index": None,
        "token_budget": token_budget,
        "estimated_tokens": estimate_tokens(packet),
        "omitted_context": {},
        "codex_packet": packet,
        "enriched_prompt": packet,
    }
