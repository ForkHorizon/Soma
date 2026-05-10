



import sys
import json

import os



import subprocess


from pathlib import Path




from .config import *


def extract_symbols(path, text=None):
    from .daemon import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('extract-symbols', path)
        res = json.loads(stdout)
        if isinstance(res, str):
            res = json.loads(res)
        return res if isinstance(res, list) else []
    except Exception as exc:
        print(f"extract_symbols failed: {exc}", file=sys.stderr)
        pass
    return []


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
    try:
        if (os.path.splitext(path)[1].lower() in {'.unity', '.prefab', '.asset'}):
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
