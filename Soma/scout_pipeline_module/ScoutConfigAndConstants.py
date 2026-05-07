
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


MODEL = os.environ.get('SOMA_LOCAL_MODEL', 'gemma4:e4b')

RANKER_MODEL = os.environ.get('SOMA_RANKER_MODEL', 'gemma4:e4b')

ANALYST_MODEL = os.environ.get('SOMA_ANALYST_MODEL', 'qwen3-coder:30b-a3b-q4_K_M')

CHAT_ALLOWED_DIRS = ([path for path in ['/Users/daliys', '/Users/daliys/Downloads', '/Users/daliys/Daliys', '/Users/daliys/Library/Logs'] if os.path.exists(path)] or ['/Users/daliys'])

MAX_ERROR_LINES = 20

MAX_EVIDENCE_ITEMS = 8

MAX_DISCOVERED_FILES = 1500

MAX_FILE_BYTES = 160000

MAX_PREVIEW_CHARS = 1400

OLLAMA_SUMMARY_TIMEOUT = 45

DEFAULT_TOKEN_BUDGET = 'balanced'

TOKEN_BUDGETS = {'micro': 1000, 'fast': 2500, 'balanced': 6000, 'deep': 15000, 'full': 30000}

ANALYSIS_DEPTHS = {'deterministic', 'ranked', 'analyst'}

CODEX_PACKET_TARGET_TOKENS = TOKEN_BUDGETS[DEFAULT_TOKEN_BUDGET]

DEFAULT_REPO_CACHE_DIR = ((((Path.home() / 'Library') / 'Caches') / 'Soma') / 'repo_index')

NOISE_PATH_NAMES = {'.DS_Store'}

NOISE_SUFFIXES = {'.pyc', '.pyo'}

SKIP_DIRS = {'.git', '.build', '.idea', '.venv', 'Assets.xcassets', 'DerivedData', 'Pods', 'build', 'dist', 'node_modules', 'venv', 'xcuserdata', '__pycache__'}

MANIFEST_NAMES = {'package.json', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'requirements.txt', 'requirements-dev.txt', 'pyproject.toml', 'Pipfile', 'Pipfile.lock', 'setup.py', 'setup.cfg', 'Package.swift', 'Podfile', 'Cartfile', 'Gemfile', 'Makefile', 'Dockerfile', '.env'}

CONFIG_EXTENSIONS = {'.cfg', '.conf', '.ini', '.json', '.plist', '.toml', '.xml', '.yaml', '.yml'}

UNITY_EXTENSIONS = {'.asmdef', '.asset', '.controller', '.mat', '.meta', '.prefab', '.unity'}

SOURCE_EXTENSIONS = {'.c', '.cc', '.cpp', '.cs', '.go', '.h', '.hpp', '.java', '.js', '.jsx', '.kt', '.m', '.mm', '.php', '.py', '.rb', '.rs', '.sh', '.sql', '.swift', '.ts', '.tsx', '.zsh'}

SCRIPT_EXTENSIONS = {'.bat', '.command', '.ps1', '.py', '.rb', '.sh', '.zsh'}

LOG_EXTENSIONS = {'.crash', '.err', '.log', '.out', '.stderr', '.stdout', '.trace'}

TEXT_EXTENSIONS = ((((SOURCE_EXTENSIONS | CONFIG_EXTENSIONS) | LOG_EXTENSIONS) | UNITY_EXTENSIONS) | {'.md', '.txt'})

DEBUG_KEYWORDS = {'bug', 'broken', 'build', 'config', 'crash', 'debug', 'diagnose', "doesn't work", 'doesnt work', 'error', 'exception', 'fail', 'failing', 'failure', 'issue', 'log', 'not work', 'problem', 'script', 'stack trace', 'traceback', 'git', 'status', 'diff', 'changes', 'change', 'changed', 'changet', 'modified', 'recent', 'last', 'review', 'regression', 'unity'}

STOP_WORDS = {'a', 'an', 'and', 'are', 'but', 'does', 'for', 'from', 'how', 'i', 'is', 'it', 'my', 'not', 'of', 'on', 'please', 'script', 'that', 'the', 'this', 'to', 'what', 'why', 'with', 'work'}

CHAT_SYSTEM = 'You are Soma, a highly capable local AI scout with full access to the filesystem.\n- list_directory: explore folders   - read_file: read files\n- Output tool calls as valid JSON in a code block, e.g.:\n```json\n{"name": "list_directory", "arguments": {"path": "/Users/daliys"}}\n```'

OLLAMA_SUMMARY_SYSTEM = 'You summarize pre-gathered debugging evidence for a larger model.\nReturn JSON only with this exact shape:\n{\n  "summary": "one or two sentences",\n  "assumptions": ["..."],\n  "open_questions": ["..."],\n  "confidence": 0.0\n}\n\nRules:\n- Use only the provided evidence.\n- Keep assumptions and open_questions concise.\n- confidence must be between 0 and 1.\n'
