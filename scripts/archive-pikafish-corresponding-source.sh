#!/usr/bin/env bash
# Builds the immutable corresponding-source archive for the pinned helper:
# exact source tree, project patch, licenses, build instructions, and
# checksums. The NNUE is deliberately NOT included (it has its own license);
# its hash and license text are recorded instead. Network is never used.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
engine_dir="$repo_root/Engines/Pikafish"
manifest="$engine_dir/manifests/development.toml"
archive_dir="$engine_dir/corresponding-source/archive"
staging="$(mktemp -d /private/tmp/nx-cs-staging.XXXXXX)"
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
source_archive_sha256="$(read_locked engine.source_archive_sha256)"
helper_sha256="$(read_locked helper.sha256)"
network_sha256="$(read_locked network.sha256)"
network_bytes="$(read_locked network.bytes)"
patch="$engine_dir/corresponding-source/patches/0001-pin-release-version.patch"

if [[ ! -f "$engine_dir/vendor/downloads/pikafish-$tag.tar.gz" ]]; then
  echo "archive-pikafish: run 'make vendor-verify' first" >&2
  exit 2
fi

mkdir -p "$staging/tree" "$staging/meta"
tar -xzf "$engine_dir/vendor/downloads/pikafish-$tag.tar.gz" -C "$staging/tree" --strip-components=1

# Tree content digest: every file, sorted, hashed, then the list hashed again.
tree_digest="$(
  (cd "$staging/tree" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
)"

mkdir -p "$staging/meta/licenses" "$staging/meta/patches"
cp "$patch" "$staging/meta/patches/"
cp "$engine_dir/licenses/GPL-3.0.txt" "$engine_dir/licenses/PIKAFISH-AUTHORS.txt" \
  "$engine_dir/licenses/NNUE-LICENSE.md" "$engine_dir/licenses/NETWORK-LICENSE.md" \
  "$engine_dir/licenses/NOTICE.md" "$engine_dir/licenses/MODIFICATIONS.md" \
  "$staging/meta/licenses/"

cat > "$staging/meta/build-instructions.md" <<MD
# NativeXiangqi Pikafish helper rebuild instructions

Locked engine: $tag, commit $commit.

1. Verify the source tree digest against checksums.sha256.
2. Apply the project patch (patches/0001-pin-release-version.patch) to the
   tree with \`patch -p1\` from the tree root.
3. Stage the hash-verified NNUE ($network_bytes bytes, SHA-256
   $network_sha256) at \`src/pikafish.nnue\` so the upstream net target skips
   its download. Never run the build with network access.
4. Build offline with the locked command:

~~~bash
cd src
make build ARCH=apple-silicon COMP=clang GIT_SHA=$(echo "$commit" | cut -c1-8) GIT_DATE=20260103 -j\$(sysctl -n hw.ncpu)
~~~

The GIT_SHA/GIT_DATE overrides pin the engine's own locked commit because the
upstream Makefile would otherwise probe the enclosing repository. The output
executable at \`src/pikafish\` must equal the recorded helper SHA-256.
MD

(
  cd "$staging/meta"
  shasum -a 256 patches/0001-pin-release-version.patch build-instructions.md \
    licenses/GPL-3.0.txt licenses/PIKAFISH-AUTHORS.txt licenses/NNUE-LICENSE.md \
    licenses/NETWORK-LICENSE.md licenses/NOTICE.md licenses/MODIFICATIONS.md \
    > checksums.sha256
  cat >> checksums.sha256 <<EOF
source-archive-sha256 $source_archive_sha256
tree-content-sha256 $tree_digest
helper-sha256 $helper_sha256
network-sha256 $network_sha256
network-bytes $network_bytes
commit $commit
EOF
)

mkdir -p "$archive_dir"
archive_path="$archive_dir/$tag-corresponding-source.tar.gz"
# Deterministic archive: the source tree carries the release tag's mtimes and
# the generated metadata gets a fixed timestamp so rebuilds hash identically.
find "$staging" -exec touch -t 202601020000 {} +
tar -cf - -C "$staging" tree meta | gzip -n > "$archive_path"
archive_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
archive_bytes="$(stat -f%z "$archive_path")"

echo "archive-pikafish: wrote $archive_path"
echo "archive-pikafish: SHA-256 $archive_sha256 ($archive_bytes bytes)"
echo "archive-pikafish: tree digest $tree_digest"
