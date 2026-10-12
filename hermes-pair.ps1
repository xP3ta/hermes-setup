# Hermes Console - check the native Windows services, then show the code again.
# It reads; without -Repair it never installs, repairs or changes anything.
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
$DashLoginFile = Join-Path $HermesHome "console-services\dashboard-login.json"
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

function Test-DashboardSignIn([string]$BaseUrl, [string]$LoginPath) {
    # True only when the Dashboard accepts the sign-in on record, by signing in.
    try {
        $login = Get-Content -LiteralPath $LoginPath -Raw | ConvertFrom-Json
        if (-not $login.username -or -not $login.password) { return $false }
        $body = [ordered]@{
            provider = "basic"
            username = [string]$login.username
            password = [string]$login.password
        } | ConvertTo-Json -Compress
        [void](Invoke-HermesJsonRequest -Method Post `
            -Url ($BaseUrl.TrimEnd('/') + "/auth/password-login") -Body $body -TimeoutSeconds 6)
        return $true
    } catch {
        return $false
    }
}

function Test-HermesService(
    [ValidateSet("gateway", "dashboard")][string]$Kind,
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
        $status = Invoke-HermesJsonRequest -Method Get -Url "$base/api/status" -TimeoutSeconds 6
        return [bool]$status.version -and $status.gateway_running -eq $true
    } catch {
        return $false
    }
}

function Render-Qr([string]$Link) {
    # Draws the code in the window and answers one thing: was it drawn.
    # The renderer writes the picture to a throwaway file that is read back as
    # UTF-8 and printed here. Two reasons, both seen on a real Windows console:
    # what a native program prints inside a function becomes part of the
    # function's answer (the code was computed and never shown), and its block
    # characters do not survive the console code page (850, 1252).
    if (-not (Test-Path -LiteralPath $Python)) { return $false }
    $code = "import io,qrcode,sys;q=qrcode.QRCode(border=1);q.add_data(sys.argv[1]);q.make();f=io.open(sys.argv[2],'w',encoding='utf-8');q.print_ascii(out=f,invert=True);f.close()"
    $drawing = Join-Path ([IO.Path]::GetTempPath()) ("hermes-pair-code-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $uv = Join-Path $HermesHome "bin\uv.exe"
    $qrProcess = $Python
    $qrArguments = @("-c", $code, $Link, $drawing)
    if (Test-Path -LiteralPath $uv) {
        # Never probe or mutate the Hermes venv: reuse the pinned, isolated
        # uv QR runtime that the setup uses. Native stderr must not escape as
        # a terminating NativeCommandError under `$ErrorActionPreference =
        # "Stop"` (Windows PowerShell 5.1 turns it into a thrown error even
        # with 2>$null, aborting the script before the link prints).
        $qrProcess = $uv
        $qrArguments = @("run", "--isolated", "--no-project", "--python", $Python,
            "--with", "qrcode==8.2", "python", "-c", $code, $Link, $drawing)
    }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $qrProcess @qrArguments 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $drawing)) { return $false }
        $picture = [IO.File]::ReadAllText($drawing, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($picture)) { return $false }
        Write-Host $picture.TrimEnd()
        return $true
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $previousPreference
        Remove-Item -LiteralPath $drawing -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-VerifiedSetupRepair([string]$Reason) {
    $setupUrl = "$RepoRaw/hermes-mobile-setup.ps1"
    Write-Host ""
    Write-Host "Explicit repair was requested for Console." -ForegroundColor Yellow
    Write-Host "Reason: $Reason"
    Write-Host "Running the requested Console setup now..." -ForegroundColor Cyan

    try {
        $setupSource = [string](Invoke-RestMethod -Method Get -Uri $setupUrl -TimeoutSec 30)
    } catch {
        throw "Automatic setup/repair could not be downloaded. Run this command and retry: irm $setupUrl | iex"
    }
    if (-not $setupSource.StartsWith("# Hermes Console - native Windows setup") -or
        $setupSource -notmatch '(?m)^function Get-PairingConfiguration' -or
        $setupSource -notmatch '(?m)^\$PairingFile = Join-Path \$ServicesDir "pairing\.json"') {
        throw "The downloaded setup file did not match the expected Console installer. Nothing was executed."
    }

    try {
        & ([ScriptBlock]::Create($setupSource))
    } catch {
        throw "Automatic setup/repair failed: $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $PairingFile)) {
        throw "Setup finished without a verified pairing record. Review the setup error above before retrying."
    }
    Write-Host "Setup/repair completed. Use the QR printed above to connect Console." -ForegroundColor Green
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

# In the window a person is looking at: the seal first, and a refusal as one
# readable block instead of PowerShell's error record. Scripts and CI (output
# redirected) get the plain lines and the exception, as before.
$PairLive = $false
try { $PairLive = -not [Console]::IsOutputRedirected } catch { $PairLive = $false }
if ($PairLive) {
    $rule = "=" * 64
    Write-Host ""
    Write-Host "  $rule" -ForegroundColor DarkGray
    Write-Host "    xPetaLab  |  CONSOLE" -ForegroundColor DarkYellow
    Write-Host "  $rule" -ForegroundColor DarkGray
}

try {
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
# Schema 1 was written by a setup that also installed the Mobile Bridge. Its
# Gateway and Dashboard addresses are the same ones, so it is still good.
if ($pairing.schema -notin @(1, 2)) {
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
$dashboardPort = if ($env:HERMES_DASHBOARD_PORT) {
    $env:HERMES_DASHBOARD_PORT
} elseif ($pairing.PSObject.Properties["dashboard_port"] -and $pairing.dashboard_port) {
    [string]$pairing.dashboard_port
} else { "9119" }
$dashboard = if ($env:HERMES_DASHBOARD_URL) {
    $env:HERMES_DASHBOARD_URL.TrimEnd('/')
} elseif ($env:HERMES_PAIR_HOST -or $env:HERMES_PAIR_SCHEME -or $env:HERMES_PAIR_PORT) {
    if ($scheme -eq "https") { $gateway } else { "http://$($baseHost):$dashboardPort" }
} else { [string]$pairing.dashboard }

$expectedGateway = "$($scheme)://$($baseHost):$port"
if ($gateway -ne $expectedGateway) {
    throw "The pairing record is inconsistent. Run setup again before showing credentials."
}
Assert-AllowedServiceUrl $gateway
Assert-AllowedServiceUrl $dashboard

foreach ($service in @(
    @{ Kind = "gateway"; Url = $gateway },
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
)
# The Dashboard sign-in that setup left on record goes into the code only while
# the Dashboard still accepts it, checked by signing in for real.
$carriesSignIn = (Test-Path -LiteralPath $DashLoginFile) -and (Test-DashboardSignIn $dashboard $DashLoginFile)
if ($carriesSignIn) {
    $dashboardLogin = Get-Content -LiteralPath $DashLoginFile -Raw | ConvertFrom-Json
    $query += "dash_user=$([Uri]::EscapeDataString([string]$dashboardLogin.username))"
    $query += "dash_pass=$([Uri]::EscapeDataString([string]$dashboardLogin.password))"
    $dashboardLogin = $null
}
if ($scheme -eq "https") { $query += "https=1" }
$link = "hermes://pair?" + ($query -join "&")

Write-Host ""
Write-Host "== SCAN THIS CODE WITH CONSOLE ==" -ForegroundColor Yellow
Write-Host ""
if (-not (Render-Qr $link)) {
    Write-Warning "The code could not be drawn here. Copy the link below and paste it in the app instead."
}
Write-Host ""
Write-Host "No camera? Copy this link and paste it in the app (Scan, then Paste link):"
Write-Host "Link: $link"
Write-Host ""
Write-Host "Gateway (chat) took your key. Dashboard answered."
if ($carriesSignIn) {
    Write-Host "The code carries your Dashboard sign-in: the app connects in one step."
} else {
    Write-Host "The code does not carry a Dashboard password: the app will ask you for it once."
    Write-Host "Forgot it? This makes a new sign-in and shows a new code:"
    Write-Host "  & ([scriptblock]::Create((irm $RepoRaw/hermes-mobile-setup.ps1))) -NewAccess"
}
Write-Host "Keep the code and the link private: whoever has them can use your Hermes."
Write-Host "Needs Console 1.2.15 or newer on the phone."
Write-Host "Help and guide: https://hermes.xpetalab.dev"
} catch {
    if (-not $PairLive) { throw }
    Write-Host ""
    Write-Host "  [x] The code cannot be shown yet. Nothing was changed." -ForegroundColor Red
    Write-Host "      $($_.Exception.Message)" -ForegroundColor Gray
    Write-Host "      Need help? https://hermes.xpetalab.dev" -ForegroundColor DarkGray
    Write-Host ""
}
