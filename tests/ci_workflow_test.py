#!/usr/bin/env python3
"""Static contract for the repository's minimum release CI."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


def fail(message: str) -> None:
    raise AssertionError(message)


def main() -> None:
    if not WORKFLOW.is_file():
        fail("missing .github/workflows/ci.yml")
    source = WORKFLOW.read_text(encoding="utf-8")

    required = (
        "permissions:\n  contents: read",
        "runs-on: ubuntu-24.04",
        "runs-on: windows-2022",
        'sh -n "$script"',
        'bash -n "$script"',
        "shellcheck",
        "tests/review-unix-security.py",
        "tests/sync-from-app_test.sh",
        "tests/bridge-release_test.py",
        "tests/bootstrap-unix_test.sh",
        "tests/powershell_test.ps1",
        "powershell",
        "pwsh",
    )
    for fragment in required:
        if fragment not in source:
            fail(f"workflow is missing required contract: {fragment}")

    uses = re.findall(r"(?m)^\s*-?\s*uses:\s*([^\s#]+)", source)
    if not uses:
        fail("workflow has no actions")
    for action in uses:
        if not re.fullmatch(r"[^@]+@[0-9a-f]{40}", action):
            fail(f"action is not pinned to a full commit SHA: {action}")

    if source.count("persist-credentials: false") != len(uses):
        fail("every checkout must disable persisted credentials")

    if re.search(r"(?m)^\s*(actions|checks|contents|deployments|issues|packages|pull-requests|statuses):\s*write\s*$", source):
        fail("workflow grants write permission")

    print("CI workflow contract: OK")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
