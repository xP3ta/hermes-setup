# Patch: safe-setup-idempotency

## Problem
Repair mode could misclassify a transient health-probe failure as a broken install, then a slow hidden reinstall could collide with a second setup run. The first lock repair held an exclusive FileStream for setup, but the timeout path still threw while deliberately leaving the installer alive; the outer finally then released the lock before venv mutation ended.

## Corrected behavior
1. **Idempotent health guard** — three retries plus `hermes_cli` import fallback before destructive reinstall.
2. **Soft installer timeout** — `-InstallerTimeoutSec` defaults to 900s. Without `-ForceClose`, crossing the threshold only emits a warning; setup remains alive and continues waiting for the installer, so `.setup-lock` stays held until the process exits.
3. **Explicit force-close** — `-ForceClose` kills the timed-out installer and confirms process exit before setup can unwind and release the lock.
4. **Single-flight lock** — the exclusive `.setup-lock` FileStream remains open for the complete setup lifetime.
5. **Regression test** — `test-lock.ps1` parses the setup source, proves the exclusive handle lifecycle, verifies stale-file recovery, and exercises timeout followed immediately by a second acquisition attempt; the second run must remain blocked until the simulated installer exits. The child signals only after its exclusive handle is open, so the proof has no startup timing race.

## Evidence discipline
The previous revision overstated its evidence by referring to `test-lock.ps1` when that file was not present and by treating a lock-handle test as proof of the installer-timeout lifecycle. This revision corrects both errors. The stale generated `.diff` has been removed rather than retained as conflicting evidence.

## Run the regression
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-lock.ps1
pwsh -NoProfile -File .\test-lock.ps1
```
