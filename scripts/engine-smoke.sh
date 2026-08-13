#!/usr/bin/env bash
# Real-helper smoke: version/UCI/isready/fixed-FEN search, plus negative
# NNUE-missing and NNUE-corrupt cases that must disable analysis only.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
engine_dir="$repo_root/Engines/Pikafish"
manifest="$engine_dir/manifests/development.toml"
artifacts_dir="$engine_dir/artifacts"
staging="$(mktemp -d /private/tmp/nx-smoke.XXXXXX)"
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

helper_name="$(basename "$(read_locked helper.path)")"
helper_sha256="$(read_locked helper.sha256)"
helper_bytes="$(read_locked helper.bytes)"
network_filename="$(read_locked network.filename)"
network_sha256="$(read_locked network.sha256)"
network_bytes="$(read_locked network.bytes)"

helper="$artifacts_dir/$helper_name"
network="$artifacts_dir/$network_filename"
for asset in "$helper" "$network"; do
  if [[ ! -f "$asset" ]]; then
    echo "engine-smoke: missing $asset; run 'make vendor-verify' and the helper build first" >&2
    exit 2
  fi
done

verify_sha() {
  local path="$1" expected="$2" label="$3"
  local actual
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "engine-smoke: $label SHA-256 mismatch: got $actual, expected $expected" >&2
    exit 2
  fi
}

verify_sha "$helper" "$helper_sha256" "helper"
verify_sha "$network" "$network_sha256" "NNUE"
actual_helper_bytes="$(stat -f%z "$helper")"
actual_network_bytes="$(stat -f%z "$network")"
[[ "$actual_helper_bytes" == "$helper_bytes" ]] || {
  echo "engine-smoke: helper byte count mismatch" >&2
  exit 2
}
[[ "$actual_network_bytes" == "$network_bytes" ]] || {
  echo "engine-smoke: NNUE byte count mismatch" >&2
  exit 2
}
echo "engine-smoke: asset hashes verified"

run_engine() {
  local dir="$1" log="$2"
  (
    cd "$dir"
    printf 'uci\nisready\nposition fen rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1\ngo movetime 300\nquit\n' \
      | ./"$(basename "$helper")" > "$log" 2>&1
  ) || true
}

smoke_dir="$staging/ok"
mkdir -p "$smoke_dir"
cp "$helper" "$smoke_dir/"
cp "$network" "$smoke_dir/"
run_engine "$smoke_dir" "$staging/ok.log"

grep -q "id name Pikafish 2026-01-02" "$staging/ok.log" || {
  echo "engine-smoke: id line mismatch" >&2
  cat "$staging/ok.log" >&2
  exit 2
}
grep -q "bestmove" "$staging/ok.log" || {
  echo "engine-smoke: no bestmove from fixed-FEN search" >&2
  cat "$staging/ok.log" >&2
  exit 2
}
echo "engine-smoke: handshake and fixed-FEN search produced a bestmove"

# Negative: missing NNUE must disable analysis, not corrupt the session.
missing_dir="$staging/missing"
mkdir -p "$missing_dir"
cp "$helper" "$missing_dir/"
run_engine "$missing_dir" "$staging/missing.log"
if grep -q "bestmove" "$staging/missing.log"; then
  echo "engine-smoke: helper produced a bestmove without its NNUE" >&2
  exit 2
fi
grep -qi "network\|nnue\|eval" "$staging/missing.log" || {
  echo "engine-smoke: missing-NNUE run produced no diagnostic" >&2
  cat "$staging/missing.log" >&2
  exit 2
}
echo "engine-smoke: missing NNUE disables analysis with a bounded diagnostic"

# Negative: corrupt NNUE must behave identically.
corrupt_dir="$staging/corrupt"
mkdir -p "$corrupt_dir"
cp "$helper" "$corrupt_dir/"
head -c 4096 /dev/urandom > "$corrupt_dir/$network_filename"
run_engine "$corrupt_dir" "$staging/corrupt.log"
if grep -q "bestmove" "$staging/corrupt.log"; then
  echo "engine-smoke: helper produced a bestmove with a corrupt NNUE" >&2
  exit 2
fi
grep -qi "network\|nnue\|eval" "$staging/corrupt.log" || {
  echo "engine-smoke: corrupt-NNUE run produced no diagnostic" >&2
  cat "$staging/corrupt.log" >&2
  exit 2
}
echo "engine-smoke: corrupt NNUE disables analysis with a bounded diagnostic"
echo "engine-smoke: PASS"
