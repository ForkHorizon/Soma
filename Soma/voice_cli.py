#!/usr/bin/env python3
"""Command line and LaunchAgent installation for Soma Voice Server.

Imports of voice_server are deliberately deferred into main(): voice_server
re-exports these entry points, and a module-level import would cycle.
"""
from __future__ import annotations

import argparse
import os
import plistlib
import signal
import sys
from pathlib import Path
from typing import Any

SERVER_SCRIPT = Path(__file__).with_name("voice_server.py")

def install_launch_agent(args: argparse.Namespace) -> Path:
    plist = Path.home() / "Library/LaunchAgents/com.daliys.soma.voice-server.plist"
    plist.parent.mkdir(parents=True, exist_ok=True)
    env = {}
    token = args.token or os.environ.get("SOMA_VOICE_TOKEN")
    if token:
        env["SOMA_VOICE_TOKEN"] = token
    program_args = [
        sys.executable,
        str(SERVER_SCRIPT.resolve()),
        "--host",
        args.host,
        "--port",
        str(args.port),
        "--asr-root",
        str(args.asr_root),
        "--idle-seconds",
        str(args.idle_seconds),
        "--max-queue",
        str(args.max_queue),
        "--max-background-queue",
        str(args.max_background_queue),
        "--abandoned-session-ttl",
        str(args.abandoned_session_ttl),
    ]
    if args.models_root:
        program_args += ["--models-root", str(args.models_root)]
    if args.allow_unauthenticated_local:
        program_args.append("--allow-unauthenticated-local")
    data = {
        "Label": "com.daliys.soma.voice-server",
        "ProgramArguments": program_args,
        "EnvironmentVariables": env,
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": str(Path.home() / "Library/Logs/soma-voice-server.out.log"),
        "StandardErrorPath": str(Path.home() / "Library/Logs/soma-voice-server.err.log"),
    }
    plist.write_bytes(plistlib.dumps(data))
    return plist


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Soma Voice Server")
    parser.add_argument("--host", default=os.environ.get("SOMA_VOICE_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("SOMA_VOICE_PORT", "8765")))
    parser.add_argument("--token", default=os.environ.get("SOMA_VOICE_TOKEN", ""))
    parser.add_argument("--asr-root", type=Path, default=Path(os.environ.get("SOMA_VOICE_ASR_ROOT", "~/soma-asr-bench")).expanduser())
    parser.add_argument("--models-root", type=Path, default=None)
    parser.add_argument("--idle-seconds", type=int, default=int(os.environ.get("SOMA_VOICE_IDLE_SECONDS", "3600")))
    parser.add_argument("--max-queue", type=int, default=int(os.environ.get("SOMA_VOICE_MAX_QUEUE", "0")))
    parser.add_argument("--max-background-queue", type=int, default=int(os.environ.get("SOMA_VOICE_MAX_BACKGROUND_QUEUE", "0")))
    parser.add_argument("--abandoned-session-ttl", type=int, default=int(os.environ.get("SOMA_VOICE_ABANDONED_SESSION_TTL", "86400")))
    parser.add_argument("--install-launch-agent", action="store_true")
    parser.add_argument("--allow-unauthenticated-local", action="store_true", help="Allow local-only requests without a bearer token")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    args.token = args.token.strip()
    if not args.token and not args.allow_unauthenticated_local:
        print("SOMA_VOICE_TOKEN is required unless --allow-unauthenticated-local is set.", file=sys.stderr)
        raise SystemExit(2)
    if args.install_launch_agent:
        plist = install_launch_agent(args)
        print(f"installed {plist}")
        return

    from http.server import ThreadingHTTPServer

    from voice_backend_broker import BackendBroker
    from voice_http import make_handler
    from voice_server import VoiceServerState

    runtime_dir = Path.home() / "Library/Application Support/Soma/VoiceServer"
    broker = BackendBroker(args.asr_root, runtime_dir, args.idle_seconds, args.models_root)
    state = VoiceServerState(
        args.token,
        broker,
        idle_seconds=args.idle_seconds,
        max_queue=args.max_queue,
        max_background_queue=args.max_background_queue,
        abandoned_session_ttl=args.abandoned_session_ttl,
        allow_unauthenticated_local=args.allow_unauthenticated_local,
    )
    server = ThreadingHTTPServer((args.host, args.port), make_handler(state))

    def stop(_signum: int, _frame: Any) -> None:
        broker.stop()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"[soma-voice-server] listening on {args.host}:{args.port} asr_root={args.asr_root}", flush=True)
    server.serve_forever()


