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
if [ ! -f "$PAIR_ENV" ]; then
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
USE_EPHEMERAL_PROBE=""
if [ "$(read_setting PROBE_SECURITY_SCHEMA)" != "2" ] || [ ! -f "$PROBE" ]; then
  USE_EPHEMERAL_PROBE=1
fi

HOST="${HERMES_PAIR_HOST:-$(read_setting PAIR_HOST)}"
PAIR_SCHEME="${HERMES_PAIR_SCHEME:-$(read_setting PAIR_SCHEME)}"
PAIR_PORT="${HERMES_PAIR_PORT:-$(read_setting PAIR_PORT)}"
GATEWAY_BASE="$(read_setting GATEWAY_BASE)"
DASHBOARD_BASE="${HERMES_DASHBOARD_URL:-$(read_setting DASHBOARD_BASE)}"
BRIDGE_BASE="${HERMES_BRIDGE_URL:-$(read_setting BRIDGE_BASE)}"

case "$HOST" in
  *[!A-Za-z0-9._:-]*|*/*|'')
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

if [ -n "$USE_EPHEMERAL_PROBE" ]; then
  umask 077
  PROBE="$(mktemp "${TMPDIR:-/tmp}/hermes-console-pair-probe.XXXXXX")"
  cleanup_probe() { rm -f -- "$PROBE"; }
  trap cleanup_probe EXIT HUP INT TERM
  cat > "$PROBE" <<'PY_PROBE'
#!/usr/bin/env python3
import ipaddress
import json
import secrets
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request

kind, base, token = sys.argv[1:4]
expected = sys.argv[4] if len(sys.argv) > 4 else ""
phone_facing = len(sys.argv) > 5 and sys.argv[5] == "phone"
base = base.rstrip("/")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, url):
        return None


opener = urllib.request.build_opener(NoRedirect)


def private_address(value):
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return False
    if ip.is_loopback:
        return False
    if ip.version == 6:
        return ip in ipaddress.ip_network("fc00::/7")
    return any(
        ip in network
        for network in (
            ipaddress.ip_network("10.0.0.0/8"),
            ipaddress.ip_network("172.16.0.0/12"),
            ipaddress.ip_network("192.168.0.0/16"),
            ipaddress.ip_network("100.64.0.0/10"),
        )
    )


def assert_phone_url():
    try:
        parsed = urllib.parse.urlsplit(base)
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except ValueError:
        raise RuntimeError("invalid phone-facing service URL") from None
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise RuntimeError("invalid phone-facing service URL")
    host = parsed.hostname.lower()
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        literal = None
    if host == "localhost" or (literal and literal.is_loopback):
        raise RuntimeError("loopback is not reachable from the phone")
    if parsed.scheme == "https":
        return
    private_name = host.endswith((".local", ".ts.net")) or "." not in host
    if literal is not None:
        addresses = [literal]
    else:
        try:
            addresses = {
                ipaddress.ip_address(item[4][0])
                for item in socket.getaddrinfo(
                    host,
                    port,
                    type=socket.SOCK_STREAM,
                )
            }
        except OSError:
            addresses = set()
    if addresses and all(private_address(str(address)) for address in addresses):
        return
    if not addresses and private_name:
        return
    raise RuntimeError("public HTTP is blocked; use LAN/Tailscale or HTTPS")


def request_json(path, authorization=None):
    headers = {"Accept": "application/json"}
    if authorization is not None:
        headers["Authorization"] = authorization
    request = urllib.request.Request(base + path, headers=headers)
    try:
        with opener.open(request, timeout=6) as response:
            status = response.status
            raw = response.read(1024 * 1024)
    except urllib.error.HTTPError as exc:
        status = exc.code
        raw = exc.read(1024 * 1024)
    except Exception as exc:
        raise RuntimeError(
            f"{path} is unreachable ({type(exc).__name__})"
        ) from None
    return status, raw


def fetch(path, auth=False):
    authorization = "Bearer " + token if auth else None
    status, raw = request_json(path, authorization)
    if status != 200:
        raise RuntimeError(f"{path} returned HTTP {status}")
    try:
        value = json.loads(raw.decode("utf-8"))
    except Exception:
        raise RuntimeError(f"{path} did not return JSON") from None
    if not isinstance(value, dict):
        raise RuntimeError(f"{path} returned the wrong JSON shape")
    return value


def assert_auth_required(path):
    invalid = "Bearer invalid-" + secrets.token_urlsafe(32)
    for label, authorization in (("missing", None), ("invalid", invalid)):
        status, _ = request_json(path, authorization)
        if status not in {401, 403}:
            raise RuntimeError(
                f"{path} did not reject {label} authentication (HTTP {status})"
            )


try:
    if phone_facing:
        assert_phone_url()
    if kind == "gateway":
        health = fetch("/health")
        if health.get("status") != "ok" or health.get("platform") != "hermes-agent":
            raise RuntimeError("/health is not Hermes Gateway")
        sessions = fetch("/api/sessions", auth=True)
        if sessions.get("object") != "list" or not isinstance(
            sessions.get("data"), list
        ):
            raise RuntimeError(
                "/api/sessions is not the authenticated Hermes API"
            )
        assert_auth_required("/api/sessions")
    elif kind == "bridge":
        health = fetch("/bridge/health")
        if health.get("status") != "ok" or not isinstance(
            health.get("version"), str
        ):
            raise RuntimeError("/bridge/health is not Hermes Mobile Bridge")
        if expected and health.get("version") != expected:
            raise RuntimeError(
                f"Bridge version is {health.get('version')}, expected {expected}"
            )
        caps = fetch("/bridge/capabilities", auth=True)
        operations = caps.get("operations")
        scopes = caps.get("scopes")
        if (
            caps.get("object") != "hermes.bridge.capabilities"
            or not isinstance(operations, dict)
            or operations.get("self_update") is not True
            or not isinstance(scopes, list)
            or "read" not in scopes
            or "config" not in scopes
        ):
            raise RuntimeError(
                "Bridge auth/config/self-update capability check failed"
            )
        assert_auth_required("/bridge/capabilities")
    elif kind == "dashboard":
        status = fetch("/api/status")
        if not isinstance(status.get("version"), str) or not isinstance(
            status.get("gateway_running"), bool
        ):
            raise RuntimeError("/api/status is not Hermes Dashboard")
        if status.get("gateway_running") is not True:
            raise RuntimeError("Dashboard reports that Hermes Gateway is stopped")
    else:
        raise RuntimeError("unknown service kind")
except RuntimeError as exc:
    print(f"{kind}: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY_PROBE
  chmod 700 "$PROBE"
fi

verify() {
  kind="$1"
  base="$2"
  if ! "$VP" "$PROBE" "$kind" "$base" "$KEY" "" phone; then
    echo "ERROR: $kind did not pass its scoped checks through the address used by the phone."
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
  if PYTHONDONTWRITEBYTECODE=1 "$VP" -c 'import qrcode' 2>/dev/null && \
     PYTHONDONTWRITEBYTECODE=1 "$VP" -c "$QRPY" "$LINK" 2>/dev/null; then
    QR_RENDERED=1
  fi
fi
if [ -z "$QR_RENDERED" ]; then
  echo "No installed QR renderer is available. Pairing did not install one or change the system."
  echo "Paste the verified link below into Hermes Console."
fi
echo ""
echo "Link: $LINK"
echo "Gateway and Mobile Bridge accepted the valid token and rejected missing/invalid tokens."
echo "Dashboard public health passed; this command does not claim that a Dashboard login succeeded."
