#!/usr/bin/env python3
"""Run one configured Layer 1 model over one complete original audio file.

The Swift layer owns queueing and durable state. This tiny adapter deliberately
does not import a legacy Ground Truth script or decide consensus. A model
command is configured in GroundTruth/active/layer1/model_commands.json and must emit
either plain text or JSON: {"text": "...", "words": [{"word": ..., "start": 0,
"end": 1}], "version": "..."}. Missing commands are failures, never empty
transcripts.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
from pathlib import Path

active_proc: subprocess.Popen | None = None


def terminate_child() -> None:
    global active_proc
    if active_proc is None or active_proc.poll() is not None:
        return
    try:
        os.killpg(active_proc.pid, signal.SIGTERM)
    except OSError:
        try:
            active_proc.terminate()
        except OSError:
            pass
    try:
        active_proc.wait(timeout=2)
    except (subprocess.TimeoutExpired, OSError):
        try:
            os.killpg(active_proc.pid, signal.SIGKILL)
        except OSError:
            try:
                active_proc.kill()
            except OSError:
                pass
        try:
            active_proc.wait(timeout=1)
        except (subprocess.TimeoutExpired, OSError):
            pass


def handle_signal(signum: int, frame: object) -> None:
    terminate_child()
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)
signal.signal(signal.SIGHUP, handle_signal)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--version", default="unversioned")
    parser.add_argument("--command", default="")
    parser.add_argument("--audio-hash", required=True)
    args = parser.parse_args()
    command = [part for part in args.command.split("\x1f") if part]
    if not command:
        return fail(f"No command configured for Layer 1 model {args.model}")
    if not Path(args.audio).is_file():
        return fail(f"Source audio does not exist: {args.audio}")

    command = [
        part.replace("{audio}", args.audio).replace("{audio_hash}", args.audio_hash).replace("{model}", args.model)
        for part in command
    ]
    environment = child_environment()
    environment["SOMA_LAYER1_AUDIO"] = args.audio
    environment["SOMA_LAYER1_AUDIO_HASH"] = args.audio_hash
    global active_proc
    try:
        active_proc = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            start_new_session=True,
        )
        stdout, stderr = active_proc.communicate()
        returncode = active_proc.returncode
    except OSError as error:
        return fail(f"Could not start {args.model}: {error}")
    finally:
        active_proc = None

    if returncode != 0:
        return fail(stderr.strip() or f"{args.model} exited with {returncode}")
    output = stdout
    payload = parse_payload(output)
    if payload is None:
        print(json.dumps({"text": output.strip(), "version": args.version}, ensure_ascii=False))
        return 0
    payload.setdefault("version", args.version)
    print(json.dumps(payload, ensure_ascii=False))
    return 0


def parse_payload(output: str) -> dict | None:
    text = output.strip()
    if not text:
        return {"text": ""}
    try:
        value = json.loads(text)
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        return None


def child_environment(base: dict[str, str] | None = None) -> dict[str, str]:
    """Build the decoder environment used by both UI and tests."""
    environment = dict(os.environ if base is None else base)
    # Xcode-launched apps inherit a minimal PATH and may not see Homebrew tools.
    # GigaAM/Whisper invoke ffmpeg internally, so make the dependency explicit.
    environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:" + environment.get("PATH", "")
    return environment


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
