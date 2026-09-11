#!/bin/sh
# Hermes Console — verified Unix setup (Linux, macOS, Termux and explicit WSL).
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

# WSL normally exposes a NAT address that an Android phone cannot reach.
# Native PowerShell can also configure Windows Firewall and persistent tasks,
# so it is the reliable default. Routed WSL installations may opt in with an
# explicit address.
if [ "$PLATFORM" = "linux" ] && { [ -n "${WSL_INTEROP:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; }; then
  if [ -z "${HERMES_PAIR_HOST:-}" ]; then
    echo "WSL detected. Its automatic IP is not reliably reachable from a phone."
    echo "Run the native Windows installer in PowerShell instead:"
    echo "  $WINDOWS_COMMAND"
    echo "Advanced routed WSL setups may set HERMES_PAIR_HOST explicitly."
    exit 2
  fi
fi

canonicalize_hermes_home() {
  candidate="$1"
  case "$candidate" in
    /*) ;;
    *) echo "ERROR: HERMES_HOME must be an absolute path." >&2; return 1 ;;
  esac
  # Generated shell runners and systemd executable paths cannot safely carry
  # these characters. Reject them rather than silently changing the path.
  if printf '%s' "$candidate" | LC_ALL=C tr '\n' '\001' | LC_ALL=C grep -q '[[:cntrl:]\\$`"]'; then
    echo "ERROR: HERMES_HOME contains unsupported characters." >&2
    return 1
  fi
  if [ -L "$candidate" ]; then
    echo "ERROR: HERMES_HOME may not be a symbolic link." >&2
    return 1
  fi
  if [ -d "$candidate" ]; then
    physical="$(CDPATH='' cd -- "$candidate" && pwd -P && printf '.')" || return 1
    physical="${physical%.}"
    physical="${physical%?}"
  else
    parent="$(dirname -- "$candidate")"
    leaf="$(basename -- "$candidate")"
    if [ ! -d "$parent" ] || [ "$leaf" = "." ] || [ "$leaf" = ".." ]; then
      echo "ERROR: the parent of HERMES_HOME must already exist." >&2
      return 1
    fi
    physical_parent="$(CDPATH='' cd -- "$parent" && pwd -P && printf '.')" || return 1
    physical_parent="${physical_parent%.}"
    physical_parent="${physical_parent%?}"
    physical="$physical_parent/$leaf"
  fi
  if printf '%s' "$physical" | LC_ALL=C tr '\n' '\001' | LC_ALL=C grep -q '[[:cntrl:]\\$`"]'; then
    echo "ERROR: HERMES_HOME contains unsupported characters." >&2
    return 1
  fi
  printf '%s\n' "$physical"
}

hermes_home_has_evidence() {
  candidate="$1"
  [ -e "$candidate/.env" ] || [ -e "$candidate/hermes-agent" ] || \
    [ -e "$candidate/console-services" ] || [ -e "$candidate/hermes_bridge.py" ]
}

case "${HOME:-}" in
  /*) ;;
  *) echo "ERROR: HOME must be a non-empty absolute path." >&2; exit 1 ;;
esac
if [ "${HERMES_HOME+x}" = x ] && [ -z "$HERMES_HOME" ]; then
  echo "ERROR: HERMES_HOME may not be empty." >&2
  exit 1
fi
HH="$(canonicalize_hermes_home "${HERMES_HOME:-$HOME/.hermes}")"
DEFAULT_HH="$(canonicalize_hermes_home "$HOME/.hermes")"
if [ "${HERMES_HOME+x}" = x ] && [ "$HH" != "$DEFAULT_HH" ] && \
   hermes_home_has_evidence "$DEFAULT_HH"; then
  echo "ERROR: another Hermes home exists at $DEFAULT_HH; refusing an ambiguous migration to $HH." >&2
  exit 1
fi

SETUP_LOCK_HELD=0
SETUP_LOCK_DIR=""
acquire_setup_lock() {
  lock_root="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
  if [ ! -d "$lock_root" ]; then
    echo "ERROR: setup lock directory $lock_root does not exist." >&2
    return 1
  fi
  SETUP_LOCK_DIR="$lock_root/hermes-console-setup-$(id -u).lock"
  old_umask="$(umask)"
  umask 077
  if ! mkdir "$SETUP_LOCK_DIR" 2>/dev/null; then
    umask "$old_umask"
    echo "ERROR: another Hermes Console setup is already running for this user." >&2
    return 1
  fi
  umask "$old_umask"
  SETUP_LOCK_HELD=1
}

release_setup_lock() {
  [ "$SETUP_LOCK_HELD" -eq 1 ] || return 0
  rmdir "$SETUP_LOCK_DIR" 2>/dev/null || true
  SETUP_LOCK_HELD=0
}

cleanup_setup() {
  if command -v rollback_transaction >/dev/null 2>&1; then
    rollback_transaction
  fi
  if command -v cleanup_downloads >/dev/null 2>&1; then
    cleanup_downloads
  fi
  release_setup_lock
}
trap cleanup_setup EXIT
trap 'exit 1' HUP INT TERM
acquire_setup_lock

ownership_python() {
  command -v python3 2>/dev/null || command -v python 2>/dev/null || true
}

assert_systemd_unit_owner() {
  unit="$1"
  parser="$(ownership_python)"
  expected_fragment="$HOME/.config/systemd/user/$unit"
  expected_dropins="$expected_fragment.d"
  if [ -L "$expected_fragment" ]; then
    echo "ERROR: $expected_fragment is a symbolic link; refusing to replace it." >&2
    return 1
  fi
  [ -n "$parser" ] || {
    echo "ERROR: no parser is available to prove ownership of $unit." >&2
    return 1
  }
  state_file="$(mktemp "${TMPDIR:-/tmp}/hermes-systemd-state.XXXXXX")"
  if ! systemctl --user show "$unit" \
      --property=LoadState,FragmentPath,DropInPaths,WorkingDirectory,ExecStart,ExecStartPre,ExecStartPost,ExecReload,ExecStop,ExecStopPost \
      >"$state_file" 2>/dev/null; then
    rm -f "$state_file"
    echo "ERROR: effective systemd state for $unit is unavailable; refusing to replace it." >&2
    return 1
  fi
  if "$parser" - "$state_file" "$HH" "$expected_fragment" "$expected_dropins" <<'PY'
import os, re, sys

state_path, expected_home, expected_fragment, expected_dropins = sys.argv[1:]
properties = {}
with open(state_path, encoding="utf-8", errors="strict") as source:
    for raw in source:
        key, separator, value = raw.rstrip("\n").partition("=")
        if separator:
            properties[key] = value


def decode(value):
    value = re.sub(
        r"\\x([0-9a-fA-F]{2})", lambda match: chr(int(match.group(1), 16)), value
    )
    return value.replace(r"\s", " ").replace(r"\\", "\\")


if properties.get("LoadState") == "not-found":
    raise SystemExit(0 if not os.path.lexists(expected_fragment) else 1)
required = ("FragmentPath", "WorkingDirectory", "ExecStart")
if properties.get("LoadState") != "loaded" or not all(properties.get(k) for k in required):
    raise SystemExit(1)
home = os.path.realpath(expected_home)
fragment = os.path.realpath(decode(properties["FragmentPath"]))
workdir = os.path.realpath(decode(properties["WorkingDirectory"]))
if fragment != os.path.realpath(expected_fragment) or workdir != home:
    raise SystemExit(1)
for encoded in properties.get("DropInPaths", "").split():
    dropin = os.path.realpath(decode(encoded))
    try:
        if os.path.commonpath((dropin, os.path.realpath(expected_dropins))) != os.path.realpath(expected_dropins):
            raise SystemExit(1)
    except ValueError:
        raise SystemExit(1)
allowed_reload = (
    os.path.realpath("/bin/kill"),
    os.path.realpath("/usr/bin/kill"),
)
for command in (
    "ExecStart", "ExecStartPre", "ExecStartPost", "ExecReload", "ExecStop", "ExecStopPost"
):
    value = properties.get(command, "")
    if not value:
        continue
    paths = re.findall(r"(?:^|[ {;])path=(.*?)\s+;\s+argv\[\]=", value)
    if not paths:
        raise SystemExit(1)
    for encoded in paths:
        declared = os.path.abspath(decode(encoded))
        executable = os.path.realpath(declared)
        if command == "ExecReload" and executable in allowed_reload:
            continue
        try:
            if os.path.commonpath((declared, home)) != home or declared == home:
                raise SystemExit(1)
        except ValueError:
            raise SystemExit(1)
PY
  then
    rm -f "$state_file"
    return 0
  fi
  rm -f "$state_file"
  echo "ERROR: effective systemd unit $unit belongs to another home or is ambiguous; refusing to replace it." >&2
  return 1
}

assert_launchd_plist_owner() {
  label="$1"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  [ ! -L "$plist" ] || {
    echo "ERROR: $plist is a symbolic link; refusing to replace it." >&2
    return 1
  }
  [ -e "$plist" ] || return 0
  parser="$(ownership_python)"
  if [ -n "$parser" ] && "$parser" - "$plist" "$label" "$HH" <<'PY'
import os, plistlib, sys
path, label, home = sys.argv[1:]
try:
    with open(path, "rb") as source:
        value = plistlib.load(source)
    arguments = value.get("ProgramArguments")
    program = value.get("Program")
    if program is None and isinstance(arguments, list) and arguments:
        program = arguments[0]
    home = os.path.realpath(home)
    program = os.path.realpath(program) if isinstance(program, str) else ""
    owned = os.path.commonpath((program, home)) == home and program != home
    valid = value.get("Label") == label and os.path.realpath(value.get("WorkingDirectory", "")) == home and owned
except (OSError, TypeError, ValueError, plistlib.InvalidFileException):
    valid = False
raise SystemExit(0 if valid else 1)
PY
  then
    return 0
  fi
  echo "ERROR: $plist belongs to another home or is ambiguous; refusing to replace it." >&2
  return 1
}

assert_loaded_launchd_job_owner() {
  label="$1"
  parser="$(ownership_python)"
  [ -n "$parser" ] || return 1
  state_file="$(mktemp "${TMPDIR:-/tmp}/hermes-launchd-state.XXXXXX")"
  if ! launchctl print "gui/$(id -u)/$label" >"$state_file" 2>/dev/null; then
    if ! launchctl print "gui/$(id -u)" >"$state_file" 2>/dev/null; then
      rm -f "$state_file"
      echo "ERROR: launchd state is unavailable; refusing lifecycle changes." >&2
      return 1
    fi
    if "$parser" - "$state_file" "$label" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="strict").read()
label = re.escape(sys.argv[2])
raise SystemExit(1 if re.search(r"(^|[\s={])" + label + r"([\s=}]+|$)", text) else 0)
PY
    then
      rm -f "$state_file"
      return 0
    fi
    rm -f "$state_file"
    echo "ERROR: loaded launchd job $label is ambiguous; refusing to replace it." >&2
    return 1
  fi
  if "$parser" - "$state_file" "$HH" <<'PY'
import os, re, sys
text = open(sys.argv[1], encoding="utf-8", errors="strict").read()
home = os.path.realpath(sys.argv[2])
def field(name):
    match = re.search(r"^\s*" + re.escape(name) + r"\s*=\s*(.*?)\s*$", text, re.MULTILINE)
    return match.group(1) if match else ""
workdir = os.path.realpath(field("working directory")) if field("working directory") else ""
program = field("program")
if not program:
    block = re.search(r"^\s*arguments\s*=\s*\{(.*?)^\s*\}", text, re.MULTILINE | re.DOTALL)
    if block:
        match = re.search(r"^\s*0\s*=\s*(.*?)\s*$", block.group(1), re.MULTILINE)
        program = match.group(1) if match else ""
program = os.path.realpath(program) if program else ""
try:
    owned = os.path.commonpath((program, home)) == home and program != home
except ValueError:
    owned = False
raise SystemExit(0 if workdir == home and owned else 1)
PY
  then
    rm -f "$state_file"
    return 0
  fi
  rm -f "$state_file"
  echo "ERROR: loaded launchd job $label belongs to another home or is ambiguous; refusing to replace it." >&2
  return 1
}

select_service_manager() {
  SERVICE_MANAGER="portable"
  if [ "$PLATFORM" = "linux" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if command -v systemctl >/dev/null 2>&1 && \
       systemctl --user show-environment >/dev/null 2>&1; then
      SERVICE_MANAGER="systemd"
    fi
  elif [ "$PLATFORM" = "macos" ] && command -v launchctl >/dev/null 2>&1 && \
       launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
    SERVICE_MANAGER="launchd"
  fi
}

preflight_service_ownership() {
  systemd_dir="$HOME/.config/systemd/user"
  launchd_dir="$HOME/Library/LaunchAgents"
  case "$SERVICE_MANAGER" in
    systemd)
      for unit in hermes-gateway.service hermes-dashboard.service hermes-bridge.service; do
        assert_systemd_unit_owner "$unit" || return 1
      done
      for label in dev.xpetalab.hermes-console.gateway dev.xpetalab.hermes-console.dashboard dev.xpetalab.hermes-console.bridge; do
        [ ! -e "$launchd_dir/$label.plist" ] || {
          echo "ERROR: stale launchd definition $label conflicts with systemd; refusing migration." >&2
          return 1
        }
      done
      ;;
    launchd)
      for label in dev.xpetalab.hermes-console.gateway dev.xpetalab.hermes-console.dashboard dev.xpetalab.hermes-console.bridge; do
        assert_launchd_plist_owner "$label" || return 1
        assert_loaded_launchd_job_owner "$label" || return 1
      done
      for unit in hermes-gateway.service hermes-dashboard.service hermes-bridge.service; do
        [ ! -e "$systemd_dir/$unit" ] || {
          echo "ERROR: stale systemd definition $unit conflicts with launchd; refusing migration." >&2
          return 1
        }
      done
      ;;
    portable)
      for path in \
        "$systemd_dir/hermes-gateway.service" \
        "$systemd_dir/hermes-dashboard.service" \
        "$systemd_dir/hermes-bridge.service" \
        "$launchd_dir/dev.xpetalab.hermes-console.gateway.plist" \
        "$launchd_dir/dev.xpetalab.hermes-console.dashboard.plist" \
        "$launchd_dir/dev.xpetalab.hermes-console.bridge.plist"; do
        [ ! -e "$path" ] || {
          echo "ERROR: $path exists but its effective manager state is unavailable; refusing migration." >&2
          return 1
        }
      done
      for name in gateway dashboard bridge; do
        pidfile="$HH/console-services/$name.pid"
        [ -f "$pidfile" ] || continue
        pid="$(sed -n '1p' "$pidfile" 2>/dev/null || true)"
        case "$pid" in
          *[!0-9]*|'')
            echo "ERROR: portable $name PID record is malformed; refusing ambiguous replacement." >&2
            return 1
            ;;
        esac
        if kill -0 "$pid" 2>/dev/null; then
          echo "ERROR: live portable $name PID $pid cannot be migrated transactionally; stop it explicitly before setup." >&2
          return 1
        fi
      done
      ;;
  esac
}

select_service_manager
preflight_service_ownership

SERVICES="$HH/console-services"
LOGS="$HH/logs"
PROBE="$SERVICES/hermes-service-probe.py"
PAIR_ENV="$SERVICES/pairing.env"
TARGET="$HH/hermes_bridge.py"
BACKUP="$TARGET.rollback"
ENV_FILE="$HH/bridge.env"
GATEWAY_RUNNER="$SERVICES/hermes-gateway.sh"
DASHBOARD_RUNNER="$SERVICES/hermes-dashboard.sh"
BRIDGE_RUNNER="$SERVICES/hermes-bridge.sh"
HELPER="$SERVICES/service-manager.sh"
for managed_dir in "$SERVICES" "$LOGS"; do
  if [ -L "$managed_dir" ]; then
    echo "ERROR: managed directory $managed_dir is a symbolic link; refusing setup." >&2
    exit 1
  fi
done
HH_CREATED_BY_SETUP=0
[ -e "$HH" ] || HH_CREATED_BY_SETUP=1
SERVICES_CREATED_BY_SETUP=0
[ -e "$SERVICES" ] || SERVICES_CREATED_BY_SETUP=1
LOGS_CREATED_BY_SETUP=0
[ -e "$LOGS" ] || LOGS_CREATED_BY_SETUP=1
mkdir -p "$HH" "$SERVICES" "$LOGS"

SETUP_STEP=0
SETUP_TOTAL=7
setup_step() {
  SETUP_STEP=$((SETUP_STEP + 1))
  case "$SETUP_STEP" in
    1) bar="#......" ;;
    2) bar="##....." ;;
    3) bar="###...." ;;
    4) bar="####..." ;;
    5) bar="#####.." ;;
    6) bar="######." ;;
    *) bar="#######" ;;
  esac
  printf '\n[%s] %s/%s %s\n' "$bar" "$SETUP_STEP" "$SETUP_TOTAL" "$1"
}

setup_step "Inspecting platform and service manager"

port_listening() {
  port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH 2>/dev/null | grep -q ":$port "
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q .
  else
    netstat -an 2>/dev/null | grep -E "[.:]${port}[[:space:]].*LISTEN" >/dev/null
  fi
}

show_port_owner() {
  port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed -n '1,4p' || true
  elif command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :$port" 2>/dev/null | sed -n '1,4p' || true
  fi
}

service_failure() {
  name="$1"
  port="$2"
  log_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  echo "ERROR: $name did not pass its required Hermes identity/access checks on TCP $port."
  if port_listening "$port"; then
    echo "TCP $port is occupied, but it is not the expected healthy $name service:"
    show_port_owner "$port"
    echo "The installer did not kill that process. Stop the conflict and run setup again."
  else
    echo "Nothing is listening on TCP $port."
  fi
  echo "Inspect $LOGS/$log_name.log or the platform service logs, then retry."
  exit 1
}

# Configure lingering only after the selected home is locked and effective
# ownership of all fixed service identifiers has been proven.
if [ "$SERVICE_MANAGER" = "systemd" ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if command -v loginctl >/dev/null 2>&1; then
    LINGER_USER="$(id -un)"
    LINGER_STATE="$(loginctl show-user "$LINGER_USER" -p Linger --value 2>/dev/null || true)"
    if [ "$LINGER_STATE" != "yes" ]; then
      LINGER_ENABLED=0
      if [ "$(id -u)" -eq 0 ]; then
        if loginctl enable-linger "$LINGER_USER" >/dev/null 2>&1; then
          LINGER_ENABLED=1
        fi
      elif command -v sudo >/dev/null 2>&1 && \
           sudo -n loginctl enable-linger "$LINGER_USER" >/dev/null 2>&1; then
        LINGER_ENABLED=1
      fi
      if [ "$LINGER_ENABLED" -ne 1 ]; then
        echo "WARNING: user lingering is not enabled; services may stop after logout."
        echo "Run once as an administrator, then rerun setup:"
        echo "  sudo loginctl enable-linger $LINGER_USER"
      fi
    fi
  fi
fi

setup_step "Checking Hermes Agent"

# Hermes Agent. A launcher only counts when it responds; stale shims from a
# half-finished uninstall must not produce three crash-looping services.
AGENT_DIR="$HH/hermes-agent"
HB="$AGENT_DIR/venv/bin/hermes"
cleanup_fresh_agent_attempt() {
  if [ "$HH_CREATED_BY_SETUP" -eq 1 ]; then
    rm -rf -- "$HH"
    return
  fi
  rm -rf -- "$AGENT_DIR" "$HH/node"
  rm -f -- "$HH/bin/hermes" "$HH/bin/uv" "$HH/bin/uvx"
  [ "$LOGS_CREATED_BY_SETUP" -ne 1 ] || rmdir "$LOGS" 2>/dev/null || true
  [ "$SERVICES_CREATED_BY_SETUP" -ne 1 ] || rmdir "$SERVICES" 2>/dev/null || true
  rmdir "$HH/bin" 2>/dev/null || true
}
if ! { [ -x "$HB" ] && "$HB" --version >/dev/null 2>&1; }; then
  if [ -e "$AGENT_DIR" ] || [ -L "$AGENT_DIR" ] || \
     [ -e "$HH/node" ] || [ -L "$HH/node" ] || \
     [ -e "$HH/bin/hermes" ] || [ -L "$HH/bin/hermes" ] || \
     [ -e "$HH/bin/uv" ] || [ -L "$HH/bin/uv" ] || \
     [ -e "$HH/bin/uvx" ] || [ -L "$HH/bin/uvx" ]; then
    echo "ERROR: an existing Hermes Agent tree or shim is not healthy; refusing to run the installer over it." >&2
    echo "Repair or remove the broken installation explicitly, then rerun setup." >&2
    exit 1
  fi
  echo "Installing Hermes Agent for $PLATFORM..."
  if ! curl -fsSL https://hermes-agent.nousresearch.com/install.sh | \
      UV_NO_CACHE=1 bash -s -- --skip-setup --non-interactive --skip-browser --skip-computer-use \
      --hermes-home "$HH" --dir "$AGENT_DIR"; then
    cleanup_fresh_agent_attempt
    echo "ERROR: Hermes Agent installation failed; fresh attempt artifacts were removed." >&2
    exit 1
  fi
  HB="$AGENT_DIR/venv/bin/hermes"
  if [ ! -x "$HB" ] || ! "$HB" --version >/dev/null 2>&1; then
    cleanup_fresh_agent_attempt
    echo "ERROR: Hermes Agent did not pass its health check; fresh attempt artifacts were removed." >&2
    exit 1
  fi
fi

# Python that owns the Hermes environment (and therefore aiohttp).
VP="$HH/hermes-agent/venv/bin/python3"
[ -x "$VP" ] || VP="$HH/hermes-agent/venv/bin/python"
if [ ! -x "$VP" ]; then
  HB_REAL="$HB"
  if command -v realpath >/dev/null 2>&1; then
    HB_REAL="$(realpath "$HB" 2>/dev/null || printf '%s' "$HB")"
  fi
  if ! HB_DIR="$(CDPATH='' cd -- "$(dirname -- "$HB_REAL")" 2>/dev/null && pwd -P)"; then
    HB_DIR="$(dirname -- "$HB_REAL")"
  fi
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

TRANSACTION_PENDING=0
TRANSACTION_DIR=""
SERVICE_LIFECYCLE_TOUCHED=0
transaction_path() {
  case "$1" in
    env) printf '%s\n' "$HH/.env" ;;
    probe) printf '%s\n' "$PROBE" ;;
    bridge) printf '%s\n' "$TARGET" ;;
    bridge_rollback) printf '%s\n' "$BACKUP" ;;
    bridge_env) printf '%s\n' "$ENV_FILE" ;;
    gateway_runner) printf '%s\n' "$GATEWAY_RUNNER" ;;
    dashboard_runner) printf '%s\n' "$DASHBOARD_RUNNER" ;;
    bridge_runner) printf '%s\n' "$BRIDGE_RUNNER" ;;
    helper) printf '%s\n' "$HELPER" ;;
    pair_env) printf '%s\n' "$PAIR_ENV" ;;
    systemd_gateway) printf '%s\n' "$HOME/.config/systemd/user/hermes-gateway.service" ;;
    systemd_dashboard) printf '%s\n' "$HOME/.config/systemd/user/hermes-dashboard.service" ;;
    systemd_bridge) printf '%s\n' "$HOME/.config/systemd/user/hermes-bridge.service" ;;
    systemd_dropin) printf '%s\n' "$HOME/.config/systemd/user/hermes-gateway.service.d/10-hermes-console-network.conf" ;;
    launchd_gateway) printf '%s\n' "$HOME/Library/LaunchAgents/dev.xpetalab.hermes-console.gateway.plist" ;;
    launchd_dashboard) printf '%s\n' "$HOME/Library/LaunchAgents/dev.xpetalab.hermes-console.dashboard.plist" ;;
    launchd_bridge) printf '%s\n' "$HOME/Library/LaunchAgents/dev.xpetalab.hermes-console.bridge.plist" ;;
    *) return 2 ;;
  esac
}

snapshot_transaction_file() {
  key="$1"
  path="$(transaction_path "$key")"
  if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
    echo "ERROR: $path is not a regular owned file; refusing transactional replacement." >&2
    return 1
  fi
  if [ -f "$path" ]; then
    printf '1\n' > "$TRANSACTION_DIR/$key.had"
    cp -p "$path" "$TRANSACTION_DIR/$key.data"
  else
    printf '0\n' > "$TRANSACTION_DIR/$key.had"
  fi
}

restore_transaction_file() {
  key="$1"
  path="$(transaction_path "$key")"
  had="$(sed -n '1p' "$TRANSACTION_DIR/$key.had" 2>/dev/null || true)"
  rm -f "$path.new" "$path.restore.$$"
  if [ "$had" = "1" ]; then
    mkdir -p "$(dirname -- "$path")"
    cp -p "$TRANSACTION_DIR/$key.data" "$path.restore.$$"
    mv "$path.restore.$$" "$path"
  elif [ "$had" = "0" ]; then
    rm -f "$path"
  else
    return 1
  fi
}

begin_transaction() {
  TRANSACTION_KEYS="env probe bridge bridge_rollback bridge_env gateway_runner dashboard_runner bridge_runner helper pair_env systemd_gateway systemd_dashboard systemd_bridge systemd_dropin launchd_gateway launchd_dashboard launchd_bridge"
  TRANSACTION_DIR="$(mktemp -d "$SERVICES/setup-transaction.XXXXXX")"
  TRANSACTION_PENDING=1
  for key in $TRANSACTION_KEYS; do
    snapshot_transaction_file "$key"
  done
  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    for name in gateway dashboard bridge; do
      if systemctl --user is-active --quiet "hermes-$name"; then
        printf '1\n' > "$TRANSACTION_DIR/systemd_$name.active"
      else
        printf '0\n' > "$TRANSACTION_DIR/systemd_$name.active"
      fi
      if systemctl --user is-enabled --quiet "hermes-$name"; then
        printf '1\n' > "$TRANSACTION_DIR/systemd_$name.enabled"
      else
        printf '0\n' > "$TRANSACTION_DIR/systemd_$name.enabled"
      fi
    done
  elif [ "$SERVICE_MANAGER" = "launchd" ]; then
    for name in gateway dashboard bridge; do
      label="dev.xpetalab.hermes-console.$name"
      if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
        printf '1\n' > "$TRANSACTION_DIR/launchd_$name.loaded"
      else
        printf '0\n' > "$TRANSACTION_DIR/launchd_$name.loaded"
      fi
    done
  fi
}

restore_systemd_state() {
  restore_failed=0
  if ! systemctl --user daemon-reload >/dev/null 2>&1; then restore_failed=1; fi
  for name in gateway dashboard bridge; do
    had_unit="$(sed -n '1p' "$TRANSACTION_DIR/systemd_$name.had" 2>/dev/null || true)"
    if [ "$had_unit" = "0" ]; then continue; fi
    if [ "$had_unit" != "1" ]; then restore_failed=1; continue; fi
    enabled="$(sed -n '1p' "$TRANSACTION_DIR/systemd_$name.enabled" 2>/dev/null || true)"
    active="$(sed -n '1p' "$TRANSACTION_DIR/systemd_$name.active" 2>/dev/null || true)"
    if [ "$enabled" = "1" ]; then
      if ! systemctl --user enable "hermes-$name" >/dev/null 2>&1; then restore_failed=1; fi
    else
      if ! systemctl --user disable "hermes-$name" >/dev/null 2>&1; then restore_failed=1; fi
    fi
    if [ "$active" = "1" ]; then
      if ! systemctl --user restart "hermes-$name" >/dev/null 2>&1; then restore_failed=1; fi
    else
      if ! systemctl --user stop "hermes-$name" >/dev/null 2>&1; then restore_failed=1; fi
    fi
  done
  return "$restore_failed"
}

cleanup_transaction_backups() {
  [ -n "$TRANSACTION_DIR" ] || return 0
  cleanup_failed=0
  for key in $TRANSACTION_KEYS; do
    rm -f "$TRANSACTION_DIR/$key.had" "$TRANSACTION_DIR/$key.data" || cleanup_failed=1
  done
  for name in gateway dashboard bridge; do
    rm -f \
      "$TRANSACTION_DIR/systemd_$name.active" \
      "$TRANSACTION_DIR/systemd_$name.enabled" \
      "$TRANSACTION_DIR/launchd_$name.loaded" || cleanup_failed=1
  done
  rm -f "$TRANSACTION_DIR/ufw.added" "$TRANSACTION_DIR/firewalld.added" || cleanup_failed=1
  if ! rmdir "$TRANSACTION_DIR" 2>/dev/null; then cleanup_failed=1; fi
  if [ "$cleanup_failed" -eq 0 ]; then TRANSACTION_DIR=""; fi
  return "$cleanup_failed"
}

rollback_private_firewall() {
  [ -n "$TRANSACTION_DIR" ] || return 0
  firewall_rollback_failed=0
  if [ -f "$TRANSACTION_DIR/ufw.added" ]; then
    while IFS= read -r port; do
      [ -n "$port" ] || continue
      if ! run_privileged ufw --force delete allow from "$FIREWALL_SOURCE" \
          to any port "$port" proto tcp >/dev/null 2>&1; then
        firewall_rollback_failed=1
      fi
    done < "$TRANSACTION_DIR/ufw.added"
  fi
  if [ -f "$TRANSACTION_DIR/firewalld.added" ]; then
    while IFS= read -r rule; do
      [ -n "$rule" ] || continue
      if ! run_privileged firewall-cmd --permanent --remove-rich-rule="$rule" \
          >/dev/null 2>&1; then
        firewall_rollback_failed=1
      fi
    done < "$TRANSACTION_DIR/firewalld.added"
    if ! run_privileged firewall-cmd --reload >/dev/null 2>&1; then
      firewall_rollback_failed=1
    fi
  fi
  return "$firewall_rollback_failed"
}

rollback_transaction() {
  [ "$TRANSACTION_PENDING" -eq 1 ] || return 0
  TRANSACTION_PENDING=0
  rollback_failed=0
  if ! rollback_private_firewall; then rollback_failed=1; fi
  if [ "$SERVICE_LIFECYCLE_TOUCHED" -eq 1 ]; then
    case "$SERVICE_MANAGER" in
      systemd)
        for name in gateway dashboard bridge; do
          if ! systemctl --user stop "hermes-$name" >/dev/null 2>&1; then rollback_failed=1; fi
        done
        ;;
      launchd)
        for name in gateway dashboard bridge; do
          label="dev.xpetalab.hermes-console.$name"
          if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && \
             ! launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1; then
            rollback_failed=1
          fi
        done
        ;;
      portable)
        if [ -x "$HELPER" ]; then
          for name in gateway dashboard bridge; do
            if ! "$HELPER" stop "$name" >/dev/null 2>&1; then rollback_failed=1; fi
          done
        fi
        ;;
    esac
  fi
  for key in $TRANSACTION_KEYS; do
    if ! restore_transaction_file "$key"; then rollback_failed=1; fi
  done
  if [ "$SERVICE_LIFECYCLE_TOUCHED" -eq 1 ]; then
    case "$SERVICE_MANAGER" in
      systemd)
        if ! restore_systemd_state; then rollback_failed=1; fi
        ;;
      launchd)
        for name in gateway dashboard bridge; do
          loaded="$(sed -n '1p' "$TRANSACTION_DIR/launchd_$name.loaded" 2>/dev/null || true)"
          [ "$loaded" = "1" ] || continue
          label="dev.xpetalab.hermes-console.$name"
          plist="$HOME/Library/LaunchAgents/$label.plist"
          if [ -f "$plist" ] && \
             ! launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1; then
            rollback_failed=1
          fi
        done
        ;;
    esac
  fi
  if [ "$rollback_failed" -eq 0 ]; then
    if ! cleanup_transaction_backups; then rollback_failed=1; fi
  fi
  if [ "$rollback_failed" -ne 0 ]; then
    echo "CRITICAL: setup rollback was incomplete; recovery data was retained at $TRANSACTION_DIR" >&2
  fi
  return 0
}

commit_transaction() {
  [ "$TRANSACTION_PENDING" -eq 1 ] || return 0
  TRANSACTION_PENDING=0
  if ! cleanup_transaction_backups; then
    echo "ERROR: setup completed but transaction cleanup failed at $TRANSACTION_DIR" >&2
    return 1
  fi
}

begin_transaction

# Preserve one usable existing API key. Blank, placeholder or too-short legacy
# values cannot start modern Hermes, so those are repaired atomically.
# Conflicting duplicate strong values fail closed instead of guessing.
KEY="$("$VP" - "$HH/.env" <<'PY'
import os, pathlib, secrets, sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
values = []
for line in lines:
    if line.startswith("API_SERVER_KEY="):
        values.append(line.split("=", 1)[1].strip().strip('"').strip("'"))
placeholders = {"changeme", "change-me", "your-api-key", "replace-me", "secret"}
strong = [v for v in values if len(v) >= 16 and v.lower() not in placeholders]
if len(set(strong)) > 1:
    raise SystemExit(
        "ERROR: conflicting API_SERVER_KEY entries exist in .env; "
        "keep exactly one and retry"
    )
key = strong[0] if strong else secrets.token_hex(32)
out, inserted = [], False
for line in lines:
    if line.startswith("API_SERVER_KEY="):
        if not inserted:
            out.append("API_SERVER_KEY=" + key)
            inserted = True
        continue
    out.append(line)
if not inserted:
    out.append("API_SERVER_KEY=" + key)
tmp = path.with_name(path.name + ".new")
tmp.write_text("\n".join(out) + "\n", encoding="utf-8")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(key)
PY
)"
chmod 600 "$HH/.env" 2>/dev/null || true

# Reachable host: mesh VPN > private LAN. Public HTTP and loopback never
# produce a QR because the Android release rejects or cannot reach them.
IPS=""
if command -v ip >/dev/null 2>&1; then
  IPS="$(ip -o -4 addr show 2>/dev/null | awk '$2 !~ /^(lo|docker|br-|veth|virbr|podman|cni|lxc)/ {if ($4 !~ /^(127\.|169\.254\.)/) print $4}' || true)"
elif command -v ifconfig >/dev/null 2>&1; then
  IPS="$(ifconfig 2>/dev/null | awk '/^[[:alnum:]]/ {iface=$1; sub(":$","",iface)} /inet / && iface !~ /^(lo|bridge|vmenet|docker|utun|awdl|llw)/ {ip=$2; sub(/^addr:/,"",ip); if (ip !~ /^(127\.|169\.254\.)/) print ip "/"}' || true)"
elif command -v hostname >/dev/null 2>&1; then
  IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -Ev '^(127\.|169\.254\.)' | sed 's|$|/|' || true)"
fi

HOST="${HERMES_PAIR_HOST:-}"
NETWORK_KIND="override"
HOST_RECORD=""
if [ -z "$HOST" ]; then
  HOST="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if [ -n "$HOST" ]; then
    NETWORK_KIND="mesh"
  else
    HOST_RECORD="$(printf '%s\n' "$IPS" | grep -E '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' | head -1 || true)"
    if [ -n "$HOST_RECORD" ]; then
      HOST="${HOST_RECORD%%/*}"
      NETWORK_KIND="mesh"
    else
      HOST_RECORD="$(printf '%s\n' "$IPS" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -1 || true)"
      if [ -n "$HOST_RECORD" ]; then
        HOST="${HOST_RECORD%%/*}"
        NETWORK_KIND="lan"
      fi
    fi
  fi
fi

# Puertos de servicio: defaults historicos, con overrides para un host que ya
# tiene 8642/9119/9131 ocupados. Todo consumidor (unidades, runners, firewall,
# probes, enlace de pairing) sale de aqui.
GATEWAY_PORT="${HERMES_GATEWAY_PORT:-8642}"
DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
BRIDGE_PORT="${HERMES_BRIDGE_PORT:-9131}"
for _hermes_port in "$GATEWAY_PORT" "$DASHBOARD_PORT" "$BRIDGE_PORT"; do
  case "$_hermes_port" in
    *[!0-9]*|'') echo "ERROR: HERMES_GATEWAY_PORT, HERMES_DASHBOARD_PORT and HERMES_BRIDGE_PORT must be TCP ports. No changes were made."; exit 1 ;;
  esac
  if [ "$_hermes_port" -lt 1 ] || [ "$_hermes_port" -gt 65535 ]; then
    echo "ERROR: a Hermes service port is out of range. No changes were made."
    exit 1
  fi
done
if [ "$GATEWAY_PORT" = "$DASHBOARD_PORT" ] || [ "$GATEWAY_PORT" = "$BRIDGE_PORT" ] || [ "$DASHBOARD_PORT" = "$BRIDGE_PORT" ]; then
  echo "ERROR: HERMES_GATEWAY_PORT, HERMES_DASHBOARD_PORT and HERMES_BRIDGE_PORT must be three different ports. No changes were made."
  exit 1
fi

PAIR_SCHEME="${HERMES_PAIR_SCHEME:-http}"
case "$PAIR_SCHEME" in
  http|https) ;;
  *) echo "ERROR: HERMES_PAIR_SCHEME must be http or https."; exit 1 ;;
esac
PAIR_PORT="${HERMES_PAIR_PORT:-}"
if [ -z "$PAIR_PORT" ]; then
  if [ "$PAIR_SCHEME" = "https" ]; then PAIR_PORT=443; else PAIR_PORT="$GATEWAY_PORT"; fi
fi
case "$PAIR_PORT" in
  *[!0-9]*|'') echo "ERROR: HERMES_PAIR_PORT must be a TCP port."; exit 1 ;;
esac
if [ "$PAIR_PORT" -lt 1 ] || [ "$PAIR_PORT" -gt 65535 ]; then
  echo "ERROR: HERMES_PAIR_PORT is out of range."
  exit 1
fi
if [ -z "$HOST" ]; then
  echo "ERROR: no private LAN or Tailscale address was found, so no safe mobile QR can be created."
  echo "Connect Tailscale or join the phone to this LAN. For a public server, configure HTTPS"
  echo "and rerun with HERMES_PAIR_HOST=<name> HERMES_PAIR_SCHEME=https."
  exit 1
fi
case "$HOST" in
  *[!A-Za-z0-9._:-]*|*/*)
    echo "ERROR: HERMES_PAIR_HOST is not a valid host name or IP address."
    exit 1
    ;;
esac

HOST_INFO="$("$VP" - "$HOST" "$PAIR_SCHEME" "$HOST_RECORD" <<'PY'
import ipaddress, socket, sys

host, scheme, record = sys.argv[1:]
try:
    ip = ipaddress.ip_address(host)
except ValueError:
    try:
        ip = ipaddress.ip_address(socket.gethostbyname(host))
    except Exception:
        ip = None
private_name = (
    host.lower().endswith((".local", ".ts.net"))
    or "." not in host
    or host.lower().endswith((".test", ".example"))
)
cgnat = bool(
    ip and ip.version == 4
    and ipaddress.ip_address("100.64.0.0") <= ip
    <= ipaddress.ip_address("100.127.255.255")
)
allowed_http = bool(ip and (ip.is_private or ip.is_loopback or cgnat)) or private_name
if host.lower() == "localhost" or (ip and ip.is_loopback):
    raise SystemExit(
        "ERROR: loopback is not reachable from a phone; use a LAN/Tailscale address"
    )
if scheme == "http" and not allowed_http:
    raise SystemExit(
        "ERROR: public HTTP is blocked; use Tailscale/LAN or HERMES_PAIR_SCHEME=https"
    )
kind = "mesh" if cgnat else "lan"
source = "100.64.0.0/10" if cgnat else ""
if not source and ip and ip.version == 4:
    prefix = None
    if record and "/" in record:
        try:
            prefix = int(record.rsplit("/", 1)[1])
        except ValueError:
            pass
    if prefix is not None:
        source = str(ipaddress.ip_network(f"{ip}/{prefix}", strict=False))
    elif ip in ipaddress.ip_network("10.0.0.0/8"):
        source = "10.0.0.0/8"
    elif ip in ipaddress.ip_network("172.16.0.0/12"):
        source = "172.16.0.0/12"
    elif ip in ipaddress.ip_network("192.168.0.0/16"):
        source = "192.168.0.0/16"
if scheme == "http" and not source:
    raise SystemExit(
        "ERROR: could not determine a private firewall source for this host; use HTTPS"
    )
print(kind + "|" + source)
PY
)"
[ "$NETWORK_KIND" = "override" ] && NETWORK_KIND="${HOST_INFO%%|*}"
FIREWALL_SOURCE="${HOST_INFO#*|}"

BASE_HOST="$HOST"
case "$BASE_HOST" in *:*) BASE_HOST="[$BASE_HOST]" ;; esac
GATEWAY_BASE="$PAIR_SCHEME://$BASE_HOST:$PAIR_PORT"
if [ "$PAIR_SCHEME" = "http" ]; then
  DASHBOARD_BASE="${HERMES_DASHBOARD_URL:-http://$BASE_HOST:$DASHBOARD_PORT}"
  BRIDGE_BASE="${HERMES_BRIDGE_URL:-http://$BASE_HOST:$BRIDGE_PORT}"
  BIND_HOST="${HERMES_SERVICE_BIND_HOST:-0.0.0.0}"
else
  DASHBOARD_BASE="${HERMES_DASHBOARD_URL:-$GATEWAY_BASE}"
  BRIDGE_BASE="${HERMES_BRIDGE_URL:-$GATEWAY_BASE}"
  BIND_HOST="${HERMES_SERVICE_BIND_HOST:-127.0.0.1}"
fi
case "$BIND_HOST" in
  0.0.0.0|127.0.0.1) ;;
  *) echo "ERROR: HERMES_SERVICE_BIND_HOST must be 0.0.0.0 or 127.0.0.1."; exit 1 ;;
esac

# Setup and the pair-only command share this installed, fail-closed verifier.
# It validates JSON identity and authentication instead of an open TCP socket.
cat > "$PROBE" <<'PY'
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
PY
chmod 700 "$PROBE"

wait_probe() {
  kind="$1"
  base="$2"
  seconds="$3"
  expected="${4:-}"
  mode="${5:-}"
  i=0
  while [ "$i" -lt "$seconds" ]; do
    if "$VP" "$PROBE" "$kind" "$base" "$KEY" "$expected" "$mode" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  "$VP" "$PROBE" "$kind" "$base" "$KEY" "$expected" "$mode" || true
  return 1
}

setup_step "Verifying Mobile Bridge release"

# Verified Bridge release: closed manifest, exact size/hash/version, compile,
# backup and atomic swap. No bytes execute before every check passes.
NEW="$TARGET.new"
MANIFEST="$HH/bridge-release.json.new"
SYSTEMD_STAGE=""
SYSTEMD_GATEWAY_PENDING=0
SYSTEMD_GATEWAY_HAD_UNIT=0
SYSTEMD_GATEWAY_HAD_DROPIN=0
SYSTEMD_USER_DIR=""
SYSTEMD_GATEWAY_DROPIN_DIR=""
rollback_pending_systemd_gateway() {
  [ "$SYSTEMD_GATEWAY_PENDING" -eq 1 ] || return 0
  rm -f \
    "$SYSTEMD_USER_DIR/hermes-gateway.service.new" \
    "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf.new"
  if [ "$SYSTEMD_GATEWAY_HAD_UNIT" -eq 1 ]; then
    cp -p "$SYSTEMD_STAGE/hermes-gateway.service.previous" \
      "$SYSTEMD_USER_DIR/hermes-gateway.service"
  else
    rm -f "$SYSTEMD_USER_DIR/hermes-gateway.service"
  fi
  if [ "$SYSTEMD_GATEWAY_HAD_DROPIN" -eq 1 ]; then
    cp -p "$SYSTEMD_STAGE/hermes-gateway-network.conf.previous" \
      "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf"
  else
    rm -f "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf"
    rmdir "$SYSTEMD_GATEWAY_DROPIN_DIR" 2>/dev/null || true
  fi
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  SYSTEMD_GATEWAY_PENDING=0
}
cleanup_systemd_stage() {
  [ -n "$SYSTEMD_STAGE" ] || return 0
  rm -f \
    "$SYSTEMD_STAGE/hermes-gateway.service.d/10-hermes-console-network.conf" \
    "$SYSTEMD_STAGE/hermes-gateway.service" \
    "$SYSTEMD_STAGE/hermes-dashboard.service" \
    "$SYSTEMD_STAGE/hermes-bridge.service" \
    "$SYSTEMD_STAGE/hermes-gateway.service.previous" \
    "$SYSTEMD_STAGE/hermes-gateway-network.conf.previous"
  rmdir "$SYSTEMD_STAGE/hermes-gateway.service.d" 2>/dev/null || true
  rmdir "$SYSTEMD_STAGE" 2>/dev/null || true
  SYSTEMD_STAGE=""
}
cleanup_downloads() {
  rm -f "$NEW" "$MANIFEST"
  rollback_pending_systemd_gateway
  cleanup_systemd_stage
}
curl -fsSL "$REPO_RAW/bridge-release.json" -o "$MANIFEST"
curl -fsSL "$REPO_RAW/hermes_bridge.py" -o "$NEW"
# bash 3.2 (el /bin/sh de macOS) no salta el cuerpo de un heredoc al buscar el
# cierre de $( ... ): cualquier ")" del cuerpo lo desincroniza y el parser se
# pierde. El verificador se escribe a fichero y se invoca sin anidar nada.
BRIDGE_VERIFY_SCRIPT="$SERVICES/bridge-release-check.py"
cat > "$BRIDGE_VERIFY_SCRIPT" <<'PY'
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
print(version)
PY
BRIDGE_VERSION="$("$VP" "$BRIDGE_VERIFY_SCRIPT" "$MANIFEST" "$NEW")"
chmod 600 "$NEW"
"$VP" -m py_compile "$NEW"
if [ -f "$TARGET" ]; then
  cp -p "$TARGET" "$BACKUP"
else
  rm -f "$BACKUP"
fi
mv "$NEW" "$TARGET"

printf 'BRIDGE_HOST=%s\nBRIDGE_PORT=%s\nBRIDGE_SCOPES=read,memory,soul,skills,cron,config,command\nBRIDGE_READ_ONLY=false\nBRIDGE_TOKEN=%s\n' "$BIND_HOST" "$BRIDGE_PORT" "$KEY" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

cat > "$GATEWAY_RUNNER" <<EOF
#!/bin/sh
export HERMES_HOME="$HH"
export API_SERVER_HOST="$BIND_HOST"
export API_SERVER_PORT="$GATEWAY_PORT"
cd "$HH"
exec "$HB" gateway run --replace
EOF
cat > "$DASHBOARD_RUNNER" <<EOF
#!/bin/sh
export HERMES_HOME="$HH"
cd "$HH"
exec "$HB" dashboard --host "$BIND_HOST" --port "$DASHBOARD_PORT" --no-open
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

# Portable lifecycle helper. It only signals a PID through pidfd after its
# kernel start time and executable match the identity captured at startup.
cat > "$HELPER" <<'HELPER_EOF'
#!/bin/sh
set -eu
ACTION="${1:-}"
NAME="${2:-}"
case "$NAME" in
  gateway) RUNNER="__GATEWAY_RUNNER__"; EXPECTED_ONE="__VP__"; EXPECTED_TWO="__HB__" ;;
  dashboard) RUNNER="__DASHBOARD_RUNNER__"; EXPECTED_ONE="__VP__"; EXPECTED_TWO="__HB__" ;;
  bridge) RUNNER="__BRIDGE_RUNNER__"; EXPECTED_ONE="__VP__"; EXPECTED_TWO="__VP__" ;;
  *) exit 2 ;;
esac
PIDFILE="__SERVICES__/$NAME.pid"
STARTFILE="__SERVICES__/$NAME.start"
EXEFILE="__SERVICES__/$NAME.exe"
LOGFILE="__LOGS__/$NAME.log"
remove_identity() {
  rm -f "$PIDFILE" "$STARTFILE" "$EXEFILE"
}
process_identity() {
  "__VP__" - "$1" <<'PY'
import os, sys
pid = int(sys.argv[1])
with open(f"/proc/{pid}/stat", encoding="ascii") as source:
    rest = source.read().rstrip().rsplit(") ", 1)[1].split()
print(rest[19])
print(os.path.realpath(f"/proc/{pid}/exe"))
PY
}
signal_owned() {
  "__VP__" - "$1" "$2" "$3" <<'PY'
import os, signal, sys
pid = int(sys.argv[1])
expected_start, expected_exe = sys.argv[2:]
pidfd = os.pidfd_open(pid)
try:
    with open(f"/proc/{pid}/stat", encoding="ascii") as source:
        rest = source.read().rstrip().rsplit(") ", 1)[1].split()
    actual_start = rest[19]
    actual_exe = os.path.realpath(f"/proc/{pid}/exe")
    if actual_start != expected_start or actual_exe != expected_exe:
        raise RuntimeError("process identity changed")
    signal.pidfd_send_signal(pidfd, signal.SIGTERM)
finally:
    os.close(pidfd)
PY
}
stop_service() {
  [ -f "$PIDFILE" ] || return 0
  PID="$(sed -n '1p' "$PIDFILE" 2>/dev/null || true)"
  case "$PID" in *[!0-9]*|'') remove_identity; return 0 ;; esac
  if ! kill -0 "$PID" 2>/dev/null; then
    remove_identity
    return 0
  fi
  RECORDED_START="$(sed -n '1p' "$STARTFILE" 2>/dev/null || true)"
  RECORDED_EXE="$(sed -n '1p' "$EXEFILE" 2>/dev/null || true)"
  CURRENT="$(process_identity "$PID" 2>/dev/null || true)"
  CURRENT_START="$(printf '%s\n' "$CURRENT" | sed -n '1p')"
  CURRENT_EXE="$(printf '%s\n' "$CURRENT" | sed -n '2p')"
  if [ -z "$RECORDED_START" ] || [ -z "$RECORDED_EXE" ] || \
     [ "$CURRENT_START" != "$RECORDED_START" ] || \
     [ "$CURRENT_EXE" != "$RECORDED_EXE" ]; then
    echo "Refusing to stop PID $PID: exact Hermes $NAME ownership is not proven." >&2
    exit 3
  fi
  if ! signal_owned "$PID" "$RECORDED_START" "$RECORDED_EXE" 2>/dev/null; then
    echo "Refusing to stop PID $PID: atomic process identity verification is unavailable." >&2
    exit 3
  fi
  i=0
  while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 5 ]; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$PID" 2>/dev/null; then
    echo "Hermes $NAME did not stop cleanly; refusing to start a duplicate." >&2
    return 1
  fi
  remove_identity
}
start_service() {
  if [ -f "$PIDFILE" ]; then
    TRACKED="$(sed -n '1p' "$PIDFILE" 2>/dev/null || true)"
    case "$TRACKED" in
      *[!0-9]*|'') remove_identity ;;
      *)
        if kill -0 "$TRACKED" 2>/dev/null; then
          echo "Refusing to overwrite the live Hermes $NAME process identity." >&2
          return 1
        fi
        remove_identity
        ;;
    esac
  fi
  nohup "$RUNNER" >> "$LOGFILE" 2>&1 </dev/null &
  PID="$!"
  SPAWN_IDENTITY="$(process_identity "$PID" 2>/dev/null || true)"
  SPAWN_START="$(printf '%s\n' "$SPAWN_IDENTITY" | sed -n '1p')"
  EXPECTED_ONE_REAL="$("__VP__" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$EXPECTED_ONE")"
  EXPECTED_TWO_REAL="$("__VP__" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$EXPECTED_TWO")"
  i=0
  while [ "$i" -lt 5 ]; do
    IDENTITY="$(process_identity "$PID" 2>/dev/null || true)"
    START="$(printf '%s\n' "$IDENTITY" | sed -n '1p')"
    EXE="$(printf '%s\n' "$IDENTITY" | sed -n '2p')"
    if [ -n "$SPAWN_START" ] && [ "$START" = "$SPAWN_START" ] && \
       { [ "$EXE" = "$EXPECTED_ONE_REAL" ] || [ "$EXE" = "$EXPECTED_TWO_REAL" ]; }; then
      printf '%s\n' "$PID" > "$PIDFILE.new"
      printf '%s\n' "$START" > "$STARTFILE.new"
      printf '%s\n' "$EXE" > "$EXEFILE.new"
      chmod 600 "$PIDFILE.new" "$STARTFILE.new" "$EXEFILE.new"
      mv "$PIDFILE.new" "$PIDFILE"
      mv "$STARTFILE.new" "$STARTFILE"
      mv "$EXEFILE.new" "$EXEFILE"
      return 0
    fi
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
    i=$((i + 1))
  done
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  echo "Hermes $NAME process identity could not be captured; refusing unmanaged startup." >&2
  return 1
}
case "$ACTION" in
  start) start_service ;;
  stop) stop_service ;;
  restart) stop_service; start_service ;;
  *) exit 2 ;;
esac
HELPER_EOF
# El cuerpo se escribe como datos y se sustituye despues. Un heredoc sin citar que
# contiene otro heredoc y parentesis sin compensar (el helper portable) rompe el
# parser de bash 3.2, que es el /bin/sh de macOS: el script ni siquiera parseaba.
"$VP" - "$HELPER" "$VP" "$HB" "$GATEWAY_RUNNER" "$DASHBOARD_RUNNER" "$BRIDGE_RUNNER" "$SERVICES" "$LOGS" <<'PY'
import pathlib, sys

path = sys.argv[1]
pairs = (
    ("__VP__", sys.argv[2]),
    ("__HB__", sys.argv[3]),
    ("__GATEWAY_RUNNER__", sys.argv[4]),
    ("__DASHBOARD_RUNNER__", sys.argv[5]),
    ("__BRIDGE_RUNNER__", sys.argv[6]),
    ("__SERVICES__", sys.argv[7]),
    ("__LOGS__", sys.argv[8]),
)
text = pathlib.Path(path).read_text(encoding="utf-8")
for token, value in pairs:
    text = text.replace(token, value)
pathlib.Path(path).write_text(text, encoding="utf-8")
PY
chmod 700 "$HELPER"

install_systemd_unit() {
  name="$1"
  runner="$2"
  unit_dir="$3"
  unit="$unit_dir/hermes-$name.service"
  mkdir -p "$unit_dir"
  "$VP" - "$unit" "$name" "$runner" "$HH" <<'PY'
import pathlib, sys

unit, name, runner, workdir = sys.argv[1:]


def specifiers(value):
    return value.replace("%", "%%")


def exec_argument(value):
    escaped = specifiers(value).replace("\\", "\\\\").replace('"', '\\"')
    return '"' + escaped + '"'


def directive_path(value):
    out = []
    for character in specifiers(value):
        codepoint = ord(character)
        if character == "\\":
            out.append("\\x5c")
        elif character == " ":
            out.append("\\x20")
        elif character == '"':
            out.append("\\x22")
        elif codepoint < 0x20 or codepoint == 0x7f:
            out.append(f"\\x{codepoint:02x}")
        else:
            out.append(character)
    return "".join(out)


payload = f"""[Unit]
Description=Hermes Console {name}
After=network-online.target
Wants=network-online.target
[Service]
ExecStart={exec_argument(runner)}
WorkingDirectory={directive_path(workdir)}
Restart=on-failure
RestartSec=2
[Install]
WantedBy=default.target
"""
pathlib.Path(unit).write_text(payload, encoding="utf-8")
PY
}

stage_gateway_systemd_unit() {
  if ! "$VP" - "$SYSTEMD_STAGE/hermes-gateway.service" <<'PY'
import pathlib, sys

from hermes_cli.gateway import generate_systemd_unit

path = pathlib.Path(sys.argv[1])
unit = generate_systemd_unit(system=False)
if not unit.startswith("[Unit]\n") or "hermes_cli.main" not in unit:
    raise SystemExit("Hermes generated an invalid gateway user unit")
path.write_text(unit, encoding="utf-8")
PY
  then
    echo "ERROR: Hermes could not generate its canonical gateway user unit."
    return 1
  fi
  mkdir -p "$SYSTEMD_STAGE/hermes-gateway.service.d"
  cat > "$SYSTEMD_STAGE/hermes-gateway.service.d/10-hermes-console-network.conf" <<EOF
[Service]
Environment="API_SERVER_HOST=$BIND_HOST"
Environment="API_SERVER_PORT=$GATEWAY_PORT"
EOF
  chmod 644 \
    "$SYSTEMD_STAGE/hermes-gateway.service" \
    "$SYSTEMD_STAGE/hermes-gateway.service.d/10-hermes-console-network.conf"
}

install_verified_systemd_units() {
  preflight_service_ownership
  SYSTEMD_STAGE="$(mktemp -d "$SERVICES/systemd-units.XXXXXX")"
  stage_gateway_systemd_unit
  install_systemd_unit dashboard "$DASHBOARD_RUNNER" "$SYSTEMD_STAGE"
  install_systemd_unit bridge "$BRIDGE_RUNNER" "$SYSTEMD_STAGE"

  if command -v systemd-analyze >/dev/null 2>&1; then
    if ! systemd-analyze --user verify \
      "$SYSTEMD_STAGE/hermes-gateway.service" \
      "$SYSTEMD_STAGE/hermes-dashboard.service" \
      "$SYSTEMD_STAGE/hermes-bridge.service"; then
      echo "ERROR: generated systemd user units are invalid; existing units were not replaced."
      rollback_pending_systemd_gateway
      cleanup_systemd_stage
      exit 1
    fi
  else
    echo "WARNING: systemd-analyze is unavailable; skipping the unit-file preflight."
  fi

  SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
  SYSTEMD_GATEWAY_DROPIN_DIR="$SYSTEMD_USER_DIR/hermes-gateway.service.d"
  mkdir -p "$SYSTEMD_USER_DIR" "$SYSTEMD_GATEWAY_DROPIN_DIR"
  SYSTEMD_GATEWAY_HAD_UNIT=0
  if [ -f "$SYSTEMD_USER_DIR/hermes-gateway.service" ]; then
    SYSTEMD_GATEWAY_HAD_UNIT=1
    cp -p "$SYSTEMD_USER_DIR/hermes-gateway.service" \
      "$SYSTEMD_STAGE/hermes-gateway.service.previous"
  fi
  SYSTEMD_GATEWAY_HAD_DROPIN=0
  if [ -f "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf" ]; then
    SYSTEMD_GATEWAY_HAD_DROPIN=1
    cp -p "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf" \
      "$SYSTEMD_STAGE/hermes-gateway-network.conf.previous"
  fi
  SYSTEMD_GATEWAY_PENDING=1

  cp "$SYSTEMD_STAGE/hermes-gateway.service" \
    "$SYSTEMD_USER_DIR/hermes-gateway.service.new"
  chmod 644 "$SYSTEMD_USER_DIR/hermes-gateway.service.new"
  mv "$SYSTEMD_USER_DIR/hermes-gateway.service.new" \
    "$SYSTEMD_USER_DIR/hermes-gateway.service"
  cp "$SYSTEMD_STAGE/hermes-gateway.service.d/10-hermes-console-network.conf" \
    "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf.new"
  chmod 644 "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf.new"
  mv "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf.new" \
    "$SYSTEMD_GATEWAY_DROPIN_DIR/10-hermes-console-network.conf"

  for name in dashboard bridge; do
    cp "$SYSTEMD_STAGE/hermes-$name.service" \
      "$SYSTEMD_USER_DIR/hermes-$name.service.new"
    chmod 644 "$SYSTEMD_USER_DIR/hermes-$name.service.new"
    mv "$SYSTEMD_USER_DIR/hermes-$name.service.new" \
      "$SYSTEMD_USER_DIR/hermes-$name.service"
  done
  SYSTEMD_GATEWAY_PENDING=0
  cleanup_systemd_stage
}

install_launchd_job() {
  name="$1"
  label="$2"
  runner="$3"
  run_at_load="$4"
  start_now="$5"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  assert_launchd_plist_owner "$label"
  assert_loaded_launchd_job_owner "$label"
  mkdir -p "$HOME/Library/LaunchAgents"
  plist_new="$plist.new"
  rm -f "$plist_new"
  "$VP" - "$plist_new" "$label" "$runner" "$HH" "$LOGS/$name.log" "$run_at_load" <<'PY'
import pathlib, plistlib, sys
path, label, runner, workdir, log, run_at_load = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": [runner],
    "WorkingDirectory": workdir,
    "RunAtLoad": run_at_load == "yes",
    "KeepAlive": {"SuccessfulExit": False},
    "ProcessType": "Background",
    "StandardOutPath": log,
    "StandardErrorPath": log,
}
with pathlib.Path(path).open("xb") as out:
    plistlib.dump(payload, out, sort_keys=True)
PY
  chmod 600 "$plist_new"
  assert_loaded_launchd_job_owner "$label"
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  mv "$plist_new" "$plist"
  launchctl bootstrap "gui/$(id -u)" "$plist"
  launchctl enable "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  [ "$start_now" != "yes" ] || launchctl kickstart -k "gui/$(id -u)/$label"
}

assert_named_service_owner() {
  name="$1"
  case "$SERVICE_MANAGER" in
    systemd) assert_systemd_unit_owner "hermes-$name.service" ;;
    launchd)
      label="dev.xpetalab.hermes-console.$name"
      assert_launchd_plist_owner "$label" && assert_loaded_launchd_job_owner "$label"
      ;;
    portable) return 0 ;;
    *) return 1 ;;
  esac
}

start_named_service() {
  name="$1"
  assert_named_service_owner "$name"
  case "$SERVICE_MANAGER" in
    systemd) systemctl --user restart "hermes-$name" ;;
    launchd)
      case "$name" in
        gateway) label="dev.xpetalab.hermes-console.gateway" ;;
        dashboard) label="dev.xpetalab.hermes-console.dashboard" ;;
        bridge) label="dev.xpetalab.hermes-console.bridge" ;;
      esac
      if ! launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
        plist="$HOME/Library/LaunchAgents/$label.plist"
        launchctl bootstrap "gui/$(id -u)" "$plist"
      fi
      launchctl kickstart -k "gui/$(id -u)/$label"
      ;;
    portable) "$HELPER" restart "$name" ;;
  esac
}

stop_named_service() {
  name="$1"
  assert_named_service_owner "$name"
  case "$SERVICE_MANAGER" in
    systemd) systemctl --user stop "hermes-$name" ;;
    launchd)
      case "$name" in
        gateway) label="dev.xpetalab.hermes-console.gateway" ;;
        dashboard) label="dev.xpetalab.hermes-console.dashboard" ;;
        bridge) label="dev.xpetalab.hermes-console.bridge" ;;
        *) return 2 ;;
      esac
      launchctl bootout "gui/$(id -u)/$label"
      ;;
    portable) "$HELPER" stop "$name" ;;
  esac
}

setup_step "Installing hidden persistent services"

SERVICE_LIFECYCLE_TOUCHED=1
case "$SERVICE_MANAGER" in
  systemd)
    install_verified_systemd_units
    systemctl --user daemon-reload
    systemctl --user enable hermes-gateway hermes-dashboard hermes-bridge >/dev/null 2>&1
    systemctl --user restart hermes-gateway
    systemctl --user restart hermes-bridge
    ;;
  launchd)
    install_launchd_job gateway dev.xpetalab.hermes-console.gateway "$GATEWAY_RUNNER" yes yes
    install_launchd_job dashboard dev.xpetalab.hermes-console.dashboard "$DASHBOARD_RUNNER" yes no
    install_launchd_job bridge dev.xpetalab.hermes-console.bridge "$BRIDGE_RUNNER" yes yes
    ;;
  portable)
    "$HELPER" restart gateway
    "$HELPER" restart bridge
    echo "WARNING: no supported persistent service manager is available."
    echo "Services work in this session but will not survive a reboot until a startup manager is configured."
    ;;
esac

if ! wait_probe gateway "http://127.0.0.1:$GATEWAY_PORT" 40; then
  service_failure Gateway "$GATEWAY_PORT"
fi
echo "Gateway identity + valid-token + auth-rejection checks OK ($SERVICE_MANAGER)"

if ! wait_probe bridge "http://127.0.0.1:$BRIDGE_PORT" 40 "$BRIDGE_VERSION"; then
  service_failure Bridge "$BRIDGE_PORT"
fi
echo "Mobile Bridge $BRIDGE_VERSION valid-token + auth-rejection + capability checks OK ($SERVICE_MANAGER)"

setup_step "Checking Dashboard and credentials"

# Ensure a strong initial Dashboard password through the authenticated Bridge.
# Existing credentials are preserved on repair/update; setup never prints them.
if ! stop_named_service dashboard >/dev/null 2>&1; then
  echo "ERROR: Dashboard ownership could not be proven before stopping it."
  exit 1
fi
DASH_PASS="$("$VP" -c 'import secrets; print(secrets.token_urlsafe(24))')"
DASHBOARD_CREDENTIAL_RESULT=""
if ! DASHBOARD_CREDENTIAL_RESULT="$("$VP" - "http://127.0.0.1:$BRIDGE_PORT" "$KEY" "$DASH_PASS" <<'PY'
import json, sys, urllib.request

base, token, password = sys.argv[1:]
headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
created = False


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, url):
        return None


opener = urllib.request.build_opener(NoRedirect)
try:
    request = urllib.request.Request(
        base + "/bridge/dashboard/credentials", headers=headers
    )
    with opener.open(request, timeout=65) as response:
        status = response.status
        value = json.loads(response.read(1024 * 1024).decode())
    if status != 200 or value.get("ok") is not True:
        raise RuntimeError("credential endpoint rejected the read")
    username = value.get("username") or "admin"
    if value.get("password_set") is not True:
        body = json.dumps(
            {"username": username, "password": password}
        ).encode()
        request = urllib.request.Request(
            base + "/bridge/dashboard/credentials",
            data=body,
            headers={
                "Authorization": "Bearer " + token,
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with opener.open(request, timeout=65) as response:
            status = response.status
            value = json.loads(response.read(1024 * 1024).decode())
        if status != 200 or value.get("ok") is not True:
            raise RuntimeError("credential endpoint rejected the change")
        username = value.get("username") or username
        created = True
except Exception as exc:
    print(
        "Dashboard credential setup failed: " + type(exc).__name__,
        file=sys.stderr,
    )
    raise SystemExit(1)
print(json.dumps({"created": created, "username": username}))
PY
)"; then
  echo "ERROR: Dashboard authentication could not be configured; no pairing QR will be shown."
  exit 1
fi
DASHBOARD_LOGIN_CREATED="$("$VP" -c 'import json,sys; print("1" if json.loads(sys.argv[1])["created"] else "0")' "$DASHBOARD_CREDENTIAL_RESULT")"
DASHBOARD_LOGIN_USER="$("$VP" -c 'import json,sys; print(json.loads(sys.argv[1])["username"])' "$DASHBOARD_CREDENTIAL_RESULT")"
if ! start_named_service dashboard >/dev/null 2>&1; then
  echo "ERROR: Dashboard ownership could not be proven before starting it."
  exit 1
fi
# El primer arranque compila el Dashboard (npm/Vite). En un host lento, con el
# disco ocupado o con antivirus revisando node_modules, una espera fija reporta un
# fallo falso. Se extiende mientras el log del servicio siga creciendo (progreso
# real), con techo de 30 minutos y rastro explicito; si deja de crecer, se falla.
dashboard_ready=0
dashboard_elapsed=0
dashboard_last_size=0
while [ "$dashboard_elapsed" -lt 1800 ]; do
  if wait_probe dashboard "http://127.0.0.1:$DASHBOARD_PORT" 5; then
    dashboard_ready=1
    break
  fi
  dashboard_elapsed=$((dashboard_elapsed + 5))
  if [ "$dashboard_elapsed" -lt 60 ]; then
    continue
  fi
  dashboard_size=0
  if [ -f "$LOGS/dashboard.log" ]; then
    dashboard_size=$(wc -c < "$LOGS/dashboard.log" 2>/dev/null | tr -d ' ')
  fi
  case "$dashboard_size" in ''|*[!0-9]*) dashboard_size=0 ;; esac
  if [ "$dashboard_size" -le "$dashboard_last_size" ]; then
    break
  fi
  dashboard_last_size="$dashboard_size"
  if [ $((dashboard_elapsed % 60)) -eq 0 ]; then
    echo "Dashboard still starting (${dashboard_elapsed}s): its log keeps growing; waiting up to 1800s"
  fi
done
if [ "$dashboard_ready" -ne 1 ]; then
  service_failure Dashboard "$DASHBOARD_PORT"
fi
if ! "$VP" - "http://127.0.0.1:$DASHBOARD_PORT" "$DASHBOARD_LOGIN_CREATED" "$DASHBOARD_LOGIN_USER" "$DASH_PASS" <<'PY_DASH_AUTH'
import json, sys, urllib.error, urllib.request

base, created, username, password = sys.argv[1:]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, url):
        return None


opener = urllib.request.build_opener(NoRedirect)


def request(path, headers=None, data=None):
    value = urllib.request.Request(base + path, headers=headers or {}, data=data)
    try:
        with opener.open(value, timeout=6) as response:
            return response.status, response.headers, response.read(1024 * 1024)
    except urllib.error.HTTPError as exc:
        return exc.code, exc.headers, exc.read(1024 * 1024)


protected = "/api/model/options"
for label, cookie in (
    ("missing", None),
    ("invalid", "hermes_session_at=invalid-dashboard-session"),
):
    headers = {"Accept": "application/json"}
    if cookie is not None:
        headers["Cookie"] = cookie
    status, _, _ = request(protected, headers=headers)
    if status not in {401, 403}:
        raise SystemExit(
            f"Dashboard protected API did not reject {label} session (HTTP {status})"
        )

if created == "1":
    body = json.dumps(
        {"provider": "basic", "username": username, "password": password}
    ).encode()
    status, headers, _ = request(
        "/auth/password-login",
        headers={"Content-Type": "application/json"},
        data=body,
    )
    if status != 200:
        raise SystemExit(f"Dashboard password login returned HTTP {status}")
    cookies = headers.get_all("Set-Cookie") or []
    pairs = []
    for raw in cookies:
        pairs.append(raw.split(";", 1)[0])
    if not any(item.split("=", 1)[0].endswith("hermes_session_at") for item in pairs):
        raise SystemExit("Dashboard password login did not return an access-session cookie")
    status, _, raw = request(
        protected,
        headers={"Accept": "application/json", "Cookie": "; ".join(pairs)},
    )
    if status != 200:
        raise SystemExit(f"Dashboard authenticated protected API returned HTTP {status}")
    try:
        value = json.loads(raw.decode("utf-8"))
    except Exception:
        raise SystemExit("Dashboard authenticated protected API did not return JSON") from None
    if not isinstance(value, dict):
        raise SystemExit("Dashboard authenticated protected API returned the wrong JSON shape")
PY_DASH_AUTH
then
  echo "ERROR: Dashboard protected-route authentication checks failed; no pairing QR will be shown."
  exit 1
fi
if [ "$DASHBOARD_LOGIN_CREATED" = "1" ]; then
  echo "Dashboard password login + protected API enforcement OK ($SERVICE_MANAGER)"
else
  echo "Dashboard public health + protected API enforcement OK ($SERVICE_MANAGER); existing login was preserved, not replayed"
fi

SUDO_READY=0
run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    if [ "$SUDO_READY" = 1 ] || sudo -n true >/dev/null 2>&1; then
      SUDO_READY=1
      sudo -n "$@"
      return
    fi
    # `curl ... | sh` occupies stdin with the script itself. Read the sudo
    # password from the controlling terminal so an ordinary interactive user
    # can finish firewall setup in one run. Agents/non-interactive shells still
    # fail closed and receive the exact manual commands below.
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
      echo "Hermes Console needs administrator approval for a private firewall rule." >/dev/tty
      if sudo -v; then
        SUDO_READY=1
        sudo -n "$@"
        return
      fi
    fi
  fi
  return 126
}

ensure_private_firewall() {
  [ "$PAIR_SCHEME" = "http" ] || return 0
  if command -v ufw >/dev/null 2>&1; then
    UFW_ACTIVE=""
    if [ -r /etc/ufw/ufw.conf ] && grep -Eqi '^ENABLED=yes' /etc/ufw/ufw.conf; then
      UFW_ACTIVE=1
    else
      UFW_STATUS="$(run_privileged ufw status 2>/dev/null || true)"
      if printf '%s\n' "$UFW_STATUS" | grep -qi '^Status: active'; then UFW_ACTIVE=1; fi
    fi
    if [ -n "$UFW_ACTIVE" ]; then
      UFW_STATUS="$(run_privileged ufw status 2>/dev/null || true)"
      for port in "$GATEWAY_PORT" "$DASHBOARD_PORT" "$BRIDGE_PORT"; do
        if printf '%s\n' "$UFW_STATUS" | grep -E "^${port}/tcp[[:space:]]" | \
            grep -F "$FIREWALL_SOURCE" >/dev/null 2>&1; then
          continue
        fi
        if ! run_privileged ufw allow from "$FIREWALL_SOURCE" to any port "$port" proto tcp comment 'Hermes Console' >/dev/null; then
          echo "ERROR: UFW is active and a private rule could not be installed."
          echo "Run these commands, then rerun setup:"
          echo "  sudo ufw allow from $FIREWALL_SOURCE to any port $GATEWAY_PORT proto tcp"
          echo "  sudo ufw allow from $FIREWALL_SOURCE to any port $DASHBOARD_PORT proto tcp"
          echo "  sudo ufw allow from $FIREWALL_SOURCE to any port $BRIDGE_PORT proto tcp"
          return 1
        fi
        printf '%s\n' "$port" >> "$TRANSACTION_DIR/ufw.added"
      done
      echo "UFW rules verified for private source $FIREWALL_SOURCE"
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for port in "$GATEWAY_PORT" "$DASHBOARD_PORT" "$BRIDGE_PORT"; do
      rule="rule family=ipv4 source address=$FIREWALL_SOURCE port port=$port protocol=tcp accept"
      if run_privileged firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1; then
        continue
      fi
      if ! run_privileged firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null; then
        echo "ERROR: firewalld is active and a private rule could not be installed."
        echo "Add private TCP rules for $GATEWAY_PORT, $DASHBOARD_PORT and $BRIDGE_PORT from $FIREWALL_SOURCE, then rerun setup."
        return 1
      fi
      printf '%s\n' "$rule" >> "$TRANSACTION_DIR/firewalld.added"
    done
    run_privileged firewall-cmd --reload >/dev/null
    echo "firewalld rules verified for private source $FIREWALL_SOURCE"
  fi
}

setup_step "Verifying private phone access"

ensure_private_firewall

# Decisive gate: use exactly the URLs encoded in the QR. A loopback-only bind,
# wrong listener, bad token, broken reverse proxy or dead Dashboard stops here.
if ! wait_probe gateway "$GATEWAY_BASE" 12 "" phone; then
  echo "ERROR: Gateway works locally but not through $GATEWAY_BASE."
  echo "Check bind, VPN/LAN routing, reverse proxy and host/cloud firewall."
  exit 1
fi
if ! wait_probe bridge "$BRIDGE_BASE" 12 "$BRIDGE_VERSION" phone; then
  echo "ERROR: Mobile Bridge works locally but not through $BRIDGE_BASE."
  echo "Check routing/proxy rules for /bridge/*."
  exit 1
fi
if ! wait_probe dashboard "$DASHBOARD_BASE" 12 "" phone; then
  echo "ERROR: Dashboard works locally but not through $DASHBOARD_BASE."
  echo "Check routing/proxy rules for /api/status."
  exit 1
fi

setup_step "Generating pairing QR and summary"

printf 'PAIRING_SCHEMA=1\nPROBE_SECURITY_SCHEMA=2\nPAIR_HOST=%s\nPAIR_SCHEME=%s\nPAIR_PORT=%s\nGATEWAY_BASE=%s\nDASHBOARD_BASE=%s\nBRIDGE_BASE=%s\nNETWORK_KIND=%s\nPYTHON_BIN=%s\n' \
  "$HOST" "$PAIR_SCHEME" "$PAIR_PORT" "$GATEWAY_BASE" "$DASHBOARD_BASE" "$BRIDGE_BASE" "$NETWORK_KIND" "$VP" > "$PAIR_ENV"
chmod 600 "$PAIR_ENV"

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
elif "$VP" -c 'import qrcode' 2>/dev/null && "$VP" -c "$QRPY" "$LINK" 2>/dev/null; then
  QR_RENDERED=1
else
  UV="$HH/bin/uv"
  [ -x "$UV" ] || UV="$(command -v uv 2>/dev/null || true)"
  if [ -n "$UV" ] && "$UV" run --isolated --no-project --no-cache --with qrcode==8.2 \
      python -c "$QRPY" "$LINK" 2>/dev/null; then
    QR_RENDERED=1
  fi
fi
if [ -z "$QR_RENDERED" ]; then
  echo "A QR renderer could not be prepared. Paste the verified link below into Hermes Console."
fi
commit_transaction
echo ""
echo "Link: $LINK"
echo ""
echo "All three services passed their scoped local and phone-address checks."
echo "Setup summary:"
echo "  Hermes Agent: ready"
echo "  Gateway: valid token accepted, missing/invalid tokens rejected, reachable"
echo "  Dashboard: public health and protected-route enforcement checked"
echo "  Mobile Bridge: $BRIDGE_VERSION, valid token accepted, missing/invalid tokens rejected, reachable"
echo "  Service manager: $SERVICE_MANAGER"
echo "  Pairing address: $HOST ($NETWORK_KIND)"
echo "To verify them and show this QR again later:"
echo "  curl -fsSL $REPO_RAW/hermes-pair.sh | sh"
echo "If chat has no model yet, open Dashboard from the app and configure your AI provider/model."
