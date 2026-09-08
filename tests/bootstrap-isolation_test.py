#!/usr/bin/env python3
"""Exercise smoke-test isolation without allowing installer writes."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BootstrapIsolationTests(unittest.TestCase):
    def test_inherited_pair_host_cannot_escape_safe_exit(self):
        self.check_safe_exit()

    def test_nonlinux_host_never_enters_installer(self):
        self.check_safe_exit("Darwin")

    def check_safe_exit(self, platform=None):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            bindir = root / "bin"
            bindir.mkdir()
            marker = root / "mutation-attempt"
            stub = bindir / "mkdir"
            stub.write_text('#!/bin/sh\nprintf "attempt" > "$MUTATION_MARKER"\nexit 93\n')
            stub.chmod(0o755)
            if platform is not None:
                uname = bindir / "uname"
                uname.write_text(f'#!/bin/sh\nprintf "%s\\n" "{platform}"\n')
                uname.chmod(0o755)
            home = root / "must-not-be-created"
            result = subprocess.run(
                ["bash", str(ROOT / "tests/bootstrap-unix_test.sh")],
                cwd=ROOT,
                env={**os.environ, "HOME": str(home), "HERMES_HOME": str(home),
                     "HERMES_PAIR_HOST": "192.168.1.20", "MUTATION_MARKER": str(marker),
                     "PATH": str(bindir) + os.pathsep + os.environ["PATH"]},
                capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(marker.exists(), "installer reached a mutation command")
            self.assertFalse(home.exists(), "inherited home must stay untouched")


if __name__ == "__main__":
    unittest.main()
