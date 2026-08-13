#!/usr/bin/env bash
# Verifies the embedded (or artifact) helper and NNUE against the locked
# manifest, and that the complete license/notice set ships alongside them.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
engine_dir="$repo_root/Engines/Pikafish"
manifest="$engine_dir/manifests/development.toml"
artifacts_dir="$engine_dir/artifacts"

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

helper_name="$(basename "$(read_locked helper.path)")"
helper_sha256="$(read_locked helper.sha256)"
network_filename="$(read_locked network.filename)"
network_sha256="$(read_locked network.sha256)"

helper="$artifacts_dir/$helper_name"
network="$artifacts_dir/$network_filename"
if [[ ! -f "$helper" || ! -f "$network" ]]; then
  echo "verify-assets: artifacts missing; run the helper build first" >&2
  exit 2
fi

for asset in "$helper:$helper_sha256" "$network:$network_sha256"; do
  path="${asset%%:*}"
  expected="${asset##*:}"
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "verify-assets: $(basename "$path") SHA-256 mismatch" >&2
    exit 2
  fi
done
echo "verify-assets: helper and NNUE hashes match the locked manifest"

required_licenses=(
  "Engines/Pikafish/licenses/GPL-3.0.txt"
  "Engines/Pikafish/licenses/PIKAFISH-AUTHORS.txt"
  "Engines/Pikafish/licenses/NNUE-LICENSE.md"
  "Engines/Pikafish/licenses/NETWORK-LICENSE.md"
  "Engines/Pikafish/licenses/NOTICE.md"
  "Engines/Pikafish/licenses/MODIFICATIONS.md"
  "Engines/Pikafish/licenses/NETWORK-UPSTREAM-README.md"
)
for license in "${required_licenses[@]}"; do
  [[ -f "$repo_root/$license" ]] || {
    echo "verify-assets: missing $license" >&2
    exit 2
  }
done
echo "verify-assets: license and notice set complete"

# The development manifest must stay not release-eligible.
release_eligible="$(read_locked release_eligible)"
if [[ "$release_eligible" != "False" ]]; then
  echo "verify-assets: development manifest must not be release eligible" >&2
  exit 2
fi
echo "verify-assets: development manifest remains not release-eligible"
echo "verify-assets: PASS"
