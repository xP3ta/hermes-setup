#!/usr/bin/env python3
"""Mobile Bridge security regressions (audit findings B1-B4).

Runs the real handlers in-process against a disposable HERMES_HOME. No network,
no Hermes CLI invocation and no real service manager.
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import pathlib
import shutil
import sys
import tempfile
import time
import unittest

BRIDGE = pathlib.Path(__file__).resolve().parents[1] / "hermes_bridge.py"
TOKEN = "T" * 48
MEMORY_ONLY = "memory"
SOUL_ONLY = "soul"


def load_bridge(home: pathlib.Path, scopes: str, tag: str):
    os.environ["HERMES_HOME"] = str(home)
    os.environ["BRIDGE_TOKEN"] = TOKEN
    os.environ["BRIDGE_SCOPES"] = scopes
    os.environ["BRIDGE_READ_ONLY"] = "false"
    name = f"bridge_under_test_{tag}"
    spec = importlib.util.spec_from_file_location(name, BRIDGE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class FakeRequest:
    def __init__(self, token: str, body: dict | None = None):
        self.headers = {"Authorization": f"Bearer {token}"}
        self._body = body if body is not None else {}

    async def json(self):
        return self._body


def body_of(response) -> dict:
    return json.loads(response.body.decode("utf-8"))


class BridgeSecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._temp = tempfile.mkdtemp(prefix="bridge-security-")
        cls.home = pathlib.Path(cls._temp) / "home"
        (cls.home / "skills").mkdir(parents=True)
        (cls.home / "memories").mkdir(parents=True)
        (cls.home / "cron").mkdir(parents=True)
        cls.bridge = load_bridge(cls.home, "read,config,memory,soul,skills,cron,command", "main")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._temp, ignore_errors=True)

    # --- B1: a skill name can never address the skills root -----------------
    def test_skill_name_rejects_special_names(self):
        for hostile in (".", "..", "", "/", "a/b", "..\\a", ".hidden", "-lead"):
            with self.subTest(name=hostile):
                self.assertFalse(self.bridge.SKILL_NAME_RE.match(hostile),
                                 f"{hostile!r} must not validate as a skill name")

    def test_root_is_never_a_skill_directory(self):
        root = self.home / "skills"
        (root / "SKILL.md").write_text("# root marker\n", encoding="utf-8")
        (root / "real-skill").mkdir()
        (root / "real-skill" / "SKILL.md").write_text("# real\n", encoding="utf-8")
        self.assertFalse(self.bridge._path_is_below(root.resolve(), root.resolve()),
                         "the skills root is not below itself")
        self.assertIsNone(self.bridge._find_skill_dir("."), "'.' must not resolve to the skills root")
        self.assertIsNone(self.bridge._find_skill_dir(".."), "'..' must not resolve outside the root")
        found = self.bridge._find_skill_dir("real-skill")
        self.assertIsNotNone(found, "a real skill is still found")
        self.assertTrue(self.bridge._path_is_below(found.resolve(), root.resolve()))

    def test_archiving_a_skill_never_moves_the_root(self):
        root = self.home / "skills"
        skill = root / "archive-me"
        skill.mkdir()
        (skill / "SKILL.md").write_text("# archive\n", encoding="utf-8")
        backup_id = self.bridge._archive_removed_skill(skill, "archive-me")
        self.assertTrue(root.is_dir(), "the skills root survives")
        self.assertFalse(skill.exists(), "the archived skill is gone from its old path")
        archived = self.bridge.BACKUP_DIR / "removed-skills" / backup_id / "skill"
        self.assertTrue((archived / "SKILL.md").is_file(), "the skill is recoverable from the backup")
        self.assertTrue(self.bridge._path_is_below(archived.resolve(), self.home.resolve()))

    # --- B4: backups stay unique inside the same second --------------------
    def test_backups_are_unique_within_one_second(self):
        target = self.home / "SOUL.md"
        target.write_text("first\n", encoding="utf-8")
        stamp = time.strftime("%Y%m%d-%H%M%S")
        first = self.bridge._create_backup(target, "soul")
        target.write_text("second\n", encoding="utf-8")
        second = self.bridge._create_backup(target, "soul")
        self.assertNotEqual(first, second, "two backups in the same second never collide")
        self.assertTrue(self.bridge.BACKUP_ID_RE.fullmatch(first))
        self.assertTrue(self.bridge.BACKUP_ID_RE.fullmatch(second))
        self.assertIn(stamp[:8], first)
        for backup_id in (first, second):
            self.assertTrue((self.bridge.BACKUP_DIR / f"{backup_id}.md").is_file())

    # --- B2: redaction is a structured projection, not a line regex --------
    def test_redaction_removes_multiline_and_nested_secrets(self):
        canary = "CANARY-9f3a-multiline"
        text = (
            "api_key: {canary}\n"
            "provider:\n"
            "  nested:\n"
            "    client_secret: >-\n"
            "      {canary}\n"
            "    tokens:\n"
            "      - {canary}\n"
            "    model: gpt-4o\n"
            "comments_like: keep-me\n"
        ).format(canary=canary)
        projected = self.bridge._redact_secrets(text)
        self.assertNotIn(canary, projected, "no secret value survives the projection")
        self.assertIn("gpt-4o", projected, "non-secret values are preserved")
        self.assertIn("***redacted***", projected)

    def test_redaction_fails_closed_on_invalid_yaml(self):
        canary = "CANARY-broken-yaml"
        projected = self.bridge._redact_secrets(f"key: [unterminated\nsecret: {canary}\n")
        self.assertNotIn(canary, projected, "an unparseable document never leaks its bytes")

    # --- B3: every mutating route needs the destination scope --------------
    def test_write_and_rollback_require_the_destination_scope(self):
        self.bridge.SOUL_PATH = self.home / "SOUL.md"
        self.bridge.TARGETS["soul"] = ("SOUL.md", "soul", "rw")
        soul = self.home / "SOUL.md"
        soul.write_text("original soul\n", encoding="utf-8")

        memory_bridge = load_bridge(self.home, MEMORY_ONLY, "memory_only")
        memory_bridge.TARGETS["soul"] = ("SOUL.md", "soul", "rw")

        write_response = asyncio.run(memory_bridge.write_file(FakeRequest(
            TOKEN, {"file": "soul", "content": "hijacked\n"})))
        self.assertEqual(write_response.status, 403,
                         "a memory-only token cannot write the soul target")
        self.assertEqual(soul.read_text(encoding="utf-8"), "original soul\n")

        backup_id = memory_bridge._create_backup(soul, "soul")
        soul.write_text("changed by the owner\n", encoding="utf-8")
        rollback_response = asyncio.run(memory_bridge.rollback(FakeRequest(
            TOKEN, {"backup_id": backup_id})))
        self.assertEqual(rollback_response.status, 403,
                         "a memory-only token cannot restore the soul target either")
        self.assertEqual(soul.read_text(encoding="utf-8"), "changed by the owner\n",
                         "the rejected rollback changed nothing")

        soul_bridge = load_bridge(self.home, SOUL_ONLY, "soul_only")
        soul_bridge.TARGETS["soul"] = ("SOUL.md", "soul", "rw")
        allowed = asyncio.run(soul_bridge.rollback(FakeRequest(TOKEN, {"backup_id": backup_id})))
        self.assertEqual(allowed.status, 200, body_of(allowed).get("log", ""))
        self.assertEqual(soul.read_text(encoding="utf-8"), "original soul\n",
                         "the matching scope restores the backup")

    def test_missing_token_is_rejected_everywhere(self):
        for handler, payload in (("write", {"file": "soul", "content": "x"}),
                                 ("rollback", {"backup_id": "soul-20260101-000000-abcdef123456"})):
            with self.subTest(handler=handler):
                response = asyncio.run({"write": self.bridge.write_file, "rollback": self.bridge.rollback}[handler](FakeRequest("wrong", payload)))
                self.assertEqual(response.status, 401)


if __name__ == "__main__":
    unittest.main(verbosity=2)
