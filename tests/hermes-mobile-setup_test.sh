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
grep -F 'from hermes_cli.gateway import generate_systemd_unit' "$SCRIPT" >/dev/null || \
  fail "gateway does not use Hermes canonical unit generator"
if grep -F 'gateway install --force' "$SCRIPT" >/dev/null; then
  fail "installer can still trigger Hermes interactive linger handling"
fi
grep -F 'SYSTEMD_GATEWAY_DROPIN_DIR="$SYSTEMD_USER_DIR/hermes-gateway.service.d"' "$SCRIPT" >/dev/null || \
  fail "gateway network settings are not stored in a persistent drop-in"
grep -F 'Environment="API_SERVER_HOST=$BIND_HOST"' "$SCRIPT" >/dev/null || \
  fail "gateway bind is not persisted outside the canonical unit"
grep -F 'rollback_pending_systemd_gateway' "$SCRIPT" >/dev/null || \
  fail "gateway unit replacement has no rollback path"
if grep -F 'install_systemd_unit gateway ' "$SCRIPT" >/dev/null; then
  fail "installer still replaces Hermes canonical gateway unit"
fi
grep -F 'ExecStart=$runner' "$SCRIPT" >/dev/null || \
  fail "ExecStart is not emitted in the Debian-compatible form"
grep -F 'WorkingDirectory=$HH' "$SCRIPT" >/dev/null || \
  fail "WorkingDirectory is not emitted in the Debian-compatible form"

TMP="$(mktemp -d)"
cleanup() {
  rm -f \
    "$TMP/install-systemd-unit.sh" \
    "$TMP/systemd-gateway-functions.sh" \
    "$TMP/fake-python" \
    "$TMP/home/.hermes/console-services/hermes-dashboard.sh" \
    "$TMP/home/.hermes/console-services/hermes-bridge.sh" \
    "$TMP/units/hermes-gateway.service.d/10-hermes-console-network.conf" \
    "$TMP/units/hermes-gateway.service" \
    "$TMP/units/hermes-dashboard.service" \
    "$TMP/units/hermes-bridge.service"
  rmdir "$TMP/units/hermes-gateway.service.d" 2>/dev/null || true
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

for function_name in rollback_pending_systemd_gateway stage_gateway_systemd_unit; do
  sed -n "/^$function_name() {/,/^}$/p" "$SCRIPT" >> \
    "$TMP/systemd-gateway-functions.sh"
done
. "$TMP/systemd-gateway-functions.sh"

HOME="$TMP/home"
HH="$HOME/.hermes"
mkdir -p "$HH/console-services" "$TMP/units"
cat > "$TMP/fake-python" <<'SH'
#!/bin/sh
[ "$1" = "-" ] && [ -n "$2" ] || exit 2
cat > "$2" <<EOF
[Unit]
Description=Canonical Hermes Gateway
[Service]
Type=simple
ExecStart=/usr/bin/python3 -m hermes_cli.main gateway run
WorkingDirectory=/tmp
[Install]
WantedBy=default.target
EOF
SH
chmod 700 "$TMP/fake-python"

SYSTEMD_STAGE="$TMP/units"
VP="$TMP/fake-python"
BIND_HOST="0.0.0.0"
stage_gateway_systemd_unit
grep -F 'Description=Canonical Hermes Gateway' \
  "$TMP/units/hermes-gateway.service" >/dev/null || \
  fail "installer replaced the canonical gateway unit"
grep -Fx 'Environment="API_SERVER_HOST=0.0.0.0"' \
  "$TMP/units/hermes-gateway.service.d/10-hermes-console-network.conf" >/dev/null || \
  fail "gateway bind drop-in is invalid"
grep -Fx 'Environment="API_SERVER_PORT=8642"' \
  "$TMP/units/hermes-gateway.service.d/10-hermes-console-network.conf" >/dev/null || \
  fail "gateway port drop-in is invalid"

for name in dashboard bridge; do
  runner="$HH/console-services/hermes-$name.sh"
  printf '#!/bin/sh\nexit 0\n' > "$runner"
  chmod 700 "$runner"
  install_systemd_unit "$name" "$runner" "$TMP/units"
done

for name in dashboard bridge; do
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
