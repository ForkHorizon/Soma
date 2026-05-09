


import sys
import hashlib

import json

import os



import subprocess


from pathlib import Path




from .config import *


def detect_project_type(project_root):
    # Performance: O(1) existence checks for common markers instead of enumerating the entire directory
    if os.path.exists(os.path.join(project_root, 'Assets')) and os.path.exists(os.path.join(project_root, 'ProjectSettings')):
        return ('unity', 'Detected Unity project markers (`Assets` and `ProjectSettings`).')
    if os.path.exists(os.path.join(project_root, 'Package.swift')):
        return ('swift', 'Detected Swift/Xcode markers in the project root.')
    if os.path.exists(os.path.join(project_root, 'pyproject.toml')) or os.path.exists(os.path.join(project_root, 'requirements.txt')) or os.path.exists(os.path.join(project_root, 'Pipfile')):
        return ('python', 'Detected Python manifests or Python source files.')
    if os.path.exists(os.path.join(project_root, 'package.json')) or os.path.exists(os.path.join(project_root, 'pnpm-lock.yaml')) or os.path.exists(os.path.join(project_root, 'yarn.lock')):
        return ('javascript', 'Detected JavaScript/TypeScript package manifests.')

    try:
        # Fallback to O(N) scan for wildcard markers. Swift has precedence over Python.
        has_python = False
        with os.scandir(project_root) as it:
            for entry in it:
                if entry.name.endswith('.xcodeproj') or entry.name.endswith('.xcworkspace'):
                    return ('swift', 'Detected Swift/Xcode markers in the project root.')
                if entry.name.endswith('.py'):
                    has_python = True
        if has_python:
            return ('python', 'Detected Python manifests or Python source files.')
    except Exception as exc:
        print(f"detect_project_type failed: {exc}", file=sys.stderr)
        pass

    return ('unknown', 'No strong project markers detected; using generic file heuristics.')

    try:
        subprocess.run(['go', 'build', '-o', 'soma_scanner', '.'], cwd=go_scanner_dir, capture_output=True, timeout=30)
    except Exception as exc:
        print(f"build_go_scanner failed: {exc}", file=sys.stderr)
        pass

    return ('unknown', 'No strong project markers detected; using generic file heuristics.')


def iter_project_files(project_root):
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('scan-files', project_root)
        return json.loads(stdout)
    except Exception as exc:
        print(f"iter_project_files failed: {exc}", file=sys.stderr)
        pass
    return []


def cache_key_for_root(project_root):
    from .utils import normalize_path
    return hashlib.sha256(normalize_path(project_root).encode()).hexdigest()[:24]


def index_cache_path(project_root):
    return (DEFAULT_REPO_CACHE_DIR / f'{cache_key_for_root(project_root)}.json')


def file_digest(path):
    digest = hashlib.sha256()
    try:
        with open(path, 'rb') as handle:
            for chunk in iter((lambda : handle.read((64 * 1024))), b''):
                digest.update(chunk)
        return digest.hexdigest()
    except Exception as exc:
        print(f"file_digest failed: {exc}", file=sys.stderr)
        return None


def build_repo_index(project_root, discovered):
    from .utils import normalize_path
    from .symbols import extract_unity_refs, extract_symbols
    from .parser import read_text_file
    cache_path = index_cache_path(project_root)
    cache = {}
    try:
        cache = (json.loads(cache_path.read_text()) if cache_path.exists() else {})
    except Exception as exc:
        print(f"build_repo_index failed: {exc}", file=sys.stderr)
        cache = {}
    indexed_files = []
    files_cache = cache.get('files', {})
    new_files_cache = {}
    changed_count = 0
    for item in discovered:
        path = item['path']
        try:
            stat = os.stat(path)
        except OSError:
            continue
        cache_id = f'{path}:{stat.st_size}:{stat.st_mtime_ns}'
        cached = files_cache.get(path)
        if (cached and (cached.get('cache_id') == cache_id)):
            indexed = cached
        else:
            changed_count += 1
            text = ''
            if ((os.path.splitext(path)[1].lower() in TEXT_EXTENSIONS) or (item['category'] in {'source', 'script', 'config', 'manifest', 'unity'})):
                text = read_text_file(path)
            indexed = {'cache_id': cache_id, 'path': path, 'category': item['category'], 'size': stat.st_size, 'mtime': item['mtime'], 'digest': file_digest(path), 'symbols': extract_symbols(path, text), 'unity_refs': extract_unity_refs(path, text)}
        new_files_cache[path] = indexed
        indexed_files.append(indexed)
    next_cache = {'project_root': normalize_path(project_root), 'updated_at': (int(os.path.getmtime(project_root)) if os.path.exists(project_root) else 0), 'files': new_files_cache}
    try:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps(next_cache))
    except Exception as exc:
        print(f"build_repo_index failed: {exc}", file=sys.stderr)
        pass
    return {'cache_path': str(cache_path), 'indexed_file_count': len(indexed_files), 'changed_index_entries': changed_count, 'files': indexed_files}
