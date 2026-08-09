#!/usr/bin/env python3
"""Fail-closed release policy authorization for NativeXiangqi v1."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
POLICY_PATH = ROOT / "config" / "release-policy.json"
MAX_POLICY_BYTES = 16 * 1024

EXPECTED_FLAGS = {
    "communityDeveloperId": True,
    "communityMustBeFree": True,
    "communityMustBeOpenSource": True,
    "commercial": False,
    "paid": False,
    "inAppPurchase": False,
    "subscription": False,
    "donationGatedBundle": False,
    "macAppStore": False,
}

DENIED_MODES = {
    "commercial": "commercial distribution is disabled",
    "paid": "paid distribution is disabled",
    "in-app-purchase": "in-app purchase is disabled",
    "subscription": "subscription distribution is disabled",
    "donation-gated-bundle": "donation-gated bundles are disabled",
    "mac-app-store": "Mac App Store distribution is disabled",
}


class PolicyError(ValueError):
    """A release policy or request failed closed."""


def load_policy() -> dict[str, Any]:
    data = POLICY_PATH.read_bytes()
    if len(data) > MAX_POLICY_BYTES:
        raise PolicyError(f"{POLICY_PATH.relative_to(ROOT)} exceeds {MAX_POLICY_BYTES} bytes")
    parsed = json.loads(data)
    if not isinstance(parsed, dict):
        raise PolicyError("release policy root must be an object")
    return parsed


def validate_policy(policy: dict[str, Any]) -> None:
    if policy.get("schemaVersion") != 1:
        raise PolicyError("schemaVersion must be exactly 1")
    for key, expected in EXPECTED_FLAGS.items():
        actual = policy.get(key)
        if actual is not expected:
            raise PolicyError(f"{key} must remain {str(expected).lower()}, found {actual!r}")

    unblock = policy.get("unblockRequires")
    if not isinstance(unblock, list) or len(unblock) < 4:
        raise PolicyError("unblockRequires must preserve all legal and distribution gates")
    if any(not isinstance(item, str) or not item.strip() for item in unblock):
        raise PolicyError("unblockRequires entries must be non-empty strings")


def authorize(mode: str) -> None:
    validate_policy(load_policy())
    if mode == "community":
        return
    if mode in DENIED_MODES:
        raise PolicyError(DENIED_MODES[mode])
    raise PolicyError(f"unknown release mode {mode!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True)
    arguments = parser.parse_args()
    try:
        authorize(arguments.mode)
    except (OSError, json.JSONDecodeError, PolicyError) as error:
        print(f"release policy denied: {error}", file=sys.stderr)
        return 2
    print("release policy authorized: free, open-source Community Developer ID preparation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
