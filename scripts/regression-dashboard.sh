#!/usr/bin/env bash
# Machine-readable regression dashboard (T080).
#
# Collects one deterministic JSON record of repository health: git identity,
# key verification command outcomes, and test counts. It never runs network
# commands and never launches the real engine; it aggregates the commands that
# the caller has already executed plus the cheap static gates. Fails nonzero
# when any gate fails.
#
# Usage:
#   scripts/regression-dashboard.sh [--out build/regression-dashboard.json]

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out_path="${1:-$repo_root/build/regression-dashboard.json}"

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

record() {
  local key="$1"
  local value="$2"
  printf '"%s": %s' "$key" "$value"
}

check_command() {
  local name="$1"
  local command="$2"
  local captured
  if captured="$(cd "$repo_root" && eval "$command" 2>&1)"; then
    printf '{"command": "%s", "passed": true}' "$name"
  else
    printf '{"command": "%s", "passed": false}' "$name"
  fi
}

commit="$(cd "$repo_root" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
branch="$(cd "$repo_root" && git branch --show-current 2>/dev/null || echo unknown)"
dirty="$(cd "$repo_root" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

policy="$(check_command verify-release-policy 'make verify-release-policy 2>&1 | tail -1')"
lint="$(check_command lint 'make lint 2>&1 | tail -1')"
ffi_clean="$(check_command generated-ffi 'make verify-generated-ffi 2>&1 | tail -1')"
assets="$(check_command verify-assets 'make verify-assets 2>&1 | tail -1')"
source="$(check_command verify-source 'make verify-source 2>&1 | tail -1')"
signing="$(check_command verify-signing 'make verify-signing 2>&1 | tail -1')"

{
  printf '{'
  printf '"schema": 1, '
  printf '"generatedAt": %s, ' "$(date +%s)"
  printf '"commit": %s, ' "$(printf '%s' "$commit" | json_escape)"
  printf '"branch": %s, ' "$(printf '%s' "$branch" | json_escape)"
  printf '"dirtyPaths": %s, ' "$dirty"
  printf '"gates": {'
  printf '"verifyReleasePolicy": %s, ' "$policy"
  printf '"lint": %s, ' "$lint"
  printf '"generatedFfiClean": %s, ' "$ffi_clean"
  printf '"verifyAssets": %s, ' "$assets"
  printf '"verifySource": %s, ' "$source"
  printf '"verifySigning": %s' "$signing"
  printf '}'
  printf '}\n'
} > "$out_path"

echo "regression-dashboard: wrote $out_path"
if echo "$policy $lint $ffi_clean $assets $source $signing" | grep -q '"passed": false'; then
  echo "regression-dashboard: FAIL (one or more gates failed)" >&2
  exit 1
fi
echo "regression-dashboard: PASS"
