



import json


import re








from .config import *


def find_errors(text):
    out = []
    tokens = ['ERROR', 'EXCEPTION', 'FATAL', 'TRACEBACK', 'CRASH']
    for line in text.splitlines():
        upper = line.upper()
        for token in tokens:
            if (token in upper):
                stripped = line.strip()
                if (len(stripped) > 5):
                    out.append(stripped)
                break
    return out


def group_compile_errors(errors):
    'Deduplicates and sanitizes compile errors into concise summaries.'
    grouped = []
    seen = set()
    for error in errors:
        sanitized = re.sub('/[a-zA-Z0-9_./-]+:[0-9]+:[0-9]+: ', '', error)
        sanitized = re.sub('\\(at .*\\)', '', sanitized)
        sanitized = sanitized.strip()
        if ((sanitized not in seen) and (len(sanitized) > 5)):
            seen.add(sanitized)
            grouped.append(sanitized)
    return grouped


def get_unity_logs(path):
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('tail-logs', path)
        return json.loads(stdout)
    except Exception:
        pass
    return []


def read_text_file(path):
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('read-text', path)
        return stdout
    except Exception as exc:
        return f'[Unable to read file: {exc}]'


def excerpt_for_text(text, terms):
    if (not text):
        return ('', None, None)
    lines = text.splitlines()
    lowered = text.lower()
    for term in terms:
        idx = lowered.find(term)
        if (idx != (- 1)):
            start = max(0, (idx - 250))
            end = min(len(text), (idx + MAX_PREVIEW_CHARS))
            start_line = (text[:start].count('\n') + 1)
            end_line = (text[:end].count('\n') + 1)
            return (text[start:end].strip(), start_line, end_line)
    preview = text[:MAX_PREVIEW_CHARS].strip()
    end_line = (min(len(lines), max(1, (preview.count('\n') + 1))) if preview else None)
    return (preview, (1 if preview else None), end_line)


def excerpt_for_log(text, terms):
    lines = text.splitlines()
    error_lines = [line for line in lines if find_errors(line)]
    if error_lines:
        return ('\n'.join(error_lines[:12])[:MAX_PREVIEW_CHARS], None, None)
    lowered_lines = [line.lower() for line in lines]
    for term in terms:
        for (idx, line) in enumerate(lowered_lines):
            if (term in line):
                start = max(0, (idx - 8))
                end = min(len(lines), (idx + 12))
                return ('\n'.join(lines[start:end])[:MAX_PREVIEW_CHARS], (start + 1), end)
    start = max(0, (len(lines) - 80))
    return ('\n'.join(lines[start:])[:MAX_PREVIEW_CHARS], ((start + 1) if lines else None), (len(lines) if lines else None))


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
    except Exception:
        return None
