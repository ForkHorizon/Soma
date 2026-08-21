import json

import os


import subprocess


import uuid

from .config import *


class GoDaemon:
    _instance = None

    def __init__(self):
        go_scanner_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "go_scanner")
        go_scanner_path = os.path.join(go_scanner_dir, "soma_scanner")
        if (not os.path.exists(go_scanner_path)) or (not os.access(go_scanner_path, os.X_OK)):
            raise RuntimeError(
                f"soma_scanner binary not found at {go_scanner_path}. It must be pre-compiled during the build phase."
            )
        self.process = subprocess.Popen(
            [go_scanner_path, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1
        )

    @classmethod
    def get_instance(cls):
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def call(self, method, *args):
        req_id = str(uuid.uuid4())
        req = {"id": req_id, "method": method, "args": list(args)}
        self.process.stdin.write((json.dumps(req) + "\n"))
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise Exception("Daemon process terminated unexpectedly")
        resp = json.loads(line)
        if resp.get("error"):
            raise Exception(resp["error"])
        return resp.get("data", "")

    def stream_call(self, method, *args):
        req_id = str(uuid.uuid4())
        req = {"id": req_id, "method": method, "args": list(args)}
        self.process.stdin.write((json.dumps(req) + "\n"))
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise Exception("Daemon process terminated unexpectedly")
            resp = json.loads(line)
            if resp.get("error"):
                raise Exception(resp["error"])

            if resp.get("data"):
                yield resp["data"]

            if resp.get("done"):
                break


def stop_daemon():
    if GoDaemon._instance:
        process = GoDaemon._instance.process

        if process.stdin:
            process.stdin.close()
        if process.stdout:
            process.stdout.close()

        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

        GoDaemon._instance = None
