# Hermes Console - native Windows setup (PowerShell 5.1+).
# Installs/repairs Hermes, Gateway, Dashboard and Mobile Bridge for this user.

param(
    [switch]$AuditOnly,
    [switch]$NoFirewallPrompt
)

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
$AuditDir = Join-Path $HermesHome "audit"
$AuditLog = Join-Path $AuditDir "safe-setup-audit.jsonl"
$EnvFile = Join-Path $HermesHome ".env"
$BridgeTarget = Join-Path $HermesHome "hermes_bridge.py"
$BridgeNew = "$BridgeTarget.new"
$BridgeBackup = "$BridgeTarget.rollback"
$ManifestFile = Join-Path $HermesHome "bridge-release.json.new"
$PairingFile = Join-Path $ServicesDir "pairing.json"
$QrFile = Join-Path $ServicesDir "pairing-qr.png"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:TaskDefinitionsChanged = @{}
$script:RunnerChanged = @{}
$script:BridgeChanged = $false

New-Item -ItemType Directory -Force -Path $HermesHome, $ServicesDir, $LogsDir, $AuditDir | Out-Null

function Protect-AuditText([string]$Text) {
    if (-not $Text) { return "" }
    $safe = $Text -replace '(?i)hermes://pair\?[^\s"'']+', 'hermes://pair?[REDACTED]'
    $safe = $safe -replace '(?i)(api[_ -]?key|token|password|credential)(\s*[:=]\s*)[^\s,;]+', '$1$2[REDACTED]'
    return $safe
}

function Write-Audit([string]$Step, [string]$State, [string]$Detail = "") {
    $safe = Protect-AuditText $Detail
    $row = [ordered]@{
        time = (Get-Date).ToString('o')
        step = $Step
        state = $State
        detail = $safe
    }
    [IO.File]::AppendAllText(
        $AuditLog,
        (($row | ConvertTo-Json -Compress) + [Environment]::NewLine),
        $Utf8NoBom
    )
    $color = if ($State -eq 'OK') { 'Green' } elseif ($State -in @('INFO', 'SKIP')) { 'Cyan' } else { 'Yellow' }
    $suffix = if ($safe) { ": $safe" } else { "" }
    Write-Host "[$State] $Step$suffix" -ForegroundColor $color
}

function Write-Info([string]$Message) { Write-Audit "Hermes Console" "INFO" $Message }
function Write-Ok([string]$Message) { Write-Audit "Hermes Console" "OK" $Message }
function Write-Warn([string]$Message) { Write-Audit "Hermes Console" "WARN" $Message }

$script:SetupPhase = 0
$script:SetupPhaseTotal = 7
function Write-SetupPhase([string]$Label) {
    $script:SetupPhase++
    $filled = "#" * $script:SetupPhase
    $remaining = "." * ($script:SetupPhaseTotal - $script:SetupPhase)
    Write-Audit "Setup progress" "INFO" "[$filled$remaining] $($script:SetupPhase)/$($script:SetupPhaseTotal) $Label"
}

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
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastReported = -1
    while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
        if (Test-HermesService $Kind $BaseUrl $Token $ExpectedVersion -PhoneFacing:$PhoneFacing) {
            Write-Audit "$Kind readiness" "OK" ("Ready in {0:N1}s" -f $watch.Elapsed.TotalSeconds)
            return $true
        }
        $elapsed = [int]$watch.Elapsed.TotalSeconds
        if ($elapsed -ne $lastReported -and $elapsed % 2 -eq 0) {
            Write-Audit "$Kind readiness" "INFO" "Waiting (${elapsed}s/${Seconds}s)"
            $lastReported = $elapsed
        }
        Start-Sleep -Milliseconds 500
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
    $lines = if (Test-Path -LiteralPath $EnvFile) {
        @([IO.File]::ReadAllLines($EnvFile))
    } else { @() }
    $keyLines = @($lines | Where-Object { $_ -match '^API_SERVER_KEY=' })
    if ($key -and $keyLines.Count -eq 1 -and $keyLines[0] -eq "API_SERVER_KEY=$key") {
        Write-Audit "API key" "SKIP" "Existing strong key retained"
        return $key
    }
    if ($AuditOnly) {
        throw "API_SERVER_KEY is missing, weak or duplicated."
    }
    if (-not $key) {
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $key = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
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
    Write-Audit "API key" "OK" "Generated or normalized in .env"
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
        $meshOverride = (Test-Cgnat $hostInfo.Address) -or
            $hostInfo.Address.EndsWith(".ts.net", [StringComparison]::OrdinalIgnoreCase)
        if (-not $meshOverride) {
            try {
                $meshOverride = @([Net.Dns]::GetHostAddresses($hostInfo.Address) |
                    Where-Object { Test-Cgnat $_.IPAddressToString }).Count -gt 0
            } catch {}
        }
        $kind = if ($meshOverride) { "mesh" } else { "lan" }
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
    $path = Join-Path $ServicesDir "$Name.vbs"
    if ((Test-Path -LiteralPath $path) -and [IO.File]::ReadAllText($path) -eq $Content) {
        $script:RunnerChanged[$Name] = $false
        return $path
    }
    if ($AuditOnly) { throw "Runner $Name is missing or outdated." }
    # Unicode es la codificación nativa y estable de Windows Script Host 5.1.
    [IO.File]::WriteAllText($path, $Content, [Text.Encoding]::Unicode)
    $script:RunnerChanged[$Name] = $true
    return $path
}

function Install-StartupShortcut([string]$Name, [string]$ScriptPath) {
    $startup = [Environment]::GetFolderPath("Startup")
    if (-not $startup) { throw "The per-user Startup folder is unavailable." }
    $shortcutPath = Join-Path $startup "$Name.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
    $arguments = "//B //NoLogo `"$ScriptPath`""
    if (Test-Path -LiteralPath $shortcutPath) {
        $existing = $shell.CreateShortcut($shortcutPath)
        if ($existing.TargetPath -eq $wscript -and $existing.Arguments -eq $arguments) {
            Write-Audit "Startup $Name" "SKIP" "Existing invisible fallback retained"
            return $false
        }
    }
    if ($AuditOnly) { throw "Startup fallback $Name is missing or outdated." }
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $wscript
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = $HermesHome
    $shortcut.WindowStyle = 7 # Minimized/no activation; wscript runner itself is windowless.
    $shortcut.Save()
    Write-Audit "Startup $Name" "OK" "Invisible fallback installed"
    return $true
}

function Register-HermesTask([string]$TaskName, [string]$ScriptPath) {
    try {
        Import-Module ScheduledTasks -ErrorAction Stop
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
        $arguments = "//B //NoLogo `"$ScriptPath`""
        $current = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $currentAction = if ($current) { @($current.Actions)[0] } else { $null }
        $same = $current -and $current.Settings.Enabled -and
            $currentAction.Execute -eq $wscript -and
            $currentAction.Arguments -eq $arguments
        if ($same) {
            $script:TaskDefinitionsChanged[$TaskName] = $false
            Write-Audit "Task $TaskName" "SKIP" "Existing invisible definition retained"
            return $true
        }
        if ($AuditOnly) { throw "Scheduled Task $TaskName is missing or outdated." }
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute $wscript `
            -Argument $arguments `
            -WorkingDirectory $HermesHome
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force | Out-Null
        $script:TaskDefinitionsChanged[$TaskName] = $true
        $startupLink = Join-Path ([Environment]::GetFolderPath("Startup")) "$TaskName.lnk"
        Remove-Item -LiteralPath $startupLink -Force -ErrorAction SilentlyContinue
        Write-Audit "Task $TaskName" "OK" "Created with invisible wscript.exe runner"
        return $true
    } catch {
        if ($AuditOnly) { throw }
        Write-Warn "Scheduled Task '$TaskName' is unavailable; using the per-user Startup fallback."
        $changed = Install-StartupShortcut $TaskName $ScriptPath
        $script:TaskDefinitionsChanged[$TaskName] = $changed
        return $false
    }
}

function Register-HermesManualTask([string]$TaskName, [string]$ScriptPath) {
    try {
        Import-Module ScheduledTasks -ErrorAction Stop
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
        $arguments = "//B //NoLogo `"$ScriptPath`""
        $current = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $currentAction = if ($current) { @($current.Actions)[0] } else { $null }
        $same = $current -and $current.Settings.Enabled -and
            $currentAction.Execute -eq $wscript -and
            $currentAction.Arguments -eq $arguments
        if ($same) {
            Write-Audit "Task $TaskName" "SKIP" "Manual restart definition retained"
            return $true
        }
        if ($AuditOnly) { throw "Manual task $TaskName is missing or outdated." }
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute $wscript `
            -Argument $arguments `
            -WorkingDirectory $HermesHome
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
            -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -Action $action -Settings $settings `
            -Principal $principal -Force | Out-Null
        Write-Audit "Task $TaskName" "OK" "Manual restart task created windowless"
        return $true
    } catch {
        if ($AuditOnly) { throw }
        Write-Warn "Restart task '$TaskName' could not be registered; remote restart will be unavailable."
        return $false
    }
}

function Test-HermesTaskRunning([string]$TaskName) {
    try {
        Import-Module ScheduledTasks -ErrorAction Stop
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        return $null -ne $task -and $task.State.ToString() -eq "Running"
    } catch {
        return $false
    }
}

function Start-HermesProcess(
    [string]$TaskName,
    [string]$ScriptPath,
    [bool]$Registered,
    [int]$Port = 0
) {
    if ($Registered) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($Port -gt 0) {
            Wait-PortRelease $Port 5
            Assert-PortAvailable $Port $TaskName
        }
        Start-ScheduledTask -TaskName $TaskName
    } else {
        if ($Port -gt 0) { Assert-PortAvailable $Port $TaskName }
        $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
        $arguments = "//B //NoLogo `"$ScriptPath`""
        Start-Process -FilePath $wscript `
            -ArgumentList $arguments `
            -WorkingDirectory $HermesHome -WindowStyle Hidden | Out-Null
    }
}

function Remove-LegacyTasks {
    foreach ($name in @("Hermes Gateway", "Hermes Dashboard", "Hermes Mobile Bridge")) {
        try {
            Import-Module ScheduledTasks -ErrorAction Stop
            if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
                if ($AuditOnly) { throw "Legacy task '$name' is still installed." }
                Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $name -Confirm:$false
                Write-Audit "Legacy task $name" "OK" "Removed to prevent duplicate services"
            }
        } catch {
            if ($AuditOnly -and $_.Exception.Message -like "Legacy task*") { throw }
        }
        $startup = [Environment]::GetFolderPath("Startup")
        if ($startup) {
            $legacyLink = Join-Path $startup "$name.lnk"
            if (Test-Path -LiteralPath $legacyLink) {
                if ($AuditOnly) { throw "Legacy Startup shortcut '$name' is still installed." }
                Remove-Item -LiteralPath $legacyLink -Force
            }
        }
    }
}

function Get-PortOwner([int]$Port) {
    try {
        $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
            Select-Object -First 1
        if (-not $connection) { return $null }
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)" `
            -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            Pid = $connection.OwningProcess
            Name = $process.Name
        }
    } catch {
        return $null
    }
}

function Assert-PortAvailable([int]$Port, [string]$Service) {
    $owner = Get-PortOwner $Port
    if ($owner) {
        # La línea de comandos puede contener tokens o credenciales. PID y
        # nombre identifican al propietario sin copiar secretos al registro.
        throw "$Service port $Port is occupied by PID $($owner.Pid) $($owner.Name)."
    }
}

function Wait-PortRelease([int]$Port, [int]$Seconds = 5) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-PortOwner $Port) -and $watch.Elapsed.TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 250
    }
}

function Invoke-HiddenProcess(
    [string]$File,
    [string]$Arguments,
    [int]$TimeoutSeconds,
    [string]$StdoutPath,
    [string]$StderrPath
) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments `
        -WorkingDirectory $HermesHome -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        throw "Hidden process timed out after ${TimeoutSeconds}s: $File"
    }
    $process.WaitForExit()
    $process.Refresh()
    if ($process.ExitCode -ne 0) {
        $tail = ""
        if (Test-Path -LiteralPath $StderrPath) {
            $tail = ([IO.File]::ReadAllText($StderrPath) -replace '[\r\n]+', ' ').Trim()
            if ($tail.Length -gt 500) { $tail = $tail.Substring($tail.Length - 500) }
        }
        throw "Hidden process exited with $($process.ExitCode): $tail"
    }
}

function Test-RestrictedFirewallRule([string]$DisplayName, [string]$Kind) {
    try {
        Import-Module NetSecurity -ErrorAction Stop
        $expectedProfile = if ($Kind -eq "mesh") { "Any" } else { "Private" }
        $expectedRemote = if ($Kind -eq "mesh") {
            @("100.64.0.0/10", "100.64.0.0/255.192.0.0")
        } else { @("LocalSubnet") }
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
                @($addresses | Where-Object { $_ -in $expectedRemote }).Count -gt 0) {
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
        if ($NoFirewallPrompt) {
            throw "Firewall repair needs elevation and -NoFirewallPrompt was selected."
        }
        Write-Info "Windows will request administrator approval for the restricted firewall rule."
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$helper`" -Kind $Kind"
        $process = Start-Process -FilePath (Get-PowerShellExecutable) -Verb RunAs `
            -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
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
    if ($AuditOnly) {
        if (-not (Test-RestrictedFirewallRule $display $Pairing.Kind)) {
            throw "Restricted Windows Firewall rule is missing or invalid."
        }
        Write-Audit "Firewall" "SKIP" "Existing restricted rule verified"
        return
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
        try {
            $version = (& $hermes --version 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0) {
                Write-Audit "Hermes Agent" "SKIP" "Installed: $version"
                return $hermes
            }
        } catch {}
    }
    if ($AuditOnly) { throw "Hermes Agent is not installed or is broken." }
    Write-Info "Installing Hermes Agent for native Windows..."
    $installer = Join-Path ([IO.Path]::GetTempPath()) "hermes-agent-install.ps1"
    Invoke-WebRequest -Uri "https://hermes-agent.nousresearch.com/install.ps1" `
        -OutFile $installer -UseBasicParsing
    try {
        $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installer`" " +
            "-SkipSetup -NonInteractive -HermesHome `"$HermesHome`" -InstallDir `"$InstallDir`""
        Invoke-HiddenProcess (Get-PowerShellExecutable) $arguments 180 `
            (Join-Path $AuditDir "hermes-install.out.log") `
            (Join-Path $AuditDir "hermes-install.err.log")
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
    $hermes = Get-HermesExecutable
    if (-not $hermes) { throw "Hermes Agent executable was not found after installation." }
    Write-Audit "Hermes Agent" "OK" "Installed with the official installer"
    return $hermes
}

function Install-VerifiedBridge([string]$Python) {
    Invoke-WebRequest -Uri "$RepoRaw/bridge-release.json" -OutFile $ManifestFile -UseBasicParsing
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

    function Test-BridgeArtifact([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $item = Get-Item -LiteralPath $Path
        $digest = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($item.Length -ne [int64]$manifest.size -or $digest -ne $manifest.sha256) {
            return $false
        }
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $source = [IO.File]::ReadAllText($Path, $strictUtf8)
        } catch {
            return $false
        }
        $versions = [regex]::Matches($source, '(?m)^VERSION\s*=\s*["''](\d+\.\d+\.\d+)["'']\s*(?:#.*)?$')
        if ($versions.Count -ne 1 -or $versions[0].Groups[1].Value -ne $manifest.version) {
            return $false
        }
        $compileLog = Join-Path $AuditDir "bridge-compile.log"
        # Compila en memoria: misma validación sintáctica que `-m py_compile`
        # sin crear __pycache__ durante una auditoría de solo lectura.
        & $Python -c 'import pathlib,sys;compile(pathlib.Path(sys.argv[1]).read_bytes(),sys.argv[1],"exec")' $Path *> $compileLog
        return $LASTEXITCODE -eq 0
    }

    if (Test-BridgeArtifact $BridgeTarget) {
        $script:BridgeChanged = $false
        Write-Audit "Mobile Bridge file" "SKIP" "Version $($manifest.version), size, SHA-256 and syntax verified"
        return [string]$manifest.version
    }
    if ($AuditOnly) {
        throw "Mobile Bridge is missing, outdated or failed integrity/syntax validation; expected $($manifest.version)."
    }

    Invoke-WebRequest -Uri "$RepoRaw/hermes_bridge.py" -OutFile $BridgeNew -UseBasicParsing
    if (-not (Test-BridgeArtifact $BridgeNew)) {
        throw "Bridge release integrity check failed (size, SHA-256, VERSION, UTF-8 or compilation)."
    }
    if (Test-Path -LiteralPath $BridgeTarget) {
        [IO.File]::Replace($BridgeNew, $BridgeTarget, $BridgeBackup, $true)
    } else {
        Move-Item -LiteralPath $BridgeNew -Destination $BridgeTarget
    }
    $script:BridgeChanged = $true
    Write-Audit "Mobile Bridge file" "OK" "Installed verified version $($manifest.version)"
    return [string]$manifest.version
}

function Write-PairingQr([string]$Python, [string]$Link) {
    & $Python -c "import qrcode" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Invoke-HiddenProcess $Python '-m pip install -q "qrcode[pil]"' 90 `
            (Join-Path $AuditDir "qrcode-install.out.log") `
            (Join-Path $AuditDir "qrcode-install.err.log")
    }
    $qrScript = Join-Path $AuditDir "make-pairing-qr.py"
    $qrSource = @'
import qrcode
import sys

link = sys.stdin.read()
if not link:
    raise SystemExit("empty pairing payload")
qrcode.make(link).save(sys.argv[1])
'@
    [IO.File]::WriteAllText($qrScript, $qrSource, $Utf8NoBom)
    try {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $Python
        $start.Arguments = "`"$qrScript`" `"$QrFile`""
        $start.WorkingDirectory = $HermesHome
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        if (-not $process.Start()) { throw "Python QR process did not start." }
        $process.StandardInput.Write($Link)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill() } catch {}
            throw "Pairing QR generation timed out."
        }
        $stderr = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $QrFile)) {
            throw "Pairing QR generation failed: $stderr"
        }
    } finally {
        Remove-Item -LiteralPath $qrScript -Force -ErrorAction SilentlyContinue
    }
    Write-Audit "Pairing QR" "OK" $QrFile
    return $QrFile
}

function Test-RunnerContract([string]$Path, [string[]]$RequiredFragments) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $content = [IO.File]::ReadAllText($Path)
    } catch {
        return $false
    }
    foreach ($fragment in $RequiredFragments) {
        if ($content.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
            return $false
        }
    }
    return $content -notmatch '(?i)powershell(?:\.exe)?\s+-.*-file'
}

function Invoke-SetupInventory {
    $missing = New-Object System.Collections.Generic.List[string]
    $hermes = Get-HermesExecutable
    if (-not $hermes) {
        [void]$missing.Add("Hermes Agent executable")
    } else {
        try {
            & $hermes --version *> $null
            if ($LASTEXITCODE -ne 0) { [void]$missing.Add("Healthy Hermes Agent executable") }
        } catch { [void]$missing.Add("Healthy Hermes Agent executable") }
    }

    $python = Get-HermesPython
    if (-not $python) {
        [void]$missing.Add("Hermes virtual-environment Python")
    } else {
        & $python -c "import aiohttp" *> $null
        if ($LASTEXITCODE -ne 0) { [void]$missing.Add("Python package aiohttp") }
        try {
            [void](Install-VerifiedBridge $python)
        } catch {
            [void]$missing.Add("Verified current Mobile Bridge file")
        } finally {
            Remove-Item -LiteralPath $BridgeNew, $ManifestFile -Force -ErrorAction SilentlyContinue
        }
    }

    $key = $null
    try { $key = Get-ApiKey } catch {}
    if (-not $key) { [void]$missing.Add("One strong API_SERVER_KEY entry") }

    $pairing = $null
    try { $pairing = Get-PairingConfiguration } catch {
        [void]$missing.Add("Tailscale/private-LAN address or configured HTTPS endpoint")
    }

    $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
    $runnerContracts = @(
        @{
            Task = "HermesConsole-Gateway"
            File = "hermes-gateway.vbs"
            Fragments = @("gateway run --replace", "API_SERVER_HOST", "sh.Run(command, 0, True)")
        },
        @{
            Task = "HermesConsole-Dashboard"
            File = "hermes-dashboard.vbs"
            Fragments = @("dashboard --host", "--no-open", "%ProgramFiles%\nodejs", "--skip-build", "sh.Run(command, 0, True)")
        },
        @{
            Task = "HermesConsole-MobileBridge"
            File = "hermes-bridge.vbs"
            Fragments = @("BRIDGE_TOKEN", "hermes_bridge.py", "--i-know-what-im-doing", "sh.Run(command, 0, True)")
        }
    )
    foreach ($contract in $runnerContracts) {
        $name = $contract.Task
        $runnerPath = Join-Path $ServicesDir $contract.File
        if (-not (Test-RunnerContract $runnerPath $contract.Fragments)) {
            [void]$missing.Add("Current windowless runner for $name")
        }
        $expectedArguments = "//B //NoLogo `"$runnerPath`""
        $persistent = $false
        try {
            Import-Module ScheduledTasks -ErrorAction Stop
            $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            $action = if ($task) { @($task.Actions)[0] } else { $null }
            $persistent = $task -and $task.Settings.Enabled -and
                $action.Execute -eq $wscript -and $action.Arguments -eq $expectedArguments
        } catch {}
        if (-not $persistent) {
            $startup = [Environment]::GetFolderPath("Startup")
            $shortcutPath = if ($startup) { Join-Path $startup "$name.lnk" } else { $null }
            if ($shortcutPath -and (Test-Path -LiteralPath $shortcutPath)) {
                try {
                    $shell = New-Object -ComObject WScript.Shell
                    $shortcut = $shell.CreateShortcut($shortcutPath)
                    $persistent = $shortcut.TargetPath -eq $wscript -and
                        $shortcut.Arguments -eq $expectedArguments
                } catch {}
            }
        }
        if (-not $persistent) { [void]$missing.Add("Exact per-user autostart for $name") }
    }

    foreach ($legacyName in @("Hermes Gateway", "Hermes Dashboard", "Hermes Mobile Bridge")) {
        $legacyFound = $false
        try {
            Import-Module ScheduledTasks -ErrorAction Stop
            $legacyFound = $null -ne (Get-ScheduledTask -TaskName $legacyName -ErrorAction SilentlyContinue)
        } catch {}
        $startup = [Environment]::GetFolderPath("Startup")
        if ($startup -and (Test-Path -LiteralPath (Join-Path $startup "$legacyName.lnk"))) {
            $legacyFound = $true
        }
        if ($legacyFound) { [void]$missing.Add("Remove legacy duplicate $legacyName") }
    }

    try {
        Import-Module ScheduledTasks -ErrorAction Stop
        $restartContracts = @(
            @{ Task = "HermesConsole-Restart-Dashboard"; File = "restart-hermes-dashboard.vbs" },
            @{ Task = "HermesConsole-Restart-MobileBridge"; File = "restart-hermes-bridge.vbs" }
        )
        foreach ($contract in $restartContracts) {
            $task = Get-ScheduledTask -TaskName $contract.Task -ErrorAction SilentlyContinue
            $action = if ($task) { @($task.Actions)[0] } else { $null }
            $runnerPath = Join-Path $ServicesDir $contract.File
            $expectedArguments = "//B //NoLogo `"$runnerPath`""
            if (-not $task -or -not $task.Settings.Enabled -or
                $action.Execute -ne $wscript -or $action.Arguments -ne $expectedArguments) {
                [void]$missing.Add("Exact allowlisted remote restart task $($contract.Task)")
            }
        }
    } catch {
        [void]$missing.Add("ScheduledTasks support for allowlisted remote restarts")
    }

    if ($key) {
        foreach ($service in @(
            @{ Kind = "gateway"; Url = "http://127.0.0.1:8642"; Port = 8642 },
            @{ Kind = "bridge"; Url = "http://127.0.0.1:9131"; Port = 9131 },
            @{ Kind = "dashboard"; Url = "http://127.0.0.1:9119"; Port = 9119 }
        )) {
            if (-not (Test-HermesService $service.Kind $service.Url $key)) {
                $owner = Get-PortOwner $service.Port
                $suffix = if ($owner) { " (port owned by PID $($owner.Pid) $($owner.Name))" } else { "" }
                [void]$missing.Add("Healthy/authenticated $($service.Kind) service$suffix")
            }
        }
        try {
            $credentials = Invoke-RestMethod -Method Get `
                -Uri "http://127.0.0.1:9131/bridge/dashboard/credentials" `
                -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 4
            if ($credentials.password_set -ne $true) {
                [void]$missing.Add("Dashboard password")
            }
        } catch { [void]$missing.Add("Readable Dashboard credential state through Mobile Bridge") }
    }

    if ($pairing) {
        if ($pairing.Scheme -eq "http") {
            $display = if ($pairing.Kind -eq "mesh") { "Hermes Console Tailscale" } else { "Hermes Console private network" }
            if (-not (Test-RestrictedFirewallRule $display $pairing.Kind)) {
                [void]$missing.Add("Restricted Windows Firewall rule")
            }
        }
        if ($key) {
            foreach ($service in @(
                @{ Kind = "gateway"; Url = $pairing.GatewayBase },
                @{ Kind = "bridge"; Url = $pairing.BridgeBase },
                @{ Kind = "dashboard"; Url = $pairing.DashboardBase }
            )) {
                if (-not (Test-HermesService $service.Kind $service.Url $key "" -PhoneFacing)) {
                    [void]$missing.Add("Phone-facing $($service.Kind) reachability")
                }
            }
        }
    }

    $dist = Join-Path $InstallDir "web\dist\index.html"
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node -and -not (Test-Path -LiteralPath "C:\Program Files\nodejs\node.exe") -and
        -not (Test-Path -LiteralPath $dist)) {
        [void]$missing.Add("Node.js in PATH or an already-built Dashboard")
    }
    $pairingRecordValid = $false
    if ($pairing -and (Test-Path -LiteralPath $PairingFile)) {
        try {
            $record = Get-Content -LiteralPath $PairingFile -Raw | ConvertFrom-Json
            $pairingRecordValid = $record.schema -eq 1 -and
                $record.host -eq $pairing.Address -and
                $record.gateway -eq $pairing.GatewayBase -and
                $record.dashboard -eq $pairing.DashboardBase -and
                $record.bridge -eq $pairing.BridgeBase -and
                $record.kind -eq $pairing.Kind
        } catch {}
    }
    if (-not $pairingRecordValid) { [void]$missing.Add("Verified current pairing record") }
    if (-not (Test-Path -LiteralPath $QrFile) -or (Get-Item -LiteralPath $QrFile).Length -le 0) {
        [void]$missing.Add("Non-empty pairing QR PNG")
    }

    foreach ($item in $missing) { Write-Audit "Inventory" "WARN" $item }
    if ($missing.Count -eq 0) { Write-Audit "Inventory" "OK" "Installation is ready for Hermes Console" }
    return [PSCustomObject]@{
        ready = $missing.Count -eq 0
        missing = @($missing)
        audit = $AuditLog
        qr = if (Test-Path -LiteralPath $QrFile) { $QrFile } else { $null }
    }
}

if ($AuditOnly) {
    Write-Audit "Setup" "INFO" "Audit-only mode; service files and tasks will not be modified"
    $inventory = Invoke-SetupInventory
    $inventory | ConvertTo-Json -Compress
    if (-not $inventory.ready) {
        throw "Audit found $($inventory.missing.Count) item(s) to repair. See $AuditLog."
    }
    return
}

try {
    Write-Audit "Setup" "INFO" "Repair/install mode"
    Write-SetupPhase "Inspecting the existing installation"
    Remove-LegacyTasks
    Write-SetupPhase "Checking Hermes Agent and Python"
    $HermesExe = Install-HermesIfNeeded
    $PythonExe = Get-HermesPython
    if (-not $PythonExe) { throw "Hermes virtual-environment Python was not found." }
    & $PythonExe -c "import aiohttp" *> $null
    if ($LASTEXITCODE -ne 0) { throw "Hermes Python does not provide aiohttp." }
    Write-Audit "Hermes Python" "OK" "Python and aiohttp are available"
    $ApiKey = Ensure-ApiKey
    $Pairing = Get-PairingConfiguration
    $HadBridgeTarget = Test-Path -LiteralPath $BridgeTarget
    Write-SetupPhase "Verifying the Mobile Bridge release"
    $BridgeVersion = Install-VerifiedBridge $PythonExe

    $gatewayRunnerContent = @'
Option Explicit
Dim sh, fso, home, exe, command, rc
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
home = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
sh.CurrentDirectory = home
sh.Environment("Process")("HERMES_HOME") = home
sh.Environment("Process")("API_SERVER_HOST") = "__BIND_HOST__"
sh.Environment("Process")("API_SERVER_PORT") = "8642"
exe = fso.BuildPath(home, "hermes-agent\venv\Scripts\hermes.exe")
command = Chr(34) & exe & Chr(34) & " gateway run --replace"
rc = sh.Run(command, 0, True)
WScript.Quit rc
'@
    $gatewayRunner = Write-ServiceRunner "hermes-gateway" ($gatewayRunnerContent.Replace("__BIND_HOST__", $Pairing.BindHost))
    $dashboardRunnerContent = @'
Option Explicit
Dim sh, fso, home, exe, dist, nodePath, command, rc
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
home = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
sh.CurrentDirectory = home
sh.Environment("Process")("HERMES_HOME") = home
nodePath = sh.ExpandEnvironmentStrings("%ProgramFiles%\nodejs")
If fso.FolderExists(nodePath) Then
  sh.Environment("Process")("PATH") = nodePath & ";" & sh.Environment("Process")("PATH")
End If
exe = fso.BuildPath(home, "hermes-agent\venv\Scripts\hermes.exe")
dist = fso.BuildPath(home, "hermes-agent\hermes_cli\web_dist\index.html")
command = Chr(34) & exe & Chr(34) & " dashboard --host __BIND_HOST__ --port 9119 --no-open"
If fso.FileExists(dist) Then command = command & " --skip-build"
rc = sh.Run(command, 0, True)
WScript.Quit rc
'@
    $dashboardRunner = Write-ServiceRunner "hermes-dashboard" ($dashboardRunnerContent.Replace("__BIND_HOST__", $Pairing.BindHost))
    $bridgeRunnerContent = @'
Option Explicit
Dim sh, fso, home, python, bridge, envFile, stream, line, token, command, rc
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
home = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))
sh.CurrentDirectory = home
sh.Environment("Process")("HERMES_HOME") = home
sh.Environment("Process")("BRIDGE_HERMES_HOME") = home
sh.Environment("Process")("BRIDGE_HOST") = "__BIND_HOST__"
sh.Environment("Process")("BRIDGE_PORT") = "9131"
sh.Environment("Process")("BRIDGE_SCOPES") = "read,memory,soul,skills,cron,config,command"
sh.Environment("Process")("BRIDGE_READ_ONLY") = "false"
envFile = fso.BuildPath(home, ".env")
token = ""
Set stream = fso.OpenTextFile(envFile, 1, False)
Do Until stream.AtEndOfStream
  line = Trim(stream.ReadLine)
  If Left(line, 15) = "API_SERVER_KEY=" Then token = Mid(line, 16)
Loop
stream.Close
If Len(token) = 0 Then WScript.Quit 2
sh.Environment("Process")("BRIDGE_TOKEN") = Replace(token, Chr(34), "")
python = fso.BuildPath(home, "hermes-agent\venv\Scripts\python.exe")
bridge = fso.BuildPath(home, "hermes_bridge.py")
command = Chr(34) & python & Chr(34) & " " & Chr(34) & bridge & Chr(34) & " --i-know-what-im-doing"
rc = sh.Run(command, 0, True)
WScript.Quit rc
'@
    $bridgeRunner = Write-ServiceRunner "hermes-bridge" ($bridgeRunnerContent.Replace("__BIND_HOST__", $Pairing.BindHost))
    $dashboardRestartRunner = Write-ServiceRunner "restart-hermes-dashboard" @'
Option Explicit
Dim sh, rc
Set sh = CreateObject("WScript.Shell")
WScript.Sleep 300
Call sh.Run("schtasks.exe /End /TN ""HermesConsole-Dashboard""", 0, True)
WScript.Sleep 500
rc = sh.Run("schtasks.exe /Run /TN ""HermesConsole-Dashboard""", 0, True)
WScript.Quit rc
'@
    $bridgeRestartRunner = Write-ServiceRunner "restart-hermes-bridge" @'
Option Explicit
Dim sh, rc
Set sh = CreateObject("WScript.Shell")
WScript.Sleep 500
Call sh.Run("schtasks.exe /End /TN ""HermesConsole-MobileBridge""", 0, True)
WScript.Sleep 500
rc = sh.Run("schtasks.exe /Run /TN ""HermesConsole-MobileBridge""", 0, True)
WScript.Quit rc
'@

    Write-SetupPhase "Installing hidden persistent services"
    $gatewayTask = Register-HermesTask "HermesConsole-Gateway" $gatewayRunner
    $dashboardTask = Register-HermesTask "HermesConsole-Dashboard" $dashboardRunner
    $bridgeTask = Register-HermesTask "HermesConsole-MobileBridge" $bridgeRunner
    if ($dashboardTask) {
        [void](Register-HermesManualTask "HermesConsole-Restart-Dashboard" $dashboardRestartRunner)
    }
    if ($bridgeTask) {
        [void](Register-HermesManualTask "HermesConsole-Restart-MobileBridge" $bridgeRestartRunner)
    }

    Write-SetupPhase "Checking Gateway, Dashboard and credentials"
    $gatewayChanged = [bool]$script:RunnerChanged["hermes-gateway"] -or
        [bool]$script:TaskDefinitionsChanged["HermesConsole-Gateway"]
    $bridgeChanged = $script:BridgeChanged -or [bool]$script:RunnerChanged["hermes-bridge"] -or
        [bool]$script:TaskDefinitionsChanged["HermesConsole-MobileBridge"]
    $gatewayHealthy = Test-HermesService "gateway" "http://127.0.0.1:8642" $ApiKey
    if (-not $gatewayHealthy -or ($gatewayTask -and $gatewayChanged)) {
        Start-HermesProcess "HermesConsole-Gateway" $gatewayRunner $gatewayTask 8642
    } else {
        Write-Audit "Gateway service" "SKIP" "Already healthy and authenticated"
    }
    if (-not (Wait-HermesService "gateway" "http://127.0.0.1:8642" $ApiKey 15)) {
        throw "Gateway readiness failed. Inspect its Scheduled Task and the owner of TCP 8642."
    }
    Write-Ok "Gateway identity and authentication passed on 8642"

    $bridgeHealthy = Test-HermesService "bridge" "http://127.0.0.1:9131" $ApiKey $BridgeVersion
    if (-not $bridgeHealthy -or ($bridgeTask -and $bridgeChanged)) {
        Start-HermesProcess "HermesConsole-MobileBridge" $bridgeRunner $bridgeTask 9131
    } else {
        Write-Audit "Mobile Bridge service" "SKIP" "Already healthy, authenticated and current"
    }
    if (-not (Wait-HermesService "bridge" "http://127.0.0.1:9131" $ApiKey 15 $BridgeVersion)) {
        if ($script:BridgeChanged -and (Test-Path -LiteralPath $BridgeBackup)) {
            Copy-Item -LiteralPath $BridgeBackup -Destination $BridgeTarget -Force
            Start-HermesProcess "HermesConsole-MobileBridge" $bridgeRunner $bridgeTask 9131
            [void](Wait-HermesService "bridge" "http://127.0.0.1:9131" $ApiKey 15)
            Write-Audit "Mobile Bridge rollback" "WARN" "Restored the previous verified file after readiness failed"
        } elseif (-not $HadBridgeTarget) {
            Remove-Item -LiteralPath $BridgeTarget -Force -ErrorAction SilentlyContinue
        }
        throw "Mobile Bridge did not pass health, auth and self-update checks. Inspect its Scheduled Task and TCP 9131."
    }
    Write-Ok "Mobile Bridge $BridgeVersion health, auth and self-update passed"

    $bridgeHeaders = @{ Authorization = "Bearer $ApiKey" }
    $currentCredentials = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:9131/bridge/dashboard/credentials" -Headers $bridgeHeaders -TimeoutSec 4
    if ($currentCredentials.ok -ne $true) {
        throw "Dashboard credential endpoint rejected the read."
    }
    if ($currentCredentials.password_set -ne $true) {
        $passwordBytes = New-Object byte[] 24
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($passwordBytes) } finally { $rng.Dispose() }
        $password = [Convert]::ToBase64String($passwordBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $username = if ($currentCredentials.username) { $currentCredentials.username } else { "admin" }
        $body = @{ username = $username; password = $password } | ConvertTo-Json -Compress
        $credentials = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:9131/bridge/dashboard/credentials" `
            -Headers $bridgeHeaders -ContentType "application/json" -Body $body -TimeoutSec 6
        if ($credentials.ok -ne $true) {
            throw "Dashboard credential endpoint rejected the configuration."
        }
        Write-Audit "Dashboard credentials" "OK" "Created through the authenticated Mobile Bridge"
    } else {
        Write-Audit "Dashboard credentials" "SKIP" "Existing password retained"
    }

    $dashboardHealthy = Test-HermesService "dashboard" "http://127.0.0.1:9119" $ApiKey
    $dashboardStarting = $dashboardTask -and
        (Test-HermesTaskRunning "HermesConsole-Dashboard")
    if (-not $dashboardHealthy -and -not $dashboardStarting) {
        Start-HermesProcess "HermesConsole-Dashboard" $dashboardRunner $dashboardTask 9119
    } elseif ($dashboardStarting -and -not $dashboardHealthy) {
        # A previous setup can have timed out while npm/Vite kept building in
        # the persistent task. Restarting here creates a second build and can
        # leave an orphan on 9119. Reuse the in-flight canonical task instead.
        Write-Audit "Dashboard service" "INFO" "Existing Dashboard startup/build is still running; waiting"
    } else {
        Write-Audit "Dashboard service" "SKIP" "Already healthy with its existing build"
    }
    # A first native-Windows launch may need npm install + the Vite build.
    # Hermes itself allows a long idle window for that work; do not fail the
    # setup after 25 seconds while the Scheduled Task is still building.
    if (-not (Wait-HermesService "dashboard" "http://127.0.0.1:9119" $ApiKey 240)) {
        throw "Dashboard readiness failed. Check Node.js/PATH, its Scheduled Task and TCP 9119."
    }
    Write-Ok "Dashboard identity and Gateway state passed on 9119"

    Write-SetupPhase "Verifying private phone access"
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

    Write-SetupPhase "Generating pairing QR and summary"
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
    $pairingJson = $pairingRecord | ConvertTo-Json -Compress
    if ((Test-Path -LiteralPath $PairingFile) -and
        [IO.File]::ReadAllText($PairingFile).Trim() -eq $pairingJson) {
        Write-Audit "Pairing record" "SKIP" "Existing verified endpoints retained"
    } else {
        $pairingNew = "$PairingFile.new"
        [IO.File]::WriteAllText($pairingNew, $pairingJson, $Utf8NoBom)
        Move-Item -LiteralPath $pairingNew -Destination $PairingFile -Force
        Write-Audit "Pairing record" "OK" "Verified endpoint metadata updated"
    }

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
    [void](Write-PairingQr $PythonExe $link)
    Write-Audit "Setup" "OK" "All local and phone-facing checks passed; pairing QR is ready"
    Write-Audit "Setup summary" "OK" "Hermes Agent, Gateway, Dashboard and Mobile Bridge are ready; private phone access passed"
    [PSCustomObject]@{
        ok = $true
        qr = $QrFile
        audit = $AuditLog
        pairing = $PairingFile
        summary = @(
            "Hermes Agent ready"
            "Gateway authenticated and reachable"
            "Dashboard ready"
            "Mobile Bridge $BridgeVersion authenticated and reachable"
            "Private phone access verified"
        )
    } | ConvertTo-Json -Compress
} catch {
    $safeError = Protect-AuditText $_.Exception.Message
    Write-Audit "Setup" "ERROR" $safeError
    [PSCustomObject]@{
        ok = $false
        error = $safeError
        audit = $AuditLog
    } | ConvertTo-Json -Compress
    throw $safeError
} finally {
    Remove-Item -LiteralPath $BridgeNew, $ManifestFile, "$PairingFile.new" -Force -ErrorAction SilentlyContinue
}
