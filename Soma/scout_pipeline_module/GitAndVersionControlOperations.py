
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


def get_git_status(project_root):
    from .GoDaemonManager import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        status = daemon.call('git-status', project_root).strip()
        if status:
            return status
    except Exception:
        pass
    return None


def get_git_diff_summary(project_root, terms=None):
    from .GoDaemonManager import GoDaemon
    try:
        daemon = GoDaemon.get_instance()
        args = ([project_root] + (terms or []))
        stdout = daemon.call('git-diff', *args)
        return json.loads(stdout)
    except Exception:
        pass
    return None


def format_git_diff_summary(summary):
    from .GoDaemonManager import GoDaemon
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
