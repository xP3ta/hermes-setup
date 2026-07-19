# Hermes Console - native Windows setup (PowerShell 5.1+).
# Installs/repairs Hermes, Gateway, Dashboard and Mobile Bridge for this user.

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
$InstallDir = Join-Path $HermesHome "hermes-agent"
$ServicesDir = Join-Path $HermesHome "console-services"
$LogsDir = Join-Path $HermesHome "logs"
$EnvFile = Join-Path $HermesHome ".env"
$BridgeTarget = Join-Path $HermesHome "hermes_bridge.py"
$BridgeNew = "$BridgeTarget.new"
$BridgeBackup = "$BridgeTarget.rollback"
$ManifestFile = Join-Path $HermesHome "bridge-release.json.new"
$PairingFile = Join-Path $ServicesDir "pairing.json"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Info([string]$Message) { Write-Host "[Hermes Console] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Warning $Message }

function Get-PowerShellExecutable {
    try {
        $hostPath = (Get-Process -Id $PID).Path
        if ($hostPath -and (Test-Path -LiteralPath $hostPath)) { return $hostPath }
    } catch {}
    $candidate = Join-Path $PSHOME "powershell.exe"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return "powershell.exe"
}

function Get-HermesExecutable {
    # Los runners persistentes usan este layout exacto. No aceptar un shim
    # global de otra instalación: funcionaría durante el setup pero dejaría
    # tareas apuntando a un venv distinto o inexistente.
    $candidate = Join-Path $InstallDir "venv\Scripts\hermes.exe"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Get-HermesPython {
    foreach ($candidate in @(
        (Join-Path $InstallDir "venv\Scripts\python.exe"),
        (Join-Path $InstallDir "venv\Scripts\python3.exe")
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Test-HermesService(
    [ValidateSet("gateway", "bridge", "dashboard")][string]$Kind,
    [string]$BaseUrl,
    [string]$Token,
    [string]$ExpectedVersion = "",
    [switch]$PhoneFacing
) {
    $base = $BaseUrl.TrimEnd('/')
    try {
        if ($PhoneFacing) { Assert-AllowedServiceUrl $base }
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
            if ($ExpectedVersion -and $health.version -ne $ExpectedVersion) { return $false }
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

function Wait-HermesService(
    [ValidateSet("gateway", "bridge", "dashboard")][string]$Kind,
    [string]$BaseUrl,
    [string]$Token,
    [int]$Seconds,
    [string]$ExpectedVersion = "",
    [switch]$PhoneFacing
) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        if (Test-HermesService $Kind $BaseUrl $Token $ExpectedVersion -PhoneFacing:$PhoneFacing) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

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
        throw "Conflicting API_SERVER_KEY entries exist in $EnvFile; keep exactly one and retry."
    }
    if ($strong.Count -eq 1) { return $strong[0] }
    return $null
}

function Ensure-ApiKey {
    $key = Get-ApiKey
    if (-not $key) {
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $key = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    $lines = if (Test-Path -LiteralPath $EnvFile) {
        @([IO.File]::ReadAllLines($EnvFile))
    } else { @() }
    $out = New-Object System.Collections.Generic.List[string]
    $inserted = $false
    foreach ($line in $lines) {
        if ($line -match '^API_SERVER_KEY=') {
            if (-not $inserted) {
                $out.Add("API_SERVER_KEY=$key")
                $inserted = $true
            }
        } else {
            $out.Add($line)
        }
    }
    if (-not $inserted) { $out.Add("API_SERVER_KEY=$key") }
    $payload = [string]::Join([Environment]::NewLine, $out) + [Environment]::NewLine
    $newFile = "$EnvFile.new"
    [IO.File]::WriteAllText($newFile, $payload, $Utf8NoBom)
    Move-Item -LiteralPath $newFile -Destination $EnvFile -Force
    return $key
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

function Get-ReachableHost {
    if ($env:HERMES_PAIR_HOST) {
        return @{ Address = $env:HERMES_PAIR_HOST.Trim(); Kind = "override"; InterfaceIndex = $null }
    }
    $tailscale = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($tailscale) {
        try {
            $mesh = (& $tailscale.Source ip -4 2>$null | Select-Object -First 1).Trim()
            if ($mesh) { return @{ Address = $mesh; Kind = "mesh"; InterfaceIndex = $null } }
        } catch {}
    }

    $records = @()
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
        $records = $preferred
    } catch {
        $addresses = @()
        $raw = ipconfig.exe 2>$null
        foreach ($line in $raw) {
            if ($line -match 'IPv4[^:]*:\s*([0-9.]+)') { $addresses += $Matches[1] }
        }
        $records = @($addresses | Select-Object -Unique | ForEach-Object {
            [PSCustomObject]@{ IPAddress = $_; InterfaceIndex = $null }
        })
    }
    $meshRecord = @($records | Where-Object { Test-Cgnat $_.IPAddress } | Select-Object -First 1)
    if ($meshRecord.Count -gt 0) {
        return @{ Address = $meshRecord[0].IPAddress; Kind = "mesh"; InterfaceIndex = $meshRecord[0].InterfaceIndex }
    }
    $privateRecord = @($records | Where-Object { Test-PrivateIpv4 $_.IPAddress } | Select-Object -First 1)
    if ($privateRecord.Count -gt 0) {
        return @{ Address = $privateRecord[0].IPAddress; Kind = "lan"; InterfaceIndex = $privateRecord[0].InterfaceIndex }
    }
    return @{ Address = ""; Kind = "none"; InterfaceIndex = $null }
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
    if (-not ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri))) {
        throw "Invalid service URL: $Url"
    }
    if ($uri.Scheme -notin @("http", "https") -or -not $uri.Host -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.Port -lt 1) {
        throw "Invalid service URL: $Url"
    }
    if ($uri.IsLoopback) {
        throw "Loopback is not reachable from the phone: $Url"
    }
    if ($uri.Scheme -eq "https") { return }
    if (-not (Test-PrivateHost $uri.Host)) {
        throw "Public HTTP is blocked. Use a LAN/Tailscale address or HTTPS: $Url"
    }
}

function Get-PairingConfiguration {
    $hostInfo = Get-ReachableHost
    if (-not $hostInfo.Address) {
        throw "No private LAN/Tailscale address was found. Connect Tailscale or configure HTTPS with HERMES_PAIR_HOST and HERMES_PAIR_SCHEME=https."
    }
    if ($hostInfo.Address -notmatch '^[A-Za-z0-9._:-]+$') {
        throw "HERMES_PAIR_HOST is not a valid host name or IP address."
    }
    $scheme = if ($env:HERMES_PAIR_SCHEME) {
        $env:HERMES_PAIR_SCHEME.Trim().ToLowerInvariant()
    } else { "http" }
    if ($scheme -notin @("http", "https")) {
        throw "HERMES_PAIR_SCHEME must be http or https."
    }
    if ($scheme -eq "http" -and -not (Test-PrivateHost $hostInfo.Address)) {
        throw "Public HTTP/loopback is blocked. Use LAN/Tailscale or HERMES_PAIR_SCHEME=https."
    }
    $defaultPort = if ($scheme -eq "https") { 443 } else { 8642 }
    $port = $defaultPort
    if ($env:HERMES_PAIR_PORT) {
        if (-not ([int]::TryParse($env:HERMES_PAIR_PORT, [ref]$port)) -or $port -lt 1 -or $port -gt 65535) {
            throw "HERMES_PAIR_PORT must be a valid TCP port."
        }
    }
    $baseHost = if ($hostInfo.Address.Contains(":")) { "[$($hostInfo.Address)]" } else { $hostInfo.Address }
    $gateway = "$($scheme)://$($baseHost):$port"
    if ($scheme -eq "http") {
        $dashboard = if ($env:HERMES_DASHBOARD_URL) { $env:HERMES_DASHBOARD_URL.TrimEnd('/') } else { "http://$($baseHost):9119" }
        $bridge = if ($env:HERMES_BRIDGE_URL) { $env:HERMES_BRIDGE_URL.TrimEnd('/') } else { "http://$($baseHost):9131" }
        $bind = if ($env:HERMES_SERVICE_BIND_HOST) { $env:HERMES_SERVICE_BIND_HOST } else { "0.0.0.0" }
    } else {
        $dashboard = if ($env:HERMES_DASHBOARD_URL) { $env:HERMES_DASHBOARD_URL.TrimEnd('/') } else { $gateway }
        $bridge = if ($env:HERMES_BRIDGE_URL) { $env:HERMES_BRIDGE_URL.TrimEnd('/') } else { $gateway }
        $bind = if ($env:HERMES_SERVICE_BIND_HOST) { $env:HERMES_SERVICE_BIND_HOST } else { "127.0.0.1" }
    }
    if ($bind -notin @("0.0.0.0", "127.0.0.1")) {
        throw "HERMES_SERVICE_BIND_HOST must be 0.0.0.0 or 127.0.0.1."
    }
    Assert-AllowedServiceUrl $gateway
    Assert-AllowedServiceUrl $dashboard
    Assert-AllowedServiceUrl $bridge
    $kind = $hostInfo.Kind
    if ($kind -eq "override") {
        $kind = if (Test-Cgnat $hostInfo.Address) { "mesh" } else { "lan" }
    }
    return @{
        Address = $hostInfo.Address
        Kind = $kind
        InterfaceIndex = $hostInfo.InterfaceIndex
        Scheme = $scheme
        Port = $port
        GatewayBase = $gateway
        DashboardBase = $dashboard
        BridgeBase = $bridge
        BindHost = $bind
    }
}

function Write-ServiceRunner([string]$Name, [string]$Content) {
    $path = Join-Path $ServicesDir "$Name.ps1"
    [IO.File]::WriteAllText($path, $Content, $Utf8NoBom)
    return $path
}

function Install-StartupShortcut([string]$Name, [string]$ScriptPath) {
    $startup = [Environment]::GetFolderPath("Startup")
    if (-not $startup) { return }
    $shortcutPath = Join-Path $startup "$Name.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Get-PowerShellExecutable
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $shortcut.WorkingDirectory = $HermesHome
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

function Register-HermesTask([string]$TaskName, [string]$ScriptPath) {
    try {
        Import-Module ScheduledTasks -ErrorAction Stop
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction -Execute (Get-PowerShellExecutable) `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
            -WorkingDirectory $HermesHome
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -RestartCount 999 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force | Out-Null
        return $true
    } catch {
        Write-Warn "Scheduled Task '$TaskName' could not be registered: $($_.Exception.Message)"
        Install-StartupShortcut $TaskName $ScriptPath
        return $false
    }
}

function Register-HermesManualTask([string]$TaskName, [string]$ScriptPath) {
    try {
        Import-Module ScheduledTasks -ErrorAction Stop
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action = New-ScheduledTaskAction -Execute (Get-PowerShellExecutable) `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
            -WorkingDirectory $HermesHome
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
            -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -Action $action -Settings $settings `
            -Principal $principal -Force | Out-Null
        return $true
    } catch {
        Write-Warn "Restart task '$TaskName' could not be registered: $($_.Exception.Message)"
        return $false
    }
}

function Start-HermesProcess([string]$TaskName, [string]$ScriptPath, [bool]$Registered) {
    if ($Registered) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName
    } else {
        Start-Process -FilePath (Get-PowerShellExecutable) `
            -ArgumentList @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) `
            -WorkingDirectory $HermesHome -WindowStyle Hidden | Out-Null
    }
}

function Test-RestrictedFirewallRule([string]$DisplayName, [string]$Kind) {
    try {
        Import-Module NetSecurity -ErrorAction Stop
        $expectedProfile = if ($Kind -eq "mesh") { "Any" } else { "Private" }
        $expectedRemote = if ($Kind -eq "mesh") { "100.64.0.0/10" } else { "LocalSubnet" }
        $requiredPorts = @("8642", "9119", "9131")
        foreach ($rule in @(Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue)) {
            if ($rule.Enabled.ToString() -ne "True" -or
                $rule.Direction.ToString() -ne "Inbound" -or
                $rule.Action.ToString() -ne "Allow" -or
                $rule.Profile.ToString() -ne $expectedProfile) {
                continue
            }
            $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction Stop
            $addressFilter = $rule | Get-NetFirewallAddressFilter -ErrorAction Stop
            if ($portFilter.Protocol.ToString() -notin @("TCP", "6")) { continue }
            $ports = @($portFilter.LocalPort | ForEach-Object {
                $_.ToString().Split(',') | ForEach-Object { $_.Trim() }
            })
            $addresses = @($addressFilter.RemoteAddress | ForEach-Object {
                $_.ToString().Split(',') | ForEach-Object { $_.Trim() }
            })
            if (@($requiredPorts | Where-Object { $_ -notin $ports }).Count -eq 0 -and
                $expectedRemote -in $addresses) {
                return $true
            }
        }
    } catch {}
    return $false
}

function Install-RestrictedFirewallRuleElevated([string]$Kind) {
    # Elevate only the firewall mutation. The main installer keeps running as
    # the original user, so Hermes, Scheduled Tasks and LOCALAPPDATA never end
    # up under a different administrator profile.
    $helper = Join-Path ([IO.Path]::GetTempPath()) (
        "hermes-console-firewall-$([Guid]::NewGuid().ToString('N')).ps1"
    )
    $content = @'
param([ValidateSet("mesh", "lan")][string]$Kind)
$ErrorActionPreference = "Stop"
Import-Module NetSecurity -ErrorAction Stop
$display = if ($Kind -eq "mesh") {
    "Hermes Console Tailscale"
} else {
    "Hermes Console private network"
}
Get-NetFirewallRule -DisplayName $display -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction Stop
if ($Kind -eq "mesh") {
    New-NetFirewallRule -DisplayName $display -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 8642, 9119, 9131 -Profile Any `
        -RemoteAddress "100.64.0.0/10" | Out-Null
} else {
    New-NetFirewallRule -DisplayName $display -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 8642, 9119, 9131 -Profile Private `
        -RemoteAddress LocalSubnet | Out-Null
}
'@
    [IO.File]::WriteAllText($helper, $content, $Utf8NoBom)
    try {
        Write-Info "Windows will request administrator approval for the restricted firewall rule."
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$helper`" -Kind $Kind"
        $process = Start-Process -FilePath (Get-PowerShellExecutable) -Verb RunAs `
            -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "The elevated firewall helper exited with code $($process.ExitCode)."
        }
    } finally {
        Remove-Item -LiteralPath $helper -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-PrivateFirewallRules([hashtable]$Pairing) {
    if ($Pairing.Scheme -eq "https") { return }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $display = if ($Pairing.Kind -eq "mesh") {
        "Hermes Console Tailscale"
    } else {
        "Hermes Console private network"
    }
    if ($Pairing.Kind -eq "lan" -and $Pairing.InterfaceIndex) {
        $profile = Get-NetConnectionProfile -InterfaceIndex $Pairing.InterfaceIndex -ErrorAction SilentlyContinue
        if ($profile -and $profile.NetworkCategory -ne "Private") {
            throw "The selected LAN is '$($profile.NetworkCategory)'. Mark it Private or use Tailscale before exposing Hermes."
        }
    }
    if (-not $admin) {
        if (Test-RestrictedFirewallRule $display $Pairing.Kind) {
            Write-Ok "Existing restricted Windows Firewall rule verified"
            return
        }
        try {
            Install-RestrictedFirewallRuleElevated $Pairing.Kind
        } catch {
            throw "Windows Firewall needs a restricted inbound rule and elevation was not completed: $($_.Exception.Message) No QR was generated."
        }
        if (-not (Test-RestrictedFirewallRule $display $Pairing.Kind)) {
            throw "The elevated Windows Firewall rule could not be verified; no QR was generated."
        }
        Write-Ok "Restricted Windows Firewall rule installed and verified"
        return
    }
    try {
        Import-Module NetSecurity -ErrorAction Stop
        Get-NetFirewallRule -DisplayName $display -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        if ($Pairing.Kind -eq "mesh") {
            New-NetFirewallRule -DisplayName $display -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort 8642, 9119, 9131 -Profile Any `
                -RemoteAddress "100.64.0.0/10" | Out-Null
            Write-Ok "Tailscale-only Windows Firewall rule installed"
        } else {
            New-NetFirewallRule -DisplayName $display -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort 8642, 9119, 9131 -Profile Private `
                -RemoteAddress LocalSubnet | Out-Null
            Write-Ok "Private-LAN Windows Firewall rule installed"
        }
    } catch {
        throw "Could not configure a restricted Windows Firewall rule: $($_.Exception.Message)"
    }
}

function Install-HermesIfNeeded {
    $hermes = Get-HermesExecutable
    if ($hermes) {
        try { & $hermes --version *> $null; if ($LASTEXITCODE -eq 0) { return $hermes } } catch {}
    }
    Write-Info "Installing Hermes Agent for native Windows..."
    $installer = Join-Path ([IO.Path]::GetTempPath()) "hermes-agent-install.ps1"
    Invoke-WebRequest -Uri "https://hermes-agent.nousresearch.com/install.ps1" `
        -OutFile $installer -UseBasicParsing
    try {
        & (Get-PowerShellExecutable) -NoProfile -ExecutionPolicy Bypass -File $installer `
            -SkipSetup -NonInteractive -HermesHome $HermesHome -InstallDir $InstallDir
        if ($LASTEXITCODE -ne 0) { throw "Hermes installer exited with $LASTEXITCODE" }
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
    $hermes = Get-HermesExecutable
    if (-not $hermes) { throw "Hermes Agent executable was not found after installation." }
    return $hermes
}

function Install-VerifiedBridge([string]$Python) {
    Invoke-WebRequest -Uri "$RepoRaw/bridge-release.json" -OutFile $ManifestFile -UseBasicParsing
    Invoke-WebRequest -Uri "$RepoRaw/hermes_bridge.py" -OutFile $BridgeNew -UseBasicParsing
    $manifest = Get-Content -LiteralPath $ManifestFile -Raw | ConvertFrom-Json
    $expectedFields = @("schema", "version", "min_app_build", "sha256", "size")
    $actualFields = @($manifest.PSObject.Properties.Name)
    if (@(Compare-Object $expectedFields $actualFields).Count -ne 0) {
        throw "Invalid Bridge release manifest fields"
    }
    if ($manifest.schema -ne 1 -or $manifest.version -notmatch '^\d+\.\d+\.\d+$' -or
        [int64]$manifest.min_app_build -le 0 -or $manifest.sha256 -notmatch '^[a-f0-9]{64}$' -or
        [int64]$manifest.size -le 0 -or [int64]$manifest.size -gt 524288) {
        throw "Invalid Bridge release manifest"
    }
    $item = Get-Item -LiteralPath $BridgeNew
    $digest = (Get-FileHash -LiteralPath $BridgeNew -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($item.Length -ne [int64]$manifest.size -or $digest -ne $manifest.sha256) {
        throw "Bridge release integrity check failed"
    }
    $source = [IO.File]::ReadAllText($BridgeNew, [Text.Encoding]::UTF8)
    $versions = [regex]::Matches($source, '(?m)^VERSION\s*=\s*["''](\d+\.\d+\.\d+)["'']\s*(?:#.*)?$')
    if ($versions.Count -ne 1 -or $versions[0].Groups[1].Value -ne $manifest.version) {
        throw "Bridge source VERSION mismatch"
    }
    & $Python -m py_compile $BridgeNew
    if ($LASTEXITCODE -ne 0) { throw "Bridge Python compilation failed" }
    if (Test-Path -LiteralPath $BridgeTarget) {
        [IO.File]::Replace($BridgeNew, $BridgeTarget, $BridgeBackup, $true)
    } else {
        Move-Item -LiteralPath $BridgeNew -Destination $BridgeTarget
    }
    return $manifest.version
}

function Render-Qr([string]$Python, [string]$Link) {
    $code = "import qrcode,sys;q=qrcode.QRCode(border=1);q.add_data(sys.argv[1]);q.make();q.print_ascii(invert=True)"
    & $Python -c "import qrcode" 2>$null
    if ($LASTEXITCODE -ne 0) {
        & $Python -m pip install -q qrcode *> $null
    }
    & $Python -c $code $Link
    return $LASTEXITCODE -eq 0
}

try {
    New-Item -ItemType Directory -Force -Path $HermesHome, $ServicesDir, $LogsDir | Out-Null
    $HermesExe = Install-HermesIfNeeded
    $PythonExe = Get-HermesPython
    if (-not $PythonExe) { throw "Hermes virtual-environment Python was not found." }
    & $PythonExe -c "import aiohttp" *> $null
    if ($LASTEXITCODE -ne 0) { throw "Hermes Python does not provide aiohttp." }
    $ApiKey = Ensure-ApiKey
    $Pairing = Get-PairingConfiguration
    $HadBridgeTarget = Test-Path -LiteralPath $BridgeTarget
    $BridgeVersion = Install-VerifiedBridge $PythonExe

    $gatewayRunnerContent = @'
$ErrorActionPreference = "Stop"
$HermesHome = Split-Path $PSScriptRoot -Parent
$env:HERMES_HOME = $HermesHome
$env:API_SERVER_HOST = "__BIND_HOST__"
$env:API_SERVER_PORT = "8642"
$exe = Join-Path $HermesHome "hermes-agent\venv\Scripts\hermes.exe"
$log = Join-Path $HermesHome "logs\gateway.log"
Set-Location $HermesHome
& $exe gateway run --replace >> $log 2>&1
exit $LASTEXITCODE
'@
    $gatewayRunner = Write-ServiceRunner "hermes-gateway" ($gatewayRunnerContent.Replace("__BIND_HOST__", $Pairing.BindHost))
    $dashboardRunnerContent = @'
$ErrorActionPreference = "Stop"
$HermesHome = Split-Path $PSScriptRoot -Parent
$env:HERMES_HOME = $HermesHome
$exe = Join-Path $HermesHome "hermes-agent\venv\Scripts\hermes.exe"
$log = Join-Path $HermesHome "logs\dashboard.log"
Set-Location $HermesHome
& $exe dashboard --host __BIND_HOST__ --port 9119 --no-open >> $log 2>&1
exit $LASTEXITCODE
'@
    $dashboardRunner = Write-ServiceRunner "hermes-dashboard" ($dashboardRunnerContent.Replace("__BIND_HOST__", $Pairing.BindHost))
    $bridgeRunnerContent = @'
$ErrorActionPreference = "Stop"
$HermesHome = Split-Path $PSScriptRoot -Parent
$env:HERMES_HOME = $HermesHome
$env:BRIDGE_HERMES_HOME = $HermesHome
$env:BRIDGE_HOST = "__BIND_HOST__"
$env:BRIDGE_PORT = "9131"
$env:BRIDGE_SCOPES = "read,memory,soul,skills,cron,config,command"
$env:BRIDGE_READ_ONLY = "false"
foreach ($line in [IO.File]::ReadAllLines((Join-Path $HermesHome ".env"))) {
    if ($line -match '^API_SERVER_KEY=(.*)$') { $env:BRIDGE_TOKEN = $Matches[1].Trim().Trim('"').Trim("'"); break }
}
if (-not $env:BRIDGE_TOKEN) { throw "API_SERVER_KEY is missing" }
$python = Join-Path $HermesHome "hermes-agent\venv\Scripts\python.exe"
$bridge = Join-Path $HermesHome "hermes_bridge.py"
$log = Join-Path $HermesHome "logs\bridge.log"
Set-Location $HermesHome
& $python $bridge --i-know-what-im-doing >> $log 2>&1
exit $LASTEXITCODE
'@
    $bridgeRunner = Write-ServiceRunner "hermes-bridge" ($bridgeRunnerContent.Replace("__BIND_HOST__", $Pairing.BindHost))
    $dashboardRestartRunner = Write-ServiceRunner "restart-hermes-dashboard" @'
$ErrorActionPreference = "Stop"
Start-Sleep -Milliseconds 300
& schtasks.exe /End /TN "HermesConsole-Dashboard" 2>$null | Out-Null
Start-Sleep -Milliseconds 500
& schtasks.exe /Run /TN "HermesConsole-Dashboard" | Out-Null
exit $LASTEXITCODE
'@
    $bridgeRestartRunner = Write-ServiceRunner "restart-hermes-bridge" @'
$ErrorActionPreference = "Stop"
Start-Sleep -Milliseconds 500
& schtasks.exe /End /TN "HermesConsole-MobileBridge" 2>$null | Out-Null
Start-Sleep -Milliseconds 500
& schtasks.exe /Run /TN "HermesConsole-MobileBridge" | Out-Null
exit $LASTEXITCODE
'@

    $gatewayTask = Register-HermesTask "HermesConsole-Gateway" $gatewayRunner
    $dashboardTask = Register-HermesTask "HermesConsole-Dashboard" $dashboardRunner
    $bridgeTask = Register-HermesTask "HermesConsole-MobileBridge" $bridgeRunner
    if ($dashboardTask) {
        [void](Register-HermesManualTask "HermesConsole-Restart-Dashboard" $dashboardRestartRunner)
    }
    if ($bridgeTask) {
        [void](Register-HermesManualTask "HermesConsole-Restart-MobileBridge" $bridgeRestartRunner)
    }

    Start-HermesProcess "HermesConsole-Gateway" $gatewayRunner $gatewayTask
    Start-HermesProcess "HermesConsole-MobileBridge" $bridgeRunner $bridgeTask
    if (-not (Wait-HermesService "gateway" "http://127.0.0.1:8642" $ApiKey 40)) {
        throw "Gateway did not pass /health plus authenticated /api/sessions. TCP 8642 may be occupied by another process; inspect $LogsDir and Task Scheduler."
    }
    Write-Ok "Gateway identity and authentication passed on 8642"
    if (-not (Wait-HermesService "bridge" "http://127.0.0.1:9131" $ApiKey 40 $BridgeVersion)) {
        if (Test-Path -LiteralPath $BridgeBackup) {
            Copy-Item -LiteralPath $BridgeBackup -Destination $BridgeTarget -Force
            Start-HermesProcess "HermesConsole-MobileBridge" $bridgeRunner $bridgeTask
        } elseif (-not $HadBridgeTarget) {
            Remove-Item -LiteralPath $BridgeTarget -Force -ErrorAction SilentlyContinue
        }
        throw "Mobile Bridge did not pass health, auth and self-update capability checks. TCP 9131 may be occupied; inspect $LogsDir and Task Scheduler."
    }
    Write-Ok "Mobile Bridge $BridgeVersion health, auth and self-update passed"

    try { & $HermesExe dashboard --stop *> $null } catch {}
    $passwordBytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($passwordBytes) } finally { $rng.Dispose() }
    $password = [Convert]::ToBase64String($passwordBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $bridgeHeaders = @{ Authorization = "Bearer $ApiKey" }
    $currentCredentials = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:9131/bridge/dashboard/credentials" -Headers $bridgeHeaders -TimeoutSec 65
    if ($currentCredentials.ok -ne $true) {
        throw "Dashboard credential endpoint rejected the read."
    }
    if ($currentCredentials.password_set -ne $true) {
        $username = if ($currentCredentials.username) { $currentCredentials.username } else { "admin" }
        $body = @{ username = $username; password = $password } | ConvertTo-Json -Compress
        $credentials = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:9131/bridge/dashboard/credentials" `
            -Headers $bridgeHeaders -ContentType "application/json" -Body $body -TimeoutSec 65
        if ($credentials.ok -ne $true) {
            throw "Dashboard credential endpoint rejected the configuration."
        }
    }
    Start-HermesProcess "HermesConsole-Dashboard" $dashboardRunner $dashboardTask
    if (-not (Wait-HermesService "dashboard" "http://127.0.0.1:9119" $ApiKey 60)) {
        throw "Dashboard did not pass /api/status or reports Gateway stopped. TCP 9119 may be occupied; inspect $LogsDir and Task Scheduler."
    }
    Write-Ok "Dashboard identity and Gateway state passed on 9119"

    Ensure-PrivateFirewallRules $Pairing

    if (-not (Wait-HermesService "gateway" $Pairing.GatewayBase $ApiKey 12 "" -PhoneFacing)) {
        throw "Gateway works locally but not through $($Pairing.GatewayBase). Check bind, VPN/LAN, proxy and host/cloud firewall. No QR was generated."
    }
    if (-not (Wait-HermesService "bridge" $Pairing.BridgeBase $ApiKey 12 $BridgeVersion -PhoneFacing)) {
        throw "Mobile Bridge works locally but not through $($Pairing.BridgeBase). Check routing/proxy rules for /bridge/*. No QR was generated."
    }
    if (-not (Wait-HermesService "dashboard" $Pairing.DashboardBase $ApiKey 12 "" -PhoneFacing)) {
        throw "Dashboard works locally but not through $($Pairing.DashboardBase). Check routing/proxy rules for /api/status. No QR was generated."
    }

    $pairingRecord = [ordered]@{
        schema = 1
        host = $Pairing.Address
        scheme = $Pairing.Scheme
        port = $Pairing.Port
        gateway = $Pairing.GatewayBase
        dashboard = $Pairing.DashboardBase
        bridge = $Pairing.BridgeBase
        kind = $Pairing.Kind
    }
    [IO.File]::WriteAllText($PairingFile, ($pairingRecord | ConvertTo-Json -Compress), $Utf8NoBom)

    $query = @(
        "host=$([Uri]::EscapeDataString($Pairing.Address))"
        "port=$($Pairing.Port)"
        "token=$([Uri]::EscapeDataString($ApiKey))"
        "dashboard=$([Uri]::EscapeDataString($Pairing.DashboardBase))"
        "bridge=$([Uri]::EscapeDataString($Pairing.BridgeBase))"
        "bridge_token=$([Uri]::EscapeDataString($ApiKey))"
    )
    if ($Pairing.Scheme -eq "https") { $query += "https=1" }
    $link = "hermes://pair?" + ($query -join "&")
    Write-Host ""
    Write-Host "== SCAN THIS QR WITH HERMES CONSOLE (or copy the link) ==" -ForegroundColor Yellow
    Write-Host ""
    if (-not (Render-Qr $PythonExe $link)) {
        Write-Warn "A QR renderer could not be prepared. Paste the link shown below."
    }
    Write-Host ""
    Write-Host "Link: $link"
    Write-Host ""
    Write-Host "All three services passed local and phone-address health/auth checks."
    Write-Host "To verify them and show this QR again later in PowerShell:"
    Write-Host "  irm $RepoRaw/hermes-pair.ps1 | iex"
    Write-Host "If chat has no model yet, open Dashboard from the app and configure your AI provider/model."
} finally {
    Remove-Item -LiteralPath $BridgeNew, $ManifestFile -Force -ErrorAction SilentlyContinue
}
