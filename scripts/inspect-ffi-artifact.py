#!/usr/bin/env python3
"""Inspect a bounded Rust static artifact and record reproducible T010 evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

MAX_COMMAND_OUTPUT = 64 * 1024
MAX_FFI_OBJECT_BYTES = 16 * 1024 * 1024
MAX_FFI_OBJECTS = 16
LC_SYMTAB = 0x2
MACHO_64_LITTLE_ENDIAN = 0xFEEDFACF
N_EXT = 0x01
N_STAB = 0xE0
EXPECTED_EXPORTS = {
    "_xq_ffi_buffer_release",
    "_xq_ffi_get_abi_info",
    "_xq_ffi_get_build_info",
    "_xq_ffi_get_capabilities",
    "_xq_ffi_validate_abi",
}


class ArtifactError(ValueError):
    """An artifact does not meet the narrow T010 static-library contract."""


def run(command: list[str], cwd: Path | None = None) -> str:
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
            cwd=cwd,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ArtifactError(f"could not run {' '.join(command)}: {error}") from error
    output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
    if len(output.encode("utf-8")) > MAX_COMMAND_OUTPUT:
        raise ArtifactError(f"command output exceeds {MAX_COMMAND_OUTPUT} bytes: {' '.join(command)}")
    if result.returncode != 0:
        raise ArtifactError(f"command failed ({result.returncode}): {' '.join(command)}\n{output}")
    return output


def verify_linkable_exports(library: Path, header_directory: Path, smoke_source: Path, output: Path) -> None:
    if not header_directory.is_dir():
        raise ArtifactError(f"header directory is missing: {header_directory}")
    if not smoke_source.is_file() or smoke_source.stat().st_size > MAX_COMMAND_OUTPUT:
        raise ArtifactError(f"bounded C smoke source is missing or too large: {smoke_source}")
    run(
        [
            "xcrun",
            "--sdk",
            "macosx",
            "clang",
            "-arch",
            "arm64",
            "-mmacosx-version-min=15.0",
            "-std=c17",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-I",
            str(header_directory),
            str(smoke_source),
            str(library),
            "-o",
            str(output),
        ]
    )
    run([str(output)])


def c_abi_exports_from_macho(object_path: Path) -> set[str]:
    data = object_path.read_bytes()
    if not 32 <= len(data) <= MAX_FFI_OBJECT_BYTES:
        raise ArtifactError(f"FFI object exceeds bounded range: {object_path.name}")
    magic, _, _, _, command_count, command_bytes, _, _ = struct.unpack_from("<IiiIIIII", data)
    if magic != MACHO_64_LITTLE_ENDIAN:
        raise ArtifactError(f"FFI archive member is not a little-endian 64-bit Mach-O object: {object_path.name}")
    if command_count > 1_024 or command_bytes > len(data) - 32:
        raise ArtifactError(f"FFI Mach-O load commands exceed bounds: {object_path.name}")

    symtab: tuple[int, int, int, int] | None = None
    offset = 32
    for _ in range(command_count):
        if offset + 8 > len(data):
            raise ArtifactError(f"truncated FFI Mach-O load command: {object_path.name}")
        command, command_size = struct.unpack_from("<II", data, offset)
        if command_size < 8 or offset + command_size > len(data):
            raise ArtifactError(f"invalid FFI Mach-O load command size: {object_path.name}")
        if command == LC_SYMTAB:
            if command_size != 24:
                raise ArtifactError(f"invalid FFI Mach-O LC_SYMTAB size: {object_path.name}")
            _, _, symbol_offset, symbol_count, string_offset, string_size = struct.unpack_from(
                "<IIIIII", data, offset
            )
            symtab = (symbol_offset, symbol_count, string_offset, string_size)
        offset += command_size

    if symtab is None:
        raise ArtifactError(f"FFI Mach-O object has no symbol table: {object_path.name}")
    symbol_offset, symbol_count, string_offset, string_size = symtab
    if symbol_count > 65_536 or symbol_offset + symbol_count * 16 > len(data):
        raise ArtifactError(f"FFI Mach-O symbol table exceeds bounds: {object_path.name}")
    if string_size > MAX_FFI_OBJECT_BYTES or string_offset + string_size > len(data):
        raise ArtifactError(f"FFI Mach-O string table exceeds bounds: {object_path.name}")

    string_end = string_offset + string_size
    exports: set[str] = set()
    for index in range(symbol_count):
        string_index, symbol_type, _, _, _ = struct.unpack_from(
            "<IBBHQ", data, symbol_offset + index * 16
        )
        if (symbol_type & N_STAB) != 0 or (symbol_type & N_EXT) == 0 or string_index >= string_size:
            continue
        name_start = string_offset + string_index
        name_end = data.find(b"\0", name_start, string_end)
        if name_end < 0:
            raise ArtifactError(f"unterminated FFI Mach-O symbol name: {object_path.name}")
        try:
            name = data[name_start:name_end].decode("ascii", errors="strict")
        except UnicodeDecodeError as error:
            raise ArtifactError(f"non-ASCII FFI Mach-O symbol name: {object_path.name}") from error
        if name.startswith("_xq_ffi_"):
            exports.add(name)
    return exports


def observed_c_abi_exports(library: Path) -> tuple[set[str], int]:
    members = run(["xcrun", "ar", "-t", str(library)]).splitlines()
    ffi_members = [
        member
        for member in members
        if member.startswith("xiangqi_ffi-")
        and member.endswith(".o")
        and "/" not in member
        and ".." not in member
    ]
    if not ffi_members or len(ffi_members) > MAX_FFI_OBJECTS:
        raise ArtifactError(f"archive must contain between one and {MAX_FFI_OBJECTS} xiangqi_ffi members")

    exports: set[str] = set()
    with tempfile.TemporaryDirectory(prefix="nativexiangqi-ffi-symbols-") as temporary:
        temporary_path = Path(temporary)
        for member in ffi_members:
            run(["xcrun", "ar", "-x", str(library), member], cwd=temporary_path)
            exports.update(c_abi_exports_from_macho(temporary_path / member))
    return exports, len(ffi_members)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--configuration", required=True, choices=("Debug", "Release"))
    parser.add_argument("--header-directory", required=True, type=Path)
    parser.add_argument("--smoke-source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    try:
        library = arguments.library.resolve(strict=True)
        if not library.is_file():
            raise ArtifactError(f"not a regular file: {library}")
        byte_count = library.stat().st_size
        if not 1 <= byte_count <= 128 * 1024 * 1024:
            raise ArtifactError(f"artifact size is outside bounded range: {byte_count}")

        file_description = run(["file", "-b", str(library)])
        architectures = run(["xcrun", "lipo", "-archs", str(library)]).split()
        if architectures != ["arm64"]:
            raise ArtifactError(f"artifact must contain exactly arm64, found {architectures}")
        exports, ffi_member_count = observed_c_abi_exports(library)
        if exports != EXPECTED_EXPORTS:
            raise ArtifactError(
                f"C ABI exports differ; missing={sorted(EXPECTED_EXPORTS - exports)}, "
                f"unexpected={sorted(exports - EXPECTED_EXPORTS)}"
            )
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        smoke_binary = arguments.output.parent / "ffi-export-smoke"
        verify_linkable_exports(
            library,
            arguments.header_directory.resolve(strict=True),
            arguments.smoke_source.resolve(strict=True),
            smoke_binary,
        )

        payload = {
            "architectures": architectures,
            "byteCount": byte_count,
            "configuration": arguments.configuration,
            "archiveFFIMemberCount": ffi_member_count,
            "exportVerification": "Mach-O LC_SYMTAB plus C linker and runtime smoke",
            "exports": sorted(exports),
            "file": file_description,
            "librarySHA256": hashlib.sha256(library.read_bytes()).hexdigest(),
            "rustc": run(["rustc", "--version"]),
            "target": "aarch64-apple-darwin",
            "undocumentedStaticArchiveSymbols": "Rust implementation symbols are not C ABI exports.",
            "xcode": run(["xcodebuild", "-version"]),
        }
        arguments.output.write_text(
            json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except (ArtifactError, OSError, struct.error) as error:
        print(f"FFI artifact inspection failed: {error}", file=sys.stderr)
        return 1

    print(f"inspected {arguments.configuration} arm64 FFI artifact: {library.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
