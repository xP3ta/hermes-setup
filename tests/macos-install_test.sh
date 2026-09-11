#!/bin/sh
# Native macOS end-to-end validation: a full isolated install driven by the
# shipped installer, with the real launchd service manager, and authenticated
# probes against the services it started. Cleans up the jobs it created so the
# runner is left as it was found.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SETUP="$HERE/../hermes-mobile-setup.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hermes-macos-install.XXXXXX")"
export HERMES_HOME="$WORK/home"
mkdir -p "$HERMES_HOME"
LOG="$WORK/install.log"
FAILED=0

say() { printf '%s\n' "$1"; }
check() {
  if [ "$2" = "0" ]; then say "PASS: $1"; else say "FAIL: $1"; FAILED=1; fi
}

say "== instalacion completa en macOS (HERMES_HOME=$HERMES_HOME) =="
set +e
sh "$SETUP" > "$LOG" 2>&1
RC=$?
set -e

# El log del run de CI es publico: nada de tokens ni claves, ni en el exito ni en
# el diagnostico de fallo.
redact() {
  sed -E 's/(token|key|secret|password)(=[^& "]*)/\1=REDACTED/Ig' \
    | sed -E 's/hermes:\/\/pair\?[^ ]*/hermes:\/\/pair?REDACTED/g'
}
if [ "$RC" -ne 0 ]; then
  echo "== ultimas lineas del instalador =="
  tail -40 "$LOG" | redact
  for svc in gateway dashboard bridge; do
    if [ -f "$HERMES_HOME/logs/$svc.log" ]; then
      echo "== $svc.log (ultimas 25) =="
      tail -25 "$HERMES_HOME/logs/$svc.log" | redact
    fi
  done
else
  tail -12 "$LOG" | redact
fi
check "the installer exits 0 on native macOS" "$RC"

LABELS="dev.xpetalab.hermes-console.gateway dev.xpetalab.hermes-console.dashboard dev.xpetalab.hermes-console.bridge"
UID_NUM="$(id -u)"
for label in $LABELS; do
  if launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1; then
    check "launchd reports $label as loaded" 0
  else
    check "launchd reports $label as loaded" 1
  fi
done

PAIR_ENV="$HERMES_HOME/console-services/pairing.env"
if [ -f "$PAIR_ENV" ]; then
  check "the pairing record is written" 0
  GATEWAY_BASE="$(sed -n 's/^GATEWAY_BASE=//p' "$PAIR_ENV" | head -1)"
  BRIDGE_BASE="$(sed -n 's/^BRIDGE_BASE=//p' "$PAIR_ENV" | head -1)"
  DASHBOARD_BASE="$(sed -n 's/^DASHBOARD_BASE=//p' "$PAIR_ENV" | head -1)"
  KEY="$(sed -n 's/^API_SERVER_KEY=//p' "$HERMES_HOME/.env" | head -1)"
  check "the pairing record is mode 600" "$([ "$(stat -f '%Lp' "$PAIR_ENV")" = "600" ] && echo 0 || echo 1)"
  # El probe real del producto contra los tres servicios, con token.
  for url in "$GATEWAY_BASE" "$BRIDGE_BASE" "$DASHBOARD_BASE"; do
    case "$url" in
      "$GATEWAY_BASE") path="/health" ;;
      "$BRIDGE_BASE") path="/bridge/health" ;;
      *) path="/api/status" ;;
    esac
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer $KEY" "${url}${path}" || echo 000)"
    if [ "$CODE" = "200" ]; then
      check "authenticated $url$path answers 200" 0
    else
      check "authenticated $url$path answers 200 (got $CODE)" 1
    fi
  done
  # Negative: sin token no debe haber 200.
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "${GATEWAY_BASE}/health" || echo 000)"
  check "an unauthenticated request is rejected (got $CODE)" "$([ "$CODE" != "200" ] && echo 0 || echo 1)"
else
  check "the pairing record is written" 1
fi

say "== limpieza: descargando los jobs y quitando los plists =="
for label in $LABELS; do
  launchctl bootout "gui/$UID_NUM/$label" >/dev/null 2>&1 || true
done
rm -f "$HOME/Library/LaunchAgents/dev.xpetalab.hermes-console."*.plist
for label in $LABELS; do
  if launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1; then
    check "$label no queda cargado" 1
  else
    check "$label no queda cargado" 0
  fi
done
rm -rf "$WORK"

if [ "$FAILED" -ne 0 ]; then
  say "RESULT: macOS native validation FAILED"
  exit 1
fi
say "RESULT: macOS native validation PASSED"
