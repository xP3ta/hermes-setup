# Hermes Setup

One-command installer that connects a self-hosted [Hermes Agent](https://hermes-agent.nousresearch.com) server to **Hermes Console** (the Android app).

## Install

Linux, macOS, Termux and other Unix hosts:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh
```

Windows and WSL2 (run this in **Windows PowerShell 5.1+**, outside WSL):

```powershell
irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1 | iex
```

That's it. When it finishes, it shows a code — scan it with the app (or copy the `hermes://pair?...` link) and you're connected: the code carries the address of this computer, its key and the Dashboard sign-in, so the app needs nothing typed by hand.

It sets up the two services of Hermes itself that the app talks to, the **Gateway** and the **Dashboard**. It installs no companion service: the Mobile Bridge of earlier versions is gone ([removing an old one](#removing-the-old-mobile-bridge)).

### Check the environment first (recommended)

Setup is read-only until it starts installing. If you want to see what your
machine is missing **before** anything happens, run the preflight (Windows):

```powershell
irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1 -OutFile "$env:TEMP\hermes-setup.ps1"
& "$env:TEMP\hermes-setup.ps1" -Preflight
```

It prints one line per condition (Windows edition, PowerShell, elevation,
HERMES_HOME, outbound network, LAN/Tailscale address, ports, Dashboard
toolchain, disk space, existing install) and, for anything red, the exact
command that fixes it. Nothing is downloaded or changed.

### When something goes wrong

```powershell
& "$env:TEMP\hermes-setup.ps1" -Diagnose
```

It writes `%LOCALAPPDATA%\hermes\audit\hermes-diagnose-<timestamp>.txt` with
versions, Scheduled Task/listener/firewall state, log tails and the audit
trail — no tokens, API keys or pairing credentials. Share that file when asking
for help: it is the difference between guessing and fixing.

**Removing everything setup created.** If you end up stuck, or you simply want a
clean slate, the installer can reverse itself. It stops and deletes only its own
Scheduled Tasks, its own firewall rules and the pairing artifacts (`-Purge`
additionally removes the Hermes home, and refuses to do so for a path that is
not a Hermes Console home):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\hermes-setup.ps1" -Uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\hermes-setup.ps1" -Uninstall -Purge
```

On Unix: `sh hermes-mobile-setup.sh --uninstall` is not a thing yet; services and
firewall rules are removed with `systemctl --user disable --now hermes-gateway
hermes-dashboard` plus your firewall tool of choice.

### Ports already in use

Setup refuses to touch a host whose ports belong to another process: 8642
(Gateway) and 9119 (Dashboard) are fixed defaults, but you can move them. The
override is honoured by the service runners, the firewall rule, the readiness
probes and the pairing link, so nothing keeps pointing at the old port. They
must be two different valid ports; anything else fails before changing the
machine.

```powershell
$env:HERMES_GATEWAY_PORT = "18642"
$env:HERMES_DASHBOARD_PORT = "19119"
```

```sh
HERMES_GATEWAY_PORT=18642 HERMES_DASHBOARD_PORT=19119 sh hermes-mobile-setup.sh
```

### First start on a slow machine

The Dashboard is built on first start. On slow disks, with antivirus scanning
`node_modules`, or a two-core laptop, that can outlive a fixed timeout: setup now
extends the wait while the Dashboard task is still running (up to 30 minutes) and
writes the extension to the audit log, instead of reporting a false failure. The
build is only trusted once the service answers on its own port.

### More than one network address

A machine with a VPN, Hyper-V/WSL adapters or a second NIC has several candidate
addresses. If the first one cannot be reached from the phone side, setup now
probes the other candidates (at most three) and adopts the first that really
answers, instead of failing with an address your phone cannot reach.

For a reproducible install that cannot change under you, use the newest tag
instead of `main` (e.g.
`https://raw.githubusercontent.com/xP3ta/hermes-setup/setup-v1.4.0/hermes-mobile-setup.ps1`).

WSL deliberately uses the Windows path so setup can configure networking,
Windows Firewall and persistent startup correctly. The Unix installer uses
`systemd --user` on Linux and `launchd` on macOS. On
Unix environments without either manager it starts a safe per-user fallback
and warns that the processes will not survive a reboot. The Windows installer
uses exactly three per-user Scheduled Tasks (no Startup-folder fallback),
stores no token in task arguments and only creates restricted Windows Firewall
rules for **Private/LAN or Tailscale** sources when PowerShell is already
elevated; without elevation it fails before changing anything and tells you to
rerun from an elevated terminal.

## What it does

The setup is **idempotent**: it preserves existing keys and sign-ins and can
safely be run again for a fresh install or a repair.

1. Installs Hermes Agent if the machine doesn't have it (non-interactive, no browser needed).
2. Ensures a strong API token exists (`API_SERVER_KEY` in `~/.hermes/.env` on Unix
   or `%LOCALAPPDATA%\hermes\.env` on Windows). Existing tokens are never
   changed when they are already strong; missing, weak or duplicated defaults
   are repaired.
3. Starts two services using the host's native per-user service manager:
   - **Gateway** (`:8642`) — the OpenAI-compatible API the app talks to.
   - **Dashboard** (`:9119`) — the web admin UI, and what the app uses for
     everything that is not plain chat.
4. Makes sure the Dashboard has a sign-in, through Hermes' own configuration
   API (the calls `hermes dashboard` makes when it asks for a password):
   - Hermes has none: one is created and shown once, for your browser.
   - It has one this setup knows (it made it earlier, or it is written in
     `.env` or in the configuration): it is kept.
   - It has one this setup does not know: it is kept and left out of the code;
     the app asks for it once. Setup never replaces a password on its own.
5. Verifies the actual services, not just listening ports: Gateway health plus
   authenticated sessions, Dashboard status, a real sign-in with the sign-in
   that goes into the code, and the exact address the phone will use.
6. Only after every check passes, shows a code/link containing the Gateway
   address and key, the Dashboard address and, when known, the Dashboard
   sign-in. It prefers **mesh VPN** (Tailscale, NetBird/CGNAT), then private
   LAN. Public hosts require HTTPS; loopback and public HTTP are rejected
   before any token is sent.

A setup that fails puts back what it changed, the Dashboard sign-in included.

For a brand-new Hermes install, the infrastructure is then ready for the app;
you still choose the AI provider/model from Hermes Console's Dashboard.

## Platforms covered by native evidence

| Platform | How it is validated |
|---|---|
| Windows 10/11 | Native VM: full install, rerun, rollback, ports, uninstall, and the reviewer suite (275 checks, zero skips) under Windows PowerShell 5.1 and PowerShell 7 |
| Windows Server 2022 | CI runner: the same reviewer suite |
| Debian 13 (systemd 257) | Native host: full install, idempotent rerun, authenticated probes, contract suite |
| macOS (Apple Silicon) | CI runner: POSIX syntax under BSD `/bin/sh`, the contract suite, a real `launchctl` lifecycle test driven by the installer's own functions, and a full isolated install with authenticated probes |
| macOS (Intel), Linux ARM64/Termux, Windows ARM64 | **Not validated natively.** Supported by code and unit tests only; treat them as unproven until they run the same gates |

The macOS row exists because "it works on Linux" is not evidence for macOS: it
uses launchd instead of systemd, a BSD userland, and neither `systemd-analyze`
nor `ufw`. That gap hid two real defects (a here-document that made the script
unparseable under bash 3.2, and a Dashboard runner without the managed node on
its PATH) until the macOS job was added.

## Security notes

- The services listen on the address needed by the phone. Prefer Tailscale or a
  trusted LAN. Setup opens UFW/firewalld/Windows Firewall only for private LAN
  or Tailscale sources; it never creates a public-internet rule.
- Public access must use HTTPS with a valid reverse proxy. The verifiers block
  public HTTP before transmitting the Gateway token.
- The code and the link carry the Gateway key and the Dashboard sign-in: treat
  them like a password. The sign-in setup created is kept in
  `console-services/dashboard-login.json` inside the Hermes home, readable only
  by your user, so the code can be shown again.
- No telemetry or hosted relay. Setup downloads Hermes from its official
  installer and, only when needed, the `qrcode` package used to render the
  pairing code. Your server token stays on the host and in the pairing link you
  control.
- Both installers are plain, auditable source and are meant to be read before
  running: [`hermes-mobile-setup.sh`](hermes-mobile-setup.sh) and
  [`hermes-mobile-setup.ps1`](hermes-mobile-setup.ps1).

## Show the pairing QR again

Already installed and just need to pair another phone (or re-pair)? This
prints the QR + link again without installing or restarting anything:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-pair.sh | sh
```

On Windows or WSL2 (again from Windows PowerShell, outside WSL):

```powershell
irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-pair.ps1 | iex
```

It validates the saved pairing record and rechecks Gateway and Dashboard
through the phone-facing address. If a service is down or unauthenticated, it
stops without exposing a code and asks you to rerun the full setup. The
Dashboard sign-in on record goes into the code only while the Dashboard still
accepts it. It changes nothing on disk.

## A new Dashboard sign-in

Forgot the Dashboard password, or want to cut off a phone or browser that is
signed in? One command makes a new sign-in, ends the sessions opened with the
old one, and shows a new code:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh -s -- --new-access
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1))) -NewAccess
```

If the password is written in `.env` (`HERMES_DASHBOARD_BASIC_AUTH_*`), that
file wins inside Hermes and this command does not edit it: it says so and shows
the code with the sign-in that is there. On a Unix host without systemd or
launchd, stop the two services first; the message names the two commands.

## Removing the old Mobile Bridge

Earlier versions installed a third service, the Mobile Bridge. The app no
longer uses it. This stops and removes it and nothing else — Gateway and
Dashboard are not touched, so the app stays connected. Running it twice, or on
a computer that never had one, changes nothing:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh -s -- --retire-bridge
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.ps1))) -RetireBridge
```

It removes the bridge's service (`hermes-bridge.service`, the
`dev.xpetalab.hermes-console.bridge` job, or the `HermesConsole-MobileBridge`
and `HermesConsole-Restart-MobileBridge` tasks), the process that runs it and
its files (`hermes_bridge.py`, `bridge.env`, its runner). Its backups under
`backups/bridge` and its logs are yours and stay. A firewall rule that opened
port 9131 can be deleted; nothing listens there any more.

`hermes_bridge.py` and `bridge-release.json` stay in this repository only for
apps older than 1.2.15, which still update a bridge they already have. Setup
does not download or start them.

## Minimal Debian and systemd troubleshooting

The Unix installer supports minimal Debian hosts without PolicyKit. It first
checks whether user lingering is already enabled and only attempts a
non-interactive change when running as root or when passwordless `sudo` is
already available. Otherwise it prints the single administrator command to run;
it does not open a `pkttyagent` prompt.

Setup keeps the Gateway unit owned by Hermes itself. The phone-facing bind is
stored in a separate `hermes-gateway.service.d` drop-in, so a Hermes update or
in-chat restart can regenerate its canonical unit without silently reverting to
loopback. The Dashboard unit is rendered in a temporary
directory, and both effective units pass `systemd-analyze --user verify`
when available before they are started. A failed preflight restores the previous
Gateway unit and drop-in. If an older install reports `bad unit file setting` or
the Gateway only listens on `127.0.0.1`, rerun the current installer. For
diagnostics, inspect the affected unit without sharing tokens or the pairing
link:

```sh
systemctl --user status hermes-gateway.service
journalctl --user -u hermes-gateway.service
```

## Contents

| File | What it is |
|---|---|
| `hermes-mobile-setup.sh` | The installer (readable top to bottom) |
| `hermes-mobile-setup.ps1` | Native Windows installer |
| `hermes-pair.sh` | Prints the pairing QR/link on demand (no reinstall) |
| `hermes-pair.ps1` | Native Windows pairing QR/link |
| `hermes_bridge.py` | The retired Mobile Bridge, kept for apps older than 1.2.15 that still update theirs; setup does not install it |
| `bridge-release.json` | Machine-readable Bridge version, compatible app build, SHA-256 and byte size |
| `sync-from-app.sh` | Maintainer-only helper from when the app repository was the source of these files |

## Maintenance

This repository is the source of truth for the four setup scripts
(`hermes-mobile-setup.sh`, `hermes-mobile-setup.ps1`, `hermes-pair.sh`,
`hermes-pair.ps1`). The app only shows the commands above; it no longer ships
its own copies.

`sync-from-app.sh` dates from when the app repository held these files and the
bridge. From app 1.2.15 on there is nothing left there to copy from; it is kept
for the history of the bridge release it last produced.

Tests, all against disposable homes (nothing touches a real `~/.hermes`):

```sh
python3 tests/review-unix-security.py     # contract suite
python3 tests/no-bridge_test.py           # sign-in decision, code, --retire-bridge
python3 tests/no-bridge-install_test.py   # a whole setup against a stand-in Hermes
```

Preview a synchronization without modifying the working tree or Git index:

```sh
./sync-from-app.sh --dry-run
```

Running `./sync-from-app.sh` without options copies only the five canonical
sources, regenerates `bridge-release.json`, stages only those release files and
creates a local commit. It never pushes implicitly. Publishing requires the
explicit form:

```sh
./sync-from-app.sh --publish
```

The generated manifest has schema `1` and records `version`, `min_app_build`,
`sha256` and `size` for the exact bytes of `hermes_bridge.py` served by this
repository. `min_app_build` defaults to the app build in `pubspec.yaml` and can
be deliberately lowered for a backwards-compatible Bridge with
`BRIDGE_MIN_APP_BUILD=<build>`.
