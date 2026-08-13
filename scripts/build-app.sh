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

xcodebuild \
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

# Stage the pinned helper, its NNUE, and the license/notice set into the app
# bundle. Nothing here downloads: the assets come from the verified vendor
# cache and the offline build output. The nested helper is ad-hoc signed so
# the archived app's helper carries a valid signature in development; the
# Developer ID signing gate remains a T090 release step.
app_path="$derived_data/Build/Products/Debug/NativeXiangqi.app"
engine_dir="$repo_root/Engines/Pikafish"
engine_resources="$app_path/Contents/Resources/Engine"
mkdir -p "$engine_resources"
cp "$engine_dir/artifacts/pikafish-2026-01-02-apple-silicon" "$engine_resources/pikafish"
cp "$engine_dir/vendor/network/pikafish.nnue" "$engine_resources/pikafish.nnue"
mkdir -p "$engine_resources/licenses"
cp "$engine_dir/licenses/GPL-3.0.txt" "$engine_dir/licenses/PIKAFISH-AUTHORS.txt" \
  "$engine_dir/licenses/NNUE-LICENSE.md" "$engine_dir/licenses/NETWORK-LICENSE.md" \
  "$engine_dir/licenses/NOTICE.md" "$engine_dir/licenses/MODIFICATIONS.md" \
  "$engine_dir/licenses/NETWORK-UPSTREAM-README.md" "$engine_resources/licenses/"
cp "$engine_dir/manifests/development.toml" "$engine_resources/engine-manifest.toml"
chmod +x "$engine_resources/pikafish"
codesign --force --sign - "$engine_resources/pikafish"
echo "build-app: embedded and ad-hoc signed nested helper at $engine_resources/pikafish"
