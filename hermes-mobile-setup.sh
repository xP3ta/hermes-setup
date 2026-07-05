#!/bin/sh
# Hermes Console — all-in-one mobile setup.
# Hosted in the public repo xP3ta/hermes-setup so the app can hand out a
# SHORT command:
#   curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh
# Installs Hermes (if missing), starts gateway + dashboard + bridge and prints the QR.
# The bridge program is downloaded from this SAME repo (single source of truth).
# SOURCE: this file lives in the app repo (scripts/hermes-mobile-setup.sh); the
# hermes-setup repo hosts a copy that must be updated together with the bridge
# asset (assets/bridge/hermes_bridge.py).
set -e

# RAW URL of the repo (branch/tag). Must point to the PUBLIC repo hosting this file.
REPO_RAW="${HERMES_REPO_RAW:-https://raw.githubusercontent.com/xP3ta/hermes-setup/main}"

HH="${HERMES_HOME:-$HOME/.hermes}"
mkdir -p "$HH"

# 0a) user service manager BEFORE any systemctl --user
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
loginctl enable-linger "$(id -un)" 2>/dev/null || true
i=0; while [ $i -lt 10 ]; do [ -S "$XDG_RUNTIME_DIR/bus" ] && break; sleep 1; i=$((i+1)); done

# 0) Hermes if missing (no wizard, no browser). A `hermes` on the PATH is not
#    enough: it can be a BROKEN launcher left by a half-finished uninstall
#    (seen in practice: ~/.local/bin/hermes pointing to a deleted venv →
#    gateway and bridge crash-looping behind a false "OK"). Only a hermes
#    that RESPONDS counts; otherwise we install.
HB="$HH/hermes-agent/venv/bin/hermes"
if ! { [ -x "$HB" ] && "$HB" --version >/dev/null 2>&1; }; then
  HB="$(command -v hermes 2>/dev/null || true)"
  if [ -z "$HB" ] || ! "$HB" --version >/dev/null 2>&1; then
    echo "Installing Hermes Agent..."
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup --non-interactive --skip-browser
    HB="$HH/hermes-agent/venv/bin/hermes"
  fi
fi

# 1) token
KEY="$(grep -E '^API_SERVER_KEY=' "$HH/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
[ -n "$KEY" ] || { KEY="$(openssl rand -hex 32)"; printf 'API_SERVER_KEY=%s\n' "$KEY" >> "$HH/.env"; }

# 2) reachable host, in order of preference:
#    mesh (Tailscale via CLI; NetBird/Tailscale/etc. via the CGNAT range
#    100.64.0.0/10) > private LAN (RFC1918, covers ZeroTier and classic VPNs) >
#    direct public IP (bare VPS — works, but we warn about the exposure) >
#    loopback (last resort, only useful on this same machine).
IPS="$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.')"
HOST="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$HOST" ] || HOST="$(echo "$IPS" | grep -E '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' | head -1)"
[ -n "$HOST" ] || HOST="$(echo "$IPS" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -1)"
PUBLIC=""
if [ -z "$HOST" ]; then
  HOST="$(echo "$IPS" | head -1)"
  if [ -n "$HOST" ]; then PUBLIC=1; else HOST="127.0.0.1"; fi
fi

# Python for the bridge: the user venv one or, if Hermes lives elsewhere
# (global install), the python that ships with THAT hermes — the bridge
# needs aiohttp and the system python usually lacks it.
VP="$HH/hermes-agent/venv/bin/python3"
[ -x "$VP" ] || VP="$(dirname "$(readlink -f "$HB")")/python3"
[ -x "$VP" ] || VP="$(command -v python3)"
"$VP" -c 'import aiohttp' 2>/dev/null || echo "WARNING: $VP has no aiohttp; the bridge may fail to start"
mkdir -p "$HOME/.config/systemd/user"

# 3) gateway 8642
if ! (ss -tlnH 2>/dev/null | grep -q ':8642 '); then
  printf '[Unit]\nDescription=Hermes Gateway API\nAfter=network.target\n[Service]\nEnvironment=API_SERVER_HOST=0.0.0.0\nEnvironment=API_SERVER_PORT=8642\nExecStart=%s gateway run\nWorkingDirectory=%s\nRestart=on-failure\n[Install]\nWantedBy=default.target\n' "$HB" "$HH" > "$HOME/.config/systemd/user/hermes-gateway.service"
  # is-active after the wait: `enable --now` returns 0 even if the process
  # dies a second later (broken launcher, incomplete venv) — it produced a false OK.
  systemctl --user daemon-reload; systemctl --user enable --now hermes-gateway; sleep 4
  if systemctl --user is-active hermes-gateway >/dev/null 2>&1; then
    echo "Gateway 8642 OK"
  else
    echo "WARNING: the gateway did not start. Check: journalctl --user -u hermes-gateway -n 20"
  fi
fi

# 3b) dashboard 9119 (create only; it starts once its password is set via bridge)
if ! (ss -tlnH 2>/dev/null | grep -q ':9119 '); then
  printf '[Unit]\nDescription=Hermes Dashboard\nAfter=network.target\n[Service]\nExecStart=%s dashboard --host 0.0.0.0 --port 9119 --no-open\nWorkingDirectory=%s\nRestart=on-failure\n[Install]\nWantedBy=default.target\n' "$HB" "$HH" > "$HOME/.config/systemd/user/hermes-dashboard.service"
  systemctl --user daemon-reload; systemctl --user enable hermes-dashboard 2>/dev/null || true
fi

# 4) bridge: download from the repo (same source of truth as the app) + flag
curl -fsSL "$REPO_RAW/hermes_bridge.py" -o "$HH/hermes_bridge.py"
printf 'BRIDGE_HOST=0.0.0.0\nBRIDGE_PORT=9131\nBRIDGE_SCOPES=read,memory,soul,skills,cron,config,command\nBRIDGE_READ_ONLY=false\nBRIDGE_TOKEN=%s\n' "$KEY" > "$HH/bridge.env"
printf '[Unit]\nDescription=Hermes Mobile Bridge\nAfter=network.target\n[Service]\nEnvironmentFile=%s/bridge.env\nExecStart=%s %s/hermes_bridge.py --i-know-what-im-doing\nWorkingDirectory=%s\nRestart=on-failure\n[Install]\nWantedBy=default.target\n' "$HH" "$VP" "$HH" "$HH" > "$HOME/.config/systemd/user/hermes-bridge.service"
# enable + restart (NOT `enable --now`): --now does not restart an ALREADY
# running service, and this script is also the bridge UPDATE path — without
# restart, the old process kept serving the previous version.
systemctl --user daemon-reload; systemctl --user enable hermes-bridge >/dev/null 2>&1; systemctl --user restart hermes-bridge; sleep 3
systemctl --user is-active hermes-bridge >/dev/null && echo "Bridge 9131 OK" || echo "WARNING: the bridge did not start (journalctl --user -u hermes-bridge -n 20)"

# 5) dashboard: set an initial password via bridge so it binds (the app rotates it)
DASH=""
if ! (ss -tlnH 2>/dev/null | grep -q ':9119 '); then
  curl -sS -m15 -X POST "http://127.0.0.1:9131/bridge/dashboard/credentials" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d "{\"password\":\"$(openssl rand -hex 16)\"}" >/dev/null 2>&1 || true
  i=0; while [ $i -lt 20 ]; do ss -tlnH 2>/dev/null | grep -q ':9119 ' && break; sleep 2; i=$((i+1)); done
fi
ss -tlnH 2>/dev/null | grep -q ':9119 ' && DASH="&dashboard=http://$HOST:9119"

# 6) QR + link
LINK="hermes://pair?host=$HOST&port=8642&token=$KEY$DASH"
echo ""; echo "== SCAN THIS QR WITH THE APP (or copy the link) =="; echo ""
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t ANSIUTF8 "$LINK"
else
  UV="$HH/bin/uv"; [ -x "$UV" ] || UV="$(command -v uv 2>/dev/null || echo uv)"
  "$UV" run --with qrcode python -c "import qrcode,sys;q=qrcode.QRCode(border=1);q.add_data(sys.argv[1]);q.make();q.print_ascii(invert=True)" "$LINK" 2>/dev/null || echo "(install qrencode to see the QR)"
fi
echo ""; echo "Link: $LINK"
if [ -n "$PUBLIC" ]; then
  echo ""
  echo "CAUTION: no private network found (mesh VPN or LAN); the link uses the public IP $HOST."
  echo "The gateway (8642), dashboard (9119) and bridge (9131) are exposed to the internet,"
  echo "protected only by the token. Recommended: Tailscale/NetBird, or a firewall that"
  echo "restricts those ports to your devices."
fi
if [ "$HOST" = "127.0.0.1" ]; then
  echo ""
  echo "CAUTION: no network IP found; the link only works from this machine."
fi
