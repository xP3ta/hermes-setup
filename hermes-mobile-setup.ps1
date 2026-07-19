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

function Test-Port([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync("127.0.0.1", $Port)
        return $task.Wait(700) -and $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Wait-Port([int]$Port, [int]$Seconds) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        if (Test-Port $Port) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
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

function Ensure-ApiKey {
    $key = Get-ApiKey
    if ($key) { return $key }
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $key = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    $existing = if (Test-Path -LiteralPath $EnvFile) {
        [IO.File]::ReadAllText($EnvFile)
    } else { "" }
    if ($existing -and -not $existing.EndsWith("`n")) { $existing += "`r`n" }
    [IO.File]::WriteAllText($EnvFile, "${existing}API_SERVER_KEY=$key`r`n", $Utf8NoBom)
    return $key
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
        $raw = ipconfig.exe 2>$null
        foreach ($line in $raw) {
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

function Ensure-PrivateFirewallRules {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        Write-Warn "Windows Firewall may block the phone. If it cannot connect, re-run PowerShell as Administrator to add private-network rules for TCP 8642, 9119 and 9131."
        return
    }
    try {
        Import-Module NetSecurity -ErrorAction Stop
        $display = "Hermes Console private network"
        Get-NetFirewallRule -DisplayName $display -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $display -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort 8642, 9119, 9131 -Profile Private | Out-Null
        Write-Ok "Private-network firewall rules installed"
    } catch {
        Write-Warn "Could not configure Windows Firewall: $($_.Exception.Message)"
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
    $BridgeVersion = Install-VerifiedBridge $PythonExe

    $gatewayRunner = Write-ServiceRunner "hermes-gateway" @'
$ErrorActionPreference = "Stop"
$HermesHome = Split-Path $PSScriptRoot -Parent
$env:HERMES_HOME = $HermesHome
$env:API_SERVER_HOST = "0.0.0.0"
$env:API_SERVER_PORT = "8642"
$exe = Join-Path $HermesHome "hermes-agent\venv\Scripts\hermes.exe"
$log = Join-Path $HermesHome "logs\gateway.log"
Set-Location $HermesHome
& $exe gateway run >> $log 2>&1
exit $LASTEXITCODE
'@
    $dashboardRunner = Write-ServiceRunner "hermes-dashboard" @'
$ErrorActionPreference = "Stop"
$HermesHome = Split-Path $PSScriptRoot -Parent
$env:HERMES_HOME = $HermesHome
$exe = Join-Path $HermesHome "hermes-agent\venv\Scripts\hermes.exe"
$log = Join-Path $HermesHome "logs\dashboard.log"
Set-Location $HermesHome
& $exe dashboard --host 0.0.0.0 --port 9119 --no-open >> $log 2>&1
exit $LASTEXITCODE
'@
    $bridgeRunner = Write-ServiceRunner "hermes-bridge" @'
$ErrorActionPreference = "Stop"
$HermesHome = Split-Path $PSScriptRoot -Parent
$env:HERMES_HOME = $HermesHome
$env:BRIDGE_HERMES_HOME = $HermesHome
$env:BRIDGE_HOST = "0.0.0.0"
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

    if (-not (Test-Port 8642)) {
        Start-HermesProcess "HermesConsole-Gateway" $gatewayRunner $gatewayTask
    }
    Start-HermesProcess "HermesConsole-MobileBridge" $bridgeRunner $bridgeTask
    if (-not (Wait-Port 9131 20)) {
        if (Test-Path -LiteralPath $BridgeBackup) {
            Copy-Item -LiteralPath $BridgeBackup -Destination $BridgeTarget -Force
            Start-HermesProcess "HermesConsole-MobileBridge" $bridgeRunner $bridgeTask
        }
        throw "Mobile Bridge did not start. Check $LogsDir and Task Scheduler."
    }
    Write-Ok "Mobile Bridge $BridgeVersion is listening on 9131"
    if (Wait-Port 8642 10) { Write-Ok "Gateway is listening on 8642" }
    else { Write-Warn "Gateway did not start; inspect the HermesConsole-Gateway task." }

    if (-not (Test-Port 9119)) {
        $passwordBytes = New-Object byte[] 16
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($passwordBytes) } finally { $rng.Dispose() }
        $password = ([BitConverter]::ToString($passwordBytes)).Replace('-', '').ToLowerInvariant()
        try {
            $body = @{ password = $password } | ConvertTo-Json -Compress
            Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:9131/bridge/dashboard/credentials" `
                -Headers @{ Authorization = "Bearer $ApiKey" } -ContentType "application/json" `
                -Body $body -TimeoutSec 15 | Out-Null
        } catch {
            Write-Warn "Dashboard credential endpoint returned: $($_.Exception.Message)"
        }
        Start-HermesProcess "HermesConsole-Dashboard" $dashboardRunner $dashboardTask
        [void](Wait-Port 9119 30)
    }

    Ensure-PrivateFirewallRules
    $hostInfo = Get-ReachableHost
    $dashboardPart = if (Test-Port 9119) { "&dashboard=http://$($hostInfo.Address):9119" } else { "" }
    $link = "hermes://pair?host=$($hostInfo.Address)&port=8642&token=$ApiKey$dashboardPart"
    Write-Host ""
    Write-Host "== SCAN THIS QR WITH HERMES CONSOLE (or copy the link) ==" -ForegroundColor Yellow
    Write-Host ""
    if (-not (Render-Qr $PythonExe $link)) {
        Write-Warn "A QR renderer could not be prepared. Paste the link shown below."
    }
    Write-Host ""
    Write-Host "Link: $link"
    Write-Host ""
    Write-Host "To show this QR again later in PowerShell:"
    Write-Host "  irm $RepoRaw/hermes-pair.ps1 | iex"
    if ($hostInfo.Public) {
        Write-Warn "The link uses public IP $($hostInfo.Address). Use a mesh VPN/private firewall; public HTTP is unsafe."
    }
    if ($hostInfo.Address -eq "127.0.0.1") {
        Write-Warn "No reachable network address was found; this link only works on this PC."
    }
} finally {
    Remove-Item -LiteralPath $BridgeNew, $ManifestFile -Force -ErrorAction SilentlyContinue
}
