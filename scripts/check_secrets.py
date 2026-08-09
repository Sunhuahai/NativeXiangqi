#!/usr/bin/env python3
"""Reject a small set of high-confidence credential formats in repository files."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_FILE_BYTES = 2 * 1024 * 1024
SELF = Path(__file__).resolve()

PATTERNS = {
    "AWS access key": re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    "GitHub token": re.compile(rb"\bgh" + rb"[opsu]_[A-Za-z0-9]{36,255}\b"),
    "private key": re.compile(
        rb"-----BEGIN (?:RSA |EC |OPENSSH )?" + rb"PRIVATE KEY-----"
    ),
}


def paths() -> list[Path]:
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
    findings: list[str] = []
    checked = 0
    for path in paths():
        if path.resolve() == SELF or not path.is_file():
            continue
        data = path.read_bytes()
        if len(data) > MAX_FILE_BYTES or b"\0" in data:
            continue
        checked += 1
        for label, pattern in PATTERNS.items():
            if pattern.search(data):
                findings.append(f"{path.relative_to(ROOT)}: possible {label}")

    if findings:
        print("\n".join(findings), file=sys.stderr)
        return 1
    print(f"secret pattern check passed for {checked} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
