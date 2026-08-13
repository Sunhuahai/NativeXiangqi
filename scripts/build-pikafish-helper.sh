#!/usr/bin/env bash
# Builds the pinned Apple Silicon Pikafish helper from the verified vendor
# cache, fully offline. The NNUE is pre-staged so the upstream net target
# never downloads. `make build` (non-PGO) is used because profile-build output
# is timing-dependent and would make verify-source byte comparison impossible;
# the choice is recorded in the development manifest and this task's report.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
engine_dir="$repo_root/Engines/Pikafish"
manifest="$engine_dir/manifests/development.toml"
source_tree="$engine_dir/vendor/source/Pikafish-2026-01-02"
network_asset="$engine_dir/vendor/network/pikafish.nnue"
artifacts_dir="$engine_dir/artifacts"
helper_name="pikafish-2026-01-02-apple-silicon"
helper_path="$artifacts_dir/$helper_name"
patch_file="$engine_dir/corresponding-source/patches/0001-pin-release-version.patch"

if [[ ! -d "$source_tree/src" || ! -f "$network_asset" ]]; then
  echo "build-pikafish-helper: vendor cache missing; run 'make vendor-verify' first" >&2
  exit 2
fi

read_locked() {
  python3 - "$manifest" "$1" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
value = data
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
PY
}

expected_sha256="$(read_locked network.sha256)"
expected_bytes="$(read_locked network.bytes)"

actual_sha256="$(shasum -a 256 "$network_asset" | awk '{print $1}')"
actual_bytes="$(stat -f%z "$network_asset")"
if [[ "$actual_sha256" != "$expected_sha256" || "$actual_bytes" != "$expected_bytes" ]]; then
  echo "build-pikafish-helper: NNUE verification failed ($actual_bytes bytes, $actual_sha256)" >&2
  exit 2
fi

echo "build-pikafish-helper: NNUE verified ($actual_bytes bytes)"

# Pre-stage the verified NNUE so the upstream net target skips its download.
staged_network="$source_tree/src/pikafish.nnue"
if [[ ! -f "$staged_network" ]] || [[ "$(shasum -a 256 "$staged_network" | awk '{print $1}')" != "$expected_sha256" ]]; then
  cp "$network_asset" "$staged_network"
  echo "build-pikafish-helper: staged verified NNUE at src/pikafish.nnue"
fi

# Apply the pinned-version patch idempotently.
if ! grep -q 'version = "2026-01-02"' "$source_tree/src/misc.cpp"; then
  echo "build-pikafish-helper: applying pinned-version patch"
  (cd "$source_tree" && patch -p1 < "$patch_file")
else
  echo "build-pikafish-helper: pinned-version patch already applied"
fi

# The upstream Makefile probes `git rev-parse HEAD` in the build directory,
# which walks up to the enclosing NativeXiangqi repository. Pin the engine's
# own locked commit values instead so the binary carries the engine's identity
# and stays byte-deterministic.
locked_sha="ce0679e0"
locked_date="20260103"

mkdir -p "$artifacts_dir"

echo "build-pikafish-helper: building (offline; network denied by sandbox-exec when available)"
if command -v sandbox-exec > /dev/null 2>&1; then
  (cd "$source_tree/src" && \
   sandbox-exec -p '(version 1)(allow default)(deny network*)' \
     make build ARCH=apple-silicon COMP=clang \
       GIT_SHA="$locked_sha" GIT_DATE="$locked_date" -j"$(sysctl -n hw.ncpu)")
else
  (cd "$source_tree/src" && make build ARCH=apple-silicon COMP=clang \
    GIT_SHA="$locked_sha" GIT_DATE="$locked_date" -j"$(sysctl -n hw.ncpu)")
fi

built_helper="$source_tree/src/pikafish"
if [[ ! -x "$built_helper" ]]; then
  echo "build-pikafish-helper: build produced no executable at src/pikafish" >&2
  exit 2
fi

file_info="$(file "$built_helper")"
case "$file_info" in
  *arm64*)
    echo "build-pikafish-helper: helper architecture verified: $file_info"
    ;;
  *)
    echo "build-pikafish-helper: unexpected helper architecture: $file_info" >&2
    exit 2
    ;;
esac

cp "$built_helper" "$helper_path"
helper_sha256="$(shasum -a 256 "$helper_path" | awk '{print $1}')"
helper_bytes="$(stat -f%z "$helper_path")"
compiler_version="$(clang --version | head -1)"

cat > "$artifacts_dir/helper.metadata.json" <<JSON
{
  "schemaVersion": 1,
  "helper": {
    "path": "Engines/Pikafish/artifacts/$helper_name",
    "name": "$helper_name",
    "sha256": "$helper_sha256",
    "bytes": $helper_bytes,
    "buildCommand": "make build ARCH=apple-silicon COMP=clang",
    "compiler": "$compiler_version",
    "hostArchitecture": "arm64",
    "targetArchitecture": "arm64-apple-macos",
    "networkName": "pikafish.nnue",
    "networkSha256": "$expected_sha256",
    "networkBytes": $expected_bytes,
    "patch": "Engines/Pikafish/corresponding-source/patches/0001-pin-release-version.patch"
  }
}
JSON

echo "build-pikafish-helper: helper built at $helper_path"
echo "build-pikafish-helper: SHA-256 $helper_sha256 ($helper_bytes bytes)"
echo "build-pikafish-helper: metadata written to $artifacts_dir/helper.metadata.json"
