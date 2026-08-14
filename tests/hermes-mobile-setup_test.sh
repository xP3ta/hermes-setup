#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
SCRIPT="$ROOT/hermes-mobile-setup.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

sh -n "$SCRIPT"
grep -F 'loginctl show-user "$LINGER_USER"' "$SCRIPT" >/dev/null || \
  fail "linger state is not checked first"
grep -F 'sudo -n loginctl enable-linger "$LINGER_USER"' "$SCRIPT" >/dev/null || \
  fail "linger is not restricted to non-interactive sudo"
if grep -F '&& loginctl enable-linger "$(id -un)"' "$SCRIPT" >/dev/null; then
  fail "installer can still trigger interactive PolicyKit authorization"
fi
grep -F 'systemd-analyze --user verify' "$SCRIPT" >/dev/null || \
  fail "generated user units are not verified"
grep -F 'ExecStart=$runner' "$SCRIPT" >/dev/null || \
  fail "ExecStart is not emitted in the Debian-compatible form"
grep -F 'WorkingDirectory=$HH' "$SCRIPT" >/dev/null || \
  fail "WorkingDirectory is not emitted in the Debian-compatible form"

TMP="$(mktemp -d)"
cleanup() {
  rm -f \
    "$TMP/install-systemd-unit.sh" \
    "$TMP/home/.hermes/console-services/hermes-gateway.sh" \
    "$TMP/home/.hermes/console-services/hermes-dashboard.sh" \
    "$TMP/home/.hermes/console-services/hermes-bridge.sh" \
    "$TMP/units/hermes-gateway.service" \
    "$TMP/units/hermes-dashboard.service" \
    "$TMP/units/hermes-bridge.service"
  rmdir "$TMP/home/.hermes/console-services" 2>/dev/null || true
  rmdir "$TMP/home/.hermes" 2>/dev/null || true
  rmdir "$TMP/home" 2>/dev/null || true
  rmdir "$TMP/units" 2>/dev/null || true
  rmdir "$TMP" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

sed -n '/^install_systemd_unit() {/,/^}$/p' "$SCRIPT" > \
  "$TMP/install-systemd-unit.sh"
# shellcheck disable=SC1090
. "$TMP/install-systemd-unit.sh"

HOME="$TMP/home"
HH="$HOME/.hermes"
mkdir -p "$HH/console-services" "$TMP/units"
for name in gateway dashboard bridge; do
  runner="$HH/console-services/hermes-$name.sh"
  printf '#!/bin/sh\nexit 0\n' > "$runner"
  chmod 700 "$runner"
  install_systemd_unit "$name" "$runner" "$TMP/units"
done

for name in gateway dashboard bridge; do
  unit="$TMP/units/hermes-$name.service"
  grep -Fx "WorkingDirectory=$HH" "$unit" >/dev/null || \
    fail "$name has an invalid WorkingDirectory"
  grep -Fx "ExecStart=$HH/console-services/hermes-$name.sh" "$unit" >/dev/null || \
    fail "$name has an invalid ExecStart"
done

if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze --user verify \
    "$TMP/units/hermes-gateway.service" \
    "$TMP/units/hermes-dashboard.service" \
    "$TMP/units/hermes-bridge.service"
fi

echo "PASS: Unix installer avoids PolicyKit prompts and emits valid user units"
