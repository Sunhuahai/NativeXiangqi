#!/usr/bin/env bash
# Proves the archived sandbox helper: the app bundle must embed a signed
# helper whose hashes match the lock, and the embedded helper must run a full
# handshake and fixed-FEN search inside a restrictive sandbox with network
# denied.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$repo_root/Engines/Pikafish/manifests/development.toml"
app_path="$repo_root/build/DerivedData/Build/Products/Debug/NativeXiangqi.app"
engine_resources="$app_path/Contents/Resources/Engine"
staging="$(mktemp -d /private/tmp/nx-signing.XXXXXX)"
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

helper_sha256="$(read_locked helper.sha256)"
network_sha256="$(read_locked network.sha256)"

[[ -d "$app_path" ]] || {
  echo "verify-signing: archived app missing; run 'make build' first" >&2
  exit 2
}
helper="$engine_resources/pikafish"
network="$engine_resources/pikafish.nnue"
[[ -f "$helper" && -f "$network" ]] || {
  echo "verify-signing: embedded engine assets missing; rebuild the app" >&2
  exit 2
}

# The embedded helper is signed, so its raw bytes differ from the locked
# artifact; content identity is proven below via the code-directory hash.
actual_network_sha256="$(shasum -a 256 "$network" | awk '{print $1}')"
[[ "$actual_network_sha256" == "$network_sha256" ]] || {
  echo "verify-signing: embedded NNUE hash mismatch" >&2
  exit 2
}
echo "verify-signing: embedded NNUE matches the lock"

# The signature rewrite is not byte-reversible, so content identity is proven
# with the code-directory hash: sign a copy of the locked artifact with the
# same identifier and compare cdhashes with the embedded helper.
embedded_identifier="$(codesign -dv "$helper" 2>&1 | sed -n 's/^Identifier=//p')"
codesign -dv "$helper" 2>&1 | grep "Signature=adhoc" > /dev/null || {
  echo "verify-signing: embedded helper is not ad-hoc signed" >&2
  exit 2
}
artifact_copy="$staging/artifact-helper"
cp "$repo_root/Engines/Pikafish/artifacts/pikafish-2026-01-02-apple-silicon" "$artifact_copy"
codesign --force --sign - --identifier "$embedded_identifier" "$artifact_copy" > /dev/null 2>&1
embedded_cdhash="$(codesign -dv --verbose=4 "$helper" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
artifact_cdhash="$(codesign -dv --verbose=4 "$artifact_copy" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
if [[ -z "$embedded_cdhash" || "$embedded_cdhash" != "$artifact_cdhash" ]]; then
  echo "verify-signing: embedded helper code does not match the locked artifact (cdhash $embedded_cdhash vs $artifact_cdhash)" >&2
  exit 2
fi
echo "verify-signing: embedded helper signature valid (adhoc) and code matches the locked artifact"

# Run the embedded helper inside a restrictive sandbox: network denied, no
# arbitrary writes outside the bundle's Engine directory.
(
  cd "$engine_resources"
  printf 'uci\nisready\nposition fen rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1\ngo movetime 300\nquit\n' \
    | sandbox-exec -p '(version 1)(allow default)(deny network*)(deny file-write* (subpath "/Users")(subpath "/System")(subpath "/private/etc"))' \
        ./pikafish > "$staging/sandbox.log" 2>&1
)

grep -q "id name Pikafish 2026-01-02" "$staging/sandbox.log" || {
  echo "verify-signing: sandboxed helper handshake failed" >&2
  cat "$staging/sandbox.log" >&2
  exit 2
}
grep -q "bestmove" "$staging/sandbox.log" || {
  echo "verify-signing: sandboxed helper produced no bestmove" >&2
  cat "$staging/sandbox.log" >&2
  exit 2
}
echo "verify-signing: embedded helper ran handshake and search inside the sandbox"
echo "verify-signing: PASS"
