#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

python3 scripts/release_policy.py --mode community
python3 -m unittest discover -s Tests/Policy -p "test_release_policy.py" -v
