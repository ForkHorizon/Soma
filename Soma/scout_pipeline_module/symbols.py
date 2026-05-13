



import sys
import json

import os



import subprocess
import re


from pathlib import Path




from .config import *


def extract_symbols(path, text=None):
    if text is None:
        try:
            text = Path(path).read_text(errors='replace')[:MAX_FILE_BYTES]
        except Exception:
            text = ''
    ext = os.path.splitext(path)[1].lower()
    patterns = []
    if ext == '.go':
        patterns = [r'\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', r'\btype\s+([A-Za-z_][A-Za-z0-9_]*)\s+(?:struct|interface)']
    elif ext == '.rs':
        patterns = [r'\b(?:fn|struct|enum|trait)\s+([A-Za-z_][A-Za-z0-9_]*)']
    elif ext in {'.c', '.cc', '.cpp', '.h', '.hpp'}:
        patterns = [r'\b(?:class|struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)', r'\b[A-Za-z_][A-Za-z0-9_:<>*&\s]+\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(']
    elif ext in {'.java', '.kt'}:
        patterns = [r'\b(?:class|interface|enum|object)\s+([A-Za-z_][A-Za-z0-9_]*)', r'\b(?:fun|void|public|private|protected|static)\s+[A-Za-z_][A-Za-z0-9_<>,\[\]?]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(']
    elif ext == '.php':
        patterns = [r'\b(?:class|interface|trait|function)\s+([A-Za-z_][A-Za-z0-9_]*)']
    elif ext == '.rb':
        patterns = [r'(?m)^\s*(?:class|module|def)\s+([A-Za-z_][A-Za-z0-9_!?=]*)']
    elif ext == '.swift':
        patterns = [
            r'\b(?:class|struct|enum|protocol|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)',
            r'\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(',
            r'\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*[:=]',
        ]
    elif ext in {'.js', '.jsx', '.ts', '.tsx'}:
        patterns = [
            r'\b(?:class|interface|type|function)\s+([A-Za-z_][A-Za-z0-9_]*)',
            r'\b(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=',
        ]
    if os.environ.get('SOMA_USE_GO_SYMBOLS') == '1':
        from .daemon import GoDaemon
        try:
            daemon = GoDaemon.get_instance()
            stdout = daemon.call('extract-symbols', path)
            res = json.loads(stdout)
            if isinstance(res, str):
                res = json.loads(res)
            if isinstance(res, list) and res:
                return res
        except Exception as exc:
            print(f"extract_symbols failed: {exc}", file=sys.stderr)
    symbols = []
    seen = set()
    for pattern in patterns:
        for match in re.findall(pattern, text or ''):
            if match not in seen:
                seen.add(match)
                symbols.append(match)
                if len(symbols) >= 12:
                    return symbols
    return symbols


def build_rust_scanner(rust_scanner_dir):
    rust_scanner_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'rust_scanner')
    rust_scanner_path = os.path.join(rust_scanner_dir, 'target', 'release', 'rust_scanner')




    try:
        subprocess.run(['cargo', 'build', '--release'], cwd=rust_scanner_dir, capture_output=True, timeout=120)
    except Exception as exc:
        print(f"build_rust_scanner failed: {exc}", file=sys.stderr)
        pass
    return rust_scanner_path


def extract_unity_refs(path, text=None):
    from .daemon import GoDaemon
    if (os.path.splitext(path)[1].lower() not in {'.unity', '.prefab', '.asset'}):
        return []
    try:
        try:
            stat = os.stat(path)
            if (stat.st_size > (10 * 1024)):
                rust_scanner_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'rust_scanner')
                rust_scanner_path = os.path.join(rust_scanner_dir, 'target', 'release', 'rust_scanner')





                if ((not os.path.exists(rust_scanner_path)) or (not os.access(rust_scanner_path, os.X_OK))):
                    build_rust_scanner(rust_scanner_dir)
                res = subprocess.run([rust_scanner_path, 'extract-unity-refs', path], capture_output=True, text=True, timeout=10)
                if (res.returncode == 0):
                    return json.loads(res.stdout)
        except Exception as exc:
            print(f"extract_unity_refs failed: {exc}", file=sys.stderr)
            pass
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('extract-unity-refs', path)
        res = json.loads(stdout)
        if isinstance(res, str):
            res = json.loads(res)
        return res if isinstance(res, list) else []
    except Exception as exc:
        print(f"extract_unity_refs failed: {exc}", file=sys.stderr)
        pass
    return []
