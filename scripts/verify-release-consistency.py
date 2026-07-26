#!/usr/bin/env python3
"""Fail when release, frontend and repository target identifiers diverge."""

from __future__ import annotations

import ast
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def constants(path: Path) -> dict[str, str]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    result: dict[str, str] = {}
    for node in tree.body:
        if (
            isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, str)
        ):
            result[node.targets[0].id] = node.value.value
    return result


def main() -> None:
    release = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", release):
        raise SystemExit(f"VERSION is not semantic: {release!r}")

    backend = constants(ROOT / "backend/app/version.py")
    frontend = json.loads((ROOT / "frontend/package.json").read_text(encoding="utf-8"))
    lock = json.loads((ROOT / "frontend/package-lock.json").read_text(encoding="utf-8"))
    versions = {
        "VERSION": release,
        "backend APPLICATION_VERSION": backend.get("APPLICATION_VERSION", ""),
        "frontend package": str(frontend.get("version", "")),
        "frontend lock root": str(lock.get("packages", {}).get("", {}).get("version", "")),
    }
    mismatches = {name: value for name, value in versions.items() if value != release}
    if mismatches:
        raise SystemExit(f"release version mismatch: {mismatches}")

    manifest_lines = [
        line
        for line in (ROOT / "sql/repository-migrations.manifest")
        .read_text(encoding="utf-8")
        .splitlines()
        if line and not line.startswith("#")
    ]
    manifest_target = manifest_lines[-1].split("|", 1)[0] if manifest_lines else ""
    expected = backend.get("EXPECTED_MIGRATION", "")
    if expected != manifest_target:
        raise SystemExit(
            f"repository migration target mismatch: backend={expected!r}, manifest={manifest_target!r}"
        )
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    if f"## {release} " not in changelog:
        raise SystemExit(f"CHANGELOG has no {release} release heading")
    print(f"Release contract OK: application={release}, repository={expected}")


if __name__ == "__main__":
    main()
