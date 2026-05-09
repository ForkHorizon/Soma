


import hashlib

import json

import os



import subprocess


from pathlib import Path




from .config import *


def detect_project_type(project_root):
    root = Path(project_root)
    names = ({child.name for child in root.iterdir()} if root.exists() else set())
    if (('Assets' in names) and ('ProjectSettings' in names)):
        return ('unity', 'Detected Unity project markers (`Assets` and `ProjectSettings`).')
    if (('Package.swift' in names) or any(((name.endswith('.xcodeproj') or name.endswith('.xcworkspace')) for name in names))):
        return ('swift', 'Detected Swift/Xcode markers in the project root.')
    if (('pyproject.toml' in names) or ('requirements.txt' in names) or ('Pipfile' in names) or any(((child.suffix == '.py') for child in root.iterdir()))):
        return ('python', 'Detected Python manifests or Python source files.')
    if (('package.json' in names) or ('pnpm-lock.yaml' in names) or ('yarn.lock' in names)):
        return ('javascript', 'Detected JavaScript/TypeScript package manifests.')
    return ('unknown', 'No strong project markers detected; using generic file heuristics.')


def build_go_scanner(go_scanner_dir):
    go_scanner_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'go_scanner')
    go_scanner_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'go_scanner')
    go_scanner_path = os.path.join(go_scanner_dir, 'soma_scanner')
    try:
        subprocess.run(['go', 'build', '-o', 'soma_scanner', '.'], cwd=go_scanner_dir, capture_output=True, timeout=30)
    except Exception:
        pass
    return go_scanner_path


def iter_project_files(project_root):
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('scan-files', project_root)
        return json.loads(stdout)
    except Exception:
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
    except Exception:
        return None


def build_repo_index(project_root, discovered):
    from .utils import normalize_path
    from .symbols import extract_unity_refs, extract_symbols
    from .parser import read_text_file
    cache_path = index_cache_path(project_root)
    cache = {}
    try:
        cache = (json.loads(cache_path.read_text()) if cache_path.exists() else {})
    except Exception:
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
            if ((Path(path).suffix.lower() in TEXT_EXTENSIONS) or (item['category'] in {'source', 'script', 'config', 'manifest', 'unity'})):
                text = read_text_file(path)
            indexed = {'cache_id': cache_id, 'path': path, 'category': item['category'], 'size': stat.st_size, 'mtime': item['mtime'], 'digest': file_digest(path), 'symbols': extract_symbols(path, text), 'unity_refs': extract_unity_refs(path, text)}
        new_files_cache[path] = indexed
        indexed_files.append(indexed)
    next_cache = {'project_root': normalize_path(project_root), 'updated_at': (int(os.path.getmtime(project_root)) if os.path.exists(project_root) else 0), 'files': new_files_cache}
    try:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps(next_cache))
    except Exception:
        pass
    return {'cache_path': str(cache_path), 'indexed_file_count': len(indexed_files), 'changed_index_entries': changed_count, 'files': indexed_files}
