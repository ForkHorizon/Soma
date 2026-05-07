
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


class GoDaemon():
    _instance = None

    def __init__(self):
        from .DiscoverAndParseFiles import build_go_scanner
        go_scanner_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'go_scanner')
        go_scanner_path = os.path.join(go_scanner_dir, 'soma_scanner')
        if ((not os.path.exists(go_scanner_path)) or (not os.access(go_scanner_path, os.X_OK))):
            build_go_scanner(go_scanner_dir)
        self.process = subprocess.Popen([go_scanner_path, 'daemon'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)

    @classmethod
    def get_instance(cls):
        if (cls._instance is None):
            cls._instance = cls()
        return cls._instance

    def call(self, method, *args):
        req_id = str(uuid.uuid4())
        req = {'id': req_id, 'method': method, 'args': list(args)}
        self.process.stdin.write((json.dumps(req) + '\n'))
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if (not line):
            raise Exception('Daemon process terminated unexpectedly')
        resp = json.loads(line)
        if resp.get('error'):
            raise Exception(resp['error'])
        return resp.get('data', '')


def stop_daemon():
    from .DiscoverAndParseFiles import build_go_scanner
    if GoDaemon._instance:
        GoDaemon._instance.process.terminate()
        GoDaemon._instance = None
