#!/usr/bin/env python3
"""A Hermes whose command is published the way current Hermes publishes it.

Current Hermes installs no <install dir>/venv. Its command is the launcher
<install dir>/.hermes/bin/hermes, which runs the interpreter of Hermes' own
package manager (under <hermes home>/tools) and answers
`--print-runtime-command` with the exact command that starts code with Hermes'
libraries. Setup must work on that layout (a fresh install) and on the older
one with venv/bin/hermes (every other test), starting the services through the
launcher rather than a hard-coded interpreter.

The stand-in is the one of no-bridge-install_test.py; only the layout differs.
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import shlex
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SETUP = ROOT / "hermes-mobile-setup.sh"

_spec = importlib.util.spec_from_file_location(
    "no_bridge_install_test", ROOT / "tests" / "no-bridge-install_test.py"
)
rig = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rig)


class CurrentLayoutTests(rig.SetupRig):
    def setUp(self) -> None:
        super().setUp()
        agent = self.hermes / "hermes-agent"
        store = self.hermes / "tools" / "python-store"
        store.parent.mkdir(parents=True)
        (agent / "venv").rename(store)
        python = store / "bin" / "python3"
        # What the venv-based rig put in the old launcher is now the
        # implementation behind the new one.
        old = store / "bin" / "hermes"
        implementation = self.hermes / "hermes-impl.py"
        implementation.write_text(
            old.read_text(encoding="utf-8").replace(
                f"#!{store.parent.parent / 'hermes-agent' / 'venv' / 'bin' / 'python3'}", f"#!{python}"
            ),
            encoding="utf-8",
        )
        old.unlink()
        site = next((store / "lib").glob("python*/site-packages"))
        (site / "hermes_bootstrap.py").write_text("", encoding="utf-8")
        bootstrap = (
            "import os, sys, runpy; sys.path.insert(0, %r); import hermes_bootstrap; "
            "runpy.run_module('hermes_cli.main', run_name='__main__', alter_sys=True)" % str(agent)
        )
        command = json.dumps([str(python), "-I", "-c", bootstrap])
        launcher = agent / ".hermes" / "bin" / "hermes"
        launcher.parent.mkdir(parents=True)
        launcher.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "--print-runtime-command" ]; then\n'
            f"  printf '%s\\n' {shlex.quote(command)}\n"
            "  exit 0\n"
            "fi\n"
            f"exec {shlex.quote(str(python))} {shlex.quote(str(implementation))} \"$@\"\n",
            encoding="utf-8",
        )
        launcher.chmod(0o700)
        implementation.chmod(0o700)
        self.python = python
        self.launcher = launcher
        self.assertFalse((agent / "venv").exists())

    def test_a_fresh_setup_works_without_any_venv(self) -> None:
        first = self.run_script(SETUP)
        link = self.link(first)
        self.assertEqual(self.sign_in(link)[0], 200)
        self.assertEqual(rig.http("GET", self.gateway + "/api/sessions", bearer=link["token"])[0], 200)
        # The services start through the launcher, and the interpreter setup
        # recorded for later runs is the one the launcher reported.
        runner = (self.services / "hermes-gateway.sh").read_text(encoding="utf-8")
        self.assertIn(f'exec "{self.launcher}" gateway run', runner)
        self.assertIn(f"PYTHON_BIN={self.python}\n", (self.services / "pairing.env").read_text(encoding="utf-8"))
        self.assertFalse((self.hermes / "hermes-agent" / "venv").exists())
        self.assert_no_bridge()
        # Showing the code again and a repair both work on this layout too.
        self.assertEqual(self.link(self.show_code_again()), link)
        self.assertEqual(self.link(self.setup_again()), link)
        self.assertEqual(self.link(self.setup_again("--new-access"))["dashboard"], link["dashboard"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
