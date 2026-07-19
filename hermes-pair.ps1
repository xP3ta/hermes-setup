# Hermes Console - native Windows pairing QR (PowerShell 5.1+).
param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
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
$Python = Join-Path $HermesHome "hermes-agent\venv\Scripts\python.exe"

function Test-Port([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync("127.0.0.1", $Port)
        return $task.Wait(700) -and $client.Connected
    } catch { return $false }
    finally { $client.Dispose() }
}

function Get-ApiKey {
    if (-not (Test-Path -LiteralPath $EnvFile)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($EnvFile)) {
        if ($line -match '^API_SERVER_KEY=(.*)$') {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

function Test-Cgnat([string]$Address) {
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    $bytes = $parsed.GetAddressBytes()
    return $bytes.Length -eq 4 -and $bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127
}

function Test-PrivateIpv4([string]$Address) {
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $false }
    return ($bytes[0] -eq 10) -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
}

function Get-ReachableHost {
    $tailscale = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($tailscale) {
        try {
            $mesh = (& $tailscale.Source ip -4 2>$null | Select-Object -First 1).Trim()
            if ($mesh) { return @{ Address = $mesh; Public = $false } }
        } catch {}
    }
    $addresses = @()
    try {
        $records = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -ne "127.0.0.1" -and
                $_.IPAddress -notlike "169.254.*" -and
                $_.AddressState -ne "Duplicate"
            })
        $preferred = @($records | Where-Object {
            $_.InterfaceAlias -notmatch '(?i)(vEthernet|WSL|Default Switch|Docker|Hyper-V|VirtualBox|VMware)'
        })
        if ($preferred.Count -eq 0) { $preferred = $records }
        $addresses = @($preferred | ForEach-Object { $_.IPAddress } | Select-Object -Unique)
    } catch {
        foreach ($line in (ipconfig.exe 2>$null)) {
            if ($line -match 'IPv4[^:]*:\s*([0-9.]+)') { $addresses += $Matches[1] }
        }
    }
    $meshAddress = @($addresses | Where-Object { Test-Cgnat $_ } | Select-Object -First 1)
    if ($meshAddress.Count -gt 0) { return @{ Address = $meshAddress[0]; Public = $false } }
    $privateAddress = @($addresses | Where-Object { Test-PrivateIpv4 $_ } | Select-Object -First 1)
    if ($privateAddress.Count -gt 0) { return @{ Address = $privateAddress[0]; Public = $false } }
    if ($addresses.Count -gt 0) { return @{ Address = $addresses[0]; Public = $true } }
    return @{ Address = "127.0.0.1"; Public = $false }
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
if (-not (Test-Port 8642)) { Write-Warning "Gateway 8642 is not listening; the app will not connect." }
if (-not (Test-Port 9131)) { Write-Warning "Mobile Bridge 9131 is not listening; some features will be limited." }
$hostInfo = Get-ReachableHost
$dashboardPart = if (Test-Port 9119) { "&dashboard=http://$($hostInfo.Address):9119" } else { "" }
$link = "hermes://pair?host=$($hostInfo.Address)&port=8642&token=$ApiKey$dashboardPart"
Write-Host ""
Write-Host "== SCAN THIS QR WITH HERMES CONSOLE (or copy the link) ==" -ForegroundColor Yellow
Write-Host ""
if (-not (Render-Qr $link)) { Write-Warning "A QR renderer could not be prepared. Paste the link below." }
Write-Host ""
Write-Host "Link: $link"
if ($hostInfo.Public) { Write-Warning "The link uses public IP $($hostInfo.Address). Prefer a mesh VPN or private firewall." }
if ($hostInfo.Address -eq "127.0.0.1") { Write-Warning "No reachable network address was found; this link only works on this PC." }
