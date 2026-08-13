#!/usr/bin/env python3
"""T090 release-gate report writer.

Reads the machine-readable gate JSON and writes the human-readable Markdown
report. Exits nonzero when any gate failed.
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: release_gate_report.py <release-gate.json> <report.md>", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as file:
        data = json.load(file)
    lines: list[str] = ["# NativeXiangqi Community release gate\n"]
    lines.append(f"- Commit: `{data['commit']}` (`{data['branch']}`)\n")
    lines.append(f"- Engine: `{data['engine']['tag']}` (`{data['engine']['commit'][:8]}`)\n")
    lines.append(f"- Helper SHA-256: `{data['hashes']['helperSha256']}`\n")
    lines.append(f"- NNUE SHA-256: `{data['hashes']['networkSha256']}`\n")
    lines.append(
        f"- Corresponding-source archive SHA-256: "
        f"`{data['hashes']['correspondingSourceArchiveSha256']}`\n"
    )
    lines.append(f"- NNUE commercial permission: `{data['nnueCommercialPermission']}`\n\n")
    lines.append("| Gate | Passed |\n|---|---|\n")
    for gate in data["gates"]:
        reason = gate.get("reason", "")
        suffix = f" ({reason})" if reason else ""
        lines.append(f"| {gate['name']} | {'yes' if gate['passed'] else 'NO'}{suffix} |\n")
    lines.append(
        "\nRelease eligibility: see the task report; publishing requires explicit authorization.\n"
    )
    with open(sys.argv[2], "w", encoding="utf-8") as file:
        file.writelines(lines)
    failed = [gate["name"] for gate in data["gates"] if not gate["passed"]]
    if failed:
        print(f"release-gate: FAIL — gates not passed: {','.join(failed)}", file=sys.stderr)
        return 1
    print("release-gate: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
