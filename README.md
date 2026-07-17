# Hermes Setup

One-command installer that connects a self-hosted [Hermes Agent](https://hermes-agent.nousresearch.com) server to **Hermes Console** (the Android app).

On your server (Linux with `systemd`), run:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh
```

That's it. When it finishes, it prints a QR code — scan it with the app (or copy the `hermes://pair?...` link) and you're connected.

## What it does

Everything is **idempotent**: anything already installed and running is left untouched, so the same command works for a fresh server, a reinstall, or a bridge update.

1. Installs Hermes Agent if the machine doesn't have it (non-interactive, no browser needed).
2. Ensures an API token exists (`API_SERVER_KEY` in `~/.hermes/.env`). Existing tokens are never rotated.
3. Starts three `systemd --user` services that survive reboots:
   - **Gateway** (`:8642`) — the OpenAI-compatible API the app talks to.
   - **Dashboard** (`:9119`) — the web admin UI.
   - **Mobile Bridge** (`:9131`) — the app's companion service (downloaded from this same repo).
4. Prints the pairing QR + link, using the best address it can find: **mesh VPN first** (Tailscale, NetBird — CGNAT range), then private LAN, then public IP (with a clear exposure warning), then loopback.

## Security notes

- Everything listens on your private network (Tailscale/LAN); nothing is published to the internet unless your server only has a public IP — in that case the script warns you loudly and recommends a mesh VPN or firewall.
- No telemetry, no third-party services. The only credential involved is your own server's token.
- The script is short, plain POSIX `sh`, and meant to be read before you run it: [`hermes-mobile-setup.sh`](hermes-mobile-setup.sh).

## Show the pairing QR again

Already installed and just need to pair another phone (or re-pair)? This
prints the QR + link again without installing or restarting anything:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-pair.sh | sh
```

It warns you if the gateway or the bridge aren't running, and renders the QR
even without `qrencode` installed.

## Contents

| File | What it is |
|---|---|
| `hermes-mobile-setup.sh` | The installer (readable top to bottom) |
| `hermes-pair.sh` | Prints the pairing QR/link on demand (no reinstall) |
| `hermes_bridge.py` | The Mobile Bridge the installer deploys to `~/.hermes/` |
| `bridge-release.json` | Machine-readable Bridge version, SHA-256 and byte size |
| `sync-from-app.sh` | Maintainer-only synchronization and release helper |

## Maintenance

The source of truth for the three public runtime files lives in the app repository
(`scripts/hermes-mobile-setup.sh`, `scripts/hermes-pair.sh` and
`assets/bridge/hermes_bridge.py`). Whenever any of them changes there, this repo
must be updated in the same release:
the app hands out this exact `curl` command during onboarding **and** when
offering bridge updates, so this repo has to stay in sync with the bridge
asset shipped inside the published app.

Preview a synchronization without modifying the working tree or Git index:

```sh
./sync-from-app.sh --dry-run
```

Running `./sync-from-app.sh` without options copies only the three canonical
sources, regenerates `bridge-release.json`, stages only those release files and
creates a local commit. It never pushes implicitly. Publishing requires the
explicit form:

```sh
./sync-from-app.sh --publish
```

The generated manifest has schema `1` and records `version`, `sha256` and
`size` for the exact bytes of `hermes_bridge.py` served by this repository.
