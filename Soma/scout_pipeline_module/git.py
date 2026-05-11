

"""Git status and diff summarization.

This stage summarizes changed files and hunks while omitting raw full diffs
from packets and reports.
"""
import sys
import json
import subprocess
from pathlib import Path










from .config import *


def _is_noise_path(path):
    candidate = Path(path)
    return (
        candidate.name in NOISE_PATH_NAMES
        or candidate.suffix.lower() in NOISE_SUFFIXES
        or any(part in SKIP_DIRS for part in candidate.parts)
    )


def _raw_diff_size(project_root):
    try:
        return len(subprocess.run(
            ['git', 'diff', '--no-ext-diff', '--no-color'],
            cwd=project_root,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        ).stdout or '')
    except Exception:
        return 0


def _normalize_git_diff_summary(summary, project_root=None):
    if not isinstance(summary, dict):
        summary = {}
    changed_files = [
        item for item in (summary.get('changed_files') or [])
        if not _is_noise_path(item.get('path', ''))
    ]
    summary['changed_files'] = changed_files
    summary['changed_file_count'] = summary.get('changed_file_count', len(changed_files))
    summary['hunks'] = summary.get('hunks') or []
    summary['raw_diff_chars_omitted'] = summary.get('raw_diff_chars_omitted', _raw_diff_size(project_root) if project_root else 0)
    return summary


def get_git_status(project_root):
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        status = daemon.call('git-status', project_root).strip()
        if status:
            return status
    except Exception as exc:
        print(f"get_git_status failed: {exc}", file=sys.stderr)
        pass
    return None


def get_git_diff_summary(project_root, terms=None):
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        args = ([project_root] + (terms or []))
        stdout = daemon.call('git-diff', *args)
        res = json.loads(stdout)
        if isinstance(res, str):
            res = json.loads(res)
        return _normalize_git_diff_summary(res, project_root)
    except Exception as exc:
        print(f"get_git_diff_summary failed: {exc}", file=sys.stderr)
        pass
    try:
        raw_size = _raw_diff_size(project_root)
        numstat = subprocess.run(
            ['git', 'diff', '--numstat'],
            cwd=project_root,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        ).stdout or ''
        changed_files = []
        for line in numstat.splitlines():
            parts = line.split('\t')
            if len(parts) < 3:
                continue
            added, removed, path = parts[0], parts[1], parts[2]
            if _is_noise_path(path):
                continue
            changed_files.append({'status': 'M', 'path': path, 'added': added, 'removed': removed})
        return _normalize_git_diff_summary({
            'changed_files': changed_files,
            'changed_file_count': len(changed_files),
            'hunks': [],
            'raw_diff_chars_omitted': raw_size,
            'fallback': 'git_cli',
        })
    except Exception as exc:
        print(f"get_git_diff_summary fallback failed: {exc}", file=sys.stderr)
    return _normalize_git_diff_summary({'changed_files': [], 'changed_file_count': 0, 'hunks': [], 'raw_diff_chars_omitted': 0, 'fallback': 'empty'})


def format_git_diff_summary(summary):
    if (not summary):
        return []
    lines = [f"Changed files: {summary.get('changed_file_count', 0)}", f"Raw diff omitted: {summary.get('raw_diff_chars_omitted', 0)} chars"]
    changed_files = (summary.get('changed_files') or [])
    if changed_files:
        lines.append('Changed file list:')
        for item in changed_files[:20]:
            stats = ''
            if ((item.get('added') is not None) or (item.get('removed') is not None)):
                stats = f" (+{item.get('added', '?')}/-{item.get('removed', '?')})"
            lines.append(f"- {item.get('status', '?')} {item.get('path', '')}{stats}")
        if (summary.get('changed_file_count', 0) > len(changed_files[:20])):
            lines.append(f"- ... {(summary.get('changed_file_count', 0) - len(changed_files[:20]))} more changed files omitted")
    hunks = (summary.get('hunks') or [])
    if hunks:
        lines.append('Top changed hunks:')
        for (index, hunk) in enumerate(hunks, start=1):
            line_range = ''
            if hunk.get('start_line'):
                line_range = f":{hunk['start_line']}-{(hunk.get('end_line') or hunk['start_line'])}"
            lines.append(f"{index}. {hunk.get('file', '[unknown]')}{line_range} (+{hunk.get('added', 0)}/-{hunk.get('removed', 0)})")
            for signal in (hunk.get('signals') or []):
                lines.append(f'   signal: {signal}')
    return lines
