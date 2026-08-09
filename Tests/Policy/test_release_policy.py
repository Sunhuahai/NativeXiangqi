from __future__ import annotations

import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "release_policy.py"


class ReleasePolicyTests(unittest.TestCase):
    def invoke(self, mode: str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "NATIVEXIANGQI_ALLOW_COMMERCIAL": "1",
                "NATIVEXIANGQI_ALLOW_MAC_APP_STORE": "1",
                "NATIVEXIANGQI_RELEASE_POLICY": "/tmp/unsafe-policy.json",
            }
        )
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--mode", mode],
            cwd=ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_community_mode_is_the_only_authorized_mode(self) -> None:
        result = self.invoke("community")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("free, open-source Community", result.stdout)

    def test_unsafe_modes_fail_even_with_override_environment(self) -> None:
        unsafe_modes = (
            "commercial",
            "paid",
            "in-app-purchase",
            "subscription",
            "donation-gated-bundle",
            "mac-app-store",
        )
        for mode in unsafe_modes:
            with self.subTest(mode=mode):
                result = self.invoke(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("release policy denied", result.stderr)
                self.assertIn("disabled", result.stderr)

    def test_unknown_mode_fails_closed(self) -> None:
        result = self.invoke("enterprise")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown release mode", result.stderr)


if __name__ == "__main__":
    unittest.main()
