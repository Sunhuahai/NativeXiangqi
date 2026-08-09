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
    max_live_games = positive_uint(abi.get("max_live_games"), "abi.max_live_games")
    max_input_bytes = positive_uint(abi.get("max_input_bytes"), "abi.max_input_bytes")
    max_owned_buffer_bytes = positive_uint(
        abi.get("max_owned_buffer_bytes"), "abi.max_owned_buffer_bytes"
    )
    max_owned_buffer_total_bytes = positive_uint(
        abi.get("max_owned_buffer_total_bytes"), "abi.max_owned_buffer_total_bytes"
    )
    ownership_token_bits = positive_uint(
        abi.get("ownership_token_bits"), "abi.ownership_token_bits"
    )
    if not 1 <= max_build_info_bytes <= 64 * 1024:
        raise ABIManifestError("abi.max_build_info_bytes must be between 1 and 65536")
    if not 1 <= max_live_buffers <= 65_536:
        raise ABIManifestError("abi.max_live_buffers must be between 1 and 65536")
    if not 1 <= max_live_games <= 4_096:
        raise ABIManifestError("abi.max_live_games must be between 1 and 4096")
    if not 1 <= max_input_bytes <= 16 * 1024 * 1024:
        raise ABIManifestError("abi.max_input_bytes must be between 1 and 16777216")
    if not 1 <= max_owned_buffer_bytes <= 16 * 1024 * 1024:
        raise ABIManifestError("abi.max_owned_buffer_bytes must be between 1 and 16777216")
    if not max_owned_buffer_bytes <= max_owned_buffer_total_bytes <= 64 * 1024 * 1024:
        raise ABIManifestError(
            "abi.max_owned_buffer_total_bytes must be at least one buffer and no greater than 67108864"
        )
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
                comment = entry.get("comment")
                if return_type != "xq_status_t" or not isinstance(parameters, str) or not parameters:
                    raise ABIManifestError(f"function.{entry_name} has an invalid C signature")
                if not isinstance(comment, str) or not comment or not comment.isascii() or "\n" in comment:
                    raise ABIManifestError(f"function.{entry_name} requires a single-line ASCII comment")
                if any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ *," for character in parameters):
                    raise ABIManifestError(f"function.{entry_name} signature has unsupported characters")
            result.append(entry)
        return result

    checked_capabilities = entries(capabilities, "capability", 32)
    checked_statuses = entries(statuses, "status", 64)
    checked_functions = entries(functions, "function", 32)
    capability_values = [entry["value"] for entry in checked_capabilities]
    if capability_values[:3] != [1, 2, 4] or any(
        value != 1 << index for index, value in enumerate(capability_values)
    ):
        raise ABIManifestError("capabilities must append contiguous powers of two after the v1 bitmap")
    legacy_statuses = [
        ("OK", 0),
        ("INVALID_ARGUMENT", 1),
        ("ABI_MAJOR_MISMATCH", 2),
        ("ABI_MINOR_MISMATCH", 3),
        ("OUTPUT_NOT_EMPTY", 4),
        ("ALLOCATION_FAILED", 5),
        ("RESOURCE_LIMIT", 6),
        ("INVALID_OWNED_BUFFER", 7),
        ("INTERNAL_ERROR", 8),
    ]
    if [(entry.get("name"), entry.get("value")) for entry in checked_statuses[: len(legacy_statuses)]] != legacy_statuses:
        raise ABIManifestError("existing v1 status names and values are immutable")

    declarations = parsed.get("c_declaration", [])
    if not isinstance(declarations, list) or len(declarations) > 32:
        raise ABIManifestError("c_declaration must be an array of no more than 32 entries")
    checked_declarations: list[dict[str, str]] = []
    declaration_names: set[str] = set()
    for declaration in declarations:
        if not isinstance(declaration, dict):
            raise ABIManifestError("c_declaration entries must be tables")
        declaration_name = identifier(declaration.get("name"), "c_declaration.name")
        declaration_code = declaration.get("code")
        if declaration_name in declaration_names:
            raise ABIManifestError(f"duplicate c_declaration name {declaration_name}")
        if (
            not isinstance(declaration_code, str)
            or not declaration_code
            or not declaration_code.isascii()
            or len(declaration_code.encode("utf-8")) > 16 * 1024
            or "#include" in declaration_code
            or "extern \"C\"" in declaration_code
        ):
            raise ABIManifestError(f"c_declaration.{declaration_name} is not a bounded header fragment")
        declaration_names.add(declaration_name)
        checked_declarations.append({"name": declaration_name, "code": declaration_code})

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
                "max_live_games": max_live_games,
                "max_input_bytes": max_input_bytes,
                "max_owned_buffer_bytes": max_owned_buffer_bytes,
                "max_owned_buffer_total_bytes": max_owned_buffer_total_bytes,
                "ownership_token_bits": ownership_token_bits,
                "deterministic_features": features,
            },
            "capabilities": checked_capabilities,
            "statuses": checked_statuses,
            "functions": checked_functions,
            "c_declarations": checked_declarations,
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
        f"#define XQ_FFI_MAX_LIVE_GAMES UINT32_C({abi['max_live_games']})",
        f"#define XQ_FFI_MAX_INPUT_BYTES UINT64_C({abi['max_input_bytes']})",
        f"#define XQ_FFI_MAX_OWNED_BUFFER_BYTES ((size_t){abi['max_owned_buffer_bytes']})",
        f"#define XQ_FFI_MAX_OWNED_BUFFER_TOTAL_BYTES ((size_t){abi['max_owned_buffer_total_bytes']})",
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
    lines.append("")
    for declaration in model["c_declarations"]:
        lines.extend(declaration["code"].splitlines())
        lines.append("")
    for function in model["functions"]:
        lines.append(f"/* {function['comment']} */")
        lines.append(f"{function['return_type']} {function['name']}({function['parameters']});")
    lines.extend(["", "#if defined(__cplusplus)", "}", "#endif", "", "#endif", ""])
    return "\n".join(lines)


def render_rust(model: dict[str, Any], source_digest: str) -> str:
    abi = model["abi"]
    build_info_parts = (
        "product=NativeXiangqi;crate=xiangqi-ffi;crate_version=0.1.0;",
        f"abi={abi['major']}.{abi['minor']};build_info_format={abi['build_info_format']};",
        f"ownership_token_bits={abi['ownership_token_bits']};",
        f"max_live_games={abi['max_live_games']};max_input_bytes={abi['max_input_bytes']};",
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
        f"pub const MAX_LIVE_GAMES: usize = {abi['max_live_games']};",
        f"pub const MAX_INPUT_BYTES: usize = {abi['max_input_bytes']};",
        f"pub const MAX_OWNED_BUFFER_BYTES: usize = {abi['max_owned_buffer_bytes']};",
        f"pub const MAX_OWNED_BUFFER_TOTAL_BYTES: usize = {abi['max_owned_buffer_total_bytes']};",
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


def swift_integer_literal(value: int) -> str:
    """Render numeric ABI limits in the repository's Swift formatting style."""
    return f"{value:_}"


def render_swift(model: dict[str, Any], source_digest: str) -> str:
    abi = model["abi"]
    lines = [
        "// Generated by scripts/generate-ffi.py from abi/ffi-api.toml. Do not edit.",
        "enum GeneratedFFIABI {",
        f"  static let major: UInt32 = {abi['major']}",
        f"  static let minimumMinor: UInt32 = {abi['minor']}",
        f"  static let buildInfoFormat: UInt32 = {abi['build_info_format']}",
        f"  static let maximumBuildInfoBytes = {swift_integer_literal(abi['max_build_info_bytes'])}",
        f"  static let maximumLiveGames = {swift_integer_literal(abi['max_live_games'])}",
        f"  static let maximumInputBytes = {swift_integer_literal(abi['max_input_bytes'])}",
        f"  static let maximumOwnedBufferBytes = {swift_integer_literal(abi['max_owned_buffer_bytes'])}",
        f"  static let maximumOwnedBufferTotalBytes = {swift_integer_literal(abi['max_owned_buffer_total_bytes'])}",
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
        "cDeclarations": [entry["name"] for entry in model["c_declarations"]],
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
