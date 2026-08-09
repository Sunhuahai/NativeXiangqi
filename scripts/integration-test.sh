#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

"$repo_root/scripts/build-rust-artifacts.sh" debug
exec xcrun swift test \
  --package-path "$repo_root/Packages/XiangqiDocumentKit" \
  --configuration debug \
  --filter NativeXiangqiDocumentIntegrationTests
