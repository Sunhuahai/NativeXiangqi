#!/usr/bin/env python3
"""Validate bounded Pikafish development and release manifests without dependencies."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_DIR = ROOT / "Engines" / "Pikafish" / "manifests"
SCHEMA_PATH = MANIFEST_DIR / "manifest.schema.json"
MAX_MANIFEST_BYTES = 64 * 1024
SHA256 = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
PATCH = re.compile(r"^([0-9a-f]{64})  ([^/].*)$")

TABLE_FIELDS = {
    "engine": {
        "id",
        "repository",
        "tag",
        "commit",
        "source_archive_url",
        "source_archive_sha256",
        "source_archive_bytes",
        "license_spdx",
        "license_file",
        "authors_file",
    },
    "build": {
        "host_architecture",
        "target_architecture",
        "target",
        "arch",
        "compiler",
        "compiler_version",
        "command",
        "flags",
        "make_help_file",
        "network_precondition",
    },
    "helper": {"bundled", "path", "sha256"},
    "network": {
        "bundled",
        "repository",
        "release_tag",
        "license_evidence_commit",
        "asset_id",
        "source_url",
        "filename",
        "bytes",
        "sha256",
        "license_file",
        "commercial_permission",
        "permission_scope",
        "release_asset_mutable",
    },
    "corresponding_source": {
        "prepared",
        "directory",
        "archive_path",
        "archive_sha256",
        "build_instructions",
    },
}


class ManifestError(ValueError):
    """A manifest is malformed or not eligible for its declared kind."""


def read_bounded(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) > MAX_MANIFEST_BYTES:
        raise ManifestError(f"{path.relative_to(ROOT)} exceeds {MAX_MANIFEST_BYTES} bytes")
    return data


def repository_path(value: Any, field: str, must_exist: bool = True) -> Path:
    if not isinstance(value, str) or not value or value == "UNRESOLVED":
        raise ManifestError(f"{field} must be a resolved repository-relative path")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise ManifestError(f"{field} must stay inside the repository")
    resolved = ROOT / path
    if must_exist and not resolved.exists():
        raise ManifestError(f"{field} does not exist: {value}")
    return resolved


def sha(value: Any, field: str, allow_unresolved: bool) -> None:
    if allow_unresolved and value == "UNRESOLVED":
        return
    if not isinstance(value, str) or SHA256.fullmatch(value) is None:
        raise ManifestError(f"{field} must be a lowercase SHA-256")


def placeholders(value: Any, prefix: str = "") -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            child_prefix = f"{prefix}.{key}" if prefix else key
            found.update(placeholders(child, child_prefix))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.update(placeholders(child, f"{prefix}[{index}]"))
    elif value == "UNRESOLVED":
        found.add(prefix)
    return found


def validate_manifest(manifest: dict[str, Any], source: str) -> None:
    if manifest.get("schema_version") != 1:
        raise ManifestError(f"{source}: schema_version must be 1")
    kind = manifest.get("kind")
    if kind not in {"development", "release"}:
        raise ManifestError(f"{source}: kind must be development or release")
    release = kind == "release"
    if manifest.get("release_eligible") is not release:
        raise ManifestError(f"{source}: release_eligible must match kind")

    unresolved = manifest.get("unresolved")
    patches = manifest.get("patches")
    if not isinstance(unresolved, list) or any(not isinstance(item, str) for item in unresolved):
        raise ManifestError(f"{source}: unresolved must be a string array")
    if len(unresolved) > 64:
        raise ManifestError(f"{source}: unresolved exceeds 64 entries")
    if release and unresolved:
        raise ManifestError(f"{source}: release manifests may not contain unresolved entries")
    if not isinstance(patches, list) or len(patches) > 128:
        raise ManifestError(f"{source}: patches must be an array with at most 128 entries")

    for table_name, required in TABLE_FIELDS.items():
        table = manifest.get(table_name)
        if not isinstance(table, dict):
            raise ManifestError(f"{source}: missing [{table_name}] table")
        missing = required - table.keys()
        if missing:
            raise ManifestError(f"{source}: [{table_name}] missing {sorted(missing)}")

    unresolved_set = set(unresolved)
    missing_declarations = placeholders(manifest) - unresolved_set
    if missing_declarations:
        raise ManifestError(
            f"{source}: unresolved placeholders not declared: {sorted(missing_declarations)}"
        )

    engine = manifest["engine"]
    if engine["repository"] != "https://github.com/official-pikafish/Pikafish":
        raise ManifestError(f"{source}: unapproved Pikafish repository")
    if not isinstance(engine["tag"], str) or not engine["tag"].startswith("Pikafish-"):
        raise ManifestError(f"{source}: engine tag must be an exact Pikafish release tag")
    if not isinstance(engine["commit"], str) or COMMIT.fullmatch(engine["commit"]) is None:
        raise ManifestError(f"{source}: engine commit must be a lowercase Git commit")
    sha(engine["source_archive_sha256"], "engine.source_archive_sha256", False)
    if not isinstance(engine["source_archive_bytes"], int) or not (
        1 <= engine["source_archive_bytes"] <= 100 * 1024 * 1024
    ):
        raise ManifestError(f"{source}: source archive byte count is invalid")
    if engine["license_spdx"] != "GPL-3.0-only":
        raise ManifestError(f"{source}: Pikafish code license must be GPL-3.0-only")
    repository_path(engine["license_file"], "engine.license_file")
    repository_path(engine["authors_file"], "engine.authors_file")

    build = manifest["build"]
    expected_build = {
        "host_architecture": "arm64",
        "target_architecture": "arm64-apple-macos",
        "target": "profile-build",
        "arch": "apple-silicon",
        "compiler": "clang",
    }
    for key, expected in expected_build.items():
        if build[key] != expected:
            raise ManifestError(f"{source}: build.{key} must be {expected!r}")
    if build["command"] != "make profile-build ARCH=apple-silicon COMP=clang":
        raise ManifestError(f"{source}: unexpected Pikafish build command")
    repository_path(build["make_help_file"], "build.make_help_file")
    if "Verify the locked NNUE hash" not in build["network_precondition"]:
        raise ManifestError(f"{source}: build must require an offline verified NNUE")

    helper = manifest["helper"]
    if not isinstance(helper["bundled"], bool):
        raise ManifestError(f"{source}: helper.bundled must be boolean")
    sha(helper["sha256"], "helper.sha256", not release)
    if helper["bundled"]:
        repository_path(helper["path"], "helper.path")
    elif release:
        raise ManifestError(f"{source}: release helper must be bundled")

    network = manifest["network"]
    if network["repository"] != "https://github.com/official-pikafish/Networks":
        raise ManifestError(f"{source}: unapproved network repository")
    if not isinstance(network["bytes"], int) or not (1 <= network["bytes"] <= 1024**3):
        raise ManifestError(f"{source}: network byte count is invalid")
    sha(network["sha256"], "network.sha256", False)
    if network["commercial_permission"] is not False:
        raise ManifestError(f"{source}: commercial NNUE permission is not established")
    if not isinstance(network["bundled"], bool):
        raise ManifestError(f"{source}: network.bundled must be boolean")
    if release and not network["bundled"]:
        raise ManifestError(f"{source}: release network must be bundled")
    if release and network["release_asset_mutable"]:
        raise ManifestError(f"{source}: mutable network releases are not release eligible")
    repository_path(network["license_file"], "network.license_file")

    corresponding = manifest["corresponding_source"]
    repository_path(corresponding["directory"], "corresponding_source.directory")
    repository_path(
        corresponding["build_instructions"], "corresponding_source.build_instructions"
    )
    sha(
        corresponding["archive_sha256"],
        "corresponding_source.archive_sha256",
        not release,
    )
    if release:
        if corresponding["prepared"] is not True:
            raise ManifestError(f"{source}: release corresponding source must be prepared")
        repository_path(corresponding["archive_path"], "corresponding_source.archive_path")

    for entry in patches:
        if not isinstance(entry, str):
            raise ManifestError(f"{source}: patch entries must be strings")
        match = PATCH.fullmatch(entry)
        if match is None:
            raise ManifestError(f"{source}: malformed patch entry {entry!r}")
        patch_path = repository_path(match.group(2), "patch path")
        digest = hashlib.sha256(patch_path.read_bytes()).hexdigest()
        if digest != match.group(1):
            raise ManifestError(f"{source}: patch hash mismatch for {match.group(2)}")


def load_manifest(path: Path) -> dict[str, Any]:
    parsed = tomllib.loads(read_bounded(path).decode("utf-8"))
    if not isinstance(parsed, dict):
        raise ManifestError(f"{path.relative_to(ROOT)} root must be a table")
    return parsed


def self_test(development: dict[str, Any]) -> None:
    unsafe = copy.deepcopy(development)
    unsafe["kind"] = "release"
    unsafe["release_eligible"] = True
    unsafe["unresolved"] = []
    try:
        validate_manifest(unsafe, "self-test unresolved release")
    except ManifestError:
        return
    raise ManifestError("self-test failed: unresolved release manifest was accepted")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    try:
        schema = json.loads(read_bounded(SCHEMA_PATH))
        if schema.get("properties", {}).get("schema_version", {}).get("const") != 1:
            raise ManifestError("manifest schema must lock schema_version to 1")
        paths = sorted(MANIFEST_DIR.glob("*.toml"))
        if not paths:
            raise ManifestError("no Pikafish manifests found")
        loaded: list[dict[str, Any]] = []
        for path in paths:
            manifest = load_manifest(path)
            validate_manifest(manifest, str(path.relative_to(ROOT)))
            loaded.append(manifest)
        development = next(
            (manifest for manifest in loaded if manifest.get("kind") == "development"), None
        )
        if arguments.self_test:
            if development is None:
                raise ManifestError("self-test requires a development manifest")
            self_test(development)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, tomllib.TOMLDecodeError, ManifestError) as error:
        print(f"manifest validation failed: {error}", file=sys.stderr)
        return 1
    print(f"validated {len(paths)} Pikafish manifest(s) against schema version 1")
    if arguments.self_test:
        print("manifest release-negative self-test passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
