#!/usr/bin/env python3
"""Isolated Unix installer security regressions.

These tests extract narrowly scoped helpers or embedded Python from the setup
script. They never install Hermes, contact external endpoints, or invoke a real
service manager. HTTP tests use disposable loopback fixtures only.
"""

from __future__ import annotations

import pathlib
import re
import contextlib
import http.server
import json
import os
import select
import subprocess
import sys
import tempfile
import threading
import unittest


# Layout-agnostic: the canonical app keeps these under scripts/, the public
# installer repository keeps them at the root.
ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts" if (ROOT / "scripts" / "hermes-mobile-setup.sh").exists() else ROOT
SETUP = SCRIPTS / "hermes-mobile-setup.sh"
PAIR = SCRIPTS / "hermes-pair.sh"


def shell_function(source: str, name: str) -> str:
    match = re.search(
        rf"^{re.escape(name)}\(\) \{{\n.*?^\}}$", source, re.MULTILINE | re.DOTALL
    )
    if not match:
        raise AssertionError(f"function {name} not found")
    return match.group(0)


def embedded_probe(source: str) -> str:
    match = re.search(
        r'^cat > "\$PROBE" <<\'PY\'\n(.*?)\nPY$',
        source,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError("embedded service probe not found")
    return match.group(1) + "\n"


class _Server:
    def __init__(self, callback):
        self.requests = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def _dispatch(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length) if length else b""
                owner.requests.append(
                    {
                        "method": self.command,
                        "path": self.path,
                        "authorization": self.headers.get("Authorization"),
                        "cookie": self.headers.get("Cookie"),
                        "body": body,
                    }
                )
                status, headers, body = callback(self)
                encoded = json.dumps(body).encode("utf-8")
                self.send_response(status)
                for name, value in headers.items():
                    self.send_header(name, value)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
                self._dispatch()

            def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
                self._dispatch()

            def log_message(self, *_args):
                pass

        try:
            self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        except PermissionError as exc:
            raise unittest.SkipTest(
                "sandbox forbids loopback listeners required by this regression"
            ) from exc
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.httpd.server_port}"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)


@contextlib.contextmanager
def probe_file():
    source = SETUP.read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="hermes-probe-") as raw:
        path = pathlib.Path(raw) / "probe.py"
        path.write_text(embedded_probe(source), encoding="utf-8")
        yield path


def run_probe(path: pathlib.Path, kind: str, base: str, token: str = "CANARY"):
    return subprocess.run(
        [sys.executable, str(path), kind, base, token],
        text=True,
        capture_output=True,
        timeout=15,
    )


def load_probe_definitions() -> dict:
    source = embedded_probe(SETUP.read_text(encoding="utf-8"))
    prefix, separator, _main = source.rpartition("\ntry:\n")
    if not separator:
        raise AssertionError("probe main block not found")
    namespace = {"__name__": "review_probe_definitions"}
    previous = sys.argv
    sys.argv = ["probe.py", "gateway", "http://127.0.0.1:1", "CANARY"]
    try:
        exec(compile(prefix + "\n", "<embedded-probe>", "exec"), namespace)
    finally:
        sys.argv = previous
    return namespace


def embedded_python(source: str, marker: str) -> str:
    match = re.search(
        rf"<<'{re.escape(marker)}'\n(.*?)\n{re.escape(marker)}$",
        source,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f"embedded block {marker} not found")
    return match.group(1) + "\n"


class HomePathSyntaxTests(unittest.TestCase):
    def test_unrepresentable_home_paths_fail_without_creating_them(self):
        function = shell_function(SETUP.read_text(encoding="utf-8"),
                                  "canonicalize_hermes_home")
        with tempfile.TemporaryDirectory() as raw:
            for name in ('back\\slash', 'double"quote', 'dollar$name',
                         'back`tick', 'line\nbreak', 'tab\tname'):
                with self.subTest(name=name):
                    candidate = pathlib.Path(raw) / name
                    result = subprocess.run(
                        ['sh', '-c', function + '\ncanonicalize_hermes_home "$1"',
                         'fixture', str(candidate)], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(candidate.exists())
                    self.assertIn('unsupported characters', result.stderr)


class SystemdUnitTests(unittest.TestCase):
    def test_special_paths_use_directive_safe_encoding(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        function = (shell_function(source, "canonicalize_hermes_home") + "\n"
                    + shell_function(source, "install_systemd_unit"))
        with tempfile.TemporaryDirectory(prefix="hermes-u1-render-") as raw:
            temp = pathlib.Path(raw)
            home = temp / "home space-ñ-%"
            runner = home / "console services" / "hermes-dashboard.sh"
            runner.parent.mkdir(parents=True)
            runner.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            runner.chmod(0o700)
            harness = temp / "render.sh"
            harness.write_text(
                "set -eu\n"
                + function
                + '\nVP="$4"\nHH="$(canonicalize_hermes_home "$1")"\ninstall_systemd_unit dashboard "$2" "$3"\n',
                encoding="utf-8",
            )
            unit_dir = temp / "units"
            subprocess.run(
                [
                    "sh",
                    str(harness),
                    str(home),
                    str(runner),
                    str(unit_dir),
                    sys.executable,
                ],
                text=True,
                capture_output=True,
                timeout=10,
                check=True,
            )
            rendered = (unit_dir / "hermes-dashboard.service").read_text(
                encoding="utf-8"
            )
            self.assertRegex(
                rendered, re.compile(r'^ExecStart=".*%%.*"$', re.MULTILINE)
            )
            working = next(
                line for line in rendered.splitlines() if line.startswith("WorkingDirectory=")
            )
            self.assertFalse(working.startswith('WorkingDirectory="'))
            self.assertIn("\\x20", working)
            self.assertIn("%%", working)

    def test_execstart_special_paths_verify(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        function = (shell_function(source, "canonicalize_hermes_home") + "\n"
                    + shell_function(source, "install_systemd_unit"))
        with tempfile.TemporaryDirectory(prefix="hermes-u1-") as raw:
            temp = pathlib.Path(raw)
            home = temp / "home space-ñ-%"
            runner = home / "console services" / "hermes-dashboard.sh"
            runner.parent.mkdir(parents=True)
            runner.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            runner.chmod(0o700)
            unit_dir = temp / "units"
            harness = temp / "render.sh"
            harness.write_text(
                "set -eu\n"
                + function
                + '\nVP="$4"\nHH="$(canonicalize_hermes_home "$1")"\ninstall_systemd_unit dashboard "$2" "$3"\n',
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    "sh",
                    str(harness),
                    str(home),
                    str(runner),
                    str(unit_dir),
                    sys.executable,
                ],
                text=True,
                capture_output=True,
                timeout=10,
                check=True,
            )
            self.assertEqual(completed.stderr, "")
            unit = unit_dir / "hermes-dashboard.service"
            rendered = unit.read_text(encoding="utf-8")
            self.assertNotIn('WorkingDirectory="', rendered)
            self.assertIn("ExecStart=\"", rendered)
            self.assertIn("\\x20", rendered)
            self.assertIn("%%", rendered)
            verified = subprocess.run(
                ["systemd-analyze", "--user", "verify", str(unit)],
                text=True,
                capture_output=True,
                timeout=15,
            )
            if (
                verified.returncode != 0
                and verified.stderr.strip() == "SO_PASSCRED failed: Operation not permitted"
            ):
                self.skipTest(
                    "sandbox forbids systemd-analyze's SO_PASSCRED setup; "
                    "the generated unit was still passed to the real verifier"
                )
            self.assertEqual(
                verified.returncode,
                0,
                msg=f"stdout={verified.stdout}\nstderr={verified.stderr}\n{rendered}",
            )


class ProbeRedirectTests(unittest.TestCase):
    def test_redirect_handler_rejects_https_downgrade(self) -> None:
        namespace = load_probe_definitions()
        handler = namespace["NoRedirect"]()
        redirected = handler.redirect_request(
            object(),
            None,
            302,
            "Found",
            {},
            "http://other.invalid/protected",
        )
        self.assertIsNone(redirected)

    def test_authenticated_redirect_is_rejected_without_forwarding_canary(self) -> None:
        token = "AUDIT-SYNTHETIC-CANARY"

        def sink(_request):
            return 200, {}, {"object": "list", "data": []}

        with _Server(sink) as destination:
            def redirect(request):
                if request.path == "/health":
                    return 200, {}, {"status": "ok", "platform": "hermes-agent"}
                return (
                    302,
                    {"Location": destination.base + request.path},
                    {"redirect": True},
                )

            with _Server(redirect) as origin, probe_file() as probe:
                completed = run_probe(probe, "gateway", origin.base, token)

        self.assertNotEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertFalse(
            any(row["authorization"] == "Bearer " + token for row in destination.requests),
            destination.requests,
        )


class ProbeAuthenticationTests(unittest.TestCase):
    def test_negative_auth_helper_rejects_open_route_without_network(self) -> None:
        namespace = load_probe_definitions()

        class Response:
            status = 200

            def read(self, _limit):
                return b'{"object":"list","data":[]}'

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

        class OpenService:
            def open(self, _request, timeout):
                self.timeout = timeout
                return Response()

        namespace["opener"] = OpenService()
        with self.assertRaisesRegex(RuntimeError, "did not reject missing authentication"):
            namespace["assert_auth_required"]("/api/sessions")

    def test_gateway_requires_valid_token_on_protected_route(self) -> None:
        token = "VALID-SYNTHETIC-TOKEN"

        def gateway(request):
            if request.path == "/health":
                return 200, {}, {"status": "ok", "platform": "hermes-agent"}
            if request.path == "/api/sessions":
                if request.headers.get("Authorization") == "Bearer " + token:
                    return 200, {}, {"object": "list", "data": []}
                return 401, {}, {"error": "unauthorized"}
            return 404, {}, {"error": "missing"}

        with _Server(gateway) as server, probe_file() as probe:
            completed = run_probe(probe, "gateway", server.base, token)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        session_auth = [
            row["authorization"]
            for row in server.requests
            if row["path"] == "/api/sessions"
        ]
        self.assertIn("Bearer " + token, session_auth)
        self.assertIn(None, session_auth)
        self.assertTrue(any(value not in (None, "Bearer " + token) for value in session_auth))

    def test_gateway_rejects_service_that_ignores_authentication(self) -> None:
        def open_gateway(request):
            if request.path == "/health":
                return 200, {}, {"status": "ok", "platform": "hermes-agent"}
            return 200, {}, {"object": "list", "data": []}

        with _Server(open_gateway) as server, probe_file() as probe:
            completed = run_probe(probe, "gateway", server.base)

        self.assertNotEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_bridge_requires_valid_token_on_protected_route(self) -> None:
        token = "VALID-BRIDGE-TOKEN"

        def bridge(request):
            if request.path == "/bridge/health":
                return 200, {}, {"status": "ok", "version": "1.2.3"}
            if request.path == "/bridge/capabilities":
                if request.headers.get("Authorization") != "Bearer " + token:
                    return 403, {}, {"error": "unauthorized"}
                return 200, {}, {
                    "object": "hermes.bridge.capabilities",
                    "operations": {"self_update": True},
                    "scopes": ["read", "config"],
                }
            return 404, {}, {"error": "missing"}

        with _Server(bridge) as server, probe_file() as probe:
            completed = run_probe(probe, "bridge", server.base, token)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        protected = [
            row["authorization"]
            for row in server.requests
            if row["path"] == "/bridge/capabilities"
        ]
        self.assertIn("Bearer " + token, protected)
        self.assertIn(None, protected)
        self.assertTrue(any(value not in (None, "Bearer " + token) for value in protected))

    def test_dashboard_probe_only_claims_public_health(self) -> None:
        def dashboard(request):
            if request.path == "/api/status":
                return 200, {}, {"version": "1.0", "gateway_running": True}
            return 401, {}, {"error": "unauthorized"}

        with _Server(dashboard) as server, probe_file() as probe:
            completed = run_probe(probe, "dashboard", server.base)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual([row["path"] for row in server.requests], ["/api/status"])


class DashboardAuthenticationTests(unittest.TestCase):
    def test_created_password_login_accepts_cookie_and_rejects_unauthorized(self) -> None:
        username = "admin"
        password = "SYNTHETIC-PASSWORD"

        def dashboard(request):
            if request.path == "/auth/password-login" and request.command == "POST":
                return 200, {"Set-Cookie": "hermes_session_at=AT1; Path=/; HttpOnly"}, {"ok": True}
            if request.path == "/api/model/options":
                if request.headers.get("Cookie") == "hermes_session_at=AT1":
                    return 200, {}, {"providers": []}
                return 401, {}, {"error": "unauthorized"}
            return 404, {}, {"error": "missing"}

        source = SETUP.read_text(encoding="utf-8")
        verifier = embedded_python(source, "PY_DASH_AUTH")
        with tempfile.TemporaryDirectory(prefix="hermes-dashboard-auth-") as raw:
            script = pathlib.Path(raw) / "dashboard-auth.py"
            script.write_text(verifier, encoding="utf-8")
            with _Server(dashboard) as server:
                completed = subprocess.run(
                    [
                        sys.executable,
                        str(script),
                        server.base,
                        "1",
                        username,
                        password,
                    ],
                    text=True,
                    capture_output=True,
                    timeout=15,
                )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        protected = [row for row in server.requests if row["path"] == "/api/model/options"]
        self.assertEqual(len(protected), 3)
        self.assertTrue(any(row["cookie"] == "hermes_session_at=AT1" for row in protected))
        self.assertTrue(any(row["cookie"] is None for row in protected))
        self.assertTrue(any(row["cookie"] not in (None, "hermes_session_at=AT1") for row in protected))


class DeliverySyntaxTests(unittest.TestCase):
    def test_all_embedded_python_blocks_compile(self) -> None:
        setup = SETUP.read_text(encoding="utf-8")
        blocks = re.findall(r"<<'PY'\n(.*?)\nPY$", setup, re.MULTILINE | re.DOTALL)
        blocks.append(embedded_python(setup, "PY_DASH_AUTH"))
        self.assertGreaterEqual(len(blocks), 10)
        for index, block in enumerate(blocks):
            with self.subTest(block=index):
                compile(block, f"<embedded-{index}>", "exec")

    def test_exact_file_and_stdin_bytes_parse_in_sh_dash_and_bash(self) -> None:
        payload = SETUP.read_bytes()
        for shell in ("sh", "dash", "bash"):
            with self.subTest(shell=shell, delivery="file"):
                parsed = subprocess.run(
                    [shell, "-n", str(SETUP)],
                    text=False,
                    capture_output=True,
                    timeout=10,
                )
                self.assertEqual(parsed.returncode, 0, parsed.stderr.decode(errors="replace"))
            with self.subTest(shell=shell, delivery="stdin"):
                parsed = subprocess.run(
                    [shell, "-n"],
                    input=payload,
                    text=False,
                    capture_output=True,
                    timeout=10,
                )
                self.assertEqual(parsed.returncode, 0, parsed.stderr.decode(errors="replace"))

    def test_pairing_has_no_install_or_repair_side_effect_path(self) -> None:
        pair = PAIR.read_text(encoding="utf-8")
        self.assertNotRegex(pair, r"\bpip\s+install\b")
        self.assertNotIn("uv run --with", pair)
        repair_lines = [
            line.strip()
            for line in pair.splitlines()
            if "hermes-mobile-setup.sh | sh" in line
        ]
        self.assertTrue(repair_lines)
        self.assertTrue(all(line.startswith("echo ") for line in repair_lines))

    def test_pairing_missing_verified_record_does_not_mutate_home(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hermes-pair-readonly-") as raw:
            home = pathlib.Path(raw) / "home"
            hermes = home / ".hermes"
            hermes.mkdir(parents=True)
            (hermes / ".env").write_text(
                "API_SERVER_KEY=SYNTHETIC-NOT-A-SECRET\n", encoding="utf-8"
            )
            before = sorted(
                (path.relative_to(home), path.read_bytes() if path.is_file() else None)
                for path in home.rglob("*")
            )
            completed = subprocess.run(
                ["sh", str(PAIR)],
                text=True,
                input="",
                capture_output=True,
                timeout=5,
                env={**os.environ, "HOME": str(home)},
            )
            after = sorted(
                (path.relative_to(home), path.read_bytes() if path.is_file() else None)
                for path in home.rglob("*")
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(after, before)
            self.assertNotIn("SYNTHETIC-NOT-A-SECRET", completed.stdout + completed.stderr)

    def test_portable_helper_never_uses_command_substring_kills(self) -> None:
        setup = SETUP.read_text(encoding="utf-8")
        # El helper se escribe como datos (heredoc citado) y se sustituye despues:
        # un heredoc sin citar con otro dentro y parentesis sin compensar rompe el
        # parser de bash 3.2 (/bin/sh de macOS).
        helper = re.search(
            r"""^cat > "\$HELPER" <<'HELPER_EOF'\n(.*?)\nHELPER_EOF$""",
            setup,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(helper)
        body = helper.group(1)
        self.assertNotIn("ps -p", body)
        self.assertNotIn("pkill", body)
        self.assertIn("pidfd_send_signal", body)

    def test_portable_helper_exact_heredoc_renders_valid_shell(self) -> None:
        setup = SETUP.read_text(encoding="utf-8")
        # El bloque incluye el paso de sustitucion; el helper contiene a su vez
        # heredocs 'PY', asi que el ancla es la ultima linea de la sustitucion.
        statement = re.search(
            r"""^cat > "\$HELPER" <<'HELPER_EOF'\n.*?write_text\(text, encoding="utf-8"\)\nPY$""",
            setup,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(statement)
        with tempfile.TemporaryDirectory(prefix="hermes-helper-syntax-") as raw:
            temp = pathlib.Path(raw)
            helper = temp / "service-manager.sh"
            harness = temp / "render.sh"
            variables = {
                "HELPER": helper,
                "SERVICES": temp / "services space",
                "LOGS": temp / "logs space",
                "GATEWAY_RUNNER": temp / "gateway runner",
                "DASHBOARD_RUNNER": temp / "dashboard runner",
                "BRIDGE_RUNNER": temp / "bridge runner",
                "VP": pathlib.Path(sys.executable),
                "HB": temp / "hermes launcher",
            }
            assignments = "".join(
                f"{name}='{value}'\n" for name, value in variables.items()
            )
            harness.write_text(
                "#!/bin/sh\nset -eu\n"
                + assignments
                + statement.group(0)
                + '\nsh -n "$HELPER"\ndash -n "$HELPER"\nbash -n "$HELPER"\n',
                encoding="utf-8",
            )
            completed = subprocess.run(
                ["sh", str(harness)],
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            # La sustitucion explicita debe dejar el helper real, sin marcadores.
            rendered = helper.read_text(encoding="utf-8")
            self.assertNotIn("__VP__", rendered)
            self.assertNotIn("__SERVICES__", rendered)
            self.assertIn(str(temp / "services space"), rendered)


class SetupLockTests(unittest.TestCase):
    def test_two_real_processes_contend_before_either_home_is_written(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        functions = "\n".join(
            shell_function(source, name)
            for name in ("acquire_setup_lock", "release_setup_lock")
        )
        with tempfile.TemporaryDirectory(prefix="hermes-u5-lock-") as raw:
            temp = pathlib.Path(raw)
            lock_root = temp / "runtime"
            mock_bin = temp / "mock-bin"
            lock_root.mkdir()
            mock_bin.mkdir()
            mock_systemctl = mock_bin / "systemctl"
            mock_systemctl.write_text(
                "#!/bin/sh\n# mock service manager: intentionally no real service calls\nexit 0\n",
                encoding="utf-8",
            )
            mock_systemctl.chmod(0o700)
            harness = temp / "lock.sh"
            harness.write_text(
                "#!/bin/sh\nset -eu\n"
                + functions
                + "\nXDG_RUNTIME_DIR=$1\nHH=$2\nSERVICE_MANAGER=mock\n"
                + "acquire_setup_lock\nprintf 'LOCKED\\n'\n"
                + "IFS= read -r release\nrelease_setup_lock\n",
                encoding="utf-8",
            )
            harness.chmod(0o700)
            first_home = temp / "selected-home-one"
            second_home = temp / "selected-home-two"
            env = {**os.environ, "PATH": str(mock_bin) + os.pathsep + os.environ["PATH"]}
            holder = subprocess.Popen(
                ["sh", str(harness), str(lock_root), str(first_home)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
            )
            try:
                ready, _, _ = select.select([holder.stdout], [], [], 5)
                self.assertTrue(ready, "lock holder did not become ready within 5 seconds")
                self.assertEqual(holder.stdout.readline(), "LOCKED\n")
                contender = subprocess.run(
                    ["sh", str(harness), str(lock_root), str(second_home)],
                    input="release\n",
                    text=True,
                    capture_output=True,
                    timeout=5,
                    env=env,
                )
                self.assertNotEqual(contender.returncode, 0)
                self.assertIn("already running", contender.stderr)
                self.assertFalse(first_home.exists())
                self.assertFalse(second_home.exists())
            finally:
                if holder.stdin:
                    try:
                        holder.stdin.write("release\n")
                        holder.stdin.flush()
                    except BrokenPipeError:
                        pass
                try:
                    holder.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    holder.terminate()
                    holder.communicate(timeout=5)

    def test_ambiguous_default_home_rejects_custom_home_without_writing_it(self) -> None:
        with tempfile.TemporaryDirectory(prefix="hermes-u5-home-") as raw:
            temp = pathlib.Path(raw)
            user_home = temp / "user"
            default_home = user_home / ".hermes"
            selected = temp / "selected"
            default_home.mkdir(parents=True)
            (default_home / ".env").write_text("fixture\n", encoding="utf-8")
            runtime = temp / "runtime"
            runtime.mkdir()
            completed = subprocess.run(
                ["sh", str(SETUP)],
                text=True,
                input="",
                capture_output=True,
                timeout=5,
                env={
                    **os.environ,
                    "HOME": str(user_home),
                    "HERMES_HOME": str(selected),
                    "XDG_RUNTIME_DIR": str(runtime),
                },
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("ambiguous migration", completed.stderr)
            self.assertFalse(selected.exists())


class SystemdOwnershipTests(unittest.TestCase):
    def test_effective_exec_and_dropins_must_belong_to_selected_home(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        functions = "\n".join(
            shell_function(source, name)
            for name in ("ownership_python", "assert_systemd_unit_owner")
        )
        with tempfile.TemporaryDirectory(prefix="hermes-u5-systemd-") as raw:
            temp = pathlib.Path(raw)
            home = temp / "user"
            selected = temp / "selected home"
            unit_dir = home / ".config" / "systemd" / "user"
            dropin_dir = unit_dir / "hermes-dashboard.service.d"
            runner = selected / "console-services" / "hermes-dashboard.sh"
            runner.parent.mkdir(parents=True)
            gateway_python = selected / "hermes-agent" / "venv" / "bin" / "python"
            gateway_python.parent.mkdir(parents=True)
            gateway_python.symlink_to(pathlib.Path(sys.executable).resolve())
            dropin_dir.mkdir(parents=True)
            unit = unit_dir / "hermes-dashboard.service"
            unit.write_text("[Service]\n", encoding="utf-8")
            owned_dropin = dropin_dir / "10-owned.conf"
            owned_dropin.write_text("[Service]\n", encoding="utf-8")
            mock_bin = temp / "mock-bin"
            mock_bin.mkdir()
            mock_systemctl = mock_bin / "systemctl"
            mock_systemctl.write_text(
                """#!/bin/sh
case "$MOCK_SYSTEMD_MODE" in
  owned) exec_path="$SELECTED_HOME/console-services/hermes-dashboard.sh"; dropin="$EXPECTED_DROPIN" ;;
  canonical-gateway) exec_path="$SELECTED_HOME/hermes-agent/venv/bin/python"; dropin="$EXPECTED_DROPIN" ;;
  foreign-exec) exec_path="$FOREIGN_HOME/run"; dropin="$EXPECTED_DROPIN" ;;
  foreign-dropin) exec_path="$SELECTED_HOME/console-services/hermes-dashboard.sh"; dropin="$FOREIGN_HOME/override.conf" ;;
  foreign-stop) exec_path="$SELECTED_HOME/console-services/hermes-dashboard.sh"; dropin="$EXPECTED_DROPIN" ;;
  foreign-reload) exec_path="$SELECTED_HOME/console-services/hermes-dashboard.sh"; dropin="$EXPECTED_DROPIN" ;;
  *) exit 2 ;;
esac
printf 'LoadState=loaded\\n'
printf 'FragmentPath=%s\\n' "$EXPECTED_FRAGMENT"
printf 'DropInPaths=%s\\n' "$dropin"
printf 'WorkingDirectory=%s\\n' "$SELECTED_HOME"
printf 'ExecStart={ path=%s ; argv[]=%s ; ignore_errors=no ; }\\n' "$exec_path" "$exec_path"
[ "$MOCK_SYSTEMD_MODE" != canonical-gateway ] || {
  printf 'ExecReload={ path=/bin/kill ; argv[]=/bin/kill -USR1 $MAINPID ; }\\n'
  printf 'ExecStopPost={ path=%s/hermes-agent/venv/bin/python ; argv[]=%s/hermes-agent/venv/bin/python -m gateway.cgroup_cleanup ; }\\n' "$SELECTED_HOME" "$SELECTED_HOME"
}
[ "$MOCK_SYSTEMD_MODE" != foreign-stop ] || printf 'ExecStop={ path=%s/stop ; argv[]=%s/stop ; }\\n' "$FOREIGN_HOME" "$FOREIGN_HOME"
[ "$MOCK_SYSTEMD_MODE" != foreign-reload ] || printf 'ExecReload={ path=%s/reload ; argv[]=%s/reload ; }\\n' "$FOREIGN_HOME" "$FOREIGN_HOME"
""",
                encoding="utf-8",
            )
            mock_systemctl.chmod(0o700)
            harness = temp / "owner.sh"
            harness.write_text(
                "#!/bin/sh\nset -eu\n"
                + functions
                + '\nHOME=$1\nHH=$2\nassert_systemd_unit_owner hermes-dashboard.service\n',
                encoding="utf-8",
            )
            harness.chmod(0o700)
            env = {
                **os.environ,
                "PATH": str(mock_bin) + os.pathsep + os.environ["PATH"],
                "SELECTED_HOME": str(selected),
                "FOREIGN_HOME": str(temp / "foreign"),
                "EXPECTED_FRAGMENT": str(unit),
                "EXPECTED_DROPIN": str(owned_dropin),
            }
            for mode in ("owned", "canonical-gateway"):
                accepted = subprocess.run(
                    ["sh", str(harness), str(home), str(selected)],
                    text=True,
                    capture_output=True,
                    timeout=5,
                    env={**env, "MOCK_SYSTEMD_MODE": mode},
                )
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
            for mode in (
                "foreign-exec",
                "foreign-dropin",
                "foreign-stop",
                "foreign-reload",
            ):
                rejected = subprocess.run(
                    ["sh", str(harness), str(home), str(selected)],
                    text=True,
                    capture_output=True,
                    timeout=5,
                    env={**env, "MOCK_SYSTEMD_MODE": mode},
                )
                self.assertNotEqual(rejected.returncode, 0, mode)
                self.assertIn("refusing to replace", rejected.stderr)


class LaunchdOwnershipTests(unittest.TestCase):
    def test_loaded_job_effective_program_and_workdir_are_checked(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        functions = "\n".join(
            shell_function(source, name)
            for name in ("ownership_python", "assert_loaded_launchd_job_owner")
        )
        with tempfile.TemporaryDirectory(prefix="hermes-u5-launchd-") as raw:
            temp = pathlib.Path(raw)
            selected = temp / "selected"
            runner = selected / "console-services" / "hermes-dashboard.sh"
            runner.parent.mkdir(parents=True)
            mock_bin = temp / "mock-bin"
            mock_bin.mkdir()
            launchctl = mock_bin / "launchctl"
            launchctl.write_text(
                """#!/bin/sh
case "$MOCK_LAUNCHD_MODE" in
  owned) program="$SELECTED_RUNNER"; workdir="$SELECTED_HOME" ;;
  foreign) program="$FOREIGN_HOME/run"; workdir="$SELECTED_HOME" ;;
  absent)
    case "$2" in */dev.xpetalab.hermes-console.dashboard) exit 1 ;; esac
    printf 'services = {\\n    com.example.other = enabled\\n}\\n'
    exit 0
    ;;
  *) exit 2 ;;
esac
printf 'program = %s\\nworking directory = %s\\n' "$program" "$workdir"
""",
                encoding="utf-8",
            )
            launchctl.chmod(0o700)
            harness = temp / "loaded.sh"
            harness.write_text(
                "#!/bin/sh\nset -eu\n"
                + functions
                + "\nHH=$1\nassert_loaded_launchd_job_owner dev.xpetalab.hermes-console.dashboard\n",
                encoding="utf-8",
            )
            harness.chmod(0o700)
            env = {
                **os.environ,
                "PATH": str(mock_bin) + os.pathsep + os.environ["PATH"],
                "SELECTED_HOME": str(selected),
                "SELECTED_RUNNER": str(runner),
                "FOREIGN_HOME": str(temp / "foreign"),
            }
            for mode, expected in (("owned", 0), ("foreign", 1), ("absent", 0)):
                completed = subprocess.run(
                    ["sh", str(harness), str(selected)],
                    text=True,
                    capture_output=True,
                    timeout=5,
                    env={**env, "MOCK_LAUNCHD_MODE": mode},
                )
                self.assertEqual(completed.returncode, expected, (mode, completed.stderr))


class TransactionRollbackTests(unittest.TestCase):
    def test_late_failure_restores_scoped_files_and_systemd_state(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        names = (
            "transaction_path",
            "snapshot_transaction_file",
            "restore_transaction_file",
            "begin_transaction",
            "restore_systemd_state",
            "cleanup_transaction_backups",
            "rollback_private_firewall",
            "rollback_transaction",
        )
        functions = "\n".join(shell_function(source, name) for name in names)
        with tempfile.TemporaryDirectory(prefix="hermes-u4-") as raw:
            temp = pathlib.Path(raw)
            selected = temp / "selected"
            services = selected / "console-services"
            user_home = temp / "user"
            unit_dir = user_home / ".config" / "systemd" / "user"
            dropin_dir = unit_dir / "hermes-gateway.service.d"
            services.mkdir(parents=True)
            dropin_dir.mkdir(parents=True)
            existing = {
                selected / ".env": "old-env\n",
                selected / "bridge.env": "old-bridge-env\n",
                selected / "hermes_bridge.py": "old-bridge\n",
                services / "hermes-gateway.sh": "old-gateway-runner\n",
                services / "hermes-dashboard.sh": "old-dashboard-runner\n",
                services / "hermes-service-probe.py": "old-probe\n",
                unit_dir / "hermes-gateway.service": "old-gateway-unit\n",
                unit_dir / "hermes-dashboard.service": "old-dashboard-unit\n",
                dropin_dir / "10-hermes-console-network.conf": "old-dropin\n",
            }
            for path, value in existing.items():
                path.write_text(value, encoding="utf-8")
            absent_before = [
                services / "hermes-bridge.sh",
                services / "service-manager.sh",
                services / "pairing.env",
                unit_dir / "hermes-bridge.service",
            ]
            mock_bin = temp / "mock-bin"
            mock_bin.mkdir()
            systemctl_log = temp / "mock-systemctl.log"
            mock_systemctl = mock_bin / "systemctl"
            mock_systemctl.write_text(
                """#!/bin/sh
# mock service manager: report gateway active/enabled, all others inactive/disabled.
printf '%s\\n' "$*" >> "$MOCK_SYSTEMCTL_LOG"
case "$*" in
  *'is-active --quiet hermes-gateway') exit 0 ;;
  *'is-enabled --quiet hermes-gateway') exit 0 ;;
  *'is-active --quiet '*|*'is-enabled --quiet '*) exit 1 ;;
  *) exit 0 ;;
esac
""",
                encoding="utf-8",
            )
            mock_systemctl.chmod(0o700)
            harness = temp / "rollback.sh"
            harness.write_text(
                "#!/bin/sh\nset -eu\n"
                + functions
                + "\nHOME=$1\nHH=$2\nSERVICES=$HH/console-services\n"
                + "PROBE=$SERVICES/hermes-service-probe.py\nPAIR_ENV=$SERVICES/pairing.env\n"
                + "TARGET=$HH/hermes_bridge.py\nBACKUP=$TARGET.rollback\nENV_FILE=$HH/bridge.env\n"
                + "GATEWAY_RUNNER=$SERVICES/hermes-gateway.sh\n"
                + "DASHBOARD_RUNNER=$SERVICES/hermes-dashboard.sh\n"
                + "BRIDGE_RUNNER=$SERVICES/hermes-bridge.sh\nHELPER=$SERVICES/service-manager.sh\n"
                + "SERVICE_MANAGER=systemd\nSERVICE_LIFECYCLE_TOUCHED=0\n"
                + "begin_transaction\nSERVICE_LIFECYCLE_TOUCHED=1\n"
                + "for path in \"$HH/.env\" \"$HH/bridge.env\" \"$TARGET\" \"$PROBE\" "
                + "\"$GATEWAY_RUNNER\" \"$DASHBOARD_RUNNER\" \"$BRIDGE_RUNNER\" "
                + "\"$HELPER\" \"$PAIR_ENV\" "
                + "\"$HOME/.config/systemd/user/hermes-gateway.service\" "
                + "\"$HOME/.config/systemd/user/hermes-dashboard.service\" "
                + "\"$HOME/.config/systemd/user/hermes-bridge.service\" "
                + "\"$HOME/.config/systemd/user/hermes-gateway.service.d/10-hermes-console-network.conf\"; do "
                + "mkdir -p \"$(dirname -- \"$path\")\"; printf 'new\\n' > \"$path\"; done\n"
                + "rollback_transaction\n",
                encoding="utf-8",
            )
            harness.chmod(0o700)
            completed = subprocess.run(
                ["sh", str(harness), str(user_home), str(selected)],
                text=True,
                capture_output=True,
                timeout=10,
                env={
                    **os.environ,
                    "PATH": str(mock_bin) + os.pathsep + os.environ["PATH"],
                    "MOCK_SYSTEMCTL_LOG": str(systemctl_log),
                },
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            for path, value in existing.items():
                self.assertEqual(path.read_text(encoding="utf-8"), value, str(path))
            for path in absent_before:
                self.assertFalse(path.exists(), str(path))
            calls = systemctl_log.read_text(encoding="utf-8")
            self.assertIn("daemon-reload", calls)
            self.assertIn("restart hermes-gateway", calls)
            self.assertIn("stop hermes-dashboard", calls)
            self.assertIn("disable hermes-dashboard", calls)

    def test_incomplete_rollback_keeps_recovery_data(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        names = (
            "transaction_path",
            "restore_transaction_file",
            "restore_systemd_state",
            "cleanup_transaction_backups",
            "rollback_private_firewall",
            "rollback_transaction",
        )
        functions = "\n".join(shell_function(source, name) for name in names)
        with tempfile.TemporaryDirectory(prefix="hermes-u4-incomplete-") as raw:
            temp = pathlib.Path(raw)
            transaction = temp / "transaction"
            transaction.mkdir()
            harness = temp / "rollback-incomplete.sh"
            harness.write_text(
                "#!/bin/sh\nset -eu\n"
                + functions
                + "\nHOME=$1\nHH=$1/.hermes\nTRANSACTION_DIR=$2\n"
                + "TRANSACTION_KEYS=env\nTRANSACTION_PENDING=1\n"
                + "SERVICE_LIFECYCLE_TOUCHED=0\nSERVICE_MANAGER=portable\n"
                + "rollback_transaction\n[ -d \"$TRANSACTION_DIR\" ]\n",
                encoding="utf-8",
            )
            harness.chmod(0o700)
            completed = subprocess.run(
                ["sh", str(harness), str(temp), str(transaction)],
                text=True,
                capture_output=True,
                timeout=5,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("rollback was incomplete", completed.stderr)
            self.assertTrue(transaction.exists())


class InstallerHygieneTests(unittest.TestCase):
    def test_never_spawns_gui_or_viewer_commands(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        banned = re.compile(
            r"^\s*(?:open|xdg-open|osascript|notify-send|zenity|kdialog)\b",
            re.MULTILINE,
        )
        self.assertIsNone(banned.search(source))

    def test_qr_renderer_is_isolated_pinned_and_cacheless(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        self.assertNotIn("-m pip install", source)
        self.assertIn(
            "run --isolated --no-project --no-cache --with qrcode==8.2",
            source,
        )

    def test_transaction_commits_only_after_pairing_finishes(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        qr = source.index("QRPY=")
        commit = source.rindex("commit_transaction")
        self.assertGreater(commit, qr)

    def test_fresh_agent_failure_is_clean_and_broken_tree_is_fail_closed(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        self.assertIn("refusing to run the installer over it", source)
        self.assertIn('[ -e "$AGENT_DIR" ] || [ -L "$AGENT_DIR" ]', source)
        self.assertIn('cleanup_fresh_agent_attempt', source)
        self.assertIn('rm -rf -- "$AGENT_DIR" "$HH/node"', source)
        self.assertIn('rm -f -- "$HH/bin/hermes" "$HH/bin/uv" "$HH/bin/uvx"', source)
        self.assertIn("UV_NO_CACHE=1 bash -s --", source)
        self.assertIn("--skip-browser --skip-computer-use", source)

    def test_attempt_created_firewall_rules_are_rolled_back(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        rollback = shell_function(source, "rollback_private_firewall")
        with tempfile.TemporaryDirectory(prefix="hermes-firewall-rollback-") as raw:
            temp = pathlib.Path(raw)
            (temp / "ufw.added").write_text("8642\n", encoding="utf-8")
            rule = (
                "rule family=ipv4 source address=192.168.10.0/24 "
                "port port=9131 protocol=tcp accept"
            )
            (temp / "firewalld.added").write_text(rule + "\n", encoding="utf-8")
            harness = temp / "rollback.sh"
            harness.write_text(
                "#!/bin/sh\nset -eu\n"
                + rollback
                + "\nTRANSACTION_DIR=$1\nCOMMANDS=$2\nFIREWALL_SOURCE=192.168.10.0/24\n"
                + "run_privileged() { printf '%s\\n' \"$*\" >> \"$COMMANDS\"; }\n"
                + "rollback_private_firewall\n",
                encoding="utf-8",
            )
            harness.chmod(0o700)
            command_log = temp / "commands.log"
            completed = subprocess.run(
                ["sh", str(harness), str(temp), str(command_log)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            commands = command_log.read_text(encoding="utf-8")
            self.assertIn(
                "ufw --force delete allow from 192.168.10.0/24 to any port 8642 proto tcp",
                commands,
            )
            self.assertIn("--remove-rich-rule=" + rule, commands)



class ServicePortTests(unittest.TestCase):
    """Los puertos dejan de estar fijos: se resuelven del entorno, se rechaza una
    colision y ningun consumidor (unidades, runners, firewall, probes) los repite."""

    def setUp(self) -> None:
        self.source = SETUP.read_text(encoding="utf-8")

    def test_ports_are_resolved_with_documented_defaults(self) -> None:
        for variable, name, default in (
            ("GATEWAY_PORT", "HERMES_GATEWAY_PORT", "8642"),
            ("DASHBOARD_PORT", "HERMES_DASHBOARD_PORT", "9119"),
            ("BRIDGE_PORT", "HERMES_BRIDGE_PORT", "9131"),
        ):
            with self.subTest(port=name):
                self.assertIn(f'{variable}="${{{name}:-{default}}}"', self.source)

    def _port_block(self) -> str:
        """El bloque de resolucion de puertos, aislado de la instalacion."""
        start = self.source.index('GATEWAY_PORT="${HERMES_GATEWAY_PORT:-8642}"')
        end = self.source.index('PAIR_SCHEME="${HERMES_PAIR_SCHEME:-http}"', start)
        return self.source[start:end]

    def _run_ports(self, overrides: dict) -> subprocess.CompletedProcess:
        environment = dict(os.environ)
        for key in ("HERMES_GATEWAY_PORT", "HERMES_DASHBOARD_PORT", "HERMES_BRIDGE_PORT"):
            environment.pop(key, None)
        environment.update(overrides)
        return subprocess.run(
            ["sh", "-c", "set -eu\n" + self._port_block() + "\necho RESOLVED\n"],
            capture_output=True, text=True, env=environment,
        )

    def test_the_port_block_is_resolved_at_the_top_level(self) -> None:
        # Si el bloque se colgara de alguna funcion, el rechazo llegaria tarde.
        for line in self._port_block().splitlines():
            if line.startswith("GATEWAY_PORT=") or line.startswith("DASHBOARD_PORT=") \
                    or line.startswith("BRIDGE_PORT="):
                self.assertFalse(line.startswith(" "), f"no es de nivel superior: {line}")
        self.assertLess(self.source.index("GATEWAY_PORT="), self.source.index("PAIR_SCHEME="))

    def test_a_port_collision_is_refused_without_resolving(self) -> None:
        result = self._run_ports({"HERMES_GATEWAY_PORT": "9119"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be three different ports", result.stdout + result.stderr)
        self.assertNotIn("RESOLVED", result.stdout)

    def test_invalid_and_out_of_range_ports_are_refused(self) -> None:
        for override, expected in (
            ({"HERMES_GATEWAY_PORT": "abc"}, "must be TCP ports"),
            ({"HERMES_GATEWAY_PORT": "0"}, "out of range"),
            ({"HERMES_DASHBOARD_PORT": "70000"}, "out of range"),
            ({"HERMES_BRIDGE_PORT": "9131.5"}, "must be TCP ports"),
        ):
            with self.subTest(override=override):
                result = self._run_ports(override)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stdout + result.stderr)
                self.assertNotIn("RESOLVED", result.stdout)

    def test_valid_overrides_resolve_without_touching_the_host(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            before = sorted(os.listdir(raw))
            result = self._run_ports({
                "HERMES_GATEWAY_PORT": "18642",
                "HERMES_DASHBOARD_PORT": "19119",
                "HERMES_BRIDGE_PORT": "19131",
            })
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("RESOLVED", result.stdout)
            self.assertEqual(before, sorted(os.listdir(raw)))
            self.assertTrue(os.path.isdir(raw))

if __name__ == "__main__":
    unittest.main(verbosity=2)
