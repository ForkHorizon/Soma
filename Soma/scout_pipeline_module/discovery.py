
"""Project discovery and indexing.

This stage detects repository type, discovers relevant files through the Go
scanner or Python fallback, and builds a cached repo index for evidence ranking.
"""
import sys
import hashlib

import json

import os



import subprocess


from pathlib import Path




from .config import *


def _looks_like_file_items(items):
    if not isinstance(items, list):
        return False
    return all(isinstance(item, dict) and item.get('path') and item.get('category') for item in items)


def _scan_files_python(project_root):
    from .utils import categorize_path, should_skip_dir, is_noise_path
    items = []
    for root, dirs, files in os.walk(project_root):
        dirs[:] = [name for name in dirs if not should_skip_dir(name)]
        for name in files:
            path = os.path.join(root, name)
            if os.path.islink(path) or is_noise_path(path):
                continue
            category = categorize_path(path)
            if not category:
                continue
            try:
                stat = os.stat(path)
                mtime = stat.st_mtime
                size = stat.st_size
                mtime_ns = stat.st_mtime_ns
            except OSError:
                mtime = 0
                size = 0
                mtime_ns = 0
            items.append({'path': path, 'name': name, 'category': category, 'mtime': mtime, 'size': size, 'mtime_ns': mtime_ns})
            if len(items) >= MAX_DISCOVERED_FILES:
                return items
    return items


def detect_project_type(project_root):
    # Performance: O(1) existence checks for common markers instead of enumerating the entire directory
    if os.path.exists(os.path.join(project_root, 'Assets')) and os.path.exists(os.path.join(project_root, 'ProjectSettings')):
        return ('unity', 'Detected Unity project markers (`Assets` and `ProjectSettings`).')
    if os.path.exists(os.path.join(project_root, 'Package.swift')):
        return ('swift', 'Detected Swift/Xcode markers in the project root.')
    if os.path.exists(os.path.join(project_root, 'go.mod')):
        return ('go', 'Detected Go module marker (`go.mod`).')
    if os.path.exists(os.path.join(project_root, 'Cargo.toml')):
        return ('rust', 'Detected Rust crate marker (`Cargo.toml`).')
    if os.path.exists(os.path.join(project_root, 'CMakeLists.txt')):
        return ('cpp', 'Detected C/C++ build marker (`CMakeLists.txt`).')
    if os.path.exists(os.path.join(project_root, 'pom.xml')) or os.path.exists(os.path.join(project_root, 'build.gradle')) or os.path.exists(os.path.join(project_root, 'build.gradle.kts')):
        return ('java_kotlin', 'Detected JVM project markers (`pom.xml` or Gradle files).')
    if os.path.exists(os.path.join(project_root, 'composer.json')):
        return ('php', 'Detected PHP Composer marker (`composer.json`).')
    if os.path.exists(os.path.join(project_root, 'Gemfile')) or os.path.exists(os.path.join(project_root, 'Rakefile')):
        return ('ruby', 'Detected Ruby project markers (`Gemfile` or `Rakefile`).')
    if os.path.exists(os.path.join(project_root, 'pyproject.toml')) or os.path.exists(os.path.join(project_root, 'requirements.txt')) or os.path.exists(os.path.join(project_root, 'Pipfile')):
        return ('python', 'Detected Python manifests or Python source files.')
    if os.path.exists(os.path.join(project_root, 'package.json')) or os.path.exists(os.path.join(project_root, 'pnpm-lock.yaml')) or os.path.exists(os.path.join(project_root, 'yarn.lock')):
        return ('javascript', 'Detected JavaScript/TypeScript package manifests.')

    try:
        # Fallback to O(N) scan for wildcard markers. Swift has precedence over Python.
        has_python = False
        has_go = False
        has_rust = False
        has_cpp = False
        has_jvm = False
        has_php = False
        has_ruby = False
        with os.scandir(project_root) as it:
            for entry in it:
                if entry.name.endswith('.xcodeproj') or entry.name.endswith('.xcworkspace'):
                    return ('swift', 'Detected Swift/Xcode markers in the project root.')
                if entry.name.endswith('.py'):
                    has_python = True
                if entry.name.endswith('.go'):
                    has_go = True
                if entry.name.endswith('.rs'):
                    has_rust = True
                if entry.name.endswith(('.c', '.cc', '.cpp', '.h', '.hpp')):
                    has_cpp = True
                if entry.name.endswith(('.java', '.kt')):
                    has_jvm = True
                if entry.name.endswith('.php'):
                    has_php = True
                if entry.name.endswith('.rb'):
                    has_ruby = True
        if has_go:
            return ('go', 'Detected Go source files.')
        if has_rust:
            return ('rust', 'Detected Rust source files.')
        if has_cpp:
            return ('cpp', 'Detected C/C++ source files.')
        if has_jvm:
            return ('java_kotlin', 'Detected Java/Kotlin source files.')
        if has_php:
            return ('php', 'Detected PHP source files.')
        if has_ruby:
            return ('ruby', 'Detected Ruby source files.')
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
    daemon_items = []
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('scan-files', project_root)
        res = json.loads(stdout)
        if isinstance(res, str):
            res = json.loads(res)
        if _looks_like_file_items(res):
            daemon_items = res
        elif isinstance(res, list) and res:
            print("iter_project_files daemon returned invalid file item shape; using Python scanner", file=sys.stderr)
    except Exception as exc:
        print(f"iter_project_files failed: {exc}", file=sys.stderr)
    if daemon_items:
        return daemon_items
    try:
        return _scan_files_python(project_root)
    except Exception as exc:
        print(f"iter_project_files fallback failed: {exc}", file=sys.stderr)
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
        if not isinstance(item, dict) or not item.get('path'):
            continue
        path = item['path']
        size = item.get('size', 0)
        mtime_ns = item.get('mtime_ns', 0)
        cache_id = f'{path}:{size}:{mtime_ns}'
        cached = files_cache.get(path)
        if (cached and (cached.get('cache_id') == cache_id)):
            indexed = cached
        else:
            changed_count += 1
            text = ''
            if ((os.path.splitext(path)[1].lower() in TEXT_EXTENSIONS) or (item['category'] in {'source', 'script', 'config', 'manifest', 'unity'})):
                text = read_text_file(path)
            indexed = {'cache_id': cache_id, 'path': path, 'category': item['category'], 'size': size, 'mtime': item.get('mtime', 0), 'digest': file_digest(path), 'symbols': extract_symbols(path, text), 'unity_refs': extract_unity_refs(path, text)}
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
