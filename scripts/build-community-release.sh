#!/usr/bin/env bash
# T090 unstaged Community Release build (CODE_SIGNING_ALLOWED=NO), embedding the
# verified helper/NNUE and the complete license/notice set. Signing happens
# later in sign-notarize-community.sh; this script never signs.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workspace="$repo_root/NativeXiangqi.xcworkspace"
derived_data="$repo_root/build/DerivedData"
community="$repo_root/build/Community"
engine_dir="$repo_root/Engines/Pikafish"

"$repo_root/scripts/build-rust-artifacts.sh" release

xcodebuild \
  -workspace "$workspace" \
  -scheme NativeXiangqi \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

app_path="$derived_data/Build/Products/Release/NativeXiangqi.app"
rm -rf "$community"
mkdir -p "$community"
cp -R "$app_path" "$community/NativeXiangqi.app"

engine_resources="$community/NativeXiangqi.app/Contents/Resources/Engine"
mkdir -p "$engine_resources/licenses"
cp "$engine_dir/artifacts/pikafish-2026-01-02-apple-silicon" "$engine_resources/pikafish"
cp "$engine_dir/vendor/network/pikafish.nnue" "$engine_resources/pikafish.nnue"
cp "$engine_dir/licenses/GPL-3.0.txt" "$engine_dir/licenses/PIKAFISH-AUTHORS.txt" \
  "$engine_dir/licenses/NNUE-LICENSE.md" "$engine_dir/licenses/NETWORK-LICENSE.md" \
  "$engine_dir/licenses/NOTICE.md" "$engine_dir/licenses/MODIFICATIONS.md" \
  "$engine_resources/licenses/"
cp "$engine_dir/manifests/development.toml" "$engine_resources/engine-manifest.toml"

echo "build-community-release: unstaged Community app at $community/NativeXiangqi.app"
echo "build-community-release: PASS"
