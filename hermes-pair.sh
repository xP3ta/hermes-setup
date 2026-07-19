#!/bin/sh
# Hermes Console — verify the installed services, then reprint pairing QR.
set -eu

REPO_RAW="${HERMES_REPO_RAW:-https://raw.githubusercontent.com/xP3ta/hermes-setup/main}"
case "$(uname -s 2>/dev/null || echo unknown)" in
  CYGWIN*|MINGW*|MSYS*)
    echo "Windows native detected. Run this command in PowerShell:"
    echo "  irm $REPO_RAW/hermes-pair.ps1 | iex"
    exit 2
    ;;
esac

if { [ -n "${WSL_INTEROP:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; } &&
   [ -z "${HERMES_PAIR_HOST:-}" ]; then
  echo "WSL detected. Run the native Windows command in PowerShell:"
  echo "  irm $REPO_RAW/hermes-pair.ps1 | iex"
  exit 2
fi

HH="${HERMES_HOME:-$HOME/.hermes}"
SERVICES="$HH/console-services"
PAIR_ENV="$SERVICES/pairing.env"
PROBE="$SERVICES/hermes-service-probe.py"
KEY="$(sed -n 's/^API_SERVER_KEY=//p' "$HH/.env" 2>/dev/null | head -1 | tr -d '[:space:]' | sed 's/^["'\'']//;s/["'\'']$//')"
if [ -z "$KEY" ]; then
  echo "No API token found in $HH/.env — run setup first:"
  echo "  curl -fsSL $REPO_RAW/hermes-mobile-setup.sh | sh"
  exit 1
fi
if [ ! -f "$PAIR_ENV" ] || [ ! -f "$PROBE" ]; then
  echo "This installation predates verified pairing. Run setup once to repair and validate it:"
  echo "  curl -fsSL $REPO_RAW/hermes-mobile-setup.sh | sh"
  exit 1
fi

read_setting() {
  name="$1"
  sed -n "s/^$name=//p" "$PAIR_ENV" | head -1
}

if [ "$(read_setting PAIRING_SCHEMA)" != "1" ]; then
  echo "This pairing record is not from the verified installer. Run setup once to repair it:"
  echo "  curl -fsSL $REPO_RAW/hermes-mobile-setup.sh | sh"
  exit 1
fi

HOST="${HERMES_PAIR_HOST:-$(read_setting PAIR_HOST)}"
PAIR_SCHEME="${HERMES_PAIR_SCHEME:-$(read_setting PAIR_SCHEME)}"
PAIR_PORT="${HERMES_PAIR_PORT:-$(read_setting PAIR_PORT)}"
GATEWAY_BASE="$(read_setting GATEWAY_BASE)"
DASHBOARD_BASE="${HERMES_DASHBOARD_URL:-$(read_setting DASHBOARD_BASE)}"
BRIDGE_BASE="${HERMES_BRIDGE_URL:-$(read_setting BRIDGE_BASE)}"

case "$HOST" in
  *[!A-Za-z0-9._:-]*|*/*|*://*|'')
    echo "The stored pairing host is invalid. Run setup again."
    exit 1
    ;;
esac
case "$PAIR_SCHEME" in
  http|https) ;;
  *) echo "The stored pairing scheme is invalid. Run setup again."; exit 1 ;;
esac
case "$PAIR_PORT" in
  *[!0-9]*|'') echo "The stored pairing port is invalid. Run setup again."; exit 1 ;;
esac
if [ "$PAIR_PORT" -lt 1 ] || [ "$PAIR_PORT" -gt 65535 ]; then
  echo "The stored pairing port is invalid. Run setup again."
  exit 1
fi
BASE_HOST="$HOST"
case "$BASE_HOST" in *:*) BASE_HOST="[$BASE_HOST]" ;; esac

if [ -n "${HERMES_PAIR_HOST:-}" ] || [ -n "${HERMES_PAIR_SCHEME:-}" ] || [ -n "${HERMES_PAIR_PORT:-}" ]; then
  GATEWAY_BASE="$PAIR_SCHEME://$BASE_HOST:$PAIR_PORT"
  if [ "$PAIR_SCHEME" = "http" ]; then
    [ -n "${HERMES_DASHBOARD_URL:-}" ] || DASHBOARD_BASE="http://$BASE_HOST:9119"
    [ -n "${HERMES_BRIDGE_URL:-}" ] || BRIDGE_BASE="http://$BASE_HOST:9131"
  else
    [ -n "${HERMES_DASHBOARD_URL:-}" ] || DASHBOARD_BASE="$GATEWAY_BASE"
    [ -n "${HERMES_BRIDGE_URL:-}" ] || BRIDGE_BASE="$GATEWAY_BASE"
  fi
fi

if [ "$GATEWAY_BASE" != "$PAIR_SCHEME://$BASE_HOST:$PAIR_PORT" ]; then
  echo "The pairing record is inconsistent. Run setup again before showing credentials."
  exit 1
fi

VP="$(read_setting PYTHON_BIN)"
[ -n "$VP" ] || VP="$HH/hermes-agent/venv/bin/python3"
[ -x "$VP" ] || VP="$HH/hermes-agent/venv/bin/python"
[ -x "$VP" ] || VP="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
if [ -z "$VP" ] || [ ! -x "$VP" ]; then
  echo "Hermes Python is missing — run setup to repair the installation."
  exit 1
fi

verify() {
  kind="$1"
  base="$2"
  if ! "$VP" "$PROBE" "$kind" "$base" "$KEY" "" phone; then
    echo "ERROR: $kind is not healthy/authenticated through the address used by the phone."
    echo "Run the full repair command before pairing:"
    echo "  curl -fsSL $REPO_RAW/hermes-mobile-setup.sh | sh"
    exit 1
  fi
}

# Do not display credentials for a dead, wrong or loopback-only service.
verify gateway "$GATEWAY_BASE"
verify bridge "$BRIDGE_BASE"
verify dashboard "$DASHBOARD_BASE"

HTTPS_FLAG=""
[ "$PAIR_SCHEME" != "https" ] || HTTPS_FLAG="1"
LINK="$("$VP" - "$HOST" "$PAIR_PORT" "$KEY" "$HTTPS_FLAG" "$DASHBOARD_BASE" "$BRIDGE_BASE" <<'PY'
import sys, urllib.parse

host, port, token, https, dashboard, bridge = sys.argv[1:]
query = {
    "host": host,
    "port": port,
    "token": token,
    "dashboard": dashboard,
    "bridge": bridge,
    "bridge_token": token,
}
if https:
    query["https"] = "1"
print("hermes://pair?" + urllib.parse.urlencode(query))
PY
)"

echo ""
echo "== SCAN THIS QR WITH HERMES CONSOLE (or copy the link) =="
echo ""
QRPY='import qrcode,sys;q=qrcode.QRCode(border=1);q.add_data(sys.argv[1]);q.make();q.print_ascii(invert=True)'
QR_RENDERED=""
if command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$LINK"; then
  QR_RENDERED=1
else
  UV="$HH/bin/uv"
  [ -x "$UV" ] || UV="$(command -v uv 2>/dev/null || true)"
  if [ -n "$UV" ] && "$UV" run --with qrcode python -c "$QRPY" "$LINK" 2>/dev/null; then
    QR_RENDERED=1
  else
    "$VP" -c 'import qrcode' 2>/dev/null || "$VP" -m pip install -q qrcode >/dev/null 2>&1 || true
    if "$VP" -c "$QRPY" "$LINK" 2>/dev/null; then QR_RENDERED=1; fi
  fi
fi
if [ -z "$QR_RENDERED" ]; then
  echo "A QR renderer could not be prepared. Paste the verified link below into Hermes Console."
fi
echo ""
echo "Link: $LINK"
echo "Gateway, Dashboard and Mobile Bridge passed their functional checks."
