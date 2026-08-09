#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

xcrun swift-format lint --strict --recursive App Packages
cargo fmt --all --check
cargo clippy --locked --workspace --all-targets -- -D warnings
python3 scripts/check_text_format.py
