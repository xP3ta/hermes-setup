[CmdletBinding()]
param(
    [ValidateSet("All", "ParserBootstrap", "UrlPolicy", "PairNoRepair", "Health", "ContainmentFailure", "LockOwnership", "TransactionRollback", "FreshInstallCleanup", "UpstreamInstallerPin", "PlatformSupport", "ProcessDiagnostics", "ServiceRunnerEncoding", "NativeJob", "TopLevelTimeouts", "PreflightDiagnose", "ServicePorts", "AdaptiveWait", "AddressCandidates", "Uninstall", "FailureHint", "ProgressBranding", "FirewallAppRules")]
    [string]$Case = "All",
    [string]$SetupScript = "",
    [string]$PairScript = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not $SetupScript -or -not $PairScript) {
    $suiteRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $scriptsRoot = Split-Path -Parent $suiteRoot
    if (-not $SetupScript) { $SetupScript = Join-Path $scriptsRoot "hermes-mobile-setup.ps1" }
    if (-not $PairScript) { $PairScript = Join-Path $scriptsRoot "hermes-pair.ps1" }
}
$script:Passed = 0
$script:Skipped = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Passed++
    Write-Host "PASS [$Case]: $Message"
}

function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = ""
    try { & $Action } catch { $caught = $_.Exception.Message }
    Assert-True ([bool]$caught) "$Message throws"
    if ($Pattern) {
        Assert-True ($caught -match $Pattern) "$Message reports the bounded reason (actual: $caught)"
    }
    return $caught
}

function Write-Skip([string]$Message) {
    $script:Skipped++
    Write-Host "SKIP [$Case]: $Message" -ForegroundColor Yellow
}

function Invoke-ChildProcessCapture([string]$FilePath, [string[]]$ArgumentList) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $captured = @(& $FilePath @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [PSCustomObject]@{ Output = $captured; ExitCode = $exitCode }
}

function Parse-Product([string]$Path) {
    $tokens = $null
    $errors = $null
    $source = [IO.File]::ReadAllText($Path)
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $source, [ref]$tokens, [ref]$errors
    )
    return [PSCustomObject]@{ Source = $source; Ast = $ast; Errors = @($errors) }
}

function Find-Function([Management.Automation.Language.Ast]$Root, [string]$Name) {
    return $Root.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
    }, $true)
}

function Import-ProductFunction($Parsed, [string]$Name) {
    $functionAst = Find-Function $Parsed.Ast $Name
    if ($null -eq $functionAst) { throw "Product function is missing: $Name" }
    $definition = [regex]::Replace(
        $functionAst.Extent.Text,
        ('^function\s+' + [regex]::Escape($Name)),
        "function global:$Name"
    )
    Invoke-Expression $definition
}

$setup = Parse-Product $SetupScript
$pair = Parse-Product $PairScript

function Test-ParserBootstrap {
    Assert-True ($setup.Errors.Count -eq 0) "setup parses"
    Assert-True ($pair.Errors.Count -eq 0) "pairing helper parses"
    $setupRaw = Get-Content -LiteralPath $SetupScript -Raw
    Assert-True ($setupRaw -notmatch '(?i)-m\s+pip\s+install') "pairing QR never mutates the Hermes venv with pip"
    Assert-True ($setupRaw -match 'function\s+Get-HermesUv' -and
        $setupRaw -match 'run\s+--isolated\s+--no-project' -and
        $setupRaw -match 'qrcode==8\.2') "pairing QR dependency is pinned in an isolated uv environment"
    Assert-True ($setupRaw -notmatch '(?i)-Verb\s+RunAs') "setup never auto-elevates or opens a UAC window"
    Assert-True ($setupRaw -match 'Assert-FirewallPreflight') "firewall privileges are checked before integration mutation"
    Assert-True ($setupRaw -notmatch 'Install-RestrictedFirewallRuleElevated') "setup has no temporary elevation helper"
    foreach ($temporaryName in @("BridgeNew", "ManifestFile", "PairingNew", "QrNew", "EnvNew", "Installer", "InstallerOut", "InstallerErr", "QrScript")) {
        Assert-True ($setupRaw -match "Remove-OwnedSetupFiles[\s\S]+$temporaryName") "cleanup covers $temporaryName"
    }
    $launcherPath = Join-Path (Split-Path $SetupScript -Parent) "hermes-mobile-setup.vbs"
    $launcherRaw = Get-Content -LiteralPath $launcherPath -Raw
    Assert-True ($launcherRaw -notmatch '(?i)MsgBox|explorer\.exe|Invoke-Item|ShellExecute') "VBS launcher never opens status, QR, console, or viewer windows"
    Assert-True ($launcherRaw -match 'shell\.Run\(command,\s*0,\s*True\)') "VBS launcher keeps its only child hidden and waits for cleanup"
    Assert-True ($setupRaw -match 'CREATE_NO_WINDOW') "contained native children use CREATE_NO_WINDOW"
    Assert-True ($setupRaw -match '-SkipComputerUse') "Console bootstrap skips unused Computer Use payloads"
    # Regression (observed natively on Windows 11 25H2, PS 5.1): upstream
    # `hermes dashboard --host 0.0.0.0` refuses a non-loopback bind without a
    # registered auth provider and exits. Provisioning credentials only after
    # the readiness gate deadlocked every fresh LAN install (240s timeout).
    $credentialsStep = $setupRaw.IndexOf('Write-Audit "Dashboard credentials"')
    $dashboardStart = $setupRaw.IndexOf('Start-HermesProcess "HermesConsole-Dashboard"')
    $dashboardGate = $setupRaw.IndexOf('Wait-HermesService "dashboard"')
    Assert-True ($credentialsStep -gt 0 -and $dashboardStart -gt 0 -and $credentialsStep -lt $dashboardStart) "dashboard credentials are provisioned before the dashboard start"
    Assert-True ($dashboardGate -gt 0 -and $credentialsStep -lt $dashboardGate) "dashboard credentials are provisioned before the dashboard readiness gate"

    $self = Parse-Product $PSCommandPath
    Assert-True ($self.Errors.Count -eq 0) "review suite parses"
    # Windows PowerShell 5.1 reads a BOM-less file as ANSI: one non-ASCII byte
    # (an em dash, a smart quote) silently terminates a string and breaks the
    # whole script. Keep every published PowerShell artifact pure ASCII.
    foreach ($artifact in @($SetupScript, $PairScript, $PSCommandPath)) {
        $bytes = [IO.File]::ReadAllBytes($artifact)
        Assert-True (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) `
            "$([IO.Path]::GetFileName($artifact)) stays pure ASCII for Windows PowerShell 5.1 without a BOM"
    }
    Import-ProductFunction $setup "Initialize-WindowsJobApi"
    function global:Test-WindowsPlatform { return $true }
    Initialize-WindowsJobApi
    Assert-True ($null -ne ("HermesConsole.NativeJobProcess" -as [type])) "embedded Job Object C# helper compiles in the current runtime"

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-bootstrap-" + [Guid]::NewGuid().ToString("N"))
    $fixtureHome = Join-Path $temp "must-not-exist"
    New-Item -ItemType Directory -Path $temp | Out-Null
    $oldReview = $env:HERMES_SETUP_REVIEW_MODE
    $oldHome = $env:HERMES_HOME
    $oldLocal = $env:LOCALAPPDATA
    try {
        $env:HERMES_SETUP_REVIEW_MODE = "synthetic-canary"
        $env:HERMES_HOME = $fixtureHome
        $env:LOCALAPPDATA = $temp
        $hostExe = (Get-Process -Id $PID).Path

        $fileRun = Invoke-ChildProcessCapture $hostExe @("-NoLogo", "-NoProfile", "-File", $SetupScript)
        $fileOutput = @($fileRun.Output)
        Assert-True ($fileRun.ExitCode -eq 0) "actual setup file safe smoke exits zero"
        Assert-True (($fileOutput -join "`n") -match 'HERMES_SETUP_REVIEW_MODE_OK') "actual setup file reaches the safe fixture boundary"
        Assert-True (-not (Test-Path -LiteralPath $fixtureHome)) "actual setup file safe smoke performs no target-home mutation"

        $invalidRun = Invoke-ChildProcessCapture $hostExe @("-NoLogo", "-NoProfile", "-File", $SetupScript, "-InstallerTimeoutSec", "0")
        $invalidOutput = @($invalidRun.Output)
        Assert-True ($invalidRun.ExitCode -ne 0) "invalid installer timeout is rejected before launch"
        Assert-True (($invalidOutput -join "`n") -match '(?i)InstallerTimeoutSec must be an integer between 1 and 86400') "invalid installer timeout reports stable English validation"
        Assert-True (-not (Test-Path -LiteralPath $fixtureHome)) "invalid installer timeout performs no target-home mutation"

        $escaped = $SetupScript.Replace("'", "''")
        $iexCommand = "Get-Content -LiteralPath '$escaped' -Raw | Invoke-Expression"
        $iexRun = Invoke-ChildProcessCapture $hostExe @("-NoLogo", "-NoProfile", "-Command", $iexCommand)
        $iexOutput = @($iexRun.Output)
        Assert-True ($iexRun.ExitCode -eq 0) "single-file pipeline/iex safe smoke exits zero"
        Assert-True (($iexOutput -join "`n") -match 'HERMES_SETUP_REVIEW_MODE_OK') "single-file pipeline/iex needs no sibling helper"
        Assert-True (-not (Test-Path -LiteralPath $fixtureHome)) "single-file pipeline/iex safe smoke performs no target-home mutation"
    } finally {
        $env:HERMES_SETUP_REVIEW_MODE = $oldReview
        $env:HERMES_HOME = $oldHome
        $env:LOCALAPPDATA = $oldLocal
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-FailureHint {
    # Quien falla tiene que saber que existe un informe redactado y como pedirlo.
    $setupRaw = Get-Content -LiteralPath $SetupScript -Raw
    Assert-True ($setupRaw -match 'Re-run this same command with -Diagnose') `
        "a failed run points the user at the redacted report"
    Assert-True ($setupRaw -match 'hint = \$diagnoseHint') "the failure object carries the diagnostic hint"
    Assert-True ($setupRaw -match 'Invoke-SetupUninstall') "the installer exposes an uninstall path for stuck states"
    Assert-True ($setupRaw -match '-Uninstall -Purge') "the uninstall hint names the purge switch explicitly"
}

function Test-UrlPolicy {
    foreach ($name in @(
        "Test-Cgnat", "Test-PrivateIpv4", "Test-AllowedIpAddress",
        "Test-PrivateHost", "Assert-AllowedServiceUrl", "Assert-HermesResponseStatus",
        "Invoke-HermesJsonRequest"
    )) { Import-ProductFunction $pair $name }

    foreach ($url in @(
        "http://10.1.2.3:8642",
        "http://172.20.1.2:8642",
        "http://192.168.2.2:8642",
        "http://100.64.2.2:8642",
        "http://169.254.2.2:8642",
        "http://127.0.0.1:8642",
        "http://[fd12:3456::2]:8642",
        "http://[fe80::2]:8642",
        "http://[::1]:8642",
        "http://hermesbox:8642",
        "http://node.tailnet.ts.net:8642",
        "https://203.0.113.10:8642"
    )) {
        Assert-AllowedServiceUrl $url
        Assert-True $true "allowed URL policy accepts $url"
    }

    foreach ($url in @(
        "http://8.8.8.8:8642",
        "http://[2001:4860:4860::8888]:8642",
        "http://user:pass@192.168.1.2:8642",
        "http://192.168.1.2:8642/path?token=canary",
        "http://192.168.1.2:8642/#fragment"
    )) {
        [void](Assert-Throws { Assert-AllowedServiceUrl $url } 'Invalid|Public HTTP' "URL policy rejects $url")
    }

    [void](Assert-Throws {
        Assert-HermesResponseStatus 302 $true
    } 'Authenticated redirects are refused' "authenticated redirect status is rejected by the product policy")

    Import-ProductFunction $setup "Get-RestrictedFirewallRuleState"
    Import-ProductFunction $setup "Assert-FirewallPreflight"
    $script:FirewallMutationCalls = 0
    function global:Get-RestrictedFirewallRuleState { param($DisplayName, $Kind) return "Absent" }
    function global:Test-CurrentProcessAdministrator { return $false }
    function global:New-NetFirewallRule { $script:FirewallMutationCalls++ }
    function global:Start-Process { $script:FirewallMutationCalls++ }
    $firewallPairing = @{ Scheme = "http"; Kind = "mesh"; InterfaceIndex = $null }
    [void](Assert-Throws {
        Assert-FirewallPreflight $firewallPairing
    } 'already elevated|no changes were made' "missing firewall privilege fails before setup mutation")
    Assert-True ($script:FirewallMutationCalls -eq 0) "firewall preflight never opens UAC or mutates firewall"
    function global:Get-RestrictedFirewallRuleState { param($DisplayName, $Kind) return "Conflict" }
    function global:Test-CurrentProcessAdministrator { return $true }
    [void](Assert-Throws {
        Assert-FirewallPreflight $firewallPairing
    } 'pre-existing.*not exact|not exact.*pre-existing' "non-exact pre-existing firewall rule fails even for administrator")
    Assert-True ($script:FirewallMutationCalls -eq 0) "conflicting firewall preflight performs no mutation"

    if ($env:OS -ne "Windows_NT") {
        Write-Skip "loopback redirect integration is reserved for native Windows; this sandbox denies listener creation"
        return
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-redirect-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $serverScript = Join-Path $temp "redirect-server.ps1"
    $ready = Join-Path $temp "ready.txt"
    $observed = Join-Path $temp "observed.txt"
    $portFile = Join-Path $temp "port.txt"
    $serverSource = @'
param([string]$Ready, [string]$Observed, [string]$PortFile)
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
[IO.File]::WriteAllText($PortFile, [string]$port)
[IO.File]::WriteAllText($Ready, "ready")
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    $count = 0
    while ($count -lt 2 -and [DateTime]::UtcNow -lt $deadline) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 25; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            $request = $reader.ReadLine()
            $auth = ""
            while ($true) {
                $line = $reader.ReadLine()
                if (-not $line) { break }
                if ($line -match '^(?i)Authorization:\s*(.*)$') { $auth = $Matches[1] }
            }
            [IO.File]::AppendAllText($Observed, "$request|$auth`n")
            $location = "http://127.0.0.1:$port/sink"
            $response = "HTTP/1.1 302 Found`r`nLocation: $location`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($response)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $count++
        } finally { $client.Dispose() }
    }
} finally { $listener.Stop() }
'@
    [IO.File]::WriteAllText($serverScript, $serverSource, (New-Object Text.UTF8Encoding($false)))
    $server = $null
    try {
        $hostExe = (Get-Process -Id $PID).Path
        $server = Microsoft.PowerShell.Management\Start-Process -FilePath $hostExe -ArgumentList @(
            "-NoLogo", "-NoProfile", "-File", "`"$serverScript`"",
            "-Ready", "`"$ready`"", "-Observed", "`"$observed`"", "-PortFile", "`"$portFile`""
        ) -PassThru
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $ready) -and $watch.Elapsed.TotalSeconds -lt 10) {
            Start-Sleep -Milliseconds 25
        }
        Assert-True (Test-Path -LiteralPath $ready) "synthetic redirect fixture starts"
        $port = [int][IO.File]::ReadAllText($portFile)
        [void](Assert-Throws {
            Invoke-HermesJsonRequest -Method Get -Url "http://127.0.0.1:$port/start" `
                -Token "REVIEW-NONSECRET-CANARY" -TimeoutSeconds 3
        } 'redirect' "authenticated request refuses redirect")
        $server.WaitForExit(10000) | Out-Null
        $lines = @([IO.File]::ReadAllLines($observed))
        Assert-True ($lines.Count -eq 1) "authenticated redirect target receives no request"
        Assert-True ($lines[0] -match 'REVIEW-NONSECRET-CANARY') "only the original loopback origin receives the synthetic canary"
    } finally {
        if ($server -and -not $server.HasExited) { $server.WaitForExit(10000) | Out-Null }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-PairNoRepair {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-pair-only-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $fixtureHome = Join-Path $temp "missing-home"
    $oldHome = $env:HERMES_HOME
    $oldLocal = $env:LOCALAPPDATA
    $oldRaw = $env:HERMES_REPO_RAW
    $oldReview = $env:HERMES_SETUP_REVIEW_MODE
    try {
        $env:HERMES_HOME = $fixtureHome
        $env:LOCALAPPDATA = $temp
        $env:HERMES_REPO_RAW = "http://127.0.0.1:1/never-used"
        $env:HERMES_SETUP_REVIEW_MODE = $null
        $hostExe = (Get-Process -Id $PID).Path
        $pairRun = Invoke-ChildProcessCapture $hostExe @("-NoLogo", "-NoProfile", "-File", $PairScript)
        $output = @($pairRun.Output)
        Assert-True ($pairRun.ExitCode -ne 0) "pair-only fails closed when repair is required"
        Assert-True (($output -join "`n") -match '(?i)-Repair') "pair-only requires explicit repair opt-in"
        Assert-True (($output -join "`n") -notmatch '(?i)running the verified|repair completed') "pair-only does not start automatic repair"
        Assert-True (-not (Test-Path -LiteralPath $fixtureHome)) "pair-only missing-installation failure performs no target-home mutation"

        # Regression (observed natively on Windows 11 25H2, PS 5.1): probing the
        # venv with `& $Python -c "import qrcode" 2>$null` under
        # $ErrorActionPreference="Stop" turns native stderr into a terminating
        # NativeCommandError and aborts pair before the link prints (exit 1).
        $pairRaw = Get-Content -LiteralPath $PairScript -Raw
        Assert-True ($pairRaw -notmatch '&\s+\$Python\s+-c\s+"import qrcode"') "pair QR never probes the venv interpreter directly under ErrorActionPreference Stop"
        Assert-True ($pairRaw -match 'qrcode==8\.2' -and $pairRaw -match '"--isolated"') "pair QR reuses the pinned isolated uv runtime"
        Assert-True ($pairRaw -match '\$ErrorActionPreference\s*=\s*"Continue"') "pair QR call site isolates native stderr from the Stop preference"
        Assert-True ($pairRaw -match 'PYTHONIOENCODING\s*=\s*"utf-8"') "pair QR forces UTF-8 for the U+2588 block glyphs the legacy console codepage cannot encode"
    } finally {
        $env:HERMES_HOME = $oldHome
        $env:LOCALAPPDATA = $oldLocal
        $env:HERMES_REPO_RAW = $oldRaw
        $env:HERMES_SETUP_REVIEW_MODE = $oldReview
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-Health {
    Import-ProductFunction $setup "Test-HermesLauncher"
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-health-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $healthyPath = Join-Path $temp "healthy-hermes.exe"
    $brokenPath = Join-Path $temp "broken-hermes.exe"
    [IO.File]::WriteAllText($healthyPath, "synthetic")
    [IO.File]::WriteAllText($brokenPath, "synthetic")
    $script:ProbeCalls = 0
    $script:TerminationTimeoutSeconds = 2
    $script:MutationQuiescent = $true
    $global:HealthyFixturePath = $healthyPath
    function global:Invoke-ContainedProcess {
        param($File, $Arguments, $TimeoutSeconds, $TerminationTimeoutSeconds, $StdoutPath, $StderrPath, $StandardInput)
        $script:ProbeCalls++
        if ($File -eq $global:HealthyFixturePath -and $Arguments -eq "--version") {
            return [PSCustomObject]@{ ExitCode = 0; TimedOut = $false }
        }
        throw "synthetic launcher exit 42"
    }
    Assert-True (Test-HermesLauncher $healthyPath 2) "health requires a successful contained launcher invocation"
    Assert-True (-not (Test-HermesLauncher $brokenPath 2)) "a broken launcher is never healthy"
    Assert-True ($script:ProbeCalls -eq 2) "health verdict comes from the launcher invocation contract"

    foreach ($name in @(
        "Get-FreshHermesInstallArtifacts", "Remove-FreshHermesInstallArtifacts", "Install-HermesIfNeeded"
    )) { Import-ProductFunction $setup $name }
    $script:HealthChecks = 0
    function global:Get-HermesExecutable { return "synthetic-hermes.exe" }
    function global:Test-HermesLauncher {
        param($Executable, $TimeoutSeconds)
        $script:HealthChecks++
        return $false
    }
    function global:Save-VerifiedHermesAgentInstaller {
        param($Destination)
        [IO.File]::WriteAllText($Destination, "# synthetic verified installer; never executed")
    }
    function global:Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing)
        [IO.File]::WriteAllText($OutFile, "# synthetic installer; never executed")
    }
    function global:Invoke-ContainedProcess { return [PSCustomObject]@{ ExitCode = 0; TimedOut = $false } }
    function global:Invoke-HiddenProcess { param($File, $Arguments, $TimeoutSeconds, $StdoutPath, $StderrPath, $Operation) }
    function global:Get-PowerShellExecutable { return (Get-Process -Id $PID).Path }
    function global:Write-Info { param($Message) }
    function global:Write-Audit { param($Step, $State, $Detail) }
    $global:AuditOnly = $false
    $script:HermesInstallTimeoutSeconds = 2
    $script:HermesAgentCommit = "0000000000000000000000000000000000000000"
    $script:TerminationTimeoutSeconds = 2
    $script:MutationQuiescent = $true
    $script:OwnedTempPaths = New-Object System.Collections.Generic.List[string]
    $global:HermesHome = Join-Path $temp "synthetic-hermes-home"
    $global:InstallDir = Join-Path $global:HermesHome "hermes-agent"
    $global:HermesBinDir = Join-Path $global:HermesHome "bin"
    $global:AuditDir = $temp
    $global:AttemptPaths = [PSCustomObject]@{
        Installer = (Join-Path $temp "installer.ps1")
        InstallerOut = (Join-Path $temp "installer.out")
        InstallerErr = (Join-Path $temp "installer.err")
    }
    [void](Assert-Throws { Install-HermesIfNeeded } 'launcher.*health|health.*launcher|did not pass' "post-install launcher failure stays broken")
    Assert-True ($script:HealthChecks -ge 2) "installer checks the launcher both before and after repair"
    $setupRaw = Get-Content -LiteralPath $SetupScript -Raw
    Assert-True ($setupRaw -match 'Wait-HermesService\s+"gateway"\s+"http://127\.0\.0\.1:\$GatewayPort"\s+\$ApiKey\s+60') `
        "clean native Gateway startup receives the proven readiness window on the resolved port"
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

function Test-ContainmentFailure {
    Import-ProductFunction $setup "Stop-ContainedProcessAfterTimeout"
    $syntheticJob = New-Object PSObject
    $syntheticJob | Add-Member -MemberType ScriptMethod -Name TerminateAndVerify -Value {
        param([int]$Milliseconds)
        return $false
    }
    $script:MutationQuiescent = $true
    $script:UnresolvedContainedProcess = $null
    $verified = Stop-ContainedProcessAfterTimeout $syntheticJob 25
    Assert-True (-not $verified) "failed Job Object termination is never reported verified"
    Assert-True (-not $script:MutationQuiescent) "failed termination forbids setup-lock release"
    Assert-True ([object]::ReferenceEquals($syntheticJob, $script:UnresolvedContainedProcess)) "failed termination retains the exact containment owner"
}

function Test-LockOwnership {
    foreach ($name in @(
        "Test-WindowsPlatform", "Get-SetupLockName", "Enter-SetupLock", "Exit-SetupLock", "New-SetupAttemptPaths",
        "Remove-OwnedSetupFiles", "Resolve-HermesHome", "ConvertTo-WindowsSid", "Test-SameWindowsIdentity",
        "Assert-OwnedHermesHome", "Assert-OwnedHermesTasks", "Assert-OwnedPortRecords"
    )) { Import-ProductFunction $setup $name }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-lock-unit-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $owner = $null
    $nextOwner = $null
    $productOwner = $null
    try {
        Assert-True ((Get-SetupLockName (Join-Path $temp "home-a")) -eq
            (Get-SetupLockName (Join-Path $temp "home-b"))) "single-flight mutex also serializes homes that share global task names"

        $contenderHome = Join-Path $temp "contender-home"
        New-Item -ItemType Directory -Path (Join-Path $contenderHome "console-services") -Force | Out-Null
        $winnerPaths = New-SetupAttemptPaths -HermesHome $contenderHome
        foreach ($path in @($winnerPaths.BridgeNew, $winnerPaths.ManifestFile, $winnerPaths.PairingNew)) {
            [IO.File]::WriteAllText($path, "winner-canary")
        }
        $productLockName = Get-SetupLockName $contenderHome
        $productOwner = Enter-SetupLock -Name $productLockName -TimeoutMilliseconds 100
        $contenderScript = Join-Path $temp "lock-contender.ps1"
        $enterLockSource = (Find-Function $setup.Ast "Enter-SetupLock").Extent.Text
        [IO.File]::WriteAllText($contenderScript, @"
param([string]`$Name)
`$ErrorActionPreference = "Stop"
$enterLockSource
try {
    `$lock = Enter-SetupLock -Name `$Name -TimeoutMilliseconds 1000
    if (`$lock) { throw "Contender unexpectedly acquired the setup lock." }
} catch {
    Write-Output `$_.Exception.Message
    exit 73
}
"@)
        $hostExe = (Get-Process -Id $PID).Path
        $contenderRun = Invoke-ChildProcessCapture $hostExe @("-NoLogo", "-NoProfile", "-File", $contenderScript, "-Name", $productLockName)
        $contenderOutput = @($contenderRun.Output)
        Assert-True ($contenderRun.ExitCode -eq 73) "actual cross-process setup-lock contender fails closed"
        Assert-True (($contenderOutput -join "`n") -match 'Another Hermes Console setup owns the lock') "actual contender reports lock ownership"
        Assert-True (([IO.File]::ReadAllText($winnerPaths.BridgeNew) -eq "winner-canary") -and
            ([IO.File]::ReadAllText($winnerPaths.ManifestFile) -eq "winner-canary") -and
            ([IO.File]::ReadAllText($winnerPaths.PairingNew) -eq "winner-canary")) "actual losing contender leaves winner staging untouched"
        Exit-SetupLock -Lock $productOwner
        $productOwner = $null

        $attemptHome = Join-Path $temp "home"
        New-Item -ItemType Directory -Path (Join-Path $attemptHome "console-services") -Force | Out-Null
        $pathsA = New-SetupAttemptPaths -HermesHome $attemptHome
        $pathsB = New-SetupAttemptPaths -HermesHome $attemptHome
        Assert-True ($pathsA.BridgeNew -ne $pathsB.BridgeNew) "attempt staging paths are unique"
        foreach ($path in @($pathsA.BridgeNew, $pathsA.ManifestFile, $pathsA.PairingNew)) {
            [IO.File]::WriteAllText($path, "winner-canary")
        }
        Remove-OwnedSetupFiles -Paths $pathsB
        Assert-True ((Test-Path $pathsA.BridgeNew) -and (Test-Path $pathsA.ManifestFile) -and (Test-Path $pathsA.PairingNew)) "loser cleanup cannot delete winner staging"

        Assert-True (-not (Test-Path -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) "hermes-console-setup.lock"))) `
            "mutex lock leaves no filesystem artifact"
        $nextOwner = Enter-SetupLock -Name $productLockName -TimeoutMilliseconds 100
        Assert-True ($null -ne $nextOwner) "next setup acquires only after winner release"
        $setupRaw = Get-Content -LiteralPath $SetupScript -Raw
        Assert-True ($setupRaw -match 'Remove-Item\s+-LiteralPath\s+\$legacyPath') "setup removes the transitional lock file on release"

        [void](Assert-Throws { Resolve-HermesHome -Candidate "relative-home" } 'absolute|ambiguous' "relative home is refused")
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($temp))
        [void](Assert-Throws { Resolve-HermesHome -Candidate $root } 'root|ambiguous' "filesystem-root home is refused")

        $foreign = Join-Path $temp "foreign-home"
        New-Item -ItemType Directory -Path $foreign | Out-Null
        $marker = Join-Path $foreign "must-remain.txt"
        [IO.File]::WriteAllText($marker, "untouched")
        [void](Assert-Throws {
            Assert-OwnedHermesHome -Path $foreign -CurrentIdentities @("DOMAIN\me") -KnownOwner "DOMAIN\other"
        } 'owned|owner' "foreign home is refused")
        Assert-True ([IO.File]::ReadAllText($marker) -eq "untouched") "foreign-home refusal performs no mutation"
        Assert-True ($setupRaw -match '\$homeOwners\s*=\s*@\(Get-CurrentHomeOwnerIdentities\)') `
            "home ownership uses an explicit elevated-owner identity set"
        Assert-True ($setupRaw -match 'Assert-OwnedHermesHome[^\r\n]+\$homeOwners' -and
            $setupRaw -match 'Assert-OwnedHermesTasks[^\r\n]+\$identities') `
            "elevated home owners never broaden Scheduled Task principals"
        Assert-True ($setupRaw -match 'Test-SameWindowsIdentity\s+\$task\.Principal\.UserId\s+\$CurrentIdentities') `
            "Scheduled Task principals are compared by canonical Windows identity"
        Assert-True ($setupRaw -match 'function\s+Stop-OwnedHermesListener' -and
            $setupRaw -match 'Assert-OwnedPortRecords' -and $setupRaw -match '\.Handle' -and
            $setupRaw -match '\.Kill\(' -and
            $setupRaw -match 'Start-HermesProcess[\s\S]+Stop-OwnedHermesListener') `
            "task restart terminates only a handle-anchored listener owned by the selected Hermes home"

        $ownedFixtureHome = Join-Path $temp "owned-home"
        $services = Join-Path $ownedFixtureHome "console-services"
        $ownedTask = [PSCustomObject]@{
            TaskName = "HermesConsole-Gateway"; TaskPath = "\"
            Principal = [PSCustomObject]@{ UserId = "DOMAIN\me" }
            Actions = @([PSCustomObject]@{
                Execute = "C:\Windows\System32\wscript.exe"
                Arguments = "//B //NoLogo `"$(Join-Path $services 'hermes-gateway.vbs')`""
                WorkingDirectory = $ownedFixtureHome
            })
        }
        Assert-OwnedHermesTasks -Tasks @($ownedTask) -CurrentIdentities @("DOMAIN\me") -ExpectedServicesDir $services
        Assert-True $true "task owned by the current identity and exact Hermes home is accepted"
        $ownedTask.Principal.UserId = "DOMAIN\other"
        [void](Assert-Throws {
            Assert-OwnedHermesTasks -Tasks @($ownedTask) -CurrentIdentities @("DOMAIN\me") -ExpectedServicesDir $services
        } 'owned|owner|identity' "foreign task is refused")

        $expectedExe = Join-Path $ownedFixtureHome "hermes-agent/venv/Scripts/hermes.exe"
        $records = @([PSCustomObject]@{
            Port = 8642; Pid = 42; ExecutablePath = $expectedExe; CommandLine = "`"$expectedExe`" gateway run"
        })
        Assert-OwnedPortRecords -Records $records -HermesHome $ownedFixtureHome
        Assert-True $true "listener rooted in the selected Hermes home is accepted"
        $records[0].ExecutablePath = "C:\foreign\hermes.exe"
        $records[0].CommandLine = "C:\foreign\hermes.exe gateway run"
        [void](Assert-Throws {
            Assert-OwnedPortRecords -Records $records -HermesHome $ownedFixtureHome
        } 'owned|listener|port' "foreign listener is refused")
    } finally {
        if ($productOwner) { Exit-SetupLock -Lock $productOwner }
        if ($nextOwner) { Exit-SetupLock -Lock $nextOwner }
        if ($owner) { Exit-SetupLock -Lock $owner }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-TransactionRollback {
    foreach ($name in @(
        "Protect-AuditText", "Test-WindowsPlatform", "Get-IntegrationTaskNames", "Get-OwnedServiceProcessIds",
        "New-SetupTransaction", "Add-TransactionFileSnapshot",
        "Write-TransactionJournal", "Restore-TransactionFiles", "Complete-TransactionStorage",
        "Invoke-SetupRollback", "Complete-SetupTransaction"
    )) { Import-ProductFunction $setup $name }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-transaction-unit-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $existing = Join-Path $temp "existing.bin"
    $created = Join-Path $temp "created.bin"
    $original = [byte[]](0, 255, 17, 128, 42)
    [IO.File]::WriteAllBytes($existing, $original)
    $originalWriteTime = [DateTime]::SpecifyKind([DateTime]::new(2024, 1, 2, 3, 4, 5), [DateTimeKind]::Utc)
    [IO.File]::SetLastWriteTimeUtc($existing, $originalWriteTime)
    $transaction = New-SetupTransaction -ParentDirectory $temp
    try {
        Add-TransactionFileSnapshot -Transaction $transaction -Label "existing" -Path $existing
        Add-TransactionFileSnapshot -Transaction $transaction -Label "created" -Path $created
        [IO.File]::WriteAllBytes($existing, [byte[]](9, 8, 7))
        [IO.File]::SetLastWriteTimeUtc($existing, [DateTime]::UtcNow)
        [IO.File]::WriteAllText($created, "attempt residue")

        $script:firstHookRan = $false
        $script:secondHookRan = $false
        $result = Invoke-SetupRollback -Transaction $transaction -SkipNative -AdditionalRollback @(
            { $script:firstHookRan = $true; throw "synthetic token=DO-NOT-PERSIST" },
            { $script:secondHookRan = $true; throw "synthetic password=DO-NOT-PERSIST" }
        )

        Assert-True (-not $result.Complete) "synthetic rollback reports incomplete aggregation"
        Assert-True ($result.Failures.Count -eq 2) "rollback aggregates every independent failure (actual: $($result.Failures.Count); $($result.Failures -join ','))"
        Assert-True ($script:firstHookRan -and $script:secondHookRan) "rollback remains best-effort after a failure"
        Assert-True ([Linq.Enumerable]::SequenceEqual([byte[]]$original, [IO.File]::ReadAllBytes($existing))) `
            "rollback restores exact pre-mutation bytes"
        Assert-True ([IO.File]::GetLastWriteTimeUtc($existing).Ticks -eq $originalWriteTime.Ticks) `
            "rollback restores file metadata timestamps"
        Assert-True (-not (Test-Path -LiteralPath $created)) "rollback restores original file non-existence"
        Assert-True (Test-Path -LiteralPath $transaction.Directory) "incomplete rollback retains a recovery journal"
        Assert-True (Test-Path -LiteralPath $transaction.PayloadDirectory -PathType Container) `
            "incomplete rollback retains snapshot payloads required for recovery"
        Assert-True (@(Get-ChildItem -LiteralPath $transaction.PayloadDirectory -File).Count -gt 0) `
            "incomplete rollback keeps at least one preimage payload"
        $journal = [IO.File]::ReadAllText($transaction.Journal)
        Assert-True ($journal -notmatch 'DO-NOT-PERSIST|token=|password=') "transaction journal contains no injected secrets"
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $cleanTemp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-transaction-clean-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $cleanTemp | Out-Null
    $cleanFile = Join-Path $cleanTemp "clean.bin"
    [IO.File]::WriteAllText($cleanFile, "before")
    $cleanTransaction = New-SetupTransaction -ParentDirectory $cleanTemp
    try {
        Add-TransactionFileSnapshot -Transaction $cleanTransaction -Label "clean" -Path $cleanFile
        [IO.File]::WriteAllText($cleanFile, "after")
        $cleanResult = Invoke-SetupRollback -Transaction $cleanTransaction -SkipNative
        Assert-True $cleanResult.Complete "portable file rollback completes without native hooks"
        Assert-True ([IO.File]::ReadAllText($cleanFile) -eq "before") "complete rollback restores content"
        Assert-True (-not (Test-Path -LiteralPath $cleanTransaction.Directory)) "complete rollback removes its transaction directory"
    } finally {
        Remove-Item -LiteralPath $cleanTemp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $commitTemp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-transaction-commit-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $commitTemp | Out-Null
    $commitTransaction = New-SetupTransaction -ParentDirectory $commitTemp
    try {
        Complete-SetupTransaction -Transaction $commitTransaction
        Assert-True $commitTransaction.Committed "commit records the logical transaction boundary"
        Assert-True (-not (Test-Path -LiteralPath $commitTransaction.Directory)) `
            "successful commit removes its transaction directory"
    } finally {
        Remove-Item -LiteralPath $commitTemp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Native regression (observed on the Win11 validation VM): a failed attempt
    # left a never-bound Dashboard process alive after a "complete" rollback,
    # because quiescence only checked tasks and port listeners.
    Import-ProductFunction $setup "Stop-AttemptServiceProcesses"
    $sweepTemp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-sweep-native-" + [Guid]::NewGuid().ToString("N"))
    $fakeBin = Join-Path $sweepTemp "home\hermes-agent\venv\Scripts"
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    # The fixture must be self-contained: a bare pwsh.exe copy cannot start
    # without its .NET host siblings, so always use Windows PowerShell 5.1.
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") -Destination (Join-Path $fakeBin "python.exe")
    $fakeExe = Join-Path $fakeBin "python.exe"
    $global:InstallDir = Join-Path $sweepTemp "home\hermes-agent"
    $preExistingId = 0
    $orphanId = 0
    try {
        # Win32_Process.Create starts the fixtures outside this suite's own
        # Job Object (earlier native cases constrain Start-Process children).
        # Attribution is PID-based, not clock-based: Win32_Process.CreationDate
        # is null under PowerShell 7, so the baseline must predate the attempt.
        $preResult = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
            -Arguments @{ CommandLine = "`"$fakeExe`" -NoProfile -Command `"Start-Sleep 120`" # dashboard --host 127.0.0.1" }
        Assert-True ($preResult.ReturnValue -eq 0 -and $preResult.ProcessId -gt 0) "pre-existing synthetic process started"
        $preExistingId = [int]$preResult.ProcessId
        Start-Sleep -Seconds 2
        $sweepTx = New-SetupTransaction -ParentDirectory $sweepTemp
        $orphanResult = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
            -Arguments @{ CommandLine = "`"$fakeExe`" -NoProfile -Command `"Start-Sleep 120`" # dashboard --host 0.0.0.0" }
        Assert-True ($orphanResult.ReturnValue -eq 0 -and $orphanResult.ProcessId -gt 0) "attempt synthetic process started"
        $orphanId = [int]$orphanResult.ProcessId
        Start-Sleep -Seconds 2
        $sweepFailures = @(Stop-AttemptServiceProcesses -Transaction $sweepTx)
        Assert-True ($sweepFailures.Count -eq 0) "attempt process sweep reports no failures (actual: $($sweepFailures -join ','))"
        Assert-True (-not (Get-Process -Id $orphanId -ErrorAction SilentlyContinue)) "attempt-started owned service process is terminated"
        Assert-True ([bool](Get-Process -Id $preExistingId -ErrorAction SilentlyContinue)) "pre-attempt process of the same home is never killed"
    } finally {
        if ($preExistingId -gt 0) { Stop-Process -Id $preExistingId -Force -ErrorAction SilentlyContinue }
        if ($orphanId -gt 0) { Stop-Process -Id $orphanId -Force -ErrorAction SilentlyContinue }
        Remove-Variable -Name InstallDir -Scope Global -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $sweepTemp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $setupRaw = Get-Content -LiteralPath $SetupScript -Raw
    $protected = Protect-AuditText "primary failure token=DO-NOT-PERSIST password=DO-NOT-PERSIST"
    Assert-True ($protected -notmatch 'DO-NOT-PERSIST') "primary errors redact token and password values"
    $taskNames = @(Get-IntegrationTaskNames)
    Assert-True ($taskNames.Count -eq 5 -and @($taskNames | Select-Object -Unique).Count -eq 5) `
        "transaction contract contains exactly five distinct Scheduled Tasks"
    foreach ($label in @(
        "env", "bridge", "bridge_rollback", "runner_gateway", "runner_dashboard",
        "runner_bridge", "runner_restart_dashboard", "runner_restart_bridge",
        "pairing", "pairing_qr"
    )) {
        Assert-True ($setupRaw -match "(?m)^\s*${label}\s*=") "transaction snapshots $label before mutation"
    }
    Assert-True ($setupRaw -match 'Export-ScheduledTask' -and $setupRaw -match 'Register-ScheduledTask[^\r\n]+-Xml') `
        "native task rollback snapshots and restores exact XML"
    Assert-True ($setupRaw -match 'Restore-TransactionTasks' -and $setupRaw -match 'Start-ScheduledTask') `
        "native task rollback restores running state"
    Assert-True ($setupRaw -notmatch 'Startup fallback|warning-and-continue|remote restart will be unavailable') `
        "all five Scheduled Tasks are mandatory with no Startup fallback"
    Assert-True ($setupRaw -match 'New-NetFirewallRule\s+-Name\s+\$ruleName' -and
        $setupRaw -match 'Remove-NetFirewallRule\s+-Name\s+\$Transaction\.FirewallRuleName' -and
        $setupRaw -notmatch 'Get-NetFirewallRule[^\r\n]+DisplayName[^\r\n]+\|\s*Remove-NetFirewallRule') `
        "firewall rollback removes only the rule created by this attempt"
    Assert-True ($setupRaw -match 'Write-ServiceRunner[\s\S]+Write-AtomicBytes' -and
        $setupRaw -match '\$qrNew\s*=\s*\$AttemptPaths\.QrNew[\s\S]+Write-AtomicBytes\s+-Path\s+\$QrFile') `
        "runners and pairing QR publish from atomic staging"
    Assert-True ($setupRaw -match 'FileAttributes\]::ReparsePoint' -and
        $setupRaw -match 'SecurityDescriptor' -and $setupRaw -match 'LastWriteTimeUtc') `
        "transaction rejects filesystem links and snapshots security metadata"
    Assert-True ($setupRaw -match 'Get-FreshHermesInstallArtifacts' -and
        $setupRaw -match 'refusing to run the installer over it' -and
        $setupRaw -match 'Remove-FreshHermesInstallArtifacts') `
        "broken existing agent state is fail-closed and fresh installer failures are cleaned"
    Assert-True ($setupRaw -match 'Remove-EmptyAttemptDirectories' -and
        $setupRaw -match 'SetupDirectoryExistedAtStart') `
        "rollback removes only empty setup directories created by this attempt"
    # Credential provisioning precedes the Dashboard start (upstream refuses a
    # non-loopback bind without auth), so it cannot be post-commit; the product
    # must instead document the non-transactional residual explicitly.
    Assert-True ($setupRaw -match 'survives rollback|does not remove the credential') `
        "non-reversible credential provisioning is documented as surviving rollback"
}

function Test-FreshInstallCleanup {
    foreach ($name in @(
        "Get-FreshHermesInstallArtifacts", "Remove-FreshHermesInstallArtifacts", "Install-HermesIfNeeded"
    )) { Import-ProductFunction $setup $name }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-fresh-install-unit-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $global:HermesHome = $temp
        $global:InstallDir = Join-Path $temp "hermes-agent"
        $global:HermesBinDir = Join-Path $temp "bin"
        $global:AuditOnly = $false
        $global:AttemptPaths = [PSCustomObject]@{
            Installer = (Join-Path $temp "installer.ps1")
            InstallerOut = (Join-Path $temp "installer.stdout.log")
            InstallerErr = (Join-Path $temp "installer.stderr.log")
        }
        $script:MutationQuiescent = $true
        $script:HermesInstallTimeoutSeconds = 5
        $script:HermesAgentCommit = "0000000000000000000000000000000000000000"
        function global:Get-HermesExecutable { return $null }
        function global:Test-HermesLauncher { return $false }
        function global:Write-Audit {}
        function global:Write-Info {}
        function global:Get-PowerShellExecutable { return "synthetic-powershell" }
        function global:Save-VerifiedHermesAgentInstaller {
            param($Destination)
            [IO.File]::WriteAllText($Destination, "synthetic verified installer")
        }
        function global:Invoke-WebRequest {
            param($Uri, $OutFile, [switch]$UseBasicParsing)
            [IO.File]::WriteAllText($OutFile, "synthetic installer")
        }
        function global:Invoke-HiddenProcess {
            New-Item -ItemType Directory -Path $global:InstallDir, (Join-Path $global:HermesHome "node"), $global:HermesBinDir -Force | Out-Null
            foreach ($name in @("hermes.exe", "hermes.cmd", "hermes.ps1", "hermes", "uv.exe", "uvx.exe", "uv", "uvx")) {
                [IO.File]::WriteAllText((Join-Path $global:HermesBinDir $name), "attempt residue")
            }
            throw "synthetic installer failure"
        }

        [void](Assert-Throws { Install-HermesIfNeeded } 'synthetic installer failure' "fresh installer failure")
        foreach ($artifact in @(Get-FreshHermesInstallArtifacts)) {
            Assert-True (-not (Test-Path -LiteralPath $artifact)) "fresh failure removes $([IO.Path]::GetFileName($artifact))"
        }
        Assert-True (-not (Test-Path -LiteralPath $global:AttemptPaths.Installer)) "fresh failure removes downloaded installer"

        New-Item -ItemType Directory -Path $global:InstallDir -Force | Out-Null
        $marker = Join-Path $global:InstallDir "user-marker"
        [IO.File]::WriteAllText($marker, "retain")
        $script:installerInvocations = 0
        function global:Invoke-WebRequest { $script:installerInvocations++ }
        [void](Assert-Throws { Install-HermesIfNeeded } 'refusing to run the installer over it' "broken existing agent tree")
        Assert-True ((Test-Path -LiteralPath $marker) -and $script:installerInvocations -eq 0) `
            "broken existing tree is retained and installer is not invoked"
    } finally {
        foreach ($name in @(
            "Get-HermesExecutable", "Test-HermesLauncher", "Write-Audit", "Write-Info",
            "Get-PowerShellExecutable", "Save-VerifiedHermesAgentInstaller", "Invoke-WebRequest", "Invoke-HiddenProcess"
        )) { Remove-Item -LiteralPath "Function:\global:$name" -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-UpstreamInstallerPin {
    Import-ProductFunction $setup "Save-VerifiedHermesAgentInstaller"
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-upstream-pin-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $target = Join-Path $temp "install.ps1"
    try {
        $verifiedBytes = [Text.Encoding]::UTF8.GetBytes("synthetic verified installer")
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $script:HermesAgentInstallerSha256 = ([BitConverter]::ToString($sha.ComputeHash($verifiedBytes))).Replace("-", "").ToLowerInvariant()
        } finally { $sha.Dispose() }
        $script:HermesAgentInstallerSize = $verifiedBytes.Length
        $script:HermesAgentInstallerUrl = "https://example.invalid/immutable/install.ps1"
        function global:Invoke-WebRequest {
            param($Uri, $OutFile, [switch]$UseBasicParsing)
            [IO.File]::WriteAllBytes($OutFile, $verifiedBytes)
        }
        Save-VerifiedHermesAgentInstaller -Destination $target
        Assert-True ([IO.File]::ReadAllBytes($target).Length -eq $verifiedBytes.Length) "verified upstream installer is retained"

        function global:Invoke-WebRequest {
            param($Uri, $OutFile, [switch]$UseBasicParsing)
            [IO.File]::WriteAllText($OutFile, "tampered installer")
        }
        $message = Assert-Throws { Save-VerifiedHermesAgentInstaller -Destination $target } `
            'integrity verification failed' "tampered upstream installer"
        Assert-True (-not (Test-Path -LiteralPath $target)) "tampered upstream installer is deleted before execution"

        $raw = [IO.File]::ReadAllText($SetupScript)
        $commitMatch = [regex]::Match($raw, '(?m)^\$script:HermesAgentCommit\s*=\s*"([a-f0-9]{40})"')
        Assert-True $commitMatch.Success "Hermes Agent source is pinned to a full commit SHA"
        $commit = $commitMatch.Groups[1].Value
        Assert-True ($raw -match [regex]::Escape("raw.githubusercontent.com/NousResearch/hermes-agent/$commit/scripts/install.ps1")) `
            "upstream installer URL uses the exact pinned commit"
        Assert-True ($raw -match '(?m)^\$script:HermesAgentInstallerSha256\s*=\s*"[a-f0-9]{64}"' -and
            $raw -match '(?m)^\$script:HermesAgentInstallerSize\s*=\s*\d+') `
            "upstream installer bytes have pinned digest and size"
        Assert-True ($raw -match 'Save-VerifiedHermesAgentInstaller[\s\S]+-Commit\s+\$\(\$script:HermesAgentCommit\)' -and
            $raw -match '-Json') "verified installer pins installed source and requests structured failure status"
        Assert-True ($raw -notmatch 'Invoke-WebRequest\s+-Uri\s+"https://hermes-agent\.nousresearch\.com/install\.ps1"') `
            "setup never executes the mutable upstream installer endpoint"
    } finally {
        Remove-Item -LiteralPath "Function:\global:Invoke-WebRequest" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-PlatformSupport {
    Import-ProductFunction $setup "Test-WindowsPlatform"
    Import-ProductFunction $setup "Assert-SupportedWindows"
    $oldOs = $env:OS
    $oldArch = $env:PROCESSOR_ARCHITECTURE
    $oldWowArch = $env:PROCESSOR_ARCHITEW6432
    try {
        $env:OS = "Windows_NT"
        $env:PROCESSOR_ARCHITECTURE = "AMD64"
        $env:PROCESSOR_ARCHITEW6432 = $null
        $script:SyntheticOs = [PSCustomObject]@{
            ProductType = 1
            Caption = "Microsoft Windows 11 Pro"
            Version = "10.0.22631"
            BuildNumber = "22631"
        }
        function global:Get-CimInstance { return $script:SyntheticOs }
        Assert-SupportedWindows
        Assert-True $true "Windows 11 x64 is accepted"

        $env:PROCESSOR_ARCHITECTURE = "ARM64"
        $script:SyntheticOs.Caption = "Microsoft Windows 10 Pro"
        $script:SyntheticOs.BuildNumber = "19045"
        Assert-SupportedWindows
        Assert-True $true "Windows 10 ARM64 is accepted"

        $script:SyntheticOs.ProductType = 3
        $script:SyntheticOs.Caption = "Microsoft Windows Server 2025 Datacenter"
        $script:SyntheticOs.Version = "10.0.26100"
        $script:SyntheticOs.BuildNumber = "26100"
        $env:PROCESSOR_ARCHITECTURE = "AMD64"
        Assert-SupportedWindows
        Assert-True $true "Windows Server (server product type) is accepted"

        $script:SyntheticOs.ProductType = 2
        $script:SyntheticOs.Caption = "Microsoft Windows Server 2022 Datacenter"
        $script:SyntheticOs.Version = "10.0.20348"
        $script:SyntheticOs.BuildNumber = "20348"
        Assert-SupportedWindows
        Assert-True $true "Windows Server (domain controller product type) is accepted"

        $script:SyntheticOs.ProductType = 3
        $script:SyntheticOs.Caption = "Microsoft Windows 10 Pro"
        $script:SyntheticOs.Version = "10.0.19045"
        $script:SyntheticOs.BuildNumber = "19045"
        $env:PROCESSOR_ARCHITECTURE = "IA64"
        $env:PROCESSOR_ARCHITEW6432 = $null
        $message = Assert-Throws { Assert-SupportedWindows } `
            'supports Windows 10, Windows 11 and Windows Server \(x64 or ARM64\).*Detected: Microsoft Windows 10 Pro, version 10\.0\.19045, build 19045, unknown.*No changes were made' `
            "unknown architecture is rejected clearly"
        Assert-True ($message -notmatch 'exception|stack|json|package') "unsupported-platform message contains no implementation noise"
        $script:SyntheticOs.ProductType = 1
        $env:PROCESSOR_ARCHITECTURE = "AMD64"
        Assert-SupportedWindows
        Assert-True $true "supported configuration is re-checked after a rejection"

        $script:SyntheticOs.ProductType = 1
        $script:SyntheticOs.Caption = "Microsoft Windows 8.1 Pro"
        $script:SyntheticOs.Version = "6.3.9600"
        $script:SyntheticOs.BuildNumber = "9600"
        [void](Assert-Throws { Assert-SupportedWindows } 'supports Windows 10, Windows 11 and Windows Server' "legacy Windows is rejected clearly")

        $script:SyntheticOs.Caption = "Microsoft Windows 11 Pro"
        $script:SyntheticOs.Version = "10.0.22631"
        $script:SyntheticOs.BuildNumber = "22631"
        $env:PROCESSOR_ARCHITECTURE = "x86"
        [void](Assert-Throws { Assert-SupportedWindows } 'x64 or ARM64.*Detected:.*x86' "32-bit Windows is rejected clearly")

        function global:Get-CimInstance { throw "synthetic CIM failure" }
        [void](Assert-Throws { Assert-SupportedWindows } `
            'could not verify the Windows version.*supports Windows 10, Windows 11 and Windows Server.*No changes were made' `
            "unverifiable Windows fails closed clearly")

        $raw = [IO.File]::ReadAllText($SetupScript)
        $preflight = $raw.LastIndexOf("`nAssert-SupportedWindows")
        $lock = $raw.LastIndexOf("`n`$SetupLockHandle = Enter-SetupLock")
        Assert-True ($preflight -ge 0 -and $lock -gt $preflight) "Windows support preflight runs before setup lock or mutation"
    } finally {
        $env:OS = $oldOs
        $env:PROCESSOR_ARCHITECTURE = $oldArch
        $env:PROCESSOR_ARCHITEW6432 = $oldWowArch
        Remove-Item -LiteralPath "Function:\global:Get-CimInstance" -Force -ErrorAction SilentlyContinue
    }
}

function Test-ProcessDiagnostics {
    Import-ProductFunction $setup "Invoke-HiddenProcess"
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-process-diagnostics-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $out = Join-Path $temp "installer.out.log"
    $err = Join-Path $temp "installer.err.log"
    try {
        [IO.File]::WriteAllText($out, "installer progress that is not an error")
        [IO.File]::WriteAllText($err, "+ ruamel-yaml==0.18.17 + six==1.17.0 + sniffio==1.3.1 + websockets==15.0.1 + youtube-transcript-api==1.2.4")
        $script:TerminationTimeoutSeconds = 5
        function global:Invoke-ContainedProcess {
            return [PSCustomObject]@{ ExitCode = 23; TimedOut = $false }
        }

        $message = Assert-Throws {
            Invoke-HiddenProcess -File "synthetic-installer" -Arguments "" -TimeoutSeconds 5 `
                -StdoutPath $out -StderrPath $err -Operation "Hermes Agent installer"
        } 'Hermes Agent installer failed \(exit code 23\)' "failed installer diagnostic"
        Assert-True ($message -notmatch 'Hidden process|ruamel|sniffio|websockets|youtube-transcript|installer progress') `
            "failed installer never dumps dependency progress or implementation jargon into the console"
    } finally {
        Remove-Item -LiteralPath "Function:\global:Invoke-ContainedProcess" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-ServiceRunnerEncoding {
    foreach ($name in @("Write-AtomicBytes", "Write-ServiceRunner")) {
        Import-ProductFunction $setup $name
    }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-runner-encoding-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $hadServicesDir = Test-Path "Variable:global:ServicesDir"
    $oldServicesDir = if ($hadServicesDir) { $global:ServicesDir } else { $null }
    $hadAuditOnly = Test-Path "Variable:global:AuditOnly"
    $oldAuditOnly = if ($hadAuditOnly) { $global:AuditOnly } else { $null }
    $hadAttemptId = Test-Path "Variable:global:AttemptId"
    $oldAttemptId = if ($hadAttemptId) { $global:AttemptId } else { $null }
    try {
        $global:ServicesDir = $temp
        $global:AuditOnly = $false
        $global:AttemptId = "runner-encoding"
        $script:RunnerChanged = @{}
        $content = "' Unicode runner: cafe ??`r`nWScript.Quit 0`r`n"
        $path = Write-ServiceRunner -Name "synthetic-runner" -Content $content
        $bytes = [IO.File]::ReadAllBytes($path)
        Assert-True ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) `
            "VBS runner is written as UTF-16LE with a BOM for Windows Script Host"
        Assert-True ([IO.File]::ReadAllText($path) -eq $content) `
            "runner content round-trips through the same BOM-aware reader used for idempotence"

        $script:RunnerChanged = @{}
        [void](Write-ServiceRunner -Name "synthetic-runner" -Content $content)
        Assert-True ($script:RunnerChanged["synthetic-runner"] -eq $false) `
            "unchanged BOM runner is retained instead of rewritten on rerun"
    } finally {
        if ($hadServicesDir) { $global:ServicesDir = $oldServicesDir } else { Remove-Variable -Scope Global -Name ServicesDir -ErrorAction SilentlyContinue }
        if ($hadAuditOnly) { $global:AuditOnly = $oldAuditOnly } else { Remove-Variable -Scope Global -Name AuditOnly -ErrorAction SilentlyContinue }
        if ($hadAttemptId) { $global:AttemptId = $oldAttemptId } else { Remove-Variable -Scope Global -Name AttemptId -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-NativeJob {
    $nativeWindows = $env:OS -eq "Windows_NT"
    if (-not $nativeWindows) {
        Write-Skip "Windows Job Object lifecycle requires native Windows; Linux parser/unit results are not lifecycle evidence"
        return
    }
    foreach ($name in @(
        "Test-WindowsPlatform", "Initialize-WindowsJobApi", "Invoke-ContainedProcess",
        "Test-HermesLauncher", "Enter-SetupLock", "Exit-SetupLock"
    )) {
        Import-ProductFunction $setup $name
    }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-native-job-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $rootScript = Join-Path $temp "root.ps1"
    $childScript = Join-Path $temp "child.ps1"
    $heartbeat = Join-Path $temp "heartbeat.txt"
    $out = Join-Path $temp "out.log"
    $err = Join-Path $temp "err.log"
    $lockName = "HermesNativeJob-" + [Guid]::NewGuid().ToString("N")
    $lock = $null
    [IO.File]::WriteAllText($childScript, 'param($Path); 1..150 | ForEach-Object { [IO.File]::AppendAllText($Path,"x"); Start-Sleep -Milliseconds 100 }')
    [IO.File]::WriteAllText($rootScript, @'
param($Child, $Heartbeat)
$hostExe = (Get-Process -Id $PID).Path
Start-Process -FilePath $hostExe -ArgumentList @("-NoProfile","-File","`"$Child`"","-Path","`"$Heartbeat`"") | Out-Null
Start-Sleep -Seconds 15
'@)
    try {
        $global:HermesHome = $temp
        $script:TerminationTimeoutSeconds = 5
        $hostExe = (Get-Process -Id $PID).Path
        $arguments = "-NoLogo -NoProfile -File `"$rootScript`" -Child `"$childScript`" -Heartbeat `"$heartbeat`""
        $script:MutationQuiescent = $true
        $lock = Enter-SetupLock -Name $lockName -TimeoutMilliseconds 100
        $message = Assert-Throws {
            Invoke-ContainedProcess -File $hostExe -Arguments $arguments -TimeoutSeconds 2 `
                -TerminationTimeoutSeconds 5 -StdoutPath $out -StderrPath $err
        } 'terminated.*verified|verified.*quiescent' "timed-out contained process"
        Assert-True $script:MutationQuiescent "verified Job Object termination permits later lock release"
        $before = if (Test-Path $heartbeat) { (Get-Item $heartbeat).Length } else { 0 }
        Start-Sleep -Milliseconds 800
        $after = if (Test-Path $heartbeat) { (Get-Item $heartbeat).Length } else { 0 }
        Assert-True ($before -eq $after) "descendant cannot keep mutating after verified timeout containment"

        Exit-SetupLock -Lock $lock
        $lock = $null
        $afterTimeoutLock = Enter-SetupLock -Name $lockName -TimeoutMilliseconds 100
        Assert-True ($null -ne $afterTimeoutLock) "lock becomes acquirable only after verified Job Object quiescence"
        Exit-SetupLock -Lock $afterTimeoutLock

        $healthyExe = Join-Path $temp "synthetic-hermes.exe"
        $brokenExe = Join-Path $temp "synthetic-broken-hermes.exe"
        $healthySource = 'public static class SyntheticHermes { public static int Main(string[] a) { return a.Length == 1 && a[0] == "--version" ? 0 : 9; } }'
        $brokenSource = 'public static class SyntheticBrokenHermes { public static int Main(string[] a) { return 42; } }'
        if ($PSVersionTable.PSEdition -eq "Core") {
            $compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
            if (-not (Test-Path -LiteralPath $compiler)) {
                throw "Windows C# compiler is unavailable for the native executable fixture."
            }
            $healthyCs = Join-Path $temp "synthetic-hermes.cs"
            $brokenCs = Join-Path $temp "synthetic-broken-hermes.cs"
            Set-Content -LiteralPath $healthyCs -Value $healthySource -Encoding Ascii
            Set-Content -LiteralPath $brokenCs -Value $brokenSource -Encoding Ascii
            & $compiler /nologo /target:exe "/out:$healthyExe" $healthyCs
            if ($LASTEXITCODE -ne 0) { throw "Failed to compile the healthy native fixture." }
            & $compiler /nologo /target:exe "/out:$brokenExe" $brokenCs
            if ($LASTEXITCODE -ne 0) { throw "Failed to compile the broken native fixture." }
        } else {
            Add-Type -TypeDefinition $healthySource -Language CSharp -OutputAssembly $healthyExe -OutputType ConsoleApplication
            Add-Type -TypeDefinition $brokenSource -Language CSharp -OutputAssembly $brokenExe -OutputType ConsoleApplication
        }
        Assert-True (Test-HermesLauncher $healthyExe 5) "native synthetic Hermes launcher --version succeeds through the Job Object"
        Assert-True (-not (Test-HermesLauncher $brokenExe 5)) "native synthetic broken launcher is not reported healthy"
    } finally {
        if ($lock) { Exit-SetupLock -Lock $lock }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-TopLevelTimeouts {
    # Regression (observed natively on Windows 11 25H2 build 26200, PS 5.1):
    # the product params are declared [string] and keep that type constraint
    # for the whole run, so the validated Int32 from Get-BoundedIntegerParameter
    # is coerced back to string on assignment. Call sites that multiply the
    # timeout must cast explicitly; otherwise "30" * 1000 repeats the string
    # and Enter-SetupLock argument binding fails with an oversized value.
    # This test rebuilds the product's real top level (param block, validator,
    # conversion lines, call-site expressions) in a child file so the coercion
    # semantics match production exactly; in-function emulation would shadow.
    $paramBlock = $setup.Ast.ParamBlock
    Assert-True ($null -ne $paramBlock) "product declares a param block"
    $validator = Find-Function $setup.Ast "Get-BoundedIntegerParameter"
    Assert-True ($null -ne $validator) "product defines Get-BoundedIntegerParameter"

    $conversions = [regex]::Matches($setup.Source, '(?m)^\$(?:InstallerTimeoutSec|TerminationTimeoutSec|LockTimeoutSec) = Get-BoundedIntegerParameter[^\r\n]*\r?$')
    Assert-True ($conversions.Count -eq 3) "top level validates all three timeout params through Get-BoundedIntegerParameter"

    $lockCall = [regex]::Match($setup.Source, 'Enter-SetupLock\s+-Name\s+\$SetupLockName\s+-TimeoutMilliseconds\s+\(([^)]+)\)')
    Assert-True $lockCall.Success "top-level Enter-SetupLock call site found"

    $storedLines = [regex]::Matches($setup.Source, '(?m)^\$script:(?:HermesInstallTimeoutSeconds|TerminationTimeoutSeconds) = [^\r\n]*\r?$')
    Assert-True ($storedLines.Count -eq 2) "top level stores install/termination timeouts in script variables"

    $body = New-Object System.Collections.Generic.List[string]
    $body.Add($paramBlock.Extent.Text)
    $body.Add($validator.Extent.Text)
    foreach ($line in $conversions) { $body.Add($line.Value) }
    foreach ($line in $storedLines) { $body.Add($line.Value) }
    $body.Add('$__ms = (' + $lockCall.Groups[1].Value + ')')
    $body.Add('if ($__ms -is [int] -and $__ms -ge 0 -and $__ms -le 600000) { Write-Output "LOCK:INT:$__ms" } else { Write-Output "LOCK:BAD:" + $__ms.GetType().Name }')
    $body.Add('foreach ($__v in @($script:HermesInstallTimeoutSeconds, $script:TerminationTimeoutSeconds)) { if ($__v -is [int]) { Write-Output "STORED:INT:$__v" } else { Write-Output "STORED:BAD:" + $__v.GetType().Name } }')

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-toplevel-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $fragmentFile = Join-Path $temp "toplevel-fragment.ps1"
    try {
        [IO.File]::WriteAllText($fragmentFile, ($body -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
        $hostExe = (Get-Process -Id $PID).Path
        $run = Invoke-ChildProcessCapture $hostExe @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $fragmentFile)
        $output = @($run.Output | ForEach-Object { [string]$_ })
        Assert-True ($run.ExitCode -eq 0) "rebuilt top level executes cleanly (actual: $($output -join ' | '))"
        Assert-True (($output -match '^LOCK:INT:30000$').Count -eq 1) "lock timeout milliseconds evaluate to Int32 30000, not a repeated string (actual: $($output -join ' | '))"
        Assert-True (($output -match '^STORED:INT:').Count -eq 2) "install/termination timeouts stored as Int32, not coerced strings (actual: $($output -join ' | '))"
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-PreflightDiagnose {
    # Preflight: read-only checklist. Diagnose: redacted support bundle. Neither
    # may take the setup lock, mutate a target home, or leak credentials.
    Import-ProductFunction $setup "New-PreflightCheck"
    Import-ProductFunction $setup "Protect-AuditText"
    Import-ProductFunction $setup "Resolve-HermesHome"
    Import-ProductFunction $setup "Invoke-SetupPreflight"
    Import-ProductFunction $setup "Protect-DiagnosticText"
    Import-ProductFunction $setup "Invoke-SetupDiagnose"
    # Environment dependencies are stubbed: this case asserts the preflight and
    # diagnostic contracts (bounded output, no mutation, redaction), not the
    # host inventory those helpers collect. Earlier cases leave global stubs
    # behind (synthetic CIM, synthetic web requests), so define our own.
    function global:Assert-SupportedWindows { }
    # Los puertos se resuelven en el nivel superior del producto; aqui se fijan a
    # los mismos defaults para que los helpers importados tengan su entorno.
    $script:GatewayPort = 8642
    $script:DashboardPort = 9119
    $script:BridgePort = 9131
    function global:Get-CimInstance {
        param($ClassName, $Filter, $ErrorAction)
        if ($ClassName -eq "Win32_LogicalDisk") {
            return [PSCustomObject]@{ FreeSpace = 200GB; DeviceID = "C:" }
        }
        return [PSCustomObject]@{
            Caption = "Microsoft Windows 11 Pro"
            BuildNumber = "26200"
            OSArchitecture = "64-bit"
            Version = "10.0.26200"
            ProductType = 1
        }
    }
    function global:Invoke-WebRequest {
        param($Uri, $Method, [switch]$UseBasicParsing, $TimeoutSec, $OutFile)
        return [PSCustomObject]@{ StatusCode = 200 }
    }
    function global:Get-HermesExecutable { return $null }
    function global:Test-HermesLauncher { param($Executable, $TimeoutSeconds) return $false }
    function global:Get-PortOwner { param($Port) return $null }
    function global:Get-ExistingHermesPortRecords { return @() }
    function global:Assert-OwnedPortRecords { param($Records, $HermesHome) return }
    function global:Get-PairingConfiguration {
        return @{ Scheme = "https"; Address = "hermes.example.ts.net"; Port = 443; Kind = "mesh"; InterfaceIndex = $null }
    }
    function global:Get-IntegrationTaskNames { return @("HermesConsole-Gateway") }
    function global:Invoke-SetupInventory {
        return [PSCustomObject]@{ ready = $false; missing = @("stub item"); audit = "stub"; qr = $null }
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-preflight-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $fixtureHome = Join-Path $temp "home"
    $oldHome = $env:HERMES_HOME
    $oldRaw = $env:HERMES_REPO_RAW
    $global:HermesHome = $fixtureHome
    $global:AuditDir = Join-Path $fixtureHome "audit"
    $global:AuditLog = Join-Path $global:AuditDir "safe-setup-audit.jsonl"
    $global:LogsDir = Join-Path $fixtureHome "logs"
    $global:InstallDir = Join-Path $fixtureHome "hermes-agent"
    $global:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        # A canary that must never reach any diagnostic output.
        New-Item -ItemType Directory -Force -Path $global:AuditDir, $global:LogsDir | Out-Null
        $canary = "CANARY-SECRET-0123456789abcdef"
        [IO.File]::WriteAllText((Join-Path $fixtureHome ".env"), "API_SERVER_KEY=$canary`r`n")
        [IO.File]::WriteAllText((Join-Path $global:LogsDir "gateway.log"),
            "Authorization: Bearer $canary`r`nlink hermes://pair?host=10.0.0.5&token=$canary`r`n", $global:Utf8NoBom)
        [IO.File]::WriteAllText($global:AuditLog,
            ('{"step":"x","state":"OK","detail":"token=' + $canary + '"}' + [Environment]::NewLine), $global:Utf8NoBom)

        # Protect-DiagnosticText removes bearers, key values and pairing links.
        $redacted = Protect-DiagnosticText "Authorization: Bearer $canary and API_SERVER_KEY=$canary and hermes://pair?host=10.0.0.5&token=$canary"
        Assert-True ($redacted -notmatch [regex]::Escape($canary)) "diagnostic redaction removes tokens and pairing links"

        # Preflight: bounded checklist output and no target-home mutation.
        # Write-Host emits on the information stream in PS 5.0+, so capture 6>&1.
        $output = @(& { Invoke-SetupPreflight } 6>&1 2>&1 | ForEach-Object { [string]$_ })
        $joined = $output -join "`n"
        Assert-True ($joined -match '\[(PASS|FAIL|WARN)\] Windows edition') "preflight reports a bounded edition check"
        Assert-True ($joined -match '"ok":(true|false)') "preflight prints a machine-readable summary"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureHome "console-services"))) `
            "preflight performs no service-directory mutation"

        # Diagnose: writes one report containing no secret material.
        $report = Invoke-SetupDiagnose
        Assert-True (Test-Path -LiteralPath $report) "diagnose writes a report"
        $text = Get-Content -LiteralPath $report -Raw
        Assert-True ($text -match 'setup_script_sha256') "diagnose records the setup identity"
        Assert-True ($text -match '== Scheduled tasks ==') "diagnose includes service state sections"
        Assert-True ($text -notmatch [regex]::Escape($canary)) "diagnose report contains no bearer, API key or pairing token"
    } finally {
        $env:HERMES_HOME = $oldHome
        $env:HERMES_REPO_RAW = $oldRaw
        foreach ($name in @("HermesHome", "AuditDir", "AuditLog", "LogsDir", "InstallDir")) {
            Remove-Variable -Name $name -Scope Global -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-ServicePorts {
    # Los puertos dejan de estar fijos: se resuelven del entorno con defaults
    # historicos, se rechaza una colision y todo consumidor los usa resueltos.
    $setupRaw = Get-Content -LiteralPath $SetupScript -Raw
    foreach ($item in @(
        @{ Name = "HERMES_GATEWAY_PORT"; Default = "8642"; Variable = "GatewayPort" },
        @{ Name = "HERMES_DASHBOARD_PORT"; Default = "9119"; Variable = "DashboardPort" },
        @{ Name = "HERMES_BRIDGE_PORT"; Default = "9131"; Variable = "BridgePort" }
    )) {
        $pattern = '\$' + $item.Variable + '\s*=\s*Get-BoundedIntegerParameter\s+"' + $item.Name + '"'
        Assert-True ($setupRaw -match $pattern) "$($item.Name) is resolved through the bounded parser"
        Assert-True ($setupRaw -match ('"' + $item.Name + '"[^\r\n]*else\s*\{\s*"' + $item.Default + '"\s*\}')) `
            "$($item.Name) keeps $($item.Default) as its documented default"
    }
    Assert-True ($setupRaw -match 'must be three different ports') "a port collision is refused before any change"
    # Los runners y la regla de firewall no pueden volver a fijar literales.
    Assert-True ($setupRaw -match '__GATEWAY_PORT__' -and $setupRaw -match '__DASHBOARD_PORT__' -and $setupRaw -match '__BRIDGE_PORT__') `
        "generated service runners take the ports from placeholders"
    Assert-True ($setupRaw -match 'Replace\("__BRIDGE_PORT__", "\$BridgePort"\)') "the bridge runner substitutes its resolved port"
    Assert-True ($setupRaw -match '-LocalPort @\(\$GatewayPort, \$DashboardPort, \$BridgePort\)') `
        "the firewall rule opens exactly the three resolved ports"
    Assert-True ($setupRaw -match '\$requiredPorts = @\("\$GatewayPort", "\$DashboardPort", "\$BridgePort"\)') `
        "the firewall rule is verified against the same resolved ports"
    Assert-True ($setupRaw -notmatch '"http://127\.0\.0\.1:8642"' -and $setupRaw -notmatch 'LocalPort 8642') `
        "no consumer keeps a hardcoded service port"
    # El rechazo es real y temprano: se ejecuta el script con dos puertos iguales.
    $exe = (Get-Process -Id $PID).Path
    $oldGateway = $env:HERMES_GATEWAY_PORT
    try {
        $env:HERMES_GATEWAY_PORT = "9119"
        # El hijo escribe el rechazo por stderr y la suite corre con
        # ErrorActionPreference Stop: se captura explicitamente para que un
        # stderr esperado no se convierta en un fallo del arnes.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = @(& $exe -NoProfile -ExecutionPolicy Bypass -File $SetupScript -Preflight 2>&1 |
                ForEach-Object { [string]$_ })
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $joined = $output -join "`n"
        # El hijo sale 1 a proposito (es el rechazo que se valida); sin esto el
        # codigo del hijo se propaga como salida de la suite entera.
        $global:LASTEXITCODE = 0
        Assert-True ($joined -match 'must be three different ports') "a duplicated port stops the run with a bounded reason"
        Assert-True ($joined -notmatch 'Adding the firewall rule') "the collision is refused before any mutation phase"
    } finally {
        if ($null -eq $oldGateway) { Remove-Item Env:HERMES_GATEWAY_PORT -ErrorAction SilentlyContinue }
        else { $env:HERMES_GATEWAY_PORT = $oldGateway }
    }
}

function Test-AdaptiveWait {
    # El primer arranque puede tardar mas que el presupuesto: mientras la tarea
    # siga corriendo hay progreso real y la espera se extiende; si la tarea murio
    # falla acotada, y si sigue viva pero nada responde se corta en el techo.
    Import-ProductFunction $setup "Wait-HermesService"
    Import-ProductFunction $setup "Test-ProgressHolder"
    $script:auditLines = New-Object System.Collections.Generic.List[string]
    $script:probeCount = 0
    $script:holderAlive = $true
    $script:probeThreshold = 7
    function global:Write-Audit { param($Step, $State, $Detail) [void]$script:auditLines.Add("$Step|$State|$Detail") }
    function global:Test-HermesService {
        param($Kind, $BaseUrl, $Token, $ExpectedVersion, [switch]$PhoneFacing)
        $script:probeCount++
        return ($script:probeCount -ge $script:probeThreshold)
    }
    function global:Test-ProgressHolder { param([string]$TaskName) return $script:holderAlive }

    # A) Progreso real: el servicio responde despues del presupuesto base y la
    #    espera se extiende en lugar de fallar.
    $script:probeCount = 0
    $script:holderAlive = $true
    $script:probeThreshold = 7
    $ok = Wait-HermesService "dashboard" "http://127.0.0.1:9119" "token" 1 "" -ExtendWhileTaskRunning "HermesConsole-Dashboard" -MaxSeconds 30
    Assert-True $ok "the wait extends past the base budget while the service task is still running"
    Assert-True ($script:probeCount -ge 7) "the extension keeps polling until the service answers"

    # B) Sin progreso (la tarea ya no corre): falla en el presupuesto base.
    $script:probeCount = 0
    $script:holderAlive = $false
    $script:probeThreshold = [int]::MaxValue
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $dead = Wait-HermesService "dashboard" "http://127.0.0.1:9119" "token" 1 "" -ExtendWhileTaskRunning "HermesConsole-Dashboard" -MaxSeconds 30
    $deadElapsed = $watch.Elapsed.TotalSeconds
    Assert-True (-not $dead) "a dead service task fails instead of waiting to the ceiling"
    Assert-True ($deadElapsed -lt 10) "the failure stays bounded by the base budget ($([int]$deadElapsed)s)"

    # C) Tarea viva pero el servicio nunca responde: se corta en el techo.
    $script:probeCount = 0
    $script:holderAlive = $true
    $script:probeThreshold = [int]::MaxValue
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $ceiling = Wait-HermesService "dashboard" "http://127.0.0.1:9119" "token" 1 "" -ExtendWhileTaskRunning "HermesConsole-Dashboard" -MaxSeconds 4
    $ceilingElapsed = $watch.Elapsed.TotalSeconds
    Assert-True (-not $ceiling) "the extension stops at the ceiling instead of hanging forever"
    Assert-True ($ceilingElapsed -ge 3 -and $ceilingElapsed -lt 12) "the ceiling is honoured ($([int]$ceilingElapsed)s)"
    Assert-True (($script:auditLines -join "`n") -match 'readiness') "the wait keeps an explicit audit trail"

    $setupRaw = Get-Content -LiteralPath $SetupScript -Raw
    Assert-True ($setupRaw -match 'Still starting \(' -and $setupRaw -match 'extended to \$\{MaxSeconds\}s') `
        "the extension writes an explicit trail in the audit log"
    Assert-True ($setupRaw -match 'ExtendWhileTaskRunning "HermesConsole-Dashboard" -MaxSeconds 1800') `
        "the Dashboard readiness budget is extended only while its canonical task runs"
}

function Test-AddressCandidates {
    # La primera direccion privada no siempre alcanza el movil: el setup debe
    # tener una lista ordenada y adoptar la primera que responde de verdad.
    foreach ($name in @("Get-ReachableHostCandidates", "Get-ReachableHost", "Test-PrivateIpv4", "Test-Cgnat")) {
        Import-ProductFunction $setup $name
    }
    # Delegar en el cmdlet real salvo para tailscale: un stub que devuelve $null
    # para todo deja sin efecto a los demas casos y al propio despachador.
    function global:Get-Command {
        param($Name, $ErrorAction, [switch]$CommandType)
        if ($Name -like "*tailscale*") { return $null }
        return Microsoft.PowerShell.Core\Get-Command $Name
    }
    function global:Get-NetIPAddress {
        param($AddressFamily, $ErrorAction)
        return @(
            [PSCustomObject]@{ IPAddress = "127.0.0.1"; InterfaceAlias = "Loopback"; InterfaceIndex = 1; AddressState = "Preferred"; PrefixLength = 8 },
            [PSCustomObject]@{ IPAddress = "172.19.240.1"; InterfaceAlias = "vEthernet (WSL)"; InterfaceIndex = 9; AddressState = "Preferred"; PrefixLength = 20 },
            [PSCustomObject]@{ IPAddress = "192.168.10.55"; InterfaceAlias = "Ethernet"; InterfaceIndex = 5; AddressState = "Preferred"; PrefixLength = 24 },
            [PSCustomObject]@{ IPAddress = "10.20.30.40"; InterfaceAlias = "Ethernet 2"; InterfaceIndex = 6; AddressState = "Preferred"; PrefixLength = 24 }
        )
    }
    Remove-Item Env:HERMES_PAIR_HOST -ErrorAction SilentlyContinue
    $candidates = @(Get-ReachableHostCandidates)
    $addresses = @($candidates | ForEach-Object { $_.Address })
    Assert-True ($addresses.Count -ge 2) "a multi-homed host yields more than one candidate"
    Assert-True (-not ($addresses -contains "127.0.0.1")) "loopback is never a phone-facing candidate"
    Assert-True (-not ($addresses -contains "172.19.240.1")) "virtual adapters are deprioritised out of the candidate list"
    Assert-True ($addresses[0] -in @("192.168.10.55", "10.20.30.40")) "the first candidate is a real private address"
    $chosen = Get-ReachableHost
    Assert-True ($chosen.Address -eq $addresses[0] -and $chosen.Kind -eq "lan") "the default host stays the first candidate as before"

    $setupRaw = Get-Content -LiteralPath $SetupScript -Raw
    Assert-True ($setupRaw -match 'Reachable address adopted') "the installer adopts a reachable candidate explicitly"
    Assert-True ($setupRaw -match 'Get-PairingConfiguration -HostOverride') "alternate candidates are built through the explicit host override"
    Assert-True ($setupRaw -match 'candidateAddresses\[0\.\.2\]') "the candidate sweep is bounded to at most three addresses"
    Assert-True ($setupRaw -match 'Ensure-PrivateFirewallRules \$Pairing') "the firewall rule is re-verified when the address kind changes"
    Assert-True ($setupRaw -match 'works locally but not through') "the bounded failure keeps its actionable wording"
}

function Test-Uninstall {
    # -Uninstall solo toca lo que el instalador crea, es idempotente y -Purge
    # jamas borra una ruta que no sea un home de Hermes Console.
    Import-ProductFunction $setup "Invoke-SetupUninstall"
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("hermes-uninstall-" + [Guid]::NewGuid().ToString("N"))
    [void](New-Item -ItemType Directory -Force -Path $temp)
    $script:unregistered = New-Object System.Collections.Generic.List[string]
    $script:removedRules = New-Object System.Collections.Generic.List[string]
    $script:auditLines = New-Object System.Collections.Generic.List[string]
    function global:Assert-SupportedWindows { }
    function global:Write-Audit { param($Step, $State, $Detail) [void]$script:auditLines.Add("$State|$Detail") }
    function global:Get-ScheduledTask {
        param([string]$TaskName, $ErrorAction)
        if ($TaskName) { return $null }
        return @(
            [PSCustomObject]@{ TaskName = "HermesConsole-Gateway" },
            [PSCustomObject]@{ TaskName = "HermesConsole-Dashboard" },
            [PSCustomObject]@{ TaskName = "OtroProducto-Updater" }
        )
    }
    function global:Stop-ScheduledTask { param([string]$TaskName, $ErrorAction) }
    function global:Unregister-ScheduledTask { param([string]$TaskName, [switch]$Confirm, $ErrorAction) $script:unregistered.Add($TaskName) }
    function global:Get-NetFirewallRule {
        param([string]$Name, $ErrorAction)
        return @(
            [PSCustomObject]@{ Name = "HermesConsole-abc123" },
            [PSCustomObject]@{ Name = "OtraAplicacion-xyz" }
        )
    }
    function global:Remove-NetFirewallRule { param([string]$Name, $ErrorAction) $script:removedRules.Add($Name) }

    $global:AuditDir = $temp
    $global:HermesHome = Join-Path $temp "Hermes Console"
    [void](New-Item -ItemType Directory -Force -Path $global:HermesHome)
    [IO.File]::WriteAllText((Join-Path $global:HermesHome "hermes-pairing.json"), "{}")
    $global:PairingFile = Join-Path $global:HermesHome "hermes-pairing.json"
    $global:QrFile = Join-Path $global:HermesHome "hermes-pair.png"
    [IO.File]::WriteAllBytes($global:QrFile, [byte[]](1, 2, 3))
    $global:Purge = $false

    $result = Invoke-SetupUninstall
    $parsed = $result | ConvertFrom-Json
    Assert-True ($parsed.ok -eq $true) "a clean uninstall reports success"
    Assert-True ($script:unregistered -contains "HermesConsole-Gateway" -and $script:unregistered -contains "HermesConsole-Dashboard") `
        "the installer's scheduled tasks are removed"
    Assert-True (-not ($script:unregistered -contains "OtroProducto-Updater")) "a foreign scheduled task is never removed"
    Assert-True ($script:removedRules -contains "HermesConsole-abc123") "the installer's firewall rule is removed"
    Assert-True (-not ($script:removedRules -contains "OtraAplicacion-xyz")) "a foreign firewall rule is never removed"
    Assert-True (-not (Test-Path -LiteralPath $global:PairingFile)) "the pairing record is removed"
    Assert-True (Test-Path -LiteralPath $global:HermesHome) "the home survives without -Purge"

    function global:Get-ScheduledTask { param([string]$TaskName, $ErrorAction) if ($TaskName) { return $null } return @() }
    function global:Get-NetFirewallRule { param([string]$Name, $ErrorAction) return @() }
    $again = Invoke-SetupUninstall | ConvertFrom-Json
    Assert-True ($again.ok -eq $true -and $again.removed -eq 0) "a second uninstall is a no-op"
    Assert-True (($script:auditLines -join "`n") -match 'already clean') "the no-op is reported explicitly"

    $global:Purge = $true
    $global:HermesHome = Join-Path $temp "Documentos-Cosas"
    [void](New-Item -ItemType Directory -Force -Path $global:HermesHome)
    $refused = $false
    try { Invoke-SetupUninstall | Out-Null } catch { $refused = ($_.Exception.Message -match 'Refusing -Purge') }
    Assert-True $refused "-Purge refuses to delete a path that is not a Hermes Console home"
    Assert-True (Test-Path -LiteralPath $global:HermesHome) "the refused path is left untouched"

    $global:HermesHome = Join-Path $temp "Hermes Console"
    [void](New-Item -ItemType Directory -Force -Path $global:HermesHome)
    [IO.File]::WriteAllText((Join-Path $global:HermesHome "config.yaml"), "x: 1")
    $purged = Invoke-SetupUninstall | ConvertFrom-Json
    Assert-True ($purged.purged -eq $true) "-Purge removes a recognised Console home"
    Assert-True (-not (Test-Path -LiteralPath $global:HermesHome)) "the purged home is gone"

    $global:Purge = $false
    foreach ($name in @("HermesHome", "AuditDir", "PairingFile", "QrFile", "Purge")) {
        Remove-Variable -Name $name -Scope Global -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

function Test-ProgressBranding {
    # La instalacion debe verse como un instalador con identidad y el QR tiene que
    # aparecer en la consola. La barra solo se dibuja en una terminal interactiva:
    # redirigido (logs, CI) la salida es exactamente la de siempre.
    $setupRaw = Get-Content -LiteralPath $SetupScript -Raw

    Assert-True ($setupRaw -match 'xPetaLab' -and $setupRaw -match 'HERMES CONSOLE') `
        "the installer shows the product banner"
    Assert-True ($setupRaw -match '\$script:SetupPhaseWeights = @\(([0-9]+, ){6}[0-9]+\)') `
        "phase weights are declared once"
    $match = [regex]::Match($setupRaw, '\$script:SetupPhaseWeights = @\(([0-9,\s]+)\)')
    Assert-True $match.Success "phase weights are parseable"
    if ($match.Success) {
        $weights = @($match.Groups[1].Value.Split(',') | ForEach-Object { [int]$_.Trim() })
        Assert-True ($weights.Count -eq 7) "one weight per phase"
        Assert-True (($weights | Measure-Object -Sum).Sum -eq 100) "weights add up to one hundred"
    }
    Assert-True ($setupRaw -match '\[Console\]::IsOutputRedirected') `
        "the installer detects whether the output is a terminal"
    Assert-True ($setupRaw -match 'function Write-SetupPhaseDetail') "long phases report real activity"
    Assert-True ($setupRaw -match 'ExtendWhileTaskRunning "HermesConsole-Dashboard" -MaxSeconds 1800') `
        "the slow phase keeps its extended, progress-driven wait"

    # El QR debe llegar a la consola: enlace + ASCII, y sin acabar en los logs.
    Assert-True ($setupRaw -match 'function Show-PairingResult') "there is a console pairing result"
    Assert-True ($setupRaw -match 'SCAN THIS QR WITH HERMES CONSOLE') "the console tells the user to scan the QR"
    Assert-True ($setupRaw -match 'print_ascii\(invert=True\)') "the QR is rendered as ASCII too"
    Assert-True ($setupRaw -match 'redirect_stdout\(buffer\)') `
        "the ASCII QR never goes to the captured stdout of the render process"
    Assert-True ($setupRaw -match 'Show-PairingResult \$link') "the flow prints the pairing result at the end"
    # Extraccion determinista del cuerpo: de la definicion al siguiente 'function'.
    $showStart = $setupRaw.IndexOf("function Show-PairingResult")
    $showEnd = if ($showStart -ge 0) { $setupRaw.IndexOf("`nfunction ", $showStart + 10) } else { -1 }
    $showBody = if ($showStart -ge 0 -and $showEnd -gt $showStart) {
        $setupRaw.Substring($showStart, $showEnd - $showStart)
    } else { "" }
    Assert-True ($showBody.Length -gt 200) "the pairing result body is found"
    Assert-True ($showBody -notmatch 'Write-Audit') "the pairing link and QR are never written to the audit log"
    Assert-True ($showBody -match 'Write-Host') "the pairing result is printed to the console"
    Assert-True ($showBody -match 'QR image:') "the console names the QR image file too"

    # La barra respeta el modo redirigido y el formato de siempre sigue ahi.
    Import-ProductFunction $setup "Write-SetupPhase"
    foreach ($name in @("Write-Audit", "Show-SetupBanner", "Write-SetupProgressBar", "Get-SetupPercent", "Format-Elapsed")) {
        Import-ProductFunction $setup $name
    }
    $script:auditLines = New-Object System.Collections.Generic.List[string]
    $script:auditOnlyCapture = $true
    function global:Write-Audit {
        param($Step, $State, $Detail)
        [void]$script:auditLines.Add("$Step|$State|$Detail")
    }
    $script:SetupPhase = 0
    $script:SetupPhaseTotal = 7
    $script:SetupPhaseWeights = @(3, 40, 4, 24, 17, 7, 5)
    $script:SetupLive = $false
    $script:SetupStartedAt = Get-Date
    $script:SetupProgressLabel = ""
    $script:SetupCompletedWeight = 0
    $output = @(& { Write-SetupPhase "First phase" } 6>&1 | ForEach-Object { [string]$_ })
    $joined = $output -join "`n"
    Assert-True (($script:auditLines -join "`n") -match '\[#\.{6}\] 1/7 First phase') `
        "the plain progress line is unchanged for logs and CI"
    Assert-True ($joined -notmatch '%') "no bar is drawn when the output is not a terminal"
    Assert-True ($joined -notmatch 'xPetaLab') "no banner is drawn when the output is not a terminal"
    Assert-True ($script:SetupCompletedWeight -eq 0) "the first phase contributes no completed weight"
    Assert-True ($script:SetupProgressLabel -eq "First phase") "the current label is tracked for the live line"
}


function Test-FirewallAppRules {
    # Windows pregunta "permitir esta aplicacion?" por PROGRAMA aunque exista una
    # regla por puerto: sin reglas por programa aparece un dialogo, y quien lo
    # cancela deja una regla de bloqueo que rompe el emparejamiento.
    $setupRaw = Get-Content -LiteralPath $SetupScript -Raw
    Assert-True ($setupRaw -match 'function Get-ManagedListenPrograms') "managed listening programs are resolved"
    Assert-True ($setupRaw -match 'function Ensure-AppFirewallRules') "application rules have their own step"
    Assert-True ($setupRaw -match '-Program \$program') "the application rule is scoped to the program"
    Assert-True ($setupRaw -match '\$appRuleName = "\$RuleName-app\$appIndex"') "application rules derive their name from the port rule"
    Assert-True ($setupRaw -match 'Ensure-AppFirewallRules \$display \$Pairing \$rule\.Name') `
        "an existing install gets the application rules without touching the port rule"
    Assert-True ($setupRaw -match 'FirewallRuleNames \+= \$appRuleName') "application rules join the rollback list"
    Assert-True ($setupRaw -match 'FirewallRuleNames') "the rollback removes them"

    foreach ($name in @("Get-ManagedListenPrograms", "Ensure-AppFirewallRules", "Remove-ManagedProgramBlockRules")) {
        Import-ProductFunction $setup $name
    }
    function global:Test-CurrentProcessAdministrator { return $true }
    function global:Write-Ok { param($Message) }
    function global:Get-NetFirewallApplicationFilter { param($Rule, $ErrorAction) return $null }
    $script:created = New-Object System.Collections.Generic.List[string]
    $script:createdNames = New-Object System.Collections.Generic.List[string]
    # El stub refleja la realidad: lo creado se puede volver a consultar, que es lo
    # que el producto verifica antes de dar la regla por buena.
    function global:Get-NetFirewallRule {
        param([string]$Name, $DisplayName, $ErrorAction)
        if ($Name -and ($script:createdNames -contains $Name)) {
            return [PSCustomObject]@{ Name = $Name; Enabled = $true }
        }
        return $null
    }
    function global:New-NetFirewallRule {
        param([string]$Name, [string]$DisplayName, [string]$Direction, [string]$Action,
              [string]$Program, [string]$Protocol, $LocalPort, [string]$Profile,
              [string]$RemoteAddress, $ErrorAction)
        [void]$script:created.Add("$Name|$Program|$Profile|$RemoteAddress|$($LocalPort -join ',')")
        [void]$script:createdNames.Add($Name)
        return [PSCustomObject]@{ Name = $Name }
    }
    $script:HermesPython = "C:\\home\\venv\\Scripts\\python.exe"
    $global:HB = "C:\\home\\venv\\Scripts\\hermes.exe"
    function global:Get-HermesPython { return $script:HermesPython }
    function global:Test-Path { param([string]$LiteralPath, $Path, $PathType) return $true }
    $script:SetupTransaction = [PSCustomObject]@{ FirewallRuleNames = @() }
    $created = Ensure-AppFirewallRules "Hermes Console private network" @{ Kind = "lan" } "HermesConsole-abc"
    Assert-True ($created -eq 2) "one application rule per managed executable (actual: $created)"
    Assert-True (($script:created -join "`n") -match 'python\.exe') "the venv interpreter is authorised"
    Assert-True (($script:created -join "`n") -match 'hermes\.exe') "the launcher is authorised"
    Assert-True (($script:created -join "`n") -match 'Private\|LocalSubnet') "application rules keep the private LAN scope"
    Assert-True (($script:created -join "`n") -match '8642,9119,9131') "application rules keep the same three ports"
    Assert-True (@($script:SetupTransaction.FirewallRuleNames).Count -eq 2) "application rules are registered for rollback"

    # Una regla de BLOQUEO para el mismo ejecutable gana al permiso: hay que quitarla.
    Assert-True ($setupRaw -match 'function Remove-ManagedProgramBlockRules') "dismissed-prompt block rules are handled"
    Assert-True ($setupRaw -match '-Enabled True -Action Block -Direction Inbound') "only enabled inbound block rules are considered"
    Assert-True ($setupRaw -match 'Remove-ManagedProgramBlockRules') "the block cleanup runs while ensuring permissions"
    # Comillas simples: con dobles, PowerShell expandiria $Pairing y StrictMode corta.
    $early = $setupRaw.IndexOf('if (-not $AuditOnly) { Ensure-PrivateFirewallRules $Pairing }')
    $services = $setupRaw.IndexOf('Write-SetupPhase "Installing hidden persistent services"')
    Assert-True ($early -gt 0 -and $services -gt 0 -and $early -lt $services) `
        "permissions are created before any service starts listening, so Windows has nothing to ask"

    function global:Get-NetFirewallApplicationFilter {
        param($Rule, $ErrorAction)
        return [PSCustomObject]@{ Program = $Rule.Program }
    }
    $script:removedBuild = New-Object System.Collections.Generic.List[string]
    function global:Get-NetFirewallRule {
        param([string]$Name, $DisplayName, $Enabled, $Action, $Direction, $ErrorAction)
        if ($Action -eq "Block") {
            return @(
                [PSCustomObject]@{ Name = "Block-python"; Program = $script:HermesPython },
                [PSCustomObject]@{ Name = "Block-otra-app"; Program = "C:\otra\app.exe" }
            )
        }
        if ($Name -and ($script:createdNames -contains $Name)) { return [PSCustomObject]@{ Name = $Name; Enabled = $true } }
        return $null
    }
    function global:Remove-NetFirewallRule {
        param([string]$Name, [string]$DisplayName, $ErrorAction)
        [void]$script:removedBuild.Add($Name)
        return $true
    }
    function global:Write-Ok { param($Message) }
    $removed = Remove-ManagedProgramBlockRules
    Assert-True ($removed -eq 1) "only the managed program's block rule is removed (actual: $removed)"
    Assert-True ($script:removedBuild -contains "Block-python") "the blocked managed executable is unblocked"
    Assert-True (-not ($script:removedBuild -contains "Block-otra-app")) "a foreign block rule is left alone"
}

$cases = if ($Case -eq "All") {
    @("ParserBootstrap", "UrlPolicy", "PairNoRepair", "Health", "ContainmentFailure", "LockOwnership", "TransactionRollback", "FreshInstallCleanup", "UpstreamInstallerPin", "PlatformSupport", "ProcessDiagnostics", "ServiceRunnerEncoding", "NativeJob", "TopLevelTimeouts", "PreflightDiagnose", "ServicePorts", "AdaptiveWait", "AddressCandidates", "Uninstall", "FailureHint", "ProgressBranding", "FirewallAppRules")
} else { @($Case) }

foreach ($selected in $cases) {
    $Case = $selected
    & (Microsoft.PowerShell.Core\Get-Command "Test-$selected" -CommandType Function)
}

Write-Host "RESULT: PASS=$script:Passed SKIP=$script:Skipped"
# Assert-True lanza en el primer fallo, asi que llegar aqui es exito: la salida no
# puede depender de LASTEXITCODE de ningun hijo.
$global:LASTEXITCODE = 0
exit 0
