#!/usr/bin/env python3
"""Fail closed if T030's custom board regresses to per-square UI machinery."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOARD = ROOT / "Packages" / "XiangqiUI" / "Sources" / "XiangqiUI" / "XiangqiBoardView.swift"
APP_DELEGATE = ROOT / "App" / "NativeXiangqi" / "Sources" / "AppDelegate.swift"
MAX_FILE_BYTES = 512 * 1024


def main() -> int:
    try:
        data = BOARD.read_bytes()
        if len(data) > MAX_FILE_BYTES:
            raise ValueError(f"{BOARD.relative_to(ROOT)} exceeds {MAX_FILE_BYTES} bytes")
        source = data.decode("utf-8")
        app_data = APP_DELEGATE.read_bytes()
        if len(app_data) > MAX_FILE_BYTES:
            raise ValueError(f"{APP_DELEGATE.relative_to(ROOT)} exceeds {MAX_FILE_BYTES} bytes")
        app_delegate = app_data.decode("utf-8")
    except (OSError, UnicodeDecodeError, ValueError) as error:
        print(f"T030 UI architecture check failed: {error}", file=sys.stderr)
        return 1

    required = (
        "public final class XiangqiBoardView: NSView",
        "virtualSquares = (0..<90).map",
        "override func draw(_ dirtyRect: NSRect)",
        "override func accessibilityChildren()",
    )
    forbidden = ("CALayer", "addSubview(", "Task {", "Task.detached", "Timer(", "NSTimer")
    for marker in required:
        if marker not in source:
            print(f"T030 UI architecture check failed: missing {marker!r}", file=sys.stderr)
            return 1
    if "redoItem.keyEquivalentModifierMask = [.command, .shift]" not in app_delegate:
        print(
            "T030 UI architecture check failed: redo must remain explicitly Shift+Command+Z",
            file=sys.stderr,
        )
        return 1
    for marker in forbidden:
        if marker in source:
            print(f"T030 UI architecture check failed: forbidden board marker {marker!r}", file=sys.stderr)
            return 1

    print("T030 UI architecture check passed: one custom view, 90 virtual AX elements, no layers/tasks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
