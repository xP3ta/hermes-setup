# Hermes Console - Dashboard-only setup for native Windows (PowerShell 5.1+).
#
# A thin complement to the official Hermes installer (install.ps1). If Hermes
# is missing it runs the official installer and nothing else; if Hermes is there
# it never runs it. It does not touch the Gateway. It does the one thing the
# official installer leaves undone: it keeps the Dashboard on all the time, on
# one LAN or Tailscale address, behind sign-in, shows the generated password
# once and draws a QR code that Console scans to connect (Dashboard sign-in only).
#
#   -NewAccess               make a new Dashboard password and end old sessions
#   -PasswordStdin           take the password from the first line of standard
#                            input instead of generating one
#   -Remove                  stop the Dashboard and take its service away; the
#                            sign-in, Hermes and the Gateway are not touched
#   -RetireGatewayExposure   undo what the earlier Console setup added to the
#                            Gateway (its network address and port, its pairing
#                            record and its firewall ports); the API key is kept
#   -AlsoRemoveApiKey        with -RetireGatewayExposure only: also remove the key
#   -RetireBridge            stop and remove the old Mobile Bridge
#   -BindAddress, -Port      choose the address and port (or set
#                            HERMES_DASHBOARD_HOST / HERMES_DASHBOARD_PORT)
#   -Help                    print this summary
#
# Run it from a saved file (the password can then come from standard input):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\hermes-dashboard-setup.ps1
# or straight from the repository, like the official installer:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-dashboard-setup.ps1)))
#
# The file is plain ASCII with no byte-order mark on purpose: a mark breaks
# [scriptblock]::Create(...) (the official installer documents the same).

[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$NewAccess,
    [switch]$PasswordStdin,
    [switch]$RetireGatewayExposure,
    [switch]$AlsoRemoveApiKey,
    [switch]$RetireBridge,
    [switch]$Remove,
    [switch]$Help,
    [string]$BindAddress = "",
    [string]$Port = "",
    # Declared only to be refused: a password never travels on a command line.
    [string]$Password = $null,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Unexpected = @()
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# A typed [string] parameter turns $null into "", so "was it given" is asked of the binder.
$script:PasswordWasGiven = $PSBoundParameters.ContainsKey("Password")

$script:OfficialInstallUrl = "https://hermes-agent.nousresearch.com/install.ps1"
$script:OfficialInstallArguments = @("-NonInteractive", "-SkipBrowser", "-SkipComputerUse")
$script:TaskName = "HermesConsole-Dashboard"
$script:FirewallRuleName = "HermesConsole-Dashboard-Only"
$script:FirewallDisplayName = "Hermes Console Dashboard (private network)"
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Messages never stop a setup: a closed output (a window that went away) must not
# keep the rollback from running.
function Write-Say([string]$Message = "") { try { Write-Host $Message } catch { } }
function Write-Problem([string]$Message) { try { [Console]::Error.WriteLine($Message) } catch { } }
function Write-Step([string]$Message) { Write-Say ""; Write-Say "== $Message" }

function Show-Usage {
    Write-Say "Hermes Console - Dashboard-only setup for Windows"
    Write-Say ""
    Write-Say "Run it AFTER the official Hermes installer. It installs nothing: it keeps the"
    Write-Say "Hermes Dashboard on all the time, on one LAN or Tailscale address, behind a"
    Write-Say "password, and shows the generated password once. It does not touch the Gateway."
    Write-Say "It ends with a QR code for Console (nothing is installed to draw it)."
    Write-Say ""
    Write-Say "  (no option)               set up, or repair, the Dashboard. A sign-in that"
    Write-Say "                            already exists is kept as it is."
    Write-Say "  -NewAccess                make a new Dashboard password and end the sessions"
    Write-Say "                            of the old one."
    Write-Say "  -PasswordStdin            take the password from the first line of standard"
    Write-Say "                            input instead of generating one (run a saved file,"
    Write-Say "                            and pipe the password in)."
    Write-Say "  -BindAddress <address>    the one private LAN or Tailscale address to listen on"
    Write-Say "                            (or HERMES_DASHBOARD_HOST)."
    Write-Say "  -Port <port>              the TCP port (or HERMES_DASHBOARD_PORT), 9119 by default."
    Write-Say "  -Remove                   stop the Dashboard and take its service away. Your"
    Write-Say "                            Dashboard sign-in, Hermes and the Gateway are not touched."
    Write-Say "  -RetireGatewayExposure    undo what the earlier Console setup added to the"
    Write-Say "                            Gateway: its network address and port, its pairing"
    Write-Say "                            record and the firewall port it opened. Your API key"
    Write-Say "                            is kept. The Gateway is not stopped."
    Write-Say "  -AlsoRemoveApiKey         with -RetireGatewayExposure only: also remove the API"
    Write-Say "                            key from .env (a private copy is kept). Anything of"
    Write-Say "                            yours that uses the key stops working."
    Write-Say "  -RetireBridge             stop and remove the old Mobile Bridge. Nothing else"
    Write-Say "                            is touched."
    Write-Say "  -Help                     this summary."
    Write-Say ""
    Write-Say "A password is never taken from the command line."
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

# Returns the action to run, or throws a message that says what is wrong.
# Nothing has been touched when it throws.
function Get-RequestedAction {
    param(
        [bool]$NewAccess, [bool]$PasswordStdin, [bool]$RetireGatewayExposure,
        [bool]$AlsoRemoveApiKey, [bool]$RetireBridge, [bool]$Remove, [bool]$Help,
        [bool]$PasswordGiven, [int]$UnexpectedCount
    )
    if ($PasswordGiven) {
        throw ("A password is never taken from the command line (it would stay in your shell history). " +
            "Use -PasswordStdin to choose your own, or give none and one is generated.")
    }
    if ($UnexpectedCount -gt 0) {
        throw "Unexpected argument (its value is not shown). Run it with -Help to see what it can do."
    }
    $chosen = @()
    if ($NewAccess) { $chosen += "new-access" }
    if ($RetireGatewayExposure) { $chosen += "retire-gateway-exposure" }
    if ($RetireBridge) { $chosen += "retire-bridge" }
    if ($Remove) { $chosen += "remove" }
    if ($Help) { $chosen += "help" }
    if ($chosen.Count -gt 1) {
        throw ("Choose one action at a time: " + ($chosen -join ", ") + " were all given.")
    }
    $action = "setup"
    if ($chosen.Count -eq 1) { $action = $chosen[0] }
    if ($AlsoRemoveApiKey -and $action -ne "retire-gateway-exposure") {
        throw "-AlsoRemoveApiKey only goes with -RetireGatewayExposure."
    }
    if ($PasswordStdin -and $action -ne "setup" -and $action -ne "new-access") {
        throw "-PasswordStdin only goes with setup or -NewAccess."
    }
    return $action
}

function Get-BoundedPort([string]$Name, [string]$Value) {
    $parsed = 0
    if ($Value -notmatch '^[0-9]{1,5}$' -or -not [int]::TryParse($Value, [ref]$parsed) -or
        $parsed -lt 1 -or $parsed -gt 65535) {
        throw "$Name must be a TCP port between 1 and 65535. Nothing was changed."
    }
    return $parsed
}

# One private LAN, Tailscale (CGNAT) address. Never 0.0.0.0, loopback, link-local
# or a public address: the Dashboard is bound to exactly one address.
function Test-AllowedBindAddress([string]$Text) {
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Text, [ref]$ip)) { return $false }
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    if ($ip.ToString() -ne $Text) { return $false }
    $b = $ip.GetAddressBytes()
    if ($b[0] -eq 10) { return $true }
    if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $true }
    if ($b[0] -eq 192 -and $b[1] -eq 168) { return $true }
    if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $true }
    return $false
}

function Test-MeshAddress([string]$Text) {
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Text, [ref]$ip)) { return $false }
    $b = $ip.GetAddressBytes()
    return ($b.Length -eq 4 -and $b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)
}

# ---------------------------------------------------------------------------
# Hermes home
# ---------------------------------------------------------------------------

# Generated runners put these paths inside a Windows script and a command line;
# these characters cannot be carried safely, so they are refused, not rewritten.
function Test-UnsafePathText([string]$Text) {
    return ($Text -match '["%^&!|<>\x00-\x1f]')
}

function Test-ReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Resolve-HermesHome([string]$Candidate) {
    # Said before .NET gets to say it, in the .NET's own (localised) words.
    if (-not [string]::IsNullOrWhiteSpace($Candidate) -and (Test-UnsafePathText $Candidate)) {
        throw "HERMES_HOME contains unsupported characters."
    }
    if ([string]::IsNullOrWhiteSpace($Candidate) -or -not [IO.Path]::IsPathRooted($Candidate)) {
        throw "HERMES_HOME must be one absolute path."
    }
    try { $resolved = [IO.Path]::GetFullPath($Candidate) } catch { throw "HERMES_HOME is not a valid path." }
    $sep = @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $root = [IO.Path]::GetPathRoot($resolved)
    if (-not $root -or $resolved.TrimEnd($sep) -eq $root.TrimEnd($sep)) {
        throw "HERMES_HOME cannot be a filesystem root."
    }
    $resolved = $resolved.TrimEnd($sep)
    if (Test-UnsafePathText $resolved) { throw "HERMES_HOME contains unsupported characters." }
    if (Test-ReparsePoint $resolved) { throw "HERMES_HOME may not be a symbolic link or junction." }
    return $resolved
}

function Test-HermesHomeEvidence([string]$Path) {
    foreach ($name in @(".env", "hermes-agent", "console-services", "hermes_bridge.py")) {
        if (Test-Path -LiteralPath (Join-Path $Path $name)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# One setup at a time (the same lock hermes-mobile-setup.ps1 takes)
# ---------------------------------------------------------------------------

function Get-SetupLockName {
    $scope = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($scope))).Replace("-", "")
    } finally { $sha.Dispose() }
    return "Global\xPeta.HermesConsole.Setup.$digest"
}

function Enter-SetupLock {
    $mutex = New-Object Threading.Mutex($false, (Get-SetupLockName))
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    } catch { $mutex.Dispose(); throw }
    if (-not $acquired) {
        $mutex.Dispose()
        throw "Another Console setup is already running for this user; nothing was changed."
    }
    return $mutex
}

function Exit-SetupLock($Mutex) {
    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { }
    $Mutex.Dispose()
}

# ---------------------------------------------------------------------------
# Small system helpers
# ---------------------------------------------------------------------------

function Test-CurrentProcessAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Only the owner, SYSTEM and the administrators may read it (SIDs, so the
# Windows language does not matter).
function Set-PrivateAcl([string]$Path) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # (OI)(CI) is for folders: on a file it would leave the list of allowed users empty.
    $flags = ""
    if (Test-Path -LiteralPath $Path -PathType Container) { $flags = "(OI)(CI)" }
    & icacls.exe $Path /inheritance:r /grant:r "*${sid}:${flags}F" /grant:r "*S-1-5-18:${flags}F" /grant:r "*S-1-5-32-544:${flags}F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not restrict access to $Path." }
}

function New-PrivateDirectory([string]$Path) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Set-PrivateAcl $Path
}

function ConvertTo-WindowsArgument([string]$Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $text = New-Object Text.StringBuilder
    [void]$text.Append('"')
    $slashes = 0
    foreach ($c in $Value.ToCharArray()) {
        if ($c -eq [char]92) {
            $slashes++
        } elseif ($c -eq [char]34) {
            [void]$text.Append([char]92, ($slashes * 2 + 1))
            [void]$text.Append([char]34)
            $slashes = 0
        } else {
            if ($slashes -gt 0) { [void]$text.Append([char]92, $slashes); $slashes = 0 }
            [void]$text.Append($c)
        }
    }
    if ($slashes -gt 0) { [void]$text.Append([char]92, ($slashes * 2)) }
    [void]$text.Append('"')
    return $text.ToString()
}

# Runs one program with its own standard streams. Text for standard input goes
# in as UTF-8 bytes; it is never an argument and never an environment variable.
function Invoke-NativeProcess {
    param(
        [string]$FilePath, [string[]]$Arguments = @(), [string]$InputText = $null,
        [int]$TimeoutSeconds = 60, [hashtable]$Environment = @{}
    )
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join " ")
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::Start($psi)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    try {
        if ($null -ne $InputText) {
            $bytes = $script:Utf8NoBom.GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $process.StandardInput.BaseStream.Flush()
        }
    } catch { } finally { try { $process.StandardInput.Close() } catch { } }
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        & taskkill.exe /T /F /PID $process.Id 2>&1 | Out-Null
        return @{ Code = 124; Out = ""; Err = ""; TimedOut = $true }
    }
    $stdout = ""
    $stderr = ""
    if ($outTask.Wait(5000)) { $stdout = $outTask.Result }
    if ($errTask.Wait(5000)) { $stderr = $errTask.Result }
    return @{ Code = $process.ExitCode; Out = $stdout; Err = $stderr; TimedOut = $false }
}

# ---------------------------------------------------------------------------
# Hermes launcher and Python
# ---------------------------------------------------------------------------

# Hermes is looked for where its installers put it (scripts/desktop-update/
# runtime.ps1:51-53 and :72-86 in Hermes). A launcher only counts when it
# answers: a stale shim of a half-finished uninstall must not become a service.
# -SeenOnly only asks whether any launcher is there at all.
function Find-HermesLauncher([string]$HermesHome, [switch]$SeenOnly) {
    $installRoot = Join-Path $HermesHome "hermes-agent"
    $candidates = @(
        @{ Path = (Join-Path $installRoot ".hermes\bin\hermes.exe"); Check = $false },
        @{ Path = (Join-Path $installRoot "venv\Scripts\hermes.exe"); Check = $false },
        @{ Path = (Join-Path $HermesHome "bin\hermes.exe"); Check = $true }
    )
    if ($env:LOCALAPPDATA) {
        $candidates += @{ Path = (Join-Path $env:LOCALAPPDATA "hermes\bin\hermes.exe"); Check = $true }
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $found = $false
        foreach ($candidate in $candidates) {
            if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) { continue }
            $found = $true
            if ($SeenOnly) { return $candidate.Path }
            $probe = Invoke-NativeProcess $candidate.Path @("--version") -TimeoutSeconds 60
            if ($probe.Code -ne 0) { continue }
            if ($candidate.Check) {
                # A launcher outside the home counts only when it is bound to this home's install.
                if ($probe.Out -notmatch '(?m)^Install directory: (.+?)\r?$') { continue }
                $reported = [IO.Path]::GetFullPath($Matches[1].Trim()).TrimEnd('\', '/')
                $expected = [IO.Path]::GetFullPath($installRoot).TrimEnd('\', '/')
                if (-not [string]::Equals($reported, $expected, [StringComparison]::OrdinalIgnoreCase)) { continue }
            }
            return $candidate.Path
        }
        if (-not $found -or $attempt -eq 3) { break }
        Start-Sleep -Seconds ($attempt * 2)
    }
    return $null
}

# The official installer updates and repairs whatever it finds, so it runs only
# when there is no Hermes at all. It runs in a child PowerShell of its own, so an
# exit in it cannot end this setup, and its exit code is the answer.
function Install-Hermes {
    $file = Join-Path ([IO.Path]::GetTempPath()) ("hermes-install-" + [Guid]::NewGuid().ToString("N") + ".ps1")
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $script:OfficialInstallUrl -OutFile $file
        $shell = (Get-Process -Id $PID).Path
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $file) + $script:OfficialInstallArguments
        $run = Start-Process -FilePath $shell -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        return ($run.ExitCode -eq 0)
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

# Hermes publishes the command that starts its own libraries
# (hermes --print-runtime-command, hermes_cli/_launchers.py). That command ends by
# running a module; this one stops before that and runs a file instead, after the
# same preparation (isolated mode, install on the path, bootstrap).
function Get-HermesPythonCommand([string]$Launcher) {
    $reply = Invoke-NativeProcess $Launcher @("--print-runtime-command") -TimeoutSeconds 120
    if ($reply.Code -ne 0) { throw "Hermes would not say how to run its Python ($Launcher --print-runtime-command)." }
    # Windows PowerShell 5.1 hands a JSON array over as one item; PowerShell 7 as many.
    $command = @()
    foreach ($item in @($reply.Out | ConvertFrom-Json)) { $command += $item }
    if ($command.Count -lt 4 -or $command[1] -ne "-I" -or $command[2] -ne "-c") {
        throw "Hermes answered with a runtime command this setup does not know."
    }
    $python = [string]$command[0]
    $code = [string]$command[3]
    $cut = $code.LastIndexOf("runpy.run_module(")
    if ($cut -lt 0) { throw "Hermes answered with a runtime command this setup does not know." }
    $head = $code.Substring(0, $cut).TrimEnd().TrimEnd(";")
    $driver = "import sys`n_p = sys.argv[1]`nsys.argv = sys.argv[1:]`n" +
        "exec(compile(open(_p, encoding='utf-8').read(), _p, 'exec'), {'__name__': '__main__'})"
    return @{ Python = $python; Code = ($head + "`n" + $driver) }
}

function Invoke-HermesPython {
    param($PythonCommand, [string]$HermesHome, [string]$ScriptPath, [string[]]$ScriptArguments = @(),
        [string]$InputText = $null, [int]$TimeoutSeconds = 300)
    $arguments = @("-I", "-c", $PythonCommand.Code, $ScriptPath) + $ScriptArguments
    $result = Invoke-NativeProcess $PythonCommand.Python $arguments -InputText $InputText `
        -TimeoutSeconds $TimeoutSeconds -Environment @{ HERMES_HOME = $HermesHome }
    if ($result.Err) { try { [Console]::Error.Write($result.Err) } catch { } }
    return $result
}

# ---------------------------------------------------------------------------
# The address the Dashboard listens on
# ---------------------------------------------------------------------------

function Get-LocalIPv4Candidates {
    $skip = "vEthernet|WSL|Hyper-V|VMware|VirtualBox|Loopback|Bluetooth|Docker|Npcap|TAP-|Teredo|isatap"
    $found = @()
    foreach ($entry in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        $address = [string]$entry.IPAddress
        if ($address -like "127.*" -or $address -like "169.254.*") { continue }
        if ([string]$entry.AddressState -ne "Preferred") { continue }
        $adapter = Get-NetAdapter -InterfaceIndex $entry.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $adapter -or [string]$adapter.Status -ne "Up") { continue }
        if (([string]$adapter.InterfaceDescription) -match $skip -or ([string]$entry.InterfaceAlias) -match $skip) { continue }
        $found += [pscustomobject]@{ Address = $address; InterfaceIndex = [int]$entry.InterfaceIndex }
    }
    return $found
}

# Tailscale first, then another mesh (CGNAT) address, then a private LAN address.
function Select-BindAddress([string]$Chosen) {
    $local = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    if ($Chosen) {
        if (-not (Test-AllowedBindAddress $Chosen)) {
            throw ("The address must be one private LAN or Tailscale IPv4 address " +
                "(not 0.0.0.0, loopback, link-local or a public one). Nothing was changed.")
        }
        $mine = @($local | Where-Object { [string]$_.IPAddress -eq $Chosen })
        if ($mine.Count -eq 0) {
            throw "The address $Chosen is not assigned to this computer, so nothing can listen on it. Nothing was changed."
        }
        $kind = "lan"
        if (Test-MeshAddress $Chosen) { $kind = "mesh" }
        return @{ Address = $Chosen; Kind = $kind; InterfaceIndex = [int]$mine[0].InterfaceIndex; Described = "chosen" }
    }
    $candidates = @(Get-LocalIPv4Candidates)
    $mesh = @($candidates | Where-Object { Test-MeshAddress $_.Address })
    if ($mesh.Count -gt 0) {
        return @{ Address = $mesh[0].Address; Kind = "mesh"; InterfaceIndex = $mesh[0].InterfaceIndex; Described = "mesh" }
    }
    $lan = @($candidates | Where-Object { (Test-AllowedBindAddress $_.Address) -and -not (Test-MeshAddress $_.Address) })
    if ($lan.Count -gt 0) {
        # The interface that has the default gateway is the one the phone reaches.
        $gateway = @(Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric | ForEach-Object { [int]$_.InterfaceIndex })
        foreach ($index in $gateway) {
            $hit = @($lan | Where-Object { $_.InterfaceIndex -eq $index })
            if ($hit.Count -gt 0) {
                return @{ Address = $hit[0].Address; Kind = "lan"; InterfaceIndex = $hit[0].InterfaceIndex; Described = "lan" }
            }
        }
        return @{ Address = $lan[0].Address; Kind = "lan"; InterfaceIndex = $lan[0].InterfaceIndex; Described = "lan" }
    }
    throw ("No LAN or Tailscale address was found, so there is nothing safe to listen on. " +
        "Connect Tailscale or join the LAN, or choose one with -BindAddress. Nothing was changed.")
}

# ---------------------------------------------------------------------------
# Windows Firewall: one rule of our own, for the chosen address and port only
# ---------------------------------------------------------------------------

function Get-RuleFields([string]$Name) {
    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if (-not $rule) { return $null }
    $ports = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule
    $addresses = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule
    $applications = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule
    return @{
        Enabled = ([string]$rule.Enabled -eq "True"); Direction = [string]$rule.Direction;
        Action = [string]$rule.Action; Profile = [string]$rule.Profile;
        Protocol = [string]$ports.Protocol; LocalPort = (@($ports.LocalPort) -join ",");
        LocalAddress = (@($addresses.LocalAddress) -join ","); RemoteAddress = (@($addresses.RemoteAddress) -join ",");
        Program = [string]$applications.Program
    }
}

function Get-WantedRuleFields($Bind, [int]$PortNumber) {
    $profile = "Private"
    $remote = "LocalSubnet"
    if ($Bind.Kind -eq "mesh") { $profile = "Any"; $remote = "100.64.0.0/10" }
    return @{
        Enabled = $true; Direction = "Inbound"; Action = "Allow"; Profile = $profile; Protocol = "TCP";
        LocalPort = "$PortNumber"; LocalAddress = [string]$Bind.Address; RemoteAddress = $remote; Program = "Any"
    }
}

function Test-RuleMatches($Have, $Want) {
    if (-not $Have) { return $false }
    foreach ($key in $Want.Keys) {
        if ([string]$Have[$key] -ne [string]$Want[$key]) { return $false }
    }
    return $true
}

function New-DashboardRule($Fields) {
    $parameters = @{
        Name = $script:FirewallRuleName; DisplayName = $script:FirewallDisplayName
        Direction = "Inbound"; Action = "Allow"; Protocol = "TCP"
        LocalPort = $Fields.LocalPort; LocalAddress = $Fields.LocalAddress
        RemoteAddress = $Fields.RemoteAddress; Profile = $Fields.Profile
    }
    New-NetFirewallRule @parameters -ErrorAction Stop | Out-Null
}

# Another rule of someone else that already lets this port in from any address.
function Get-BroaderPortRules([int]$PortNumber) {
    $broader = @()
    foreach ($rule in @(Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue)) {
        if ($rule.Name -eq $script:FirewallRuleName) { continue }
        $ports = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
        if (-not $ports) { continue }
        if (@($ports.Protocol) -notcontains "TCP") { continue }
        if (@($ports.LocalPort | ForEach-Object { [string]$_ }) -notcontains "$PortNumber") { continue }
        $addresses = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
        if ($addresses -and (@($addresses.LocalAddress) -contains "Any")) { $broader += $rule.DisplayName }
    }
    return $broader
}

# ---------------------------------------------------------------------------
# The Dashboard service: a Scheduled Task that starts with the computer
# ---------------------------------------------------------------------------

# The runner starts the Dashboard again, five seconds after it stops with an error
# (the address may not be up yet when the computer starts): the same promise as
# Restart=on-failure of the Linux service. Task Scheduler's own restart setting
# did not bring a failed task back in the lab, so it is not relied on.
function New-DashboardRunnerText {
    param([string]$HermesHome, [string]$Launcher, [string]$BindAddress, [int]$PortNumber, [string]$LogPath, [bool]$SkipBuild)
    $extra = ""
    if ($SkipBuild) { $extra = " --skip-build" }
    $lines = @(
        "Option Explicit",
        "Dim sh, fso, q, command, rc, nodePath",
        "Set sh = CreateObject(""WScript.Shell"")",
        "Set fso = CreateObject(""Scripting.FileSystemObject"")",
        "q = Chr(34)",
        "sh.CurrentDirectory = ""$HermesHome""",
        "sh.Environment(""Process"")(""HERMES_HOME"") = ""$HermesHome""",
        "nodePath = sh.ExpandEnvironmentStrings(""%ProgramFiles%\nodejs"")",
        "If fso.FolderExists(nodePath) Then",
        "  sh.Environment(""Process"")(""PATH"") = nodePath & "";"" & sh.Environment(""Process"")(""PATH"")",
        "End If",
        "command = ""cmd.exe /d /c "" & q & q & ""$Launcher"" & q & "" dashboard --host $BindAddress --port $PortNumber --no-open$extra >> "" & q & ""$LogPath"" & q & "" 2>&1"" & q",
        "Do",
        "  rc = sh.Run(command, 0, True)",
        "  If rc = 0 Then Exit Do",
        "  WScript.Sleep 5000",
        "Loop",
        "WScript.Quit rc"
    )
    return (($lines -join "`r`n") + "`r`n")
}

# Windows Script Host reads UTF-16LE reliably only with its byte-order mark.
function Write-RunnerFile([string]$Path, [string]$Text) {
    $encoding = New-Object Text.UnicodeEncoding($false, $true)
    $bytes = [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($Text))
    $temp = "$Path.new"
    [IO.File]::WriteAllBytes($temp, $bytes)
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-DashboardTask {
    return (Get-ScheduledTask -TaskName $script:TaskName -TaskPath "\" -ErrorAction SilentlyContinue)
}

# The task is ours when it runs this home's own runner through wscript.
function Test-DashboardTaskOwned($Task, [string]$Runner) {
    $action = @($Task.Actions)[0]
    $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
    return ($action -and [string]::Equals([string]$action.Execute, $wscript, [StringComparison]::OrdinalIgnoreCase) -and
        ([string]$action.Arguments).IndexOf($Runner, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Register-DashboardTask([string]$HermesHome, [string]$Runner) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
    $action = New-ScheduledTaskAction -Execute $wscript -Argument "//B //NoLogo `"$Runner`"" -WorkingDirectory $HermesHome
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
    $mode = "boot"
    try {
        # At startup, without being signed in and without a stored password: only an
        # administrator can ask for it.
        if (-not (Test-CurrentProcessAdministrator)) { throw "not elevated" }
        $triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn -User $user))
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
        Register-ScheduledTask -TaskName $script:TaskName -TaskPath "\" -Action $action -Trigger $triggers `
            -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
    } catch {
        $mode = "logon"
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $script:TaskName -TaskPath "\" -Action $action `
            -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
            -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
    }
    return $mode
}

# Everything below a process (its children, theirs, and so on).
function Get-DescendantProcessIds([int[]]$RootIds) {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($root in $RootIds) { [void]$set.Add([int]$root) }
    do {
        $added = $false
        foreach ($process in $all) {
            if ($set.Contains([int]$process.ParentProcessId) -and -not $set.Contains([int]$process.ProcessId)) {
                [void]$set.Add([int]$process.ProcessId)
                $added = $true
            }
        }
    } while ($added)
    return @($set)
}

# The processes of the Dashboard this home's runner started: what runs below its
# wscript, plus any Dashboard of this home on this port that nothing owns any more
# (left by a run that was killed).
function Get-OwnDashboardProcessIds([string]$HermesHome, [int]$PortNumber, [string]$Runner) {
    $ids = New-Object System.Collections.Generic.List[int]
    $roots = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq "wscript.exe" -and $_.CommandLine -and
        ([string]$_.CommandLine).IndexOf($Runner, [StringComparison]::OrdinalIgnoreCase) -ge 0
    } | ForEach-Object { [int]$_.ProcessId })
    foreach ($id in $roots) { if (-not $ids.Contains($id)) { $ids.Add($id) } }
    if ($roots.Count -gt 0) {
        foreach ($id in (Get-DescendantProcessIds $roots)) { if (-not $ids.Contains([int]$id)) { $ids.Add([int]$id) } }
    }
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $line = [string]$process.CommandLine
        if (-not $line -or $line.IndexOf($HermesHome, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($line -match '\sdashboard\s+--host\s+\S+\s+--port\s+(\d+)\b' -and [int]$Matches[1] -eq $PortNumber) {
            if (-not $ids.Contains([int]$process.ProcessId)) { $ids.Add([int]$process.ProcessId) }
        }
    }
    return @($ids)
}

function Get-PortListener([int]$PortNumber) {
    return @(Get-NetTCPConnection -LocalPort $PortNumber -State Listen -ErrorAction SilentlyContinue)
}

# True when whatever listens on the port is the Dashboard of this home's runner.
function Test-PortHeldByOwnDashboard([string]$HermesHome, [int]$PortNumber, [string]$Runner) {
    $listeners = @(Get-PortListener $PortNumber)
    if ($listeners.Count -eq 0) { return $true }
    $own = @(Get-OwnDashboardProcessIds $HermesHome $PortNumber $Runner)
    foreach ($listener in $listeners) {
        if ($own -notcontains [int]$listener.OwningProcess) { return $false }
    }
    return $true
}

# Stopping the task ends only its own process: the Dashboard that runner started
# (cmd, hermes, python) would go on holding the port. So the runner's wscript goes
# first (it would start the Dashboard again), then everything below it, then the task.
function Stop-DashboardTask([string]$HermesHome, [int]$PortNumber, [string]$Runner) {
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        foreach ($id in (Get-OwnDashboardProcessIds $HermesHome $PortNumber $Runner)) {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        }
        if (Get-DashboardTask) { Stop-ScheduledTask -TaskName $script:TaskName -TaskPath "\" -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
        $task = Get-DashboardTask
        $running = ($task -and [string]$task.State -eq "Running")
        if (-not $running -and @(Get-OwnDashboardProcessIds $HermesHome $PortNumber $Runner).Count -eq 0) { return $true }
    }
    return $false
}

function Show-PortOwner([int]$PortNumber) {
    foreach ($listener in (Get-PortListener $PortNumber | Select-Object -First 3)) {
        $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        $name = "unknown"
        if ($process) { $name = $process.ProcessName }
        Write-Problem ("  {0}:{1} held by process {2} ({3})" -f $listener.LocalAddress, $listener.LocalPort, $listener.OwningProcess, $name)
    }
}

# ---------------------------------------------------------------------------
# What the Dashboard must answer, checked at the address it listens on
# ---------------------------------------------------------------------------

function Invoke-HttpRequest {
    param([string]$Url, [string]$Method = "GET", [hashtable]$Headers = @{}, [string]$Body = $null)
    $last = $null
    for ($try = 0; $try -lt 4; $try++) {
        try {
            $request = [Net.HttpWebRequest]::Create($Url)
            $request.Method = $Method
            $request.Proxy = $null
            $request.AllowAutoRedirect = $false
            $request.Timeout = 8000
            $request.ReadWriteTimeout = 8000
            if (-not $Headers.ContainsKey("Cookie")) { $request.CookieContainer = New-Object Net.CookieContainer }
            $request.Accept = "application/json"
            foreach ($key in $Headers.Keys) {
                if ($key -eq "Content-Type") { $request.ContentType = [string]$Headers[$key] }
                else { $request.Headers[[string]$key] = [string]$Headers[$key] }
            }
            if (-not [string]::IsNullOrEmpty($Body)) {
                $bytes = $script:Utf8NoBom.GetBytes($Body)
                $request.ContentLength = $bytes.Length
                $stream = $request.GetRequestStream()
                try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            }
            $response = $null
            try { $response = [Net.HttpWebResponse]$request.GetResponse() }
            catch [Net.WebException] {
                if (-not $_.Exception.Response) { throw }
                $response = [Net.HttpWebResponse]$_.Exception.Response
            }
            try {
                $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
                $text = $reader.ReadToEnd()
                $cookies = @()
                foreach ($cookie in $response.Cookies) { $cookies += ("{0}={1}" -f $cookie.Name, $cookie.Value) }
                return @{ Status = [int]$response.StatusCode; Body = $text; Cookies = $cookies }
            } finally { $response.Close() }
        } catch {
            $last = $_.Exception
            Start-Sleep -Seconds 1
        }
    }
    throw ("{0} is unreachable ({1}: {2})" -f $Url, $last.GetType().Name, $last.Message)
}

function ConvertFrom-JsonObject([string]$Text, [string]$What) {
    try { $value = $Text | ConvertFrom-Json } catch { throw "$What did not return JSON" }
    if ($null -eq $value -or $value -isnot [pscustomobject]) { throw "$What returned the wrong JSON shape" }
    return $value
}

# Mode "alive": the status page answers. "refuse": and whoever is not signed in is
# turned away. "login": and, as well, a real sign-in with the given password opens
# a protected page. Returns 0 when it all holds, 10 when the sign-in was refused,
# 1 otherwise (the reason is written).
function Test-DashboardAnswers {
    param([string]$Base, [string]$Mode, [string]$UserName = "", [string]$PasswordText = "", [switch]$Quiet)
    $protected = "/api/model/options"
    try {
        $status = Invoke-HttpRequest ($Base + "/api/status")
        if ($status.Status -ne 200) { throw "/api/status returned HTTP $($status.Status)" }
        [void](ConvertFrom-JsonObject $status.Body "/api/status")
        if ($Mode -eq "alive") { return 0 }
        foreach ($case in @(@("missing", $null), @("invalid", "hermes_session_at=invalid"))) {
            $headers = @{}
            if ($case[1]) { $headers["Cookie"] = $case[1] }
            $answer = Invoke-HttpRequest ($Base + $protected) -Headers $headers
            if ($answer.Status -ne 401 -and $answer.Status -ne 403) {
                throw ("the Dashboard did not refuse a {0} session (HTTP {1})" -f $case[0], $answer.Status)
            }
        }
        if ($Mode -ne "login") { return 0 }
        $body = (@{ provider = "basic"; username = $UserName; password = $PasswordText } | ConvertTo-Json -Compress)
        $login = Invoke-HttpRequest ($Base + "/auth/password-login") -Method "POST" `
            -Headers @{ "Content-Type" = "application/json" } -Body $body
        if ($login.Status -in 400, 401, 403) { return 10 }
        if ($login.Status -ne 200) { throw "password login returned HTTP $($login.Status)" }
        if (-not @($login.Cookies | Where-Object { ($_ -split "=", 2)[0].EndsWith("hermes_session_at") })) {
            throw "password login did not return an access-session cookie"
        }
        $page = Invoke-HttpRequest ($Base + $protected) -Headers @{ "Cookie" = ($login.Cookies -join "; ") }
        if ($page.Status -ne 200) { throw "the signed-in protected page returned HTTP $($page.Status)" }
        [void](ConvertFrom-JsonObject $page.Body "the signed-in protected page")
        return 0
    } catch {
        if (-not $Quiet) { Write-Problem ("  " + $_.Exception.Message) }
        return 1
    }
}

# ---------------------------------------------------------------------------
# Dashboard sign-in, through Hermes' own configuration API
# ---------------------------------------------------------------------------
# These are the same calls `hermes dashboard` makes when it asks for a password
# (hermes_cli/main_dashboard.py:608-720): the .env is loaded the way
# hermes_cli/main.py:714 loads it, the plugins are discovered, and a sign-in is
# only made when no provider is registered. A sign-in that exists is left alone.

$script:AuthSource = @'
import json, os, pathlib, secrets, sys

action, home, state_path, previous_path, from_stdin, password_out = sys.argv[1:]
os.environ["HERMES_HOME"] = home
password_given = sys.stdin.buffer.readline().decode("utf-8").rstrip("\r\n") if from_stdin == "1" else ""
if from_stdin == "1" and not password_given.strip():
    raise SystemExit("the password is empty")


def say(state, user=""):
    pathlib.Path(state_path).write_text("STATE=%s\nUSER=%s\n" % (state, user), encoding="utf-8")


def pinned_names():
    names = {}
    try:
        from hermes_cli.env_loader import load_hermes_dotenv
        # Only the .env is read. Sources outside it (a secret manager Hermes is
        # set up to use) are not asked: a setup script must not run those helpers
        # (hermes_cli/env_loader.py:488-493 resolves them). A sign-in kept only
        # there is not seen; the final message says so.
        load_hermes_dotenv(hermes_home=home, load_external_secrets=False)
        for key in ("USERNAME", "PASSWORD", "PASSWORD_HASH"):
            names[key] = os.environ.get("HERMES_DASHBOARD_BASIC_AUTH_" + key, "").strip()
        names["OAUTH"] = os.environ.get("HERMES_DASHBOARD_OAUTH_CLIENT_ID", "").strip()
    except Exception:
        path = pathlib.Path(home) / ".env"
        if path.exists():
            for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
                line = raw.strip()
                if line.startswith("export "):
                    line = line[len("export "):].lstrip()
                if "=" not in line:
                    continue
                name, value = line.split("=", 1)
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                for key in ("USERNAME", "PASSWORD", "PASSWORD_HASH"):
                    if name.strip() == "HERMES_DASHBOARD_BASIC_AUTH_" + key:
                        names[key] = value.strip()
                if name.strip() == "HERMES_DASHBOARD_OAUTH_CLIENT_ID":
                    names["OAUTH"] = value.strip()
    return names


from hermes_cli.config import load_config, save_config

env = pinned_names()
cfg = load_config()
if not isinstance(cfg.get("dashboard"), dict):
    cfg["dashboard"] = {}
if not isinstance(cfg["dashboard"].get("basic_auth"), dict):
    cfg["dashboard"]["basic_auth"] = {}
basic = cfg["dashboard"]["basic_auth"]
oauth_cfg = cfg["dashboard"].get("oauth")
oauth_cfg = oauth_cfg if isinstance(oauth_cfg, dict) else {}

providers = None
try:
    from hermes_cli.plugins import discover_plugins
    from hermes_cli.dashboard_auth import list_providers
    discover_plugins(force=True)
    providers = [str(getattr(item, "name", "")) for item in list_providers()]
except Exception:
    providers = None
if providers is None:
    # An older Hermes without the registry: decide from what its providers read.
    providers = []
    config_user = str(basic.get("username") or "").strip()
    if (env.get("USERNAME") or config_user) and (
        env.get("PASSWORD") or env.get("PASSWORD_HASH") or basic.get("password_hash") or basic.get("password")
    ):
        providers.append("basic")
    if env.get("OAUTH") or str(oauth_cfg.get("client_id") or "").strip():
        providers.append("oauth")

pinned = bool(env.get("PASSWORD") or env.get("PASSWORD_HASH"))
other = [name for name in providers if name != "basic"]
# A password sign-in that is written down but not registered: Hermes parks the
# bundled plugin in plugins.disabled in that case (hermes_cli/plugins_cmd.py:531-537).
configured = bool(
    (env.get("USERNAME") or str(basic.get("username") or "").strip())
    and (env.get("PASSWORD") or env.get("PASSWORD_HASH") or basic.get("password_hash") or basic.get("password"))
)


def disabled_plugins():
    plugins = cfg.get("plugins")
    value = plugins.get("disabled") if isinstance(plugins, dict) else None
    return list(value) if isinstance(value, list) else []


def enable_basic_plugin():
    """Take the bundled basic plugin out of plugins.disabled; returns the names
    that were taken out, so a rolled-back run can park them there again."""
    before = disabled_plugins()
    try:
        from hermes_cli.plugins_cmd import ensure_basic_auth_plugin_enabled_in_config
        if ensure_basic_auth_plugin_enabled_in_config(cfg):
            sys.stderr.write("Re-enabled the bundled 'basic' auth plugin (it was in plugins.disabled)\n")
    except ImportError:
        pass
    after = disabled_plugins()
    return [name for name in before if name not in after]


def remember(basic_before, reenabled):
    pathlib.Path(previous_path).write_text(
        json.dumps({"basic": basic_before, "reenabled": reenabled}), encoding="utf-8")
    os.chmod(previous_path, 0o600)


if action == "new-access":
    if pinned:
        say("pinned", env.get("USERNAME", ""))
        raise SystemExit(0)
    if other:
        say("other")
        raise SystemExit(0)
else:
    if providers:
        say("existing", str(basic.get("username") or env.get("USERNAME") or ""))
        raise SystemExit(0)
    if configured:
        # The user's own sign-in is there and only parked: switch the plugin back
        # on and change nothing else; a new password would replace their hash.
        reenabled = enable_basic_plugin()
        if reenabled:
            remember({}, reenabled)
            save_config(cfg)
        say("pinned" if pinned else "existing", str(basic.get("username") or env.get("USERNAME") or ""))
        raise SystemExit(0)

from plugins.dashboard_auth.basic import hash_password

previous = {key: basic.get(key) for key in ("username", "password_hash", "password", "secret")}


def new_password():
    # Four groups of five from 32 symbols (no 0, o, 1, l): 100 bits a person can read out and type.
    letters = "abcdefghijkmnpqrstuvwxyz23456789"
    return "-".join("".join(secrets.choice(letters) for _ in range(5)) for _ in range(4))


password = password_given or new_password()
username = str(basic.get("username") or "").strip() or env.get("USERNAME") or "admin"
basic["username"] = username
basic["password_hash"] = hash_password(password)
basic["password"] = ""  # never persist the plaintext
# --new-access also ends the sessions opened with the old sign-in.
if action == "new-access" or not str(basic.get("secret") or "").strip():
    basic["secret"] = secrets.token_urlsafe(32)
remember(previous, enable_basic_plugin())
save_config(cfg)
say("created", username)
if not password_given:
    # Into the private file the caller made, not onto standard output, where any
    # line Hermes prints while it loads would be taken for part of the password.
    pathlib.Path(password_out).write_text(password, encoding="utf-8")
'@

$script:RestoreSource = @'
import json, pathlib, sys

from hermes_cli.config import load_config, save_config

previous = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
cfg = load_config()
if not isinstance(cfg.get("dashboard"), dict):
    cfg["dashboard"] = {}
if not isinstance(cfg["dashboard"].get("basic_auth"), dict):
    cfg["dashboard"]["basic_auth"] = {}
basic = cfg["dashboard"]["basic_auth"]
for key, value in (previous.get("basic") or {}).items():
    if value is None:
        basic.pop(key, None)
    else:
        basic[key] = value
# A plugin this run took out of plugins.disabled goes back in.
parked = [name for name in (previous.get("reenabled") or []) if isinstance(name, str)]
if parked:
    if not isinstance(cfg.get("plugins"), dict):
        cfg["plugins"] = {}
    disabled = cfg["plugins"].get("disabled")
    if not isinstance(disabled, list):
        disabled = cfg["plugins"]["disabled"] = []
    for name in parked:
        if name not in disabled:
            disabled.append(name)
save_config(cfg)
'@

function Read-PasswordFromStdin {
    if (-not [Console]::IsInputRedirected) {
        throw ("-PasswordStdin needs the password piped in, from a saved file: " +
            "'my password' | powershell -NoProfile -ExecutionPolicy Bypass -File .\hermes-dashboard-setup.ps1 -PasswordStdin. " +
            "Nothing was changed.")
    }
    $stream = [Console]::OpenStandardInput()
    $bytes = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1
    while ($stream.Read($one, 0, 1) -eq 1) {
        if ($one[0] -eq 10) { break }
        $bytes.Add($one[0])
    }
    $text = $script:Utf8NoBom.GetString($bytes.ToArray()).TrimStart([char]0xFEFF).TrimEnd("`r")
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "The password on standard input is empty. Nothing was changed."
    }
    return $text
}

function Read-StateFile([string]$Path) {
    $state = @{ STATE = ""; USER = "" }
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if ($line -match '^(STATE|USER)=(.*)$') { $state[$Matches[1]] = $Matches[2] }
        }
    }
    return $state
}

# ---------------------------------------------------------------------------
# Undo, when a setup stops half-way
# ---------------------------------------------------------------------------

$script:Txn = $null
$script:KeepWork = $false

function Undo-DashboardSetup {
    $t = $script:Txn
    if (-not $t -or -not $t.Pending) { return }
    $t.Pending = $false
    $failed = $false
    # The sign-in settings go back to what they were (and a plugin this run took
    # out of plugins.disabled goes back in).
    if ($t.AccessTouched -and (Test-Path -LiteralPath $t.PreviousPath)) {
        try {
            $restore = Join-Path $t.Work "restore.py"
            [IO.File]::WriteAllText($restore, $script:RestoreSource, $script:Utf8NoBom)
            $answer = Invoke-HermesPython $t.Python $t.HermesHome $restore @($t.PreviousPath)
            if ($answer.Code -ne 0) { $failed = $true }
        } catch { $failed = $true }
    }
    if ($t.TaskTouched) {
        try {
            if (-not (Stop-DashboardTask $t.HermesHome $t.Port $t.RunnerPath)) { $failed = $true }
            if ($t.HadRunner) {
                [IO.File]::WriteAllBytes($t.RunnerPath, $t.PreviousRunner)
            } elseif (Test-Path -LiteralPath $t.RunnerPath) {
                Remove-Item -LiteralPath $t.RunnerPath -Force
            }
            if ($t.HadTask) {
                Register-ScheduledTask -TaskName $script:TaskName -TaskPath "\" -Xml $t.PreviousTaskXml -Force -ErrorAction Stop | Out-Null
                if ($t.PreviousTaskRunning) { Start-ScheduledTask -TaskName $script:TaskName -TaskPath "\" }
            } elseif (Get-DashboardTask) {
                Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath "\" -Confirm:$false -ErrorAction Stop
            }
        } catch { $failed = $true }
    } elseif ($t.RunnerTouched) {
        try {
            if ($t.HadRunner) { [IO.File]::WriteAllBytes($t.RunnerPath, $t.PreviousRunner) }
            elseif (Test-Path -LiteralPath $t.RunnerPath) { Remove-Item -LiteralPath $t.RunnerPath -Force }
        } catch { $failed = $true }
    }
    if ($t.RuleTouched) {
        try {
            if (Get-NetFirewallRule -Name $script:FirewallRuleName -ErrorAction SilentlyContinue) {
                Remove-NetFirewallRule -Name $script:FirewallRuleName -ErrorAction Stop
            }
            if ($t.PreviousRule) { New-DashboardRule $t.PreviousRule }
        } catch { $failed = $true }
    }
    if ($failed) {
        $script:KeepWork = $true
        Write-Problem "CRITICAL: the rollback was incomplete; recovery data was kept in $($t.Work)"
    }
}

function Show-DashboardFailure([string]$Base, [int]$PortNumber, [string]$LogPath) {
    Write-Problem "ERROR: the Dashboard did not pass its checks at $Base."
    if ((Get-PortListener $PortNumber).Count -gt 0) {
        Write-Problem "TCP $PortNumber is occupied, but not by a healthy Hermes Dashboard:"
        Show-PortOwner $PortNumber
        Write-Problem "The setup did not stop that process."
    } else {
        Write-Problem "Nothing is listening on TCP $PortNumber."
    }
    $task = Get-DashboardTask
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $script:TaskName -TaskPath "\" -ErrorAction SilentlyContinue
        Write-Problem ("Scheduled Task {0}: state {1}, last result {2}" -f $script:TaskName, $task.State, $info.LastTaskResult)
    }
    if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 0) {
        Write-Problem "Last lines of ${LogPath}:"
        Get-Content -LiteralPath $LogPath -Tail 15 -Encoding UTF8 | ForEach-Object { Write-Problem ("  " + $_) }
    } else {
        Write-Problem "$LogPath is empty: the Dashboard never wrote a line."
    }
}

# The QR Console scans: hermes://pair with v=2, url, user and, when this run made
# the password, pass. Only the Dashboard sign-in goes in; no Gateway key, host or
# port is read or written. The password reaches the builder and the drawer on
# standard input: never on a command line, never in a file, and the picture is
# not written to a file either: it comes back as text and goes to this window
# once. Drawing uses what is there, in this order, and leaves nothing behind:
# qrencode, the Python of Hermes if it has qrcode, a throwaway uv environment.
function Invoke-QrDrawer([string]$Program, [string[]]$DrawerArguments, [string]$Link) {
    try {
        $result = Invoke-NativeProcess $Program $DrawerArguments -InputText $Link -TimeoutSeconds 120
        if ($result.Code -eq 0 -and $result.Out.Trim()) { return $result.Out.TrimEnd() }
    } catch { }
    return ""
}

function Get-QrDrawing([string]$Link, [string]$PythonPath, [string]$HermesHome) {
    $drawer = 'import sys, qrcode' + "`n" + 'sys.stdout.reconfigure(encoding="utf-8")' + "`n" +
        'q = qrcode.QRCode(border=1)' + "`n" + 'q.add_data(sys.stdin.read())' + "`n" + 'q.make()' + "`n" +
        'q.print_ascii(invert=True)'
    $qrencode = Get-Command qrencode -ErrorAction SilentlyContinue
    if ($qrencode) {
        $art = Invoke-QrDrawer $qrencode.Source @("-t", "ANSIUTF8", "-l", "M") $Link
        if ($art) { return $art }
    }
    if ((Invoke-NativeProcess $PythonPath @("-I", "-c", "import qrcode")).Code -eq 0) {
        $art = Invoke-QrDrawer $PythonPath @("-I", "-c", $drawer) $Link
        if ($art) { return $art }
    }
    $uv = Join-Path $HermesHome "bin\uv.exe"
    if (-not (Test-Path -LiteralPath $uv)) {
        $found = Get-Command uv -ErrorAction SilentlyContinue
        $uv = ""
        if ($found) { $uv = $found.Source }
    }
    if ($uv) {
        return (Invoke-QrDrawer $uv @("run", "--isolated", "--no-project", "--no-cache", "--python", $PythonPath,
            "--with", "qrcode==8.2", "python", "-c", $drawer) $Link)
    }
    return ""
}

function Show-PairingCode {
    param([string]$Base, [string]$UserName, [string]$CodePassword, $Python, [string]$HermesHome)
    $builder = 'import sys, urllib.parse as u' + "`n" +
        'url, user, secret = (sys.stdin.buffer.readline().decode("utf-8").rstrip("\r\n") for _ in range(3))' + "`n" +
        'pairs = [("v", "2"), ("url", url), ("user", user)] + ([("pass", secret)] if secret else [])' + "`n" +
        'print("hermes://pair?" + u.urlencode(pairs, quote_via=u.quote, safe=""))'
    $art = ""
    try {
        $made = Invoke-NativeProcess $Python.Python @("-I", "-c", $builder) `
            -InputText ($Base + "`n" + $UserName + "`n" + $CodePassword + "`n")
        $link = ""
        if ($made.Code -eq 0) { $link = $made.Out.Trim() }
        if ($link) { $art = Get-QrDrawing $link $Python.Python $HermesHome }
    } catch { $art = "" }
    Write-Say ""
    if (-not $art) {
        if ($CodePassword) {
            Write-Say "I could not draw the code here; type these three details in Console."
        } else {
            Write-Say "I could not draw the code here; type the address and the user in Console, then the password."
        }
        return
    }
    $before = $null
    try { $before = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    Write-Say "== SCAN THIS CODE WITH CONSOLE =="
    Write-Say ""
    Write-Say $art
    Write-Say ""
    if ($CodePassword) {
        Write-Say "Scan it from Console. It carries the password: keep it off photos and shared screens."
        Write-Say "It is drawn here once and is not saved."
    } else {
        Write-Say "Scan it from Console: it carries the address and the user; Console asks for the password once."
    }
    try { if ($before) { [Console]::OutputEncoding = $before } } catch { }
}

# ---------------------------------------------------------------------------
# Setup and -NewAccess
# ---------------------------------------------------------------------------

function Invoke-DashboardSetup {
    param([string]$Action, [bool]$FromStdin, [string]$ChosenAddress, [string]$ChosenPort, [string]$HermesHome)

    $services = Join-Path $HermesHome "console-services"
    $logs = Join-Path $HermesHome "logs"
    $logPath = Join-Path $logs "dashboard.log"
    $runner = Join-Path $services "hermes-dashboard.vbs"
    foreach ($managed in @($services, $logs)) {
        if (Test-ReparsePoint $managed) { throw "Managed directory $managed is a symbolic link; refusing setup." }
    }

    $givenPassword = $null
    if ($FromStdin) { $givenPassword = Read-PasswordFromStdin }

    $portText = $ChosenPort
    if (-not $portText) { $portText = $env:HERMES_DASHBOARD_PORT }
    if (-not $portText) { $portText = "9119" }
    $portNumber = Get-BoundedPort "The port (-Port or HERMES_DASHBOARD_PORT)" $portText
    $addressText = $ChosenAddress
    if (-not $addressText) { $addressText = $env:HERMES_DASHBOARD_HOST }

    Write-Step "Looking at this computer"
    $launcher = Find-HermesLauncher $HermesHome
    if (-not $launcher) {
        if (Find-HermesLauncher $HermesHome -SeenOnly) {
            Write-Problem "Hermes is installed under $HermesHome but does not answer. The official installer would repair or"
            Write-Problem "update it, so it was not run. Repair Hermes first, then run this again. Nothing was changed."
            return 1
        }
        $elsewhere = Get-Command hermes -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($elsewhere) {
            Write-Problem "Hermes is at $($elsewhere.Source), outside its standard place ($HermesHome). Installing it again would"
            Write-Problem "make two copies, so nothing was run. Nothing was changed."
            return 1
        }
        Write-Say "Hermes Agent is not installed on this computer: running its official installer."
        $installed = Install-Hermes
        $launcher = Find-HermesLauncher $HermesHome
        if (-not $installed -or -not $launcher) {
            Write-Problem "The official Hermes installation did not finish. This setup changed nothing."
            return 1
        }
    }
    $python = Get-HermesPythonCommand $launcher

    $work = Join-Path ([IO.Path]::GetTempPath()) ("hermes-dashboard-setup-" + [Guid]::NewGuid().ToString("N"))
    New-PrivateDirectory $work
    try {
        $checkPath = Join-Path $work "check.py"
        [IO.File]::WriteAllText($checkPath, "import hermes_cli.config, plugins.dashboard_auth.basic`n", $script:Utf8NoBom)
        $check = Invoke-HermesPython $python $HermesHome $checkPath -TimeoutSeconds 120
        if ($check.Code -ne 0) {
            throw "Hermes cannot run its own configuration code; repair the Hermes installation first."
        }

        $bind = Select-BindAddress $addressText
        if ($bind.Kind -eq "lan") {
            $profile = Get-NetConnectionProfile -InterfaceIndex $bind.InterfaceIndex -ErrorAction SilentlyContinue
            if ($profile -and [string]$profile.NetworkCategory -ne "Private") {
                throw ("The network of $($bind.Address) is marked '$($profile.NetworkCategory)'. Mark it Private " +
                    "(Windows Settings, Network) or use Tailscale. Nothing was changed.")
            }
        }
        $base = "http://$($bind.Address):$portNumber"
        Write-Say "Dashboard address: $($bind.Address):$portNumber ($($bind.Kind))"

        Write-Step "Checking the Dashboard port"
        $task = Get-DashboardTask
        if ($task -and -not (Test-DashboardTaskOwned $task $runner)) {
            throw ("A Scheduled Task named $script:TaskName exists but does not run this home's Dashboard runner " +
                "($runner). Nothing was changed.")
        }
        $active = ($task -and [string]$task.State -eq "Running")
        if (-not (Test-PortHeldByOwnDashboard $HermesHome $portNumber $runner)) {
            Write-Problem "ERROR: TCP $portNumber is occupied by something that is not this Dashboard service:"
            Show-PortOwner $portNumber
            Write-Problem "Nothing was changed. Free the port, or choose another with -Port."
            return 1
        }

        $t = @{
            Pending = $true; Work = $work; HermesHome = $HermesHome; Python = $python; Port = $portNumber
            PreviousPath = (Join-Path $work "dashboard-access.previous.json")
            RunnerPath = $runner; HadRunner = (Test-Path -LiteralPath $runner); PreviousRunner = $null
            HadTask = [bool]$task; PreviousTaskXml = $null; PreviousTaskRunning = $active
            AccessTouched = $false; RunnerTouched = $false; TaskTouched = $false; RuleTouched = $false; PreviousRule = $null
        }
        if ($t.HadRunner) { $t.PreviousRunner = [IO.File]::ReadAllBytes($runner) }
        if ($task) { $t.PreviousTaskXml = (Export-ScheduledTask -TaskName $script:TaskName -TaskPath "\") }
        $script:Txn = $t

        Write-Step "Setting up Dashboard sign-in"
        $statePath = Join-Path $work "state"
        $passwordFile = Join-Path $work "new-password"
        [IO.File]::WriteAllText($passwordFile, "", $script:Utf8NoBom)
        $authPath = Join-Path $work "auth.py"
        [IO.File]::WriteAllText($authPath, $script:AuthSource, $script:Utf8NoBom)
        $flag = "0"
        $stdinText = $null
        if ($FromStdin) { $flag = "1"; $stdinText = $givenPassword + "`n" }
        $t.AccessTouched = $true
        $answer = Invoke-HermesPython $python $HermesHome $authPath `
            @($Action, $HermesHome, $statePath, $t.PreviousPath, $flag, $passwordFile) -InputText $stdinText
        $newPassword = ""
        if (Test-Path -LiteralPath $passwordFile) {
            $newPassword = [IO.File]::ReadAllText($passwordFile, $script:Utf8NoBom).TrimEnd("`r", "`n")
            Remove-Item -LiteralPath $passwordFile -Force
        }
        if ($answer.Code -ne 0) {
            throw "Hermes would not accept the sign-in settings (its answer is above). Nothing was kept."
        }
        $login = Read-StateFile $statePath
        if (@("created", "existing", "pinned", "other") -notcontains $login.STATE) {
            throw "Could not tell whether the Dashboard already has a sign-in."
        }
        switch ($login.STATE) {
            "created"  { Write-Say "Dashboard sign-in: a new one was made" }
            "existing" { Write-Say "Dashboard sign-in: yours was kept as it is" }
            "pinned"   { Write-Say "Dashboard sign-in: written in $HermesHome\.env, kept as it is" }
            "other"    { Write-Say "Dashboard sign-in: another provider is configured, kept as it is" }
        }

        Write-Step "Writing the Dashboard service"
        New-Item -ItemType Directory -Force -Path $services, $logs | Out-Null
        $skipBuild = Test-Path -LiteralPath (Join-Path $HermesHome "hermes-agent\hermes_cli\web_dist\index.html")
        $runnerText = New-DashboardRunnerText -HermesHome $HermesHome -Launcher $launcher `
            -BindAddress $bind.Address -PortNumber $portNumber -LogPath $logPath -SkipBuild $skipBuild
        $t.RunnerTouched = $true
        Write-RunnerFile $runner $runnerText

        # The firewall first, so Windows never asks "allow this app?" at the moment
        # the Dashboard starts listening.
        $want = Get-WantedRuleFields $bind $portNumber
        $have = Get-RuleFields $script:FirewallRuleName
        $firewall = "kept"
        if (Test-RuleMatches $have $want) {
            Write-Say "Windows Firewall rule: already as wanted"
        } elseif (Test-CurrentProcessAdministrator) {
            $t.RuleTouched = $true
            $t.PreviousRule = $have
            if ($have) { Remove-NetFirewallRule -Name $script:FirewallRuleName -ErrorAction Stop }
            New-DashboardRule $want
            $firewall = "created"
            Write-Say "Windows Firewall rule: $($want.LocalAddress) port $($want.LocalPort), profile $($want.Profile), from $($want.RemoteAddress) only"
        } else {
            $firewall = "needs-administrator"
            Write-Say "Windows Firewall: not changed (this window is not elevated)."
        }

        Write-Step "Starting the Dashboard in the background"
        Write-Say "The first start can take a few minutes: Hermes builds its web pages once."
        $t.TaskTouched = $true
        if ($task) { [void](Stop-DashboardTask $HermesHome $portNumber $runner) }
        $mode = Register-DashboardTask $HermesHome $runner
        Start-ScheduledTask -TaskName $script:TaskName -TaskPath "\"

        # The first start of a freshly built Hermes on a cold computer can compile
        # the web UI and take minutes; a warm restart answers at once. The wait goes
        # on while the log keeps growing (real progress), up to 30 minutes.
        $startWait = 240
        $parsedWait = 0
        if ($env:HERMES_SETUP_START_WAIT -and [int]::TryParse($env:HERMES_SETUP_START_WAIT, [ref]$parsedWait) -and $parsedWait -ge 0) {
            $startWait = $parsedWait
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $ready = $false
        $lastSize = 0
        $nextNote = 60
        while ($clock.Elapsed.TotalSeconds -lt 1800) {
            if ((Test-DashboardAnswers -Base $base -Mode "alive" -Quiet) -eq 0) { $ready = $true; break }
            Start-Sleep -Seconds 1
            if ($clock.Elapsed.TotalSeconds -lt $startWait) { continue }
            $size = 0
            if (Test-Path -LiteralPath $logPath) { $size = (Get-Item -LiteralPath $logPath).Length }
            if ($size -le $lastSize) { break }
            $lastSize = $size
            if ($clock.Elapsed.TotalSeconds -ge $nextNote) {
                Write-Say ("Dashboard still starting ({0}s): its log keeps growing; waiting up to 1800s" -f [int]$clock.Elapsed.TotalSeconds)
                $nextNote += 60
            }
        }
        if (-not $ready) {
            Show-DashboardFailure $base $portNumber $logPath
            throw "The Dashboard did not start."
        }

        Write-Step "Checking the Dashboard like the app will"
        $verified = 0
        $codePassword = ""
        if ($login.STATE -eq "created") {
            $secret = $newPassword
            if (-not $secret) { $secret = $givenPassword }
            $codePassword = $secret
            $verified = Test-DashboardAnswers -Base $base -Mode "login" -UserName $login.USER -PasswordText $secret
        } else {
            $verified = Test-DashboardAnswers -Base $base -Mode "refuse"
        }
        if ($verified -ne 0) {
            if ($verified -eq 10) { throw "The Dashboard did not accept the sign-in this setup just made." }
            throw "The Dashboard is running but failed its checks."
        }
        $accepts = ""
        if ($login.STATE -eq "created") { $accepts = " and accepts the new sign-in" }
        Write-Say "Dashboard answers at $base, refuses whoever is not signed in$accepts"

        # Done: nothing to take back any more.
        $t.Pending = $false
        $script:Txn = $null
        $stale = Join-Path $services "dashboard-login.json"
        if ($login.STATE -eq "created" -and (Test-Path -LiteralPath $stale)) {
            Remove-Item -LiteralPath $stale -Force
        }

        Write-Say ""
        Write-Say "== DASHBOARD READY =="
        Write-Say ""
        if ($login.STATE -eq "other") {
            Write-Say "Address: $base"
        } else {
            Write-Say "To connect Console to this computer you need:"
            Write-Say "  address:  $base"
            Write-Say "  user:     $($login.USER)"
        }
        switch ($login.STATE) {
            "created" {
                Write-Say ""
                if ($newPassword) {
                    Write-Say "  password: $newPassword"
                    Write-Say ""
                    Write-Say "In Console: Type an address -> paste these three details."
                    Write-Say "This password is shown now, once, and is not saved anywhere in clear."
                } else {
                    Write-Say "Your password is the one you gave on standard input (not shown, not saved in clear)."
                    Write-Say "In Console: Type an address -> paste the address and the user, then type your password."
                }
                Write-Say "Forgot it later? Run this again with -NewAccess to make a new one."
            }
            "existing" {
                Write-Say ""
                Write-Say "This computer already had a sign-in, which is kept as it is. Its password is only"
                Write-Say "stored scrambled, so this setup cannot show it: use the one you already have."
                Write-Say "In Console: Type an address -> paste the address and the user, then type that password."
                Write-Say "Forgot it? Run this again with -NewAccess: it makes a new password and signs out"
                Write-Say "everything that used the old one (the browser too)."
            }
            "pinned" {
                Write-Say ""
                Write-Say "The password is the one written in your .env. No new sign-in was made and that file"
                Write-Say "was not changed. A sign-in kept only in an external secret source (a secret manager)"
                Write-Say "is not seen by this setup."
                Write-Say "In Console: Type an address -> paste the address and the user, then type that password."
            }
            "other" {
                Write-Say ""
                Write-Say "Another sign-in provider is configured for this Dashboard, so this setup made no"
                Write-Say "sign-in and changed no configuration. Use that provider's sign-in in Console."
            }
        }
        if ($login.STATE -ne "other" -and $login.USER) {
            Show-PairingCode -Base $base -UserName $login.USER -CodePassword $codePassword -Python $python -HermesHome $HermesHome
        }
        $codePassword = ""
        if (Test-Path -LiteralPath (Join-Path $services "dashboard-login.json")) {
            Write-Say ""
            Write-Say "WARNING: $services\dashboard-login.json still holds the Dashboard password"
            Write-Say "in clear, written by an earlier Console setup. This run did not touch it;"
            Write-Say "delete it yourself if you do not want the password stored."
        }
        if ($mode -eq "boot") {
            Write-Say "Starts by itself at restart: yes (Scheduled Task $script:TaskName, at startup)"
        } else {
            Write-Say "Starts by itself at restart: only after you sign in to Windows. Run this again"
            Write-Say "from an elevated (administrator) PowerShell to start it with the computer."
        }
        Write-Say "Address: $($bind.Address) ($($bind.Kind)); only this address listens."
        if ($bind.Kind -eq "mesh") {
            Write-Say "Only devices signed in to your Tailscale can reach it: the phone needs Tailscale too."
        } else {
            Write-Say "The phone must be on this same network. Reserve this address for the computer in your"
            Write-Say "router, or run this setup again if it changes: the Windows Firewall rule is made for it."
        }
        if ($firewall -eq "needs-administrator") {
            Write-Say ""
            Write-Say "If the app cannot connect, allow the port from an elevated PowerShell (this window is not):"
            Write-Say ("  New-NetFirewallRule -Name {0} -DisplayName '{1}' -Direction Inbound -Action Allow -Protocol TCP -LocalPort {2} -LocalAddress {3} -RemoteAddress {4} -Profile {5}" -f `
                $script:FirewallRuleName, $script:FirewallDisplayName, $want.LocalPort, $want.LocalAddress, $want.RemoteAddress, $want.Profile)
        }
        foreach ($other in @(Get-BroaderPortRules $portNumber)) {
            Write-Say ""
            Write-Say "NOTE: the Windows Firewall rule '$other' (not made by this setup, left as it is)"
            Write-Say "also lets TCP $portNumber in on every address of this computer."
        }
        Write-Say "Keep the password private: whoever has it can use your Hermes."

        # What the earlier Console setup (Console 1.2) left is reported, never removed
        # here: a phone still on Console 1.2 would stop working.
        $oldGateway = (Test-GatewayExposurePresent $HermesHome)
        $oldBridge = (Test-BridgeLeftoversPresent $HermesHome)
        if ($oldGateway -or $oldBridge) {
            Write-Say ""
            Write-Say "Left over from the earlier Console setup (Console 1.2):"
            if ($oldGateway) {
                Write-Say "  - The Gateway is still reachable over the network. To undo that, run this setup again with -RetireGatewayExposure"
            }
            if ($oldBridge) {
                Write-Say "  - The old Mobile Bridge is still installed. To remove it, run this setup again with -RetireBridge"
            }
            Write-Say "Nothing was changed: Console 1.2 needs them. Do it when every phone uses Console 1.3."
        }
        return 0
    } catch {
        Write-Problem "ERROR: $($_.Exception.Message)"
        Undo-DashboardSetup
        return 1
    } finally {
        if ($script:Txn -and $script:Txn.Pending) { Undo-DashboardSetup }
        # A rollback that was incomplete keeps its recovery data (Undo-DashboardSetup says where).
        if (-not $script:KeepWork -and (Test-Path -LiteralPath $work)) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:Txn = $null
    }
}

# ---------------------------------------------------------------------------
# -Remove: the Dashboard service and nothing else
# ---------------------------------------------------------------------------
# Stops the Dashboard, then takes away its Scheduled Task, its runner and its own
# firewall rule. The sign-in stays in config.yaml; Hermes and the Gateway are not
# touched. Safe to repeat.
function Invoke-RemoveDashboard([string]$HermesHome) {
    $runner = Join-Path (Join-Path $HermesHome "console-services") "hermes-dashboard.vbs"
    $task = Get-DashboardTask
    if ($task -and -not (Test-DashboardTaskOwned $task $runner)) {
        throw ("A Scheduled Task named $script:TaskName exists but does not run this home's Dashboard runner " +
            "($runner). Nothing was changed.")
    }
    $hadRunner = Test-Path -LiteralPath $runner
    $rule = Get-NetFirewallRule -Name $script:FirewallRuleName -ErrorAction SilentlyContinue
    if (-not $task -and -not $hadRunner -and -not $rule) {
        Write-Say "Nothing to remove: this computer has no Dashboard service from this setup."
        return 0
    }
    Write-Step "Removing the Dashboard service"
    $portNumber = 9119
    if ($hadRunner) {
        $found = [regex]::Match([IO.File]::ReadAllText($runner, [Text.Encoding]::Unicode), '--port (\d{1,5})')
        if ($found.Success) { $portNumber = [int]$found.Groups[1].Value }
    }
    if (-not (Stop-DashboardTask $HermesHome $portNumber $runner)) {
        throw "The Dashboard could not be stopped, so nothing was deleted."
    }
    if (Get-DashboardTask) { Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath "\" -Confirm:$false -ErrorAction Stop }
    if ($hadRunner) { Remove-Item -LiteralPath $runner -Force }
    if ($rule) {
        if (Test-CurrentProcessAdministrator) {
            Remove-NetFirewallRule -Name $script:FirewallRuleName -ErrorAction Stop
        } else {
            Write-Say "The Windows Firewall rule was left (this window is not elevated). From an elevated PowerShell:"
            Write-Say "  Remove-NetFirewallRule -Name $script:FirewallRuleName"
        }
    }
    Write-Say "The Dashboard was stopped and its service removed."
    Write-Say "Kept as it was: your Hermes, the Gateway and the Dashboard sign-in"
    Write-Say "(dashboard.basic_auth in $HermesHome\config.yaml). To remove the sign-in too, delete"
    Write-Say "that block from config.yaml. Run this setup again, without -Remove, to bring the Dashboard back."
    return 0
}

# ---------------------------------------------------------------------------
# -RetireGatewayExposure
# ---------------------------------------------------------------------------
# Undo what hermes-mobile-setup.ps1 added to the Gateway, and nothing else:
#   - the API_SERVER_HOST / API_SERVER_PORT it set in console-services\hermes-gateway.vbs,
#   - its pairing record (pairing.json and the code pictures next to it),
#   - the Gateway's port in the Windows Firewall rules it made.
# The API_SERVER_KEY line in .env is KEPT. The earlier setup reuses a strong key
# that was already there (hermes-mobile-setup.ps1 Get-ApiKey / Ensure-ApiKey), so
# the line can belong to Open WebUI, a cron provider or another client of the
# user. Without a usable key Hermes does not start its API server at all
# (gateway/config_env.py:306-310, gateway/config.py:566) and external cron
# providers, which fire over loopback HTTP into it, fail every time
# (gateway/run.py:5672-5688). What exposed the Gateway was the address and port;
# without them the API server binds its default, this computer only
# (gateway/platforms/api_server.py:216,227). Only the explicit option
# -AlsoRemoveApiKey takes the key out, and it says what that costs.
# The Gateway is not stopped or restarted, and its Scheduled Task is not touched.
#region retire-gateway-exposure

function Read-TextFile([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $encoding = $script:Utf8NoBom
    $preamble = [byte[]]@()
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object Text.UnicodeEncoding($false, $true); $preamble = [byte[]]@(0xFF, 0xFE)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object Text.UnicodeEncoding($true, $true); $preamble = [byte[]]@(0xFE, 0xFF)
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $preamble = [byte[]]@(0xEF, 0xBB, 0xBF)
    }
    $text = $encoding.GetString($bytes, $preamble.Length, $bytes.Length - $preamble.Length)
    return @{ Text = $text; Encoding = $encoding; Preamble = $preamble }
}

function Write-TextFileKeepingAccess([string]$Path, $File, [string]$Text) {
    $body = $File.Encoding.GetBytes($Text)
    $temp = "$Path.new"
    [IO.File]::WriteAllBytes($temp, ([byte[]]($File.Preamble + $body)))
    try { Set-Acl -LiteralPath $temp -AclObject (Get-Acl -LiteralPath $Path) } catch { Remove-Item -LiteralPath $temp -Force; throw }
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Remove-MatchingLines([string]$Text, [string]$Pattern) {
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split "(?<=\n)")) {
        if ($line -match $Pattern) { continue }
        $kept.Add($line)
    }
    return ($kept -join "")
}

$script:OldFirewallDisplayNames = @(
    "Hermes Console Tailscale", "Hermes Console private network",
    "Hermes Console Tailscale (application)", "Hermes Console private network (application)"
)

function Get-OldFirewallRules {
    $rules = @()
    foreach ($rule in @(Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        if ($rule.Name -notlike "HermesConsole-*" -or $rule.Name -eq $script:FirewallRuleName) { continue }
        if ($script:OldFirewallDisplayNames -notcontains [string]$rule.DisplayName) { continue }
        $rules += $rule
    }
    return $rules
}

# Read-only: the traces Invoke-RetireGatewayExposure and Invoke-RetireBridge look
# for in files. Setup only reports them at the end of a run.
function Test-GatewayExposurePresent([string]$HermesHome) {
    $services = Join-Path $HermesHome "console-services"
    $runner = Join-Path $services "hermes-gateway.vbs"
    if (Test-Path -LiteralPath $runner -PathType Leaf) {
        if ((Read-TextFile $runner).Text -match '(?m)^\s*sh\.Environment\("Process"\)\("API_SERVER_(HOST|PORT)"\)\s*=') { return $true }
    }
    foreach ($name in @("pairing.json", "pairing-qr.png", "pairing-qr.txt")) {
        if (Test-Path -LiteralPath (Join-Path $services $name)) { return $true }
    }
    return $false
}

function Test-BridgeLeftoversPresent([string]$HermesHome) {
    $services = Join-Path $HermesHome "console-services"
    $target = Join-Path $HermesHome "hermes_bridge.py"
    foreach ($path in @($target, "$target.rollback", "$target.new", (Join-Path $HermesHome "bridge.env"),
                        (Join-Path $HermesHome "bridge_token"), (Join-Path $services "hermes-bridge.vbs"),
                        (Join-Path $services "restart-hermes-bridge.vbs"))) {
        if (Test-Path -LiteralPath $path) { return $true }
    }
    return $false
}

function Invoke-RetireGatewayExposure {
    param([string]$HermesHome, [bool]$AlsoRemoveKey)
    $services = Join-Path $HermesHome "console-services"
    $envFile = Join-Path $HermesHome ".env"
    $runner = Join-Path $services "hermes-gateway.vbs"
    $backups = Join-Path $HermesHome "backups"
    $pairing = @("pairing.json", "pairing-qr.png", "pairing-qr.txt") | ForEach-Object { Join-Path $services $_ }
    foreach ($guarded in (@($services, $envFile, $runner, $backups) + $pairing)) {
        if (Test-ReparsePoint $guarded) { throw "$guarded is a symbolic link; nothing was changed." }
    }

    $runnerFile = $null
    $hasRunnerExposure = $false
    $gatewayPort = 8642
    if ($env:HERMES_GATEWAY_PORT -and $env:HERMES_GATEWAY_PORT -match '^[0-9]{1,5}$') { $gatewayPort = [int]$env:HERMES_GATEWAY_PORT }
    $runnerPattern = '^\s*sh\.Environment\("Process"\)\("API_SERVER_(HOST|PORT)"\)\s*='
    if (Test-Path -LiteralPath $runner -PathType Leaf) {
        $runnerFile = Read-TextFile $runner
        if ($runnerFile.Text -match ("(?m)" + $runnerPattern)) { $hasRunnerExposure = $true }
        if ($runnerFile.Text -match '(?m)^\s*sh\.Environment\("Process"\)\("API_SERVER_PORT"\)\s*=\s*"([0-9]{1,5})"') {
            $gatewayPort = [int]$Matches[1]
        }
    }
    $pairingPresent = @($pairing | Where-Object { Test-Path -LiteralPath $_ })
    $keyPresent = $false
    $envFileData = $null
    if (Test-Path -LiteralPath $envFile -PathType Leaf) {
        $envFileData = Read-TextFile $envFile
        if ($envFileData.Text -match '(?m)^API_SERVER_KEY=') { $keyPresent = $true }
    }
    $oldRules = @(Get-OldFirewallRules)
    $rulesToChange = @()
    foreach ($rule in $oldRules) {
        $ports = @((Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule).LocalPort | ForEach-Object { [string]$_ })
        if ($ports -contains "$gatewayPort") { $rulesToChange += $rule }
    }
    $isAdmin = Test-CurrentProcessAdministrator

    $removeKey = ($AlsoRemoveKey -and $keyPresent)
    $evidence = ($hasRunnerExposure -or $pairingPresent.Count -gt 0 -or $rulesToChange.Count -gt 0 -or $removeKey)
    if (-not $evidence) {
        Write-Say "The earlier Console setup left nothing exposed on the Gateway. Nothing to do."
        return 0
    }

    # Everything is prepared first, so a failure leaves the computer as it was.
    $newEnv = $null
    $backup = $null
    if ($removeKey) {
        $newEnv = Remove-MatchingLines $envFileData.Text '^API_SERVER_KEY='
        $lines = (($envFileData.Text -split "(?<=\n)") | Where-Object { $_ -match '^API_SERVER_KEY=' }) -join ""
        $backupDir = Join-Path $backups "gateway-exposure"
        New-Item -ItemType Directory -Force -Path $backups | Out-Null
        New-PrivateDirectory $backupDir
        $backup = Join-Path $backupDir ("api-server-key." + (Get-Date -Format "yyyyMMdd-HHmmss") + "." + $PID)
        [IO.File]::WriteAllText($backup, $lines, $script:Utf8NoBom)
        Set-PrivateAcl $backup
    }
    $newRunner = $null
    if ($hasRunnerExposure) { $newRunner = Remove-MatchingLines $runnerFile.Text $runnerPattern }

    if ($removeKey) { Write-TextFileKeepingAccess $envFile $envFileData $newEnv }
    if ($hasRunnerExposure) { Write-TextFileKeepingAccess $runner $runnerFile $newRunner }
    foreach ($path in $pairingPresent) { Remove-Item -LiteralPath $path -Force }
    $rulesClosed = 0
    if ($isAdmin) {
        foreach ($rule in $rulesToChange) {
            $ports = @((Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule).LocalPort | ForEach-Object { [string]$_ })
            $left = @($ports | Where-Object { $_ -ne "$gatewayPort" })
            if ($left.Count -eq 0) { Remove-NetFirewallRule -Name $rule.Name } else { Set-NetFirewallRule -Name $rule.Name -LocalPort $left }
            $rulesClosed++
        }
    }

    Write-Say "Done. What the earlier Console setup added to the Gateway was removed:"
    if ($hasRunnerExposure) { Write-Say "  - the network address and port in $runner" }
    if ($pairingPresent.Count -gt 0) { Write-Say "  - the pairing record" }
    if ($rulesClosed -gt 0) { Write-Say "  - TCP $gatewayPort in $rulesClosed Windows Firewall rule(s) the earlier setup made" }
    if ($removeKey) { Write-Say "  - the API key line in $envFile (you asked for it)" }
    if ($rulesToChange.Count -gt 0 -and -not $isAdmin) {
        Write-Say "NOT DONE: TCP $gatewayPort is still allowed in $($rulesToChange.Count) Windows Firewall rule(s) the earlier setup made."
        Write-Say "Run this again from an elevated (administrator) PowerShell to close it."
    }
    if ($removeKey) {
        Write-Say "A private copy of the removed key line is in $backup."
        Write-Say "WARNING: without a usable API key Hermes does not start its API server. After the"
        Write-Say "Gateway's next restart anything of yours that uses that key stops working: a cron"
        Write-Say "provider other than the built-in one, Open WebUI or any other client. To undo,"
        Write-Say "copy the line back into $envFile."
    } elseif ($keyPresent) {
        Write-Say "Your API key in $envFile was kept: Open WebUI, a cron provider or another client"
        Write-Say "of yours may be using it. Without this network address and port, Hermes' API server"
        Write-Say "listens on its default, this computer only, unless you set a host yourself."
        Write-Say "To remove the key too, run this again with -AlsoRemoveApiKey."
    }
    if ($envFileData -and $envFileData.Text -match '(?m)^API_SERVER_HOST=(.*)$') {
        Write-Say "NOTE: your .env sets API_SERVER_HOST itself. It is yours, so it was left as it is; the"
        Write-Say "Gateway's API server keeps listening there until you change it."
    }
    if (Test-Path -LiteralPath (Join-Path $services "dashboard-login.json")) {
        Write-Say "Left in place: $services\dashboard-login.json holds the Dashboard"
        Write-Say "password in clear, from the earlier setup. Nothing uses it any more; delete it"
        Write-Say "yourself if you do not want the password stored."
    }
    Write-Say "Your Gateway was not stopped or restarted. It keeps listening as it was"
    Write-Say "until the Gateway is restarted (hermes gateway restart). Its Scheduled Task, its other"
    Write-Say "settings and the rest of your .env were not changed."
    return 0
}
#endregion retire-gateway-exposure

# ---------------------------------------------------------------------------
# -RetireBridge
# ---------------------------------------------------------------------------

function Invoke-RetireBridge([string]$HermesHome) {
    $services = Join-Path $HermesHome "console-services"
    $target = Join-Path $HermesHome "hermes_bridge.py"
    $files = @(
        $target, "$target.rollback", "$target.new",
        (Join-Path $HermesHome "bridge.env"), (Join-Path $HermesHome "bridge_token"),
        (Join-Path $services "hermes-bridge.vbs"), (Join-Path $services "restart-hermes-bridge.vbs")
    )
    if (Test-ReparsePoint $services) { throw "$services is a symbolic link; nothing was removed." }
    $names = @("HermesConsole-MobileBridge", "HermesConsole-Restart-MobileBridge")
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.TaskName })
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and ([string]$_.CommandLine).IndexOf($target, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    $present = @($files | Where-Object { Test-Path -LiteralPath $_ })
    if ($tasks.Count -eq 0 -and $processes.Count -eq 0 -and $present.Count -eq 0) {
        Write-Say "There is no Mobile Bridge on this computer. Nothing to do."
        return 0
    }
    # A task whose runner is not this home's belongs to somebody else: nothing is removed.
    foreach ($task in $tasks) {
        $arguments = [string](@($task.Actions)[0].Arguments)
        if ($arguments.IndexOf($services, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            Write-Problem "ERROR: the Scheduled Task $($task.TaskName) does not run this home's runner. Nothing was removed."
            return 1
        }
    }
    $failed = @()
    foreach ($task in $tasks) {
        try {
            Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
        } catch { $failed += "task:$($task.TaskName)" }
    }
    foreach ($process in $processes) {
        try { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop } catch { $failed += "process:$($process.ProcessId)" }
    }
    if ($failed.Count -eq 0) {
        # The files go last: a bridge that is still running is never deleted from under itself.
        foreach ($path in $present) {
            try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $failed += "file:$([IO.Path]::GetFileName($path))" }
        }
    }
    if ($failed.Count -gt 0) {
        Write-Problem "ERROR: part of the Mobile Bridge could not be removed: $($failed -join ', ')."
        Write-Problem "Nothing else was touched. Close whatever still uses it and run this again."
        return 1
    }
    Write-Say "Done. The old Mobile Bridge was stopped and removed."
    Write-Say "Hermes, its Gateway and its Dashboard were not touched: Console 1.2.15 or newer keeps working."
    Write-Say "Port 9131 is no longer used. A firewall rule that opened it can be deleted; nothing listens there now."
    return 0
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

function Get-ResolvedHermesHome {
    if (-not $env:LOCALAPPDATA) { throw "LOCALAPPDATA is not set, so the default Hermes home cannot be found." }
    $default = Resolve-HermesHome (Join-Path $env:LOCALAPPDATA "hermes")
    $given = [Environment]::GetEnvironmentVariable("HERMES_HOME")
    if ($null -eq $given) { return $default }
    if ([string]::IsNullOrWhiteSpace($given)) { throw "HERMES_HOME may not be empty." }
    $chosen = Resolve-HermesHome $given
    if (-not [string]::Equals($chosen, $default, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-HermesHomeEvidence $default)) {
        throw "Another Hermes home exists at $default; refusing an ambiguous choice of $chosen."
    }
    return $chosen
}

function Assert-WindowsPlatform {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "This is the Windows version. On Linux or macOS use hermes-dashboard-setup.sh."
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw "Windows PowerShell 5.1 or newer is needed." }
}

# A function's result is everything it wrote to the pipeline; the exit code is the last item.
function Get-ExitCode($Result) {
    $items = @($Result)
    if ($items.Count -eq 0) { return 1 }
    return [int]$items[$items.Count - 1]
}

function Invoke-Main {
    $lock = $null
    try {
        $action = Get-RequestedAction -NewAccess $NewAccess.IsPresent -PasswordStdin $PasswordStdin.IsPresent `
            -RetireGatewayExposure $RetireGatewayExposure.IsPresent -AlsoRemoveApiKey $AlsoRemoveApiKey.IsPresent `
            -RetireBridge $RetireBridge.IsPresent -Remove $Remove.IsPresent -Help $Help.IsPresent `
            -PasswordGiven $script:PasswordWasGiven -UnexpectedCount @($Unexpected).Count
        if ($action -eq "help") { Show-Usage; return 0 }
        Assert-WindowsPlatform
        $hermesHome = Get-ResolvedHermesHome
        $lock = Enter-SetupLock
        switch ($action) {
            "retire-bridge" { return (Get-ExitCode (Invoke-RetireBridge $hermesHome)) }
            "remove" { return (Get-ExitCode (Invoke-RemoveDashboard $hermesHome)) }
            "retire-gateway-exposure" {
                return (Get-ExitCode (Invoke-RetireGatewayExposure -HermesHome $hermesHome -AlsoRemoveKey $AlsoRemoveApiKey.IsPresent))
            }
            default {
                return (Get-ExitCode (Invoke-DashboardSetup -Action $action -FromStdin $PasswordStdin.IsPresent `
                    -ChosenAddress $BindAddress -ChosenPort $Port -HermesHome $hermesHome))
            }
        }
    } catch {
        Write-Problem "ERROR: $($_.Exception.Message)"
        return 1
    } finally {
        Exit-SetupLock $lock
    }
}

# Dot-sourced (by the tests): only the definitions above are wanted.
if ($MyInvocation.InvocationName -eq ".") { return }

$exitCode = Invoke-Main
if ($PSCommandPath) { exit $exitCode }
$global:LASTEXITCODE = $exitCode
