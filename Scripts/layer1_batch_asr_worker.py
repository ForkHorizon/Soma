#!/usr/bin/env python3
"""Run one Layer-1 model command over a manifest of audio files.

The command must load its model once, process the manifest, and print one JSON
object per input row containing the same ``id``. Partial output is forwarded
when the child fails, but the non-zero exit status makes the caller fail the
whole user batch transactionally.
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
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--version", default="unversioned")
    parser.add_argument("--command", default="")
    args = parser.parse_args()

    manifest = Path(args.manifest)
    if not manifest.is_file():
        return fail(f"Batch manifest does not exist: {manifest}")
    command = [part for part in args.command.split("\x1f") if part]
    if not command:
        return fail(f"No batch command configured for Layer 1 model {args.model}")
    command = [part.replace("{manifest}", str(manifest)).replace("{model}", args.model) for part in command]
    environment = dict(os.environ)
    environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:" + environment.get("PATH", "")
    environment["SOMA_LAYER1_MANIFEST"] = str(manifest)
    environment["SOMA_LAYER1_MODEL"] = args.model
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

    if stdout:
        sys.stdout.write(stdout)
        sys.stdout.flush()
    if returncode != 0:
        message = stderr.strip() or f"{args.model} exited with {returncode}"
        return fail(message)
    return 0


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
