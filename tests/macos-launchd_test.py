#!/usr/bin/env python3
"""Native macOS validation of the launchd service path.

Runs on a real macOS host (GitHub Actions macos runner). It extracts the
installer's own launchd functions from the shipped script and drives them against
the real `launchctl`, so the plist contract, the ownership guards and the job
lifecycle are exercised by the same code that ships, not by a reimplementation.

Asserted here:
  * install_launchd_job writes a mode-600 plist with the shipped label;
  * launchctl actually loads the job and the runner really executes;
  * bootout removes it;
  * a plist owned by another home is refused and left untouched.
"""
from __future__ import annotations

import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
SETUP = ROOT / "hermes-mobile-setup.sh"
LABEL = "dev.xpetalab.hermes-console.gateway"

failures: list[str] = []
checks = 0


def check(condition: bool, message: str) -> None:
    global checks
    checks += 1
    if condition:
        print(f"PASS: {message}")
    else:
        print(f"FAIL: {message}")
        failures.append(message)


def extract_function(source: str, name: str) -> str:
    """Extrae `name() { ... }` de nivel superior (cierre en columna 0)."""
    match = re.search(rf"^{re.escape(name)}\(\) \{{\n", source, re.MULTILINE)
    if not match:
        raise SystemExit(f"function {name} not found in {SETUP}")
    end = source.index("\n}\n", match.end())
    return source[match.start():end + 3]


def launchctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["launchctl", *args], capture_output=True, text=True)


def main() -> int:
    if sys.platform != "darwin":
        print("SKIP: this validation only runs on macOS")
        return 0
    uid = os.getuid()
    domain = f"gui/{uid}"
    home = pathlib.Path(os.environ["HOME"])
    plist = home / "Library" / "LaunchAgents" / f"{LABEL}.plist"
    work = pathlib.Path(tempfile.mkdtemp(prefix="hermes-launchd-"))
    hh = work / "home"
    logs = work / "logs"
    hh.mkdir()
    logs.mkdir()
    heartbeat = work / "heartbeat.txt"
    runner = work / "runner.sh"
    runner.write_text(
        "#!/bin/sh\n"
        f'echo "started $$" >> "{heartbeat}"\n'
        "while :; do sleep 1; done\n",
        encoding="utf-8",
    )
    runner.chmod(0o700)

    source = SETUP.read_text(encoding="utf-8")
    harness = work / "launchd_harness.sh"
    harness.write_text(
        "set -eu\n"
        + extract_function(source, "assert_launchd_plist_owner")
        + extract_function(source, "assert_loaded_launchd_job_owner")
        + extract_function(source, "install_launchd_job")
        + f'\nHOME="{home}"\nHH="{hh}"\nLOGS="{logs}"\nVP="$(command -v python3)"\n'
          'SERVICE_MANAGER="launchd"\n'
          'install_launchd_job "$1" "$2" "$3" "$4" "$5"\n',
        encoding="utf-8",
    )

    def install(label: str, now: str = "yes") -> subprocess.CompletedProcess:
        return subprocess.run(
            ["sh", str(harness), "gateway", label, str(runner), "yes", now],
            capture_output=True, text=True, env={**os.environ, "HOME": str(home)},
        )

    try:
        shutil.rmtree(plist, ignore_errors=True)
        result = install(LABEL)
        check(result.returncode == 0, f"install_launchd_job succeeds on real launchd ({result.stderr.strip()[:200]})")
        check(plist.exists(), "the shipped label is written under ~/Library/LaunchAgents")
        check(
            plist.exists() and stat.S_IMODE(plist.stat().st_mode) == 0o600,
            "the plist is mode 600",
        )
        plist_text = plist.read_text(encoding="utf-8") if plist.exists() else ""
        for fragment in ("ProgramArguments", "KeepAlive", "StandardOutPath", LABEL):
            check(fragment in plist_text, f"the plist carries {fragment}")

        printed = launchctl("print", f"{domain}/{LABEL}")
        check(printed.returncode == 0, "launchctl reports the job as loaded")

        deadline = time.time() + 20
        while time.time() < deadline and not heartbeat.exists():
            time.sleep(0.5)
        check(heartbeat.exists(), "the launchd job really executed the runner")
        check(
            (logs / "gateway.log").exists(),
            "the job writes to the configured StandardOutPath",
        )

        bootout = launchctl("bootout", f"{domain}/{LABEL}")
        check(bootout.returncode == 0, "launchctl bootout stops the job")
        time.sleep(1)
        check(
            launchctl("print", f"{domain}/{LABEL}").returncode != 0,
            "the job is gone after bootout",
        )

        # Guarda de propiedad: un plist con la misma etiqueta pero otro home no se
        # debe pisar.
        foreign = plist.read_text(encoding="utf-8") if plist.exists() else ""
        plist.write_text(
            foreign.replace(str(hh), "/tmp/otro-home"), encoding="utf-8"
        )
        before = plist.read_bytes()
        result = install(LABEL)
        check(result.returncode != 0, "a plist owned by another home is refused")
        check(plist.read_bytes() == before, "the refused plist is left untouched")
    finally:
        launchctl("bootout", f"{domain}/{LABEL}")
        if plist.exists():
            plist.unlink()
        shutil.rmtree(work, ignore_errors=True)

    print(f"RESULT: PASS={checks - len(failures)} FAIL={len(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
