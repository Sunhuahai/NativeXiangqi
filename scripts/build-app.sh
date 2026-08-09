#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workspace="$repo_root/NativeXiangqi.xcworkspace"
derived_data="$repo_root/build/DerivedData"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "full Xcode is required; install Xcode 27.x and select its Developer directory" >&2
  exit 1
fi

"$repo_root/scripts/build-rust-artifacts.sh" release

exec xcodebuild \
  -workspace "$workspace" \
  -scheme NativeXiangqi \
  -configuration Debug \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build
