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

That's it. When it finishes, it prints a QR code — scan it with the app (or copy the `hermes://pair?...` link) and you're connected.

WSL deliberately uses the Windows path so setup can configure networking,
Windows Firewall and persistent startup correctly. The Unix installer uses
`systemd --user` on Linux and `launchd` on macOS. On
Unix environments without either manager it starts a safe per-user fallback
and warns that the processes will not survive a reboot. The Windows installer
uses per-user Scheduled Tasks (with a Startup-folder fallback), stores no token
in task arguments and only creates restricted Windows Firewall rules for
**Private/LAN or Tailscale** sources when PowerShell is already elevated.

## What it does

The setup is **idempotent**: it preserves existing keys and can safely be run
again for a fresh install, a repair or a Bridge update.

1. Installs Hermes Agent if the machine doesn't have it (non-interactive, no browser needed).
2. Ensures a strong API token exists (`API_SERVER_KEY` in `~/.hermes/.env` on Unix
   or `%LOCALAPPDATA%\hermes\.env` on Windows). Existing tokens are never
   changed when they are already strong; missing, weak or duplicated defaults
   are repaired.
3. Starts three services using the host's native per-user service manager:
   - **Gateway** (`:8642`) — the OpenAI-compatible API the app talks to.
   - **Dashboard** (`:9119`) — the web admin UI.
   - **Mobile Bridge** (`:9131`) — the app's companion service (downloaded from this same repo).
4. Configures Dashboard authentication on first install without replacing an
   existing password.
5. Verifies the actual services, not just listening ports: Gateway health plus
   authenticated sessions, Bridge identity/auth/scopes/self-update, Dashboard
   status, and the exact address the phone will use.
6. Only after every check passes, prints a QR/link containing the Gateway,
   Dashboard, Bridge URL and Bridge token. It prefers **mesh VPN** (Tailscale,
   NetBird/CGNAT), then private LAN. Public hosts require HTTPS; loopback and
   public HTTP are rejected before any token is sent.

For a brand-new Hermes install, the infrastructure is then ready for the app;
you still choose the AI provider/model from Hermes Console's Dashboard.

## Security notes

- The services listen on the address needed by the phone. Prefer Tailscale or a
  trusted LAN. Setup opens UFW/firewalld/Windows Firewall only for private LAN
  or Tailscale sources; it never creates a public-internet rule.
- Public access must use HTTPS with a valid reverse proxy. The verifiers block
  public HTTP before transmitting the Gateway or Bridge token.
- No telemetry or hosted relay. Setup downloads Hermes from its official
  installer, the Bridge from this repository and, only when needed, the
  `qrcode` package used to render the pairing code. Your server token stays on
  the host and in the pairing link you control.
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

It validates the saved pairing record and rechecks Gateway, Dashboard and
Bridge through the phone-facing address. If any service is down, unauthenticated
or lacks Bridge self-update support, it stops without exposing a QR and asks you
to rerun the full setup. If the services pass, it can render via `qrencode`, a
temporary Python renderer or the verified link fallback.

## Updating the Mobile Bridge

Recent versions update through the app's authenticated **Mobile Bridge** panel:
the app validates the release metadata, size, SHA-256 and version, asks the
Bridge to replace itself atomically, and confirms the new process is healthy.
Rerunning the full setup command remains the repair/bootstrap path for an older
Bridge that predates self-update.

## Contents

| File | What it is |
|---|---|
| `hermes-mobile-setup.sh` | The installer (readable top to bottom) |
| `hermes-mobile-setup.ps1` | Native Windows installer |
| `hermes-pair.sh` | Prints the pairing QR/link on demand (no reinstall) |
| `hermes-pair.ps1` | Native Windows pairing QR/link |
| `hermes_bridge.py` | The Mobile Bridge deployed under the platform's Hermes home |
| `bridge-release.json` | Machine-readable Bridge version, compatible app build, SHA-256 and byte size |
| `sync-from-app.sh` | Maintainer-only synchronization and release helper |

## Maintenance

The source of truth for the five public runtime files lives in the app repository
(`scripts/hermes-mobile-setup.sh`, `scripts/hermes-mobile-setup.ps1`,
`scripts/hermes-pair.sh`, `scripts/hermes-pair.ps1` and
`assets/bridge/hermes_bridge.py`). Whenever any of them changes there, this repo
must be updated in the same release:
the app hands out this exact `curl` command during onboarding **and** when
offering bridge updates, so this repo has to stay in sync with the bridge
asset shipped inside the published app.

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
