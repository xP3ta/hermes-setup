#!/usr/bin/env python3
"""The Hermes installer step and the run lock, against the real script.

What the people who reviewed the Windows helper asked for, checked on the Unix
script: a healthy install is never judged broken (nor removed) on one failed
answer; an installer that outlives its limit is stopped with everything it
started before the run lock is released; a lock left by a run that was killed
never locks the next one out, while a lock whose owner is alive still does.
Hermes is the stand-in of no-bridge-install_test.py; nothing real is reached.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SETUP = ROOT / "hermes-mobile-setup.sh"

_spec = importlib.util.spec_from_file_location(
    "no_bridge_install_test", ROOT / "tests" / "no-bridge-install_test.py"
)
rig = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rig)


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A zombie is not running anything.
    try:
        state = pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
        return state != "Z"
    except OSError:
        return True


class InstallerTests(rig.SetupRig):
    def test_an_installer_that_outlives_its_limit_is_stopped_with_its_children(self) -> None:
        shutil.rmtree(self.hermes / "hermes-agent")
        (self.hermes / ".env").write_text("KEEP=me\n", encoding="utf-8")
        pids = self.temp / "pids"
        installer = (
            "mkdir -p \"$HERMES_HOME_FOR_TEST/hermes-agent/half-built\"\n"
            f"sleep 300 & echo $! >> {pids}\n"
            f"sh -c 'sleep 301 & echo $! >> {pids}; wait' & echo $! >> {pids}\n"
            "wait\n"
        )
        (self.mock_bin / "curl").write_text(
            "#!/bin/sh\ncat <<'SCRIPT'\n" + installer + "SCRIPT\n", encoding="utf-8"
        )
        started = time.monotonic()
        done = self.run_script(
            SETUP,
            HERMES_INSTALLER_TIMEOUT_SEC="3",
            HERMES_HOME_FOR_TEST=str(self.hermes),
        )
        self.assertNotEqual(done.returncode, 0)
        self.assertLess(time.monotonic() - started, 60)
        self.assertIn("did not finish within 3s", done.stderr)
        self.assertIn("nothing that was there before was touched", done.stderr)
        listed = [int(x) for x in pids.read_text().split()]
        self.assertGreaterEqual(len(listed), 3)
        time.sleep(0.5)
        self.assertEqual([p for p in listed if alive(p)], [], "the installer left processes running")
        # Only what this run began was removed.
        self.assertFalse((self.hermes / "hermes-agent").exists())
        self.assertEqual((self.hermes / ".env").read_text(encoding="utf-8"), "KEEP=me\n")
        # The lock went with the run: an immediate second run is not refused by it.
        self.assertEqual(list(self.runtime.glob("hermes-console-setup-*")), [])
        again = self.run_script(SETUP, HERMES_INSTALLER_TIMEOUT_SEC="3", HERMES_HOME_FOR_TEST=str(self.hermes))
        self.assertNotIn("already running", again.stderr)

    def test_a_bad_limit_is_refused_before_anything_runs(self) -> None:
        shutil.rmtree(self.hermes / "hermes-agent")
        done = self.run_script(SETUP, HERMES_INSTALLER_TIMEOUT_SEC="soon")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("HERMES_INSTALLER_TIMEOUT_SEC", done.stderr)

    def _slow_launcher(self, failures: int | None) -> pathlib.Path:
        launcher = self.hermes / "hermes-agent" / "venv" / "bin" / "hermes"
        real = launcher.with_name("hermes.real")
        launcher.rename(real)
        count = self.temp / "version-calls"
        # failures=None: --version never answers; N: the first N calls fail.
        wrapper = (
            "#!/bin/sh\n"
            'if [ "$1" = "--version" ]; then\n'
            f"  echo x >> {count}\n"
            f"  calls=$(wc -l < {count})\n"
            + ("  exit 1\n" if failures is None else f'  [ "$calls" -gt {failures} ] || exit 1\n')
            + "fi\n"
            f'exec {real} "$@"\n'
        )
        launcher.write_text(wrapper, encoding="utf-8")
        launcher.chmod(0o700)
        return launcher

    def test_one_failed_answer_does_not_make_a_healthy_install_broken(self) -> None:
        self._slow_launcher(failures=1)
        done = self.run_script(SETUP, HERMES_SETUP_PROBE_PAUSE="0")
        self.assertEqual(done.returncode, 0, done.stderr[-600:])
        self.assertFalse((self.temp / "mock.curl").exists(), "setup tried to reinstall")

    def test_an_install_that_never_answers_is_refused_untouched(self) -> None:
        launcher = self._slow_launcher(failures=None)
        done = self.run_script(SETUP, HERMES_SETUP_PROBE_PAUSE="0")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("Nothing was changed or removed", done.stderr)
        self.assertTrue(launcher.exists())
        self.assertTrue((launcher.with_name("hermes.real")).exists())
        self.assertFalse((self.temp / "mock.curl").exists(), "setup ran the installer over it")


class LockTests(unittest.TestCase):
    def _acquire(self, runtime: pathlib.Path) -> subprocess.CompletedProcess:
        source = SETUP.read_text(encoding="utf-8")
        parts = []
        for name in ("acquire_setup_lock", "release_setup_lock"):
            match = re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", source, re.MULTILINE | re.DOTALL)
            self.assertIsNotNone(match, name)
            parts.append(match.group(0))
        script = (
            "set -eu\nSETUP_LOCK_HELD=0\nSETUP_LOCK_DIR=\n" + "\n".join(parts)
            + "\nacquire_setup_lock\nprintf 'OWNER=%s\\n' \"$(cat \"$SETUP_LOCK_DIR/pid\")\"\nrelease_setup_lock\n"
        )
        return subprocess.run(
            ["sh", "-c", script], text=True, capture_output=True, timeout=30,
            env={**os.environ, "XDG_RUNTIME_DIR": str(runtime)},
        )

    def test_stale_lock_is_taken_over_live_lock_is_not(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hermes-lock-") as raw:
            runtime = pathlib.Path(raw)
            lock = runtime / f"hermes-console-setup-{os.getuid()}.lock"
            # A run that was killed outright: the directory stays, its owner is gone.
            gone = subprocess.Popen(["true"])
            gone.wait()
            lock.mkdir()
            (lock / "pid").write_text(f"{gone.pid}\n")
            taken = self._acquire(runtime)
            self.assertEqual(taken.returncode, 0, taken.stderr)
            self.assertIn("OWNER=", taken.stdout)
            self.assertFalse(lock.exists())
            # Owner alive: refused, and the owner is named.
            holder = subprocess.Popen(["sleep", "30"])
            try:
                lock.mkdir()
                (lock / "pid").write_text(f"{holder.pid}\n")
                refused = self._acquire(runtime)
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn("already running", refused.stderr)
                self.assertIn(str(holder.pid), refused.stderr)
                self.assertTrue(lock.exists(), "a live lock must not be removed")
            finally:
                holder.kill()
                holder.wait()


class SystemdUnitTests(unittest.TestCase):
    """Hermes' own gateway unit, in the form current Hermes writes and the old one."""

    NEW = (
        "[Unit]\nDescription=Hermes\n[Service]\nType=simple\n"
        'ExecStart="{agent}/.hermes/bin/hermes" "gateway" "run"\n'
        "WorkingDirectory={home}\n"
        'Environment="HERMES_HOME={home}"\n'
        'ExecStop=-"{agent}/.hermes/bin/hermes" "--run-module" "gateway.systemd_stop_mark"\n'
        "[Install]\nWantedBy=default.target\n"
    )
    OLD = NEW.replace(
        '"{agent}/.hermes/bin/hermes" "gateway" "run"',
        '"{agent}/venv/bin/python" "-m" "hermes_cli.main" "gateway" "run"',
        1,
    )

    def _stage(self, unit_text: str):
        source = SETUP.read_text(encoding="utf-8")
        match = re.search(r"^stage_gateway_systemd_unit\(\) \{\n.*?^\}\n", source, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match)
        with tempfile.TemporaryDirectory(prefix="hermes-unit-") as raw:
            temp = pathlib.Path(raw)
            home = temp / "home"
            agent = home / "hermes-agent"
            package = temp / "py" / "hermes_cli"
            package.mkdir(parents=True)
            home.mkdir()
            (package / "__init__.py").write_text("")
            (package / "gateway.py").write_text(
                "def generate_systemd_unit(system=False):\n    return %r\n"
                % unit_text.format(agent=agent, home=home, foreign="/opt/other")
            )
            stage = temp / "stage"
            stage.mkdir()
            script = (
                "set -u\n" + match.group(0)
                + f'HP=python3\nSYSTEMD_STAGE={stage}\nHH={home}\nAGENT_DIR={agent}\n'
                + "BIND_HOST=127.0.0.1\nGATEWAY_PORT=1\nstage_gateway_systemd_unit\n"
            )
            done = subprocess.run(
                ["sh", "-c", script], text=True, capture_output=True, timeout=30,
                env={**os.environ, "PYTHONPATH": str(temp / "py")},
            )
            return done, (stage / "hermes-gateway.service").exists()

    def test_current_and_old_forms_are_accepted(self) -> None:
        for name, text in (("current", self.NEW), ("old", self.OLD)):
            done, staged = self._stage(text)
            self.assertEqual(done.returncode, 0, (name, done.stdout, done.stderr))
            self.assertTrue(staged, name)

    def test_what_matters_for_safety_is_still_refused(self) -> None:
        cases = {
            "program outside the install": self.NEW.replace('"{agent}/.hermes/bin/hermes"', '"{foreign}/hermes"', 1),
            "not the gateway": self.NEW.replace('"gateway" "run"', '"dashboard"', 1),
            "another home": self.NEW.replace('HERMES_HOME={home}', 'HERMES_HOME={foreign}', 1),
            "a system unit": self.NEW.replace("[Service]\n", "[Service]\nUser=root\n", 1),
            "an inline interpreter": self.NEW.replace('"gateway" "run"', '"-c" "x" "gateway" "run"', 1),
        }
        for name, text in cases.items():
            done, staged = self._stage(text)
            self.assertNotEqual(done.returncode, 0, name)
            self.assertFalse(staged, name)
            self.assertIn("invalid gateway user unit", done.stderr + done.stdout, name)

    def test_rollback_does_not_count_a_unit_that_was_never_installed(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        match = re.search(r"^rollback_transaction\(\) \{\n.*?^\}\n", source, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match)
        with tempfile.TemporaryDirectory(prefix="hermes-rollback-") as raw:
            temp = pathlib.Path(raw)
            bin_dir = temp / "bin"
            bin_dir.mkdir()
            # systemd that has never heard of the units: show says not-found, stop fails with 5.
            (bin_dir / "systemctl").write_text(
                '#!/bin/sh\ncase "$*" in *show*) echo not-found ;; *stop*) exit 5 ;; esac\nexit 0\n'
            )
            (bin_dir / "systemctl").chmod(0o700)
            script = (
                "TRANSACTION_PENDING=1\nSERVICE_LIFECYCLE_TOUCHED=1\nSERVICE_MANAGER=systemd\n"
                "TRANSACTION_DIR=x\nTRANSACTION_KEYS=\n"
                + "rollback_private_firewall() { return 0; }\nrollback_dashboard_access() { return 0; }\n"
                + "restore_systemd_state() { return 0; }\ncleanup_transaction_backups() { return 0; }\n"
                + match.group(0) + "rollback_transaction\n"
            )
            done = subprocess.run(
                ["sh", "-c", script], text=True, capture_output=True, timeout=30,
                env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"},
            )
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertNotIn("incomplete", done.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
