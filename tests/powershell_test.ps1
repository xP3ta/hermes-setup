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
    $env:HERMES_HOME = Join-Path $tempHome "home"
    if (-not $env:SystemRoot) { $env:SystemRoot = $tempHome }
    $expectedFailure = $false
    try {
        if ($Mode -eq "file") {
            & $publishedFile -AuditOnly -NoFirewallPrompt
        } else {
            $bootstrap = [ScriptBlock]::Create($publishedSource)
            & $bootstrap -AuditOnly -NoFirewallPrompt
        }
    } catch {
        if ($_.Exception.Message -match "Audit found [0-9]+ item\(s\) to repair") {
            $expectedFailure = $true
        } else {
            throw
        }
    } finally {
        $env:HERMES_HOME = $oldHome
        $env:SystemRoot = $oldSystemRoot
        Remove-Item -LiteralPath $tempHome -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $expectedFailure) {
        throw "$Mode bootstrap did not execute through the non-destructive audit guard"
    }
}

Invoke-SafeBootstrapSmoke file
Invoke-SafeBootstrapSmoke memory
Write-Host "PowerShell parser, manifest and bootstrap file/memory tests: OK"
