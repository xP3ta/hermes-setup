#!/bin/sh
# Hermes Console — pairing QR on demand.
# For a server that ALREADY ran the installer: prints the pairing QR + link
# again without installing or restarting anything. Hosted in the public repo
# xP3ta/hermes-setup so the app can hand out a SHORT command:
#   curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-pair.sh | sh
# SOURCE: this file lives in the app repo (scripts/hermes-pair.sh); the
# hermes-setup repo hosts a copy that must be updated together with it.
set -e

HH="${HERMES_HOME:-$HOME/.hermes}"

# Token: this script never creates one — that is the installer's job.
KEY="$(grep -E '^API_SERVER_KEY=' "$HH/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
if [ -z "$KEY" ]; then
  echo "No API token found in $HH/.env — run the installer first:"
  echo "  curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh"
  exit 1
fi

# Reachable host, in order of preference: mesh (Tailscale CLI; NetBird/etc.
# via CGNAT 100.64.0.0/10) > private LAN (RFC1918) > public IP (warn) > loopback.
IPS="$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.')"
HOST="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$HOST" ] || HOST="$(echo "$IPS" | grep -E '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' | head -1)"
[ -n "$HOST" ] || HOST="$(echo "$IPS" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -1)"
PUBLIC=""
if [ -z "$HOST" ]; then
  HOST="$(echo "$IPS" | head -1)"
  if [ -n "$HOST" ]; then PUBLIC=1; else HOST="127.0.0.1"; fi
fi

# Health check first: a QR for a dead server only causes confusion.
ss -tlnH 2>/dev/null | grep -q ':8642 ' || echo "WARNING: the gateway (8642) is not listening — the app will not connect. Re-run the installer."
ss -tlnH 2>/dev/null | grep -q ':9131 ' || echo "WARNING: the mobile bridge (9131) is not listening — some features will be limited. Re-run the installer."
DASH=""
ss -tlnH 2>/dev/null | grep -q ':9119 ' && DASH="&dashboard=http://$HOST:9119"

LINK="hermes://pair?host=$HOST&port=8642&token=$KEY$DASH"
echo ""; echo "== SCAN THIS QR WITH THE APP (or copy the link) =="; echo ""

# QR renderers, most to least likely: qrencode > uv (ephemeral qrcode) >
# Hermes venv Python (installing the tiny pure-python `qrcode` if missing).
# A successful run MUST render a QR; the link remains the emergency fallback.
QRPY="import qrcode,sys;q=qrcode.QRCode(border=1);q.add_data(sys.argv[1]);q.make();q.print_ascii(invert=True)"
QR_RENDERED=""
if command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$LINK"; then
  QR_RENDERED=1
else
  UV="$HH/bin/uv"; [ -x "$UV" ] || UV="$(command -v uv 2>/dev/null || echo uv)"
  if "$UV" run --with qrcode python -c "$QRPY" "$LINK" 2>/dev/null; then
    QR_RENDERED=1
  else
    VP="$HH/hermes-agent/venv/bin/python3"
    [ -x "$VP" ] || VP="$(command -v python3 2>/dev/null || true)"
    if [ -x "$VP" ]; then
      "$VP" -c "import qrcode" 2>/dev/null || "$VP" -m pip install -q qrcode >/dev/null 2>&1 || true
      if "$VP" -c "$QRPY" "$LINK" 2>/dev/null; then QR_RENDERED=1; fi
    fi
  fi
fi
if [ -z "$QR_RENDERED" ]; then
  echo "ERROR: the server could not prepare a QR renderer."
  echo "Copy the pairing link below into Hermes Console instead:"
  echo "Link: $LINK"
  exit 1
fi
echo ""; echo "Link: $LINK"
if [ -n "$PUBLIC" ]; then
  echo ""
  echo "CAUTION: no private network found (mesh VPN or LAN); the link uses the public IP $HOST."
  echo "Recommended: Tailscale/NetBird, or a firewall restricting ports 8642/9119/9131."
fi
if [ "$HOST" = "127.0.0.1" ]; then
  echo ""
  echo "CAUTION: no network IP found; the link only works from this machine."
fi
