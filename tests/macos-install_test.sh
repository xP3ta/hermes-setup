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
# BSD sed (macOS) no acepta todas las extensiones de GNU: se usan reglas simples
# y explicitas para que la redaccion nunca se coma la salida.
redact() {
  sed -e 's/token=[^& ]*/token=REDACTED/g' \
      -e 's/bridge_token=[^& ]*/bridge_token=REDACTED/g' \
      -e 's/API_SERVER_KEY=[^ ]*/API_SERVER_KEY=REDACTED/g' \
      -e 's/BRIDGE_TOKEN=[^ ]*/BRIDGE_TOKEN=REDACTED/g' \
      -e 's/password=[^ ]*/password=REDACTED/g' \
      -e 's|hermes://pair?[^ ]*|hermes://pair?REDACTED|g'
}
if [ "$RC" -ne 0 ]; then
  echo "== ultimas lineas del instalador =="
  tail -40 "$LOG" | redact
  for svc in gateway dashboard bridge; do
    log="$HERMES_HOME/logs/$svc.log"
    echo "== $svc.log =="
    if [ -f "$log" ]; then
      printf 'bytes: '; wc -c < "$log" | tr -d ' '
      tail -25 "$log" | redact
    else
      echo "ausente"
    fi
  done
  echo "== estado de launchd =="
  for label in $LABELS; do
    printf -- '-- %s --\n' "$label"
    launchctl print "gui/$(id -u)/$label" 2>&1 | head -25 | redact
  done
  echo "== bin/ del home =="
  ls -la "$HERMES_HOME/bin" 2>&1 | head -8
  echo "== runner del Dashboard =="
  if [ -f "$HERMES_HOME/console-services/hermes-dashboard.sh" ]; then
    redact < "$HERMES_HOME/console-services/hermes-dashboard.sh" | head -14
  else
    echo "ausente"
  fi
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
  # Negative: una ruta protegida sin token no puede responder 200. /health es
  # publico a proposito, asi que se usa la ruta protegida del Dashboard.
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "${DASHBOARD_BASE}/api/model/options" || echo 000)"
  check "an unauthenticated request to a protected route is rejected (got $CODE)" \
    "$([ "$CODE" = "401" ] || [ "$CODE" = "403" ] && echo 0 || echo 1)"
else
  check "the pairing record is written" 1
fi

say "== limpieza: descargando los jobs y quitando los plists =="
for label in $LABELS; do
  launchctl bootout "gui/$UID_NUM/$label" >/dev/null 2>&1 || true
done
rm -f "$HOME/Library/LaunchAgents/dev.xpetalab.hermes-console."*.plist
# bootout es asincrono: se da un margen corto antes de declarar que sigue cargado.
for label in $LABELS; do
  attempts=0
  while [ "$attempts" -lt 10 ] && launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    sleep 1
  done
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
