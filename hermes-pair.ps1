# Hermes Console - verify all native Windows services, then reprint pairing QR.
param([switch]$Repair)

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

function Test-AllowedIpAddress([string]$Address) {
    $parsed = $null
    if (-not ([Net.IPAddress]::TryParse($Address, [ref]$parsed))) { return $false }
    if ($parsed.IsIPv4MappedToIPv6) { $parsed = $parsed.MapToIPv4() }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -eq 4) {
        return (Test-PrivateIpv4 $parsed.IPAddressToString) -or
            (Test-Cgnat $parsed.IPAddressToString) -or
            $bytes[0] -eq 127 -or
            ($bytes[0] -eq 169 -and $bytes[1] -eq 254)
    }
    return $parsed.Equals([Net.IPAddress]::IPv6Loopback) -or
        $parsed.IsIPv6LinkLocal -or (($bytes[0] -band 0xFE) -eq 0xFC)
}

function Test-PrivateHost([string]$HostName) {
    if (-not $HostName) { return $false }
    $parsed = $null
    if ([Net.IPAddress]::TryParse($HostName, [ref]$parsed)) {
        return Test-AllowedIpAddress $parsed.IPAddressToString
    }
    if ($HostName -eq "localhost" -or $HostName.EndsWith(".local") -or
        $HostName.EndsWith(".ts.net") -or $HostName -notmatch '\.') {
        return $true
    }
    try {
        $addresses = @([Net.Dns]::GetHostAddresses($HostName))
        return $addresses.Count -gt 0 -and @($addresses | Where-Object {
            -not (Test-AllowedIpAddress $_.IPAddressToString)
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
    if ($uri.Scheme -eq "https") { return }
    if (-not (Test-PrivateHost $uri.Host)) {
        throw "Public HTTP is blocked. Use LAN/Tailscale or HTTPS: $Url"
    }
}

function Assert-HermesResponseStatus([int]$StatusCode, [bool]$Authenticated) {
    if ($StatusCode -ge 300 -and $StatusCode -lt 400) {
        $kind = if ($Authenticated) { "Authenticated" } else { "Service" }
        throw "$kind redirects are refused."
    }
}

function Invoke-HermesJsonRequest {
    [CmdletBinding()]
    param(
        [ValidateSet("Get", "Post")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Token = "",
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 6,
        [string]$Body = ""
    )
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Url)
    $request.Method = $Method.ToUpperInvariant()
    $request.AllowAutoRedirect = $false
    $request.Timeout = $TimeoutSeconds * 1000
    $request.ReadWriteTimeout = $TimeoutSeconds * 1000
    $request.Accept = "application/json"
    if ($Token) { $request.Headers["Authorization"] = "Bearer $Token" }
    if ($Method -eq "Post") {
        $request.ContentType = "application/json"
        $payload = [Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentLength = $payload.Length
        $requestStream = $request.GetRequestStream()
        try { $requestStream.Write($payload, 0, $payload.Length) } finally { $requestStream.Dispose() }
    }
    $response = $null
    try {
        $response = [Net.HttpWebResponse]$request.GetResponse()
        $status = [int]$response.StatusCode
        Assert-HermesResponseStatus $status ([bool]$Token)
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return $json | ConvertFrom-Json
    } catch [Net.WebException] {
        if ($_.Exception.Response) {
            $errorResponse = [Net.HttpWebResponse]$_.Exception.Response
            try {
                $status = [int]$errorResponse.StatusCode
                Assert-HermesResponseStatus $status ([bool]$Token)
            } finally { $errorResponse.Dispose() }
        }
        throw
    } finally {
        if ($response) { $response.Dispose() }
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
            $health = Invoke-HermesJsonRequest -Method Get -Url "$base/health" -TimeoutSeconds 6
            if ($health.status -ne "ok" -or $health.platform -ne "hermes-agent") {
                return $false
            }
            $sessions = Invoke-HermesJsonRequest -Method Get -Url "$base/api/sessions" -Token $Token -TimeoutSeconds 6
            return $sessions.object -eq "list" -and $null -ne $sessions.data
        }
        if ($Kind -eq "bridge") {
            $health = Invoke-HermesJsonRequest -Method Get -Url "$base/bridge/health" -TimeoutSeconds 6
            if ($health.status -ne "ok" -or -not $health.version) { return $false }
            $caps = Invoke-HermesJsonRequest -Method Get -Url "$base/bridge/capabilities" -Token $Token -TimeoutSeconds 6
            return ($caps.object -eq "hermes.bridge.capabilities") -and
                ($caps.operations.self_update -eq $true) -and
                (@($caps.scopes) -contains "read") -and
                (@($caps.scopes) -contains "config")
        }
        $status = Invoke-HermesJsonRequest -Method Get -Url "$base/api/status" -TimeoutSeconds 6
        return [bool]$status.version -and $status.gateway_running -eq $true
    } catch {
        return $false
    }
}

function Render-Qr([string]$Link) {
    if (-not (Test-Path -LiteralPath $Python)) { return $false }
    $code = "import qrcode,sys;q=qrcode.QRCode(border=1);q.add_data(sys.argv[1]);q.make();q.print_ascii(invert=True)"
    $uv = Join-Path $HermesHome "bin\uv.exe"
    $qrProcess = $Python
    $qrArguments = @("-c", $code, $Link)
    if (Test-Path -LiteralPath $uv) {
        # Never probe or mutate the Hermes venv: reuse the pinned, isolated
        # uv QR runtime that the setup uses. Native stderr must not escape as
        # a terminating NativeCommandError under `$ErrorActionPreference =
        # "Stop"` (Windows PowerShell 5.1 turns it into a thrown error even
        # with 2>$null, aborting the script before the link prints).
        $qrProcess = $uv
        $qrArguments = @("run", "--isolated", "--no-project", "--python", $Python,
            "--with", "qrcode==8.2", "python", "-c", $code, $Link)
    }
    $previousPreference = $ErrorActionPreference
    $previousIoEncoding = $env:PYTHONIOENCODING
    try {
        $ErrorActionPreference = "Continue"
        # print_ascii emits U+2588 block characters; the legacy Windows console
        # codepage (e.g. cp1252) cannot encode them and python would die with
        # UnicodeEncodeError instead of printing the QR.
        $env:PYTHONIOENCODING = "utf-8"
        & $qrProcess @qrArguments 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $previousPreference
        $env:PYTHONIOENCODING = $previousIoEncoding
    }
}

function Invoke-VerifiedSetupRepair([string]$Reason) {
    $setupUrl = "$RepoRaw/hermes-mobile-setup.ps1"
    Write-Host ""
    Write-Host "Explicit repair was requested for Hermes Console." -ForegroundColor Yellow
    Write-Host "Reason: $Reason"
    Write-Host "Running the requested Hermes Console setup now..." -ForegroundColor Cyan

    try {
        $setupSource = [string](Invoke-RestMethod -Method Get -Uri $setupUrl -TimeoutSec 30)
    } catch {
        throw "Automatic setup/repair could not be downloaded. Run this command and retry: irm $setupUrl | iex"
    }
    if (-not $setupSource.StartsWith("# Hermes Console - native Windows setup") -or
        $setupSource -notmatch '(?m)^function Get-PairingConfiguration' -or
        $setupSource -notmatch '(?m)^\$PairingFile = Join-Path \$ServicesDir "pairing\.json"') {
        throw "The downloaded setup file did not match the expected Hermes Console installer. Nothing was executed."
    }

    try {
        & ([ScriptBlock]::Create($setupSource))
    } catch {
        throw "Automatic setup/repair failed: $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $PairingFile)) {
        throw "Setup finished without a verified pairing record. Review the setup error above before retrying."
    }
    Write-Host "Setup/repair completed. Use the QR printed above to connect Hermes Console." -ForegroundColor Green
}

function Require-ExplicitRepair([string]$Reason) {
    if ($Repair) {
        Invoke-VerifiedSetupRepair $Reason
        return
    }
    throw "Pairing is read-only and requires repair: $Reason Re-run this script with -Repair to opt in explicitly."
}

if ($env:HERMES_SETUP_REVIEW_MODE -eq "synthetic-canary") {
    Write-Output "HERMES_PAIR_REVIEW_MODE_OK"
    return
}

$ApiKey = Get-ApiKey
if (-not $ApiKey) {
    Require-ExplicitRepair "No valid API token was found."
    return
}
if (-not (Test-Path -LiteralPath $PairingFile)) {
    Require-ExplicitRepair "This installation predates verified pairing."
    return
}
try {
    $pairing = Get-Content -LiteralPath $PairingFile -Raw | ConvertFrom-Json
} catch {
    Require-ExplicitRepair "The saved pairing record is unreadable."
    return
}
if ($pairing.schema -ne 1) {
    Require-ExplicitRepair "The saved pairing record is outdated."
    return
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
# Los defaults respetan los overrides de puerto del setup, o el enlace mostraria
# puertos que no son los que escucha esta maquina.
$dashboardPort = if ($env:HERMES_DASHBOARD_PORT) { $env:HERMES_DASHBOARD_PORT } else { "9119" }
$bridgePort = if ($env:HERMES_BRIDGE_PORT) { $env:HERMES_BRIDGE_PORT } else { "9131" }
$dashboard = if ($env:HERMES_DASHBOARD_URL) {
    $env:HERMES_DASHBOARD_URL.TrimEnd('/')
} elseif ($env:HERMES_PAIR_HOST -or $env:HERMES_PAIR_SCHEME -or $env:HERMES_PAIR_PORT) {
    if ($scheme -eq "https") { $gateway } else { "http://$($baseHost):$dashboardPort" }
} else { [string]$pairing.dashboard }
$bridge = if ($env:HERMES_BRIDGE_URL) {
    $env:HERMES_BRIDGE_URL.TrimEnd('/')
} elseif ($env:HERMES_PAIR_HOST -or $env:HERMES_PAIR_SCHEME -or $env:HERMES_PAIR_PORT) {
    if ($scheme -eq "https") { $gateway } else { "http://$($baseHost):$bridgePort" }
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
