# Hermes Console - verify all native Windows services, then reprint pairing QR.
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$RepoRaw = if ($env:HERMES_REPO_RAW) {
    $env:HERMES_REPO_RAW.TrimEnd('/')
} else {
    "https://raw.githubusercontent.com/xP3ta/hermes-setup/main"
}
$HermesHome = if ($env:HERMES_HOME) {
    $env:HERMES_HOME
} else {
    Join-Path $env:LOCALAPPDATA "hermes"
}
$EnvFile = Join-Path $HermesHome ".env"
$PairingFile = Join-Path $HermesHome "console-services\pairing.json"
$Python = Join-Path $HermesHome "hermes-agent\venv\Scripts\python.exe"

function Get-ApiKey {
    if (-not (Test-Path -LiteralPath $EnvFile)) { return $null }
    $values = @()
    foreach ($line in [IO.File]::ReadAllLines($EnvFile)) {
        if ($line -match '^API_SERVER_KEY=(.*)$') {
            $values += $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    $strong = @($values | Where-Object {
        $_.Length -ge 16 -and $_.ToLowerInvariant() -notin @(
            "changeme", "change-me", "your-api-key", "replace-me", "secret"
        )
    } | Select-Object -Unique)
    if ($strong.Count -gt 1) {
        throw "Conflicting API_SERVER_KEY entries exist in $EnvFile. Run setup to repair them."
    }
    if ($strong.Count -eq 1) { return $strong[0] }
    return $null
}

function Test-Cgnat([string]$Address) {
    $parsed = $null
    if (-not ([Net.IPAddress]::TryParse($Address, [ref]$parsed))) { return $false }
    $bytes = $parsed.GetAddressBytes()
    return $bytes.Length -eq 4 -and $bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127
}

function Test-PrivateIpv4([string]$Address) {
    $parsed = $null
    if (-not ([Net.IPAddress]::TryParse($Address, [ref]$parsed))) { return $false }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $false }
    return ($bytes[0] -eq 10) -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
}

function Test-PrivateHost([string]$HostName) {
    if (-not $HostName -or $HostName -eq "localhost") { return $false }
    if ($HostName.EndsWith(".local") -or $HostName.EndsWith(".ts.net") -or $HostName -notmatch '\.') {
        return $true
    }
    if ((Test-Cgnat $HostName) -or (Test-PrivateIpv4 $HostName)) { return $true }
    try {
        $addresses = @([Net.Dns]::GetHostAddresses($HostName))
        return $addresses.Count -gt 0 -and @($addresses | Where-Object {
            -not ((Test-Cgnat $_.IPAddressToString) -or (Test-PrivateIpv4 $_.IPAddressToString))
        }).Count -eq 0
    } catch {}
    return $false
}

function Assert-AllowedServiceUrl([string]$Url) {
    $uri = $null
    if (-not ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) -or
        $uri.Scheme -notin @("http", "https") -or -not $uri.Host -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.Port -lt 1) {
        throw "Invalid phone-facing service URL: $Url"
    }
    if ($uri.IsLoopback) {
        throw "Loopback is not reachable from the phone: $Url"
    }
    if ($uri.Scheme -eq "https") { return }
    if (-not (Test-PrivateHost $uri.Host)) {
        throw "Public HTTP is blocked. Use LAN/Tailscale or HTTPS: $Url"
    }
}

function Test-HermesService(
    [ValidateSet("gateway", "bridge", "dashboard")][string]$Kind,
    [string]$BaseUrl,
    [string]$Token
) {
    $base = $BaseUrl.TrimEnd('/')
    try {
        if ($Kind -eq "gateway") {
            $health = Invoke-RestMethod -Method Get -Uri "$base/health" -TimeoutSec 6
            if ($health.status -ne "ok" -or $health.platform -ne "hermes-agent") {
                return $false
            }
            $sessions = Invoke-RestMethod -Method Get -Uri "$base/api/sessions" -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 6
            return $sessions.object -eq "list" -and $null -ne $sessions.data
        }
        if ($Kind -eq "bridge") {
            $health = Invoke-RestMethod -Method Get -Uri "$base/bridge/health" -TimeoutSec 6
            if ($health.status -ne "ok" -or -not $health.version) { return $false }
            $caps = Invoke-RestMethod -Method Get -Uri "$base/bridge/capabilities" -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 6
            return ($caps.object -eq "hermes.bridge.capabilities") -and
                ($caps.operations.self_update -eq $true) -and
                (@($caps.scopes) -contains "read") -and
                (@($caps.scopes) -contains "config")
        }
        $status = Invoke-RestMethod -Method Get -Uri "$base/api/status" -TimeoutSec 6
        return [bool]$status.version -and $status.gateway_running -eq $true
    } catch {
        return $false
    }
}

function Render-Qr([string]$Link) {
    if (-not (Test-Path -LiteralPath $Python)) { return $false }
    $code = "import qrcode,sys;q=qrcode.QRCode(border=1);q.add_data(sys.argv[1]);q.make();q.print_ascii(invert=True)"
    & $Python -c "import qrcode" 2>$null
    if ($LASTEXITCODE -ne 0) { & $Python -m pip install -q qrcode *> $null }
    & $Python -c $code $Link
    return $LASTEXITCODE -eq 0
}

$ApiKey = Get-ApiKey
if (-not $ApiKey) {
    throw "No API token found in $EnvFile. Run first: irm $RepoRaw/hermes-mobile-setup.ps1 | iex"
}
if (-not (Test-Path -LiteralPath $PairingFile)) {
    throw "This installation predates verified pairing. Run setup once: irm $RepoRaw/hermes-mobile-setup.ps1 | iex"
}
$pairing = Get-Content -LiteralPath $PairingFile -Raw | ConvertFrom-Json
if ($pairing.schema -ne 1) {
    throw "This pairing record is not from the verified installer. Run setup once: irm $RepoRaw/hermes-mobile-setup.ps1 | iex"
}
$hostName = if ($env:HERMES_PAIR_HOST) { $env:HERMES_PAIR_HOST.Trim() } else { [string]$pairing.host }
$scheme = if ($env:HERMES_PAIR_SCHEME) { $env:HERMES_PAIR_SCHEME.Trim().ToLowerInvariant() } else { [string]$pairing.scheme }
if ($hostName -notmatch '^[A-Za-z0-9._:-]+$') {
    throw "The stored pairing host is invalid. Run setup again."
}
if ($scheme -notin @("http", "https")) {
    throw "The stored pairing scheme is invalid. Run setup again."
}
$port = 0
$rawPort = if ($env:HERMES_PAIR_PORT) { $env:HERMES_PAIR_PORT } else { [string]$pairing.port }
if (-not ([int]::TryParse($rawPort, [ref]$port)) -or $port -lt 1 -or $port -gt 65535) {
    throw "The stored pairing port is invalid. Run setup again."
}
$baseHost = if ($hostName.Contains(":")) { "[$hostName]" } else { $hostName }
$gateway = if ($env:HERMES_PAIR_HOST -or $env:HERMES_PAIR_SCHEME -or $env:HERMES_PAIR_PORT) {
    "$($scheme)://$($baseHost):$port"
} else { [string]$pairing.gateway }
$dashboard = if ($env:HERMES_DASHBOARD_URL) {
    $env:HERMES_DASHBOARD_URL.TrimEnd('/')
} elseif ($env:HERMES_PAIR_HOST -or $env:HERMES_PAIR_SCHEME -or $env:HERMES_PAIR_PORT) {
    if ($scheme -eq "https") { $gateway } else { "http://$($baseHost):9119" }
} else { [string]$pairing.dashboard }
$bridge = if ($env:HERMES_BRIDGE_URL) {
    $env:HERMES_BRIDGE_URL.TrimEnd('/')
} elseif ($env:HERMES_PAIR_HOST -or $env:HERMES_PAIR_SCHEME -or $env:HERMES_PAIR_PORT) {
    if ($scheme -eq "https") { $gateway } else { "http://$($baseHost):9131" }
} else { [string]$pairing.bridge }

$expectedGateway = "$($scheme)://$($baseHost):$port"
if ($gateway -ne $expectedGateway) {
    throw "The pairing record is inconsistent. Run setup again before showing credentials."
}
Assert-AllowedServiceUrl $gateway
Assert-AllowedServiceUrl $dashboard
Assert-AllowedServiceUrl $bridge

foreach ($service in @(
    @{ Kind = "gateway"; Url = $gateway },
    @{ Kind = "bridge"; Url = $bridge },
    @{ Kind = "dashboard"; Url = $dashboard }
)) {
    if (-not (Test-HermesService $service.Kind $service.Url $ApiKey)) {
        throw "$($service.Kind) is not healthy/authenticated through $($service.Url). Run repair first: irm $RepoRaw/hermes-mobile-setup.ps1 | iex"
    }
}

$query = @(
    "host=$([Uri]::EscapeDataString($hostName))"
    "port=$port"
    "token=$([Uri]::EscapeDataString($ApiKey))"
    "dashboard=$([Uri]::EscapeDataString($dashboard))"
    "bridge=$([Uri]::EscapeDataString($bridge))"
    "bridge_token=$([Uri]::EscapeDataString($ApiKey))"
)
if ($scheme -eq "https") { $query += "https=1" }
$link = "hermes://pair?" + ($query -join "&")

Write-Host ""
Write-Host "== SCAN THIS QR WITH HERMES CONSOLE (or copy the link) ==" -ForegroundColor Yellow
Write-Host ""
if (-not (Render-Qr $link)) {
    Write-Warning "A QR renderer could not be prepared. Paste the verified link below."
}
Write-Host ""
Write-Host "Link: $link"
Write-Host "Gateway, Dashboard and Mobile Bridge passed their functional checks."
