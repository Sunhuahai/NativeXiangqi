#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
package_path="$repo_root/Packages/XiangqiCoreBinary"

"$repo_root/scripts/build-rust-artifacts.sh" debug
exec xcrun swift test --package-path "$package_path" --configuration debug
