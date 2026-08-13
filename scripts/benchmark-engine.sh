#!/usr/bin/env bash
# Engine/cache benchmark for `make benchmark-engine`. Measures preset search
# latency, cancel/final/lifecycle stress, helper RSS, and helper reclaim.
# Offline: uses the verified local artifacts only. The 30-minute RSS/thermal
# run is opt-in via --long-run and never runs inside `make test`.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
artifacts="$repo_root/Engines/Pikafish/artifacts"

if [[ ! -f "$artifacts/pikafish-2026-01-02-apple-silicon" || ! -f "$artifacts/pikafish.nnue" ]]; then
  echo "benchmark-engine: verified artifacts missing; run make vendor-verify first" >&2
  exit 2
fi

mode="${1:---presets}"
if [[ "$mode" == "--long-run" ]]; then
  echo "benchmark-engine: long-run mode (30 minutes of continuous analysis)" >&2
fi

bench_binary="$(find "$repo_root/Packages/PikafishKit/.build" -type f -name PikafishKitBenchmarks 2>/dev/null | head -1)"
if [[ -z "$bench_binary" ]]; then
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}" \
    xcrun swift build \
    --package-path "$repo_root/Packages/PikafishKit" \
    --configuration release \
    --product PikafishKitBenchmarks >&2
  bench_binary="$(find "$repo_root/Packages/PikafishKit/.build" -type f -name PikafishKitBenchmarks | head -1)"
fi
[[ -n "$bench_binary" ]] || { echo "benchmark-engine: benchmark binary not built" >&2; exit 2; }

output="$("$bench_binary" "$artifacts" "$mode")"
echo "$output"

# Release gates on the short modes.
if [[ "$mode" == "--presets" || "$mode" == "--stress" ]]; then
  failed=""
  if echo "$output" | grep -q '"skipped": true'; then
    echo "benchmark-engine: artifacts were skipped; treat as failure" >&2
    exit 2
  fi
  if echo "$output" | grep -q '"phase": "failed"'; then
    failed="session ended failed"
  fi
  if [[ -n "$failed" ]]; then
    echo "benchmark-engine: gate failure: $failed" >&2
    exit 1
  fi
fi

if [[ "$mode" == "--presets" ]]; then
  helper_pid="$(pgrep -f 'pikafish-2026-01-02-apple-silicon' | head -1 || true)"
  if [[ -n "$helper_pid" ]]; then
    rss_kb="$(ps -o rss= -p "$helper_pid" | tr -d ' ' || true)"
    echo "benchmark-engine: helper RSS after presets: ${rss_kb:-unknown} KiB"
    if [[ -n "$rss_kb" && "$rss_kb" -gt 524288 ]]; then
      echo "benchmark-engine: helper RSS exceeds the 512 MiB combined hard gate" >&2
      exit 1
    fi
  fi
fi

echo "benchmark-engine: PASS"
