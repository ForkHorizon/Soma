import glob

clean_imports = """from __future__ import annotations
import json
from typing import Any
from mcp.core import (
    _error_response, _compact_result, _ok_response, _safe_text, _json, 
    _safe_nexus_result, _append_graph_context, _enforce_packet_budget, 
    _evidence_summary, _packet_budget, _analysis_depth, _parse_ports,
    nexus, graphify, memory_store
)
from scout_pipeline import (
    run_gather, run_review, run_changes_delta, run_debug,
    get_git_status, get_git_diff_summary, build_repo_index, iter_project_files,
    build_preflight, select_evidence, find_errors, build_codex_packet, estimate_tokens,
    classify_prompt_intent, dedupe_strings, get_active_project_root, prompt_terms,
    detect_project_type, TOKEN_BUDGETS, MAX_ERROR_LINES, MAX_EVIDENCE_ITEMS
)
from soma_logger import log_tool_call
"""


def clean_file(path, extra=""):
    with open(path, "r") as fh:
        lines = fh.readlines()

    start_idx = 0
    for i, line in enumerate(lines):
        if line.startswith("@log_tool_call") or line.startswith("async def"):
            start_idx = i
            break

    content = clean_imports + extra + "".join(lines[start_idx:])
    with open(path, "w") as fh:
        fh.write(content)


clean_file("/Users/daliys/Daliys/Swift/Soma/Soma/mcp/tools/context.py")
clean_file("/Users/daliys/Daliys/Swift/Soma/Soma/mcp/tools/nexus.py")
clean_file(
    "/Users/daliys/Daliys/Swift/Soma/Soma/mcp/tools/query.py", "from mcp.tools.context import soma_prepare_context\n"
)
clean_file("/Users/daliys/Daliys/Swift/Soma/Soma/mcp/tools/memory.py")

print("Cleaned tools imports.")
