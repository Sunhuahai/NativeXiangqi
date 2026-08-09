#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
hard_limit_mib="$(awk -F: '/"emptyWindowHard"/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "$repo_root/config/memory-budgets.json")"

if [[ -z "$hard_limit_mib" ]]; then
  echo "could not read budgetsMiB.emptyWindowHard from config/memory-budgets.json" >&2
  exit 1
fi

export NATIVEXIANGQI_EMPTY_WINDOW_HARD_MIB="$hard_limit_mib"
export NATIVEXIANGQI_GIT_COMMIT="$(git -C "$repo_root" rev-parse HEAD)"
export NATIVEXIANGQI_HOST_MODEL="$(sysctl -n hw.model)"

"$repo_root/scripts/build-rust-artifacts.sh" release
exec xcrun swift run \
  --package-path "$repo_root/Packages/XiangqiDocumentKit" \
  --configuration release \
  XiangqiUIBenchmarks
