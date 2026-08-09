#!/usr/bin/env python3
"""Check the pinned NativeXiangqi toolchain without installing or downloading it."""

from __future__ import annotations

import platform
import re
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIN_PATH = ROOT / "rust-toolchain.toml"
CONFIG_PIN_PATH = ROOT / "config" / "rust-toolchain.toml"
TIMEOUT_SECONDS = 10


def run(command: list[str]) -> tuple[bool, str]:
    try:
        result = subprocess.run(
            command,
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, str(error)
    output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
    return result.returncode == 0, output


def report(ok: bool, label: str, detail: str) -> bool:
    marker = "ok" if ok else "error"
    first_line = detail.splitlines()[0] if detail else "no version output"
    print(f"[{marker}] {label}: {first_line}")
    return ok


def load_toolchain(path: Path) -> dict[str, object]:
    with path.open("rb") as file:
        parsed = tomllib.load(file)
    toolchain = parsed.get("toolchain")
    if not isinstance(toolchain, dict):
        raise ValueError(f"{path.relative_to(ROOT)} has no [toolchain] table")
    return toolchain


def main() -> int:
    checks: list[bool] = []

    architecture = platform.machine()
    checks.append(report(architecture == "arm64", "architecture", architecture))

    xcode_ok, xcode_output = run(["xcodebuild", "-version"])
    xcode_match = re.search(r"^Xcode\s+(\d+)(?:\.\d+)*", xcode_output, re.MULTILINE)
    expected_xcode = 26
    xcode_version_ok = xcode_ok and xcode_match is not None and int(xcode_match.group(1)) == expected_xcode
    xcode_detail = xcode_output
    if xcode_ok and xcode_match is not None and not xcode_version_ok:
        detected_version = xcode_output.splitlines()[0]
        xcode_detail = (
            f"{detected_version} detected; repository pins Xcode {expected_xcode}.x"
        )
    checks.append(
        report(
            xcode_version_ok,
            "Xcode",
            xcode_detail
            or "full Xcode is unavailable; install Xcode 26.x and select its Developer directory",
        )
    )

    swift_ok, swift_output = run(["xcrun", "swift", "--version"])
    swift_match = re.search(r"Apple Swift version\s+(\d+)", swift_output)
    checks.append(
        report(
            swift_ok and swift_match is not None and int(swift_match.group(1)) >= 6,
            "Swift",
            swift_output,
        )
    )

    try:
        root_pin = load_toolchain(PIN_PATH)
        config_pin = load_toolchain(CONFIG_PIN_PATH)
        pin_keys = ("channel", "profile", "components", "targets")
        pins_match = all(root_pin.get(key) == config_pin.get(key) for key in pin_keys)
        checks.append(report(pins_match, "Rust pin", str(root_pin.get("channel", "missing"))))
        channel = root_pin["channel"]
        if not isinstance(channel, str):
            raise ValueError("Rust channel must be a string")
    except (OSError, KeyError, ValueError, tomllib.TOMLDecodeError) as error:
        checks.append(report(False, "Rust pin", str(error)))
        channel = ""

    rustup_ok, installed_output = run(["rustup", "toolchain", "list"])
    installed = rustup_ok and any(
        line.split()[0].startswith(f"{channel}-") or line.split()[0] == channel
        for line in installed_output.splitlines()
        if line.split()
    )
    checks.append(
        report(
            installed,
            "Rust toolchain installed",
            channel if installed else f"{channel} is not installed; run rustup explicitly",
        )
    )

    if installed:
        rustc_ok, rustc_output = run(["rustup", "run", channel, "rustc", "--version"])
        cargo_ok, cargo_output = run(["rustup", "run", channel, "cargo", "--version"])
        component_ok, component_output = run(
            ["rustup", "component", "list", "--toolchain", channel, "--installed"]
        )
        required_components = {"cargo", "clippy", "rustfmt", "rust-std", "rustc"}
        installed_components = {
            line.split()[0] for line in component_output.splitlines() if line.split()
        }
        missing_components = {
            component
            for component in required_components
            if not any(
                installed == component or installed.startswith(f"{component}-")
                for installed in installed_components
            )
        }
        checks.append(report(rustc_ok, "rustc", rustc_output))
        checks.append(report(cargo_ok, "cargo", cargo_output))
        checks.append(
            report(
                component_ok and not missing_components,
                "Rust components",
                (
                    ", ".join(sorted(required_components))
                    if not missing_components
                    else f"missing {', '.join(sorted(missing_components))}"
                ),
            )
        )

    make_path = shutil.which("make")
    make_ok, make_output = run(["make", "--version"]) if make_path else (False, "make not found")
    checks.append(report(make_ok, "Make", make_output))

    python_ok = sys.version_info >= (3, 11)
    checks.append(report(python_ok, "Python", platform.python_version()))

    if all(checks):
        print("bootstrap checks passed; no tools were installed or downloaded")
        return 0

    print("bootstrap checks failed; no tools were installed or downloaded", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
