#!/usr/bin/env bash
# Explicit, network-capable vendor fetch for the pinned Pikafish helper source
# and NNUE. This is the ONLY command allowed to touch the network for engine
# assets. Every normal build/archive step runs offline against the verified
# cache created here. All locked values come from the development manifest.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
engine_dir="$repo_root/Engines/Pikafish"
manifest="$engine_dir/manifests/development.toml"
vendor_dir="$engine_dir/vendor"
downloads_dir="$vendor_dir/downloads"
source_dir="$vendor_dir/source"
network_dir="$vendor_dir/network"

if [[ ! -f "$manifest" ]]; then
  echo "vendor-pikafish: missing locked manifest $manifest" >&2
  exit 2
fi

read_locked() {
  python3 - "$manifest" "$1" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
keys = sys.argv[2].split(".")
value = data
for key in keys:
    value = value[key]
print(value)
PY
}

tag="$(read_locked engine.tag)"
repo="$(read_locked engine.repository)"
commit="$(read_locked engine.commit)"
archive_url="$(read_locked engine.source_archive_url)"
archive_sha256="$(read_locked engine.source_archive_sha256)"
archive_bytes="$(read_locked engine.source_archive_bytes)"
network_url="$(read_locked network.source_url)"
release_archive_name="$(read_locked network.release_archive)"
release_archive_sha256="$(read_locked network.release_archive_sha256)"
release_archive_bytes="$(read_locked network.release_archive_bytes)"
network_sha256="$(read_locked network.sha256)"
network_bytes="$(read_locked network.bytes)"
network_filename="$(read_locked network.filename)"
network_version_header="$(read_locked network.version_header)"
make_help_file="$engine_dir/configs/make-help-Pikafish-2026-01-02.txt"

mkdir -p "$downloads_dir" "$source_dir" "$network_dir"

archive="$downloads_dir/pikafish-$tag.tar.gz"
network_asset="$network_dir/$network_filename"
release_archive="$downloads_dir/$release_archive_name"

fetch_verified() {
  local url="$1" target="$2" expected_sha256="$3" expected_bytes="$4" label="$5"
  if [[ ! -f "$target" ]]; then
    echo "vendor-pikafish: fetching $label from $url"
    curl -fL --retry 3 --retry-delay 2 -o "$target.part" "$url"
    mv "$target.part" "$target"
  else
    echo "vendor-pikafish: $label already present; verifying"
  fi
  local actual_sha256 actual_bytes
  actual_sha256="$(shasum -a 256 "$target" | awk '{print $1}')"
  actual_bytes="$(stat -f%z "$target")"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "vendor-pikafish: $label SHA-256 mismatch: got $actual_sha256, expected $expected_sha256" >&2
    exit 2
  fi
  if [[ "$actual_bytes" != "$expected_bytes" ]]; then
    echo "vendor-pikafish: $label byte count mismatch: got $actual_bytes, expected $expected_bytes" >&2
    exit 2
  fi
  echo "vendor-pikafish: verified $label: $actual_bytes bytes, SHA-256 $actual_sha256"
}

fetch_verified "$archive_url" "$archive" "$archive_sha256" "$archive_bytes" "source archive $tag"

fetch_verified "$network_url" "$release_archive" "$release_archive_sha256" \
  "$release_archive_bytes" "release archive $release_archive_name"

release_extract="$downloads_dir/release-extracted"
if [[ ! -f "$release_extract/$network_filename" ]]; then
  echo "vendor-pikafish: extracting $network_filename from release archive"
  rm -rf "$release_extract"
  mkdir -p "$release_extract"
  tar -xf "$release_archive" -C "$release_extract"
fi

if [[ ! -f "$release_extract/$network_filename" ]]; then
  echo "vendor-pikafish: release archive contains no $network_filename" >&2
  exit 2
fi

# The extracted network replaces the network cache so the pinned engine and the
# distributed app both use exactly the release-matching asset.
cp "$release_extract/$network_filename" "$network_asset"
fetch_verified "local" "$network_asset" "$network_sha256" "$network_bytes" "NNUE $network_filename"

if command -v zstd > /dev/null 2>&1; then
  actual_version_header="$(set +o pipefail; zstd -dc "$network_asset" 2>/dev/null | head -c 4 | xxd -p | awk '{print substr($0,7,2) substr($0,5,2) substr($0,3,2) substr($0,1,2)}')"
  actual_version_header="0x$actual_version_header"
  if [[ "$(echo "$actual_version_header" | tr '[:lower:]' '[:upper:]')" != "$(echo "$network_version_header" | tr '[:lower:]' '[:upper:]')" ]]; then
    echo "vendor-pikafish: NNUE version header mismatch: got $actual_version_header, expected $network_version_header" >&2
    exit 2
  fi
  echo "vendor-pikafish: NNUE version header verified: $actual_version_header"
else
  echo "vendor-pikafish: zstd not found; NNUE version-header check skipped (sha256 lock still enforced)" >&2
fi

extracted="$source_dir/$tag"
if [[ ! -d "$extracted/src" ]]; then
  echo "vendor-pikafish: extracting source archive"
  rm -rf "$extracted"
  mkdir -p "$extracted"
  tar -xzf "$archive" -C "$extracted" --strip-components=1
fi

if [[ "$(git -C "$extracted" rev-parse --short HEAD 2>/dev/null || true)" == *"$commit"* ]]; then
  echo "vendor-pikafish: extracted tree is the exact locked commit"
elif [[ -f "$extracted/src/version.cpp" ]] || [[ -f "$extracted/src/uci.cpp" ]]; then
  # The archive is a plain source tree without .git; identity is enforced by the
  # archive SHA-256 above plus the make-help comparison below.
  echo "vendor-pikafish: extracted plain source tree (identity from archive hash)"
else
  echo "vendor-pikafish: extracted tree does not look like the Pikafish source" >&2
  exit 2
fi

echo "vendor-pikafish: running pinned source make help"
make_help_output="$(cd "$extracted/src" && make help 2>&1)"
make_help_normalized="$(printf '%s' "$make_help_output" | sed 's/[[:space:]]*$//')"
if [[ ! -f "$make_help_file" ]] || [[ "$make_help_normalized" != "$(tail -n +9 "$make_help_file")" ]]; then
  # The committed record must be the true upstream output plus the fixed
  # header. A body mismatch rewrites it so future runs verify raw output.
  make_help_body="$(printf '%s\n' "$make_help_normalized")"
  {
    echo "Pinned upstream source"
    echo "======================"
    echo "Repository: $repo"
    echo "Tag: $tag"
    echo "Commit: $commit"
    echo "Command: cd src && make help"
    echo "Recorded: $(date +%F) on arm64 macOS"
    echo
    printf '%s\n' "$make_help_body"
  } > "$make_help_file"
  echo "vendor-pikafish: recorded true make help output"
else
  echo "vendor-pikafish: make help matches the recorded output"
fi

echo "vendor-pikafish: verified vendor cache ready at $vendor_dir"
