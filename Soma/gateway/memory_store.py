from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

SOMA_MEMORY_DIR = Path.home() / '.soma'

class MemoryStore:
    def project_dir(self, project_root: str | None) -> Path:
        if project_root:
            path = Path(project_root) / ".soma"
        else:
            path = SOMA_MEMORY_DIR / "default"
        path.mkdir(parents=True, exist_ok=True)
        return path

    def _json_file(self, project_root: str | None, name: str) -> Path:
        return self.project_dir(project_root) / name

    def load(self, project_root: str | None) -> dict[str, Any]:
        memory = {"notes": [], "known_issues": [], "patterns": []}
        legacy = self._json_file(project_root, "memory.json")
        if legacy.exists():
            try:
                memory.update(json.loads(legacy.read_text()))
            except Exception:
                pass
        known = self._json_file(project_root, "known_issues.json")
        if known.exists():
            try:
                data = json.loads(known.read_text())
                memory["known_issues"] = data if isinstance(data, list) else data.get("known_issues", [])
            except Exception:
                pass
        return memory

    def save(self, project_root: str | None, memory: dict[str, Any]) -> None:
        self._json_file(project_root, "memory.json").write_text(json.dumps(memory, indent=2, sort_keys=True))
        known = memory.get("known_issues") or []
        self._json_file(project_root, "known_issues.json").write_text(json.dumps(known, indent=2, sort_keys=True))

    def append(self, project_root: str | None, category: str, content: str) -> dict[str, Any]:
        memory = self.load(project_root)
        category = category if category in {"notes", "known_issues", "patterns"} else "notes"
        clean_content = content.strip()[:2000]
        memory.setdefault(category, []).append({"text": clean_content, "timestamp": int(time.time())})
        self.save(project_root, memory)
        return memory

    def write_map(self, project_root: str | None, map_data: dict[str, Any]) -> None:
        self._json_file(project_root, "map.json").write_text(json.dumps(map_data, indent=2, sort_keys=True))
        architecture = self.project_dir(project_root) / "architecture.md"
        if not architecture.exists():
            architecture.write_text("# Architecture\n\nProject architecture notes captured by Soma.\n")
