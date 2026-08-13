#!/usr/bin/env bash
# Rebuilds the helper from the committed corresponding-source archive and
# byte-compares the executable with the locked helper hash. Runs fully
# offline; the NNUE is staged from the verified vendor cache.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
engine_dir="$repo_root/Engines/Pikafish"
manifest="$engine_dir/manifests/development.toml"
archive_dir="$engine_dir/corresponding-source/archive"
artifacts_dir="$engine_dir/artifacts"
staging="$(mktemp -d /private/tmp/nx-vs-staging.XXXXXX)"
trap 'rm -rf "$staging"' EXIT

read_locked() {
  python3 - "$manifest" "$1" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
value = data
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
PY
}

tag="$(read_locked engine.tag)"
commit="$(read_locked engine.commit)"
expected_helper_sha256="$(read_locked helper.sha256)"
network_sha256="$(read_locked network.sha256)"
network_bytes="$(read_locked network.bytes)"
expected_archive_sha256="$(read_locked corresponding_source.archive_sha256)"

archive_path="$archive_dir/$tag-corresponding-source.tar.gz"
if [[ ! -f "$archive_path" ]]; then
  echo "verify-pikafish-source: archive missing; run make archive-corresponding-source" >&2
  exit 2
fi

actual_archive_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
if [[ "$actual_archive_sha256" != "$expected_archive_sha256" ]]; then
  echo "verify-pikafish-source: archive SHA-256 mismatch: got $actual_archive_sha256, expected $expected_archive_sha256" >&2
  exit 2
fi
echo "verify-pikafish-source: archive hash verified"

tar -xzf "$archive_path" -C "$staging"

# Verify the tree content digest recorded inside the archive.
tree_digest="$(
  (cd "$staging/tree" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
)"
recorded_tree_digest="$(grep '^tree-content-sha256 ' "$staging/meta/checksums.sha256" | awk '{print $2}')"
if [[ "$tree_digest" != "$recorded_tree_digest" ]]; then
  echo "verify-pikafish-source: tree content digest mismatch" >&2
  exit 2
fi
echo "verify-pikafish-source: tree content digest verified"

# Apply the project patch, stage the verified NNUE, and rebuild offline.
(cd "$staging/tree" && patch -p1 < "$staging/meta/patches/0001-pin-release-version.patch" > /dev/null)
network_asset="$engine_dir/vendor/network/pikafish.nnue"
if [[ ! -f "$network_asset" ]]; then
  echo "verify-pikafish-source: vendor NNUE missing; run make vendor-verify" >&2
  exit 2
fi
actual_network_sha256="$(shasum -a 256 "$network_asset" | awk '{print $1}')"
actual_network_bytes="$(stat -f%z "$network_asset")"
if [[ "$actual_network_sha256" != "$network_sha256" || "$actual_network_bytes" != "$network_bytes" ]]; then
  echo "verify-pikafish-source: NNUE verification failed" >&2
  exit 2
fi
cp "$network_asset" "$staging/tree/src/pikafish.nnue"

echo "verify-pikafish-source: rebuilding helper from archive (offline)"
(cd "$staging/tree/src" && \
 sandbox-exec -p '(version 1)(allow default)(deny network*)' \
   make build ARCH=apple-silicon COMP=clang \
   GIT_SHA="$(echo "$commit" | cut -c1-8)" GIT_DATE=20260103 \
   -j"$(sysctl -n hw.ncpu)" > /dev/null 2>&1)

rebuilt_sha256="$(shasum -a 256 "$staging/tree/src/pikafish" | awk '{print $1}')"
if [[ "$rebuilt_sha256" != "$expected_helper_sha256" ]]; then
  echo "verify-pikafish-source: rebuilt helper SHA-256 $rebuilt_sha256 does not match locked $expected_helper_sha256" >&2
  exit 2
fi
echo "verify-pikafish-source: rebuilt helper byte-identical to the locked artifact"
echo "verify-pikafish-source: PASS"
