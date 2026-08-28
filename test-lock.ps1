[CmdletBinding()]
param(
    [string]$SetupScript = (Join-Path $PSScriptRoot "hermes-mobile-setup.ps1"),
    [string]$ProcessTreeHelper = (Join-Path $PSScriptRoot "process-tree.ps1")
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

function Test-PidAlive([int]$ProcessId) {
    try {
        [void](Get-Process -Id $ProcessId -ErrorAction Stop)
        return $true
    } catch {
        return $false
    }
}

if (-not (Test-Path -LiteralPath $SetupScript)) {
    throw "Setup script not found: $SetupScript"
}
if (-not (Test-Path -LiteralPath $ProcessTreeHelper)) {
    throw "Process-tree helper not found: $ProcessTreeHelper"
}

$source = Get-Content -LiteralPath $SetupScript -Raw
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput(
    $source, [ref]$tokens, [ref]$parseErrors
)
Assert-True ($parseErrors.Count -eq 0) "hermes-mobile-setup.ps1 parses cleanly"

$helperSource = Get-Content -LiteralPath $ProcessTreeHelper -Raw
$helperTokens = $null
$helperParseErrors = $null
$helperAst = [Management.Automation.Language.Parser]::ParseInput(
    $helperSource, [ref]$helperTokens, [ref]$helperParseErrors
)
Assert-True ($helperParseErrors.Count -eq 0) "process-tree.ps1 parses cleanly"

function Find-Function([Management.Automation.Language.Ast]$Root, [string]$Name) {
    return $Root.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
    }, $true)
}

$enterFn = Find-Function $ast "Enter-SetupLock"
$exitFn = Find-Function $ast "Exit-SetupLock"
$installFn = Find-Function $ast "Install-HermesIfNeeded"
$platformFn = Find-Function $helperAst "Test-WindowsPlatform"
$aliveFn = Find-Function $helperAst "Test-ProcessAlive"
$unixDescendantsFn = Find-Function $helperAst "Get-UnixDescendantProcessIds"
$stopTreeFn = Find-Function $helperAst "Stop-ProcessTree"

Assert-True ($null -ne $enterFn) "Enter-SetupLock exists"
Assert-True ($null -ne $exitFn) "Exit-SetupLock exists"
Assert-True ($null -ne $installFn) "Install-HermesIfNeeded exists"
Assert-True ($null -ne $platformFn) "Test-WindowsPlatform exists"
Assert-True ($null -ne $aliveFn) "Test-ProcessAlive exists"
Assert-True ($null -ne $unixDescendantsFn) "Get-UnixDescendantProcessIds exists"
Assert-True ($null -ne $stopTreeFn) "Stop-ProcessTree exists"

$installText = $installFn.Extent.Text
$stopTreeText = $stopTreeFn.Extent.Text
Assert-True (
    $source -match '(?m)^\.\s+\$ProcessTreeHelper\s*$'
) "setup imports the portable process-tree helper"
Assert-True (
    $installText -match "continuing to wait while the setup lock remains held"
) "default timeout path explicitly preserves lock ownership while waiting"
Assert-True (
    $installText -notmatch "leaving it running detached"
) "default timeout path no longer detaches installer from lock owner"
Assert-True (
    $installText -notmatch "Hermes installer still running after .*It was NOT killed"
) "default timeout path no longer throws while installer is still running"
Assert-True (
    $installText -match 'Stop-ProcessTree\s+-Process\s+\$process'
) "ForceClose terminates the installer process tree"
Assert-True (
    $source -notmatch '\.Kill\s*\('
) "setup contains no parent-only Process.Kill timeout path"
Assert-True (
    $stopTreeText -match '(?i)taskkill(?:\.exe)?' -and
    $stopTreeText -match '/T' -and
    $stopTreeText -match '/F'
) "Windows adapter uses taskkill /T /F for PowerShell 5.1-compatible tree termination"
Assert-True (
    $stopTreeText -match 'Get-UnixDescendantProcessIds' -and
    $stopTreeText -match 'Stop-Process'
) "PowerShell Core Unix adapter terminates discovered descendants before the root"

$temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-lock-review-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$lockPath = Join-Path $temp ".setup-lock"

try {
    function Write-Audit([string]$Step, [string]$State, [string]$Detail = "") {}
    Invoke-Expression $enterFn.Extent.Text
    Invoke-Expression $exitFn.Extent.Text
    . $ProcessTreeHelper
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
        "-File", "`"$holderScript`"",
        "-LockPath", "`"$lockPath`"",
        "-ReadyPath", "`"$readyPath`""
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

    # ForceClose regression: root PowerShell creates another PowerShell child.
    # The tree-aware primitive must remove both before the caller can release
    # the setup lock. This catches the exact uv/Git/Python/npm/cmd orphan class
    # reported in review without depending on any one child executable.
    $grandchildScript = Join-Path $temp "grandchild.ps1"
    $treeRootScript = Join-Path $temp "tree-root.ps1"
    $grandchildPidPath = Join-Path $temp "grandchild.pid"
    @'
Start-Sleep -Seconds 60
'@ | Set-Content -LiteralPath $grandchildScript -Encoding UTF8
    @'
param([string]$GrandchildScript, [string]$PidPath)
$ErrorActionPreference = "Stop"
$hostExe = (Get-Process -Id $PID).Path
$child = Start-Process -FilePath $hostExe -ArgumentList @(
    "-NoProfile", "-File", "`"$GrandchildScript`""
) -PassThru
Set-Content -LiteralPath $PidPath -Value $child.Id -Encoding ASCII
Start-Sleep -Seconds 60
'@ | Set-Content -LiteralPath $treeRootScript -Encoding UTF8

    $treeRoot = Start-Process -FilePath $hostExe -ArgumentList @(
        "-NoProfile",
        "-File", "`"$treeRootScript`"",
        "-GrandchildScript", "`"$grandchildScript`"",
        "-PidPath", "`"$grandchildPidPath`""
    ) -PassThru

    $treeWatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $grandchildPidPath) -and $treeWatch.Elapsed.TotalSeconds -lt 10) {
        if ($treeRoot.HasExited) {
            throw "tree root exited before publishing grandchild PID (exit $($treeRoot.ExitCode))"
        }
        Start-Sleep -Milliseconds 50
    }
    Assert-True (Test-Path -LiteralPath $grandchildPidPath) "process-tree fixture created a descendant"
    $grandchildPid = [int](Get-Content -LiteralPath $grandchildPidPath -Raw).Trim()
    Assert-True (Test-PidAlive $treeRoot.Id) "process-tree root is alive before ForceClose"
    Assert-True (Test-PidAlive $grandchildPid) "process-tree child is alive before ForceClose"

    Stop-ProcessTree -Process $treeRoot -WaitSeconds 10
    Start-Sleep -Milliseconds 200
    Assert-True (-not (Test-PidAlive $treeRoot.Id)) "ForceClose removes the PowerShell parent"
    Assert-True (-not (Test-PidAlive $grandchildPid)) "ForceClose removes the full descendant process tree"

    Write-Host "ALL PASS"
} finally {
    try {
        if ($script:SetupLockStream) { $script:SetupLockStream.Dispose() }
    } catch {}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
