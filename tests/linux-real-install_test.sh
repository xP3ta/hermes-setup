#!/bin/sh
# Linux end-to-end validation with the REAL, current upstream Hermes Agent: a
# full isolated install driven by the shipped installer (temporary HOME, ports
# away from the defaults, whichever service manager the runner offers), then
# authenticated probes against the services it started. The stand-in suites
# cannot notice when upstream changes its layout; this one can. It reaches the
# network by design, so CI runs it nightly and on demand, not on every push.
set -eu

# This installs services under the user's real service manager and stops them
# afterwards: on a machine that already runs Hermes that would stop its own.
# It is meant for a disposable CI runner.
if [ "${CI:-}" != "true" ] && [ "${HERMES_DISPOSABLE_HOST:-}" != "1" ]; then
  echo "Refusing to run: this needs a disposable host (CI=true, or HERMES_DISPOSABLE_HOST=1)." >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SETUP="$HERE/../hermes-mobile-setup.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hermes-linux-install.XXXXXX")"
# A normal Linux user session: the user's service manager was started with the
# real HOME and reads its units from there, so HOME stays what it is and only
# the Hermes home (and the ports) are isolated.
export HERMES_HOME="$WORK/hermes-home"
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
  DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  export DBUS_SESSION_BUS_ADDRESS
fi
export HERMES_GATEWAY_PORT="${HERMES_GATEWAY_PORT:-18642}"
export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-19119}"
mkdir -p "$HERMES_HOME"
# Pairing needs an address a phone could use; a runner's own private one will do.
if [ -z "${HERMES_PAIR_HOST:-}" ]; then
  HERMES_PAIR_HOST="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -1 || true)"
  export HERMES_PAIR_HOST
fi
LOG="$WORK/install.log"
FAILED=0

say() { printf '%s\n' "$1"; }
check() {
  if [ "$2" = "0" ]; then say "PASS: $1"; else say "FAIL: $1"; FAILED=1; fi
}
redact() {
  sed -e 's/token=[^& ]*/token=REDACTED/g' -e 's/dash_pass=[^& ]*/dash_pass=REDACTED/g' \
      -e 's/password: .*/password: REDACTED/' -e 's/API_SERVER_KEY=[^ ]*/API_SERVER_KEY=REDACTED/g' \
      -e 's|hermes://pair?[^ ]*|hermes://pair?REDACTED|g'
}
stop_all() {
  systemctl --user disable --now hermes-gateway hermes-dashboard >/dev/null 2>&1 || true
  for name in gateway dashboard; do
    if [ -f "$HERMES_HOME/console-services/service-manager.sh" ]; then
      sh "$HERMES_HOME/console-services/service-manager.sh" stop "$name" >/dev/null 2>&1 || true
    fi
  done
  # The units are this test's own on a disposable runner: leave none behind.
  rm -f "$HOME/.config/systemd/user/hermes-gateway.service" \
    "$HOME/.config/systemd/user/hermes-dashboard.service" \
    "$HOME/.config/systemd/user/hermes-gateway.service.d/10-hermes-console-network.conf"
  rmdir "$HOME/.config/systemd/user/hermes-gateway.service.d" 2>/dev/null || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}
dump_systemd() {
  say "== session: user=$(id -un) uid=$(id -u) XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR bus=${DBUS_SESSION_BUS_ADDRESS:-unset} =="
  loginctl show-user "$(id -un)" -p Linger -p State 2>&1 || true
  systemctl --user is-system-running 2>&1 || true
  for unit in hermes-gateway hermes-dashboard; do
    say "== systemctl --user status $unit =="
    systemctl --user status "$unit" --no-pager 2>&1 | head -25 | redact || true
    say "== journalctl --user -u $unit =="
    journalctl --user -u "$unit" -n 60 --no-pager 2>&1 | tail -60 | redact || true
  done
  for file in "$HOME/.config/systemd/user/hermes-gateway.service" \
      "$HOME/.config/systemd/user/hermes-gateway.service.d/10-hermes-console-network.conf" \
      "$HOME/.config/systemd/user/hermes-dashboard.service"; do
    say "== $file =="
    [ -f "$file" ] && redact < "$file" || say "absent"
  done
  say "== setup-transaction leftovers =="
  ls -la "$HERMES_HOME/console-services" 2>&1 | head -20
}
trap stop_all EXIT

say "== real install on Linux (HERMES_HOME=$HERMES_HOME) =="
set +e
sh "$SETUP" > "$LOG" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  say "== the installer's full output (stdout and stderr) =="
  redact < "$LOG"
  dump_systemd
  for svc in gateway dashboard; do
    say "== $svc.log =="
    [ -f "$HERMES_HOME/logs/$svc.log" ] && tail -25 "$HERMES_HOME/logs/$svc.log" | redact || say "absent"
  done
fi
check "the installer exits 0 against the current upstream Hermes" "$RC"

PAIR_ENV="$HERMES_HOME/console-services/pairing.env"
if [ -f "$PAIR_ENV" ]; then
  check "the pairing record is written" 0
  GATEWAY_BASE="$(sed -n 's/^GATEWAY_BASE=//p' "$PAIR_ENV" | head -1)"
  DASHBOARD_BASE="$(sed -n 's/^DASHBOARD_BASE=//p' "$PAIR_ENV" | head -1)"
  KEY="$(sed -n 's/^API_SERVER_KEY=//p' "$HERMES_HOME/.env" | head -1)"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer $KEY" "$GATEWAY_BASE/health" || echo 000)"
  check "the Gateway answers an authenticated /health (got $CODE)" "$([ "$CODE" = "200" ] && echo 0 || echo 1)"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer $KEY" "$DASHBOARD_BASE/api/status" || echo 000)"
  check "the Dashboard answers an authenticated /api/status (got $CODE)" "$([ "$CODE" = "200" ] && echo 0 || echo 1)"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$DASHBOARD_BASE/api/model/options" || echo 000)"
  check "a protected Dashboard route rejects a request without a token (got $CODE)" \
    "$([ "$CODE" = "401" ] || [ "$CODE" = "403" ] && echo 0 || echo 1)"
elif [ "$RC" -eq 0 ]; then
  check "the pairing record is written" 1
fi

stop_all
rm -rf "$WORK"
if [ "$FAILED" -ne 0 ]; then
  say "RESULT: Linux real-install validation FAILED"
  exit 1
fi
say "RESULT: Linux real-install validation PASSED"
