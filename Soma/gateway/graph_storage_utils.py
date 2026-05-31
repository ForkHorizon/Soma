from __future__ import annotations

import re
from pathlib import Path
from typing import Any

GRAPHIFY_BASE_DIR = Path.home() / ".soma" / "graphs"
GRAPH_STALE_SECONDS = 24 * 60 * 60


def dedupe_paths(paths: list[Path]) -> list[Path]:
    seen: set[str] = set()
    result: list[Path] = []
    for path in paths:
        key = str(path.expanduser().resolve(strict=False))
        if key in seen:
            continue
        seen.add(key)
        result.append(path)
    return result


def version_tuple(version: str | None) -> tuple[int, ...]:
    if not version:
        return ()
    return tuple(int(part) for part in re.findall(r"\d+", version)[:4])


def diagnostic_degraded_reason(summary: dict[str, Any]) -> tuple[bool, str | None]:
    collapsed = max(
        int(summary.get("directed_same_endpoint_collapsed_edges") or 0),
        int(summary.get("undirected_same_endpoint_collapsed_edges") or 0),
    )
    malformed = sum(
        int(summary.get(key) or 0)
        for key in ("non_object_edges", "missing_endpoint_edges", "dangling_endpoint_edges")
    )
    post_build_error = str(summary.get("post_build_error") or "").strip()
    if post_build_error:
        return True, f"post-build graph error: {post_build_error[:160]}"
    if malformed:
        return True, f"{malformed} malformed graph edge(s) found."
    if collapsed:
        return True, f"{collapsed} edge(s) may collapse in non-multigraph consumers."
    return False, None
