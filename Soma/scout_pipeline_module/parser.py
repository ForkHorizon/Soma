



import sys
import json


import re








from .config import *


def find_errors(text):
    errors = []
    for line in (text or '').splitlines():
        lowered = line.lower()
        if any(marker in lowered for marker in ('error', 'exception', 'failed', 'failure', 'traceback', 'panic')):
            errors.append(line.strip()[:500])
        if len(errors) >= MAX_ERROR_LINES:
            break
    return errors


def group_compile_errors(errors):
    'Deduplicates and sanitizes compile errors into concise summaries.'
    if not errors:
        return []
    grouped = []
    seen = set()
    for error in errors:
        text = str(error).strip()
        key = re.sub(r':\d+(?::\d+)?', ':#', text)
        if key in seen:
            continue
        seen.add(key)
        grouped.append(text[:500])
        if len(grouped) >= MAX_ERROR_LINES:
            break
    return grouped


def get_unity_logs(path):
    try:
        return find_errors(read_text_file(path))
    except Exception as exc:
        print(f"get_unity_logs failed: {exc}", file=sys.stderr)
    return []


def read_text_file(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            return handle.read(MAX_FILE_BYTES)
    except Exception as exc:
        return f'[Unable to read file: {exc}]'


def excerpt_for_text(text, terms):
    if (not text):
        return ('', None, None)
    lines = text.splitlines()
    lowered_terms = [term.lower() for term in (terms or []) if len(str(term)) > 2]
    match_index = None
    for index, line in enumerate(lines):
        lowered = line.lower()
        if any(term in lowered for term in lowered_terms):
            match_index = index
            break
    if match_index is None:
        preview = text[:MAX_PREVIEW_CHARS].strip()
        end_line = (min(len(lines), max(1, (preview.count('\n') + 1))) if preview else None)
        return (preview, (1 if preview else None), end_line)
    start = max(0, match_index - 12)
    end = min(len(lines), match_index + 28)
    preview = '\n'.join(lines[start:end])[:MAX_PREVIEW_CHARS].strip()
    return (preview, start + 1, end)


def excerpt_for_log(text, terms):
    if not text:
        return ('', None, None)
    errors = find_errors(text)
    if errors:
        return ('\n'.join(errors)[:MAX_PREVIEW_CHARS], 1, min(len(errors), MAX_ERROR_LINES))
    return excerpt_for_text(text, terms)


def format_line_range(item):
    if (item.get('start_line') and item.get('end_line')):
        return f":{item['start_line']}-{item['end_line']}"
    if item.get('start_line'):
        return f":{item['start_line']}"
    return ''


def extract_json_object(text):
    start = text.find('{')
    end = text.rfind('}')
    if ((start == (- 1)) or (end <= start)):
        return None
    try:
        return json.loads(text[start:(end + 1)])
    except Exception as exc:
        print(f"extract_json_object failed: {exc}", file=sys.stderr)
        return None
