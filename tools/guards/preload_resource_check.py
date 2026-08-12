#!/usr/bin/env python3
"""Ensure literal GDScript preload targets exist in the Godot project."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from guard_common import REPO_ROOT  # noqa: E402


GAME_ROOT = REPO_ROOT / "game"
PRELOAD_RE = re.compile(
    r'''preload\s*\(\s*(["'])(res://[^"']+)\1\s*\)''',
    re.DOTALL,
)


def tracked_gdscript_paths() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "--", "game"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return [
        REPO_ROOT / line
        for line in result.stdout.splitlines()
        if line.endswith(".gd")
    ]


def main() -> int:
    checked = 0
    failures: list[str] = []
    for source_path in tracked_gdscript_paths():
        source = source_path.read_text(encoding="utf-8")
        for match in PRELOAD_RE.finditer(source):
            checked += 1
            resource_path = match.group(2)
            disk_path = GAME_ROOT / resource_path.removeprefix("res://")
            if not disk_path.is_file():
                relative_source = source_path.relative_to(REPO_ROOT)
                failures.append(f"{relative_source}: {resource_path}")

    if failures:
        print("GDScript preload 资源检查失败，以下目标文件不存在：")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print(f"PRELOAD_RESOURCE_CHECK_PASS references={checked}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
