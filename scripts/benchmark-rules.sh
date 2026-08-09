#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

echo "Rule benchmark: initial-position perft depth 5 (expected 133312995 nodes)"
echo "Hardware: $(sysctl -n hw.model 2>/dev/null || echo unknown)"
echo "OS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"

SECONDS=0
CARGO_NET_OFFLINE=true cargo test \
  --locked \
  --offline \
  --release \
  --package xiangqi-io \
  --test codec_and_rules \
  fixed_initial_perft_depth_five \
  -- \
  --ignored \
  --exact \
  --nocapture
echo "Rule benchmark elapsed_seconds=$SECONDS"
