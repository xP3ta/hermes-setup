#!/usr/bin/env python3
"""Behavioral sync regressions. All git writes are in temporary local repos."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SyncWorkPreservation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="setup-sync-preserve-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.repo = root / "repo"
        self.app = root / "app"
        self.repo.mkdir()
        (self.app / "assets/bridge").mkdir(parents=True)
        (self.app / "scripts").mkdir()
        shutil.copy2(ROOT / "sync-from-app.sh", self.repo / "sync-from-app.sh")
        self.paths = ["hermes_bridge.py", "hermes-mobile-setup.sh",
                      "hermes-mobile-setup.ps1", "hermes-pair.sh", "hermes-pair.ps1"]
        for name in self.paths:
            original = 'VERSION = "1.0.0"\n' if name.endswith(".py") else "# baseline\n"
            (self.repo / name).write_text(original)
            source = self.app / ("assets/bridge" if name.endswith(".py") else "scripts") / name
            source.write_text('VERSION = "1.0.1"\n' if name.endswith(".py") else "# upstream change\n")
        (self.app / "pubspec.yaml").write_text("version: 1.0.0+903\n")
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Sync Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "baseline")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args])

    def snapshot(self):
        return (self.git("rev-parse", "HEAD"), self.git("diff", "--binary"),
                self.git("diff", "--cached", "--binary"),
                self.git("status", "--porcelain=v1", "--untracked-files=all"),
                {p.name: p.read_bytes() for p in self.repo.iterdir() if p.is_file()})

    def assert_refused_unchanged(self):
        before = self.snapshot()
        result = subprocess.run(["bash", str(self.repo / "sync-from-app.sh")],
                                env={**os.environ, "HERMES_APP_DIR": str(self.app)},
                                capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0, "sync silently overwrote local canonical work")
        self.assertIn(b"local", result.stderr.lower())
        self.assertEqual(before, self.snapshot(), "refusal changed files/index/HEAD")

    def test_unstaged_canonical_work_survives(self):
        (self.repo / "hermes-pair.sh").write_text("# LOCAL UNSTAGED CANARY\n")
        self.assert_refused_unchanged()

    def test_staged_canonical_work_survives(self):
        (self.repo / "hermes-pair.sh").write_text("# LOCAL STAGED CANARY\n")
        self.git("add", "hermes-pair.sh")
        self.assert_refused_unchanged()

    def test_untracked_manifest_survives(self):
        (self.repo / "bridge-release.json").write_text('{"local": "CANARY"}\n')
        self.assert_refused_unchanged()

    def test_ignored_manifest_survives(self):
        (self.repo / ".gitignore").write_text("bridge-release.json\n")
        (self.repo / "bridge-release.json").write_text('{"local": "IGNORED CANARY"}\n')
        self.assert_refused_unchanged()

    def test_assume_unchanged_local_content_survives(self):
        self.git("update-index", "--assume-unchanged", "hermes-pair.sh")
        (self.repo / "hermes-pair.sh").write_text("# HIDDEN LOCAL CANARY\n")
        self.assert_refused_unchanged()


if __name__ == "__main__":
    unittest.main(verbosity=2)
