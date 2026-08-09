#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
sanitizer="${NATIVEXIANGQI_FFI_SANITIZER:-address}"
rust_sanitizer_mode="${NATIVEXIANGQI_RUST_SANITIZER:-auto}"
test_binary="$repo_root/build/ffi-c-smoke"
library="$repo_root/target/aarch64-apple-darwin/debug/libxiangqi_ffi.a"

case "$sanitizer" in
  address | undefined) sanitizer_flags=("-fsanitize=$sanitizer" "-fno-omit-frame-pointer") ;;
  none) sanitizer_flags=() ;;
  *)
    echo "NATIVEXIANGQI_FFI_SANITIZER must be address, undefined, or none" >&2
    exit 2
    ;;
esac

case "$rust_sanitizer_mode" in
  auto | require | off) ;;
  *)
    echo "NATIVEXIANGQI_RUST_SANITIZER must be auto, require, or off" >&2
    exit 2
    ;;
esac

rust_sanitizer_flags=()
if [[ "$sanitizer" != "none" && "$rust_sanitizer_mode" != "off" ]]; then
  if rustc -Z help 2>&1 | rg -q '^    sanitizer'; then
    rust_sanitizer_flags=("-Zsanitizer=$sanitizer")
    echo "Rust sanitizer instrumentation enabled: $sanitizer"
  elif [[ "$rust_sanitizer_mode" == "require" ]]; then
    echo "the pinned Rust toolchain does not support required sanitizer instrumentation" >&2
    exit 1
  else
    echo "Rust sanitizer instrumentation unavailable on the pinned stable toolchain; C boundary sanitizer remains enabled"
  fi
fi

"$repo_root/scripts/generate-ffi.sh" --check
RUSTFLAGS="${rust_sanitizer_flags[*]:-}" CARGO_NET_OFFLINE=true cargo test \
  --locked \
  --offline \
  --workspace \
  -- \
  --test-threads=1
RUSTFLAGS="${rust_sanitizer_flags[*]:-}" "$repo_root/scripts/build-rust-artifacts.sh" debug

xcrun --sdk macosx clang \
  -arch arm64 \
  -mmacosx-version-min=15.0 \
  -std=c17 \
  -Wall \
  -Wextra \
  -Werror \
  "${sanitizer_flags[@]}" \
  -I "$repo_root/Packages/XiangqiCoreBinary/Generated" \
  "$repo_root/Tests/FFI/ffi_smoke.c" \
  "$library" \
  -o "$test_binary"
"$test_binary"
echo "C ABI smoke test passed with sanitizer=${sanitizer}"
