#!/usr/bin/env bash
# Smoke-test the published Unix bootstrap artifact without installing anything.
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  printf 'SKIP: this smoke exercises the Linux-only WSL early-exit guard\n'
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hermes-bootstrap-unix.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

cp "$ROOT/hermes-mobile-setup.sh" "$TMP_ROOT/hermes-mobile-setup.sh"

run_and_expect_wsl_guard() {
  local mode="$1"
  local output="$TMP_ROOT/$mode.out"
  local status

  set +e
  if [[ "$mode" == file ]]; then
    HOME="$TMP_ROOT/home" HERMES_HOME="$TMP_ROOT/hermes" HERMES_PAIR_HOST= \
      WSL_INTEROP=ci-smoke sh "$TMP_ROOT/hermes-mobile-setup.sh" >"$output" 2>&1
    status=$?
  else
    cat "$TMP_ROOT/hermes-mobile-setup.sh" | \
      HOME="$TMP_ROOT/home" HERMES_HOME="$TMP_ROOT/hermes" HERMES_PAIR_HOST= \
      WSL_INTEROP=ci-smoke sh >"$output" 2>&1
    status=$?
  fi
  set -e

  [[ "$status" -eq 2 ]] || {
    printf 'FAIL: %s bootstrap exited %s, expected safe WSL exit 2\n' "$mode" "$status" >&2
    cat "$output" >&2
    exit 1
  }
  grep -F "Run the native Windows installer in PowerShell instead" "$output" >/dev/null || {
    printf 'FAIL: %s bootstrap did not reach the WSL safety guard\n' "$mode" >&2
    cat "$output" >&2
    exit 1
  }
}

run_and_expect_wsl_guard file
run_and_expect_wsl_guard memory
printf 'Unix bootstrap file/memory smoke: OK\n'
