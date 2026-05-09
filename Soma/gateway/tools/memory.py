from __future__ import annotations

from gateway.core import (
    _error_response,
    _ok_response,
    get_active_project_root,
    memory_store,
)


async def soma_remember(action: str, content: str = "", category: str = "notes") -> str:
    """Save, list, or clear structured project memory."""
    project_root = get_active_project_root()
    action = action.lower().strip()
    if action == "save":
        if not content.strip():
            return _error_response("No memory content supplied.")
        memory = memory_store.append(project_root, category, content)
        return _ok_response(
            "Saved structured project memory.",
            memory_counts={key: len(memory.get(key, [])) for key in ("notes", "known_issues", "patterns")},
            omitted={"max_saved_chars": 2000, "category": category},
        )
    if action == "list":
        memory = memory_store.load(project_root)
        return _ok_response(
            "Loaded project memory.",
            memory={
                "notes": memory.get("notes", [])[-5:],
                "known_issues": memory.get("known_issues", [])[-5:],
                "patterns": memory.get("patterns", [])[-5:],
            },
        )
    if action == "clear":
        memory_store.save(project_root, {"notes": [], "known_issues": [], "patterns": []})
        return _ok_response("Project memory cleared.")
    return _error_response("Unknown memory action.", next_calls=["Use action save, list, or clear."])
