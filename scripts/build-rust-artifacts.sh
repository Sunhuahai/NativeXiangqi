#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
artifact_root="$repo_root/build/rust-artifacts"
package_artifacts="$repo_root/Packages/XiangqiCoreBinary/Artifacts"
generated_header="$repo_root/Packages/XiangqiCoreBinary/Generated/xiangqi_ffi.h"
target="aarch64-apple-darwin"
configuration="${1:-all}"

case "$configuration" in
  all | debug | release) ;;
  *)
    echo "usage: $0 [all|debug|release]" >&2
    exit 2
    ;;
esac

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "full Xcode is required to create the local XCFramework" >&2
  exit 1
fi

"$repo_root/scripts/generate-ffi.sh" --check

export CARGO_INCREMENTAL=0
export CARGO_NET_OFFLINE=true
export MACOSX_DEPLOYMENT_TARGET=15.0
export SOURCE_DATE_EPOCH=0

safe_remove() {
  case "$1" in
    "$artifact_root"/* | "$package_artifacts"/*) rm -rf "$1" ;;
    *)
      echo "refusing to remove a path outside generated FFI artifacts: $1" >&2
      exit 1
      ;;
  esac
}

build_one() {
  local profile="$1"
  local label
  local cargo_profile=()
  local library
  local output
  local headers
  local staged

  if [[ "$profile" == "release" ]]; then
    label="Release"
    cargo_profile=(--release)
    library="$repo_root/target/$target/release/libxiangqi_ffi.a"
  else
    label="Debug"
    library="$repo_root/target/$target/debug/libxiangqi_ffi.a"
  fi
  output="$artifact_root/$label/XiangqiCoreFFI.xcframework"

  cargo build \
    --locked \
    --offline \
    --package xiangqi-ffi \
    --target "$target" \
    --no-default-features \
    --features deterministic-ffi-v1 \
    "${cargo_profile[@]}"

  if [[ ! -f "$library" ]]; then
    echo "missing expected Rust static library: $library" >&2
    exit 1
  fi

  headers="$(mktemp -d "${TMPDIR:-/tmp}/nativexiangqi-ffi-headers.XXXXXX")"
  cp "$generated_header" "$headers/xiangqi_ffi.h"
  printf '%s\n' \
    'module XiangqiCoreFFI {' \
    '  header "xiangqi_ffi.h"' \
    '  export *' \
    '}' > "$headers/module.modulemap"

  safe_remove "$output"
  mkdir -p "$(dirname "$output")"
  xcodebuild -create-xcframework \
    -library "$library" \
    -headers "$headers" \
    -output "$output"
  rm -rf "$headers"

  python3 "$repo_root/scripts/inspect-ffi-artifact.py" \
    --library "$library" \
    --configuration "$label" \
    --header-directory "$repo_root/Packages/XiangqiCoreBinary/Generated" \
    --smoke-source "$repo_root/Tests/FFI/ffi_smoke.c" \
    --output "$artifact_root/$label/artifact-metadata.json"

  mkdir -p "$package_artifacts"
  staged="$package_artifacts/.XiangqiCoreFFI.staging"
  safe_remove "$staged"
  ditto "$output" "$staged"
  safe_remove "$package_artifacts/XiangqiCoreFFI.xcframework"
  mv "$staged" "$package_artifacts/XiangqiCoreFFI.xcframework"
  echo "staged $label XiangqiCoreFFI XCFramework for local Swift builds"
}

case "$configuration" in
  all)
    build_one debug
    build_one release
    ;;
  debug) build_one debug ;;
  release) build_one release ;;
esac
