# Parser, release-integrity and safe bootstrap smoke tests for PowerShell 5.1+.
param()

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$PowerShellFiles = @(
    (Join-Path $Root "hermes-mobile-setup.ps1"),
    (Join-Path $Root "hermes-pair.ps1")
)

foreach ($path in $PowerShellFiles) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors
    )
    if (@($errors).Count -ne 0) {
        $details = @($errors | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "PowerShell parser errors in $path`n$details"
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $Root "bridge-release.json") -Raw |
    ConvertFrom-Json
$bridgePath = Join-Path $Root "hermes_bridge.py"
$bridge = Get-Item -LiteralPath $bridgePath
$digest = (Get-FileHash -LiteralPath $bridgePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($bridge.Length -ne [int64]$manifest.size -or $digest -ne $manifest.sha256) {
    throw "Bridge release manifest does not match hermes_bridge.py"
}

$publishedSource = [IO.File]::ReadAllText(
    (Join-Path $Root "hermes-mobile-setup.ps1"),
    [Text.Encoding]::UTF8
)
if (-not $publishedSource.StartsWith("# Hermes Console - native Windows setup")) {
    throw "Unexpected Windows bootstrap identity"
}

function Invoke-SafeBootstrapSmoke([ValidateSet("file", "memory")][string]$Mode) {
    $tempHome = Join-Path ([IO.Path]::GetTempPath()) ("hermes-bootstrap-" + [Guid]::NewGuid().ToString("N"))
    $publishedFile = Join-Path $tempHome "hermes-mobile-setup.ps1"
    New-Item -ItemType Directory -Force -Path $tempHome | Out-Null
    [IO.File]::WriteAllText($publishedFile, $publishedSource, (New-Object Text.UTF8Encoding($false)))
    $oldHome = $env:HERMES_HOME
    $oldSystemRoot = $env:SystemRoot
    $fixtureHome = Join-Path $tempHome "home"
    $env:HERMES_HOME = $fixtureHome
    if (-not $env:SystemRoot) { $env:SystemRoot = $tempHome }
    # Both the platform refusal (legacy/32-bit/unknown hosts) and the clean-host
    # audit guard are valid non-destructive outcomes here; anything else must
    # fail, and no run may create the target home.
    $boundedOutcomes = 'Audit found [0-9]+ item\(s\) to repair|' +
        'supports Windows 10, Windows 11 and Windows Server|' +
        'could not verify the Windows version|' +
        'does not belong to the selected Hermes home|' +
        'owned by another identity'
    $observed = $null
    try {
        if ($Mode -eq "file") {
            & $publishedFile -AuditOnly -NoFirewallPrompt
        } else {
            $bootstrap = [ScriptBlock]::Create($publishedSource)
            & $bootstrap -AuditOnly -NoFirewallPrompt
        }
    } catch {
        if ($_.Exception.Message -match $boundedOutcomes) {
            $observed = $_.Exception.Message
        } else {
            throw
        }
    } finally {
        $mutated = Test-Path -LiteralPath $fixtureHome
        $env:HERMES_HOME = $oldHome
        $env:SystemRoot = $oldSystemRoot
        Remove-Item -LiteralPath $tempHome -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $observed) {
        throw "$Mode bootstrap did not execute through the non-destructive audit guard"
    }
    if ($mutated) {
        throw "$Mode bootstrap mutated the target home before failing: $observed"
    }
}

function Invoke-ReviewModeSmoke([ValidateSet("file", "memory")][string]$Mode) {
    # Proves the published single file executes as delivered (file and irm|iex
    # equivalent) without touching the target home or any real service.
    $tempHome = Join-Path ([IO.Path]::GetTempPath()) ("hermes-review-" + [Guid]::NewGuid().ToString("N"))
    $publishedFile = Join-Path $tempHome "hermes-mobile-setup.ps1"
    New-Item -ItemType Directory -Force -Path $tempHome | Out-Null
    [IO.File]::WriteAllText($publishedFile, $publishedSource, (New-Object Text.UTF8Encoding($false)))
    $oldHome = $env:HERMES_HOME
    $oldReview = $env:HERMES_SETUP_REVIEW_MODE
    $fixtureHome = Join-Path $tempHome "home"
    try {
        $env:HERMES_HOME = $fixtureHome
        $env:HERMES_SETUP_REVIEW_MODE = "synthetic-canary"
        $output = @(
            if ($Mode -eq "file") {
                & $publishedFile
            } else {
                $bootstrap = [ScriptBlock]::Create($publishedSource)
                & $bootstrap
            }
        )
        if (-not (@($output | ForEach-Object { [string]$_ }) -match 'HERMES_SETUP_REVIEW_MODE_OK')) {
            throw "$Mode review smoke did not reach the fixture boundary"
        }
    } finally {
        $mutated = Test-Path -LiteralPath $fixtureHome
        $env:HERMES_HOME = $oldHome
        $env:HERMES_SETUP_REVIEW_MODE = $oldReview
        Remove-Item -LiteralPath $tempHome -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($mutated) { throw "$Mode review smoke mutated the target home" }
}

Invoke-ReviewModeSmoke file
Invoke-ReviewModeSmoke memory
Invoke-SafeBootstrapSmoke file
Invoke-SafeBootstrapSmoke memory
Write-Host "PowerShell parser, manifest and bootstrap file/memory tests: OK"
