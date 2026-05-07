
import argparse

import asyncio

import hashlib

import json

import os

import re

import shutil

import subprocess

import urllib.request

from pathlib import Path

from mcp import ClientSession, StdioServerParameters

from mcp.client.stdio import stdio_client

import uuid

from .ScoutConfigAndConstants import *


def extract_symbols(path, text=None):
    from .GoDaemonManager import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('extract-symbols', path)
        return json.loads(stdout)
    except Exception:
        pass
    return []


def build_rust_scanner(rust_scanner_dir):
    rust_scanner_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'rust_scanner')
    rust_scanner_path = os.path.join(rust_scanner_dir, 'target', 'release', 'rust_scanner')
    from .GoDaemonManager import GoDaemon




    try:
        subprocess.run(['cargo', 'build', '--release'], cwd=rust_scanner_dir, capture_output=True, timeout=120)
    except Exception:
        pass
    return rust_scanner_path


def extract_unity_refs(path, text=None):
    from .GoDaemonManager import GoDaemon
    try:
        if (Path(path).suffix.lower() in {'.unity', '.prefab', '.asset'}):
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
            except Exception:
                pass
        daemon = GoDaemon.get_instance()
        stdout = daemon.call('extract-unity-refs', path)
        return json.loads(stdout)
    except Exception:
        pass
    return []
