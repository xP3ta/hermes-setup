#!/usr/bin/env python3
"""A whole setup, from nothing to a code that signs in, without the bridge.

The shipped scripts run unmodified against a disposable home. Hermes is a
stand-in that offers exactly the three commands setup drives (--version,
gateway, dashboard) and the same sign-in rules as the real Dashboard: it
refuses to start on the network without a sign-in, a line in .env wins over
the configuration, and rotating the secret ends every open session.

Service managers, sudo, firewalls, curl and the QR renderers are mocks placed
first on PATH, so nothing outside the disposable home can be touched and
nothing is downloaded. The stand-in services listen on two free ports of this
machine's private address for the few seconds the test lasts.
"""

from __future__ import annotations

import importlib.util
import ipaddress
import json
import os
import pathlib
import platform
import re
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
SETUP = ROOT / "hermes-mobile-setup.sh"
PAIR = ROOT / "hermes-pair.sh"

_spec = importlib.util.spec_from_file_location(
    "no_bridge_test", ROOT / "tests" / "no-bridge_test.py"
)
units = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(units)


FAKE_HERMES = r'''#!__PYTHON__
"""Stand-in for Hermes Agent: --version, gateway, dashboard."""
import hashlib, hmac, http.server, json, os, pathlib, sys

from hermes_cli.config import load_config
from plugins.dashboard_auth.basic import hash_password

HOME = pathlib.Path(os.environ.get("HERMES_HOME") or pathlib.Path.home() / ".hermes")


def env_file():
    values = {}
    path = HOME / ".env"
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                name, value = line.split("=", 1)
                values[name.strip()] = value.strip().strip('"')
    return values


def serve(host, port, routes):
    class Handler(http.server.BaseHTTPRequestHandler):
        def _answer(self):
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length) if length else b""
            status, headers, payload = routes(self, body)
            encoded = json.dumps(payload).encode()
            self.send_response(status)
            for name, value in headers.items():
                self.send_header(name, value)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        do_GET = _answer
        do_POST = _answer

        def log_message(self, *_arguments):
            pass

    http.server.ThreadingHTTPServer.allow_reuse_address = True
    http.server.ThreadingHTTPServer((host, port), Handler).serve_forever()


def gateway():
    key = env_file().get("API_SERVER_KEY", "")

    def routes(request, _body):
        if request.path == "/health":
            return 200, {}, {"status": "ok", "platform": "hermes-agent"}
        if request.path == "/api/sessions":
            if key and request.headers.get("Authorization") == "Bearer " + key:
                return 200, {}, {"object": "list", "data": []}
            return 401, {}, {"error": "unauthorized"}
        return 404, {}, {"error": "missing"}

    serve(os.environ["API_SERVER_HOST"], int(os.environ["API_SERVER_PORT"]), routes)


def dashboard(host, port):
    env = env_file()
    basic = (load_config().get("dashboard") or {}).get("basic_auth") or {}
    username = env.get("HERMES_DASHBOARD_BASIC_AUTH_USERNAME") or basic.get("username") or ""
    env_password = env.get("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD") or ""
    password_hash = (
        env.get("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH")
        or basic.get("password_hash")
        or ""
    )
    if env_password:
        password_hash = hash_password(env_password)
    elif not password_hash and basic.get("password"):
        password_hash = hash_password(basic["password"])
    if host != "127.0.0.1" and not (username and password_hash):
        sys.exit("refusing to serve the Dashboard on the network without a sign-in")
    secret = str(basic.get("secret") or "none")
    session = hmac.new(secret.encode(), username.encode(), hashlib.sha256).hexdigest()

    def routes(request, body):
        if request.path == "/api/status":
            return 200, {}, {
                "version": "0.0.0-standin",
                "gateway_running": True,
                "auth_required": True,
            }
        if request.path == "/auth/password-login" and request.command == "POST":
            if os.environ.get("STANDIN_BREAK_SIGN_IN") == "1":
                return 500, {}, {"error": "broken on purpose"}
            value = json.loads(body or b"{}")
            if (
                value.get("provider") == "basic"
                and value.get("username") == username
                and hash_password(str(value.get("password") or "")) == password_hash
            ):
                cookie = "hermes_session_at=" + session + "; Path=/; HttpOnly"
                return 200, {"Set-Cookie": cookie}, {"ok": True}
            return 401, {}, {"error": "invalid_credentials"}
        if request.path == "/api/model/options":
            if request.headers.get("Cookie") == "hermes_session_at=" + session:
                return 200, {}, {"providers": []}
            return 401, {}, {"error": "unauthorized"}
        return 404, {}, {"error": "missing"}

    serve(host, port, routes)


arguments = sys.argv[1:]
if arguments == ["--version"]:
    print("Hermes Agent v0.0.0-standin")
elif arguments[:2] == ["gateway", "run"]:
    gateway()
elif arguments[:1] == ["dashboard"]:
    dashboard(arguments[arguments.index("--host") + 1], int(arguments[arguments.index("--port") + 1]))
else:
    sys.exit("stand-in Hermes: unsupported command " + " ".join(arguments))
'''

# Loaded by every Python the scripts start (it sits in the stand-in's own
# site-packages): a connection to anything but the two stand-in services is
# refused and written down. A real Hermes that happens to run on this machine,
# on its usual ports, can therefore never be reached by a test run.
NETWORK_FENCE = r'''
import os, socket

_allowed = {int(p) for p in os.environ.get("STANDIN_PORTS", "").split(",") if p}
_log = os.environ.get("STANDIN_FENCE_LOG", "")
_connect = socket.socket.connect


def _fenced(self, address, *rest):
    port = address[1] if isinstance(address, tuple) and len(address) >= 2 else None
    if _allowed and port not in _allowed:
        if _log:
            with open(_log, "a", encoding="utf-8") as trail:
                trail.write("%r\n" % (address,))
        raise ConnectionRefusedError("test fence: only the stand-in services may be reached")
    return _connect(self, address, *rest)


socket.socket.connect = _fenced
'''

MOCKS = {
    # No systemd for this user: setup falls back to its own portable manager.
    "systemctl": '#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$MOCK_LOG.systemctl"\nexit 1\n',
    "loginctl": "#!/bin/sh\nexit 1\n",
    "launchctl": "#!/bin/sh\nexit 1\n",
    "tailscale": "#!/bin/sh\nexit 1\n",
    # Privilege is never real here: sudo runs the (mocked) command as the user.
    "sudo": (
        "#!/bin/sh\n"
        'while [ "$#" -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done\n'
        '[ "$#" -gt 0 ] || exit 0\n'
        'exec "$@"\n'
    ),
    "ufw": (
        '#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$MOCK_LOG.ufw"\n'
        '[ "$1" != status ] || echo "Status: inactive"\nexit 0\n'
    ),
    "firewall-cmd": "#!/bin/sh\nexit 1\n",
    "curl": '#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$MOCK_LOG.curl"\nexit 97\n',
    "qrencode": '#!/bin/sh\necho "[code drawn here]"\n',
    "uv": "#!/bin/sh\nexit 1\n",
}


def private_address() -> str | None:
    """An address of this machine a phone on the same network would use."""
    candidates = []
    try:
        listing = subprocess.run(
            ["ip", "-o", "-4", "addr", "show"], text=True, capture_output=True, timeout=5
        ).stdout
        candidates = re.findall(r"inet (\d+\.\d+\.\d+\.\d+)/", listing)
    except (OSError, subprocess.SubprocessError):
        pass
    for value in candidates:
        address = ipaddress.ip_address(value)
        if address.is_private and not address.is_loopback and not address.is_link_local:
            return value
    return None


def free_port(host: str) -> int:
    with socket.socket() as probe:
        probe.bind((host, 0))
        return probe.getsockname()[1]


def http(method, url, body=None, cookie=None, bearer=None):
    headers = {"Accept": "application/json"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    if cookie:
        headers["Cookie"] = cookie
    if bearer:
        headers["Authorization"] = "Bearer " + bearer
    request = urllib.request.Request(
        url, data=json.dumps(body).encode() if body is not None else None,
        headers=headers, method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=6) as response:
            return response.status, response.headers.get("Set-Cookie", ""), response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, "", exc.read()


@unittest.skipUnless(platform.system() == "Linux", "drives the Linux portable manager")
class SetupRig(unittest.TestCase):
    """A disposable home, the stand-in Hermes, the mocks and the fence. No tests
    of its own: tests/legacy-bridge-coexistence_test.py builds on it too."""

    def setUp(self) -> None:
        self.host = private_address()
        if not self.host:
            self.skipTest("this machine has no private address a phone could use")
        self._temp = tempfile.TemporaryDirectory(prefix="hermes-whole-setup-")
        self.addCleanup(self._temp.cleanup)
        self.temp = pathlib.Path(self._temp.name)
        self.home = self.temp / "user"
        self.hermes = self.home / ".hermes"
        self.services = self.hermes / "console-services"
        self.login_file = self.services / "dashboard-login.json"
        self.runtime = self.temp / "runtime"
        self.runtime.mkdir()
        self.mock_bin = self.temp / "mock-bin"
        self.mock_bin.mkdir()
        for name, body in MOCKS.items():
            path = self.mock_bin / name
            path.write_text(body, encoding="utf-8")
            path.chmod(0o700)
        venv = self.hermes / "hermes-agent" / "venv"
        created = subprocess.run(
            [sys.executable, "-m", "venv", "--without-pip", str(venv)],
            text=True, capture_output=True, timeout=120,
        )
        if created.returncode != 0:
            self.skipTest("cannot create a virtual environment here: " + created.stderr[-200:])
        python = venv / "bin" / "python3"
        site = subprocess.run(
            [str(python), "-c", "import site; print(site.getsitepackages()[0])"],
            text=True, capture_output=True, timeout=30, check=True,
        ).stdout.strip()
        units.write_fake_hermes_modules(pathlib.Path(site))
        # A .pth line runs at interpreter start whatever else the system adds
        # (a distribution's own sitecustomize would shadow one placed here).
        (pathlib.Path(site) / "standin_fence.py").write_text(NETWORK_FENCE, encoding="utf-8")
        (pathlib.Path(site) / "standin_fence.pth").write_text("import standin_fence\n", encoding="utf-8")
        self.fence_log = self.temp / "fence.log"
        self.addCleanup(self.assert_nothing_else_was_reached)
        launcher = venv / "bin" / "hermes"
        launcher.write_text(FAKE_HERMES.replace("__PYTHON__", str(python)), encoding="utf-8")
        launcher.chmod(0o700)
        try:
            self.gateway_port = free_port(self.host)
            self.dashboard_port = free_port(self.host)
        except OSError:
            self.skipTest("this sandbox forbids listening on the private address")
        self.gateway = f"http://{self.host}:{self.gateway_port}"
        self.dashboard = f"http://{self.host}:{self.dashboard_port}"
        self.addCleanup(self.stop_services)

    def environment(self, **extra):
        return {
            "PATH": str(self.mock_bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.home),
            "XDG_RUNTIME_DIR": str(self.runtime),
            "TMPDIR": str(self.runtime),
            "LANG": "C",
            "HERMES_PAIR_HOST": self.host,
            "HERMES_GATEWAY_PORT": str(self.gateway_port),
            "HERMES_DASHBOARD_PORT": str(self.dashboard_port),
            "HERMES_REPO_RAW": "https://setup.invalid",
            "MOCK_LOG": str(self.temp / "mock"),
            "STANDIN_PORTS": f"{self.gateway_port},{self.dashboard_port}",
            "STANDIN_FENCE_LOG": str(self.fence_log),
            **extra,
        }

    def assert_nothing_else_was_reached(self) -> None:
        reached = self.fence_log.read_text(encoding="utf-8") if self.fence_log.exists() else ""
        self.assertEqual(reached, "", "a script tried to reach something that is not the stand-in")

    def run_script(self, script, *arguments, **extra):
        return subprocess.run(
            ["sh", str(script), *arguments],
            text=True, input="", capture_output=True, timeout=240,
            env=self.environment(**extra),
        )

    def setup_again(self, *arguments):
        """Without systemd or launchd, setup asks for the services to be stopped
        first and names the two commands; this is the user following them."""
        refused = self.run_script(SETUP, *arguments)
        self.assertNotEqual(refused.returncode, 0)
        commands = re.findall(r"^  (sh \S+service-manager\.sh stop \w+)$", refused.stderr, re.MULTILINE)
        self.assertEqual(len(commands), 2, refused.stderr)
        for command in commands:
            stopped = subprocess.run(
                command.split(), capture_output=True, text=True, timeout=30,
                env=self.environment(),
            )
            self.assertEqual(stopped.returncode, 0, stopped.stderr)
        return self.run_script(SETUP, *arguments)

    def show_code_again(self):
        """hermes-pair.sh as a user runs it: no overrides, only what setup recorded."""
        environment = self.environment()
        for name in ("HERMES_PAIR_HOST", "HERMES_GATEWAY_PORT", "HERMES_DASHBOARD_PORT"):
            environment.pop(name, None)
        return subprocess.run(
            ["sh", str(PAIR)],
            text=True, input="", capture_output=True, timeout=120, env=environment,
        )

    def stop_services(self) -> None:
        helper = self.services / "service-manager.sh"
        for name in ("gateway", "dashboard"):
            if helper.exists():
                subprocess.run(
                    ["sh", str(helper), "stop", name],
                    capture_output=True, timeout=30, env=self.environment(),
                )
            pidfile = self.services / f"{name}.pid"
            if pidfile.exists():
                try:
                    pid = int(pidfile.read_text().split()[0])
                    command = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
                    if str(self.hermes).encode() in command:
                        os.kill(pid, 9)
                except (OSError, ValueError, IndexError):
                    pass

    def link(self, completed) -> dict:
        self.assertEqual(completed.returncode, 0, completed.stdout[-3000:] + completed.stderr[-3000:])
        match = re.search(r"^Link: (hermes://pair\?\S+)$", completed.stdout, re.MULTILINE)
        self.assertIsNotNone(match, completed.stdout[-2000:])
        query = urllib.parse.parse_qs(match.group(1).split("?", 1)[1], strict_parsing=True)
        return {name: values[0] for name, values in query.items()}

    def sign_in(self, link: dict):
        """What the app does with a scanned code: sign in, then use the session."""
        status, cookie, _ = http(
            "POST", link["dashboard"] + "/auth/password-login",
            {"provider": "basic", "username": link["dash_user"], "password": link["dash_pass"]},
        )
        if status != 200:
            return status, ""
        cookie = cookie.split(";", 1)[0]
        status, _, _ = http("GET", link["dashboard"] + "/api/model/options", cookie=cookie)
        return status, cookie

    def config(self) -> dict:
        return json.loads((self.hermes / "config.json").read_text())

    def assert_no_bridge(self) -> None:
        names = [str(path.relative_to(self.home)) for path in self.home.rglob("*")]
        self.assertEqual([name for name in names if "bridge" in name.lower()], [])

class WholeSetupTests(SetupRig):
    def test_the_fence_refuses_and_records_any_other_destination(self) -> None:
        python = self.hermes / "hermes-agent" / "venv" / "bin" / "python3"
        probe = subprocess.run(
            [str(python), "-c",
             "import urllib.request\n"
             "try:\n"
             "    urllib.request.urlopen('http://127.0.0.1:1/', timeout=3)\n"
             "    print('REACHED')\n"
             "except Exception as exc:\n"
             "    print(type(exc).__name__)\n"],
            text=True, capture_output=True, timeout=30, env=self.environment(),
        )
        # Port 1 is nobody's: what is checked is that the attempt was stopped
        # by the fence and written down, before any packet left.
        self.assertNotIn("REACHED", probe.stdout)
        self.assertEqual(self.fence_log.read_text(encoding="utf-8"), "('127.0.0.1', 1)\n")
        self.fence_log.unlink()

    def test_scan_and_done_then_every_way_the_sign_in_can_change(self) -> None:
        # A computer with Hermes and nothing else: one command, one code.
        first = self.run_script(SETUP)
        link = self.link(first)
        self.assertEqual(
            sorted(link), ["dash_pass", "dash_user", "dashboard", "host", "port", "token"]
        )
        self.assertEqual(
            (link["host"], link["port"], link["dashboard"], link["dash_user"]),
            (self.host, str(self.gateway_port), self.dashboard, "admin"),
        )
        self.assertEqual(http("GET", self.gateway + "/api/sessions", bearer=link["token"])[0], 200)
        self.assertEqual(http("GET", self.gateway + "/api/sessions", bearer="wrong")[0], 401)
        status, first_session = self.sign_in(link)
        self.assertEqual(status, 200)
        self.assertEqual(http("GET", self.dashboard + "/api/model/options")[0], 401)
        self.assertIn("  user:     admin", first.stdout)
        self.assertIn("  password: " + link["dash_pass"], first.stdout)
        self.assertEqual(stat.S_IMODE(self.login_file.stat().st_mode), 0o600)
        record = (self.services / "pairing.env").read_text()
        self.assertIn("PAIRING_SCHEMA=2\n", record)
        # The record keeps the Dashboard port, and showing the code again for
        # another address uses it: never the default port of some other Hermes.
        self.assertIn(f"DASHBOARD_PORT={self.dashboard_port}\n", record)
        self.assertNotIn(":9119", PAIR.read_text(encoding="utf-8"))
        self.assert_no_bridge()
        self.assertFalse((self.temp / "mock.curl").exists(), "setup downloaded something")
        self.assertEqual(list(self.runtime.glob("hermes-console-setup-*")), [])

        # Showing the code again reads; it changes nothing.
        before = units.tree(self.home)
        again = self.show_code_again()
        self.assertEqual(self.link(again), link)
        self.assertEqual(units.tree(self.home), before)

        # Running setup again repairs; it does not hand out a new password.
        hash_before = self.config()["dashboard"]["basic_auth"]["password_hash"]
        second = self.setup_again()
        self.assertEqual(self.link(second), link)
        self.assertEqual(self.config()["dashboard"]["basic_auth"]["password_hash"], hash_before)
        self.assertNotIn(link["dash_pass"], second.stdout.replace(urllib.parse.quote(link["dash_pass"]), ""))
        self.assertEqual(self.sign_in(link)[0], 200)

        # What an older setup left of the bridge is not setup's business...
        leftovers = [
            self.hermes / "hermes_bridge.py",
            self.hermes / "bridge.env",
            self.services / "hermes-bridge.sh",
        ]
        for path in leftovers:
            path.write_text("left by an older setup\n", encoding="utf-8")
        third = self.setup_again()
        self.assertEqual(self.link(third), link)
        self.assertIn("--retire-bridge", third.stdout)
        for path in leftovers:
            self.assertEqual(path.read_text(), "left by an older setup\n")

        # ...and removing it leaves Hermes exactly as connected as it was.
        gateway_pid = (self.services / "gateway.pid").read_text()
        dashboard_pid = (self.services / "dashboard.pid").read_text()
        retired = self.run_script(SETUP, "--retire-bridge")
        self.assertEqual(retired.returncode, 0, retired.stdout + retired.stderr)
        self.assert_no_bridge()
        self.assertEqual((self.services / "gateway.pid").read_text(), gateway_pid)
        self.assertEqual((self.services / "dashboard.pid").read_text(), dashboard_pid)
        self.assertEqual(http("GET", self.gateway + "/api/sessions", bearer=link["token"])[0], 200)
        self.assertEqual(self.sign_in(link)[0], 200)
        self.assertEqual(self.link(self.show_code_again()), link)

        # The password was changed somewhere else: it is not ours to replace.
        config_path = self.hermes / "config.json"
        changed = self.config()
        changed["dashboard"]["basic_auth"]["password_hash"] = units.fake_hash("chosen by the user")
        config_path.write_text(json.dumps(changed), encoding="utf-8")
        fourth = self.setup_again()
        without = self.link(fourth)
        self.assertEqual(sorted(without), ["dashboard", "host", "port", "token"])
        self.assertIn("--new-access", fourth.stdout)
        self.assertEqual(
            self.config()["dashboard"]["basic_auth"]["password_hash"],
            units.fake_hash("chosen by the user"),
        )
        self.assertFalse(self.login_file.exists())
        self.assertEqual(sorted(self.link(self.show_code_again())), ["dashboard", "host", "port", "token"])
        status, user_session = self.sign_in({**without, "dash_user": "admin", "dash_pass": "chosen by the user"})
        self.assertEqual(status, 200)

        # "I forgot it": one command makes a new sign-in and ends the old sessions.
        fifth = self.setup_again("--new-access")
        renewed = self.link(fifth)
        self.assertNotIn(renewed["dash_pass"], (link["dash_pass"], "chosen by the user"))
        self.assertEqual(self.sign_in(renewed)[0], 200)
        self.assertEqual(
            self.sign_in({**renewed, "dash_pass": "chosen by the user"})[0], 401
        )
        self.assertEqual(
            http("GET", self.dashboard + "/api/model/options", cookie=user_session)[0], 401
        )
        self.assertEqual(self.link(self.show_code_again()), renewed)

        # A password written in .env is the owner's: used as it is, never replaced.
        with (self.hermes / ".env").open("a", encoding="utf-8") as env:
            env.write('HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="from env &1"\n')
        hash_before = self.config()["dashboard"]["basic_auth"]["password_hash"]
        sixth = self.setup_again("--new-access")
        pinned = self.link(sixth)
        self.assertEqual(pinned["dash_pass"], "from env &1")
        self.assertIn("No new sign-in was made", sixth.stdout)
        self.assertEqual(self.config()["dashboard"]["basic_auth"]["password_hash"], hash_before)
        self.assertEqual(self.sign_in(pinned)[0], 200)
        self.assert_no_bridge()

    def test_a_setup_that_fails_leaves_no_half_made_sign_in(self) -> None:
        (self.hermes / "config.json").write_text(
            json.dumps({"model": "kept"}), encoding="utf-8"
        )
        failed = self.run_script(SETUP, STANDIN_BREAK_SIGN_IN="1")
        self.assertNotEqual(failed.returncode, 0)
        self.assertNotIn("hermes://pair?", failed.stdout + failed.stderr)
        restored = self.config()
        self.assertEqual(restored["model"], "kept")
        self.assertEqual((restored.get("dashboard") or {}).get("basic_auth") or {}, {})
        self.assertFalse(self.login_file.exists())
        self.assertFalse((self.services / "pairing.env").exists())
        self.assertFalse((self.hermes / ".env").exists())
        for name in ("gateway", "dashboard"):
            self.assertFalse((self.services / f"{name}.pid").exists(), name)
        self.assertEqual(list(self.services.glob("setup-transaction.*")), [])
        self.assertEqual(list(self.runtime.glob("hermes-console-setup-*")), [])

        # The same computer, once the fault is gone, sets up normally.
        link = self.link(self.run_script(SETUP))
        self.assertEqual(self.sign_in(link)[0], 200)


if __name__ == "__main__":
    unittest.main(verbosity=2)
