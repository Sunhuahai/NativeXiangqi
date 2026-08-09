#!/usr/bin/env python3
"""Run the T040 deterministic fuzz smoke suites under bounded offline limits."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TIMEOUT_SECONDS = 180


def terminate_process_group(process: subprocess.Popen[object], signal_number: int) -> None:
    """Request process-group termination without replacing the timeout result."""

    try:
        os.killpg(process.pid, signal_number)
    except ProcessLookupError:
        # The process exited after `wait` timed out but before the kill request.
        pass


def run(label: str, command: list[str], environment: dict[str, str]) -> None:
    """Run one isolated subprocess and fail closed if it exceeds the wall budget."""

    print(f"fuzz-smoke: {label}", flush=True)
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=environment,
        start_new_session=True,
    )
    try:
        result = process.wait(timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        print(
            f"fuzz-smoke: {label} exceeded the {TIMEOUT_SECONDS}-second wall-clock limit",
            file=sys.stderr,
        )
        terminate_process_group(process, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            terminate_process_group(process, signal.SIGKILL)
            process.wait()
        raise SystemExit(124) from None
    if result != 0:
        raise SystemExit(result)


def main() -> int:
    environment = os.environ.copy()
    environment["CARGO_NET_OFFLINE"] = "true"

    run(
        "stage local Debug Rust artifacts",
        [str(ROOT / "scripts" / "build-rust-artifacts.sh"), "debug"],
        environment,
    )
    run(
        "Rust FEN/UCCI corpus",
        [
            "cargo",
            "test",
            "--locked",
            "--offline",
            "-p",
            "xiangqi-io",
            "--test",
            "fuzz_smoke",
            "--",
            "--test-threads=1",
        ],
        environment,
    )
    run(
        "Swift .xqgame corpus",
        [
            "xcrun",
            "swift",
            "test",
            "--package-path",
            str(ROOT / "Packages" / "XiangqiDocumentKit"),
            "--configuration",
            "debug",
            "--filter",
            "NativeXiangqiDocumentFuzzSmokeTests",
        ],
        environment,
    )
    print("fuzz-smoke: bounded offline corpus passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
