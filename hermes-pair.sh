#!/bin/sh
# Hermes Console — cross-platform Unix pairing QR (no reinstall/restart).
set -eu

REPO_RAW="${HERMES_REPO_RAW:-https://raw.githubusercontent.com/xP3ta/hermes-setup/main}"
case "$(uname -s 2>/dev/null || echo unknown)" in
  CYGWIN*|MINGW*|MSYS*)
    echo "Windows native detected. Run this command in PowerShell:"
    echo "  irm $REPO_RAW/hermes-pair.ps1 | iex"
    exit 2
    ;;
esac

HH="${HERMES_HOME:-$HOME/.hermes}"
KEY="$(grep -E '^API_SERVER_KEY=' "$HH/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
if [ -z "$KEY" ]; then
  echo "No API token found in $HH/.env — run the setup first:"
  echo "  curl -fsSL $REPO_RAW/hermes-mobile-setup.sh | sh"
  exit 1
fi

port_listening() {
  port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | grep -q ":$port "
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q .
  else
    netstat -an 2>/dev/null | grep -E "[.:]$port[[:space:]].*LISTEN" >/dev/null
  fi
}

IPS=""
if command -v ip >/dev/null 2>&1; then
  IPS="$(ip -o -4 addr show 2>/dev/null | awk '$2 !~ /^(lo|docker|br-|veth|virbr|podman|cni|lxc)/ {split($4,a,"/"); if (a[1] !~ /^127\./) print a[1]}' || true)"
elif command -v ifconfig >/dev/null 2>&1; then
  IPS="$(ifconfig 2>/dev/null | awk '/^[[:alnum:]]/ {iface=$1; sub(":$","",iface)} /inet / && iface !~ /^(lo|bridge|vmenet|docker|utun|awdl|llw)/ {ip=$2; sub(/^addr:/,"",ip); if (ip !~ /^127\./) print ip}' || true)"
elif command -v hostname >/dev/null 2>&1; then
  IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' || true)"
fi
HOST="$(tailscale ip -4 2>/dev/null | head -1 || true)"
[ -n "$HOST" ] || HOST="$(printf '%s\n' "$IPS" | grep -E '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' | head -1 || true)"
[ -n "$HOST" ] || HOST="$(printf '%s\n' "$IPS" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -1 || true)"
PUBLIC=""
if [ -z "$HOST" ]; then
  HOST="$(printf '%s\n' "$IPS" | head -1)"
  if [ -n "$HOST" ]; then PUBLIC=1; else HOST="127.0.0.1"; fi
fi

port_listening 8642 || echo "WARNING: gateway 8642 is not listening — the app will not connect."
port_listening 9131 || echo "WARNING: Mobile Bridge 9131 is not listening — some features will be limited."
DASH=""
port_listening 9119 && DASH="&dashboard=http://$HOST:9119"
LINK="hermes://pair?host=$HOST&port=8642&token=$KEY$DASH"

VP="$HH/hermes-agent/venv/bin/python3"
[ -x "$VP" ] || VP="$HH/hermes-agent/venv/bin/python"
[ -x "$VP" ] || VP="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"

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
  elif [ -n "$VP" ] && [ -x "$VP" ]; then
    "$VP" -c 'import qrcode' 2>/dev/null || "$VP" -m pip install -q qrcode >/dev/null 2>&1 || true
    if "$VP" -c "$QRPY" "$LINK" 2>/dev/null; then QR_RENDERED=1; fi
  fi
fi
if [ -z "$QR_RENDERED" ]; then
  echo "ERROR: the server could not prepare a QR renderer."
  echo "Copy the pairing link below into Hermes Console instead:"
  echo "Link: $LINK"
  exit 1
fi
echo ""
echo "Link: $LINK"
if [ -n "$PUBLIC" ]; then
  echo ""
  echo "CAUTION: the link uses public IP $HOST. Prefer a mesh VPN or private firewall."
fi
if [ "$HOST" = "127.0.0.1" ]; then
  echo ""
  echo "CAUTION: no reachable network IP was found; this link only works locally."
fi
