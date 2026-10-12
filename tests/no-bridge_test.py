#!/usr/bin/env python3
"""Setup without the Mobile Bridge: the paths that are new in this version.

Everything runs against disposable homes. Service managers are mocks placed
first on PATH; Hermes' configuration API is a two-file stand-in. Nothing here
installs Hermes, contacts the network, or reads the real ~/.hermes.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import platform
import re
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse


ROOT = pathlib.Path(__file__).resolve().parents[1]
SETUP = ROOT / "hermes-mobile-setup.sh"
PAIR = ROOT / "hermes-pair.sh"

_spec = importlib.util.spec_from_file_location(
    "review_unix_security", ROOT / "tests" / "review-unix-security.py"
)
review = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(review)

LINUX = platform.system() == "Linux"


def link_builder(source: str) -> str:
    match = re.search(
        r'^LINK="\$\("\$VP" - [^\n]*<<\'PY\'\n(.*?)\nPY\n\)"$',
        source,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError("pairing link builder not found")
    return match.group(1) + "\n"


def tree(root: pathlib.Path):
    """Every path under root with its bytes: what "nothing else changed" means."""
    return sorted(
        (
            str(path.relative_to(root)),
            path.read_bytes() if path.is_file() and not path.is_symlink() else None,
        )
        for path in root.rglob("*")
    )


def write_fake_hermes_modules(target: pathlib.Path) -> None:
    """Hermes' configuration API, reduced to a JSON file under HERMES_HOME."""
    (target / "hermes_cli").mkdir(parents=True)
    (target / "hermes_cli" / "__init__.py").write_text("", encoding="utf-8")
    (target / "hermes_cli" / "config.py").write_text(
        "import json, os, pathlib\n"
        "def _path():\n"
        "    return pathlib.Path(os.environ['HERMES_HOME']) / 'config.json'\n"
        "def load_config():\n"
        "    path = _path()\n"
        "    return json.loads(path.read_text()) if path.exists() else {}\n"
        "def save_config(cfg):\n"
        "    _path().write_text(json.dumps(cfg, sort_keys=True))\n",
        encoding="utf-8",
    )
    basic = target / "plugins" / "dashboard_auth" / "basic"
    basic.mkdir(parents=True)
    (target / "plugins" / "__init__.py").write_text("", encoding="utf-8")
    (target / "plugins" / "dashboard_auth" / "__init__.py").write_text("", encoding="utf-8")
    (basic / "__init__.py").write_text(
        "import hashlib\n"
        "def hash_password(password):\n"
        "    return 'fake$' + hashlib.sha256(password.encode()).hexdigest()\n",
        encoding="utf-8",
    )


def fake_hash(password: str) -> str:
    return "fake$" + hashlib.sha256(password.encode()).hexdigest()


class OptionTests(unittest.TestCase):
    def _run(self, *arguments):
        with tempfile.TemporaryDirectory(prefix="hermes-options-") as raw:
            home = pathlib.Path(raw) / "home"
            home.mkdir()
            completed = subprocess.run(
                ["sh", str(SETUP), *arguments],
                text=True,
                input="",
                capture_output=True,
                timeout=10,
                env={**os.environ, "HOME": str(home), "XDG_RUNTIME_DIR": raw},
            )
            return completed, list(home.iterdir())

    def test_help_names_the_three_things_it_does_and_touches_nothing(self) -> None:
        completed, left = self._run("--help")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("--new-access", completed.stdout)
        self.assertIn("--retire-bridge", completed.stdout)
        self.assertEqual(left, [])

    def test_an_unknown_option_stops_before_anything_happens(self) -> None:
        completed, left = self._run("--retire-brigde")
        self.assertEqual(completed.returncode, 2)
        self.assertIn("Unknown option", completed.stdout)
        self.assertEqual(left, [])


class NoBridgeInSetupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.setup = SETUP.read_text(encoding="utf-8")
        self.pair = PAIR.read_text(encoding="utf-8")

    def test_setup_neither_downloads_nor_starts_nor_probes_a_bridge(self) -> None:
        for fragment in (
            "$REPO_RAW/hermes_bridge.py",
            "$REPO_RAW/bridge-release.json",
            "/bridge/",
            "BRIDGE_PORT=",
            "BRIDGE_RUNNER",
            '"bridge_token"',
            "bridge_token=",
            "restart hermes-bridge",
            "enable hermes-gateway hermes-dashboard hermes-bridge",
            "import aiohttp",
        ):
            with self.subTest(fragment=fragment):
                self.assertNotIn(fragment, self.setup)
                self.assertNotIn(fragment, self.pair)

    def test_the_only_code_that_names_the_bridge_unit_is_the_retire_path(self) -> None:
        _, _, after = self.setup.partition('  exit "$retire_status_final"\nfi\n')
        self.assertTrue(after)
        # After the retire branch has exited, setup may only look for leftovers
        # to tell the user about them.
        for line in after.splitlines():
            if "bridge" not in line.lower():
                continue
            self.assertTrue(
                "bridge_leftovers" in line
                or line.lstrip().startswith(("echo ", "#"))
                or "iface !~" in line,
                line,
            )

    def test_both_scripts_build_the_same_link_with_the_dashboard_sign_in(self) -> None:
        setup_builder = link_builder(self.setup)
        self.assertEqual(setup_builder, link_builder(self.pair))
        self.assertNotIn("bridge", setup_builder)

    def test_the_link_carries_the_sign_in_exactly_and_nothing_of_the_bridge(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hermes-link-") as raw:
            temp = pathlib.Path(raw)
            script = temp / "link.py"
            script.write_text(link_builder(self.setup), encoding="utf-8")
            login = temp / "login.json"
            password = "p@ss word+&=%/é\"'"
            login.write_text(
                json.dumps({"username": "ana maría", "password": password}),
                encoding="utf-8",
            )

            def build(login_argument, https=""):
                completed = subprocess.run(
                    [
                        sys.executable,
                        str(script),
                        "192.168.1.40",
                        "8642",
                        "SYNTHETIC-KEY",
                        https,
                        "http://192.168.1.40:9119",
                        login_argument,
                    ],
                    text=True,
                    capture_output=True,
                    timeout=10,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                link = completed.stdout.strip()
                self.assertTrue(link.startswith("hermes://pair?"), link)
                return urllib.parse.parse_qs(
                    link.split("?", 1)[1], keep_blank_values=True, strict_parsing=True
                )

            with_login = build(str(login))
            self.assertEqual(
                with_login,
                {
                    "host": ["192.168.1.40"],
                    "port": ["8642"],
                    "token": ["SYNTHETIC-KEY"],
                    "dashboard": ["http://192.168.1.40:9119"],
                    "dash_user": ["ana maría"],
                    "dash_pass": [password],
                },
            )
            without_login = build("", https="1")
            self.assertEqual(
                sorted(without_login), ["dashboard", "host", "https", "port", "token"]
            )


class WindowsParityTests(unittest.TestCase):
    """The Windows installer cannot run here. What can be held is that it runs
    the very same sign-in decision the Unix tests exercise, and that neither
    Windows script knows the bridge outside the retire path."""

    def setUp(self) -> None:
        self.setup_ps1 = (ROOT / "hermes-mobile-setup.ps1").read_text(encoding="utf-8")
        self.pair_ps1 = (ROOT / "hermes-pair.ps1").read_text(encoding="utf-8")
        self.setup_sh = SETUP.read_text(encoding="utf-8")

    def here_string(self, name: str) -> str:
        match = re.search(
            r"^\$script:%s = @'\n(.*?)\n'@$" % re.escape(name),
            self.setup_ps1,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, name)
        return match.group(1) + "\n"

    def test_windows_runs_the_same_sign_in_decision_byte_for_byte(self) -> None:
        self.assertEqual(
            self.here_string("DashboardAccessSource"),
            review.embedded_python(self.setup_sh, "PY_DASH_ACCESS"),
        )
        self.assertEqual(
            self.here_string("DashboardAccessRestoreSource"),
            review.embedded_python(self.setup_sh, "PY_DASH_RESTORE"),
        )

    def test_windows_scripts_stay_ascii_and_know_no_bridge_endpoint(self) -> None:
        for name, source in (("setup", self.setup_ps1), ("pair", self.pair_ps1)):
            with self.subTest(script=name):
                self.assertTrue(source.isascii())
                for fragment in (
                    "/bridge/",
                    "bridge_token=",
                    "$RepoRaw/hermes_bridge.py",
                    "$RepoRaw/bridge-release.json",
                    'Kind = "bridge"',
                    "BridgeBase",
                ):
                    self.assertNotIn(fragment, source)
        self.assertNotIn(":9119", self.pair_ps1.replace('else { "9119" }', ""))

    def test_every_script_opens_with_the_same_seal(self) -> None:
        seal = "xPetaLab  |  CONSOLE"
        rule = "=" * 64
        for name in (
            "hermes-mobile-setup.sh",
            "hermes-pair.sh",
            "hermes-mobile-setup.ps1",
            "hermes-pair.ps1",
        ):
            with self.subTest(script=name):
                source = (ROOT / name).read_text(encoding="utf-8")
                self.assertIn(seal, source)
                self.assertTrue(rule in source or '"=" * 64' in source)

    def test_every_script_closes_with_the_site_and_the_app_version_it_needs(self) -> None:
        needs = "Needs Console 1.2.15 or newer on the phone."
        site = "https://hermes.xpetalab.dev"
        for name in (
            "hermes-mobile-setup.sh",
            "hermes-pair.sh",
            "hermes-mobile-setup.ps1",
            "hermes-pair.ps1",
        ):
            with self.subTest(script=name):
                source = (ROOT / name).read_text(encoding="utf-8")
                self.assertIn(needs, source)
                self.assertIn("Help and guide: " + site, source)
                # The window may be 80 columns wide: nothing printed there wraps.
                for line in source.splitlines():
                    if needs in line or "Help and guide:" in line:
                        text = line.split("'" if "printf" in line else '"')[1]
                        self.assertLessEqual(len(text.replace("\\n", "")) + 4, 80, line)

    def test_the_unix_seal_is_only_drawn_for_a_person(self) -> None:
        # Piped or logged output keeps its plain lines: no seal, no bar.
        function = review.shell_function(self.setup_sh, "setup_seal")
        completed = subprocess.run(
            ["sh", "-c", function + "\nsetup_seal\necho END"],
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(completed.stdout, "END\n")

    def test_both_platforms_offer_the_same_three_actions(self) -> None:
        for switch in ("[switch]$RetireBridge", "[switch]$NewAccess"):
            self.assertIn(switch, self.setup_ps1)
        for option in ("--retire-bridge)", "--new-access)"):
            self.assertIn(option, self.setup_sh)
        for script in (self.setup_ps1, self.pair_ps1):
            self.assertIn("dash_user=", script)
            self.assertIn("dash_pass=", script)


class DashboardAccessTests(unittest.TestCase):
    """The sign-in decision, against a stand-in for Hermes' configuration API."""

    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory(prefix="hermes-dash-access-")
        self.addCleanup(self._temp.cleanup)
        self.temp = pathlib.Path(self._temp.name)
        self.modules = self.temp / "modules"
        write_fake_hermes_modules(self.modules)
        self.home = self.temp / "hermes"
        (self.home / "console-services").mkdir(parents=True)
        self.login = self.home / "console-services" / "dashboard-login.json"
        self.state = self.temp / "state"
        self.previous = self.temp / "previous.json"
        self.script = self.temp / "access.py"
        self.script.write_text(
            review.embedded_python(SETUP.read_text(encoding="utf-8"), "PY_DASH_ACCESS"),
            encoding="utf-8",
        )

    def config(self) -> dict:
        path = self.home / "config.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def set_basic(self, **values) -> None:
        (self.home / "config.json").write_text(
            json.dumps({"model": "kept", "dashboard": {"basic_auth": values}}),
            encoding="utf-8",
        )

    def run_access(self, action="setup"):
        completed = subprocess.run(
            [
                sys.executable,
                str(self.script),
                action,
                str(self.home),
                str(self.login),
                str(self.state),
                str(self.previous),
            ],
            text=True,
            capture_output=True,
            timeout=15,
            env={
                **os.environ,
                "PYTHONPATH": str(self.modules),
                "HERMES_HOME": str(self.home),
            },
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        # Nothing secret may travel through the output of this step.
        self.assertEqual(completed.stdout, "")
        return self.state.read_text(encoding="utf-8").splitlines()

    def stored(self) -> dict:
        return json.loads(self.login.read_text(encoding="utf-8"))

    def test_a_hermes_without_a_sign_in_gets_one_and_it_is_remembered_privately(self) -> None:
        state, username, pinned = self.run_access()
        self.assertEqual((state, username, pinned), ("created", "admin", "0"))
        basic = self.config()["dashboard"]["basic_auth"]
        record = self.stored()
        self.assertEqual(record["username"], "admin")
        self.assertGreaterEqual(len(record["password"]), 24)
        self.assertEqual(basic["username"], "admin")
        self.assertEqual(basic["password_hash"], fake_hash(record["password"]))
        self.assertEqual(basic["password"], "")
        self.assertTrue(basic["secret"])
        self.assertEqual(stat.S_IMODE(self.login.stat().st_mode), 0o600)
        self.assertEqual(
            json.loads(self.previous.read_text()),
            {"username": None, "password_hash": None, "password": None, "secret": None},
        )

    def test_a_password_this_setup_does_not_know_is_kept_and_left_out(self) -> None:
        self.set_basic(username="owner", password_hash="scrypt$theirs", secret="S")
        self.login.write_text(
            json.dumps({"username": "admin", "password": "stale"}), encoding="utf-8"
        )
        before = self.config()
        state, username, pinned = self.run_access()
        self.assertEqual((state, username, pinned), ("unknown", "owner", "0"))
        self.assertEqual(self.config(), before)
        self.assertFalse(self.login.exists())
        self.assertFalse(self.previous.exists())

    def test_the_sign_in_setup_made_before_is_reused_not_replaced(self) -> None:
        self.run_access()
        before = self.config()
        record = self.stored()
        self.previous.unlink()
        state, username, pinned = self.run_access()
        self.assertEqual((state, username, pinned), ("known", "admin", "0"))
        self.assertEqual(self.config(), before)
        self.assertEqual(self.stored(), record)
        self.assertFalse(self.previous.exists())

    def test_new_access_replaces_the_password_and_ends_old_sessions(self) -> None:
        self.set_basic(username="owner", password_hash="scrypt$theirs", secret="OLD-SECRET")
        state, username, pinned = self.run_access("new-access")
        self.assertEqual((state, username, pinned), ("created", "owner", "0"))
        cfg = self.config()
        basic = cfg["dashboard"]["basic_auth"]
        self.assertEqual(cfg["model"], "kept")
        self.assertEqual(basic["username"], "owner")
        self.assertEqual(basic["password_hash"], fake_hash(self.stored()["password"]))
        self.assertNotEqual(basic["secret"], "OLD-SECRET")
        self.assertEqual(
            json.loads(self.previous.read_text()),
            {
                "username": "owner",
                "password_hash": "scrypt$theirs",
                "password": None,
                "secret": "OLD-SECRET",
            },
        )

    def test_a_password_written_in_env_is_used_as_it_is_and_never_replaced(self) -> None:
        self.set_basic(username="owner", password_hash="scrypt$ignored", secret="S")
        (self.home / ".env").write_text(
            "API_SERVER_KEY=SYNTHETIC\n"
            "export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=\"env pass&1\"\n",
            encoding="utf-8",
        )
        before = self.config()
        for action in ("setup", "new-access"):
            with self.subTest(action=action):
                state, username, pinned = self.run_access(action)
                self.assertEqual((state, username, pinned), ("known", "owner", "1"))
                self.assertEqual(self.config(), before)
                record = self.stored()
                self.assertEqual(
                    (record["username"], record["password"], record["source"]),
                    ("owner", "env pass&1", "env"),
                )
                self.assertFalse(self.previous.exists())

    def test_a_password_hash_written_in_env_cannot_be_known_or_replaced(self) -> None:
        (self.home / ".env").write_text(
            "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=envuser\n"
            "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=scrypt$fixed\n",
            encoding="utf-8",
        )
        for action in ("setup", "new-access"):
            with self.subTest(action=action):
                state, username, pinned = self.run_access(action)
                self.assertEqual((state, username, pinned), ("unknown", "envuser", "1"))
                self.assertEqual(self.config(), {})
                self.assertFalse(self.login.exists())

    def test_a_plain_password_in_the_configuration_is_used_without_rewriting_it(self) -> None:
        self.set_basic(username="owner", password="plain one")
        before = self.config()
        state, username, pinned = self.run_access()
        self.assertEqual((state, username, pinned), ("known", "owner", "0"))
        self.assertEqual(self.config(), before)
        self.assertEqual(self.stored()["password"], "plain one")

    def test_a_failed_setup_gives_back_the_sign_in_that_was_there(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        function = review.shell_function(source, "rollback_dashboard_access")
        harness = self.temp / "restore.sh"
        harness.write_text(
            "#!/bin/sh\nset -eu\n"
            + function
            + '\nHH=$1\nVP=$2\nTRANSACTION_DIR=$3\nrollback_dashboard_access\n',
            encoding="utf-8",
        )
        transaction = self.temp / "transaction"
        transaction.mkdir()
        self.previous = transaction / "dashboard-access.previous.json"
        for label, initial in (
            ("had a sign-in", {"username": "owner", "password_hash": "scrypt$theirs", "secret": "S"}),
            ("had none", None),
        ):
            with self.subTest(label):
                config_path = self.home / "config.json"
                if initial is None:
                    config_path.write_text(json.dumps({"model": "kept"}), encoding="utf-8")
                else:
                    self.set_basic(**initial)
                self.login.unlink(missing_ok=True)
                self.run_access("new-access")
                self.assertNotEqual(
                    self.config()["dashboard"]["basic_auth"].get("password_hash"),
                    (initial or {}).get("password_hash"),
                )
                completed = subprocess.run(
                    ["sh", str(harness), str(self.home), sys.executable, str(transaction)],
                    text=True,
                    capture_output=True,
                    timeout=15,
                    env={**os.environ, "PYTHONPATH": str(self.modules)},
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                restored = self.config()
                self.assertEqual(restored["model"], "kept")
                self.assertEqual(restored["dashboard"]["basic_auth"], initial or {})
                self.previous.unlink()


class PairSignInCheckTests(unittest.TestCase):
    """Showing the code again: the sign-in on record goes in only if it works."""

    def _check(self, accepted_password):
        block = review.embedded_python(PAIR.read_text(encoding="utf-8"), "PY_DASH_LOGIN")

        def dashboard(request):
            body = json.loads(server.requests[-1]["body"] or b"{}")
            if request.path == "/auth/password-login" and body.get("password") == accepted_password:
                return 200, {"Set-Cookie": "hermes_session_at=AT1; Path=/"}, {"ok": True}
            return 401, {}, {"error": "invalid_credentials"}

        with tempfile.TemporaryDirectory(prefix="hermes-pair-login-") as raw:
            temp = pathlib.Path(raw)
            script = temp / "check.py"
            script.write_text(block, encoding="utf-8")
            login = temp / "dashboard-login.json"
            login.write_text(
                json.dumps({"username": "admin", "password": "ON-RECORD"}), encoding="utf-8"
            )
            before = login.read_bytes()
            with review._Server(dashboard) as server:
                completed = subprocess.run(
                    [sys.executable, str(script), server.base + "/", str(login)],
                    text=True,
                    capture_output=True,
                    timeout=15,
                )
            self.assertEqual(login.read_bytes(), before)
            self.assertNotIn("ON-RECORD", completed.stdout + completed.stderr)
            return completed.returncode

    def test_a_sign_in_the_dashboard_accepts_goes_into_the_code(self) -> None:
        self.assertEqual(self._check("ON-RECORD"), 0)

    def test_a_sign_in_the_dashboard_refuses_stays_out(self) -> None:
        self.assertNotEqual(self._check("CHANGED"), 0)

    def test_pairing_still_changes_nothing_on_disk(self) -> None:
        pair = PAIR.read_text(encoding="utf-8")
        for fragment in ("save_config", "rm -f \"$DASH_LOGIN_FILE\"", "> \"$DASH_LOGIN_FILE\""):
            self.assertNotIn(fragment, pair)


MOCK_SYSTEMCTL = """#!/bin/sh
printf '%s\\n' "$*" >> "$MOCK_SYSTEMCTL_LOG"
case "$*" in
  '--user show-environment')
    [ "$MOCK_MANAGER" = systemd ]
    exit $?
    ;;
  '--user show hermes-bridge.service '*)
    printf 'LoadState=loaded\\n'
    printf 'FragmentPath=%s\\n' "$MOCK_FRAGMENT"
    printf 'DropInPaths=\\n'
    printf 'WorkingDirectory=%s\\n' "$MOCK_WORKDIR"
    printf 'ExecStart={ path=%s ; argv[]=%s ; ignore_errors=no ; }\\n' "$MOCK_EXEC" "$MOCK_EXEC"
    exit 0
    ;;
  '--user disable --now hermes-bridge.service')
    [ "$MOCK_STUCK" = 1 ] || : > "$MOCK_STOPPED"
    exit 0
    ;;
  '--user is-active --quiet hermes-bridge.service')
    [ ! -e "$MOCK_STOPPED" ]
    exit $?
    ;;
  *) exit 0 ;;
esac
"""


@unittest.skipUnless(LINUX, "the systemd and portable managers are Linux paths")
class RetireBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory(prefix="hermes-retire-")
        self.addCleanup(self._temp.cleanup)
        self.temp = pathlib.Path(self._temp.name)
        self.home = self.temp / "user"
        self.hermes = self.home / ".hermes"
        self.services = self.hermes / "console-services"
        self.units = self.home / ".config" / "systemd" / "user"
        self.runtime = self.temp / "runtime"
        self.runtime.mkdir()
        self.mock_bin = self.temp / "mock-bin"
        self.mock_bin.mkdir()
        systemctl = self.mock_bin / "systemctl"
        systemctl.write_text(MOCK_SYSTEMCTL, encoding="utf-8")
        systemctl.chmod(0o700)
        self.log = self.temp / "systemctl.log"
        self.log.write_text("", encoding="utf-8")

    def install_fixture(self, with_unit=True) -> None:
        self.services.mkdir(parents=True)
        self.units.mkdir(parents=True)
        (self.hermes / "logs").mkdir()
        (self.hermes / "backups" / "bridge").mkdir(parents=True)
        self.kept = {
            self.hermes / ".env": "API_SERVER_KEY=SYNTHETIC-NOT-A-SECRET\n",
            self.hermes / "config.yaml": "model: kept\n",
            self.hermes / "logs" / "bridge_audit.log": "audit\n",
            self.hermes / "backups" / "bridge" / "config.1": "backup\n",
            self.services / "hermes-gateway.sh": "gateway runner\n",
            self.services / "hermes-dashboard.sh": "dashboard runner\n",
            self.services / "service-manager.sh": "helper\n",
            self.services / "pairing.env": "PAIRING_SCHEMA=1\n",
            self.services / "gateway.pid": "1\n",
            self.units / "hermes-gateway.service": "gateway unit\n",
            self.units / "hermes-dashboard.service": "dashboard unit\n",
        }
        self.removed = [
            self.hermes / "hermes_bridge.py",
            self.hermes / "hermes_bridge.py.rollback",
            self.hermes / "bridge.env",
            self.hermes / "bridge_token",
            self.services / "hermes-bridge.sh",
            self.services / "bridge-release-check.py",
        ]
        if with_unit:
            self.removed.append(self.units / "hermes-bridge.service")
        for path, value in self.kept.items():
            path.write_text(value, encoding="utf-8")
        for path in self.removed:
            path.write_text("bridge\n", encoding="utf-8")

    def retire(self, manager="systemd", **extra):
        return subprocess.run(
            ["sh", str(SETUP), "--retire-bridge"],
            text=True,
            input="",
            capture_output=True,
            timeout=40,
            env={
                **os.environ,
                "PATH": str(self.mock_bin) + os.pathsep + os.environ["PATH"],
                "HOME": str(self.home),
                "XDG_RUNTIME_DIR": str(self.runtime),
                "TMPDIR": str(self.runtime),
                "MOCK_SYSTEMCTL_LOG": str(self.log),
                "MOCK_MANAGER": manager,
                "MOCK_FRAGMENT": str(self.units / "hermes-bridge.service"),
                "MOCK_WORKDIR": str(self.hermes),
                "MOCK_EXEC": str(self.services / "hermes-bridge.sh"),
                "MOCK_STOPPED": str(self.temp / "stopped"),
                "MOCK_STUCK": "0",
                **extra,
            },
        )

    def lifecycle_calls(self):
        return [
            line
            for line in self.log.read_text(encoding="utf-8").splitlines()
            if not line.startswith(("--user show-environment", "--user show "))
        ]

    def assert_kept(self) -> None:
        for path, value in self.kept.items():
            self.assertEqual(path.read_text(encoding="utf-8"), value, str(path))

    def test_without_a_bridge_there_is_nothing_to_do_and_no_home_appears(self) -> None:
        self.home.mkdir()
        completed = self.retire()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("Nothing to do", completed.stdout)
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertEqual(self.lifecycle_calls(), [])
        self.assertEqual(list(self.runtime.iterdir()), [])

    def test_the_bridge_goes_and_gateway_and_dashboard_are_not_touched(self) -> None:
        self.install_fixture()
        completed = self.retire()
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("stopped and removed", completed.stdout)
        for path in self.removed:
            self.assertFalse(path.exists(), str(path))
        self.assert_kept()
        calls = self.lifecycle_calls()
        self.assertIn("--user disable --now hermes-bridge.service", calls)
        for call in calls:
            self.assertNotIn("hermes-gateway", call)
            self.assertNotIn("hermes-dashboard", call)
            self.assertTrue("hermes-bridge.service" in call or call == "--user daemon-reload", call)

        # Running it again finds nothing and still succeeds.
        self.log.write_text("", encoding="utf-8")
        again = self.retire()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("Nothing to do", again.stdout)
        self.assertEqual(self.lifecycle_calls(), [])
        self.assert_kept()
        self.assertEqual(list(self.runtime.iterdir()), [])

    def test_a_bridge_unit_of_another_home_is_refused_whole(self) -> None:
        self.install_fixture()
        before = tree(self.home)
        completed = self.retire(MOCK_EXEC=str(self.temp / "elsewhere" / "hermes-bridge.sh"))
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Nothing was removed", completed.stderr)
        self.assertEqual(tree(self.home), before)
        self.assertEqual(self.lifecycle_calls(), [])

    def test_a_bridge_that_keeps_running_is_not_deleted_under_itself(self) -> None:
        self.install_fixture()
        before = tree(self.home)
        completed = self.retire(MOCK_STUCK="1")
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("still running", completed.stderr)
        self.assertEqual(tree(self.home), before)

    def test_a_unit_without_its_service_manager_is_refused_whole(self) -> None:
        self.install_fixture()
        before = tree(self.home)
        completed = self.retire(manager="none")
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Nothing was removed", completed.stderr)
        self.assertEqual(tree(self.home), before)

    def _sleeper(self, *arguments):
        process = subprocess.Popen(
            [sys.executable, *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(lambda: (process.kill(), process.wait(timeout=5)))
        return process

    @unittest.skipUnless(hasattr(os, "pidfd_open"), "needs pidfd support")
    def test_the_portable_bridge_process_is_stopped_and_only_that_one(self) -> None:
        self.install_fixture(with_unit=False)
        bridge = self.hermes / "hermes_bridge.py"
        bridge.write_text("import time\ntime.sleep(120)\n", encoding="utf-8")
        process = self._sleeper(str(bridge), "--i-know-what-im-doing")
        with open(f"/proc/{process.pid}/stat", encoding="ascii") as source:
            start = source.read().rsplit(") ", 1)[1].split()[19]
        (self.services / "bridge.pid").write_text(f"{process.pid}\n", encoding="utf-8")
        (self.services / "bridge.start").write_text(f"{start}\n", encoding="utf-8")
        (self.services / "bridge.exe").write_text("recorded\n", encoding="utf-8")
        completed = self.retire(manager="none")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertEqual(process.wait(timeout=5), -15)
        for path in self.removed + [
            self.services / "bridge.pid",
            self.services / "bridge.start",
            self.services / "bridge.exe",
        ]:
            self.assertFalse(path.exists(), str(path))
        self.assert_kept()

    @unittest.skipUnless(hasattr(os, "pidfd_open"), "needs pidfd support")
    def test_a_recorded_pid_that_is_now_something_else_is_left_running(self) -> None:
        self.install_fixture(with_unit=False)
        process = self._sleeper("-c", "import time; time.sleep(120)")
        time.sleep(0.2)
        (self.services / "bridge.pid").write_text(f"{process.pid}\n", encoding="utf-8")
        completed = self.retire(manager="none")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("left alone", completed.stdout)
        self.assertIsNone(process.poll())
        for path in self.removed:
            self.assertFalse(path.exists(), str(path))
        self.assert_kept()


if __name__ == "__main__":
    unittest.main(verbosity=2)
