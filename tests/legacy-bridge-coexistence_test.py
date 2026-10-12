#!/usr/bin/env python3
"""LEGACY (removed with Console 1.2.17): setup on a computer that still has a
bridge-era install, and on one that never had a bridge.

A person with an install made before Console 1.2.15 may run any of the one-line
commands again (the URLs did not change, so they now run this version), or the
cleanup line. None of that may break what works: an app older than 1.2.15 keeps
its bridge until the person decides otherwise, and the cleanup removes the
bridge and nothing else. Every case below runs the shipped scripts exactly as
the one-liners feed them (the script on standard input, `curl ... | sh`)
against the stand-in Hermes of no-bridge-install_test.py in a disposable home;
the fence there refuses and records any connection outside its two stand-in
ports, and each test checks that record stayed empty.
"""

from __future__ import annotations

import hashlib
import importlib.util
import os
import pathlib
import re
import subprocess
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SETUP = ROOT / "hermes-mobile-setup.sh"
PAIR = ROOT / "hermes-pair.sh"

_spec = importlib.util.spec_from_file_location(
    "no_bridge_install_test", ROOT / "tests" / "no-bridge-install_test.py"
)
rig = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rig)

HINT_LINE = "curl -fsSL https://setup.invalid/hermes-mobile-setup.sh | sh -s -- --retire-bridge"


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class BridgeEraInstallTests(rig.SetupRig):
    def piped(self, script, *arguments, **extra):
        """The one-liner: the script arrives on standard input."""
        return subprocess.run(
            ["sh", "-s", "--", *arguments],
            text=True, input=script.read_text(encoding="utf-8"),
            capture_output=True, timeout=240, env=self.environment(**extra),
        )

    def piped_again(self, *arguments):
        """Without a service manager setup asks for the services to be stopped
        first and names the two commands; this is the user following them."""
        refused = self.piped(SETUP, *arguments)
        self.assertNotEqual(refused.returncode, 0)
        commands = re.findall(r"^  (sh \S+service-manager\.sh stop \w+)$", refused.stderr, re.MULTILINE)
        self.assertEqual(len(commands), 2, refused.stderr)
        for command in commands:
            subprocess.run(command.split(), capture_output=True, timeout=30, env=self.environment())
        return self.piped(SETUP, *arguments)

    def make_bridge_era_install(self):
        """What a published bridge-era setup left behind, with the bridge alive:
        Gateway and Dashboard as this setup makes them, plus the bridge's files,
        its recorded process, and a schema 1 pairing record."""
        link = self.link(self.piped(SETUP))
        bridge = self.hermes / "hermes_bridge.py"
        bridge.write_text("# the bridge of an older setup\n", encoding="utf-8")
        self.old_files = {
            bridge: None,
            self.hermes / "bridge.env": "BRIDGE_TOKEN=SYNTHETIC-NOT-A-SECRET\n",
            self.hermes / "bridge_token": "SYNTHETIC-NOT-A-SECRET\n",
            self.services / "hermes-bridge.sh": "#!/bin/sh\n",
            self.services / "bridge-release-check.py": "# verifier\n",
        }
        for path, text in self.old_files.items():
            if text is not None:
                path.write_text(text, encoding="utf-8")
        # A process that runs "the bridge" of this home, recorded as the old
        # portable manager recorded it. It listens on nothing.
        self.bridge_process = subprocess.Popen(
            ["python3", "-c", "import time; time.sleep(600)", str(bridge)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.addCleanup(self.stop_bridge_process)
        stat = pathlib.Path(f"/proc/{self.bridge_process.pid}/stat").read_text()
        started = stat.rstrip().rsplit(") ", 1)[1].split()[19]
        (self.services / "bridge.pid").write_text(f"{self.bridge_process.pid}\n", encoding="utf-8")
        (self.services / "bridge.start").write_text(f"{started}\n", encoding="utf-8")
        record = self.services / "pairing.env"
        text = record.read_text(encoding="utf-8").replace("PAIRING_SCHEMA=2", "PAIRING_SCHEMA=1")
        record.write_text(text + f"BRIDGE_BASE=http://{self.host}:9131\n", encoding="utf-8")
        self.digests = {path: digest(path) for path in self.old_files}
        self.digests[self.services / "bridge.pid"] = digest(self.services / "bridge.pid")
        return link

    def stop_bridge_process(self) -> None:
        if getattr(self, "bridge_process", None) and self.bridge_process.poll() is None:
            self.bridge_process.kill()
            self.bridge_process.wait()

    def bridge_alive(self) -> bool:
        return self.bridge_process.poll() is None

    def bridge_names(self):
        return sorted(
            str(path.relative_to(self.home))
            for path in self.home.rglob("*") if "bridge" in path.name.lower()
        )

    def test_the_old_one_liners_and_the_cleanup_line_on_a_live_bridge_install(self) -> None:
        link = self.make_bridge_era_install()
        names_before = self.bridge_names()
        self.assertTrue(self.bridge_alive())

        # (e) Showing the code again, the one-liner, on a schema 1 record: the
        # same code, nothing written, the bridge not looked at.
        before = rig.units.tree(self.home)
        shown = subprocess.run(
            ["sh", "-s"], text=True, input=PAIR.read_text(encoding="utf-8"),
            capture_output=True, timeout=120,
            env={k: v for k, v in self.environment().items()
                 if k not in ("HERMES_PAIR_HOST", "HERMES_GATEWAY_PORT", "HERMES_DASHBOARD_PORT")},
        )
        self.assertEqual(self.link(shown), link)
        self.assertIn("Needs Console 1.2.15 or newer on the phone.", shown.stdout)
        self.assertIn("https://hermes.xpetalab.dev", shown.stdout)
        self.assertEqual(rig.units.tree(self.home), before)

        # (a)/(d) The old setup command is now this setup. Run over a live
        # bridge it sets up Gateway and Dashboard, leaves the bridge running and
        # untouched, creates nothing new for it, and says how to remove it.
        again = self.piped_again()
        self.assertEqual(self.link(again), link)
        self.assertTrue(self.bridge_alive(), "setup stopped the old bridge")
        for path, value in self.digests.items():
            self.assertEqual(digest(path), value, f"setup changed {path.name}")
        self.assertEqual(self.bridge_names(), names_before)
        self.assertIn("still installed here and was left as it was", again.stdout)
        self.assertIn("Console older", again.stdout)
        self.assertIn("than 1.2.15 still uses it", again.stdout)
        self.assertIn(HINT_LINE, again.stdout)
        self.assertIn("Needs Console 1.2.15 or newer on the phone.", again.stdout)
        self.assertIn("Help and guide: https://hermes.xpetalab.dev", again.stdout)
        self.assertNotIn("SCAN THIS CODE WITH HERMES", again.stdout)
        self.assertIn("== SCAN THIS CODE WITH CONSOLE ==", again.stdout)
        self.assertEqual(self.sign_in(link)[0], 200)
        self.assertEqual(rig.http("GET", self.gateway + "/api/sessions", bearer=link["token"])[0], 200)
        self.assertFalse((self.temp / "mock.curl").exists(), "setup downloaded something")
        record = (self.services / "pairing.env").read_text(encoding="utf-8")
        self.assertIn("PAIRING_SCHEMA=2\n", record)
        self.assertNotIn("BRIDGE", record)

        # (b) The cleanup line, the one-liner: the bridge goes, its process
        # stops, Gateway and Dashboard are not touched and the code still works.
        gateway_pid = (self.services / "gateway.pid").read_text()
        dashboard_pid = (self.services / "dashboard.pid").read_text()
        retired = self.piped(SETUP, "--retire-bridge")
        self.assertEqual(retired.returncode, 0, retired.stdout + retired.stderr)
        self.assertIn("The old Mobile Bridge is stopped and removed", retired.stdout)
        deadline = time.time() + 15
        while self.bridge_alive() and time.time() < deadline:
            time.sleep(0.2)
        self.assertFalse(self.bridge_alive(), "the bridge process was left running")
        self.assertEqual(self.bridge_names(), [])
        self.assertEqual((self.services / "gateway.pid").read_text(), gateway_pid)
        self.assertEqual((self.services / "dashboard.pid").read_text(), dashboard_pid)
        self.assertEqual(rig.http("GET", self.gateway + "/api/sessions", bearer=link["token"])[0], 200)
        self.assertEqual(self.sign_in(link)[0], 200)
        self.assertEqual(self.link(self.show_code_again()), link)
        for path in (self.hermes / ".env", self.hermes / "config.json"):
            self.assertTrue(path.exists(), path.name)

        # Idempotent: a second run, and a setup afterwards, find nothing to
        # remove and no hint about it.
        twice = self.piped(SETUP, "--retire-bridge")
        self.assertEqual(twice.returncode, 0, twice.stdout + twice.stderr)
        self.assertIn("Nothing to do", twice.stdout)
        later = self.piped_again()
        self.assertEqual(self.link(later), link)
        self.assertNotIn("--retire-bridge", later.stdout)
        self.assertEqual(self.bridge_names(), [])

    def test_the_cleanup_line_where_there_is_no_bridge_or_no_hermes_at_all(self) -> None:
        # (c) A computer with no Hermes home: one calm line, success, and no
        # home appears.
        empty = self.temp / "empty-user"
        empty.mkdir()
        nothing = self.piped(SETUP, "--retire-bridge", HOME=str(empty))
        self.assertEqual(nothing.returncode, 0, nothing.stdout + nothing.stderr)
        self.assertIn("There is no Mobile Bridge on this computer. Nothing to do.", nothing.stdout)
        self.assertEqual(nothing.stderr, "")
        self.assertEqual(list(empty.iterdir()), [])

        # Hermes set up by this version, which never had a bridge: same answer,
        # and nothing of Hermes changes.
        link = self.link(self.piped(SETUP))
        before = rig.units.tree(self.home)
        calm = self.piped(SETUP, "--retire-bridge")
        self.assertEqual(calm.returncode, 0, calm.stdout + calm.stderr)
        self.assertIn("Nothing to do", calm.stdout)
        self.assertEqual(rig.units.tree(self.home), before)
        self.assertEqual(self.sign_in(link)[0], 200)

    def test_a_fresh_setup_creates_no_bridge_of_any_kind(self) -> None:
        link = self.link(self.piped(SETUP))
        self.assertEqual(self.bridge_names(), [])
        self.assertFalse((self.temp / "mock.curl").exists(), "setup downloaded something")
        # No service manager call names a bridge either (the mock logs them).
        calls = (self.temp / "mock.systemctl")
        if calls.exists():
            self.assertNotIn("bridge", calls.read_text(encoding="utf-8").lower())
        for text in (self.hermes / "console-services").glob("*"):
            if text.is_file() and text.suffix in {".sh", ".env", ".json", ".py"}:
                self.assertNotIn("hermes_bridge", text.read_text(encoding="utf-8", errors="replace"), text.name)
        self.assertNotIn("BRIDGE", (self.services / "pairing.env").read_text(encoding="utf-8"))
        self.assertEqual(self.sign_in(link)[0], 200)


class NothingFetchesOrInstallsTheBridgeAnyMore(unittest.TestCase):
    """The four scripts, read as text: no way left to download, schedule, start
    or probe a bridge. What they still name is the cleanup path."""

    NAMES = ("hermes-mobile-setup.sh", "hermes-pair.sh", "hermes-mobile-setup.ps1", "hermes-pair.ps1")

    def test_no_download_names_a_bridge_file(self) -> None:
        for name in self.NAMES:
            with self.subTest(script=name):
                for number, line in enumerate((ROOT / name).read_text(encoding="utf-8").splitlines(), 1):
                    lowered = line.lower()
                    if "bridge" not in lowered:
                        continue
                    # What is printed for a person (the cleanup line itself) is not a download.
                    if lowered.lstrip().startswith(("echo ", "printf ", "write-host ", "#")):
                        continue
                    for fetcher in ("curl ", "wget ", "invoke-webrequest", "invoke-restmethod",
                                    "downloadfile", "urlopen", "irm "):
                        self.assertNotIn(fetcher, lowered, f"{name}:{number}: {line.strip()}")

    def test_nothing_registers_or_starts_a_bridge(self) -> None:
        for name in self.NAMES:
            with self.subTest(script=name):
                source = (ROOT / name).read_text(encoding="utf-8")
                for fragment in (
                    'Register-HermesTask "HermesConsole-MobileBridge"',
                    'Register-HermesTask "HermesConsole-Restart-MobileBridge"',
                    "systemctl --user enable --now hermes-bridge",
                    "install_launchd_job bridge",
                    "hermes-bridge.service <<",
                    "--i-know-what-im-doing",
                ):
                    self.assertNotIn(fragment, source)

    def test_the_published_bridge_is_untouched_and_the_readme_says_it_is_legacy(self) -> None:
        # Console <= 1.2.14 checks the bytes it downloads against the
        # manifest: the file stays exactly as published, not even a comment
        # is added to it. Its legacy status lives in the README.
        import hashlib
        import json

        manifest = json.loads((ROOT / "bridge-release.json").read_text(encoding="utf-8"))
        payload = (ROOT / "hermes_bridge.py").read_bytes()
        self.assertEqual(
            manifest["sha256"],
            "f61cde2912cd6e35e917e6a994b904aeaa7a82df8cb56b35b7fdff91f17324d5",
        )
        self.assertEqual(hashlib.sha256(payload).hexdigest(), manifest["sha256"])
        self.assertEqual(len(payload), manifest["size"])
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("Legacy", readme)
        self.assertIn("1.2.17", readme)
        self.assertFalse((ROOT / "hermes-mobile-setup.vbs").exists())

    def test_what_an_older_pair_script_checks_before_running_this_setup_still_holds(self) -> None:
        # hermes-pair.ps1 of the bridge era, run with -Repair, downloads
        # hermes-mobile-setup.ps1 from main and only runs it if it starts with
        # this line and has these two lines.
        source = (ROOT / "hermes-mobile-setup.ps1").read_text(encoding="utf-8")
        self.assertTrue(source.startswith("# Hermes Console - native Windows setup"))
        self.assertRegex(source, r'(?m)^function Get-PairingConfiguration')
        self.assertRegex(source, r'(?m)^\$PairingFile = Join-Path \$ServicesDir "pairing\.json"')


if __name__ == "__main__":
    unittest.main(verbosity=2)
