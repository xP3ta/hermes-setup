# Patch: safe-setup-idempotency

## Problem
Repair mode could misclassify a transient health-probe failure as a broken install, then a slow hidden reinstall could collide with a second setup run. The first lock repair held an exclusive FileStream for setup, but the timeout path still threw while deliberately leaving the installer alive; the outer finally then released the lock before venv mutation ended.

## Corrected behavior
1. **Idempotent health guard** — three retries plus `hermes_cli` import fallback before destructive reinstall.
2. **Soft installer timeout** — `-InstallerTimeoutSec` defaults to 900s. Without `-ForceClose`, crossing the threshold only emits a warning; setup remains alive and continues waiting for the installer, so `.setup-lock` stays held until the process exits.
3. **Tree-aware force-close** — `-ForceClose` terminates the timed-out installer **and its descendants** before setup can unwind and release the lock. Windows PowerShell 5.1 and PowerShell 7+ on Windows use `taskkill.exe /PID <pid> /T /F`; PowerShell Core on Linux/macOS uses a `ps`-derived descendant graph and stops descendants deepest-first. The helper verifies the captured PID set and does not return to the lock owner while tracked descendants remain alive.
4. **Portable process primitive** — `process-tree.ps1` contains only the host process-tree adapter; it carries no Hermes policy and no external framework/runtime internals.
5. **Single-flight lock** — the exclusive `.setup-lock` FileStream remains open for the complete setup lifetime.
6. **Regression tests** — `test-lock.ps1` parses both scripts, proves the exclusive handle lifecycle, verifies stale-file recovery, exercises timeout followed immediately by a second acquisition attempt, and spawns a PowerShell parent/child tree to prove ForceClose removes both processes rather than only the parent.

## Evidence discipline
The previous revision overstated its evidence by referring to `test-lock.ps1` when that file was not present and by treating a lock-handle test as proof of the installer-timeout lifecycle. This revision corrects both errors. The stale generated `.diff` remains removed rather than retained as conflicting evidence.

## Run the regression
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-lock.ps1
pwsh -NoProfile -File .\test-lock.ps1
```

The test is intentionally host-agnostic at the PowerShell process-control boundary: on Windows it verifies the `taskkill /T /F` adapter, while on PowerShell Core Unix-like hosts it exercises the descendant-discovery/child-first termination path.
