#!/bin/sh
# Hermes Console — cross-platform Unix setup (Linux, macOS, WSL2, Termux).
# Native Windows uses hermes-mobile-setup.ps1 from the same public repository.
set -eu

REPO_RAW="${HERMES_REPO_RAW:-https://raw.githubusercontent.com/xP3ta/hermes-setup/main}"
WINDOWS_COMMAND="irm $REPO_RAW/hermes-mobile-setup.ps1 | iex"

case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux*) PLATFORM="linux" ;;
  Darwin*) PLATFORM="macos" ;;
  CYGWIN*|MINGW*|MSYS*)
    echo "Windows native detected. Run this command in PowerShell:"
    echo "  $WINDOWS_COMMAND"
    exit 2
    ;;
  *) PLATFORM="unix" ;;
esac

HH="${HERMES_HOME:-$HOME/.hermes}"
SERVICES="$HH/console-services"
LOGS="$HH/logs"
mkdir -p "$HH" "$SERVICES" "$LOGS"

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

# Resolve the best available per-user service manager. A portable supervisor
# keeps the current session working on containers, Termux and WSL without
# systemd; its warning below makes the reboot limitation explicit.
SERVICE_MANAGER="portable"
if [ "$PLATFORM" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  command -v loginctl >/dev/null 2>&1 && loginctl enable-linger "$(id -un)" 2>/dev/null || true
  i=0
  while [ "$i" -lt 10 ]; do
    [ -S "$XDG_RUNTIME_DIR/bus" ] && break
    sleep 1
    i=$((i + 1))
  done
  if systemctl --user show-environment >/dev/null 2>&1; then
    SERVICE_MANAGER="systemd"
  fi
elif [ "$PLATFORM" = "macos" ] && command -v launchctl >/dev/null 2>&1; then
  if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
    SERVICE_MANAGER="launchd"
  fi
fi

# Hermes Agent. A launcher only counts when it responds; stale shims from a
# half-finished uninstall must not produce three crash-looping services.
HB="$HH/hermes-agent/venv/bin/hermes"
if ! { [ -x "$HB" ] && "$HB" --version >/dev/null 2>&1; }; then
  HB="$(command -v hermes 2>/dev/null || true)"
  if [ -z "$HB" ] || ! "$HB" --version >/dev/null 2>&1; then
    echo "Installing Hermes Agent for $PLATFORM..."
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | \
      bash -s -- --skip-setup --non-interactive --skip-browser
    HB="$HH/hermes-agent/venv/bin/hermes"
    [ -x "$HB" ] || HB="$(command -v hermes 2>/dev/null || true)"
  fi
fi
if [ -z "$HB" ] || [ ! -x "$HB" ] || ! "$HB" --version >/dev/null 2>&1; then
  echo "ERROR: Hermes Agent was not installed correctly."
  exit 1
fi

# Python that owns the Hermes environment (and therefore aiohttp).
VP="$HH/hermes-agent/venv/bin/python3"
[ -x "$VP" ] || VP="$HH/hermes-agent/venv/bin/python"
if [ ! -x "$VP" ]; then
  HB_DIR="$(CDPATH= cd -- "$(dirname -- "$HB")" 2>/dev/null && pwd -P || dirname -- "$HB")"
  VP="$HB_DIR/python3"
  [ -x "$VP" ] || VP="$HB_DIR/python"
fi
[ -x "$VP" ] || VP="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
if [ -z "$VP" ] || [ ! -x "$VP" ]; then
  echo "ERROR: no Python interpreter is available for the Mobile Bridge."
  exit 1
fi
"$VP" -c 'import aiohttp' 2>/dev/null || {
  echo "ERROR: $VP does not provide aiohttp; repair the Hermes installation first."
  exit 1
}

# Shared gateway/bridge token. Existing values are never rotated.
KEY="$(grep -E '^API_SERVER_KEY=' "$HH/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
if [ -z "$KEY" ]; then
  if command -v openssl >/dev/null 2>&1; then
    KEY="$(openssl rand -hex 32)"
  else
    KEY="$("$VP" -c 'import secrets; print(secrets.token_hex(32))')"
  fi
  printf 'API_SERVER_KEY=%s\n' "$KEY" >> "$HH/.env"
fi
chmod 600 "$HH/.env" 2>/dev/null || true

# Reachable host: mesh VPN > private LAN > public address > loopback.
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

# Verified Bridge release: closed manifest, exact size/hash/version, compile,
# backup and atomic swap. No bytes execute before every check passes.
TARGET="$HH/hermes_bridge.py"
NEW="$TARGET.new"
BACKUP="$TARGET.rollback"
MANIFEST="$HH/bridge-release.json.new"
cleanup_downloads() { rm -f "$NEW" "$MANIFEST"; }
trap cleanup_downloads EXIT HUP INT TERM
curl -fsSL "$REPO_RAW/bridge-release.json" -o "$MANIFEST"
curl -fsSL "$REPO_RAW/hermes_bridge.py" -o "$NEW"
"$VP" - "$MANIFEST" "$NEW" <<'PY'
import hashlib, json, pathlib, re, sys
manifest_path, bridge_path = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
if set(manifest) != {"schema", "version", "min_app_build", "sha256", "size"}:
    raise SystemExit("Invalid Bridge release manifest fields")
version = manifest.get("version")
digest = manifest.get("sha256")
size = manifest.get("size")
if (manifest.get("schema") != 1
        or not isinstance(version, str)
        or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version)
        or not isinstance(manifest.get("min_app_build"), int)
        or manifest["min_app_build"] <= 0
        or not isinstance(digest, str)
        or not re.fullmatch(r"[a-f0-9]{64}", digest)
        or not isinstance(size, int) or size <= 0 or size > 512 * 1024):
    raise SystemExit("Invalid Bridge release manifest")
payload = bridge_path.read_bytes()
if len(payload) != size or hashlib.sha256(payload).hexdigest() != digest:
    raise SystemExit("Bridge release integrity check failed")
source = payload.decode("utf-8", errors="strict")
versions = re.findall(
    r'''^VERSION\s*=\s*["']((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))["']\s*(?:#.*)?$''',
    source, re.MULTILINE)
if versions != [version]:
    raise SystemExit("Bridge source VERSION mismatch")
compile(source, str(bridge_path), "exec")
PY
chmod 600 "$NEW"
"$VP" -m py_compile "$NEW"
[ ! -f "$TARGET" ] || cp -p "$TARGET" "$BACKUP"
mv "$NEW" "$TARGET"

ENV_FILE="$HH/bridge.env"
printf 'BRIDGE_HOST=0.0.0.0\nBRIDGE_PORT=9131\nBRIDGE_SCOPES=read,memory,soul,skills,cron,config,command\nBRIDGE_READ_ONLY=false\nBRIDGE_TOKEN=%s\n' "$KEY" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

GATEWAY_RUNNER="$SERVICES/hermes-gateway.sh"
DASHBOARD_RUNNER="$SERVICES/hermes-dashboard.sh"
BRIDGE_RUNNER="$SERVICES/hermes-bridge.sh"
HELPER="$SERVICES/service-manager.sh"

cat > "$GATEWAY_RUNNER" <<EOF
#!/bin/sh
export HERMES_HOME="$HH"
export API_SERVER_HOST=0.0.0.0
export API_SERVER_PORT=8642
cd "$HH"
exec "$HB" gateway run
EOF
cat > "$DASHBOARD_RUNNER" <<EOF
#!/bin/sh
export HERMES_HOME="$HH"
cd "$HH"
exec "$HB" dashboard --host 0.0.0.0 --port 9119 --no-open
EOF
HELPER_EXPORT=""
[ "$SERVICE_MANAGER" = "portable" ] && HELPER_EXPORT="export BRIDGE_SERVICE_HELPER=\"$HELPER\""
cat > "$BRIDGE_RUNNER" <<EOF
#!/bin/sh
set -a
. "$ENV_FILE"
set +a
export HERMES_HOME="$HH"
export BRIDGE_HERMES_HOME="$HH"
$HELPER_EXPORT
cd "$HH"
exec "$VP" "$TARGET" --i-know-what-im-doing
EOF
chmod 700 "$GATEWAY_RUNNER" "$DASHBOARD_RUNNER" "$BRIDGE_RUNNER"

# Portable lifecycle helper. It only accepts three allowlisted service names,
# validates PID ownership against the exact runner path and never uses pkill.
cat > "$HELPER" <<EOF
#!/bin/sh
set -eu
ACTION="\${1:-}"
NAME="\${2:-}"
case "\$NAME" in
  gateway) RUNNER="$GATEWAY_RUNNER" ;;
  dashboard) RUNNER="$DASHBOARD_RUNNER" ;;
  bridge) RUNNER="$BRIDGE_RUNNER" ;;
  *) exit 2 ;;
esac
PIDFILE="$SERVICES/\$NAME.pid"
LOGFILE="$LOGS/\$NAME.log"
stop_service() {
  [ -f "\$PIDFILE" ] || return 0
  PID="\$(sed -n '1p' "\$PIDFILE" 2>/dev/null || true)"
  case "\$PID" in *[!0-9]*|'') rm -f "\$PIDFILE"; return 0 ;; esac
  if kill -0 "\$PID" 2>/dev/null; then
    CMD="\$(ps -p "\$PID" -o command= 2>/dev/null || true)"
    case "\$CMD" in *"\$RUNNER"*|*hermes_bridge.py*|*" dashboard "*|*" gateway run"*) kill "\$PID" 2>/dev/null || true ;; *) exit 3 ;; esac
    i=0; while kill -0 "\$PID" 2>/dev/null && [ "\$i" -lt 3 ]; do sleep 1; i=\$((i + 1)); done
  fi
  rm -f "\$PIDFILE"
}
start_service() {
  nohup "\$RUNNER" >> "\$LOGFILE" 2>&1 </dev/null &
  echo "\$!" > "\$PIDFILE"
}
case "\$ACTION" in
  start) start_service ;;
  stop) stop_service ;;
  restart) stop_service; start_service ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$HELPER"

install_systemd_unit() {
  name="$1"
  runner="$2"
  unit="$HOME/.config/systemd/user/hermes-$name.service"
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$unit" <<EOF
[Unit]
Description=Hermes Console $name
After=network.target
[Service]
ExecStart="$runner"
WorkingDirectory="$HH"
Restart=on-failure
RestartSec=2
[Install]
WantedBy=default.target
EOF
}

install_launchd_job() {
  name="$1"
  label="$2"
  runner="$3"
  start_now="$4"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  "$VP" - "$plist" "$label" "$runner" "$HH" "$LOGS/$name.log" "$start_now" <<'PY'
import pathlib, plistlib, sys
path, label, runner, workdir, log, start = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": [runner],
    "WorkingDirectory": workdir,
    "RunAtLoad": start == "yes",
    "KeepAlive": {"SuccessfulExit": False},
    "ProcessType": "Background",
    "StandardOutPath": log,
    "StandardErrorPath": log,
}
with pathlib.Path(path).open("wb") as out:
    plistlib.dump(payload, out, sort_keys=True)
PY
  chmod 600 "$plist"
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  launchctl enable "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  [ "$start_now" != "yes" ] || launchctl kickstart -k "gui/$(id -u)/$label"
}

start_named_service() {
  name="$1"
  case "$SERVICE_MANAGER" in
    systemd) systemctl --user restart "hermes-$name" ;;
    launchd)
      case "$name" in
        gateway) label="dev.xpetalab.hermes-console.gateway" ;;
        dashboard) label="dev.xpetalab.hermes-console.dashboard" ;;
        bridge) label="dev.xpetalab.hermes-console.bridge" ;;
      esac
      launchctl kickstart -k "gui/$(id -u)/$label"
      ;;
    portable) "$HELPER" restart "$name" ;;
  esac
}

case "$SERVICE_MANAGER" in
  systemd)
    install_systemd_unit gateway "$GATEWAY_RUNNER"
    install_systemd_unit dashboard "$DASHBOARD_RUNNER"
    install_systemd_unit bridge "$BRIDGE_RUNNER"
    systemctl --user daemon-reload
    systemctl --user enable hermes-gateway hermes-dashboard hermes-bridge >/dev/null 2>&1
    port_listening 8642 || systemctl --user restart hermes-gateway
    systemctl --user restart hermes-bridge
    ;;
  launchd)
    if ! port_listening 8642; then
      install_launchd_job gateway dev.xpetalab.hermes-console.gateway "$GATEWAY_RUNNER" yes
    fi
    if ! port_listening 9119; then
      install_launchd_job dashboard dev.xpetalab.hermes-console.dashboard "$DASHBOARD_RUNNER" no
    fi
    install_launchd_job bridge dev.xpetalab.hermes-console.bridge "$BRIDGE_RUNNER" yes
    ;;
  portable)
    port_listening 8642 || "$HELPER" restart gateway
    "$HELPER" restart bridge
    echo "WARNING: no supported persistent service manager was available."
    echo "Gateway and Bridge are running for this session; configure systemd/launchd"
    echo "or your platform's startup manager to keep them across reboots."
    ;;
esac

i=0
while [ "$i" -lt 15 ] && ! port_listening 9131; do sleep 1; i=$((i + 1)); done
if port_listening 9131; then
  echo "Bridge 9131 OK ($SERVICE_MANAGER)"
else
  echo "ERROR: the bridge did not start. Check $LOGS/bridge.log or your service logs."
  if [ -f "$BACKUP" ]; then mv "$BACKUP" "$TARGET"; start_named_service bridge || true; fi
  exit 1
fi

if port_listening 8642; then
  echo "Gateway 8642 OK"
else
  echo "WARNING: the gateway did not start; check $LOGS/gateway.log or your service logs."
fi

# Set an initial Dashboard password through the authenticated Bridge. The
# Bridge restarts the correct platform service; we also kick it once as a
# deterministic fallback for older Bridge versions.
DASH=""
if ! port_listening 9119; then
  DASH_PASS="$("$VP" -c 'import secrets; print(secrets.token_hex(16))')"
  curl -sS -m15 -X POST "http://127.0.0.1:9131/bridge/dashboard/credentials" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"password\":\"$DASH_PASS\"}" >/dev/null 2>&1 || true
  start_named_service dashboard >/dev/null 2>&1 || true
  i=0
  while [ "$i" -lt 20 ] && ! port_listening 9119; do sleep 2; i=$((i + 1)); done
fi
port_listening 9119 && DASH="&dashboard=http://$HOST:9119"

LINK="hermes://pair?host=$HOST&port=8642&token=$KEY$DASH"
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
  echo "ERROR: the server could not prepare a QR renderer."
  echo "Copy the pairing link below into Hermes Console instead:"
  echo "Link: $LINK"
  exit 1
fi
echo ""
echo "Link: $LINK"
echo ""
echo "To show this QR again later:"
echo "  curl -fsSL $REPO_RAW/hermes-pair.sh | sh"
if [ -n "$PUBLIC" ]; then
  echo ""
  echo "CAUTION: the link uses public IP $HOST and exposes ports 8642/9119/9131."
  echo "Use a mesh VPN/private firewall; HTTP on the public internet is unsafe."
fi
if [ "$HOST" = "127.0.0.1" ]; then
  echo ""
  echo "CAUTION: no reachable network IP was found; this link only works locally."
fi
