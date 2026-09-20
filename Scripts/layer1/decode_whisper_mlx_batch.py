#!/usr/bin/env python3
"""Run Whisper large-v3 MLX over a Layer-1 manifest in one process."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from decode_whisper_mlx import decode


def main() -> int:
    manifest = Path(sys.argv[1])
    for row in (json.loads(line) for line in manifest.read_text().splitlines() if line.strip()):
        result = decode(row["audio"])
        result["id"], result["file"] = row["id"], row["file"]
        print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
