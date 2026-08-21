from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path


DEFAULT_CHANGE_MARKER = "\n// soma fixture change\n"


def prepare_fixture_repo(template: Path) -> tuple[tempfile.TemporaryDirectory, Path]:
    tmp = tempfile.TemporaryDirectory()
    root = Path(tmp.name) / template.name
    shutil.copytree(template, root)

    subprocess.run(["git", "init"], cwd=root, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "soma@example.test"], cwd=root, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "Soma Fixture"], cwd=root, check=True, capture_output=True)
    subprocess.run(["git", "add", "."], cwd=root, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-m", "fixture baseline"], cwd=root, check=True, capture_output=True)

    changed = _choose_change_file(root)
    with changed.open("a", encoding="utf-8") as handle:
        handle.write(_change_marker_for(changed))
    return tmp, root


def fixture_templates(fixtures_dir: str | Path) -> list[Path]:
    root = Path(fixtures_dir)
    return sorted(path for path in root.iterdir() if path.is_dir() and not path.name.startswith("."))


def _choose_change_file(root: Path) -> Path:
    preferred_suffixes = [
        ".swift",
        ".py",
        ".ts",
        ".go",
        ".rs",
        ".cpp",
        ".java",
        ".kt",
        ".php",
        ".rb",
        ".sh",
        ".sql",
        ".md",
    ]
    for suffix in preferred_suffixes:
        matches = sorted(path for path in root.rglob(f"*{suffix}") if ".git" not in path.parts)
        if matches:
            return matches[0]
    return next(path for path in root.rglob("*") if path.is_file() and ".git" not in path.parts)


def _change_marker_for(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in {".py", ".rb", ".sh"}:
        return "\n# soma fixture change\n"
    if suffix in {".sql"}:
        return "\n-- soma fixture change\n"
    if suffix in {".md", ".txt", ".log"}:
        return "\nsoma fixture change\n"
    return DEFAULT_CHANGE_MARKER
