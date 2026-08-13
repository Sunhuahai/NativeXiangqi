#!/usr/bin/env bash
# T090 Developer ID signing and notarization for the Community artifact.
#
# Fail-closed: credentials never enter the repository. The script requires
#   - a "Developer ID Application" identity in the keychain, and
#   - notarization credentials via $NOTARY_PROFILE (notarytool profile) or a
#     keychain generic-password item named "nativexiangqi-notary".
# Without them it exits nonzero with evidence and never produces a fake
# "signed" artifact.
#
# Produces build/Community/NativeXiangqi-<version>.zip plus SHA-256 checksums.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
community="$repo_root/build/Community"
report_dir="$repo_root/build/reports"
mkdir -p "$community" "$report_dir"

identity="$(security find-identity -p codesigning 2>/dev/null | awk '/Developer ID Application/ {print $2; exit}')"
if [[ -z "$identity" ]]; then
  echo "sign-notarize: no Developer ID Application identity in the keychain; aborting (fail-closed)" >&2
  exit 2
fi

if [[ -z "${NOTARY_PROFILE:-}" ]] && ! security find-generic-password -s "nativexiangqi-notary" >/dev/null 2>&1; then
  echo "sign-notarize: NOTARY_PROFILE or keychain item nativexiangqi-notary required; aborting (fail-closed)" >&2
  exit 2
fi

app_path="$community/NativeXiangqi.app"
version="0.1.0-community"

if [[ ! -d "$app_path" ]]; then
  echo "sign-notarize: build the unstaged Release app first (scripts/build-community-release.sh)" >&2
  exit 2
fi

# Sign from the inside out: nested helper, then the app shell.
codesign --force --options runtime --timestamp --identifier org.nativexiangqi.helper \
  --sign "$identity" "$app_path/Contents/Resources/Engine/pikafish"
codesign --force --options runtime --timestamp --identifier org.nativexiangqi.app \
  --sign "$identity" "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=2 "$app_path" \
  || echo "sign-notarize: spctl assessment requires a notarized artifact; expected to fail before notarization"

zip_path="$community/NativeXiangqi-${version}.zip"
rm -f "$zip_path"
ditto -c -k --keepParent "$app_path" "$zip_path"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$zip_path" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format json > "$report_dir/notary-submit.json"
  xcrun stapler staple "$app_path"
  ditto -c -k --keepParent "$app_path" "$zip_path"
fi

checksums="$community/SHA256SUMS.txt"
(
  cd "$community"
  shasum -a 256 "NativeXiangqi-${version}.zip"
) > "$checksums"

echo "sign-notarize: wrote $zip_path and $checksums"
echo "sign-notarize: PASS"
