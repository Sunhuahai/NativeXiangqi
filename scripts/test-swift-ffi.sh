#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

"$repo_root/scripts/build-rust-artifacts.sh" debug
xcrun swift test --package-path "$repo_root/Packages/XiangqiCoreBinary" --configuration debug
xcrun swift test --package-path "$repo_root/Packages/XiangqiUI" --configuration debug
xcrun swift test --package-path "$repo_root/Packages/XiangqiDocumentKit" --configuration debug
exec xcrun swift test --package-path "$repo_root/Packages/PikafishKit" --configuration debug
