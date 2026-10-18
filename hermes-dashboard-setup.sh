#!/bin/sh
# Hermes Console - Dashboard-only setup (Linux and macOS).
# On native Windows use hermes-dashboard-setup.ps1 (the same setup, in PowerShell).
#
# A thin complement to the official Hermes installer. It installs nothing,
# downloads nothing and does not touch the Gateway. It does the one thing the
# official installer leaves undone: it keeps the Dashboard on all the time, on
# one LAN or Tailscale address, behind a sign-in, and shows the generated
# password once.
set -eu

# What to do. Piped from curl, an option goes after "sh -s --":
#   curl -fsSL .../hermes-dashboard-setup.sh | sh -s -- --new-access
ACTION="setup"
ACTION_SET=""
PASSWORD_STDIN=0
ALSO_REMOVE_KEY=0
for _hermes_arg in "$@"; do
  _hermes_next=""
  case "$_hermes_arg" in
    --new-access) _hermes_next="new-access" ;;
    --retire-gateway-exposure) _hermes_next="retire-gateway-exposure" ;;
    --retire-bridge) _hermes_next="retire-bridge" ;;
    -h|--help) _hermes_next="help" ;;
    --password-stdin) PASSWORD_STDIN=1 ;;
    --also-remove-api-key) ALSO_REMOVE_KEY=1 ;;
    --password|--password=*)
      # The value is never echoed: a password on a command line is a leak.
      echo "Unknown option: --password"
      echo "A password is never taken from the command line. Use --password-stdin"
      echo "to choose your own, or give none and one is generated."
      exit 2
      ;;
    *)
      echo "Unknown option: ${_hermes_arg%%=*}"
      echo "Run it with --help to see what it can do."
      exit 2
      ;;
  esac
  if [ -n "$_hermes_next" ]; then
    if [ -n "$ACTION_SET" ] && [ "$ACTION_SET" != "$_hermes_next" ]; then
      echo "Choose one action at a time: $ACTION_SET and $_hermes_next were both given."
      exit 2
    fi
    ACTION_SET="$_hermes_next"
    ACTION="$_hermes_next"
  fi
done
if [ "$ALSO_REMOVE_KEY" -eq 1 ] && [ "$ACTION" != "retire-gateway-exposure" ]; then
  echo "--also-remove-api-key only goes with --retire-gateway-exposure."
  exit 2
fi
case "$ACTION" in
  setup|new-access) ;;
  retire-gateway-exposure|retire-bridge|help)
    if [ "$PASSWORD_STDIN" -eq 1 ]; then
      echo "--password-stdin only goes with setup or --new-access."
      exit 2
    fi
    ;;
  *)
    echo "Unknown action: $ACTION"
    exit 2
    ;;
esac
if [ "$ACTION" = "help" ]; then
  echo "Dashboard-only setup for Hermes Agent (a complement to the official installer)"
  echo ""
  echo "  (no option)       Keep the Dashboard on at all times, on your LAN or Tailscale"
  echo "                    address, behind a sign-in. A password is generated and shown once."
  echo "                    A sign-in that already exists is kept as it is."
  echo "  --new-access      Make a new Dashboard password and end the sessions of the old one."
  echo "  --password-stdin  Take the password from the first line of standard input"
  echo "                    instead of generating one (run the saved script, not a pipe)."
  echo "  --retire-gateway-exposure"
  echo "                    Undo what the earlier Console setup added to the Gateway:"
  echo "                    its network address and port and its pairing record. Your"
  echo "                    API key is kept. The Gateway is not stopped."
  echo "  --also-remove-api-key"
  echo "                    With --retire-gateway-exposure only: also remove the API key"
  echo "                    from .env (a private copy is kept). Anything of yours that"
  echo "                    uses that key stops working."
  echo "  --retire-bridge   Stop and remove the old Mobile Bridge. Nothing else is touched."
  exit 0
fi

# The one line that installs Hermes. Nothing here runs it.
OFFICIAL_INSTALL="curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"


case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux*) PLATFORM="linux" ;;
  Darwin*) PLATFORM="macos" ;;
  CYGWIN*|MINGW*|MSYS*)
    echo "Windows native detected. This shell script covers Linux and macOS, so nothing"
    echo "was changed. On Windows run hermes-dashboard-setup.ps1 from Windows PowerShell 5.1 or newer."
    exit 2
    ;;
  *) PLATFORM="unix" ;;
esac

# WSL normally exposes a NAT address that a phone cannot reach. Native
# PowerShell configures the firewall and the startup task, so it is the default.
if [ "$PLATFORM" = "linux" ] && { [ -n "${WSL_INTEROP:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; }; then
  case "$ACTION" in
    setup|new-access)
      if [ -z "${HERMES_DASHBOARD_HOST:-}" ]; then
        echo "WSL detected. Its automatic IP is not reliably reachable from a phone, so"
        echo "nothing was changed. Advanced routed WSL setups may set HERMES_DASHBOARD_HOST"
        echo "explicitly to an address the phone can reach."
        exit 2
      fi
      ;;
  esac
fi

# A password given on standard input is read before anything else happens, so
# that a bad one stops the run with the computer untouched. A script piped into
# sh reads itself from standard input: it would eat its own next lines.
DASH_PASSWORD=""
if [ "$PASSWORD_STDIN" -eq 1 ]; then
  if [ ! -f "$0" ]; then
    echo "--password-stdin needs the script saved to a file and run from it:"
    echo "  sh hermes-dashboard-setup.sh --password-stdin < password-file"
    exit 2
  fi
  IFS= read -r DASH_PASSWORD || true
  DASH_PASSWORD="${DASH_PASSWORD%"$(printf '\r')"}"
  if [ -z "$(printf '%s' "$DASH_PASSWORD" | tr -d '[:space:]')" ]; then
    echo "ERROR: the password on standard input is empty. Nothing was changed." >&2
    exit 1
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
  echo "ERROR: another Hermes home exists at $DEFAULT_HH; refusing an ambiguous choice of $HH." >&2
  exit 1
fi

SETUP_LOCK_HELD=0
SETUP_LOCK_DIR=""
# One setup at a time per user (the lock is shared with hermes-mobile-setup.sh),
# held to the end of the run. The lock is a directory holding the owner's pid: a
# run that was killed outright leaves it behind, and the next run recognises
# that the pid is gone and takes it over. Only a lock whose owner is alive refuses.
acquire_setup_lock() {
  lock_root="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
  if [ ! -d "$lock_root" ]; then
    echo "ERROR: setup lock directory $lock_root does not exist." >&2
    return 1
  fi
  SETUP_LOCK_DIR="$lock_root/hermes-console-setup-$(id -u).lock"
  old_umask="$(umask)"
  umask 077
  lock_try=0
  while ! mkdir "$SETUP_LOCK_DIR" 2>/dev/null; do
    lock_try=$((lock_try + 1))
    lock_owner=""
    lock_wait=0
    # A run that has just made the directory writes its pid a moment later.
    while [ "$lock_wait" -lt 20 ]; do
      lock_owner="$(cat "$SETUP_LOCK_DIR/pid" 2>/dev/null || true)"
      [ -n "$lock_owner" ] && break
      [ -d "$SETUP_LOCK_DIR" ] || break
      sleep 0.1 2>/dev/null || sleep 1
      lock_wait=$((lock_wait + 1))
    done
    if [ -n "$lock_owner" ] && [ "$lock_try" -le 3 ] && \
       ! kill -0 "$lock_owner" 2>/dev/null; then
      # Its owner is gone. Renaming is atomic, so when two runs find the same
      # stale lock only one of them clears it.
      lock_stale="$SETUP_LOCK_DIR.stale.$$"
      if mv "$SETUP_LOCK_DIR" "$lock_stale" 2>/dev/null; then
        rm -rf -- "$lock_stale"
      fi
      continue
    fi
    umask "$old_umask"
    if [ -n "$lock_owner" ]; then
      echo "ERROR: another Console setup is already running for this user (process $lock_owner); nothing was changed." >&2
    elif [ -d "$SETUP_LOCK_DIR" ]; then
      echo "ERROR: another Console setup is already running for this user, or left $SETUP_LOCK_DIR without an owner; nothing was changed." >&2
    else
      echo "ERROR: another Console setup is already running for this user." >&2
    fi
    return 1
  done
  umask "$old_umask"
  printf '%s\n' "$$" > "$SETUP_LOCK_DIR/pid" 2>/dev/null || true
  SETUP_LOCK_HELD=1
}

release_setup_lock() {
  [ "$SETUP_LOCK_HELD" -eq 1 ] || return 0
  rm -f "$SETUP_LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$SETUP_LOCK_DIR" 2>/dev/null || true
  SETUP_LOCK_HELD=0
}

WORK=""
cleanup_setup() {
  setup_exit_status=$?
  # No exit is silent: whatever stopped the run, the step it stopped in and the
  # exit code are said before anything is rolled back.
  if [ "$setup_exit_status" -ne 0 ] && [ "${TRANSACTION_PENDING:-0}" -eq 1 ]; then
    echo "Setup stopped during \"${SETUP_PROGRESS_LABEL:-startup}\" (exit code $setup_exit_status); changes made so far are being rolled back." >&2
  fi
  if command -v rollback_transaction >/dev/null 2>&1; then
    rollback_transaction
  fi
  if [ -n "$WORK" ]; then rm -rf -- "$WORK"; fi
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

DASH_UNIT="$HOME/.config/systemd/user/hermes-dashboard.service"
DASH_LABEL="dev.xpetalab.hermes-console.dashboard"
DASH_PLIST="$HOME/Library/LaunchAgents/$DASH_LABEL.plist"

# The Dashboard definition this setup writes is the one the earlier setup wrote
# (same names), so it is replaced in place. Ownership is proven first; a
# definition that belongs to another Hermes home is never replaced.
preflight_service_ownership() {
  case "$SERVICE_MANAGER" in
    systemd)
      assert_systemd_unit_owner hermes-dashboard.service || return 1
      [ ! -e "$DASH_PLIST" ] || {
        echo "ERROR: stale launchd definition $DASH_LABEL conflicts with systemd; refusing." >&2
        return 1
      }
      ;;
    launchd)
      assert_launchd_plist_owner "$DASH_LABEL" || return 1
      assert_loaded_launchd_job_owner "$DASH_LABEL" || return 1
      [ ! -e "$DASH_UNIT" ] || {
        echo "ERROR: stale systemd definition hermes-dashboard.service conflicts with launchd; refusing." >&2
        return 1
      }
      ;;
  esac
}

select_service_manager

# LEGACY: cleanup of Mobile Bridge setups made before Console 1.2.15
# (--retire-bridge is all that touches it). Removed with Console 1.2.17.
BRIDGE_SYSTEMD_UNIT="$HOME/.config/systemd/user/hermes-bridge.service"
BRIDGE_LAUNCHD_LABEL="dev.xpetalab.hermes-console.bridge"
BRIDGE_LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$BRIDGE_LAUNCHD_LABEL.plist"

bridge_files() {
  printf '%s\n' \
    "$HH/hermes_bridge.py" \
    "$HH/hermes_bridge.py.rollback" \
    "$HH/hermes_bridge.py.new" \
    "$HH/bridge.env" \
    "$HH/bridge_token" \
    "$HH/bridge-release.json.new" \
    "$HH/console-services/hermes-bridge.sh" \
    "$HH/console-services/bridge-release-check.py" \
    "$HH/console-services/bridge.pid" \
    "$HH/console-services/bridge.start" \
    "$HH/console-services/bridge.exe"
}

bridge_leftovers() {
  for path in "$BRIDGE_SYSTEMD_UNIT" "$BRIDGE_LAUNCHD_PLIST"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      printf '%s\n' "$path"
    fi
  done
  bridge_files | while IFS= read -r path; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      printf '%s\n' "$path"
    fi
  done
}

# Without systemd or launchd the old setup started the bridge itself and wrote
# down its PID. That PID is signalled only while it is still that process: the
# same kernel start time when one was recorded, and the bridge of THIS Hermes
# home on its command line. Anything else is left alone.
stop_portable_bridge() {
  pidfile="$HH/console-services/bridge.pid"
  [ -f "$pidfile" ] || return 0
  pid="$(sed -n '1p' "$pidfile" 2>/dev/null || true)"
  case "$pid" in
    *[!0-9]*|'') return 0 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 0
  retire_python="$HH/hermes-agent/venv/bin/python3"
  [ -x "$retire_python" ] || retire_python="$HH/hermes-agent/venv/bin/python"
  [ -x "$retire_python" ] || retire_python="$(ownership_python)"
  if [ -z "$retire_python" ] || [ ! -x "$retire_python" ]; then
    echo "ERROR: process $pid may be the Mobile Bridge, but it cannot be identified safely without Python." >&2
    echo "Nothing was removed. Stop that process yourself, then run this again." >&2
    return 1
  fi
  recorded_start="$(sed -n '1p' "$HH/console-services/bridge.start" 2>/dev/null || true)"
  retire_status=0
  if "$retire_python" - "$pid" "$recorded_start" "$HH/hermes_bridge.py" <<'PY_RETIRE'
import os, select, signal, sys

pid = int(sys.argv[1])
recorded_start, bridge_path = sys.argv[2:]
try:
    pidfd = os.pidfd_open(pid)
except ProcessLookupError:
    raise SystemExit(0)
except (AttributeError, OSError):
    raise SystemExit(4)
try:
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii", errors="replace") as source:
            rest = source.read().rstrip().rsplit(") ", 1)[1].split()
        with open(f"/proc/{pid}/cmdline", "rb") as source:
            arguments = [os.fsdecode(item) for item in source.read().split(b"\0") if item]
    except (OSError, IndexError):
        raise SystemExit(4)
    same_start = not recorded_start or rest[19] == recorded_start
    wanted = os.path.realpath(bridge_path)
    runs_bridge = any(os.path.realpath(item) == wanted for item in arguments[1:])
    if not (same_start and runs_bridge):
        raise SystemExit(3)
    signal.pidfd_send_signal(pidfd, signal.SIGTERM)
    if not select.select([pidfd], [], [], 10)[0]:
        signal.pidfd_send_signal(pidfd, signal.SIGKILL)
        if not select.select([pidfd], [], [], 5)[0]:
            raise SystemExit(1)
finally:
    os.close(pidfd)
PY_RETIRE
  then
    retire_status=0
  else
    retire_status=$?
  fi
  case "$retire_status" in
    0) return 0 ;;
    3)
      echo "Process $pid is no longer the Mobile Bridge; it was left alone."
      return 0
      ;;
    4)
      echo "ERROR: process $pid may be the Mobile Bridge, but this system cannot identify it safely." >&2
      echo "Nothing was removed. Stop that process yourself, then run this again." >&2
      return 1
      ;;
    *)
      echo "ERROR: the Mobile Bridge (process $pid) did not stop. Nothing was removed." >&2
      return 1
      ;;
  esac
}

# Stop, disable and remove the Mobile Bridge and nothing else. Running it twice,
# or on a computer that never had one, changes nothing and succeeds.
retire_bridge() {
  if [ -z "$(bridge_leftovers)" ]; then
    echo "There is no Mobile Bridge on this computer. Nothing to do."
    return 0
  fi
  if [ -L "$HH/console-services" ]; then
    echo "ERROR: $HH/console-services is a symbolic link; nothing was removed." >&2
    return 1
  fi
  if [ -e "$BRIDGE_SYSTEMD_UNIT" ] || [ -L "$BRIDGE_SYSTEMD_UNIT" ]; then
    if [ "$SERVICE_MANAGER" != "systemd" ]; then
      echo "ERROR: the Mobile Bridge service belongs to your own login session, which is not available here." >&2
      echo "Open a terminal as yourself (not through sudo or su) and run this again. Nothing was removed." >&2
      return 1
    fi
    if ! assert_systemd_unit_owner hermes-bridge.service; then
      echo "Nothing was removed." >&2
      return 1
    fi
    systemctl --user disable --now hermes-bridge.service >/dev/null 2>&1 || true
    if systemctl --user is-active --quiet hermes-bridge.service; then
      echo "ERROR: the Mobile Bridge service is still running. Nothing was removed." >&2
      return 1
    fi
    rm -f "$BRIDGE_SYSTEMD_UNIT"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user reset-failed hermes-bridge.service >/dev/null 2>&1 || true
  fi
  if [ -e "$BRIDGE_LAUNCHD_PLIST" ] || [ -L "$BRIDGE_LAUNCHD_PLIST" ]; then
    if [ "$SERVICE_MANAGER" != "launchd" ]; then
      echo "ERROR: the Mobile Bridge job belongs to your own login session, which is not available here." >&2
      echo "Open Terminal as yourself (not through sudo or ssh) and run this again. Nothing was removed." >&2
      return 1
    fi
    if ! assert_launchd_plist_owner "$BRIDGE_LAUNCHD_LABEL" || \
       ! assert_loaded_launchd_job_owner "$BRIDGE_LAUNCHD_LABEL"; then
      echo "Nothing was removed." >&2
      return 1
    fi
    launchctl bootout "gui/$(id -u)/$BRIDGE_LAUNCHD_LABEL" >/dev/null 2>&1 || true
    if launchctl print "gui/$(id -u)/$BRIDGE_LAUNCHD_LABEL" >/dev/null 2>&1; then
      echo "ERROR: the Mobile Bridge job is still loaded. Nothing was removed." >&2
      return 1
    fi
    rm -f "$BRIDGE_LAUNCHD_PLIST"
  fi
  stop_portable_bridge || return 1
  bridge_files | while IFS= read -r path; do
    rm -f "$path" 2>/dev/null || true
  done
  if [ -n "$(bridge_leftovers)" ]; then
    echo "ERROR: part of the Mobile Bridge could not be removed:" >&2
    bridge_leftovers >&2
    return 1
  fi
  echo "Done. The old Mobile Bridge was stopped and removed."
  echo "Hermes, its Gateway and its Dashboard were not touched: Console 1.2.15 or newer keeps working."
  if command -v ufw >/dev/null 2>&1 || command -v firewall-cmd >/dev/null 2>&1; then
    echo "Port ${HERMES_BRIDGE_PORT:-9131} is no longer used. A firewall rule that opened it can be deleted; nothing listens there now."
  fi
}

if [ "$ACTION" = "retire-bridge" ]; then
  retire_status_final=0
  retire_bridge || retire_status_final=$?
  exit "$retire_status_final"
fi

# Undo what hermes-mobile-setup.sh added to the Gateway, and nothing else:
#   - the API_SERVER_HOST / API_SERVER_PORT it exported in console-services/hermes-gateway.sh,
#   - the same two variables in the systemd drop-in 10-hermes-console-network.conf,
#   - the pairing record.
# The API_SERVER_KEY line in .env is KEPT. The earlier setup reuses a strong key
# that was already there (hermes-mobile-setup.sh:1353-1389, "Preserve one usable
# existing API key"), so the line can belong to Open WebUI, a cron provider or
# another client of the user. Without a usable key Hermes does not start its API
# server at all (gateway/config_env.py:306-310, gateway/config.py:566) and external
# cron providers, which fire over loopback HTTP into it, fail every time
# (gateway/run.py:5672-5688). What exposed the Gateway was the address and port;
# without them the API server binds its default, this computer only
# (gateway/platforms/api_server.py:216,227). Only the explicit option
# --also-remove-api-key takes the key out, and it says what that costs.
# The Gateway is not stopped or restarted. Its own unit, its other settings and
# every other line of .env stay as they are.
retire_gateway_exposure() {
  env_file="$HH/.env"
  runner="$HH/console-services/hermes-gateway.sh"
  pairing="$HH/console-services/pairing.env"
  dropin_dir="$HOME/.config/systemd/user/hermes-gateway.service.d"
  dropin="$dropin_dir/10-hermes-console-network.conf"

  for guarded in "$HH/console-services" "$env_file" "$runner" "$pairing" "$dropin_dir" "$dropin" "$HH/backups"; do
    if [ -L "$guarded" ]; then
      echo "ERROR: $guarded is a symbolic link; nothing was changed." >&2
      return 1
    fi
  done

  evidence=0
  has_runner_exposure=0
  has_dropin=0
  if [ -f "$runner" ] && grep -Eq '^export API_SERVER_(HOST|PORT)=' "$runner" 2>/dev/null; then
    has_runner_exposure=1
    evidence=1
  fi
  if [ -f "$dropin" ]; then
    has_dropin=1
    evidence=1
  fi
  has_pairing=0
  [ ! -f "$pairing" ] || has_pairing=1
  [ "$has_pairing" -eq 0 ] || evidence=1
  key_present=0
  if [ -f "$env_file" ] && grep -q '^API_SERVER_KEY=' "$env_file" 2>/dev/null; then
    key_present=1
  fi
  # Asking for the key to go too is an explicit order, so it needs no other trace.
  if [ "$ALSO_REMOVE_KEY" -eq 1 ] && [ "$key_present" -eq 1 ]; then
    evidence=1
  fi
  if [ "$evidence" -eq 0 ]; then
    echo "The earlier Console setup left nothing exposed on the Gateway. Nothing to do."
    return 0
  fi

  # Everything is prepared first, so a failure leaves the computer as it was.
  prepared="$(mktemp -d "${TMPDIR:-/tmp}/hermes-retire.XXXXXX")"
  WORK="$prepared"
  umask 077
  removed_key=0
  backup=""
  if [ "$ALSO_REMOVE_KEY" -eq 1 ] && [ "$key_present" -eq 1 ]; then
    removed_key=1
    awk '!/^API_SERVER_KEY=/' "$env_file" > "$prepared/env" || return 1
    mkdir -p "$HH/backups/gateway-exposure"
    chmod 700 "$HH/backups" "$HH/backups/gateway-exposure" 2>/dev/null || true
    backup="$HH/backups/gateway-exposure/api-server-key.$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now).$$"
    grep '^API_SERVER_KEY=' "$env_file" > "$backup" || return 1
    chmod 600 "$backup"
  fi
  if [ "$has_runner_exposure" -eq 1 ]; then
    awk '!/^export API_SERVER_(HOST|PORT)=/' "$runner" > "$prepared/runner" || return 1
  fi
  dropin_left=0
  if [ "$has_dropin" -eq 1 ]; then
    awk '!/^Environment="API_SERVER_(HOST|PORT)=/' "$dropin" > "$prepared/dropin" || return 1
    if grep -qv '^[[:space:]]*\(\[Service\]\)\{0,1\}[[:space:]]*$' "$prepared/dropin"; then
      dropin_left=1
    fi
  fi

  if [ "$removed_key" -eq 1 ]; then
    cp -p "$env_file" "$env_file.new.$$" && cat "$prepared/env" > "$env_file.new.$$" && \
      mv "$env_file.new.$$" "$env_file" || { rm -f "$env_file.new.$$"; return 1; }
  fi
  if [ "$has_runner_exposure" -eq 1 ]; then
    cp -p "$runner" "$runner.new.$$" && cat "$prepared/runner" > "$runner.new.$$" && \
      mv "$runner.new.$$" "$runner" || { rm -f "$runner.new.$$"; return 1; }
  fi
  if [ "$has_dropin" -eq 1 ]; then
    if [ "$dropin_left" -eq 1 ]; then
      cat "$prepared/dropin" > "$dropin.new.$$" && chmod 644 "$dropin.new.$$" && mv "$dropin.new.$$" "$dropin" || {
        rm -f "$dropin.new.$$"
        return 1
      }
    else
      rm -f "$dropin"
      rmdir "$dropin_dir" 2>/dev/null || true
    fi
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
      systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$pairing"

  echo "Done. What the earlier Console setup added to the Gateway was removed:"
  [ "$has_runner_exposure" -eq 0 ] || echo "  - the network address and port in $runner"
  [ "$has_dropin" -eq 0 ] || echo "  - the network address and port in the Gateway's systemd drop-in"
  [ "$has_pairing" -eq 0 ] || echo "  - the pairing record"
  [ "$removed_key" -eq 0 ] || echo "  - the API key line in $env_file (you asked for it)"
  if [ "$removed_key" -eq 1 ]; then
    echo "A private copy of the removed key line is in $backup."
    echo "WARNING: without a usable API key Hermes does not start its API server. After the"
    echo "Gateway's next restart anything of yours that uses that key stops working: a cron"
    echo "provider other than the built-in one, Open WebUI or any other client. To undo,"
    echo "copy the line back into $env_file."
  elif [ "$key_present" -eq 1 ]; then
    echo "Your API key in $env_file was kept: Open WebUI, a cron provider or another client"
    echo "of yours may be using it. Without this network address and port, Hermes' API server"
    echo "listens on its default, this computer only, unless you set a host yourself."
    echo "To remove the key too, run this again with --also-remove-api-key."
  fi
  if [ -f "$HH/console-services/dashboard-login.json" ]; then
    echo "Left in place: $HH/console-services/dashboard-login.json holds the Dashboard"
    echo "password in clear, from the earlier setup. Nothing uses it any more; delete it"
    echo "yourself if you do not want the password stored."
  fi
  echo "Your Gateway was not stopped or restarted. It keeps listening as it was"
  echo "until the Gateway is restarted (hermes gateway restart). Its other settings"
  echo "and the rest of your .env were not changed."
  return 0
}

if [ "$ACTION" = "retire-gateway-exposure" ]; then
  retire_status_final=0
  retire_gateway_exposure || retire_status_final=$?
  exit "$retire_status_final"
fi

# ---------------------------------------------------------------------------
# Setup / --new-access: from here on, Hermes must already be installed.
# ---------------------------------------------------------------------------
SERVICES="$HH/console-services"
LOGS="$HH/logs"
DASHBOARD_RUNNER="$SERVICES/hermes-dashboard.sh"
DASH_HELPER="$SERVICES/dashboard-service.py"
SETUP_PROGRESS_LABEL="startup"
TRANSACTION_PENDING=0
TRANSACTION_DIR=""
SERVICE_LIFECYCLE_TOUCHED=0

for managed_dir in "$SERVICES" "$LOGS"; do
  if [ -L "$managed_dir" ]; then
    echo "ERROR: managed directory $managed_dir is a symbolic link; refusing setup." >&2
    exit 1
  fi
done

step() {
  SETUP_PROGRESS_LABEL="$1"
  printf '\n== %s\n' "$1"
}

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

# Hermes is looked for where its installers put it. A launcher only counts when
# it answers; a stale shim of a half-finished uninstall must not become a service.
find_hermes_launcher() {
  probe_try=1
  while [ "$probe_try" -le 3 ]; do
    found_any=0
    for candidate in "$HH/hermes-agent/.hermes/bin/hermes" "$HH/hermes-agent/venv/bin/hermes" "$HH/bin/hermes" "$HOME/.local/bin/hermes"; do
      if [ -x "$candidate" ]; then
        found_any=1
        if "$candidate" --version >/dev/null 2>&1; then
          printf '%s\n' "$candidate"
          return 0
        fi
      fi
    done
    [ "$found_any" -eq 1 ] || return 1
    [ "$probe_try" -lt 3 ] || break
    sleep $((probe_try * ${HERMES_SETUP_PROBE_PAUSE:-2})) 2>/dev/null || true
    probe_try=$((probe_try + 1))
  done
  return 1
}

step "Looking at this computer"
select_service_manager
preflight_service_ownership

HB="$(find_hermes_launcher || true)"
if [ -z "$HB" ]; then
  echo "Hermes Agent is not installed on this computer (nothing answered under $HH)." >&2
  echo "This setup does not install it. Install Hermes with the official command, then run this again:" >&2
  echo "  $OFFICIAL_INSTALL" >&2
  echo "Nothing was changed." >&2
  exit 1
fi

# Two interpreters, because Hermes does not guarantee one that does both.
# VP does this setup's own plain work (probes, units, the service helper).
# HP can import Hermes and its configuration API. A current install publishes the
# command that starts its libraries (hermes --print-runtime-command), and that
# is asked first; an older install keeps a venv whose interpreter is both.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hermes-dashboard-setup.XXXXXX")" || {
  echo "ERROR: cannot create a private working folder." >&2
  exit 1
}
chmod 700 "$WORK"
VP=""
HP=""
RUNTIME_PY="$("$HB" --print-runtime-command 2>/dev/null | sed -n 's/^\["\([^"]*\)".*/\1/p' | head -1 || true)"
[ -x "$RUNTIME_PY" ] || RUNTIME_PY=""
if [ -n "$RUNTIME_PY" ]; then
  VP="$RUNTIME_PY"
  if "$RUNTIME_PY" -I - "$WORK/hermes-python" "$HB" <<'PY_HERMES_PYTHON'
import json, shlex, subprocess, sys

target, launcher = sys.argv[1:]
reported = subprocess.run(
    [launcher, "--print-runtime-command"], capture_output=True, text=True, timeout=120, check=True
).stdout
command = json.loads(reported)
python, code = command[0], command[3]
# Hermes' launch command ends by running a module; run the caller's code instead,
# after the same preparation (isolated mode, install on the path, bootstrap).
head = code[: code.rindex("runpy.run_module(")].rstrip().rstrip(";")
driver = """
_a = sys.argv[1:]
if _a[:1] == ['-']:
    _src = sys.stdin.read()
    sys.argv = ['-'] + _a[1:]
elif _a[:1] == ['-c']:
    _src = _a[1]
    sys.argv = ['-c'] + _a[2:]
else:
    _src = open(_a[0], encoding='utf-8').read()
    sys.argv = _a
exec(compile(_src, sys.argv[0], 'exec'), {'__name__': '__main__'})
"""
with open(target, "w", encoding="utf-8") as wrapper:
    wrapper.write("#!/bin/sh\nexec %s -I -c %s \"$@\"\n" % (shlex.quote(python), shlex.quote(head + "\n" + driver)))
PY_HERMES_PYTHON
  then
    chmod 700 "$WORK/hermes-python"
    HP="$WORK/hermes-python"
  fi
fi
if [ -z "$HP" ]; then
  VP="$HH/hermes-agent/venv/bin/python3"
  [ -x "$VP" ] || VP="$HH/hermes-agent/venv/bin/python"
  if [ ! -x "$VP" ]; then
    VP="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
  fi
  HP="$VP"
fi
if [ -z "$VP" ] || [ ! -x "$VP" ]; then
  echo "ERROR: Hermes has no usable Python interpreter; repair the Hermes installation first." >&2
  exit 1
fi
if ! HERMES_HOME="$HH" "$HP" -c 'import hermes_cli.config, plugins.dashboard_auth.basic' >/dev/null 2>&1; then
  echo "ERROR: Hermes cannot run its own configuration code with $HP; repair the Hermes installation first." >&2
  exit 1
fi

# ---- the address the Dashboard listens on ----------------------------------
# Mesh VPN (Tailscale / CGNAT) first, then private LAN. Never a public address,
# never 0.0.0.0: the Dashboard is bound to exactly one address.
IPS=""
if command -v ip >/dev/null 2>&1; then
  IPS="$(ip -o -4 addr show 2>/dev/null | awk '$2 !~ /^(lo|docker|br-|veth|virbr|podman|cni|lxc)/ {if ($4 !~ /^(127\.|169\.254\.)/) print $4}' || true)"
elif command -v ifconfig >/dev/null 2>&1; then
  IPS="$(ifconfig 2>/dev/null | awk '/^[[:alnum:]]/ {iface=$1; sub(":$","",iface)} /inet / && iface !~ /^(lo|bridge|vmenet|docker|utun|awdl|llw)/ {ip=$2; sub(/^addr:/,"",ip); if (ip !~ /^(127\.|169\.254\.)/) print ip "/"}' || true)"
elif command -v hostname >/dev/null 2>&1; then
  IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -Ev '^(127\.|169\.254\.)' | sed 's|$|/|' || true)"
fi
BIND_HOST="${HERMES_DASHBOARD_HOST:-}"
NETWORK_KIND="chosen"
if [ -z "$BIND_HOST" ]; then
  BIND_HOST="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if [ -n "$BIND_HOST" ]; then
    NETWORK_KIND="mesh"
  else
    candidate="$(printf '%s\n' "$IPS" | grep -E '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' | head -1 || true)"
    if [ -n "$candidate" ]; then
      BIND_HOST="${candidate%%/*}"
      NETWORK_KIND="mesh"
    else
      candidate="$(printf '%s\n' "$IPS" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -1 || true)"
      if [ -n "$candidate" ]; then
        BIND_HOST="${candidate%%/*}"
        NETWORK_KIND="lan"
      fi
    fi
  fi
fi
if [ -z "$BIND_HOST" ]; then
  echo "ERROR: no LAN or Tailscale address was found, so there is nothing safe to listen on." >&2
  echo "Connect Tailscale or join the LAN, or choose one: HERMES_DASHBOARD_HOST=<private address>." >&2
  echo "Nothing was changed." >&2
  exit 1
fi
if ! "$VP" -I - "$BIND_HOST" <<'PY_HOST'
import ipaddress, sys

try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
cgnat = ip.version == 4 and ip in ipaddress.ip_network("100.64.0.0/10")
ula = ip.version == 6 and ip in ipaddress.ip_network("fc00::/7")
private = ip.version == 4 and ip.is_private and not ip.is_loopback and not ip.is_link_local
raise SystemExit(0 if (private or cgnat or ula) and not ip.is_unspecified else 1)
PY_HOST
then
  echo "ERROR: HERMES_DASHBOARD_HOST must be one private LAN, Tailscale or unique-local address (not 0.0.0.0, loopback or a public one)." >&2
  echo "Nothing was changed." >&2
  exit 1
fi
case "$BIND_HOST" in
  *:*) BASE_HOST="[$BIND_HOST]" ;;
  *) BASE_HOST="$BIND_HOST" ;;
esac
DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
case "$DASHBOARD_PORT" in
  *[!0-9]*|'') echo "ERROR: HERMES_DASHBOARD_PORT must be a TCP port. Nothing was changed." >&2; exit 1 ;;
esac
if [ "$DASHBOARD_PORT" -lt 1 ] || [ "$DASHBOARD_PORT" -gt 65535 ]; then
  echo "ERROR: HERMES_DASHBOARD_PORT is out of range. Nothing was changed." >&2
  exit 1
fi
DASHBOARD_BASE="http://$BASE_HOST:$DASHBOARD_PORT"

# ---- service helpers --------------------------------------------------------
# The portable manager keeps three small files per service (pid, kernel start
# time, executable) in console-services, the same names the earlier setup used,
# and signals a pid only while it is still that process.
write_dash_helper() {
  cat > "$DASH_HELPER" <<'PY_HELPER'
import os, select, signal, subprocess, sys, time

action, runner, services, logs = sys.argv[1:5]
allowed = {os.path.realpath(item) for item in sys.argv[5:] if item}
pidfile = os.path.join(services, "dashboard.pid")
startfile = os.path.join(services, "dashboard.start")
exefile = os.path.join(services, "dashboard.exe")
logfile = os.path.join(logs, "dashboard.log")


def first_line(path):
    try:
        with open(path, encoding="utf-8") as source:
            return source.readline().strip()
    except OSError:
        return ""


def identity(pid):
    with open(f"/proc/{pid}/stat", encoding="ascii") as source:
        rest = source.read().rstrip().rsplit(") ", 1)[1].split()
    return rest[19], os.path.realpath(f"/proc/{pid}/exe")


def forget():
    for path in (pidfile, startfile, exefile):
        try:
            os.unlink(path)
        except OSError:
            pass


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii") as source:
            return source.read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return True


def tracked():
    value = first_line(pidfile)
    if not value.isdigit():
        forget()
        return 0
    pid = int(value)
    if not alive(pid):
        forget()
        return 0
    return pid


def stop():
    pid = tracked()
    if not pid:
        return 0
    recorded_start, recorded_exe = first_line(startfile), first_line(exefile)
    try:
        pidfd = os.pidfd_open(pid)
    except ProcessLookupError:
        forget()
        return 0
    except (AttributeError, OSError):
        print("Refusing to stop process %d: atomic identity verification is unavailable." % pid, file=sys.stderr)
        return 3
    try:
        try:
            start, exe = identity(pid)
        except (OSError, IndexError):
            start, exe = "", ""
        if not recorded_start or not recorded_exe or start != recorded_start or exe != recorded_exe:
            print("Refusing to stop process %d: exact Hermes dashboard ownership is not proven." % pid, file=sys.stderr)
            return 3
        signal.pidfd_send_signal(pidfd, signal.SIGTERM)
        if not select.select([pidfd], [], [], 15)[0]:
            print("The Hermes dashboard did not stop cleanly; refusing to start a duplicate.", file=sys.stderr)
            return 1
    finally:
        os.close(pidfd)
    forget()
    return 0


def start():
    pid = tracked()
    if pid:
        print("Refusing to overwrite the live Hermes dashboard process identity.", file=sys.stderr)
        return 1
    os.makedirs(logs, exist_ok=True)
    with open(logfile, "ab") as log:
        child = subprocess.Popen(
            [runner], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True
        )
    spawn_start = ""
    for _ in range(40):
        try:
            current, exe = identity(child.pid)
        except (OSError, IndexError):
            current, exe = "", ""
        spawn_start = spawn_start or current
        if spawn_start and current == spawn_start and exe in allowed:
            for path, value in ((pidfile, str(child.pid)), (startfile, current), (exefile, exe)):
                with open(path + ".new", "w", encoding="utf-8") as target:
                    target.write(value + "\n")
                os.chmod(path + ".new", 0o600)
                os.replace(path + ".new", path)
            return 0
        if child.poll() is not None:
            break
        time.sleep(0.25)
    try:
        child.kill()
        child.wait(timeout=5)
    except Exception:
        pass
    print("The Hermes dashboard process identity could not be captured; refusing unmanaged startup.", file=sys.stderr)
    return 1


if action == "start":
    sys.exit(start())
if action == "stop":
    sys.exit(stop())
if action == "restart":
    code = stop()
    sys.exit(code or start())
if action == "alive":
    sys.exit(0 if tracked() else 1)
sys.exit(2)
PY_HELPER
  chmod 600 "$DASH_HELPER"
}

portable_dashboard() {
  "$VP" "$DASH_HELPER" "$1" "$DASHBOARD_RUNNER" "$SERVICES" "$LOGS" \
    "$VP" "$HB" "$(readlink "$HB" 2>/dev/null || true)" "$RUNTIME_PY" "$HH/hermes-agent/venv/bin/python3"
}

dashboard_active() {
  case "$SERVICE_MANAGER" in
    systemd) systemctl --user is-active --quiet hermes-dashboard ;;
    launchd) launchctl print "gui/$(id -u)/$DASH_LABEL" >/dev/null 2>&1 ;;
    portable)
      [ -f "$DASH_HELPER" ] && portable_dashboard alive >/dev/null 2>&1 && return 0
      pidfile="$SERVICES/dashboard.pid"
      [ -f "$pidfile" ] || return 1
      pid="$(sed -n '1p' "$pidfile" 2>/dev/null || true)"
      case "$pid" in *[!0-9]*|'') return 1 ;; esac
      kill -0 "$pid" 2>/dev/null
      ;;
  esac
}

# ---- one transaction around everything that changes -------------------------
transaction_path() {
  case "$1" in
    runner) printf '%s\n' "$DASHBOARD_RUNNER" ;;
    helper) printf '%s\n' "$DASH_HELPER" ;;
    systemd_dashboard) printf '%s\n' "$DASH_UNIT" ;;
    launchd_dashboard) printf '%s\n' "$DASH_PLIST" ;;
    login_record) printf '%s\n' "$SERVICES/dashboard-login.json" ;;
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

TRANSACTION_KEYS="runner helper systemd_dashboard launchd_dashboard login_record"
begin_transaction() {
  mkdir -p "$HH" "$SERVICES" "$LOGS"
  TRANSACTION_DIR="$(mktemp -d "$SERVICES/setup-transaction.XXXXXX")"
  TRANSACTION_PENDING=1
  for key in $TRANSACTION_KEYS; do
    snapshot_transaction_file "$key"
  done
  PREV_ACTIVE=0
  PREV_ENABLED=0
  dashboard_active && PREV_ACTIVE=1
  if [ "$SERVICE_MANAGER" = "systemd" ] && systemctl --user is-enabled --quiet hermes-dashboard 2>/dev/null; then
    PREV_ENABLED=1
  fi
}

rollback_dashboard_access() {
  [ -n "$TRANSACTION_DIR" ] || return 0
  [ -f "$TRANSACTION_DIR/dashboard-access.previous.json" ] || return 0
  HERMES_HOME="$HH" "$HP" "$WORK/restore.py" "$TRANSACTION_DIR/dashboard-access.previous.json" >/dev/null 2>&1 </dev/null
}

stop_dashboard_service() {
  case "$SERVICE_MANAGER" in
    systemd)
      unit_state="$(systemctl --user show -p LoadState --value hermes-dashboard 2>/dev/null || true)"
      [ "$unit_state" != "not-found" ] || return 0
      systemctl --user stop hermes-dashboard >/dev/null 2>&1
      ;;
    launchd)
      if launchctl print "gui/$(id -u)/$DASH_LABEL" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$DASH_LABEL" >/dev/null 2>&1
      fi
      ;;
    portable)
      [ -f "$DASH_HELPER" ] || return 0
      stop_rc=0
      portable_dashboard stop >/dev/null 2>&1 || stop_rc=$?
      # 3: a process the helper cannot prove to be its own. It is not ours to
      # stop, so there is nothing of ours to take back.
      [ "$stop_rc" -eq 0 ] || [ "$stop_rc" -eq 3 ]
      ;;
  esac
}

rollback_transaction() {
  [ "$TRANSACTION_PENDING" -eq 1 ] || return 0
  TRANSACTION_PENDING=0
  rollback_failed=0
  if ! rollback_dashboard_access; then rollback_failed=1; fi
  if [ "$SERVICE_LIFECYCLE_TOUCHED" -eq 1 ]; then
    if ! stop_dashboard_service; then rollback_failed=1; fi
  fi
  for key in $TRANSACTION_KEYS; do
    [ "$key" = "helper" ] && [ "$SERVICE_MANAGER" = "portable" ] && continue
    if ! restore_transaction_file "$key"; then rollback_failed=1; fi
  done
  if [ "$SERVICE_LIFECYCLE_TOUCHED" -eq 1 ]; then
    case "$SERVICE_MANAGER" in
      systemd)
        systemctl --user daemon-reload >/dev/null 2>&1 || rollback_failed=1
        if [ "$(sed -n '1p' "$TRANSACTION_DIR/systemd_dashboard.had" 2>/dev/null)" = "1" ]; then
          if [ "$PREV_ENABLED" -eq 1 ]; then
            systemctl --user enable hermes-dashboard >/dev/null 2>&1 || rollback_failed=1
          else
            systemctl --user disable hermes-dashboard >/dev/null 2>&1 || rollback_failed=1
          fi
          if [ "$PREV_ACTIVE" -eq 1 ]; then
            systemctl --user restart hermes-dashboard >/dev/null 2>&1 || rollback_failed=1
          fi
        else
          systemctl --user disable hermes-dashboard >/dev/null 2>&1 || true
        fi
        ;;
      launchd)
        if [ "$PREV_ACTIVE" -eq 1 ] && [ -f "$DASH_PLIST" ]; then
          launchctl bootstrap "gui/$(id -u)" "$DASH_PLIST" >/dev/null 2>&1 || rollback_failed=1
        fi
        ;;
      portable)
        # Started again only when it is really gone: a process that is still
        # there (the one that was never stopped, or one that is not ours) is left as it is.
        if [ "$PREV_ACTIVE" -eq 1 ] && [ -f "$DASH_HELPER" ] && [ -x "$DASHBOARD_RUNNER" ] && \
           ! portable_dashboard alive >/dev/null 2>&1; then
          portable_dashboard start >/dev/null 2>&1 || rollback_failed=1
        fi
        restore_transaction_file helper || rollback_failed=1
        ;;
    esac
  fi
  if [ "$rollback_failed" -eq 0 ]; then
    for key in $TRANSACTION_KEYS; do
      rm -f "$TRANSACTION_DIR/$key.had" "$TRANSACTION_DIR/$key.data"
    done
    rm -f "$TRANSACTION_DIR/dashboard-access.previous.json" "$TRANSACTION_DIR/state" "$TRANSACTION_DIR/new-password"
    rmdir "$TRANSACTION_DIR" 2>/dev/null || rollback_failed=1
  fi
  if [ "$rollback_failed" -ne 0 ]; then
    echo "CRITICAL: setup rollback was incomplete; recovery data was retained at $TRANSACTION_DIR" >&2
  fi
  return 0
}

commit_transaction() {
  [ "$TRANSACTION_PENDING" -eq 1 ] || return 0
  TRANSACTION_PENDING=0
  for key in $TRANSACTION_KEYS; do
    rm -f "$TRANSACTION_DIR/$key.had" "$TRANSACTION_DIR/$key.data"
  done
  rm -f "$TRANSACTION_DIR/dashboard-access.previous.json" "$TRANSACTION_DIR/state" "$TRANSACTION_DIR/new-password"
  rmdir "$TRANSACTION_DIR" 2>/dev/null || {
    echo "ERROR: setup completed but transaction cleanup failed in $TRANSACTION_DIR" >&2
    return 1
  }
  TRANSACTION_DIR=""
}

# ---- Dashboard sign-in, through Hermes' own configuration API --------------
# The same calls `hermes dashboard` makes when it asks for a password
# (hermes_cli/main_dashboard.py:608-720): the .env is loaded the way
# hermes_cli/main.py:714 loads it, the plugins are discovered, and a sign-in is
# only made when no provider is registered. A sign-in that exists is left alone.
write_auth_scripts() {
  cat > "$WORK/auth.py" <<'PY_AUTH'
import json, os, pathlib, secrets, sys

action, home, state_path, previous_path, from_stdin, password_out = sys.argv[1:]
os.environ["HERMES_HOME"] = home
password_given = sys.stdin.readline().rstrip("\r\n") if from_stdin == "1" else ""
if from_stdin == "1" and not password_given.strip():
    raise SystemExit("the password is empty")


def say(state, user=""):
    pathlib.Path(state_path).write_text("STATE=%s\nUSER=%s\n" % (state, user), encoding="utf-8")


def pinned_names():
    names = {}
    try:
        from hermes_cli.env_loader import load_hermes_dotenv
        # Only the .env is read. Sources outside it (a secret manager Hermes is
        # set up to use) are not asked: a setup script must not run those helpers
        # (hermes_cli/env_loader.py:488-493 resolves them). A sign-in kept only
        # there is not seen; the final message says so.
        load_hermes_dotenv(hermes_home=home, load_external_secrets=False)
        for key in ("USERNAME", "PASSWORD", "PASSWORD_HASH"):
            names[key] = os.environ.get("HERMES_DASHBOARD_BASIC_AUTH_" + key, "").strip()
        names["OAUTH"] = os.environ.get("HERMES_DASHBOARD_OAUTH_CLIENT_ID", "").strip()
    except Exception:
        path = pathlib.Path(home) / ".env"
        if path.exists():
            for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
                line = raw.strip()
                if line.startswith("export "):
                    line = line[len("export "):].lstrip()
                if "=" not in line:
                    continue
                name, value = line.split("=", 1)
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                for key in ("USERNAME", "PASSWORD", "PASSWORD_HASH"):
                    if name.strip() == "HERMES_DASHBOARD_BASIC_AUTH_" + key:
                        names[key] = value.strip()
                if name.strip() == "HERMES_DASHBOARD_OAUTH_CLIENT_ID":
                    names["OAUTH"] = value.strip()
    return names


from hermes_cli.config import load_config, save_config

env = pinned_names()
cfg = load_config()
if not isinstance(cfg.get("dashboard"), dict):
    cfg["dashboard"] = {}
if not isinstance(cfg["dashboard"].get("basic_auth"), dict):
    cfg["dashboard"]["basic_auth"] = {}
basic = cfg["dashboard"]["basic_auth"]
oauth_cfg = cfg["dashboard"].get("oauth")
oauth_cfg = oauth_cfg if isinstance(oauth_cfg, dict) else {}

providers = None
try:
    from hermes_cli.plugins import discover_plugins
    from hermes_cli.dashboard_auth import list_providers
    discover_plugins(force=True)
    providers = [str(getattr(item, "name", "")) for item in list_providers()]
except Exception:
    providers = None
if providers is None:
    # An older Hermes without the registry: decide from what its providers read.
    providers = []
    config_user = str(basic.get("username") or "").strip()
    if (env.get("USERNAME") or config_user) and (
        env.get("PASSWORD") or env.get("PASSWORD_HASH") or basic.get("password_hash") or basic.get("password")
    ):
        providers.append("basic")
    if env.get("OAUTH") or str(oauth_cfg.get("client_id") or "").strip():
        providers.append("oauth")

pinned = bool(env.get("PASSWORD") or env.get("PASSWORD_HASH"))
other = [name for name in providers if name != "basic"]
# A password sign-in that is written down but not registered: Hermes parks the
# bundled plugin in plugins.disabled in that case (hermes_cli/plugins_cmd.py:531-537).
configured = bool(
    (env.get("USERNAME") or str(basic.get("username") or "").strip())
    and (env.get("PASSWORD") or env.get("PASSWORD_HASH") or basic.get("password_hash") or basic.get("password"))
)


def disabled_plugins():
    plugins = cfg.get("plugins")
    value = plugins.get("disabled") if isinstance(plugins, dict) else None
    return list(value) if isinstance(value, list) else []


def enable_basic_plugin():
    """Take the bundled basic plugin out of plugins.disabled; returns the names
    that were taken out, so a rolled-back run can park them there again."""
    before = disabled_plugins()
    try:
        from hermes_cli.plugins_cmd import ensure_basic_auth_plugin_enabled_in_config
        if ensure_basic_auth_plugin_enabled_in_config(cfg):
            sys.stderr.write("Re-enabled the bundled 'basic' auth plugin (it was in plugins.disabled)\n")
    except ImportError:
        pass
    after = disabled_plugins()
    return [name for name in before if name not in after]


def remember(basic_before, reenabled):
    pathlib.Path(previous_path).write_text(
        json.dumps({"basic": basic_before, "reenabled": reenabled}), encoding="utf-8")
    os.chmod(previous_path, 0o600)


if action == "new-access":
    if pinned:
        say("pinned", env.get("USERNAME", ""))
        raise SystemExit(0)
    if other:
        say("other")
        raise SystemExit(0)
else:
    if providers:
        say("existing", str(basic.get("username") or env.get("USERNAME") or ""))
        raise SystemExit(0)
    if configured:
        # The user's own sign-in is there and only parked: switch the plugin back
        # on and change nothing else; a new password would replace their hash.
        reenabled = enable_basic_plugin()
        if reenabled:
            remember({}, reenabled)
            save_config(cfg)
        say("pinned" if pinned else "existing", str(basic.get("username") or env.get("USERNAME") or ""))
        raise SystemExit(0)

from plugins.dashboard_auth.basic import hash_password

previous = {key: basic.get(key) for key in ("username", "password_hash", "password", "secret")}
password = password_given or secrets.token_urlsafe(24)
username = str(basic.get("username") or "").strip() or env.get("USERNAME") or "admin"
basic["username"] = username
basic["password_hash"] = hash_password(password)
basic["password"] = ""  # never persist the plaintext
# --new-access also ends the sessions opened with the old sign-in.
if action == "new-access" or not str(basic.get("secret") or "").strip():
    basic["secret"] = secrets.token_urlsafe(32)
remember(previous, enable_basic_plugin())
save_config(cfg)
say("created", username)
if not password_given:
    # Into the private file the caller made, not onto standard output, where any
    # line Hermes prints while it loads would be taken for part of the password.
    pathlib.Path(password_out).write_text(password, encoding="utf-8")
PY_AUTH
  cat > "$WORK/restore.py" <<'PY_RESTORE'
import json, pathlib, sys

from hermes_cli.config import load_config, save_config

previous = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
cfg = load_config()
if not isinstance(cfg.get("dashboard"), dict):
    cfg["dashboard"] = {}
if not isinstance(cfg["dashboard"].get("basic_auth"), dict):
    cfg["dashboard"]["basic_auth"] = {}
basic = cfg["dashboard"]["basic_auth"]
for key, value in (previous.get("basic") or {}).items():
    if value is None:
        basic.pop(key, None)
    else:
        basic[key] = value
# A plugin this run took out of plugins.disabled goes back in.
parked = [name for name in (previous.get("reenabled") or []) if isinstance(name, str)]
if parked:
    if not isinstance(cfg.get("plugins"), dict):
        cfg["plugins"] = {}
    disabled = cfg["plugins"].get("disabled")
    if not isinstance(disabled, list):
        disabled = cfg["plugins"]["disabled"] = []
    for name in parked:
        if name not in disabled:
            disabled.append(name)
save_config(cfg)
PY_RESTORE
}

# What the Dashboard must answer, checked at the address it listens on:
# its status; a refusal for whoever is not signed in; and, when this run knows
# the password, a real sign-in that opens a protected page.
write_probe() {
  cat > "$WORK/probe.py" <<'PY_PROBE'
import http.client, json, sys, time, urllib.error, urllib.request

base, mode, username = sys.argv[1:4]
password = sys.stdin.readline().rstrip("\r\n") if mode == "login" else ""
protected = "/api/model/options"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, url):
        return None


opener = urllib.request.build_opener(NoRedirect)


def request(path, headers=None, data=None):
    last = None
    for _ in range(4):
        req = urllib.request.Request(base + path, data=data, headers=headers or {}, method="POST" if data is not None else "GET")
        try:
            with opener.open(req, timeout=8) as response:
                return response.status, response.headers, response.read(1024 * 1024)
        except urllib.error.HTTPError as exc:
            return exc.code, exc.headers, exc.read(1024 * 1024)
        except (ConnectionError, http.client.HTTPException, urllib.error.URLError, OSError) as exc:
            last = exc
            time.sleep(1)
    raise SystemExit("%s unreachable (%s)" % (path, type(last).__name__))


def json_object(raw, what):
    try:
        value = json.loads(raw.decode("utf-8"))
    except Exception:
        raise SystemExit("%s did not return JSON" % what)
    if not isinstance(value, dict):
        raise SystemExit("%s returned the wrong JSON shape" % what)
    return value


status, _, raw = request("/api/status", {"Accept": "application/json"})
if status != 200:
    raise SystemExit("/api/status returned HTTP %s" % status)
json_object(raw, "/api/status")
if mode == "alive":
    raise SystemExit(0)
for label, cookie in (("missing", None), ("invalid", "hermes_session_at=invalid")):
    headers = {"Accept": "application/json"}
    if cookie:
        headers["Cookie"] = cookie
    status, _, _ = request(protected, headers)
    if status not in (401, 403):
        raise SystemExit("the Dashboard did not refuse a %s session (HTTP %s)" % (label, status))
if mode == "login":
    body = json.dumps({"provider": "basic", "username": username, "password": password}).encode()
    status, headers, _ = request("/auth/password-login", {"Content-Type": "application/json", "Accept": "application/json"}, body)
    if status in (400, 401, 403):
        raise SystemExit(10)
    if status != 200:
        raise SystemExit("password login returned HTTP %s" % status)
    pairs = [item.split(";", 1)[0] for item in (headers.get_all("Set-Cookie") or [])]
    if not any(item.split("=", 1)[0].endswith("hermes_session_at") for item in pairs):
        raise SystemExit("password login did not return an access-session cookie")
    status, _, raw = request(protected, {"Accept": "application/json", "Cookie": "; ".join(pairs)})
    if status != 200:
        raise SystemExit("the signed-in protected page returned HTTP %s" % status)
    json_object(raw, "the signed-in protected page")
PY_PROBE
}

service_failure() {
  echo "ERROR: the Dashboard did not pass its checks at $DASHBOARD_BASE." >&2
  if port_listening "$DASHBOARD_PORT"; then
    echo "TCP $DASHBOARD_PORT is occupied, but not by a healthy Hermes Dashboard:" >&2
    show_port_owner "$DASHBOARD_PORT" >&2
    echo "The setup did not kill that process." >&2
  else
    echo "Nothing is listening on TCP $DASHBOARD_PORT." >&2
  fi
  if [ "$SERVICE_MANAGER" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user status hermes-dashboard --no-pager 2>&1 | sed -n '1,14p' >&2 || true
  fi
  if [ -s "$LOGS/dashboard.log" ]; then
    echo "Last lines of $LOGS/dashboard.log:" >&2
    tail -n 15 "$LOGS/dashboard.log" >&2 || true
  else
    echo "$LOGS/dashboard.log is empty: the Dashboard never wrote a line." >&2
  fi
  exit 1
}

# ---------------------------------------------------------------------------
step "Checking the Dashboard port"
if port_listening "$DASHBOARD_PORT" && ! dashboard_active; then
  echo "ERROR: TCP $DASHBOARD_PORT is occupied by something that is not this Dashboard service:" >&2
  show_port_owner "$DASHBOARD_PORT" >&2
  echo "Nothing was changed. Free the port, or choose another: HERMES_DASHBOARD_PORT=<port>." >&2
  exit 1
fi

if [ "$SERVICE_MANAGER" = "systemd" ] && command -v loginctl >/dev/null 2>&1; then
  LINGER_USER="$(id -un)"
  if [ "$(loginctl show-user "$LINGER_USER" -p Linger --value 2>/dev/null || true)" != "yes" ]; then
    LINGER_ENABLED=0
    if [ "$(id -u)" -eq 0 ]; then
      loginctl enable-linger "$LINGER_USER" >/dev/null 2>&1 && LINGER_ENABLED=1
    elif command -v sudo >/dev/null 2>&1 && sudo -n loginctl enable-linger "$LINGER_USER" >/dev/null 2>&1; then
      LINGER_ENABLED=1
    fi
    if [ "$LINGER_ENABLED" -ne 1 ]; then
      echo "WARNING: user lingering is not enabled; the Dashboard may stop after you log out."
      echo "Run once as an administrator:"
      echo "  sudo loginctl enable-linger $LINGER_USER"
    fi
  fi
fi

step "Setting up the Dashboard sign-in"
begin_transaction
write_auth_scripts
write_probe
LOGIN_PW_FILE_FLAG=0
[ "$PASSWORD_STDIN" -eq 0 ] || LOGIN_PW_FILE_FLAG=1
auth_status=0
# A generated password comes back in a file made here, private from the start and
# inside the transaction folder (owner only), not on standard output: whatever
# Hermes prints while it loads cannot end up inside the password.
NEW_PASSWORD_FILE="$TRANSACTION_DIR/new-password"
( umask 077; : > "$NEW_PASSWORD_FILE" ) || exit 1
# The password given on standard input reaches Python through a pipe made by a
# shell builtin: it is in no argument and in no environment variable.
printf '%s\n' "$DASH_PASSWORD" | HERMES_HOME="$HH" "$HP" "$WORK/auth.py" "$ACTION" "$HH" "$TRANSACTION_DIR/state" "$TRANSACTION_DIR/dashboard-access.previous.json" "$LOGIN_PW_FILE_FLAG" "$NEW_PASSWORD_FILE" 1>&2 || auth_status=$?
NEW_PASSWORD=""
IFS= read -r NEW_PASSWORD < "$NEW_PASSWORD_FILE" || true
rm -f "$NEW_PASSWORD_FILE"
if [ "$auth_status" -ne 0 ]; then
  echo "ERROR: Hermes would not accept the sign-in settings (its answer is above). Nothing was kept." >&2
  exit 1
fi
LOGIN_STATE="$(sed -n 's/^STATE=//p' "$TRANSACTION_DIR/state" | head -1)"
LOGIN_USER="$(sed -n 's/^USER=//p' "$TRANSACTION_DIR/state" | head -1)"
case "$LOGIN_STATE" in
  created|existing|pinned|other) ;;
  *) echo "ERROR: could not tell whether the Dashboard already has a sign-in." >&2; exit 1 ;;
esac
case "$LOGIN_STATE" in
  created) echo "Dashboard sign-in: a new one was made" ;;
  existing) echo "Dashboard sign-in: yours was kept as it is" ;;
  pinned) echo "Dashboard sign-in: written in $HH/.env, kept as it is" ;;
  other) echo "Dashboard sign-in: another provider is configured, kept as it is" ;;
esac

step "Writing the Dashboard service"
cat > "$DASHBOARD_RUNNER.new" <<EOF
#!/bin/sh
export HERMES_HOME="$HH"
# systemd and launchd do not inherit the user's PATH: add the node Hermes manages
# and the usual Homebrew locations so the Dashboard can build its web UI.
export PATH="$HH/node/bin:$HH/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH"
cd "$HH"
exec "$HB" dashboard --host "$BIND_HOST" --port "$DASHBOARD_PORT" --no-open >> "$LOGS/dashboard.log" 2>&1
EOF
chmod 700 "$DASHBOARD_RUNNER.new"
mv "$DASHBOARD_RUNNER.new" "$DASHBOARD_RUNNER"

install_systemd_unit() {
  mkdir -p "$(dirname -- "$DASH_UNIT")" "$WORK/unit"
  staged="$WORK/unit/hermes-dashboard.service"
  "$VP" -I - "$staged" "$DASHBOARD_RUNNER" "$HH" <<'PY'
import pathlib, sys

unit, runner, workdir = sys.argv[1:]


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
Description=Hermes Console dashboard
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
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
  chmod 644 "$staged"
  if command -v systemd-analyze >/dev/null 2>&1 && ! systemd-analyze --user verify "$staged"; then
    echo "ERROR: systemd did not accept the Dashboard unit (systemd-analyze --user verify, its answer is above)." >&2
    return 1
  fi
  cp "$staged" "$DASH_UNIT.new"
  mv "$DASH_UNIT.new" "$DASH_UNIT"
}

install_launchd_job() {
  assert_launchd_plist_owner "$DASH_LABEL"
  assert_loaded_launchd_job_owner "$DASH_LABEL"
  mkdir -p "$HOME/Library/LaunchAgents"
  rm -f "$DASH_PLIST.new"
  "$VP" -I - "$DASH_PLIST.new" "$DASH_LABEL" "$DASHBOARD_RUNNER" "$HH" "$LOGS/dashboard.log" <<'PY'
import pathlib, plistlib, sys
path, label, runner, workdir, log = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": [runner],
    "WorkingDirectory": workdir,
    "RunAtLoad": True,
    "KeepAlive": {"SuccessfulExit": False},
    "ProcessType": "Background",
    "StandardOutPath": log,
    "StandardErrorPath": log,
}
with pathlib.Path(path).open("xb") as out:
    plistlib.dump(payload, out, sort_keys=True)
PY
  chmod 600 "$DASH_PLIST.new"
  assert_loaded_launchd_job_owner "$DASH_LABEL"
  launchctl bootout "gui/$(id -u)/$DASH_LABEL" >/dev/null 2>&1 || true
  mv "$DASH_PLIST.new" "$DASH_PLIST"
  # bootout is asynchronous: a bootstrap straight after it can find the old job
  # still going away. Every call is checked; the bootstrap gets a second try.
  if ! launchctl bootstrap "gui/$(id -u)" "$DASH_PLIST" 2>/dev/null; then
    launchctl bootout "gui/$(id -u)/$DASH_LABEL" >/dev/null 2>&1 || true
    sleep 2
    if ! launchctl bootstrap "gui/$(id -u)" "$DASH_PLIST"; then
      echo "ERROR: launchd would not load $DASH_LABEL." >&2
      return 1
    fi
  fi
  launchctl enable "gui/$(id -u)/$DASH_LABEL" >/dev/null 2>&1 || true
}

step "Starting the Dashboard in the background"
SERVICE_LIFECYCLE_TOUCHED=1
case "$SERVICE_MANAGER" in
  systemd)
    install_systemd_unit
    if ! systemctl --user daemon-reload; then
      echo "ERROR: systemd did not reload user units." >&2
      exit 1
    fi
    if ! systemctl --user enable hermes-dashboard; then
      echo "ERROR: systemd would not enable the Dashboard service (its answer is above)." >&2
      exit 1
    fi
    if ! systemctl --user restart hermes-dashboard; then
      echo "ERROR: systemd could not start the Dashboard." >&2
      exit 1
    fi
    ;;
  launchd)
    install_launchd_job
    ;;
  portable)
    write_dash_helper
    portable_dashboard restart
    echo "WARNING: no supported persistent service manager is available."
    echo "The Dashboard works in this session but will not survive a reboot until a startup manager is configured."
    ;;
esac

# The first start of a freshly built Hermes on a cold machine compiles the web UI
# and can take minutes; a warm restart answers at once. The wait goes on while
# the log keeps growing (real progress), up to 30 minutes, and stops when it does not.
START_WAIT="${HERMES_SETUP_START_WAIT:-240}"
dashboard_ready=0
dashboard_elapsed=0
dashboard_last_size=0
while [ "$dashboard_elapsed" -lt 1800 ]; do
  if "$VP" -I "$WORK/probe.py" "$DASHBOARD_BASE" alive admin >/dev/null 2>&1 </dev/null; then
    dashboard_ready=1
    break
  fi
  sleep 1
  dashboard_elapsed=$((dashboard_elapsed + 1))
  if [ "$dashboard_elapsed" -lt "$START_WAIT" ]; then
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
[ "$dashboard_ready" -eq 1 ] || service_failure

step "Checking the Dashboard like the app will"
verify_status=0
if [ "$LOGIN_STATE" = "created" ]; then
  # The password this run just made (or was given) must really open the Dashboard.
  printf '%s\n' "${NEW_PASSWORD:-$DASH_PASSWORD}" | "$VP" -I "$WORK/probe.py" "$DASHBOARD_BASE" login "$LOGIN_USER" || verify_status=$?
else
  "$VP" -I "$WORK/probe.py" "$DASHBOARD_BASE" refuse "$LOGIN_USER" </dev/null || verify_status=$?
fi
if [ "$verify_status" -ne 0 ]; then
  if [ "$verify_status" -eq 10 ]; then
    echo "ERROR: the Dashboard did not accept the sign-in this setup just made." >&2
  else
    echo "ERROR: the Dashboard is running but failed its checks." >&2
  fi
  exit 1
fi
echo "Dashboard answers at $DASHBOARD_BASE, refuses whoever is not signed in${NEW_PASSWORD:+ and accepts the new sign-in}"

commit_transaction
DASH_PASSWORD=""
# The earlier setup kept its Dashboard password in clear in this file. A new
# sign-in makes that record stale, so it goes with it.
if [ "$LOGIN_STATE" = "created" ]; then
  rm -f "$SERVICES/dashboard-login.json"
fi

printf '\n== DASHBOARD READY ==\n\n'
echo "Dashboard: $DASHBOARD_BASE"
echo "Gateway: not touched"
case "$LOGIN_STATE" in
  created)
    echo ""
    echo "Sign in with:"
    echo "  user:     $LOGIN_USER"
    if [ -n "$NEW_PASSWORD" ]; then
      echo "  password: $NEW_PASSWORD"
      echo "This password is shown now and is not saved anywhere in clear."
      echo "Forgot it later? Run this again with --new-access to make a new one."
    else
      echo "  password: as you gave it on standard input (not shown, not saved in clear)"
    fi
    echo "A sign-in kept only in an external secret source (a secret manager Hermes is set up"
    echo "to use) is not read by this setup: if you have one, this password was added next to it."
    ;;
  existing)
    echo ""
    echo "The sign-in this Hermes already had was kept as it is, so no password is shown."
    echo "Forgot it? Run this again with --new-access to make a new one."
    ;;
  pinned)
    echo ""
    echo "The password is written in $HH/.env (the lines that start with"
    echo "HERMES_DASHBOARD_BASIC_AUTH_). This setup does not change that file."
    echo "No new sign-in was made. Change it there and restart the Dashboard if you want another."
    ;;
  other)
    echo ""
    echo "Another sign-in provider is configured for this Dashboard. No new sign-in was made"
    echo "and the configuration was not changed."
    ;;
esac
if [ -f "$SERVICES/dashboard-login.json" ]; then
  echo ""
  echo "WARNING: $SERVICES/dashboard-login.json still holds a Dashboard password"
  echo "in clear, written by the earlier Console setup. This run did not touch it;"
  echo "delete it yourself if you do not want that password stored."
fi
case "$SERVICE_MANAGER" in
  portable) echo "Starts by itself after a restart: no (this system has no service manager)" ;;
  *) echo "Starts by itself after a restart: yes ($SERVICE_MANAGER)" ;;
esac
echo "Address: $BIND_HOST ($NETWORK_KIND), the only one the Dashboard listens on."
if { command -v ufw >/dev/null 2>&1 && [ -r /etc/ufw/ufw.conf ] && grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; } || \
   { command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; }; then
  echo "A firewall is active here and this setup did not change it. If the app cannot connect,"
  echo "allow TCP $DASHBOARD_PORT from your own network only, for example (ufw):"
  echo "  sudo ufw allow from <your network> to any port $DASHBOARD_PORT proto tcp"
fi
echo "Keep the password private: whoever has it can use your Hermes."
