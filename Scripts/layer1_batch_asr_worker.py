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
import subprocess
import sys
from pathlib import Path


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
    try:
        completed = subprocess.run(command, capture_output=True, text=True, env=environment, check=False)
    except OSError as error:
        return fail(f"Could not start {args.model}: {error}")
    if completed.stdout:
        sys.stdout.write(completed.stdout)
        sys.stdout.flush()
    if completed.returncode != 0:
        message = completed.stderr.strip() or f"{args.model} exited with {completed.returncode}"
        return fail(message)
    return 0


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
