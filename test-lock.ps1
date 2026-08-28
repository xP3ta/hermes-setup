[CmdletBinding()]
param(
    [string]$SetupScript = (Join-Path $PSScriptRoot "hermes-mobile-setup.ps1")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

function Test-ExclusiveAcquire([string]$Path) {
    try {
        $stream = [IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None')
        try { return $true } finally { $stream.Dispose() }
    } catch [IO.IOException] {
        return $false
    }
}

if (-not (Test-Path -LiteralPath $SetupScript)) {
    throw "Setup script not found: $SetupScript"
}

$source = Get-Content -LiteralPath $SetupScript -Raw
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput(
    $source, [ref]$tokens, [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) "hermes-mobile-setup.ps1 parses cleanly"

$enterFn = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Enter-SetupLock"
}, $true)
$exitFn = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Exit-SetupLock"
}, $true)
$installFn = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Install-HermesIfNeeded"
}, $true)

Assert-True ($null -ne $enterFn) "Enter-SetupLock exists"
Assert-True ($null -ne $exitFn) "Exit-SetupLock exists"
Assert-True ($null -ne $installFn) "Install-HermesIfNeeded exists"

$installText = $installFn.Extent.Text
Assert-True (
    $installText -match "continuing to wait while the setup lock remains held"
) "default timeout path explicitly preserves lock ownership while waiting"
Assert-True (
    $installText -notmatch "leaving it running detached"
) "default timeout path no longer detaches installer from lock owner"
Assert-True (
    $installText -notmatch "Hermes installer still running after .*It was NOT killed"
) "default timeout path no longer throws while installer is still running"

$temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-lock-review-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$lockPath = Join-Path $temp ".setup-lock"

try {
    function Write-Audit([string]$Step, [string]$State, [string]$Detail = "") {}
    Invoke-Expression $enterFn.Extent.Text
    Invoke-Expression $exitFn.Extent.Text
    $script:SetupLock = $lockPath
    $script:SetupLockStream = $null

    Enter-SetupLock
    Assert-True ($null -ne $script:SetupLockStream) "setup retains the exclusive FileStream"
    Assert-True (-not (Test-ExclusiveAcquire $lockPath)) "second acquirer is blocked while setup lock is held"
    Exit-SetupLock
    Assert-True (Test-ExclusiveAcquire $lockPath) "Exit-SetupLock releases exclusivity"

    $stale = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    $stale.Dispose()
    Assert-True (Test-ExclusiveAcquire $lockPath) "stale lock file does not deadlock the next run"

    $holderScript = Join-Path $temp "holder.ps1"
    $readyPath = Join-Path $temp "holder.ready"
    @'
param([string]$LockPath, [string]$ReadyPath)
$ErrorActionPreference = "Stop"
$stream = [IO.File]::Open($LockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    Set-Content -LiteralPath $ReadyPath -Value "ready" -Encoding ASCII
    Start-Sleep -Milliseconds 2600
} finally {
    $stream.Dispose()
}
'@ | Set-Content -LiteralPath $holderScript -Encoding UTF8

    $hostExe = (Get-Process -Id $PID).Path
    $holder = Start-Process -FilePath $hostExe -ArgumentList @(
        "-NoProfile",
        "-File", $holderScript,
        "-LockPath", $lockPath,
        "-ReadyPath", $readyPath
    ) -PassThru

    $readyWatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $readyPath) -and $readyWatch.Elapsed.TotalSeconds -lt 10) {
        if ($holder.HasExited) {
            throw "holder exited before acquiring the lock (exit $($holder.ExitCode))"
        }
        Start-Sleep -Milliseconds 50
    }
    Assert-True (Test-Path -LiteralPath $readyPath) "simulated first run signaled lock ownership"
    Assert-True (-not (Test-ExclusiveAcquire $lockPath)) "first run owns lock before timeout"

    Start-Sleep -Milliseconds 1100
    Assert-True (-not (Test-ExclusiveAcquire $lockPath)) "timeout followed by immediate second run remains blocked"

    $holder.WaitForExit()
    Assert-True ($holder.ExitCode -eq 0) "simulated long installer exits cleanly"
    Assert-True (Test-ExclusiveAcquire $lockPath) "second run can acquire only after installer completion"

    Write-Host "ALL PASS"
} finally {
    try {
        if ($script:SetupLockStream) { $script:SetupLockStream.Dispose() }
    } catch {}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
