#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

xcrun swift-format format --in-place --recursive App Packages
cargo fmt --all
