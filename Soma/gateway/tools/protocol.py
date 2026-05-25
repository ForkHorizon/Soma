from __future__ import annotations


CODEX_TRACKING_HINT = "Pass run_id/task_id plus client='codex' and workflow='live_mcp' on follow-up Soma calls so the packet usefulness loop can count live tool use."

CODEX_START_NEXT_CALLS = [
    CODEX_TRACKING_HINT,
    "Start from this packet, then call soma_code_context only for one missing area.",
    "After edits or tests, call soma_delta; before final review, call soma_review.",
]

CODEX_FOLLOWUP_NEXT_CALLS = [
    CODEX_TRACKING_HINT,
    "Use the returned evidence before opening broad files manually.",
    "After edits or tests, call soma_delta; before final answer, call soma_review when regressions or missing tests matter.",
]


def codex_next_calls(*items: str) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for item in [*items, *CODEX_FOLLOWUP_NEXT_CALLS]:
        text = item.strip()
        if text and text not in seen:
            seen.add(text)
            result.append(text)
    return result[:5]
