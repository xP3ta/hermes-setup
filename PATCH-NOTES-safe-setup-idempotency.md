# Patch: safe-setup-idempotency

## Problem (observed in production, 2026-08-23)
`hermes-mobile-setup.ps1` repair mode failed twice consecutively:

1. `Get-HermesExecutable` found `venv\Scripts\hermes.exe`, but a single
   transient `--version` probe failure reclassified the healthy install as
   broken and triggered a full reinstall.
2. The reinstall ran hidden with a hard **180s timeout**, but the official
   installer routinely needs 5-10 minutes on Windows (PortableGit download,
   venv recreate, full dependency install). It was killed mid-run during the
   `uv.lock` dependency tier — twice — leaving a half-built venv and all
   three console services (gateway :8642, dashboard :9119, bridge :9131) down.

Audit log evidence (`safe-setup-audit.jsonl`):
```
{"step":"Hermes Console","state":"INFO","detail":"Installing Hermes Agent for native Windows..."}
{"step":"Setup","state":"ERROR","detail":"Hidden process timed out after 180s: ...pwsh.exe"}
```
(repeated on two consecutive runs, ~3 minutes apart)

## Fix
1. **Idempotent health guard** — `Test-HermesHealthy`: 3 retries with backoff
   plus a `hermes_cli` venv-import fallback before declaring an install broken.
2. **Safe installer timeout** — default 900s via `-InstallerTimeoutSec`. On
   timeout the installer keeps running detached so it can finish rebuilding
   the venv; `-ForceClose` restores the old kill behavior explicitly;
   `-Interactive` runs the installer attached with live output.
3. **Single-flight lock** — `.setup-lock` exclusive-open makes overlapping
   setup runs wait instead of corrupting each other's venv rebuild.

## Validation (live Windows 11 host, RTX laptop, PowerShell 7.6.5)
- Parser check: clean.
- `-AuditOnly` on the broken system correctly listed only genuinely-down
  items; "Healthy Hermes Agent executable" no longer falsely flagged.
- Full repair run with patched script: gateway ready 9.7s + auth passed,
  bridge 1.18.0 health/auth/self-update passed, dashboard ready 2.4s,
  all scheduled tasks registered, firewall rule installed+verified.
- Phone-facing check fail-closed correctly when Tailscale runs under a
  different local account (environment issue, not script).

Full unified diff: `docs-safe-setup-idempotency.diff` (118+/17-).
