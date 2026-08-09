#!/usr/bin/env python3
"""Prove that the T000 application build has no remote dependencies or download hooks."""

from __future__ import annotations

import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "App" / "NativeXiangqi" / "NativeXiangqi.xcodeproj" / "project.pbxproj"
ENTITLEMENTS = ROOT / "App" / "NativeXiangqi" / "Resources" / "NativeXiangqi.entitlements"
WORKSPACE = ROOT / "NativeXiangqi.xcworkspace" / "contents.xcworkspacedata"
BUILD_SCRIPT = ROOT / "scripts" / "build-app.sh"
RUST_ARTIFACT_SCRIPT = ROOT / "scripts" / "build-rust-artifacts.sh"
MAX_FILE_BYTES = 2 * 1024 * 1024


class BuildPolicyError(ValueError):
    """A build input could download code/assets or enable runtime networking."""


def text(path: Path) -> str:
    data = path.read_bytes()
    if len(data) > MAX_FILE_BYTES:
        raise BuildPolicyError(f"{path.relative_to(ROOT)} exceeds {MAX_FILE_BYTES} bytes")
    return data.decode("utf-8")


def reject(pattern: str, content: str, label: str, flags: int = 0) -> None:
    if re.search(pattern, content, flags):
        raise BuildPolicyError(label)


def main() -> int:
    try:
        project = text(PROJECT)
        reject(r"PBXShellScriptBuildPhase", project, "Xcode shell build phases are forbidden")
        reject(
            r"XCRemoteSwiftPackageReference",
            project,
            "remote Swift package references are forbidden",
        )
        if len(re.findall(r"isa = XCLocalSwiftPackageReference;", project)) != 1:
            raise BuildPolicyError("exactly one local XiangqiDocumentKit package reference is required")
        if "relativePath = ../../Packages/XiangqiDocumentKit;" not in project:
            raise BuildPolicyError("XiangqiDocumentKit must remain a repository-local package")
        if "productName = XiangqiDocumentKit;" not in project:
            raise BuildPolicyError("app must link the local XiangqiDocumentKit product")
        required_settings = (
            "ARCHS = arm64;",
            "MACOSX_DEPLOYMENT_TARGET = 15.0;",
            "ENABLE_APP_SANDBOX = YES;",
            "ENABLE_HARDENED_RUNTIME = YES;",
            "SWIFT_STRICT_CONCURRENCY = complete;",
            "SWIFT_VERSION = 6.0;",
        )
        for setting in required_settings:
            if setting not in project:
                raise BuildPolicyError(f"missing required Xcode setting: {setting}")

        package_files = sorted((ROOT / "Packages").glob("*/Package.swift"))
        if len(package_files) != 4:
            raise BuildPolicyError("exactly four local Swift package manifests are required")
        allowed_local_dependencies = {
            ROOT / "Packages" / "XiangqiDocumentKit" / "Package.swift": {
                "../XiangqiCoreBinary",
                "../XiangqiUI",
            }
        }
        for path in package_files:
            package = text(path)
            local_dependencies = set(
                re.findall(r'\.package\s*\(\s*path\s*:\s*"([^"]+)"\s*\)', package)
            )
            if local_dependencies != allowed_local_dependencies.get(path, set()):
                raise BuildPolicyError(f"unexpected local package dependency declaration in {path}")
            without_local_paths = re.sub(
                r'\.package\s*\(\s*path\s*:\s*"[^"]+"\s*\)',
                "",
                package,
            )
            reject(r"\.package\s*\(", without_local_paths, f"remote dependency declaration in {path}")
            reject(r"https?://", package, f"remote URL in {path}")

        package_swift_sources: list[Path] = []
        for package in (ROOT / "Packages").iterdir():
            if not package.is_dir():
                continue
            for directory_name in ("Sources", "Tests"):
                source_root = package / directory_name
                if source_root.is_dir():
                    package_swift_sources.extend(sorted(source_root.rglob("*.swift")))
        for path in package_swift_sources:
            if "XiangqiCoreBinary" in path.parts:
                continue
            source = text(path)
            reject(
                r"\bimport\s+XiangqiCoreFFI\b",
                source,
                f"direct FFI import outside XiangqiCoreBinary in {path.relative_to(ROOT)}",
            )
            reject(
                r"\bxq_[a-z0-9_]+\s*\(",
                source,
                f"direct FFI call outside XiangqiCoreBinary in {path.relative_to(ROOT)}",
            )

        for path in sorted((ROOT / "App").rglob("*.swift")):
            source = text(path)
            reject(
                r"\b(?:URLSession|NSURLConnection|NWConnection)\b",
                source,
                f"runtime network API in {path.relative_to(ROOT)}",
            )
            reject(r"https?://", source, f"remote URL in {path.relative_to(ROOT)}")

        with ENTITLEMENTS.open("rb") as file:
            entitlements = plistlib.load(file)
        allowed_entitlements = {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.user-selected.read-write": True,
        }
        if entitlements != allowed_entitlements:
            raise BuildPolicyError(
                "entitlements must contain only App Sandbox plus user-selected read/write and no network entitlement"
            )

        workspace_root = ET.fromstring(text(WORKSPACE))
        file_refs = [element.attrib.get("location", "") for element in workspace_root]
        expected_ref = "group:App/NativeXiangqi/NativeXiangqi.xcodeproj"
        if file_refs != [expected_ref]:
            raise BuildPolicyError("workspace may reference only the local app project")

        build_script = text(BUILD_SCRIPT).lower()
        for command in ("curl", "wget", "git clone", "cargo fetch", "swift package resolve"):
            if command in build_script:
                raise BuildPolicyError(f"download command in build-app.sh: {command}")
        if "-disableautomaticpackageresolution" not in build_script:
            raise BuildPolicyError("xcodebuild must disable automatic package resolution")

        artifact_script = text(RUST_ARTIFACT_SCRIPT).lower()
        for command in ("curl", "wget", "git clone", "cargo fetch", "swift package resolve"):
            if command in artifact_script:
                raise BuildPolicyError(f"download command in build-rust-artifacts.sh: {command}")
        if "--offline" not in artifact_script:
            raise BuildPolicyError("Rust artifact builds must pass Cargo --offline")
    except (OSError, UnicodeDecodeError, plistlib.InvalidFileException, ET.ParseError, BuildPolicyError) as error:
        print(f"no-network build check failed: {error}", file=sys.stderr)
        return 1

    print(
        "no-network build check passed: local project, local packages, user-selected files only, no network entitlement"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
