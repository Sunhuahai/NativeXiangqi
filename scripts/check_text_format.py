#!/usr/bin/env python3
"""Bounded whitespace and newline checks for repository text files."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_FILE_BYTES = 2 * 1024 * 1024
SKIPPED_SUFFIXES = {
    ".7z",
    ".bin",
    ".dylib",
    ".gz",
    ".ico",
    ".jpeg",
    ".jpg",
    ".nnue",
    ".pdf",
    ".png",
    ".so",
    ".tar",
    ".xcresult",
    ".zip",
}


def candidate_paths() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return [ROOT / line for line in result.stdout.splitlines() if line]


def main() -> int:
    errors: list[str] = []
    checked = 0
    for path in candidate_paths():
        if not path.is_file() or path.suffix.lower() in SKIPPED_SUFFIXES:
            continue
        data = path.read_bytes()
        relative = path.relative_to(ROOT)
        if len(data) > MAX_FILE_BYTES:
            errors.append(f"{relative}: text file exceeds {MAX_FILE_BYTES} bytes")
            continue
        if b"\0" in data:
            continue
        checked += 1
        if b"\r" in data:
            errors.append(f"{relative}: CR line ending is not allowed")
        if data and not data.endswith(b"\n"):
            errors.append(f"{relative}: missing final newline")
        if data.endswith(b"\n\n"):
            errors.append(f"{relative}: extra blank line at end of file")
        for number, line in enumerate(data.splitlines(), start=1):
            if line.endswith((b" ", b"\t")):
                errors.append(f"{relative}:{number}: trailing whitespace")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"text formatting passed for {checked} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
