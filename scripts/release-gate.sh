#!/usr/bin/env bash
# T090 Community release gate.
#
# Aggregates every hard gate into one reproducible report:
#   build/reports/release-gate.json   (machine-readable)
#   build/reports/release-gate.md     (human-readable)
#
# Hard failures (per task card) fail the script nonzero. Developer ID signing
# and notarization are recorded as their own gate: the script never fakes
# success — without a Developer ID identity or notary profile it fails closed
# with evidence.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
report_dir="$repo_root/build/reports"
mkdir -p "$report_dir"
json_out="$report_dir/release-gate.json"
md_out="$report_dir/release-gate.md"
artifacts="$repo_root/Engines/Pikafish/artifacts"
manifest="$repo_root/Engines/Pikafish/manifests/development.toml"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

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

run_gate() {
  local name="$1"
  local command="$2"
  local output
  if output="$(cd "$repo_root" && eval "$command" 2>&1)"; then
    printf '{"name": "%s", "passed": true}' "$name"
  else
    printf '{"name": "%s", "passed": false}' "$name"
  fi
}

rule_label_check() {
  # The release must keep the exact base-rule label until the WXF corpus passes
  # independent human review, and must never imply full tournament rules.
  local source_dir="$repo_root/Packages/XiangqiDocumentKit/Sources"
  local label_ok="no"
  if grep -rq "baseRuleModeTitle = \"基础规则模式\"" "$source_dir"; then
    if ! grep -rq "完整赛事判罚\|赛事规则" "$source_dir"; then
      label_ok="yes"
    fi
  fi
  if [[ "$label_ok" == "yes" ]]; then
    printf '{"name": "rule-label", "passed": true, "label": "基础规则模式"}'
  else
    printf '{"name": "rule-label", "passed": false, "label": "基础规则模式"}'
  fi
}

developer_id_check() {
  local identity
  identity="$(security find-identity -p codesigning 2>/dev/null | grep -c "Developer ID Application" || true)"
  if [[ "$identity" -gt 0 ]]; then
    printf '{"name": "developer-id", "passed": true}'
  else
    printf '{"name": "developer-id", "passed": false, "reason": "no Developer ID Application identity in the keychain"}'
  fi
}

notary_profile_check() {
  if [[ -n "${NOTARY_PROFILE:-}" ]] || security find-generic-password -s "nativexiangqi-notary" >/dev/null 2>&1; then
    printf '{"name": "notary-profile", "passed": true}'
  else
    printf '{"name": "notary-profile", "passed": false, "reason": "NOTARY_PROFILE or keychain item nativexiangqi-notary absent"}'
  fi
}

commit="$(cd "$repo_root" && git rev-parse HEAD)"
branch="$(cd "$repo_root" && git branch --show-current)"

engine_tag="$(read_locked engine.tag)"
engine_commit="$(read_locked engine.commit)"
helper_sha256="$(read_locked helper.sha256)"
network_sha256="$(read_locked network.sha256)"
archive_sha256="$(read_locked corresponding_source.archive_sha256)"
commercial_permission_raw="$(read_locked network.commercial_permission)"
if [[ "$commercial_permission_raw" == "true" ]]; then
  commercial_permission="true"
else
  commercial_permission="false"
fi

gates=(
  "verify-assets|make verify-assets 2>&1 | tail -1"
  "verify-source|make verify-source 2>&1 | tail -1"
  "verify-release-policy|make verify-release-policy 2>&1 | tail -1"
  "verify-signing|make verify-signing 2>&1 | tail -1"
  "lint|make lint 2>&1 | tail -1"
  "swift-test|make swift-test 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -1"
  "integration-test|make integration-test 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -1"
)

gate_json=""
for gate in "${gates[@]}"; do
  name="${gate%%|*}"
  command="${gate#*|}"
  entry="$(run_gate "$name" "$command")"
  gate_json="${gate_json}${entry}, "
done
gate_json="${gate_json}$(rule_label_check), "
gate_json="${gate_json}$(developer_id_check), "
gate_json="${gate_json}$(notary_profile_check)"

{
  printf '{'
  printf '"schema": 1, '
  printf '"generatedAt": %s, ' "$(date +%s)"
  printf '"commit": "%s", ' "$commit"
  printf '"branch": "%s", ' "$branch"
  printf '"engine": {"tag": "%s", "commit": "%s"}, ' "$engine_tag" "$engine_commit"
  printf '"hashes": {"helperSha256": "%s", "networkSha256": "%s", "correspondingSourceArchiveSha256": "%s"}, ' "$helper_sha256" "$network_sha256" "$archive_sha256"
  printf '"nnueCommercialPermission": %s, ' "$commercial_permission"
  printf '"gates": [%s]' "${gate_json%, }"
  printf '}\n'
} > "$json_out"

python3 "$repo_root/scripts/release_gate_report.py" "$json_out" "$md_out"

echo "release-gate: report written to $json_out and $md_out"

if python3 "$repo_root/scripts/release_gate_report.py" "$json_out" "$md_out"; then
  :
else
  exit 1
fi
