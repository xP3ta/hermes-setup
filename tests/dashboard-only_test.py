#!/usr/bin/env python3
"""Dashboard-only setup: the thin complement that runs after the official Hermes
installer (hermes-dashboard-setup.sh).

It does the one thing the official installer does not: leave the Dashboard on
all the time, bound to one LAN/Tailscale address, behind a sign-in. It never
installs Hermes, never touches the Gateway, never creates an API key and never
prints a pairing code.

Everything runs against disposable homes. Hermes is the stand-in of
no-bridge-install_test.py, extended with the three official calls the script
makes about Dashboard authentication (env loading, plugin discovery, provider
registry). Service managers, sudo and firewalls are mocks placed first on PATH;
a connection fence refuses every destination but the stand-in. Nothing here
installs Hermes, reads the real ~/.hermes or reaches the network.

DASHBOARD_ONLY_SCRIPT points the suite at another script (the mutant runner and
the "what does the old script do" comparison use it).
"""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import platform
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
import urllib.error


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = pathlib.Path(os.environ.get("DASHBOARD_ONLY_SCRIPT") or ROOT / "hermes-dashboard-setup.sh")
OLD_SETUP = ROOT / "hermes-mobile-setup.sh"
OFFICIAL_INSTALL = "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tests" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


units = _load("no_bridge_test", "no-bridge_test.py")


def tree(root):
    """Every file under root, byte for byte; compiled caches are not state."""
    return [item for item in units.tree(root) if "__pycache__" not in item[0]]
rig = _load("no_bridge_install_test", "no-bridge-install_test.py")

LINUX = platform.system() == "Linux"

# The official calls the script makes (hermes_cli/main_dashboard.py:608-720 and
# plugins/dashboard_auth/basic/__init__.py:213-263), reduced to files.
FAKE_AUTH_MODULES = {
    "hermes_cli/env_loader.py": '''
import os, pathlib

def load_hermes_dotenv(*, hermes_home=None, project_env=None, load_external_secrets=True):
    home = pathlib.Path(hermes_home or os.environ["HERMES_HOME"])
    path = home / ".env"
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                name, value = line.split("=", 1)
                os.environ[name.strip()] = value.strip().strip('"')
    return [path]
''',
    "hermes_cli/plugins.py": '''
import glob, os, stat

def discover_plugins(force=False):
    # STANDIN_NOISE: Hermes printing a line on standard output while it loads.
    if os.environ.get("STANDIN_NOISE") == "1":
        print("plugin discovery noise")
    # STANDIN_RECORD_PASSWORD_FILE: the mode of the password file at this moment.
    record = os.environ.get("STANDIN_RECORD_PASSWORD_FILE")
    if record:
        pattern = os.path.join(os.environ["HERMES_HOME"], "console-services", "setup-transaction.*", "new-password")
        with open(record, "a") as out:
            for path in glob.glob(pattern):
                out.write("%o\\n" % stat.S_IMODE(os.stat(path).st_mode))
    return None
''',
    "hermes_cli/plugins_cmd.py": '''
def ensure_basic_auth_plugin_enabled_in_config(cfg):
    disabled = (cfg.get("plugins") or {}).get("disabled")
    if isinstance(disabled, list) and "basic" in disabled:
        disabled.remove("basic")
        return True
    return False
''',
    "hermes_cli/dashboard_auth/__init__.py": '''
import os

class _Provider:
    def __init__(self, name):
        self.name = name

def list_providers(*, scope=None):
    from hermes_cli.config import load_config
    section = (load_config().get("dashboard") or {})
    basic = section.get("basic_auth") or {}
    def setting(env, key):
        return os.environ.get(env, "").strip() or str(basic.get(key) or "").strip()
    found = []
    disabled = (load_config().get("plugins") or {}).get("disabled") or []
    if (setting("HERMES_DASHBOARD_BASIC_AUTH_USERNAME", "username")
            and (setting("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH", "password_hash")
                 or setting("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD", "password"))
            and "basic" not in disabled):
        found.append(_Provider("basic"))
    oauth = (section.get("oauth") or {}).get("client_id") or os.environ.get("HERMES_DASHBOARD_OAUTH_CLIENT_ID", "")
    if str(oauth).strip():
        found.append(_Provider("nous"))
    return found
''',
}

STANDIN = r'''#!__PYTHON__
"""Stand-in for Hermes Agent: --version, gateway run, dashboard."""
import glob, hashlib, hmac, http.server, json, os, pathlib, socket, sys, time

with open(os.environ.get("MOCK_LOG", os.devnull) + ".hermes", "a", encoding="utf-8") as trail:
    trail.write(" ".join(sys.argv[1:]) + "\n")

from hermes_cli.config import load_config
from hermes_cli.dashboard_auth import list_providers
from hermes_cli.env_loader import load_hermes_dotenv
from hermes_cli.plugins import discover_plugins
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
    time.sleep(float(os.environ.get("STANDIN_DASHBOARD_DELAY", "0")))
    watch = os.environ.get("STANDIN_RECORD_TRANSACTION")
    if watch:
        found = glob.glob(str(HOME / "console-services" / "setup-transaction.*" / "*"))
        with open(watch, "a") as out:
            out.write(json.dumps(sorted(os.path.basename(item) for item in found)) + "\n")
    # What main.py:714 and main_dashboard.py:709-712 do before the gate.
    load_hermes_dotenv(hermes_home=HOME)
    discover_plugins(force=True)
    providers = [provider.name for provider in list_providers()]
    if host not in ("127.0.0.1", "::1", "localhost") and not providers:
        sys.exit("refusing to serve the Dashboard on the network without a sign-in")
    env = env_file()
    basic = (load_config().get("dashboard") or {}).get("basic_auth") or {}
    username = env.get("HERMES_DASHBOARD_BASIC_AUTH_USERNAME") or basic.get("username") or ""
    env_password = env.get("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD") or ""
    password_hash = (
        env.get("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH") or basic.get("password_hash") or ""
    )
    if env_password:
        password_hash = hash_password(env_password)
    elif not password_hash and basic.get("password"):
        password_hash = hash_password(basic["password"])
    secret = str(basic.get("secret") or "none")
    session = hmac.new(secret.encode(), username.encode(), hashlib.sha256).hexdigest()

    def routes(request, body):
        if request.path == "/api/status":
            return 200, {}, {"version": "0.0.0-standin", "gateway_running": True, "auth_required": True}
        if request.path == "/auth/password-login" and request.command == "POST":
            if "basic" not in providers:
                return 404, {}, {"error": "no password provider"}
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
            if os.environ.get("STANDIN_OPEN_DASHBOARD") == "1":
                return 200, {}, {"providers": []}
            if request.headers.get("Cookie") == "hermes_session_at=" + session and "basic" in providers:
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

# Loaded by every Python start of the stand-in's interpreter: the command line
# of each one is written down, so "the password was in no argument" is checked
# on what really ran and not on what the script says it does.
ARGV_TRAIL = r'''
import os

_log = os.environ.get("MOCK_LOG", "")
if _log:
    try:
        with open("/proc/self/cmdline", "rb") as _source:
            _line = _source.read().replace(b"\0", b" ").decode("utf-8", "replace")
        with open(_log + ".python", "a", encoding="utf-8") as _trail:
            _trail.write(_line + "\n")
    except OSError:
        pass
'''

# A stateful user service manager: it knows units by their files, keeps them
# running as the real one would and records every call.
MOCK_SYSTEMCTL = r'''#!__PYTHON__
import os, pathlib, re, signal, subprocess, sys, time

arguments = sys.argv[1:]
with open(os.environ["MOCK_LOG"] + ".systemctl", "a", encoding="utf-8") as trail:
    trail.write(" ".join(arguments) + "\n")
state = pathlib.Path(os.environ["MOCK_STATE"])
state.mkdir(parents=True, exist_ok=True)
home = pathlib.Path(os.environ["HOME"])
if arguments[:1] != ["--user"]:
    sys.exit(1)
arguments = arguments[1:]
command = arguments[0] if arguments else ""
rest = arguments[1:]


def name_of(items):
    for item in items:
        if item.startswith("-") or item == "LoadState":
            continue
        return item[:-8] if item.endswith(".service") else item
    return ""


def unit_file(name):
    return home / ".config" / "systemd" / "user" / (name + ".service")


def pid_of(name):
    try:
        return int((state / (name + ".pid")).read_text())
    except (OSError, ValueError):
        return 0


def alive(name):
    pid = pid_of(name)
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
        return stat != "Z"
    except (OSError, IndexError):
        return False


def stop(name):
    pid = pid_of(name)
    if pid and alive(name):
        os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            if not alive(name):
                break
            time.sleep(0.1)
    (state / (name + ".pid")).unlink(missing_ok=True)


def start(name):
    text = unit_file(name).read_text(encoding="utf-8")
    match = re.search(r'^ExecStart="(.*)"$', text, re.M)
    runner = match.group(1).replace('\\"', '"').replace("\\\\", "\\")
    log = open(state / (name + ".log"), "ab")
    process = subprocess.Popen([runner], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    (state / (name + ".pid")).write_text(str(process.pid))


def decode(value):
    return re.sub(r"\\x([0-9a-f]{2})", lambda m: chr(int(m.group(1), 16)), value)


if command == "show-environment":
    sys.exit(0)
if command == "show":
    name = name_of(rest)
    path = unit_file(name)
    if "--value" in rest:
        print("loaded" if path.exists() else "not-found")
        sys.exit(0)
    if not path.exists():
        print("LoadState=not-found")
        sys.exit(0)
    text = path.read_text(encoding="utf-8")
    work = re.search(r"^WorkingDirectory=(.*)$", text, re.M).group(1)
    execs = re.search(r'^ExecStart="(.*)"$', text, re.M).group(1)
    print("LoadState=loaded")
    print("FragmentPath=" + str(path))
    print("DropInPaths=")
    print("WorkingDirectory=" + work)
    print("ExecStart={ path=%s ; argv[]=%s ; ignore_errors=no ; }" % (execs, execs))
    sys.exit(0)
if command in ("daemon-reload", "reset-failed", "status"):
    sys.exit(0)
name = name_of(rest)
if command == "enable":
    for item in rest:
        if not item.startswith("-"):
            (state / (item.replace(".service", "") + ".enabled")).write_text("1")
    sys.exit(0)
if command == "disable":
    (state / (name + ".enabled")).unlink(missing_ok=True)
    if "--now" in rest:
        stop(name)
    sys.exit(0)
if command == "is-enabled":
    sys.exit(0 if (state / (name + ".enabled")).exists() else 1)
if command == "is-active":
    sys.exit(0 if alive(name) else 3)
if command == "stop":
    stop(name)
    sys.exit(0)
if command in ("restart", "start"):
    if not unit_file(name).exists():
        sys.exit(5)
    stop(name)
    start(name)
    sys.exit(0)
sys.exit(0)
'''


def add_hermes_auth_modules(site: pathlib.Path) -> None:
    for relative, body in FAKE_AUTH_MODULES.items():
        path = site / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")


class DashRig(rig.SetupRig):
    """The disposable home, stand-in Hermes (with the official auth calls), the
    fence and the mocks of no-bridge-install_test.py; adds the new script."""

    def setUp(self) -> None:
        super().setUp()
        venv = self.hermes / "hermes-agent" / "venv"
        python = venv / "bin" / "python3"
        site = pathlib.Path(subprocess.run(
            [str(python), "-c", "import site; print(site.getsitepackages()[0])"],
            text=True, capture_output=True, timeout=30, check=True,
        ).stdout.strip())
        add_hermes_auth_modules(site)
        launcher = venv / "bin" / "hermes"
        launcher.write_text(STANDIN.replace("__PYTHON__", str(python)), encoding="utf-8")
        launcher.chmod(0o700)
        (site / "standin_argv.py").write_text(ARGV_TRAIL, encoding="utf-8")
        (site / "standin_argv.pth").write_text("import standin_argv\n", encoding="utf-8")
        self.mock_state = self.temp / "mock-state"
        self.dash_pid = self.services / "dashboard.pid"
        self.dash_helper = self.services / "dashboard-service.sh"

    def environment(self, **extra):
        return super().environment(**{
            "HERMES_DASHBOARD_HOST": self.host,
            "MOCK_STATE": str(self.mock_state),
            **extra,
        })

    # -- driving the new script ------------------------------------------

    def dash(self, *arguments, stdin="", **extra):
        return subprocess.run(
            ["sh", str(SCRIPT), *arguments],
            text=True, input=stdin, capture_output=True, timeout=240,
            env=self.environment(**extra),
        )

    def use_systemd(self) -> None:
        python = self.hermes / "hermes-agent" / "venv" / "bin" / "python"
        body = MOCK_SYSTEMCTL.replace("__PYTHON__", str(python.resolve()))
        path = self.mock_bin / "systemctl"
        path.write_text(body, encoding="utf-8")
        path.chmod(0o700)
        loginctl = self.mock_bin / "loginctl"
        loginctl.write_text("#!/bin/sh\necho yes\n", encoding="utf-8")
        loginctl.chmod(0o700)

    def stop_services(self) -> None:
        super().stop_services()
        pids = []
        if self.mock_state.exists():
            pids += [p for p in self.mock_state.glob("*.pid")]
        pids.append(self.dash_pid)
        for pidfile in pids:
            try:
                pid = int(pidfile.read_text().split()[0])
                command = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
                if str(self.hermes).encode() in command or b"hermes" in command:
                    os.kill(pid, signal.SIGKILL)
            except (OSError, ValueError, IndexError):
                pass

    # -- reading the result ----------------------------------------------

    def config(self) -> dict:
        path = self.hermes / "config.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def basic(self) -> dict:
        return (self.config().get("dashboard") or {}).get("basic_auth") or {}

    def password_from(self, completed) -> str:
        match = re.search(r"^  password: (\S+)$", completed.stdout, re.MULTILINE)
        self.assertIsNotNone(match, completed.stdout[-2000:] + completed.stderr[-2000:])
        return match.group(1)

    def sign_in(self, password, user="admin", base=None):
        base = base or self.dashboard
        status, cookie, _ = rig.http(
            "POST", base + "/auth/password-login",
            {"provider": "basic", "username": user, "password": password},
        )
        if status != 200:
            return status, ""
        cookie = cookie.split(";", 1)[0]
        status, _, _ = rig.http("GET", base + "/api/model/options", cookie=cookie)
        return status, cookie

    def refused(self, port=None, host="127.0.0.1") -> bool:
        with socket.socket() as probe:
            probe.settimeout(2)
            return probe.connect_ex((host, port or self.dashboard_port)) != 0

    def everything_on_disk(self) -> bytes:
        blobs = []
        for path in sorted(self.home.rglob("*")):
            if path.is_file() and not path.is_symlink():
                blobs.append(path.read_bytes())
        return b"\0".join(blobs)

    def log(self, suffix) -> str:
        path = self.temp / ("mock." + suffix)
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def assert_gateway_untouched(self) -> None:
        self.assertNotIn("gateway", self.log("hermes"))
        self.assertNotIn("hermes-gateway", self.log("systemctl"))
        self.assertFalse((self.services / "hermes-gateway.sh").exists())
        env = self.hermes / ".env"
        self.assertNotIn("API_SERVER", env.read_text() if env.exists() else "")
        self.assertTrue(self.refused(self.gateway_port, self.host), "something listens on the Gateway port")


@unittest.skipUnless(LINUX, "drives the Linux managers")
class OptionTests(unittest.TestCase):
    def run_it(self, *arguments):
        with tempfile.TemporaryDirectory(prefix="hermes-dash-options-") as raw:
            home = pathlib.Path(raw) / "home"
            home.mkdir()
            completed = subprocess.run(
                ["sh", str(SCRIPT), *arguments],
                text=True, input="", capture_output=True, timeout=20,
                env={**os.environ, "HOME": str(home), "XDG_RUNTIME_DIR": raw},
            )
            return completed, list(home.iterdir())

    def test_help_names_what_it_does_and_touches_nothing(self) -> None:
        completed, left = self.run_it("--help")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        for option in ("--new-access", "--retire-gateway-exposure", "--retire-bridge", "--password-stdin"):
            self.assertIn(option, completed.stdout)
        self.assertEqual(left, [])

    def test_an_unknown_option_stops_before_anything_happens(self) -> None:
        completed, left = self.run_it("--retire-gatewy-exposure")
        self.assertEqual(completed.returncode, 2)
        self.assertIn("Unknown option", completed.stdout)
        self.assertEqual(left, [])

    def test_two_actions_at_once_are_refused_before_anything_happens(self) -> None:
        completed, left = self.run_it("--new-access", "--retire-gateway-exposure")
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(left, [])

    def test_a_password_cannot_be_given_on_the_command_line(self) -> None:
        completed, left = self.run_it("--password=hunter2")
        self.assertEqual(completed.returncode, 2)
        self.assertNotIn("hunter2", completed.stdout + completed.stderr)
        self.assertEqual(left, [])


    def test_a_password_option_with_a_retire_action_is_refused(self) -> None:
        for action in ("--retire-bridge", "--retire-gateway-exposure"):
            completed, left = self.run_it(action, "--password-stdin")
            self.assertEqual(completed.returncode, 2, action)
            self.assertEqual(left, [])

    def test_removing_the_api_key_is_an_option_of_the_gateway_retire_only(self) -> None:
        for arguments in (("--also-remove-api-key",), ("--new-access", "--also-remove-api-key"),
                          ("--retire-bridge", "--also-remove-api-key"), ("--help", "--also-remove-api-key")):
            with self.subTest(arguments):
                completed, left = self.run_it(*arguments)
                self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
                self.assertIn("--also-remove-api-key only goes with --retire-gateway-exposure", completed.stdout)
                self.assertEqual(left, [])

    def test_help_tells_that_the_api_key_is_kept_unless_asked(self) -> None:
        completed, _ = self.run_it("--help")
        self.assertIn("--also-remove-api-key", completed.stdout)
        self.assertIn("API key is kept", completed.stdout)

    def test_a_script_piped_into_sh_cannot_also_read_a_password_from_stdin(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hermes-dash-pipe-") as raw:
            home = pathlib.Path(raw) / "home"
            home.mkdir()
            completed = subprocess.run(
                ["sh", "-s", "--", "--password-stdin"],
                text=True, input=SCRIPT.read_text(encoding="utf-8"), capture_output=True, timeout=20,
                env={**os.environ, "HOME": str(home), "XDG_RUNTIME_DIR": raw},
            )
            self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
            self.assertIn("saved to a file", completed.stdout)
            self.assertEqual(list(home.iterdir()), [])


class SourceContractTests(unittest.TestCase):
    """What the script is made of, not what it does."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SCRIPT.read_text(encoding="utf-8")
        # The comment that explains the retire path belongs to it.
        match = re.search(
            r"^# Undo what hermes-mobile-setup\.sh added.*?^retire_gateway_exposure\(\) \{\n.*?^\}\n",
            cls.source, re.M | re.S,
        )
        cls.outside_retire = cls.source.replace(match.group(0), "") if match else cls.source

    def test_nothing_outside_the_retire_path_knows_the_api_server(self) -> None:
        for fragment in ("API_SERVER", "gateway run", "hermes-gateway"):
            self.assertNotIn(fragment, self.outside_retire.replace("hermes-gateway.service.d", ""), fragment)

    def test_no_pairing_code_and_no_qr(self) -> None:
        for fragment in ("hermes://pair", "qrencode", "qrcode", "PAIRING_SCHEMA=2\\n"):
            self.assertNotIn(fragment, self.outside_retire)

    def test_it_never_installs_hermes(self) -> None:
        for fragment in ("| bash -s", "install.sh | bash", "run_hermes_installer", "--skip-setup", "git clone"):
            self.assertNotIn(fragment, self.source.replace(OFFICIAL_INSTALL, ""))

    def test_the_windows_script_it_points_at_exists(self) -> None:
        # The shell script names the PowerShell one; it must be there to be named.
        self.assertIn("hermes-dashboard-setup.ps1", self.source)
        self.assertTrue((ROOT / "hermes-dashboard-setup.ps1").is_file())

    def test_native_windows_is_sent_to_the_powershell_script(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hermes-dash-win-") as raw:
            home = pathlib.Path(raw) / "home"
            home.mkdir()
            mock = pathlib.Path(raw) / "bin"
            mock.mkdir()
            (mock / "uname").write_text("#!/bin/sh\necho MINGW64_NT-10.0\n", encoding="utf-8")
            (mock / "uname").chmod(0o700)
            completed = subprocess.run(
                ["sh", str(SCRIPT)], text=True, input="", capture_output=True, timeout=20,
                env={**os.environ, "HOME": str(home), "XDG_RUNTIME_DIR": raw,
                     "PATH": str(mock) + os.pathsep + os.environ["PATH"]},
            )
            self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
            self.assertIn("hermes-dashboard-setup.ps1", completed.stdout)
            self.assertIn("Windows PowerShell", completed.stdout)
            self.assertEqual(list(home.iterdir()), [])

    def test_no_gnu_only_alternation_in_a_basic_regular_expression(self) -> None:
        # \\| in a BRE is a GNU extension; macOS grep and sed do not read it.
        self.assertIsNone(re.search(r"\\\|", self.source), "use grep -E and (a|b)")

    def test_it_stays_posix_and_ascii(self) -> None:
        self.assertTrue(self.source.startswith("#!/bin/sh\n"))
        self.source.encode("ascii")
        completed = subprocess.run(["sh", "-n", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_it_publishes_no_private_paths_addresses_or_names(self) -> None:
        for fragment in ("/home/", "xpeta@", "udyat"):
            self.assertNotIn(fragment, self.source)
        # No address written out in full except the two that are not anyone's.
        quads = set(re.findall(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", self.source))
        self.assertLessEqual(quads, {"100.64.0.0", "0.0.0.0"}, quads)
        tests_text = pathlib.Path(__file__).read_text(encoding="utf-8")
        self.assertNotIn("/home/xp" + "eta", tests_text)


@unittest.skipUnless(LINUX, "drives the Linux managers")
class SetupTests(DashRig):
    def test_a_hermes_without_a_sign_in_gets_the_dashboard_on_one_address_and_one_password(self) -> None:
        completed = self.dash()
        self.assertEqual(completed.returncode, 0, completed.stdout[-3000:] + completed.stderr[-3000:])
        password = self.password_from(completed)
        self.assertIn("  user:     admin", completed.stdout)
        self.assertIn(f"Dashboard: {self.dashboard}", completed.stdout)
        self.assertIn("Gateway: not touched", completed.stdout)
        # Shown once, and only in the output.
        self.assertEqual(completed.stdout.count(password), 1)
        self.assertNotIn(password, completed.stderr)
        # Bound to the chosen address and nowhere else; protected; the password works.
        self.assertTrue(self.refused(host="127.0.0.1"))
        self.assertEqual(rig.http("GET", self.dashboard + "/api/model/options")[0], 401)
        self.assertEqual(self.sign_in(password)[0], 200)
        self.assertEqual(self.sign_in("wrong")[0], 401)
        # Official shape: scrypt hash, no plaintext, a stable secret.
        basic = self.basic()
        self.assertEqual(basic["username"], "admin")
        self.assertTrue(basic["password_hash"].startswith("fake$"))
        self.assertEqual(basic["password"], "")
        self.assertGreaterEqual(len(basic["secret"]), 32)
        # The password is nowhere on disk and was never an argument of anything.
        self.assertNotIn(password.encode(), self.everything_on_disk())
        for trail in ("python", "hermes", "systemctl", "ufw", "curl"):
            self.assertNotIn(password, self.log(trail), trail)
        self.assertFalse(self.login_file.exists())
        # Nothing of the Gateway, no key, no pairing record, no code.
        self.assert_gateway_untouched()
        self.assertFalse((self.services / "pairing.env").exists())
        self.assertNotIn("hermes://pair", completed.stdout)
        self.assertFalse((self.temp / "mock.curl").exists(), "the script downloaded something")
        self.assertEqual(list(self.runtime.glob("hermes-console-setup-*")), [])
        self.assertEqual(list(self.services.glob("setup-transaction.*")), [])
        runner = (self.services / "hermes-dashboard.sh").read_text()
        self.assertIn(f'--host "{self.host}" --port "{self.dashboard_port}"', runner)
        self.assertNotIn("0.0.0.0", runner)
        self.assertEqual(stat.S_IMODE((self.services / "hermes-dashboard.sh").stat().st_mode), 0o700)

    def test_running_it_again_keeps_the_sign_in_and_shows_no_password(self) -> None:
        first = self.dash()
        password = self.password_from(first)
        hash_before = self.basic()["password_hash"]
        secret_before = self.basic()["secret"]
        second = self.dash()
        self.assertEqual(second.returncode, 0, second.stdout[-2000:] + second.stderr[-2000:])
        self.assertNotIn("password:", second.stdout)
        self.assertIn("kept as it is", second.stdout)
        self.assertEqual(self.basic()["password_hash"], hash_before)
        self.assertEqual(self.basic()["secret"], secret_before)
        self.assertEqual(self.sign_in(password)[0], 200)
        self.assertEqual(list(self.services.glob("setup-transaction.*")), [])

    def test_an_authentication_provider_that_is_already_there_is_not_touched(self) -> None:
        cases = {
            "basic in the configuration": (
                {"dashboard": {"basic_auth": {"username": "owner", "password_hash": units.fake_hash("mine"),
                                              "password": "", "secret": "s" * 32}}}, None),
            "basic pinned in .env": (
                {"model": "kept"}, 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=owner\n'
                                   'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="from env"\n'),
            "OAuth client": ({"dashboard": {"oauth": {"client_id": "abc"}}}, None),
            "OAuth client in .env": ({"model": "kept"}, "HERMES_DASHBOARD_OAUTH_CLIENT_ID=abc\n"),
        }
        for label, (config, env) in cases.items():
            with self.subTest(label):
                self.stop_services()
                shutil.rmtree(self.services, ignore_errors=True)
                (self.hermes / "config.json").write_text(json.dumps(config, sort_keys=True), encoding="utf-8")
                if env is None:
                    (self.hermes / ".env").unlink(missing_ok=True)
                else:
                    (self.hermes / ".env").write_text(env, encoding="utf-8")
                before = {n: (self.hermes / n).read_bytes() for n in ("config.json", ".env") if (self.hermes / n).exists()}
                completed = self.dash()
                self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
                self.assertIn("kept as it is", completed.stdout)
                self.assertNotIn("password:", completed.stdout)
                after = {n: (self.hermes / n).read_bytes() for n in ("config.json", ".env") if (self.hermes / n).exists()}
                self.assertEqual(after, before)
                self.assertEqual(rig.http("GET", self.dashboard + "/api/model/options")[0], 401)
                self.assertFalse(self.login_file.exists())

    def test_new_access_replaces_the_password_and_ends_old_sessions(self) -> None:
        password = self.password_from(self.dash())
        status, session = self.sign_in(password)
        self.assertEqual(status, 200)
        secret_before = self.basic()["secret"]
        completed = self.dash("--new-access")
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        renewed = self.password_from(completed)
        self.assertNotEqual(renewed, password)
        self.assertNotEqual(self.basic()["secret"], secret_before)
        self.assertEqual(self.sign_in(renewed)[0], 200)
        self.assertEqual(self.sign_in(password)[0], 401)
        self.assertEqual(rig.http("GET", self.dashboard + "/api/model/options", cookie=session)[0], 401)
        self.assertNotIn(renewed.encode(), self.everything_on_disk())

    def test_new_access_does_not_touch_a_sign_in_it_did_not_make(self) -> None:
        (self.hermes / ".env").write_text(
            'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=owner\nHERMES_DASHBOARD_BASIC_AUTH_PASSWORD="from env"\n',
            encoding="utf-8",
        )
        before = (self.hermes / ".env").read_bytes()
        completed = self.dash("--new-access")
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        self.assertIn("No new sign-in was made", completed.stdout)
        self.assertEqual((self.hermes / ".env").read_bytes(), before)
        self.assertEqual(self.basic().get("password_hash", ""), "")

    def test_a_password_given_on_stdin_is_the_one_that_works_and_is_never_echoed(self) -> None:
        chosen = "correct horse battery staple"
        completed = self.dash("--password-stdin", stdin=chosen + "\n")
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        self.assertNotIn(chosen, completed.stdout + completed.stderr)
        self.assertIsNone(re.search(r"^  password: \S+$", completed.stdout, re.MULTILINE))
        self.assertEqual(self.sign_in(chosen)[0], 200)
        self.assertNotIn(chosen.encode(), self.everything_on_disk())
        for trail in ("python", "hermes", "systemctl"):
            self.assertNotIn(chosen, self.log(trail), trail)

    def test_an_empty_password_on_stdin_is_refused_before_anything_changes(self) -> None:
        before = tree(self.hermes)
        for given in ("", "\n", "   \n"):
            completed = self.dash("--password-stdin", stdin=given)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("empty", (completed.stdout + completed.stderr).lower())
        self.assertEqual(tree(self.hermes), before)

    def test_only_a_lan_or_tailscale_address_may_be_chosen(self) -> None:
        before = tree(self.hermes)
        for bad in ("0.0.0.0", "127.0.0.1", "169.254.7.7", "8.8.8.8", "::", "::1", "not-an-address",
                    "example.com", "192.0.2.1/24", ""):
            with self.subTest(bad):
                completed = self.dash(HERMES_DASHBOARD_HOST=bad)
                if bad == "":
                    # An empty value is "not given": the script picks an address itself.
                    self.stop_services()
                    shutil.rmtree(self.services, ignore_errors=True)
                    continue
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("HERMES_DASHBOARD_HOST", completed.stdout + completed.stderr)
                self.assertEqual(tree(self.hermes), before)
        self.assertTrue(self.refused())

    def test_a_port_taken_by_something_else_is_refused_and_left_alone(self) -> None:
        blocker = socket.socket()
        self.addCleanup(blocker.close)
        blocker.bind((self.host, self.dashboard_port))
        blocker.listen(1)
        completed = self.dash()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("occupied", completed.stdout + completed.stderr)
        self.assertFalse((self.services / "dashboard.pid").exists())
        self.assertEqual(self.basic().get("password_hash", ""), "")

    def test_without_hermes_it_says_which_official_command_installs_it_and_creates_nothing(self) -> None:
        shutil.rmtree(self.hermes)
        completed = self.dash()
        self.assertEqual(completed.returncode, 1)
        self.assertIn("not installed", completed.stdout + completed.stderr)
        self.assertIn(OFFICIAL_INSTALL, completed.stdout + completed.stderr)
        self.assertFalse(self.hermes.exists())
        self.assertFalse((self.temp / "mock.curl").exists())

    def test_a_setup_that_fails_gives_back_the_sign_in_that_was_there(self) -> None:
        (self.hermes / "config.json").write_text(json.dumps({"model": "kept"}), encoding="utf-8")
        failed = self.dash(STANDIN_BREAK_SIGN_IN="1")
        self.assertNotEqual(failed.returncode, 0)
        self.assertNotIn("password:", failed.stdout)
        restored = self.config()
        self.assertEqual(restored["model"], "kept")
        self.assertEqual((restored.get("dashboard") or {}).get("basic_auth") or {}, {})
        self.assertFalse((self.services / "hermes-dashboard.sh").exists())
        self.assertFalse(self.dash_pid.exists())
        self.assertEqual(list(self.services.glob("setup-transaction.*")), [])
        self.assertEqual(list(self.runtime.glob("hermes-console-setup-*")), [])
        self.assertTrue(self.refused())
        # The same computer, once the fault is gone, sets up normally.
        again = self.dash()
        self.assertEqual(self.sign_in(self.password_from(again))[0], 200)

    def test_a_dashboard_that_is_slow_to_come_up_is_waited_for(self) -> None:
        completed = self.dash(STANDIN_DASHBOARD_DELAY="3")
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        self.assertEqual(self.sign_in(self.password_from(completed))[0], 200)

    def test_the_setup_lock_is_taken_and_released(self) -> None:
        lock = self.runtime / f"hermes-console-setup-{os.getuid()}.lock"
        lock.mkdir()
        (lock / "pid").write_text(f"{os.getpid()}\n")
        before = tree(self.hermes)
        refused = self.dash()
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("another Console setup is already running", refused.stderr)
        self.assertEqual(tree(self.hermes), before)
        shutil.rmtree(lock)
        self.assertEqual(self.dash().returncode, 0)
        self.assertEqual(list(self.runtime.glob("hermes-console-setup-*")), [])


    # -- P2-1 / P2-5: a sign-in that is written down but parked ------------------

    PARKED = {"dashboard": {"basic_auth": {"username": "owner", "password_hash": units.fake_hash("mine"),
                                           "password": "", "secret": "s" * 32}},
              "plugins": {"disabled": ["basic"]}}

    def test_a_sign_in_that_is_written_down_but_parked_is_switched_on_not_replaced(self) -> None:
        (self.hermes / "config.json").write_text(json.dumps(self.PARKED, sort_keys=True), encoding="utf-8")
        completed = self.dash()
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        self.assertIn("kept as it is", completed.stdout)
        self.assertIsNone(re.search(r"^  password: ", completed.stdout, re.MULTILINE))
        self.assertIn("Re-enabled the bundled 'basic' auth plugin", completed.stderr)
        basic = self.basic()
        self.assertEqual(basic["password_hash"], units.fake_hash("mine"))
        self.assertEqual(basic["secret"], "s" * 32)
        self.assertEqual(basic["username"], "owner")
        self.assertEqual(self.config()["plugins"]["disabled"], [])
        self.assertEqual(rig.http("GET", self.dashboard + "/api/model/options")[0], 401)
        self.assertEqual(self.sign_in("mine", user="owner")[0], 200)

    def test_a_parked_sign_in_comes_back_parked_when_setup_fails(self) -> None:
        (self.hermes / "config.json").write_text(json.dumps(self.PARKED, sort_keys=True), encoding="utf-8")
        before = self.config()
        failed = self.dash(STANDIN_OPEN_DASHBOARD="1")
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(self.config(), before)
        self.assertEqual(list(self.services.glob("setup-transaction.*")), [])

    def test_a_plugin_this_run_switched_on_is_switched_off_again_when_setup_fails(self) -> None:
        (self.hermes / "config.json").write_text(
            json.dumps({"model": "kept", "plugins": {"disabled": ["basic", "other"]}}, sort_keys=True), encoding="utf-8")
        failed = self.dash(STANDIN_BREAK_SIGN_IN="1")
        self.assertNotEqual(failed.returncode, 0)
        restored = self.config()
        self.assertEqual(restored["model"], "kept")
        self.assertEqual(sorted(restored["plugins"]["disabled"]), ["basic", "other"])
        self.assertEqual((restored.get("dashboard") or {}).get("basic_auth") or {}, {})
        self.assertEqual(list(self.services.glob("setup-transaction.*")), [])

    # -- P2-3: the generated password does not travel on standard output ----------

    def test_a_line_printed_while_hermes_loads_does_not_become_part_of_the_password(self) -> None:
        completed = self.dash(STANDIN_NOISE="1")
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        password = self.password_from(completed)
        self.assertNotIn("noise", password)
        # Shown (it is Hermes' answer), but with the errors, not in the setup's own output.
        self.assertIn("plugin discovery noise", completed.stderr)
        self.assertNotIn("plugin discovery noise", completed.stdout)
        self.assertEqual(self.sign_in(password)[0], 200)

    def test_the_password_file_is_private_from_the_start_and_gone_before_the_dashboard_starts(self) -> None:
        seen_mode = self.temp / "password-file-mode"
        seen_files = self.temp / "transaction-files"
        previous = os.umask(0o022)
        try:
            completed = self.dash(STANDIN_RECORD_PASSWORD_FILE=str(seen_mode),
                                  STANDIN_RECORD_TRANSACTION=str(seen_files))
        finally:
            os.umask(previous)
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        self.assertEqual(seen_mode.read_text().split(), ["600"])
        listings = [json.loads(line) for line in seen_files.read_text().splitlines()]
        self.assertTrue(listings)
        for names in listings:
            self.assertNotIn("new-password", names)
        self.assertEqual(list(self.services.glob("setup-transaction.*")), [])

    def test_a_password_given_on_stdin_leaves_no_password_file_behind(self) -> None:
        seen_files = self.temp / "transaction-files"
        completed = self.dash("--password-stdin", stdin="a chosen password\n",
                              STANDIN_RECORD_TRANSACTION=str(seen_files))
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        for line in seen_files.read_text().splitlines():
            self.assertNotIn("new-password", json.loads(line))
        self.assertEqual(self.sign_in("a chosen password")[0], 200)

    # -- P2-2 / P2-6: what the final message says -----------------------------------

    def test_a_new_password_says_that_external_secret_sources_were_not_read(self) -> None:
        completed = self.dash()
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        self.assertIn("external secret source", completed.stdout)

    def test_a_clear_password_record_that_is_kept_is_warned_about_at_setup(self) -> None:
        self.services.mkdir(parents=True)
        self.login_file.write_text(json.dumps({"user": "old", "password": "old-clear-password"}), encoding="utf-8")
        (self.hermes / "config.json").write_text(json.dumps(self.PARKED, sort_keys=True), encoding="utf-8")
        completed = self.dash()
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        self.assertIn("kept as it is", completed.stdout)
        self.assertTrue(self.login_file.exists())
        self.assertIn("dashboard-login.json still holds a Dashboard password", completed.stdout)
        self.assertNotIn("old-clear-password", completed.stdout + completed.stderr)

    def test_a_new_sign_in_replaces_the_clear_record_and_has_nothing_to_warn_about(self) -> None:
        self.services.mkdir(parents=True)
        self.login_file.write_text(json.dumps({"user": "old", "password": "old-clear-password"}), encoding="utf-8")
        completed = self.dash()
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        self.assertFalse(self.login_file.exists())
        self.assertNotIn("still holds a Dashboard password", completed.stdout)


    def test_a_dashboard_that_does_not_protect_its_pages_is_not_accepted(self) -> None:
        completed = self.dash(STANDIN_OPEN_DASHBOARD="1")
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("did not refuse", completed.stdout + completed.stderr)
        self.assertNotIn("DASHBOARD READY", completed.stdout)
        self.assertEqual(self.basic().get("password_hash", ""), "")
        self.assertTrue(self.refused())

    def test_a_port_that_is_not_a_port_is_refused_before_anything_changes(self) -> None:
        before = tree(self.hermes)
        for bad in ("abc", "0", "70000", "-1", "9119 "):
            with self.subTest(bad):
                completed = self.dash(HERMES_DASHBOARD_PORT=bad)
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("HERMES_DASHBOARD_PORT", completed.stdout + completed.stderr)
                self.assertEqual(tree(self.hermes), before)

    def test_new_access_leaves_another_provider_alone(self) -> None:
        (self.hermes / "config.json").write_text(
            json.dumps({"dashboard": {"oauth": {"client_id": "abc"}}}, sort_keys=True), encoding="utf-8")
        before = (self.hermes / "config.json").read_bytes()
        completed = self.dash("--new-access")
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        self.assertIn("Another sign-in provider", completed.stdout)
        self.assertEqual((self.hermes / "config.json").read_bytes(), before)
        self.assertIsNone(re.search(r"^  password: ", completed.stdout, re.MULTILINE))

    def test_a_wsl_address_is_not_guessed(self) -> None:
        before = tree(self.hermes)
        completed = self.dash(WSL_INTEROP="1", HERMES_DASHBOARD_HOST="")
        self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
        self.assertIn("WSL detected", completed.stdout)
        self.assertEqual(tree(self.hermes), before)
        # An explicit address is the opt-in the message names.
        chosen = self.dash(WSL_INTEROP="1")
        self.assertEqual(chosen.returncode, 0, chosen.stdout[-2000:] + chosen.stderr[-2000:])

    def test_a_hermes_home_that_is_not_a_plain_absolute_path_is_refused(self) -> None:
        link = self.temp / "link"
        link.symlink_to(self.hermes)
        cases = (
            ("relative/home", "absolute path"),
            (str(link), "symbolic link"),
            ('/tmp/with"quote', "unsupported characters"),
        )
        for bad, reason in cases:
            with self.subTest(bad):
                completed = self.dash(HERMES_HOME=bad)
                self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
                self.assertIn(reason, completed.stderr)
        empty = self.dash(HERMES_HOME="")
        self.assertEqual(empty.returncode, 1)
        self.assertIn("may not be empty", empty.stderr)

    def test_a_second_hermes_home_is_not_chosen_over_the_one_that_exists(self) -> None:
        other = self.temp / "elsewhere"
        other.mkdir()
        before = tree(self.hermes)
        completed = self.dash(HERMES_HOME=str(other))
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        self.assertIn("another Hermes home exists", completed.stderr)
        self.assertEqual(tree(self.hermes), before)
        self.assertEqual(list(other.iterdir()), [])

    def test_a_lock_left_by_a_dead_run_does_not_lock_anyone_out(self) -> None:
        gone = subprocess.Popen(["true"])
        gone.wait()
        lock = self.runtime / f"hermes-console-setup-{os.getuid()}.lock"
        lock.mkdir()
        (lock / "pid").write_text(f"{gone.pid}\n")
        completed = self.dash()
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        self.assertEqual(list(self.runtime.glob("hermes-console-setup-*")), [])

    def test_a_services_folder_that_is_a_link_is_refused(self) -> None:
        target = self.temp / "elsewhere"
        target.mkdir()
        self.services.parent.mkdir(parents=True, exist_ok=True)
        self.services.symlink_to(target)
        completed = self.dash()
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        self.assertIn("symbolic link", completed.stderr)
        self.assertEqual(list(target.iterdir()), [])

    def test_a_hermes_whose_libraries_cannot_run_is_refused_untouched(self) -> None:
        python = self.hermes / "hermes-agent" / "venv" / "bin" / "python3"
        site = pathlib.Path(subprocess.run(
            [str(python), "-c", "import site; print(site.getsitepackages()[0])"],
            text=True, capture_output=True, check=True).stdout.strip())
        launcher = self.hermes / "hermes-agent" / "venv" / "bin" / "hermes"
        real = launcher.with_name("hermes.real")
        launcher.rename(real)
        launcher.write_text(
            f'#!/bin/sh\n[ "$1" = --version ] && {{ echo Hermes; exit 0; }}\nexec "{real}" "$@"\n',
            encoding="utf-8")
        launcher.chmod(0o700)
        (site / "hermes_cli" / "config.py").unlink()
        before = tree(self.hermes)
        completed = self.dash()
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        self.assertIn("cannot run its own configuration code", completed.stderr)
        self.assertEqual(tree(self.hermes), before)

    def test_a_dashboard_pid_that_is_now_another_process_is_never_signalled(self) -> None:
        first = self.dash()
        self.assertEqual(first.returncode, 0, first.stdout[-1500:] + first.stderr[-1500:])
        self.stop_services()
        stranger = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
        self.addCleanup(lambda: (stranger.kill(), stranger.wait(timeout=5)))
        time.sleep(0.3)
        self.dash_pid.write_text(f"{stranger.pid}\n", encoding="utf-8")
        (self.services / "dashboard.start").write_text("1\n", encoding="utf-8")
        (self.services / "dashboard.exe").write_text("/not/the/dashboard\n", encoding="utf-8")
        runner_before = (self.services / "hermes-dashboard.sh").read_bytes()
        again = self.dash("--new-access")
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("ownership is not proven", again.stderr)
        self.assertIsNone(stranger.poll(), "an unrelated process was signalled")
        self.assertEqual((self.services / "hermes-dashboard.sh").read_bytes(), runner_before)
        self.assertEqual(list(self.services.glob("setup-transaction.*")), [])


@unittest.skipUnless(LINUX, "drives systemd")
class SystemdTests(DashRig):
    def setUp(self) -> None:
        super().setUp()
        self.use_systemd()
        self.unit = self.home / ".config" / "systemd" / "user" / "hermes-dashboard.service"

    def test_the_dashboard_becomes_a_user_service_that_starts_with_the_machine(self) -> None:
        completed = self.dash()
        self.assertEqual(completed.returncode, 0, completed.stdout[-3000:] + completed.stderr[-3000:])
        password = self.password_from(completed)
        text = self.unit.read_text()
        self.assertIn("Restart=on-failure", text)
        self.assertIn("WantedBy=default.target", text)
        self.assertIn(str(self.services / "hermes-dashboard.sh"), text)
        calls = self.log("systemctl")
        self.assertIn("--user enable hermes-dashboard", calls)
        self.assertIn("--user restart hermes-dashboard", calls)
        self.assertIn("starts by itself after a restart: yes (systemd)", completed.stdout.lower())
        self.assertEqual(self.sign_in(password)[0], 200)
        self.assertFalse(self.dash_pid.exists(), "the portable manager must not run beside systemd")
        self.assert_gateway_untouched()

    def test_a_slow_network_cannot_leave_the_unit_failed_for_good(self) -> None:
        completed = self.dash()
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        text = self.unit.read_text()
        unit_section = text.split("[Service]", 1)[0]
        self.assertIn("\nStartLimitIntervalSec=0\n", unit_section)
        self.assertIn("Restart=on-failure", text.split("[Service]", 1)[1])

    def test_a_unit_of_another_home_is_refused_and_nothing_changes(self) -> None:
        self.unit.parent.mkdir(parents=True)
        self.unit.write_text(
            '[Unit]\nDescription=someone else\n[Service]\nExecStart="/opt/elsewhere/run.sh"\n'
            "WorkingDirectory=/opt/elsewhere\n",
            encoding="utf-8",
        )
        before = tree(self.home)
        completed = self.dash()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("belongs to another home", completed.stdout + completed.stderr)
        self.assertEqual(tree(self.home), before)

    def test_a_stale_launchd_definition_next_to_systemd_is_refused(self) -> None:
        agents = self.home / "Library" / "LaunchAgents"
        agents.mkdir(parents=True)
        (agents / "dev.xpetalab.hermes-console.dashboard.plist").write_text("stale\n")
        before = tree(self.home)
        completed = self.dash()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("stale launchd definition", completed.stderr)
        self.assertEqual(tree(self.home), before)

    def test_a_failed_start_puts_the_previous_unit_back(self) -> None:
        first = self.dash()
        self.assertEqual(first.returncode, 0, first.stdout[-2000:] + first.stderr[-2000:])
        unit_before = self.unit.read_bytes()
        runner_before = (self.services / "hermes-dashboard.sh").read_bytes()
        basic_before = self.basic()
        # Another address would be a new unit; the sign-in check is what fails.
        failed = self.dash("--new-access", STANDIN_BREAK_SIGN_IN="1")
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(self.unit.read_bytes(), unit_before)
        self.assertEqual((self.services / "hermes-dashboard.sh").read_bytes(), runner_before)
        self.assertEqual(self.basic(), basic_before)
        self.assertEqual(list(self.services.glob("setup-transaction.*")), [])


@unittest.skipUnless(LINUX, "drives the Linux managers")
class RetireGatewayExposureTests(DashRig):
    """Against what the previous script really leaves: it is run first."""

    def old_setup(self):
        completed = self.run_script(OLD_SETUP)
        self.assertEqual(completed.returncode, 0, completed.stdout[-3000:] + completed.stderr[-3000:])
        return self.link(completed)

    def retire(self, *arguments, **extra):
        return self.dash("--retire-gateway-exposure", *arguments, **extra)

    def test_it_removes_what_the_old_script_added_and_leaves_the_running_gateway_alone(self) -> None:
        link = self.old_setup()
        self.assertEqual(rig.http("GET", self.gateway + "/api/sessions", bearer=link["token"])[0], 200)
        keep_paths = [
            self.services / "gateway.pid", self.services / "gateway.start", self.services / "gateway.exe",
            self.services / "dashboard.pid", self.services / "service-manager.sh",
            self.login_file, self.hermes / "config.json",
        ]
        keep = {p: p.read_bytes() for p in keep_paths}
        env_lines = (self.hermes / ".env").read_text().splitlines()
        key_line = next(line for line in env_lines if line.startswith("API_SERVER_KEY="))
        (self.hermes / ".env").write_text("\n".join(["BEFORE=1", *env_lines, "AFTER=2"]) + "\n")
        runner = self.services / "hermes-gateway.sh"
        self.assertIn("API_SERVER_HOST", runner.read_text())

        env_before = (self.hermes / ".env").read_bytes()
        completed = self.retire()
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("Done.", completed.stdout)
        # The key is kept: it may be somebody else's. The file is not even rewritten.
        self.assertEqual((self.hermes / ".env").read_bytes(), env_before)
        env = (self.hermes / ".env").read_text()
        self.assertIn(key_line, env)
        self.assertIn("BEFORE=1", env)
        self.assertIn("AFTER=2", env)
        self.assertFalse((self.services / "pairing.env").exists())
        text = runner.read_text()
        for gone in ("API_SERVER_HOST", "API_SERVER_PORT"):
            self.assertNotIn(gone, text)
        self.assertIn("gateway run --replace", text)
        for path, value in keep.items():
            self.assertEqual(path.read_bytes(), value, str(path))
        # The Gateway process was not stopped: it keeps serving until Hermes restarts it.
        self.assertEqual(rig.http("GET", self.gateway + "/api/sessions", bearer=link["token"])[0], 200)
        self.assertIn("until the Gateway is restarted", completed.stdout)
        self.assertIn("Left in place", completed.stdout)
        self.assertIn("dashboard-login.json", completed.stdout)
        # What it says about the key: kept, and how to take it out. No promise about cron.
        self.assertIn("Your API key", completed.stdout)
        self.assertIn("was kept", completed.stdout)
        self.assertIn("--also-remove-api-key", completed.stdout)
        self.assertNotIn("not affected", completed.stdout)
        self.assertFalse((self.hermes / "backups" / "gateway-exposure").exists())
        self.assertNotIn(key_line.split("=", 1)[1], completed.stdout + completed.stderr)

        # Twice is the same as once.
        before = tree(self.home)
        again = self.retire()
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertIn("Nothing to do", again.stdout)
        self.assertEqual(tree(self.home), before)

    def test_new_access_over_an_old_install_drops_its_clear_password_record(self) -> None:
        link = self.old_setup()
        self.assertTrue(self.login_file.exists())
        completed = self.dash("--new-access")
        self.assertEqual(completed.returncode, 0, completed.stdout[-2000:] + completed.stderr[-2000:])
        renewed = self.password_from(completed)
        self.assertFalse(self.login_file.exists())
        self.assertEqual(self.sign_in(renewed)[0], 200)
        self.assertEqual(self.sign_in(link["dash_pass"])[0], 401)
        self.assertNotIn(renewed.encode(), self.everything_on_disk())

    def test_a_key_that_was_already_there_before_the_old_setup_is_still_there_after(self) -> None:
        # Open WebUI, a cron provider or another client may use it: the old setup
        # reuses a strong key it finds, so the key is not proof of anything it added.
        key = "preexisting-" + "k" * 40
        self.hermes.mkdir(exist_ok=True)
        (self.hermes / ".env").write_text("OPEN_WEBUI=1\nAPI_SERVER_KEY=" + key + "\nOTHER=2\n", encoding="utf-8")
        link = self.old_setup()
        self.assertEqual(link["token"], key)
        runner = self.services / "hermes-gateway.sh"
        self.assertIn("API_SERVER_HOST", runner.read_text())
        self.assertIn("API_SERVER_PORT", runner.read_text())
        env_before = (self.hermes / ".env").read_bytes()
        self.assertIn(("API_SERVER_KEY=" + key).encode(), env_before)

        completed = self.retire()
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertEqual((self.hermes / ".env").read_bytes(), env_before)
        text = runner.read_text()
        self.assertNotIn("API_SERVER_HOST", text)
        self.assertNotIn("API_SERVER_PORT", text)
        self.assertNotIn("API_SERVER_HOST", (self.hermes / ".env").read_text())
        self.assertFalse((self.services / "pairing.env").exists())
        self.assertFalse((self.hermes / "backups" / "gateway-exposure").exists())
        # The running Gateway still answers to that key, and a restart would find it.
        self.assertEqual(rig.http("GET", self.gateway + "/api/sessions", bearer=key)[0], 200)

    def test_the_key_goes_only_when_asked_and_a_private_copy_stays(self) -> None:
        link = self.old_setup()
        key_line = next(line for line in (self.hermes / ".env").read_text().splitlines()
                        if line.startswith("API_SERVER_KEY="))
        (self.hermes / ".env").write_text("BEFORE=1\n" + key_line + "\nAFTER=2\n", encoding="utf-8")
        completed = self.retire("--also-remove-api-key")
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        env = (self.hermes / ".env").read_text()
        self.assertNotIn("API_SERVER_KEY", env)
        self.assertEqual(env, "BEFORE=1\nAFTER=2\n")
        for gone in ("API_SERVER_HOST", "API_SERVER_PORT"):
            self.assertNotIn(gone, (self.services / "hermes-gateway.sh").read_text())
        self.assertFalse((self.services / "pairing.env").exists())
        backups = list((self.hermes / "backups" / "gateway-exposure").glob("*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), key_line + "\n")
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)
        # It says what this costs.
        self.assertIn("WARNING", completed.stdout)
        self.assertIn("does not start its API server", completed.stdout)
        self.assertIn("stops working", completed.stdout)
        self.assertNotIn(key_line.split("=", 1)[1], completed.stdout + completed.stderr)
        self.assertEqual(rig.http("GET", self.gateway + "/api/sessions", bearer=link["token"])[0], 200)

    def test_the_key_can_be_removed_in_a_second_step_after_the_default_retire(self) -> None:
        self.old_setup()
        first = self.retire()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertIn("API_SERVER_KEY=", (self.hermes / ".env").read_text())
        plain = self.retire()
        self.assertIn("Nothing to do", plain.stdout)
        self.assertIn("API_SERVER_KEY=", (self.hermes / ".env").read_text())
        second = self.retire("--also-remove-api-key")
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertNotIn("API_SERVER_KEY", (self.hermes / ".env").read_text())
        self.assertEqual(len(list((self.hermes / "backups" / "gateway-exposure").glob("*"))), 1)
        again = self.retire("--also-remove-api-key")
        self.assertIn("Nothing to do", again.stdout)

    def test_a_key_without_the_old_setup_record_is_not_ours_and_stays(self) -> None:
        self.hermes.mkdir(exist_ok=True)
        (self.hermes / ".env").write_text("API_SERVER_KEY=" + "k" * 40 + "\nOTHER=1\n", encoding="utf-8")
        before = tree(self.home)
        completed = self.retire()
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("Nothing to do", completed.stdout)
        self.assertEqual(tree(self.home), before)

    def test_without_any_trace_nothing_is_created(self) -> None:
        shutil.rmtree(self.hermes)
        completed = self.retire()
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("Nothing to do", completed.stdout)
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertEqual(list(self.runtime.iterdir()), [])

    def test_the_systemd_drop_in_goes_and_the_gateway_is_never_stopped(self) -> None:
        self.use_systemd()
        dropin_dir = self.home / ".config" / "systemd" / "user" / "hermes-gateway.service.d"
        dropin_dir.mkdir(parents=True)
        dropin = dropin_dir / "10-hermes-console-network.conf"
        dropin.write_text('[Service]\nEnvironment="API_SERVER_HOST=0.0.0.0"\nEnvironment="API_SERVER_PORT=8642"\n')
        other = dropin_dir / "20-mine.conf"
        other.write_text("[Service]\nRestart=always\n")
        unit = dropin_dir.parent / "hermes-gateway.service"
        unit.write_text("[Unit]\nDescription=Hermes Gateway\n")
        completed = self.retire()
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertFalse(dropin.exists())
        self.assertEqual(other.read_text(), "[Service]\nRestart=always\n")
        self.assertEqual(unit.read_text(), "[Unit]\nDescription=Hermes Gateway\n")
        for call in self.log("systemctl").splitlines():
            if call.startswith(("--user show-environment", "--user show ")):
                continue
            self.assertEqual(call, "--user daemon-reload", call)

    def test_a_drop_in_with_settings_of_its_own_keeps_them(self) -> None:
        self.use_systemd()
        dropin_dir = self.home / ".config" / "systemd" / "user" / "hermes-gateway.service.d"
        dropin_dir.mkdir(parents=True)
        dropin = dropin_dir / "10-hermes-console-network.conf"
        dropin.write_text('[Service]\nEnvironment="API_SERVER_HOST=0.0.0.0"\nEnvironment="TZ=UTC"\n'
                          'Environment="API_SERVER_PORT=8642"\n')
        completed = self.retire()
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertEqual(dropin.read_text(), '[Service]\nEnvironment="TZ=UTC"\n')

    def test_a_drop_in_that_is_a_symbolic_link_is_refused_whole(self) -> None:
        dropin_dir = self.home / ".config" / "systemd" / "user" / "hermes-gateway.service.d"
        dropin_dir.mkdir(parents=True)
        target = self.temp / "elsewhere.conf"
        target.write_text('[Service]\nEnvironment="API_SERVER_HOST=0.0.0.0"\n')
        (dropin_dir / "10-hermes-console-network.conf").symlink_to(target)
        before = tree(self.home)
        completed = self.retire()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("symbolic link", completed.stderr)
        self.assertEqual(tree(self.home), before)
        self.assertEqual(target.read_text(), '[Service]\nEnvironment="API_SERVER_HOST=0.0.0.0"\n')

    def test_setup_over_an_old_install_moves_the_dashboard_and_leaves_the_gateway_running(self) -> None:
        link = self.old_setup()
        old_password = link["dash_pass"]
        gateway_pid = (self.services / "gateway.pid").read_text()
        runner_before = (self.services / "hermes-gateway.sh").read_bytes()
        helper_before = (self.services / "service-manager.sh").read_bytes()
        # The old dashboard listens on every address; setup narrows it to one.
        self.assertFalse(self.refused(host="127.0.0.1") and False)
        completed = self.dash()
        self.assertEqual(completed.returncode, 0, completed.stdout[-3000:] + completed.stderr[-3000:])
        self.assertIn("kept as it is", completed.stdout)
        self.assertNotIn("  password:", completed.stdout)
        self.assertEqual(self.sign_in(old_password)[0], 200)
        self.assertIn(f'--host "{self.host}"', (self.services / "hermes-dashboard.sh").read_text())
        self.assertTrue(self.refused(host="127.0.0.1"))
        # The Gateway is the user's: same process, same runner, same key.
        self.assertEqual((self.services / "gateway.pid").read_text(), gateway_pid)
        self.assertEqual((self.services / "hermes-gateway.sh").read_bytes(), runner_before)
        self.assertEqual((self.services / "service-manager.sh").read_bytes(), helper_before)
        self.assertEqual(rig.http("GET", self.gateway + "/api/sessions", bearer=link["token"])[0], 200)


@unittest.skipUnless(LINUX, "drives the Linux managers")
class RetireBridgeStillWorks(units.RetireBridgeTests):
    """The bridge cleanup of the old script, word for word, through the new one."""

    def setUp(self) -> None:
        super().setUp()
        previous = units.SETUP
        units.SETUP = SCRIPT
        self.addCleanup(setattr, units, "SETUP", previous)


@unittest.skipUnless(LINUX, "drives the Linux managers")
class OldScriptContrast(unittest.TestCase):
    """What this suite would say about the script it complements."""

    def test_the_old_script_is_unchanged_in_what_it_exposes(self) -> None:
        source = OLD_SETUP.read_text(encoding="utf-8")
        self.assertIn("API_SERVER_KEY=", source)
        self.assertIn('export API_SERVER_HOST="$BIND_HOST"', source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
