#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

required=(
  AGENTS.md
  README.md
  LICENSE_STRATEGY.md
  SOURCES.md
  tasks/INDEX.md
  prompts/00-initial-codex-prompt.md
  config/rust-toolchain.toml
  config/version-lock.example.toml
  config/memory-budgets.json
  config/release-policy.json
)

for path in "${required[@]}"; do
  [[ -f "$path" ]] || { echo "missing required file: $path" >&2; exit 1; }
done

python3 - <<'PY'
from pathlib import Path
import json, tomllib, re, sys

root = Path(".")
for path in sorted((root / "config").glob("*.json")):
    json.loads(path.read_text(encoding="utf-8"))
for path in sorted((root / "config").glob("*.toml")):
    tomllib.loads(path.read_text(encoding="utf-8"))

index = (root / "tasks/INDEX.md").read_text(encoding="utf-8")
task_files = sorted((root / "tasks").glob("T*.md"))
for task in task_files:
    if task.name not in index:
        raise SystemExit(f"task missing from INDEX.md: {task.name}")

for md in root.rglob("*.md"):
    text = md.read_text(encoding="utf-8")
    for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", text):
        if "://" in target or target.startswith("#") or target.startswith("mailto:"):
            continue
        target = target.split("#", 1)[0]
        if target and not (md.parent / target).resolve().exists():
            raise SystemExit(f"broken relative link in {md}: {target}")

print(f"validated {len(task_files)} task cards")
PY

echo "plan validation passed"
