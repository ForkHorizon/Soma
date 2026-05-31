"""Evidence selection facade.

Implementation is split into scope, ranking, selection, preflight, and quality
modules so each piece stays readable and independently testable.
"""
import os
import re
import subprocess
import sys

from .gather_preflight import build_preflight
from .gather_quality import (
    assess_evidence_quality,
    assess_plan_alignment,
    repair_evidence_from_plan,
)
from .gather_rank import file_rank
from .gather_scope import (
    _candidate_items,
    _is_under_path,
    _package_json_metadata,
    _prompt_reference_fragments,
    extract_explicit_paths,
    focus_seed_paths,
    infer_focus_scope,
)
from .gather_select import (
    _command_evidence_item,
    _graphify_command_evidence,
    _is_graphify_update_review_prompt,
    _run_command,
    build_open_source_reason,
    build_reason,
    evidence_item_from_path,
    evidence_policy_summary,
    gather_external_evidence,
    select_evidence,
)

__all__ = [
    "assess_evidence_quality",
    "assess_plan_alignment",
    "build_open_source_reason",
    "build_preflight",
    "build_reason",
    "evidence_item_from_path",
    "evidence_policy_summary",
    "extract_explicit_paths",
    "file_rank",
    "focus_seed_paths",
    "gather_external_evidence",
    "infer_focus_scope",
    "repair_evidence_from_plan",
    "select_evidence",
    "os",
    "re",
    "subprocess",
    "sys",
]
