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

## Contents

| File | What it is |
|---|---|
| `hermes-mobile-setup.sh` | The installer (readable top to bottom) |
| `hermes_bridge.py` | The Mobile Bridge the installer deploys to `~/.hermes/` |

## Maintenance

The source of truth for both files lives in the app repository
(`scripts/hermes-mobile-setup.sh` and `assets/bridge/hermes_bridge.py`).
Whenever either changes there, this repo must be updated in the same release:
the app hands out this exact `curl` command during onboarding **and** when
offering bridge updates, so this repo has to stay in sync with the bridge
asset shipped inside the published app.
