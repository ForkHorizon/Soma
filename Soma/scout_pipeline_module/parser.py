



import sys
import json


import re








from .config import *


def find_errors(text):
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('find-errors', text)
        res = json.loads(stdout)
        if isinstance(res, str):
            res = json.loads(res)
        return res if isinstance(res, list) else []
    except Exception as exc:
        print(f"find_errors failed: {exc}", file=sys.stderr)
        return []


def group_compile_errors(errors):
    'Deduplicates and sanitizes compile errors into concise summaries.'
    if not errors:
        return []
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('group-compile-errors', json.dumps(errors))
        res = json.loads(stdout)
        if isinstance(res, str):
            res = json.loads(res)
        return res if isinstance(res, list) else []
    except Exception as exc:
        print(f"group_compile_errors failed: {exc}", file=sys.stderr)
        return []


def get_unity_logs(path):
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('tail-logs', path)
        res = json.loads(stdout)
        if isinstance(res, str):
            res = json.loads(res)
        return res if isinstance(res, list) else []
    except Exception as exc:
        print(f"get_unity_logs failed: {exc}", file=sys.stderr)
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
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('excerpt-for-text', text, json.dumps(terms))
        res = json.loads(stdout)
        if isinstance(res, str):
            res = json.loads(res)
        if isinstance(res, dict):
            return (res.get('text', ''), res.get('start_line'), res.get('end_line'))
        return ('', None, None)
    except Exception as exc:
        print(f"excerpt_for_text failed: {exc}", file=sys.stderr)
        # Fallback
        lines = text.splitlines()
        preview = text[:MAX_PREVIEW_CHARS].strip()
        end_line = (min(len(lines), max(1, (preview.count('\n') + 1))) if preview else None)
        return (preview, (1 if preview else None), end_line)


def excerpt_for_log(text, terms):
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('excerpt-for-log', text, json.dumps(terms))
        res = json.loads(stdout)
        if isinstance(res, str):
            res = json.loads(res)
        if isinstance(res, dict):
            return (res.get('text', ''), res.get('start_line'), res.get('end_line'))
        return ('', None, None)
    except Exception as exc:
        print(f"excerpt_for_log failed: {exc}", file=sys.stderr)
        # Fallback
        lines = text.splitlines()
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
    except Exception as exc:
        print(f"extract_json_object failed: {exc}", file=sys.stderr)
        return None
