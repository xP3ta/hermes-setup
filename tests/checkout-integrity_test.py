#!/usr/bin/env python3
"""Verify the shipped digest survives Git's Windows-style checkout."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CheckoutIntegrityTests(unittest.TestCase):
    def test_autocrlf_checkout_preserves_bridge_release_bytes(self):
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "checkout"
            subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", str(ROOT), str(repo)], check=True)
            attributes = ROOT / ".gitattributes"
            if attributes.exists():
                shutil.copyfile(attributes, repo / ".gitattributes")
            subprocess.run(["git", "-C", str(repo), "-c", "core.autocrlf=true", "checkout", "--force", "HEAD"],
                           check=True, capture_output=True)
            payload = (repo / "hermes_bridge.py").read_bytes()
            manifest = json.loads((repo / "bridge-release.json").read_text())
            self.assertEqual(len(payload), manifest["size"], "checkout changed the distributed payload size")
            self.assertEqual(hashlib.sha256(payload).hexdigest(), manifest["sha256"])


if __name__ == "__main__":
    unittest.main()
