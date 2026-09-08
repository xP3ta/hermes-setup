#!/usr/bin/env python3
"""Execute CI's syntax step with a broken non-first script (temporary files)."""
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SyntaxStepTests(unittest.TestCase):
    def test_second_posix_file_is_actually_parsed(self):
        source = (ROOT / ".github/workflows/ci.yml").read_text()
        step = source.split("- name: Validate POSIX and Bash syntax\n", 1)[1]
        block = step.split("run: |\n", 1)[1].split("\n      - name:", 1)[0]
        command = textwrap.dedent(block).strip()
        with tempfile.TemporaryDirectory(prefix="ci-parse-closure-") as temp:
            root = Path(temp)
            (root / "tests").mkdir()
            for name in ("hermes-mobile-setup.sh", "hermes-pair.sh", "sync-from-app.sh",
                         "tests/hermes-mobile-setup_test.sh", "tests/sync-from-app_test.sh",
                         "tests/bootstrap-unix_test.sh"):
                (root / name).write_text("#!/bin/sh\ntrue\n")
            (root / "hermes-pair.sh").write_text("#!/bin/sh\nif (\n")
            result = subprocess.run(["bash", "-e", "-c", command], cwd=root,
                                    capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0,
                                "CI syntax gate ignored broken hermes-pair.sh")
            self.assertIn(b"hermes-pair.sh", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
