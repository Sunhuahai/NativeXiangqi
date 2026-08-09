#!/usr/bin/env python3
"""Generate the checked-in T010 ABI projections from one bounded manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Rust" / "crates" / "xiangqi-ffi" / "abi" / "ffi-api.toml"
MAX_MANIFEST_BYTES = 32 * 1024

OUTPUTS = {
    "rust": ROOT / "Rust" / "crates" / "xiangqi-ffi" / "src" / "generated_abi.rs",
    "header": ROOT / "Packages" / "XiangqiCoreBinary" / "Generated" / "xiangqi_ffi.h",
    "metadata": ROOT
    / "Packages"
    / "XiangqiCoreBinary"
    / "Generated"
    / "xiangqi_ffi_metadata.json",
    "swift": ROOT
    / "Packages"
    / "XiangqiCoreBinary"
    / "Sources"
    / "XiangqiCoreBinary"
    / "GeneratedFFIABI.swift",
}


class ABIManifestError(ValueError):
    """The checked-in ABI source cannot safely generate a projection."""


def bounded_manifest() -> bytes:
    data = MANIFEST.read_bytes()
    if len(data) > MAX_MANIFEST_BYTES:
        raise ABIManifestError(f"{MANIFEST.relative_to(ROOT)} exceeds {MAX_MANIFEST_BYTES} bytes")
    return data


def positive_uint(value: Any, field: str, maximum: int = 2**32 - 1) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= maximum:
        raise ABIManifestError(f"{field} must be an unsigned integer no greater than {maximum}")
    return value


def identifier(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or not value.replace("_", "").isalnum():
        raise ABIManifestError(f"{field} must be an ASCII identifier")
    if not value.isascii() or not (value[0].isalpha() or value[0] == "_"):
        raise ABIManifestError(f"{field} must be ASCII")
    return value


def parse_manifest() -> tuple[dict[str, Any], bytes]:
    data = bounded_manifest()
    parsed = tomllib.loads(data.decode("utf-8"))
    if not isinstance(parsed, dict):
        raise ABIManifestError("ABI manifest root must be a table")

    abi = parsed.get("abi")
    capabilities = parsed.get("capability")
    statuses = parsed.get("status")
    functions = parsed.get("function")
    if not isinstance(abi, dict):
        raise ABIManifestError("[abi] table is required")
    if not all(isinstance(entries, list) and entries for entries in (capabilities, statuses, functions)):
        raise ABIManifestError("capability, status, and function tables must be non-empty arrays")

    name = identifier(abi.get("name"), "abi.name")
    if name != "xiangqi_ffi":
        raise ABIManifestError("abi.name must remain xiangqi_ffi")
    major = positive_uint(abi.get("major"), "abi.major")
    minor = positive_uint(abi.get("minor"), "abi.minor")
    metadata_schema = positive_uint(abi.get("metadata_schema"), "abi.metadata_schema")
    build_info_format = positive_uint(abi.get("build_info_format"), "abi.build_info_format")
    max_build_info_bytes = positive_uint(abi.get("max_build_info_bytes"), "abi.max_build_info_bytes")
    max_live_buffers = positive_uint(abi.get("max_live_buffers"), "abi.max_live_buffers")
    ownership_token_bits = positive_uint(
        abi.get("ownership_token_bits"), "abi.ownership_token_bits"
    )
    if not 1 <= max_build_info_bytes <= 64 * 1024:
        raise ABIManifestError("abi.max_build_info_bytes must be between 1 and 65536")
    if not 1 <= max_live_buffers <= 65_536:
        raise ABIManifestError("abi.max_live_buffers must be between 1 and 65536")
    if ownership_token_bits != 64:
        raise ABIManifestError("abi.ownership_token_bits must remain 64 for the v1 C layout")
    features = abi.get("deterministic_features")
    if not isinstance(features, list) or not features or any(
        not isinstance(feature, str) or re.fullmatch(r"[A-Za-z0-9_-]+", feature) is None
        for feature in features
    ):
        raise ABIManifestError("abi.deterministic_features must be a non-empty string array")

    def entries(table: list[Any], label: str, limit: int) -> list[dict[str, Any]]:
        if len(table) > limit:
            raise ABIManifestError(f"{label} exceeds {limit} entries")
        result: list[dict[str, Any]] = []
        names: set[str] = set()
        values: set[int] = set()
        for entry in table:
            if not isinstance(entry, dict):
                raise ABIManifestError(f"{label} entries must be tables")
            entry_name = identifier(entry.get("name"), f"{label}.name")
            if entry_name in names:
                raise ABIManifestError(f"duplicate {label} name {entry_name}")
            names.add(entry_name)
            if label != "function":
                entry_value = positive_uint(entry.get("value"), f"{label}.{entry_name}")
                if entry_value in values:
                    raise ABIManifestError(f"duplicate {label} value {entry_value}")
                values.add(entry_value)
            else:
                return_type = entry.get("return_type")
                parameters = entry.get("parameters")
                if return_type != "xq_status_t" or not isinstance(parameters, str) or not parameters:
                    raise ABIManifestError(f"function.{entry_name} has an invalid C signature")
                if any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ *," for character in parameters):
                    raise ABIManifestError(f"function.{entry_name} signature has unsupported characters")
            result.append(entry)
        return result

    checked_capabilities = entries(capabilities, "capability", 32)
    checked_statuses = entries(statuses, "status", 64)
    checked_functions = entries(functions, "function", 32)
    if [entry["value"] for entry in checked_capabilities] != [1, 2, 4]:
        raise ABIManifestError("capability values must remain the explicit v1 bitmap 1, 2, 4")
    if checked_statuses[0].get("name") != "OK" or checked_statuses[0].get("value") != 0:
        raise ABIManifestError("the first status must be OK = 0")

    return (
        {
            "abi": {
                "name": name,
                "major": major,
                "minor": minor,
                "metadata_schema": metadata_schema,
                "build_info_format": build_info_format,
                "max_build_info_bytes": max_build_info_bytes,
                "max_live_buffers": max_live_buffers,
                "ownership_token_bits": ownership_token_bits,
                "deterministic_features": features,
            },
            "capabilities": checked_capabilities,
            "statuses": checked_statuses,
            "functions": checked_functions,
        },
        data,
    )


def c_define_name(prefix: str, name: str) -> str:
    return f"{prefix}_{name}"


def render_header(model: dict[str, Any], source_digest: str) -> str:
    abi = model["abi"]
    lines = [
        "/*",
        " * Generated by scripts/generate-ffi.py from Rust/crates/xiangqi-ffi/abi/ffi-api.toml.",
        f" * Source SHA-256: {source_digest}",
        " * Do not edit this file directly.",
        " */",
        "#ifndef XIANGQI_FFI_H",
        "#define XIANGQI_FFI_H",
        "",
        "#include <stddef.h>",
        "#include <stdint.h>",
        "",
        "#if defined(__cplusplus)",
        'extern "C" {',
        "#endif",
        "",
        f"#define XQ_FFI_ABI_MAJOR UINT32_C({abi['major']})",
        f"#define XQ_FFI_ABI_MINOR UINT32_C({abi['minor']})",
        f"#define XQ_FFI_BUILD_INFO_FORMAT UINT32_C({abi['build_info_format']})",
        f"#define XQ_FFI_MAX_BUILD_INFO_BYTES ((size_t){abi['max_build_info_bytes']})",
        f"#define XQ_FFI_MAX_LIVE_BUFFERS ((size_t){abi['max_live_buffers']})",
        f"#define XQ_FFI_OWNERSHIP_TOKEN_BITS UINT32_C({abi['ownership_token_bits']})",
        "",
        "typedef uint32_t xq_status_t;",
        "",
    ]
    for status in model["statuses"]:
        lines.append(f"#define {c_define_name('XQ_STATUS', status['name'])} UINT32_C({status['value']})")
    lines.append("")
    for capability in model["capabilities"]:
        lines.append(
            f"#define {c_define_name('XQ_CAPABILITY', capability['name'])} UINT64_C({capability['value']})"
        )
    lines.extend(
        [
            "",
            "typedef struct xq_ffi_abi_info {",
            "  uint32_t abi_major;",
            "  uint32_t abi_minor;",
            "  uint64_t capabilities;",
            "  uint32_t build_info_format;",
            "  uint32_t reserved;",
            "} xq_ffi_abi_info_t;",
            "",
            "typedef struct xq_owned_buffer {",
            "  uint8_t *data;",
            "  size_t len;",
            "  size_t capacity;",
            "  uint64_t allocation_token;",
            "} xq_owned_buffer_t;",
            "",
            "#define XQ_OWNED_BUFFER_INIT { NULL, 0u, 0u, UINT64_C(0) }",
            "",
        ]
    )
    function_comments = {
        "xq_ffi_get_abi_info": "Writes ABI information to a non-null writable out_info pointer.",
        "xq_ffi_get_capabilities": "Writes the capability bitmap to a non-null writable out_capabilities pointer.",
        "xq_ffi_validate_abi": "Checks the requested major and minimum minor ABI without allocating.",
        "xq_ffi_get_build_info": (
            "Requires out_buffer initialized with XQ_OWNED_BUFFER_INIT; success transfers one owned "
            "buffer that must be released exactly once."
        ),
        "xq_ffi_buffer_release": (
            "Releases exactly one matching Rust-owned buffer and clears it; null, forged, and double "
            "releases return a typed error."
        ),
    }
    for function in model["functions"]:
        comment = function_comments.get(function["name"])
        if comment is None:
            raise ABIManifestError(f"unsupported generated header function {function['name']}")
        lines.append(f"/* {comment} */")
        lines.append(f"{function['return_type']} {function['name']}({function['parameters']});")
    lines.extend(["", "#if defined(__cplusplus)", "}", "#endif", "", "#endif", ""])
    return "\n".join(lines)


def render_rust(model: dict[str, Any], source_digest: str) -> str:
    abi = model["abi"]
    build_info_parts = (
        "product=NativeXiangqi;crate=xiangqi-ffi;crate_version=0.1.0;",
        f"abi={abi['major']}.{abi['minor']};build_info_format={abi['build_info_format']};",
        f"ownership_token_bits={abi['ownership_token_bits']};",
        f"features={','.join(abi['deterministic_features'])};",
        f"abi_source_sha256={source_digest}",
    )
    lines = [
        "// Generated by scripts/generate-ffi.py from abi/ffi-api.toml. Do not edit.",
        f"pub const ABI_MAJOR: u32 = {abi['major']};",
        f"pub const ABI_MINOR: u32 = {abi['minor']};",
        f"pub const BUILD_INFO_FORMAT: u32 = {abi['build_info_format']};",
        f"pub const MAX_BUILD_INFO_BYTES: usize = {abi['max_build_info_bytes']};",
        f"pub const MAX_LIVE_BUFFERS: usize = {abi['max_live_buffers']};",
        f"pub const OWNERSHIP_TOKEN_BITS: u32 = {abi['ownership_token_bits']};",
        "pub const ABI_SOURCE_SHA256: &str =",
        f'    "{source_digest}";',
        f'pub const DETERMINISTIC_FEATURES: &str = "{",".join(abi["deterministic_features"])}";',
        "pub const BUILD_INFO: &str = concat!(",
    ]
    lines.extend(f'    "{part}",' for part in build_info_parts)
    lines.append(");")
    for status in model["statuses"]:
        lines.append(f"pub const STATUS_{status['name']}: u32 = {status['value']};")
    for capability in model["capabilities"]:
        lines.append(f"pub const CAPABILITY_{capability['name']}: u64 = {capability['value']};")
    return "\n".join(lines) + "\n"


def swift_upper_camel(name: str) -> str:
    parts = name.lower().split("_")
    return "".join(part.capitalize() for part in parts)


def render_swift(model: dict[str, Any], source_digest: str) -> str:
    abi = model["abi"]
    lines = [
        "// Generated by scripts/generate-ffi.py from abi/ffi-api.toml. Do not edit.",
        "enum GeneratedFFIABI {",
        f"  static let major: UInt32 = {abi['major']}",
        f"  static let minimumMinor: UInt32 = {abi['minor']}",
        f"  static let buildInfoFormat: UInt32 = {abi['build_info_format']}",
        f"  static let maximumBuildInfoBytes = {abi['max_build_info_bytes']}",
        f'  static let sourceSHA256 = "{source_digest}"',
    ]
    for capability in model["capabilities"]:
        lines.append(
            f"  static let capability{swift_upper_camel(capability['name'])}: UInt64 = {capability['value']}"
        )
    for status in model["statuses"]:
        lines.append(
            f"  static let status{swift_upper_camel(status['name'])}: UInt32 = {status['value']}"
        )
    lines.append("}")
    return "\n".join(lines) + "\n"


def render_metadata(model: dict[str, Any], source_digest: str) -> str:
    payload = {
        "abi": model["abi"],
        "capabilities": model["capabilities"],
        "functions": model["functions"],
        "ownedBuffer": {
            "allocationTokenBits": model["abi"]["ownership_token_bits"],
            "layout": ["data", "len", "capacity", "allocation_token"],
            "tokenPolicy": "nonreusable",
        },
        "schemaVersion": model["abi"]["metadata_schema"],
        "sourceSHA256": source_digest,
        "statuses": model["statuses"],
    }
    return json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n"


def expected_outputs() -> dict[Path, str]:
    model, source = parse_manifest()
    digest = hashlib.sha256(source).hexdigest()
    return {
        OUTPUTS["rust"]: render_rust(model, digest),
        OUTPUTS["header"]: render_header(model, digest),
        OUTPUTS["metadata"]: render_metadata(model, digest),
        OUTPUTS["swift"]: render_swift(model, digest),
    }


def write_or_check(check: bool) -> int:
    mismatches: list[str] = []
    for path, content in expected_outputs().items():
        if check:
            try:
                current = path.read_text(encoding="utf-8")
            except OSError:
                mismatches.append(str(path.relative_to(ROOT)))
                continue
            if current != content:
                mismatches.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8", newline="\n")
    if mismatches:
        print("generated FFI files are stale: " + ", ".join(mismatches), file=sys.stderr)
        return 1
    action = "verified" if check else "generated"
    print(f"{action} {len(OUTPUTS)} FFI projections from {MANIFEST.relative_to(ROOT)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if any checked-in projection differs")
    arguments = parser.parse_args()
    try:
        return write_or_check(arguments.check)
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError, ABIManifestError) as error:
        print(f"FFI generation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
