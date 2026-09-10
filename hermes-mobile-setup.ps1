# Hermes Console - native Windows setup (PowerShell 5.1+).
# Installs/repairs Hermes, Gateway, Dashboard and Mobile Bridge for this user.

param(
    [switch]$AuditOnly,
    [switch]$Preflight,
    [switch]$Diagnose,
    [switch]$NoFirewallPrompt,
    [string]$InstallerTimeoutSec = "900",
    [string]$TerminationTimeoutSec = "15",
    [string]$LockTimeoutSec = "30"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
function Get-BoundedIntegerParameter([string]$Name, [string]$Value, [int]$Minimum, [int]$Maximum) {
    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed) -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        throw "$Name must be an integer between $Minimum and $Maximum. No changes were made."
    }
    return $parsed
}
$InstallerTimeoutSec = Get-BoundedIntegerParameter "InstallerTimeoutSec" $InstallerTimeoutSec 1 86400
$TerminationTimeoutSec = Get-BoundedIntegerParameter "TerminationTimeoutSec" $TerminationTimeoutSec 1 300
$LockTimeoutSec = Get-BoundedIntegerParameter "LockTimeoutSec" $LockTimeoutSec 0 600
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoRaw = if ($env:HERMES_REPO_RAW) {
    $env:HERMES_REPO_RAW.TrimEnd('/')
} else {
    "https://raw.githubusercontent.com/xP3ta/hermes-setup/main"
}
$script:HermesAgentCommit = "b1f003e18633298d549668b8e186af84cca45b76"
$script:HermesAgentInstallerUrl = "https://raw.githubusercontent.com/NousResearch/hermes-agent/b1f003e18633298d549668b8e186af84cca45b76/scripts/install.ps1"
$script:HermesAgentInstallerSha256 = "226c70a90ad47e8a4d34cb11aca4ecbeb649e2f9b67fbd009ea49791de2d56f5"
$script:HermesAgentInstallerSize = 245718
function Resolve-HermesHome([string]$Candidate) {
    if ([string]::IsNullOrWhiteSpace($Candidate) -or
        -not [IO.Path]::IsPathRooted($Candidate)) {
        throw "HERMES_HOME is ambiguous; configure one absolute, non-root path."
    }
    try { $resolved = [IO.Path]::GetFullPath($Candidate) } catch {
        throw "HERMES_HOME is ambiguous or invalid."
    }
    $root = [IO.Path]::GetPathRoot($resolved)
    if (-not $root -or $resolved.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) -eq
        $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) {
        throw "HERMES_HOME cannot be a filesystem root."
    }
    return $resolved.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

$homeCandidate = if ($env:HERMES_HOME) {
    $env:HERMES_HOME
} elseif ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA "hermes"
} else {
    throw "HERMES_HOME is ambiguous because LOCALAPPDATA is unavailable."
}
$HermesHome = Resolve-HermesHome $homeCandidate
$InstallDir = Join-Path $HermesHome "hermes-agent"
$HermesBinDir = Join-Path $HermesHome "bin"
$ServicesDir = Join-Path $HermesHome "console-services"
$LogsDir = Join-Path $HermesHome "logs"
$AuditDir = Join-Path $HermesHome "audit"
$script:SetupDirectoryExistedAtStart = @{}
foreach ($setupDirectory in @($HermesHome, $HermesBinDir, $ServicesDir, $LogsDir, $AuditDir)) {
    $script:SetupDirectoryExistedAtStart[$setupDirectory] = Test-Path -LiteralPath $setupDirectory -PathType Container
}
$AuditLog = Join-Path $AuditDir "safe-setup-audit.jsonl"
$EnvFile = Join-Path $HermesHome ".env"
$BridgeTarget = Join-Path $HermesHome "hermes_bridge.py"
$BridgeBackup = "$BridgeTarget.rollback"
$PairingFile = Join-Path $ServicesDir "pairing.json"
$QrFile = Join-Path $ServicesDir "pairing-qr.png"
$AttemptId = [Guid]::NewGuid().ToString("N")
$BridgeNew = "$BridgeTarget.$AttemptId.new"
$ManifestFile = Join-Path $HermesHome "bridge-release.$AttemptId.new"
$PairingNew = "$PairingFile.$AttemptId.new"
$EnvNew = "$EnvFile.$AttemptId.new"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:TaskDefinitionsChanged = @{}
$script:RunnerChanged = @{}
$script:BridgeChanged = $false
$script:HermesInstallTimeoutSeconds = [int]$InstallerTimeoutSec
$script:TerminationTimeoutSeconds = [int]$TerminationTimeoutSec
$script:MutationQuiescent = $true
$script:UnresolvedContainedProcess = $null
$script:SetupTransaction = $null
$script:IntegrationCommitted = $false
$script:FirewallRuleCreatedName = ""

function Test-WindowsPlatform {
    return $env:OS -eq "Windows_NT"
}

function Assert-SupportedWindows {
    $support = "Hermes Console Setup supports Windows 10, Windows 11 and Windows Server (x64 or ARM64)."
    if (-not (Test-WindowsPlatform)) {
        throw "$support Detected: non-Windows operating system. This system is not supported. No changes were made."
    }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($null -eq $os) { throw "Operating system inventory was empty." }
        [version]$version = $null
        if (-not [Version]::TryParse([string]$os.Version, [ref]$version)) {
            throw "Operating system version was invalid."
        }
        $productType = [int]$os.ProductType
        $build = [string]$os.BuildNumber
        if ([string]::IsNullOrWhiteSpace($build)) { throw "Operating system build was empty." }
    } catch {
        throw "Hermes Console Setup could not verify the Windows version. It supports Windows 10, Windows 11 and Windows Server (x64 or ARM64). No changes were made."
    }

    $nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }
    $architecture = switch ([string]$nativeArchitecture) {
        "AMD64" { "x64"; break }
        "ARM64" { "ARM64"; break }
        "x86" { "x86"; break }
        default { "unknown"; break }
    }
    $caption = (([string]$os.Caption -replace '[\r\n]+', ' ').Trim())
    if ([string]::IsNullOrWhiteSpace($caption)) { $caption = "unknown Windows edition" }
    if ($caption.Length -gt 120) { $caption = $caption.Substring(0, 120) }
    $detected = "$caption, version $version, build $build, $architecture"

    # Windows Server (productType 2 = domain controller, 3 = server) is a
    # supported target: the per-user Scheduled Tasks, restricted firewall rules
    # and CIM preflight behave the same as on client Windows. Release evidence
    # is still recorded separately per edition.
    $supportedEdition = $productType -in @(1, 2, 3)
    $supportedVersion = $version.Major -eq 10
    $supportedArchitecture = $architecture -in @("x64", "ARM64")
    if (-not ($supportedEdition -and $supportedVersion -and $supportedArchitecture)) {
        throw "$support Detected: $detected. This system is not supported. No changes were made."
    }
}

function Get-SetupLockName([string]$Path) {
    # Scheduled Task and Startup names are per-user globals, so competing
    # homes must share one lock rather than coordinating by home. A named
    # mutex preserves atomic exclusivity without leaving a lock file behind.
    if (Test-WindowsPlatform) {
        $scope = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    } else {
        $scope = "{0}@{1}" -f [Environment]::UserName, [Environment]::MachineName
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($scope)
        $digest = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "")
    } finally {
        $sha.Dispose()
    }
    $name = "xPeta.HermesConsole.Setup.$digest"
    if (Test-WindowsPlatform) { return "Global\$name" }
    return $name
}

function Enter-SetupLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateRange(0, 600000)][int]$TimeoutMilliseconds = 30000
    )
    $mutex = New-Object Threading.Mutex($false, $Name)
    $acquired = $false
    $legacyHandle = $null
    $legacyPath = Join-Path ([IO.Path]::GetTempPath()) "hermes-console-setup.lock"
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        } catch [Threading.AbandonedMutexException] {
            # Windows transferred ownership because the previous process died.
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Another Hermes Console setup owns the lock; no changes were made."
        }
        try {
            # Transitional dual lock: excludes the published file-lock version.
            # This file exists only while setup runs and is removed on release.
            $legacyHandle = [IO.File]::Open($legacyPath, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            throw "Another Hermes Console setup owns the legacy lock; no changes were made."
        }
        return [PSCustomObject]@{
            Mutex = $mutex
            LegacyHandle = $legacyHandle
            LegacyPath = $legacyPath
        }
    } catch {
        if ($legacyHandle) { $legacyHandle.Dispose() }
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        throw
    }
}

function Exit-SetupLock($Lock) {
    if ($null -eq $Lock) { return }
    $legacyPath = $Lock.LegacyPath
    try {
        if ($Lock.LegacyHandle) { $Lock.LegacyHandle.Dispose() }
        if ($legacyPath) {
            Remove-Item -LiteralPath $legacyPath -Force -ErrorAction SilentlyContinue
        }
        if ($legacyPath -and (Test-Path -LiteralPath $legacyPath)) {
            throw "Could not clean the temporary setup lock: $legacyPath"
        }
    } finally {
        try { $Lock.Mutex.ReleaseMutex() } finally { $Lock.Mutex.Dispose() }
    }
}

function New-SetupAttemptPaths([string]$HermesHome) {
    $id = [Guid]::NewGuid().ToString("N")
    $services = Join-Path $HermesHome "console-services"
    return [PSCustomObject]@{
        BridgeNew = (Join-Path $HermesHome "hermes_bridge.py.$id.new")
        ManifestFile = (Join-Path $HermesHome "bridge-release.$id.new")
        PairingNew = (Join-Path $services "pairing.json.$id.new")
        QrNew = (Join-Path $services "pairing-qr.png.$id.new")
        EnvNew = (Join-Path $HermesHome ".env.$id.new")
        Installer = (Join-Path ([IO.Path]::GetTempPath()) "hermes-agent-install-$id.ps1")
        InstallerOut = (Join-Path $services "hermes-install-$id.out.log")
        InstallerErr = (Join-Path $services "hermes-install-$id.err.log")
        QrScript = (Join-Path $services "make-pairing-qr-$id.py")
    }
}

function Remove-OwnedSetupFiles($Paths) {
    if ($null -eq $Paths) { return }
    foreach ($name in @(
        "BridgeNew", "ManifestFile", "PairingNew", "QrNew", "EnvNew", "Installer",
        "InstallerOut", "InstallerErr", "QrScript"
    )) {
        $property = $Paths.PSObject.Properties[$name]
        if ($property -and $property.Value) {
            Remove-Item -LiteralPath ([string]$property.Value) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-IntegrationTaskNames {
    return @(
        "HermesConsole-Gateway", "HermesConsole-Dashboard", "HermesConsole-MobileBridge",
        "HermesConsole-Restart-Dashboard", "HermesConsole-Restart-MobileBridge"
    )
}

function Get-ExactScheduledTask([string]$TaskName) {
    Import-Module ScheduledTasks -ErrorAction Stop
    $matches = @(Get-ScheduledTask -TaskPath "\" -ErrorAction Stop | Where-Object {
        $_.TaskName -eq $TaskName -and $_.TaskPath -eq "\"
    })
    if ($matches.Count -gt 1) { throw "Scheduled Task '$TaskName' is ambiguous." }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Get-IntegrationRunnerMap {
    return [ordered]@{
        "HermesConsole-Gateway" = "hermes-gateway.vbs"
        "HermesConsole-Dashboard" = "hermes-dashboard.vbs"
        "HermesConsole-MobileBridge" = "hermes-bridge.vbs"
        "HermesConsole-Restart-Dashboard" = "restart-hermes-dashboard.vbs"
        "HermesConsole-Restart-MobileBridge" = "restart-hermes-bridge.vbs"
    }
}

function Write-TransactionJournal($Transaction, [string]$Event, [string]$State, [string]$Code = "") {
    if ($null -eq $Transaction -or -not $Transaction.Journal) { return }
    $safeEvent = if ($Event -match '^[A-Za-z0-9_.-]{1,64}$') { $Event } else { "redacted" }
    $safeState = if ($State -match '^[A-Za-z0-9_.-]{1,32}$') { $State } else { "redacted" }
    $safeCode = if ($Code -match '^[A-Za-z0-9_.-]{0,96}$') { $Code } else { "redacted" }
    $row = [ordered]@{
        time = (Get-Date).ToUniversalTime().ToString('o')
        event = $safeEvent
        state = $safeState
        code = $safeCode
    }
    [IO.File]::AppendAllText(
        $Transaction.Journal,
        (($row | ConvertTo-Json -Compress) + [Environment]::NewLine),
        (New-Object Text.UTF8Encoding($false))
    )
}

function New-SetupTransaction {
    [CmdletBinding()]
    param([string]$ParentDirectory = ([IO.Path]::GetTempPath()))
    $directory = Join-Path $ParentDirectory ("hermes-console-transaction-" + [Guid]::NewGuid().ToString("N"))
    $payload = Join-Path $directory "payload"
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    if (Test-WindowsPlatform) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $identity.User,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $directory -AclObject $acl
        Set-Acl -LiteralPath $payload -AclObject $acl
    }
    $transaction = [PSCustomObject]@{
        Directory = $directory
        PayloadDirectory = $payload
        Journal = (Join-Path $directory "journal.jsonl")
        FileSnapshots = (New-Object Collections.ArrayList)
        TaskSnapshots = (New-Object Collections.ArrayList)
        FirewallRuleName = ""
        Committed = $false
        BaselineServicePids = @()
    }
    # Baseline of owned service processes at attempt start: the rollback sweep
    # terminates only processes absent from it. PID attribution avoids clocks
    # entirely (Win32_Process.CreationDate is null under PowerShell 7).
    if (Get-Command Get-OwnedServiceProcessIds -ErrorAction SilentlyContinue) {
        $transaction.BaselineServicePids = @(Get-OwnedServiceProcessIds)
    }
    Write-TransactionJournal $transaction "transaction" "started"
    return $transaction
}

function Add-TransactionFileSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Transaction,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ($Label -notmatch '^[A-Za-z0-9_.-]{1,64}$') { throw "Invalid transaction snapshot label." }
    $exists = Test-Path -LiteralPath $Path
    $snapshotPath = ""
    $attributes = $null
    $creationTicks = $null
    $lastWriteTicks = $null
    $securityDescriptor = ""
    if ($exists) {
        $item = Get-Item -LiteralPath $Path -Force
        $linkType = if ($item.PSObject.Properties["LinkType"]) { [string]$item.LinkType } else { "" }
        if ($item.PSIsContainer -or
            (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            -not [string]::IsNullOrWhiteSpace($linkType)) {
            throw "Transaction path is not a regular standalone file: $Path"
        }
        $snapshotPath = Join-Path $Transaction.PayloadDirectory ("file-{0:D3}.bin" -f $Transaction.FileSnapshots.Count)
        [IO.File]::WriteAllBytes($snapshotPath, [IO.File]::ReadAllBytes($Path))
        $attributes = [int64]$item.Attributes
        $creationTicks = [int64]$item.CreationTimeUtc.Ticks
        $lastWriteTicks = [int64]$item.LastWriteTimeUtc.Ticks
        if (Test-WindowsPlatform) {
            $securityDescriptor = (Get-Acl -LiteralPath $Path).Sddl
        }
    }
    [void]$Transaction.FileSnapshots.Add([PSCustomObject]@{
        Label = $Label
        Path = $Path
        Existed = [bool]$exists
        SnapshotPath = $snapshotPath
        Attributes = $attributes
        CreationTimeUtcTicks = $creationTicks
        LastWriteTimeUtcTicks = $lastWriteTicks
        SecurityDescriptor = $securityDescriptor
    })
    Write-TransactionJournal $Transaction "file-snapshot" "ok" $Label
}

function Add-TransactionTaskSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Transaction,
        [Parameter(Mandatory = $true)][string]$TaskName
    )
    Import-Module ScheduledTasks -ErrorAction Stop
    $task = Get-ExactScheduledTask $TaskName
    $exists = $null -ne $task
    $xmlPath = ""
    $enabled = $false
    $running = $false
    if ($exists) {
        $xml = Export-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction Stop
        $xmlPath = Join-Path $Transaction.PayloadDirectory ("task-{0:D2}.xml" -f $Transaction.TaskSnapshots.Count)
        [IO.File]::WriteAllText($xmlPath, [string]$xml, (New-Object Text.UTF8Encoding($false)))
        $enabled = [bool]$task.Settings.Enabled
        $running = $task.State.ToString() -eq "Running"
    }
    [void]$Transaction.TaskSnapshots.Add([PSCustomObject]@{
        Name = $TaskName
        Existed = [bool]$exists
        XmlPath = $xmlPath
        Enabled = $enabled
        Running = $running
    })
    Write-TransactionJournal $Transaction "task-snapshot" "ok" $TaskName
}

function Initialize-SetupTransaction {
    $transaction = New-SetupTransaction
    try {
        $files = [ordered]@{
            env = $EnvFile
            bridge = $BridgeTarget
            bridge_rollback = $BridgeBackup
            runner_gateway = (Join-Path $ServicesDir "hermes-gateway.vbs")
            runner_dashboard = (Join-Path $ServicesDir "hermes-dashboard.vbs")
            runner_bridge = (Join-Path $ServicesDir "hermes-bridge.vbs")
            runner_restart_dashboard = (Join-Path $ServicesDir "restart-hermes-dashboard.vbs")
            runner_restart_bridge = (Join-Path $ServicesDir "restart-hermes-bridge.vbs")
            pairing = $PairingFile
            pairing_qr = $QrFile
            audit = $AuditLog
        }
        $startup = [Environment]::GetFolderPath("Startup")
        if (-not $startup) { throw "The per-user Startup folder is unavailable for transaction snapshot." }
        foreach ($name in @(Get-IntegrationTaskNames)) {
            $label = "startup_" + ($name -replace '[^A-Za-z0-9_.-]', '_')
            $files[$label] = Join-Path $startup "$name.lnk"
        }
        foreach ($entry in $files.GetEnumerator()) {
            Add-TransactionFileSnapshot -Transaction $transaction -Label ([string]$entry.Key) -Path ([string]$entry.Value)
        }
        foreach ($name in @(Get-IntegrationTaskNames)) {
            Add-TransactionTaskSnapshot -Transaction $transaction -TaskName $name
        }
        Write-TransactionJournal $transaction "snapshot" "complete"
        return $transaction
    } catch {
        Complete-TransactionStorage -Transaction $transaction -Complete | Out-Null
        throw
    }
}

function Restore-TransactionFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)
    $failures = New-Object Collections.Generic.List[string]
    foreach ($snapshot in @($Transaction.FileSnapshots)) {
        try {
            if (Test-Path -LiteralPath $snapshot.Path) {
                $current = Get-Item -LiteralPath $snapshot.Path -Force
                $currentLinkType = if ($current.PSObject.Properties["LinkType"]) { [string]$current.LinkType } else { "" }
                if ($current.PSIsContainer -or
                    (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
                    -not [string]::IsNullOrWhiteSpace($currentLinkType)) {
                    throw "Rollback target is not a regular standalone file: $($snapshot.Path)"
                }
            }
            if ($snapshot.Existed) {
                if (-not (Test-Path -LiteralPath $snapshot.SnapshotPath -PathType Leaf)) {
                    throw "Snapshot payload is unavailable."
                }
                $parent = Split-Path -Parent $snapshot.Path
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                $stage = "$($snapshot.Path).restore-$([Guid]::NewGuid().ToString('N'))"
                $discard = "$($snapshot.Path).discard-$([Guid]::NewGuid().ToString('N'))"
                try {
                    [IO.File]::WriteAllBytes($stage, [IO.File]::ReadAllBytes($snapshot.SnapshotPath))
                    if (Test-Path -LiteralPath $snapshot.Path -PathType Leaf) {
                        [IO.File]::Replace($stage, $snapshot.Path, $discard, $true)
                    } else {
                        Move-Item -LiteralPath $stage -Destination $snapshot.Path
                    }
                } finally {
                    Remove-Item -LiteralPath $stage, $discard -Force -ErrorAction SilentlyContinue
                }
                $expected = (Get-FileHash -LiteralPath $snapshot.SnapshotPath -Algorithm SHA256).Hash
                $actual = (Get-FileHash -LiteralPath $snapshot.Path -Algorithm SHA256).Hash
                if ($actual -ne $expected) { throw "Restored bytes did not verify." }
                [IO.File]::SetLastWriteTimeUtc(
                    $snapshot.Path,
                    [DateTime]::new([int64]$snapshot.LastWriteTimeUtcTicks, [DateTimeKind]::Utc)
                )
                if (Test-WindowsPlatform) {
                    [IO.File]::SetCreationTimeUtc(
                        $snapshot.Path,
                        [DateTime]::new([int64]$snapshot.CreationTimeUtcTicks, [DateTimeKind]::Utc)
                    )
                    [IO.File]::SetAttributes($snapshot.Path, [IO.FileAttributes][int64]$snapshot.Attributes)
                    if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.SecurityDescriptor)) {
                        $acl = New-Object Security.AccessControl.FileSecurity
                        $acl.SetSecurityDescriptorSddlForm([string]$snapshot.SecurityDescriptor)
                        Set-Acl -LiteralPath $snapshot.Path -AclObject $acl
                    }
                }
            } else {
                Remove-Item -LiteralPath $snapshot.Path -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $snapshot.Path) { throw "Attempt-created file remains." }
            }
            Write-TransactionJournal $Transaction "file-restore" "ok" $snapshot.Label
        } catch {
            $code = "file." + $snapshot.Label
            [void]$failures.Add($code)
            Write-TransactionJournal $Transaction "file-restore" "failed" $code
        }
    }
    return @($failures)
}

function Get-OwnedServiceProcessIds {
    # Owned identity = executable inside this install dir AND a service verb in
    # the command line. Anything outside that identity is never touched.
    $rootVar = Get-Variable -Name InstallDir -ErrorAction SilentlyContinue
    if (-not $rootVar -or -not $rootVar.Value) { return @() }
    $agentRoot = [IO.Path]::GetFullPath([string]$rootVar.Value)
    $pattern = '(?i)(gateway\s+run|dashboard\s+--host|hermes_bridge\.py)'
    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and $_.ExecutablePath -and ($_.CommandLine -match $pattern) -and
            [IO.Path]::GetFullPath([string]$_.ExecutablePath).StartsWith($agentRoot, [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object { [int]$_.ProcessId }
    )
}

function Stop-AttemptServiceProcesses {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)
    # Port-listener checks miss owned processes that never bound (observed
    # natively: a Dashboard whose launch was refused pre-bind survived a
    # "complete" rollback). Sweep owned service processes absent from the
    # attempt baseline; pre-existing ones are never killed and failures stay
    # visible in the rollback report.
    $failures = New-Object Collections.Generic.List[string]
    $baseline = @($Transaction.BaselineServicePids)
    foreach ($id in @(Get-OwnedServiceProcessIds)) {
        if ($baseline -contains $id) { continue }
        try {
            Stop-Process -Id $id -Force -ErrorAction Stop
            $deadline = [DateTime]::Now.AddSeconds(5)
            while ((Get-Process -Id $id -ErrorAction SilentlyContinue) -and [DateTime]::Now -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
            if (Get-Process -Id $id -ErrorAction SilentlyContinue) { throw "still running" }
            Write-TransactionJournal $Transaction "process-sweep" "ok" "pid $id"
        } catch {
            [void]$failures.Add("process.$id")
            Write-TransactionJournal $Transaction "process-sweep" "failed" "pid $id"
        }
    }
    return $failures.ToArray()
}

function Stop-TransactionTasksAndVerify {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)
    Import-Module ScheduledTasks -ErrorAction Stop
    $failures = New-Object Collections.Generic.List[string]
    foreach ($name in @(Get-IntegrationTaskNames)) {
        try {
            if (Get-ExactScheduledTask $name) {
                Stop-ScheduledTask -TaskName $name -TaskPath "\" -ErrorAction SilentlyContinue
            }
        } catch {
            [void]$failures.Add("task-query.$name")
        }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $running = @()
        foreach ($name in @(Get-IntegrationTaskNames)) {
            try {
                $task = Get-ExactScheduledTask $name
                if ($task -and $task.State.ToString() -eq "Running") { $running += $name }
            } catch {
                if (-not $failures.Contains("task-query.$name")) {
                    [void]$failures.Add("task-query.$name")
                }
            }
        }
        if ($running.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    } while ($watch.Elapsed.TotalSeconds -lt 10)
    foreach ($name in $running) { [void]$failures.Add("task-running.$name") }
    foreach ($service in @(
        @{ Port = 8642; Name = "HermesConsole-Gateway" },
        @{ Port = 9119; Name = "HermesConsole-Dashboard" },
        @{ Port = 9131; Name = "HermesConsole-MobileBridge" }
    )) {
        try {
            $records = @(Get-ExistingHermesPortRecords | Where-Object { $_.Port -eq $service.Port })
            if ($records.Count -gt 0) { Stop-OwnedHermesListener $service.Port $service.Name }
            if (@(Get-ExistingHermesPortRecords | Where-Object { $_.Port -eq $service.Port }).Count -gt 0) {
                throw "Listener remains."
            }
        } catch {
            [void]$failures.Add("listener.$($service.Port)")
        }
    }
    foreach ($failure in @(Stop-AttemptServiceProcesses -Transaction $Transaction)) {
        [void]$failures.Add($failure)
    }
    if ($failures.Count -gt 0) { throw "Integration process quiescence was not verified." }
    Write-TransactionJournal $Transaction "quiescence" "verified"
}

function Restore-TransactionTasks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)
    $failures = New-Object Collections.Generic.List[string]
    Import-Module ScheduledTasks -ErrorAction Stop
    foreach ($snapshot in @($Transaction.TaskSnapshots)) {
        try {
            $current = Get-ExactScheduledTask $snapshot.Name
            if ($current) {
                Unregister-ScheduledTask -TaskName $snapshot.Name -TaskPath "\" -Confirm:$false -ErrorAction Stop
            }
            if ($snapshot.Existed) {
                $xml = [IO.File]::ReadAllText($snapshot.XmlPath)
                Register-ScheduledTask -TaskName $snapshot.Name -TaskPath "\" -Xml $xml -Force -ErrorAction Stop | Out-Null
                if ($snapshot.Enabled) {
                    Enable-ScheduledTask -TaskName $snapshot.Name -TaskPath "\" -ErrorAction Stop | Out-Null
                } else {
                    Disable-ScheduledTask -TaskName $snapshot.Name -TaskPath "\" -ErrorAction Stop | Out-Null
                }
            }
            Write-TransactionJournal $Transaction "task-definition-restore" "ok" $snapshot.Name
        } catch {
            $code = "task-definition." + $snapshot.Name
            [void]$failures.Add($code)
            Write-TransactionJournal $Transaction "task-definition-restore" "failed" $snapshot.Name
        }
    }
    foreach ($snapshot in @($Transaction.TaskSnapshots | Where-Object { $_.Existed -and $_.Running })) {
        try {
            Start-ScheduledTask -TaskName $snapshot.Name -TaskPath "\" -ErrorAction Stop
            $restored = Get-ScheduledTask -TaskName $snapshot.Name -TaskPath "\" -ErrorAction Stop
            if ($restored.State.ToString() -ne "Running") { throw "Running state was not restored." }
            Write-TransactionJournal $Transaction "task-running-restore" "ok" $snapshot.Name
        } catch {
            $code = "task-running." + $snapshot.Name
            [void]$failures.Add($code)
            Write-TransactionJournal $Transaction "task-running-restore" "failed" $snapshot.Name
        }
    }
    return @($failures)
}

function Remove-AttemptFirewallRule {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)
    if (-not $Transaction.FirewallRuleName) { return }
    Import-Module NetSecurity -ErrorAction Stop
    $rule = Get-NetFirewallRule -Name $Transaction.FirewallRuleName -ErrorAction SilentlyContinue
    if ($rule) {
        Remove-NetFirewallRule -Name $Transaction.FirewallRuleName -ErrorAction Stop
    }
    if (Get-NetFirewallRule -Name $Transaction.FirewallRuleName -ErrorAction SilentlyContinue) {
        throw "Attempt-created firewall rule remains."
    }
    Write-TransactionJournal $Transaction "firewall-rollback" "ok"
}

function Complete-TransactionStorage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction, [switch]$Complete)
    if (-not (Test-Path -LiteralPath $Transaction.Directory)) { return $true }
    if ($Complete) {
        foreach ($item in @(Get-ChildItem -LiteralPath $Transaction.Directory -Force -ErrorAction SilentlyContinue)) {
            if ($item.FullName -ne $Transaction.Journal) {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $payloadRemaining = @(Get-ChildItem -LiteralPath $Transaction.Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $Transaction.Journal })
        if ($payloadRemaining.Count -gt 0) { return $false }
        Remove-Item -LiteralPath $Transaction.Journal -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Transaction.Directory -Force -ErrorAction SilentlyContinue
        return -not (Test-Path -LiteralPath $Transaction.Directory)
    }
    # On incomplete rollback retain the complete private preimage. Removing a
    # payload after its restore failed would destroy the recovery path.
    Write-TransactionJournal $Transaction "cleanup" "incomplete" "private recovery payload retained"
    return (Test-Path -LiteralPath $Transaction.PayloadDirectory -PathType Container)
}

function Invoke-SetupRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Transaction,
        [switch]$SkipNative,
        [scriptblock[]]$AdditionalRollback = @()
    )
    $failures = New-Object Collections.Generic.List[string]
    $quiescent = $true
    Write-TransactionJournal $Transaction "rollback" "started"
    if (-not $SkipNative) {
        try { Stop-TransactionTasksAndVerify -Transaction $Transaction } catch {
            $quiescent = $false
            $script:MutationQuiescent = $false
            [void]$failures.Add("quiescence")
            Write-TransactionJournal $Transaction "quiescence" "failed"
        }
    }
    if ($quiescent) {
        foreach ($failure in @(Restore-TransactionFiles -Transaction $Transaction)) {
            [void]$failures.Add([string]$failure)
        }
        if (-not $SkipNative) {
            try {
                foreach ($failure in @(Restore-TransactionTasks -Transaction $Transaction)) {
                    [void]$failures.Add([string]$failure)
                }
            } catch {
                [void]$failures.Add("task-restore")
                Write-TransactionJournal $Transaction "task-restore" "failed"
            }
        }
    } else {
        [void]$failures.Add("restore-skipped-unverified-quiescence")
        Write-TransactionJournal $Transaction "restore" "skipped" "unverified-quiescence"
    }
    if (-not $SkipNative) {
        try { Remove-AttemptFirewallRule -Transaction $Transaction } catch {
            [void]$failures.Add("firewall")
            Write-TransactionJournal $Transaction "firewall-rollback" "failed"
        }
    }
    foreach ($rollback in @($AdditionalRollback)) {
        try { & $rollback } catch {
            [void]$failures.Add("synthetic-hook")
            Write-TransactionJournal $Transaction "rollback-hook" "failed"
        }
    }
    $complete = $failures.Count -eq 0
    Write-TransactionJournal $Transaction "rollback" $(if ($complete) { "complete" } else { "incomplete" }) `
        $(if ($complete) { "" } else { "failure-count-$($failures.Count)" })
    if (-not (Complete-TransactionStorage -Transaction $Transaction -Complete:$complete)) {
        [void]$failures.Add("transaction-storage")
        $complete = $false
        Write-TransactionJournal $Transaction "storage-cleanup" "failed"
        [void](Complete-TransactionStorage -Transaction $Transaction)
    }
    return [PSCustomObject]@{ Complete = $complete; Failures = @($failures) }
}

function Complete-SetupTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)
    Write-TransactionJournal $Transaction "transaction" "committing"
    # This is the logical commit point. Cleanup failures after it must never
    # roll back a fully verified integration with a partially deleted snapshot.
    $Transaction.Committed = $true
    $script:IntegrationCommitted = $true
    if (-not (Complete-TransactionStorage -Transaction $Transaction -Complete)) {
        [void](Complete-TransactionStorage -Transaction $Transaction)
        throw "Post-commit transaction storage cleanup failed; Windows integration remains committed."
    }
}

function Write-AtomicBytes([string]$Path, [byte[]]$Bytes) {
    $stage = "$Path.$AttemptId.stage"
    $discard = "$Path.$AttemptId.discard"
    try {
        [IO.File]::WriteAllBytes($stage, $Bytes)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($stage, $Path, $discard, $true)
        } else {
            Move-Item -LiteralPath $stage -Destination $Path
        }
    } finally {
        Remove-Item -LiteralPath $stage, $discard -Force -ErrorAction SilentlyContinue
    }
}

function Get-CurrentSetupIdentities {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $values = @($identity.Name)
    if ($identity.User) { $values += $identity.User.Value }
    return @($values | Where-Object { $_ } | Select-Object -Unique)
}

function Get-CurrentHomeOwnerIdentities {
    $values = @(Get-CurrentSetupIdentities)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $administratorsSid = New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $values += $administratorsSid.Value
        try {
            $values += $administratorsSid.Translate([Security.Principal.NTAccount]).Value
        } catch {
            # The well-known SID itself remains locale independent.
        }
    }
    return @($values | Where-Object { $_ } | Select-Object -Unique)
}

function ConvertTo-WindowsSid([string]$Identity) {
    if ([string]::IsNullOrWhiteSpace($Identity)) { return $null }
    try {
        if ($Identity -match '^S-\d(?:-\d+)+$') {
            return (New-Object Security.Principal.SecurityIdentifier($Identity)).Value
        }
        $account = New-Object Security.Principal.NTAccount($Identity)
        return $account.Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
        return $null
    }
}

function Test-SameWindowsIdentity([string]$Candidate, [string[]]$CurrentIdentities) {
    if ($Candidate -in $CurrentIdentities) { return $true }
    $candidateSid = ConvertTo-WindowsSid $Candidate
    if (-not $candidateSid) { return $false }
    foreach ($current in $CurrentIdentities) {
        $currentSid = ConvertTo-WindowsSid $current
        if ($currentSid -and $currentSid -eq $candidateSid) { return $true }
    }
    return $false
}

function Assert-OwnedHermesHome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$CurrentIdentities,
        [string]$KnownOwner = ""
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { throw "The selected Hermes home is not a directory." }
    $owner = $KnownOwner
    if (-not $owner) {
        try { $owner = (Get-Acl -LiteralPath $Path -ErrorAction Stop).Owner } catch {
            throw "The selected Hermes home owner could not be verified."
        }
    }
    if (-not $owner -or $owner -notin $CurrentIdentities) {
        throw "The selected Hermes home is owned by another identity; no changes were made."
    }
}

function Assert-OwnedHermesTasks {
    [CmdletBinding()]
    param(
        [object[]]$Tasks,
        [Parameter(Mandatory = $true)][string[]]$CurrentIdentities,
        [Parameter(Mandatory = $true)][string]$ExpectedServicesDir
    )
    $runners = @{
        "HermesConsole-Gateway" = "hermes-gateway.vbs"
        "HermesConsole-Dashboard" = "hermes-dashboard.vbs"
        "HermesConsole-MobileBridge" = "hermes-bridge.vbs"
        "HermesConsole-Restart-Dashboard" = "restart-hermes-dashboard.vbs"
        "HermesConsole-Restart-MobileBridge" = "restart-hermes-bridge.vbs"
    }
    $legacy = @("Hermes Gateway", "Hermes Dashboard", "Hermes Mobile Bridge")
    foreach ($task in @($Tasks)) {
        if ($task.TaskName -in $legacy) {
            throw "Legacy task '$($task.TaskName)' has ambiguous ownership; remove it explicitly before repair."
        }
        if (-not $runners.ContainsKey([string]$task.TaskName)) { continue }
        if ($task.TaskPath -ne "\" -or -not $task.Principal -or
            -not (Test-SameWindowsIdentity $task.Principal.UserId $CurrentIdentities)) {
            throw "Task '$($task.TaskName)' is not owned by the current Hermes identity."
        }
        $actions = @($task.Actions)
        if ($actions.Count -ne 1) { throw "Task '$($task.TaskName)' has an ambiguous action set." }
        $action = $actions[0]
        $expectedRunner = Join-Path $ExpectedServicesDir $runners[[string]$task.TaskName]
        $expectedArguments = "//B //NoLogo `"$expectedRunner`""
        $executeName = @(([string]$action.Execute) -split '[\\/]')[-1]
        $expectedWorkingDirectory = Split-Path $ExpectedServicesDir -Parent
        if ($executeName -ne "wscript.exe" -or $action.Arguments -ne $expectedArguments -or
            $action.WorkingDirectory -ne $expectedWorkingDirectory) {
            throw "Task '$($task.TaskName)' does not belong to the selected Hermes home."
        }
    }
}

function Assert-OwnedPortRecords {
    [CmdletBinding()]
    param([object[]]$Records, [Parameter(Mandatory = $true)][string]$HermesHome)
    $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = $HermesHome.TrimEnd($trimChars) + [IO.Path]::DirectorySeparatorChar
    foreach ($record in @($Records)) {
        $executable = [string]$record.ExecutablePath
        $commandLine = [string]$record.CommandLine
        $owned = $executable.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            $commandLine.IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0
        if (-not $owned) {
            throw "TCP port $($record.Port) has a listener not owned by the selected Hermes home (PID $($record.Pid))."
        }
    }
}

function Get-ExistingHermesTasks {
    $command = Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue
    if (-not $command) { throw "Scheduled Task ownership cannot be verified on this Windows host." }
    try {
        $all = @(Get-ScheduledTask -ErrorAction Stop)
    } catch { throw "Scheduled Task ownership cannot be verified: $($_.Exception.Message)" }
    $names = @(
        "HermesConsole-Gateway", "HermesConsole-Dashboard", "HermesConsole-MobileBridge",
        "HermesConsole-Restart-Dashboard", "HermesConsole-Restart-MobileBridge",
        "Hermes Gateway", "Hermes Dashboard", "Hermes Mobile Bridge"
    )
    return @($all | Where-Object { $_.TaskName -in $names })
}

function Get-ExistingHermesPortRecords {
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        throw "TCP listener ownership cannot be verified on this Windows host."
    }
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($connection in @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalPort -in @(8642, 9119, 9131) })) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)" -ErrorAction Stop
        if (-not $process) { throw "TCP listener ownership could not be resolved for PID $($connection.OwningProcess)." }
        $records.Add([PSCustomObject]@{
            Port = [int]$connection.LocalPort
            Pid = [int]$connection.OwningProcess
            ExecutablePath = [string]$process.ExecutablePath
            CommandLine = [string]$process.CommandLine
        })
    }
    return $records.ToArray()
}

function Assert-SetupOwnership {
    if (-not (Test-WindowsPlatform)) { throw "This setup must run on native Windows." }
    $identities = @(Get-CurrentSetupIdentities)
    $homeOwners = @(Get-CurrentHomeOwnerIdentities)
    Assert-OwnedHermesHome -Path $HermesHome -CurrentIdentities $homeOwners
    $tasks = @(Get-ExistingHermesTasks)
    Assert-OwnedHermesTasks -Tasks $tasks -CurrentIdentities $identities -ExpectedServicesDir $ServicesDir
    Assert-OwnedPortRecords -Records @(Get-ExistingHermesPortRecords) -HermesHome $HermesHome

    $startup = [Environment]::GetFolderPath("Startup")
    if (-not $startup) { throw "The per-user Startup folder cannot be inspected." }
    $current = Get-IntegrationRunnerMap
    foreach ($name in $current.Keys) {
        $path = Join-Path $startup "$name.lnk"
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $runner = Join-Path $ServicesDir $current[$name]
        Assert-OwnedHermesShortcut $path $name $runner
    }
    foreach ($name in @("Hermes Gateway", "Hermes Dashboard", "Hermes Mobile Bridge")) {
        if (Test-Path -LiteralPath (Join-Path $startup "$name.lnk")) {
            throw "Legacy Startup shortcut '$name' has ambiguous ownership; remove it explicitly before repair."
        }
    }
}

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
    if (-not $AuditOnly) {
        [IO.File]::AppendAllText(
            $AuditLog,
            (($row | ConvertTo-Json -Compress) + [Environment]::NewLine),
            $Utf8NoBom
        )
    }
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
    # global de otra instalacio?n: funcionari?a durante el setup pero dejari?a
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
            if ($ExpectedVersion -and $health.version -ne $ExpectedVersion) { return $false }
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
    Write-AtomicBytes -Path $EnvFile -Bytes ($Utf8NoBom.GetBytes($payload))
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
    if (-not ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri))) {
        throw "Invalid service URL: $Url"
    }
    if ($uri.Scheme -notin @("http", "https") -or -not $uri.Host -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.Port -lt 1) {
        throw "Invalid service URL: $Url"
    }
    if ($uri.Scheme -eq "https") { return }
    if (-not (Test-PrivateHost $uri.Host)) {
        throw "Public HTTP is blocked. Use a LAN/Tailscale address or HTTPS: $Url"
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
    # Windows Script Host 5.1 consumes UTF-16LE reliably only when the BOM is present.
    $runnerEncoding = New-Object Text.UnicodeEncoding($false, $true)
    $runnerBytes = [byte[]]($runnerEncoding.GetPreamble() + $runnerEncoding.GetBytes($Content))
    Write-AtomicBytes -Path $path -Bytes $runnerBytes
    $script:RunnerChanged[$Name] = $true
    return $path
}

function Assert-OwnedHermesShortcut([string]$Path, [string]$Name, [string]$ExpectedScriptPath) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $expectedTarget = Join-Path $env:SystemRoot "System32\wscript.exe"
    $expectedArguments = "//B //NoLogo `"$ExpectedScriptPath`""
    if ($shortcut.TargetPath -ne $expectedTarget -or
        $shortcut.Arguments -ne $expectedArguments -or
        $shortcut.WorkingDirectory -ne $HermesHome) {
        throw "Startup shortcut '$Name' is not owned by the selected Hermes home."
    }
}

function Register-HermesTask([string]$TaskName, [string]$ScriptPath) {
    Import-Module ScheduledTasks -ErrorAction Stop
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
    $arguments = "//B //NoLogo `"$ScriptPath`""
    $current = Get-ExactScheduledTask $TaskName
    if ($current) {
        Assert-OwnedHermesTasks -Tasks @($current) `
            -CurrentIdentities @(Get-CurrentSetupIdentities) -ExpectedServicesDir $ServicesDir
    }
    $currentAction = if ($current) { @($current.Actions)[0] } else { $null }
    $same = $current -and $current.Settings.Enabled -and
        $currentAction.Execute -eq $wscript -and
        $currentAction.Arguments -eq $arguments -and
        $currentAction.WorkingDirectory -eq $HermesHome
    if ($same) {
        $script:TaskDefinitionsChanged[$TaskName] = $false
        Write-Audit "Task $TaskName" "SKIP" "Existing invisible definition retained"
        return $true
    }
    if ($AuditOnly) { throw "Scheduled Task $TaskName is missing or outdated." }
    if ($current) { Stop-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue }
    $action = New-ScheduledTaskAction -Execute $wscript `
        -Argument $arguments `
        -WorkingDirectory $HermesHome
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -TaskPath "\" -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
    $script:TaskDefinitionsChanged[$TaskName] = $true
    $startupLink = Join-Path ([Environment]::GetFolderPath("Startup")) "$TaskName.lnk"
    Assert-OwnedHermesShortcut $startupLink $TaskName $ScriptPath
    Remove-Item -LiteralPath $startupLink -Force -ErrorAction SilentlyContinue
    Write-Audit "Task $TaskName" "OK" "Created with invisible wscript.exe runner"
    return $true
}

function Register-HermesManualTask([string]$TaskName, [string]$ScriptPath) {
    Import-Module ScheduledTasks -ErrorAction Stop
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
    $arguments = "//B //NoLogo `"$ScriptPath`""
    $current = Get-ExactScheduledTask $TaskName
    if ($current) {
        Assert-OwnedHermesTasks -Tasks @($current) `
            -CurrentIdentities @(Get-CurrentSetupIdentities) -ExpectedServicesDir $ServicesDir
    }
    $currentAction = if ($current) { @($current.Actions)[0] } else { $null }
    $same = $current -and $current.Settings.Enabled -and
        $currentAction.Execute -eq $wscript -and
        $currentAction.Arguments -eq $arguments -and
        $currentAction.WorkingDirectory -eq $HermesHome
    if ($same) {
        $script:TaskDefinitionsChanged[$TaskName] = $false
        Write-Audit "Task $TaskName" "SKIP" "Manual restart definition retained"
        return $true
    }
    if ($AuditOnly) { throw "Manual task $TaskName is missing or outdated." }
    if ($current) { Stop-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue }
    $action = New-ScheduledTaskAction -Execute $wscript `
        -Argument $arguments `
        -WorkingDirectory $HermesHome
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
        -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -TaskPath "\" -Action $action -Settings $settings `
        -Principal $principal -Force -ErrorAction Stop | Out-Null
    $script:TaskDefinitionsChanged[$TaskName] = $true
    $startupLink = Join-Path ([Environment]::GetFolderPath("Startup")) "$TaskName.lnk"
    Assert-OwnedHermesShortcut $startupLink $TaskName $ScriptPath
    Remove-Item -LiteralPath $startupLink -Force -ErrorAction SilentlyContinue
    Write-Audit "Task $TaskName" "OK" "Manual restart task created windowless"
    return $true
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

function Stop-OwnedHermesListener([int]$Port, [string]$TaskName) {
    $records = @(Get-ExistingHermesPortRecords | Where-Object { $_.Port -eq $Port })
    if ($records.Count -eq 0) { return }
    if ($records.Count -ne 1) {
        throw "$TaskName port $Port has an ambiguous listener set."
    }
    Assert-OwnedPortRecords -Records $records -HermesHome $HermesHome
    $record = $records[0]
    try {
        $ownedProcess = Get-Process -Id $record.Pid -ErrorAction Stop
        [void]$ownedProcess.Handle
        $livePath = $ownedProcess.Path
    } catch {
        throw "$TaskName listener PID $($record.Pid) could not be handle-anchored safely."
    }
    if (-not $livePath -or -not $record.ExecutablePath -or
        -not [IO.Path]::GetFullPath($livePath).Equals(
            [IO.Path]::GetFullPath([string]$record.ExecutablePath),
            [StringComparison]::OrdinalIgnoreCase)) {
        $ownedProcess.Dispose()
        throw "$TaskName listener identity changed before termination; refusing to kill it."
    }
    try {
        $ownedProcess.Kill()
        if (-not $ownedProcess.WaitForExit(5000)) {
            throw "$TaskName owned listener did not terminate within 5 seconds."
        }
    } finally {
        $ownedProcess.Dispose()
    }
    Wait-PortRelease $Port 5
    Assert-PortAvailable $Port $TaskName
}

function Start-HermesProcess(
    [string]$TaskName,
    [int]$Port = 0
) {
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction Stop
    if (-not $task -or -not $task.Settings.Enabled) {
        throw "Mandatory Scheduled Task '$TaskName' is unavailable or disabled."
    }
    Stop-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue
    if ($Port -gt 0) {
        Wait-PortRelease $Port 5
        if (Get-PortOwner $Port) {
            Stop-OwnedHermesListener $Port $TaskName
        } else {
            Assert-PortAvailable $Port $TaskName
        }
    }
    Start-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction Stop
}

function Remove-LegacyTasks {
    foreach ($name in @("Hermes Gateway", "Hermes Dashboard", "Hermes Mobile Bridge")) {
        Import-Module ScheduledTasks -ErrorAction Stop
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            throw "Legacy task '$name' requires explicit owner cleanup; setup will not remove it automatically."
        }
        $startup = [Environment]::GetFolderPath("Startup")
        if ($startup) {
            $legacyLink = Join-Path $startup "$name.lnk"
            if (Test-Path -LiteralPath $legacyLink) {
                throw "Legacy Startup shortcut '$name' requires explicit owner cleanup; setup will not remove it automatically."
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
        # La li?nea de comandos puede contener tokens o credenciales. PID y
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

function Initialize-WindowsJobApi {
    if (-not (Test-WindowsPlatform)) { throw "Windows Job Objects require native Windows." }
    if ("HermesConsole.NativeJobProcess" -as [type]) { return }
    $source = @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace HermesConsole {
    public sealed class NativeJobProcess : IDisposable {
        const uint CREATE_SUSPENDED = 0x00000004;
        const uint CREATE_NO_WINDOW = 0x08000000;
        const uint STARTF_USESTDHANDLES = 0x00000100;
        const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint CREATE_ALWAYS = 2;
        const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        const uint HANDLE_FLAG_INHERIT = 0x00000001;
        const uint WAIT_OBJECT_0 = 0;
        const uint WAIT_TIMEOUT = 258;

        IntPtr job;
        IntPtr process;
        bool disposed;

        [StructLayout(LayoutKind.Sequential)]
        struct SECURITY_ATTRIBUTES {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO {
            public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
            public int dwX; public int dwY; public int dwXSize; public int dwYSize;
            public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute;
            public uint dwFlags; public short wShowWindow; public short cbReserved2;
            public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION {
            public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS {
            public ulong ReadOperationCount; public ulong WriteOperationCount; public ulong OtherOperationCount;
            public ulong ReadTransferCount; public ulong WriteTransferCount; public ulong OtherTransferCount;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
            public long TotalUserTime; public long TotalKernelTime; public long ThisPeriodTotalUserTime;
            public long ThisPeriodTotalKernelTime; public uint TotalPageFaultCount;
            public uint TotalProcesses; public uint ActiveProcesses; public uint TotalTerminatedProcesses;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length, IntPtr returnLength);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFile(string name, uint access, uint share, ref SECURITY_ATTRIBUTES security,
            uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CreatePipe(out IntPtr readPipe, out IntPtr writePipe, ref SECURITY_ATTRIBUTES security, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcess(string application, StringBuilder commandLine, IntPtr processAttributes,
            IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string currentDirectory,
            ref STARTUPINFO startup, out PROCESS_INFORMATION processInfo);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);

        NativeJobProcess(IntPtr jobHandle, IntPtr processHandle) {
            job = jobHandle; process = processHandle;
        }

        static void ThrowLast(string operation) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }
        static string Quote(string value) {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
        static void CloseIfValid(ref IntPtr handle) {
            if (handle != IntPtr.Zero && handle != new IntPtr(-1)) { CloseHandle(handle); }
            handle = IntPtr.Zero;
        }

        public static NativeJobProcess Start(string file, string arguments, string currentDirectory,
            string stdoutPath, string stderrPath, string standardInput) {
            IntPtr jobHandle = IntPtr.Zero;
            IntPtr stdoutHandle = IntPtr.Zero;
            IntPtr stderrHandle = IntPtr.Zero;
            IntPtr stdinRead = IntPtr.Zero;
            IntPtr stdinWrite = IntPtr.Zero;
            PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
            bool assigned = false;
            try {
                jobHandle = CreateJobObject(IntPtr.Zero, null);
                if (jobHandle == IntPtr.Zero) ThrowLast("CreateJobObject failed");
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                int limitSize = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                IntPtr limitPtr = Marshal.AllocHGlobal(limitSize);
                try {
                    Marshal.StructureToPtr(limits, limitPtr, false);
                    if (!SetInformationJobObject(jobHandle, 9, limitPtr, (uint)limitSize))
                        ThrowLast("SetInformationJobObject failed");
                } finally { Marshal.FreeHGlobal(limitPtr); }

                SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
                sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
                sa.bInheritHandle = true;
                stdoutHandle = CreateFile(stdoutPath, GENERIC_WRITE, FILE_SHARE_READ, ref sa,
                    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
                if (stdoutHandle == new IntPtr(-1)) ThrowLast("CreateFile stdout failed");
                stderrHandle = CreateFile(stderrPath, GENERIC_WRITE, FILE_SHARE_READ, ref sa,
                    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
                if (stderrHandle == new IntPtr(-1)) ThrowLast("CreateFile stderr failed");
                if (!CreatePipe(out stdinRead, out stdinWrite, ref sa, 0)) ThrowLast("CreatePipe failed");
                if (!SetHandleInformation(stdinWrite, HANDLE_FLAG_INHERIT, 0)) ThrowLast("SetHandleInformation failed");

                STARTUPINFO startup = new STARTUPINFO();
                startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                startup.dwFlags = STARTF_USESTDHANDLES;
                startup.hStdInput = stdinRead;
                startup.hStdOutput = stdoutHandle;
                startup.hStdError = stderrHandle;
                StringBuilder commandLine = new StringBuilder(Quote(file) + (String.IsNullOrEmpty(arguments) ? "" : " " + arguments));
                if (!CreateProcess(file, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                    CREATE_SUSPENDED | CREATE_NO_WINDOW, IntPtr.Zero, currentDirectory, ref startup, out pi))
                    ThrowLast("CreateProcess failed");
                if (!AssignProcessToJobObject(jobHandle, pi.hProcess))
                    ThrowLast("AssignProcessToJobObject failed");
                assigned = true;
                CloseIfValid(ref stdinRead);
                CloseIfValid(ref stdoutHandle);
                CloseIfValid(ref stderrHandle);

                using (FileStream input = new FileStream(new SafeFileHandle(stdinWrite, true), FileAccess.Write)) {
                    stdinWrite = IntPtr.Zero;
                    if (!String.IsNullOrEmpty(standardInput)) {
                        byte[] bytes = new UTF8Encoding(false).GetBytes(standardInput);
                        input.Write(bytes, 0, bytes.Length);
                    }
                }
                NativeJobProcess result = new NativeJobProcess(jobHandle, pi.hProcess);
                jobHandle = IntPtr.Zero; pi.hProcess = IntPtr.Zero;
                if (ResumeThread(pi.hThread) == UInt32.MaxValue) {
                    int resumeError = Marshal.GetLastWin32Error();
                    result.Dispose();
                    throw new Win32Exception(resumeError, "ResumeThread failed");
                }
                CloseIfValid(ref pi.hThread);
                return result;
            } catch {
                if (pi.hProcess != IntPtr.Zero) TerminateProcess(pi.hProcess, 125);
                throw;
            } finally {
                CloseIfValid(ref pi.hThread); CloseIfValid(ref pi.hProcess);
                CloseIfValid(ref stdinRead); CloseIfValid(ref stdinWrite);
                CloseIfValid(ref stdoutHandle); CloseIfValid(ref stderrHandle);
                if (jobHandle != IntPtr.Zero) {
                    if (assigned) TerminateJobObject(jobHandle, 125);
                    CloseHandle(jobHandle);
                }
            }
        }

        public bool WaitForQuiescence(int milliseconds) {
            Stopwatch watch = Stopwatch.StartNew();
            do {
                JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting = new JOBOBJECT_BASIC_ACCOUNTING_INFORMATION();
                int size = Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                IntPtr ptr = Marshal.AllocHGlobal(size);
                try {
                    if (!QueryInformationJobObject(job, 1, ptr, (uint)size, IntPtr.Zero))
                        ThrowLast("QueryInformationJobObject failed");
                    accounting = (JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(
                        ptr, typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                    if (accounting.ActiveProcesses == 0) return true;
                } finally { Marshal.FreeHGlobal(ptr); }
                System.Threading.Thread.Sleep(25);
            } while (watch.ElapsedMilliseconds < milliseconds);
            return false;
        }

        public bool TerminateAndVerify(int milliseconds) {
            if (!TerminateJobObject(job, 124)) return false;
            return WaitForQuiescence(milliseconds);
        }

        public int GetRootExitCode() {
            uint result = WaitForSingleObject(process, 0);
            if (result == WAIT_TIMEOUT) throw new InvalidOperationException("Root process is still running.");
            if (result != WAIT_OBJECT_0) ThrowLast("WaitForSingleObject failed");
            uint exitCode;
            if (!GetExitCodeProcess(process, out exitCode)) ThrowLast("GetExitCodeProcess failed");
            return unchecked((int)exitCode);
        }

        public void Dispose() {
            if (disposed) return;
            disposed = true;
            CloseIfValid(ref process);
            CloseIfValid(ref job);
            GC.SuppressFinalize(this);
        }
        ~NativeJobProcess() { Dispose(); }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Stop-ContainedProcessAfterTimeout($JobProcess, [int]$TimeoutMilliseconds) {
    if ($JobProcess.TerminateAndVerify($TimeoutMilliseconds)) { return $true }
    $script:MutationQuiescent = $false
    $script:UnresolvedContainedProcess = $JobProcess
    return $false
}

function Invoke-ContainedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string]$Arguments = "",
        [ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [ValidateRange(1, 300)][int]$TerminationTimeoutSeconds = 15,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [string]$StandardInput = ""
    )
    Initialize-WindowsJobApi
    $jobProcess = $null
    $retain = $false
    $verifiedQuiescent = $false
    try {
        $jobProcess = [HermesConsole.NativeJobProcess]::Start(
            $File, $Arguments, $HermesHome, $StdoutPath, $StderrPath, $StandardInput
        )
        if (-not $jobProcess.WaitForQuiescence($TimeoutSeconds * 1000)) {
            if (-not (Stop-ContainedProcessAfterTimeout $jobProcess ($TerminationTimeoutSeconds * 1000))) {
                $retain = $true
                throw "Timed-out process containment could not be verified; the setup lock remains held for this host process."
            }
            $verifiedQuiescent = $true
            throw "Process timed out after ${TimeoutSeconds}s; its Windows Job Object was terminated and verified quiescent."
        }
        $verifiedQuiescent = $true
        return [PSCustomObject]@{
            ExitCode = $jobProcess.GetRootExitCode()
            TimedOut = $false
        }
    } catch {
        if ($jobProcess -and -not $verifiedQuiescent) {
            $script:MutationQuiescent = $false
            $script:UnresolvedContainedProcess = $jobProcess
            $retain = $true
        }
        throw
    } finally {
        if ($jobProcess -and -not $retain) { $jobProcess.Dispose() }
    }
}

function Invoke-HiddenProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string]$Arguments = "",
        [ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Operation
    )
    $result = Invoke-ContainedProcess -File $File -Arguments $Arguments `
        -TimeoutSeconds $TimeoutSeconds -TerminationTimeoutSeconds $script:TerminationTimeoutSeconds `
        -StdoutPath $StdoutPath -StderrPath $StderrPath
    if ($null -eq $result.ExitCode) {
        throw "$Operation failed because Windows did not provide a process exit code."
    }
    if ([int]$result.ExitCode -ne 0) {
        throw "$Operation failed (exit code $([int]$result.ExitCode))."
    }
}

function Get-RestrictedFirewallRuleState([string]$DisplayName, [string]$Kind) {
    try {
        Import-Module NetSecurity -ErrorAction Stop
        $rules = @(Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue)
        if ($rules.Count -eq 0) { return "Absent" }
        if ($rules.Count -ne 1) { return "Conflict" }
        $rule = $rules[0]
        $expectedProfile = if ($Kind -eq "mesh") { "Any" } else { "Private" }
        $expectedRemote = if ($Kind -eq "mesh") {
            @("100.64.0.0/10", "100.64.0.0/255.192.0.0")
        } else { @("LocalSubnet") }
        if ($rule.Enabled.ToString() -ne "True" -or
            $rule.Direction.ToString() -ne "Inbound" -or
            $rule.Action.ToString() -ne "Allow" -or
            $rule.Profile.ToString() -ne $expectedProfile) {
            return "Conflict"
        }
        $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction Stop
        $addressFilter = $rule | Get-NetFirewallAddressFilter -ErrorAction Stop
        if ($portFilter.Protocol.ToString() -notin @("TCP", "6")) { return "Conflict" }
        $ports = @($portFilter.LocalPort | ForEach-Object {
            $_.ToString().Split(',') | ForEach-Object { $_.Trim() }
        } | Sort-Object -Unique)
        $requiredPorts = @("8642", "9119", "9131")
        if (@(Compare-Object $requiredPorts $ports).Count -ne 0) { return "Conflict" }
        $addresses = @($addressFilter.RemoteAddress | ForEach-Object {
            $_.ToString().Split(',') | ForEach-Object { $_.Trim() }
        } | Sort-Object -Unique)
        if ($addresses.Count -ne 1 -or $addresses[0] -notin $expectedRemote) { return "Conflict" }
        $localAddresses = @($addressFilter.LocalAddress | ForEach-Object {
            $_.ToString().Split(',') | ForEach-Object { $_.Trim() }
        } | Sort-Object -Unique)
        if ($localAddresses.Count -ne 1 -or $localAddresses[0] -ne "Any") { return "Conflict" }
        return "Exact"
    } catch {
        return "Unverifiable"
    }
}

function Test-RestrictedFirewallRule([string]$DisplayName, [string]$Kind) {
    return (Get-RestrictedFirewallRuleState $DisplayName $Kind) -eq "Exact"
}

function Test-CurrentProcessAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-FirewallPreflight([hashtable]$Pairing) {
    if ($Pairing.Scheme -eq "https") { return }
    $display = if ($Pairing.Kind -eq "mesh") {
        "Hermes Console Tailscale"
    } else {
        "Hermes Console private network"
    }
    if ($Pairing.Kind -eq "lan" -and $Pairing.InterfaceIndex) {
        $profile = Get-NetConnectionProfile -InterfaceIndex $Pairing.InterfaceIndex -ErrorAction SilentlyContinue
        if ($profile -and $profile.NetworkCategory -ne "Private") {
            throw "The selected LAN is '$($profile.NetworkCategory)'. Mark it Private or use Tailscale before exposing Hermes. No changes were made."
        }
    }
    $state = Get-RestrictedFirewallRuleState $display $Pairing.Kind
    if ($state -eq "Unverifiable") {
        throw "Existing Windows Firewall state could not be verified; no changes were made."
    }
    if ($state -eq "Conflict") {
        throw "A pre-existing Hermes Windows Firewall rule is not exact; setup refuses to replace or broaden it. No changes were made."
    }
    if ($state -eq "Exact" -or (Test-CurrentProcessAdministrator)) { return }
    throw "A restricted Windows Firewall rule is required. Re-run setup from an already elevated PowerShell terminal; setup never opens UAC or secondary windows. No changes were made."
}

function Ensure-PrivateFirewallRules([hashtable]$Pairing) {
    if ($Pairing.Scheme -eq "https") { return }
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
    $state = Get-RestrictedFirewallRuleState $display $Pairing.Kind
    if ($state -eq "Exact") {
        Write-Ok "Existing restricted Windows Firewall rule verified"
        return
    }
    if ($state -ne "Absent") {
        throw "A pre-existing Hermes Windows Firewall rule is not exact; setup will not modify it."
    }
    if ($AuditOnly) { throw "Restricted Windows Firewall rule is missing." }
    if (-not (Test-CurrentProcessAdministrator)) {
        throw "A restricted Windows Firewall rule is required. Re-run setup from an already elevated PowerShell terminal; setup never opens UAC or secondary windows. No QR was generated."
    }
    if ($null -eq $script:SetupTransaction) { throw "Firewall creation requires an active setup transaction." }
    $ruleName = "HermesConsole-$AttemptId"
    try {
        Import-Module NetSecurity -ErrorAction Stop
        if ($Pairing.Kind -eq "mesh") {
            New-NetFirewallRule -Name $ruleName -DisplayName $display -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort 8642, 9119, 9131 -Profile Any `
                -RemoteAddress "100.64.0.0/10" -ErrorAction Stop | Out-Null
        } else {
            New-NetFirewallRule -Name $ruleName -DisplayName $display -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort 8642, 9119, 9131 -Profile Private `
                -RemoteAddress LocalSubnet -ErrorAction Stop | Out-Null
        }
        $script:SetupTransaction.FirewallRuleName = $ruleName
        $script:FirewallRuleCreatedName = $ruleName
        if ((Get-RestrictedFirewallRuleState $display $Pairing.Kind) -ne "Exact") {
            throw "Created firewall rule did not verify exactly."
        }
        Write-TransactionJournal $script:SetupTransaction "firewall-create" "ok"
        Write-Ok $(if ($Pairing.Kind -eq "mesh") {
            "Tailscale-only Windows Firewall rule installed"
        } else {
            "Private-LAN Windows Firewall rule installed"
        })
    } catch {
        throw "Could not configure a restricted Windows Firewall rule without replacing existing state."
    }
}

function Test-HermesLauncher([string]$Executable, [int]$TimeoutSeconds = 15) {
    if (-not $Executable -or -not (Test-Path -LiteralPath $Executable)) { return $false }
    $probeId = [Guid]::NewGuid().ToString("N")
    $stdout = Join-Path ([IO.Path]::GetTempPath()) "hermes-launcher-$probeId.out.log"
    $stderr = Join-Path ([IO.Path]::GetTempPath()) "hermes-launcher-$probeId.err.log"
    try {
        $result = Invoke-ContainedProcess -File $Executable -Arguments "--version" `
            -TimeoutSeconds $TimeoutSeconds -TerminationTimeoutSeconds $script:TerminationTimeoutSeconds `
            -StdoutPath $stdout -StderrPath $stderr
        return $result.ExitCode -eq 0
    } catch {
        if (-not $script:MutationQuiescent) { throw }
        return $false
    } finally {
        if ($script:MutationQuiescent) {
            Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-PythonSnippet(
    [string]$Python,
    [string]$Code,
    [string[]]$ExtraArguments = @(),
    [int]$TimeoutSeconds = 15
) {
    if (-not $Python -or -not (Test-Path -LiteralPath $Python)) { return $false }
    $probeId = [Guid]::NewGuid().ToString("N")
    $stdout = Join-Path ([IO.Path]::GetTempPath()) "hermes-python-$probeId.out.log"
    $stderr = Join-Path ([IO.Path]::GetTempPath()) "hermes-python-$probeId.err.log"
    $escapedCode = $Code.Replace('"', '\"')
    $arguments = "-c `"$escapedCode`""
    foreach ($value in @($ExtraArguments)) {
        $arguments += " `"$($value.Replace('"', '\"'))`""
    }
    try {
        $result = Invoke-ContainedProcess -File $Python -Arguments $arguments `
            -TimeoutSeconds $TimeoutSeconds -TerminationTimeoutSeconds $script:TerminationTimeoutSeconds `
            -StdoutPath $stdout -StderrPath $stderr
        return $result.ExitCode -eq 0
    } catch {
        if (-not $script:MutationQuiescent) { throw }
        return $false
    } finally {
        if ($script:MutationQuiescent) {
            Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-FreshHermesInstallArtifacts {
    return @(
        $InstallDir,
        (Join-Path $HermesHome "node"),
        (Join-Path $HermesBinDir "hermes.exe"),
        (Join-Path $HermesBinDir "hermes.cmd"),
        (Join-Path $HermesBinDir "hermes.ps1"),
        (Join-Path $HermesBinDir "hermes"),
        (Join-Path $HermesBinDir "uv.exe"),
        (Join-Path $HermesBinDir "uvx.exe"),
        (Join-Path $HermesBinDir "uv"),
        (Join-Path $HermesBinDir "uvx")
    )
}

function Remove-FreshHermesInstallArtifacts([string[]]$Paths) {
    if (-not $script:MutationQuiescent) {
        throw "Fresh Hermes artifacts cannot be cleaned while process quiescence is unresolved."
    }
    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        }
    }
}

function Remove-EmptyAttemptDirectories {
    $paths = @($script:SetupDirectoryExistedAtStart.Keys) |
        Sort-Object { ([string]$_).Length } -Descending
    foreach ($path in $paths) {
        if ($script:SetupDirectoryExistedAtStart[$path]) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        if (@(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop).Count -eq 0) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
}

function Save-VerifiedHermesAgentInstaller {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Destination)

    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    try {
        Invoke-WebRequest -Uri $script:HermesAgentInstallerUrl `
            -OutFile $Destination -UseBasicParsing
    } catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "Hermes Agent installer download failed. Check internet, proxy, and TLS access. No installation changes were made."
    }

    try {
        $item = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
        $digest = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($item.Length -ne $script:HermesAgentInstallerSize -or
            $digest -ne $script:HermesAgentInstallerSha256) {
            throw "Installer bytes did not match the pinned release."
        }
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $Destination, [ref]$tokens, [ref]$errors
        )
        if (@($errors).Count -ne 0) { throw "Installer did not parse as PowerShell." }
    } catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "Hermes Agent installer integrity verification failed. No installation changes were made."
    }
}

function Install-HermesIfNeeded {
    $hermes = Get-HermesExecutable
    if ($hermes -and (Test-HermesLauncher $hermes 15)) {
        Write-Audit "Hermes Agent" "SKIP" "Installed launcher command verified"
        return $hermes
    }
    if ($AuditOnly) { throw "Hermes Agent is not installed or is broken." }

    $freshArtifacts = @(Get-FreshHermesInstallArtifacts)
    $existingArtifacts = @($freshArtifacts | Where-Object { Test-Path -LiteralPath $_ })
    if ($existingArtifacts.Count -gt 0) {
        throw "Hermes Agent state exists but is not healthy; refusing to run the installer over it. Remove or repair the broken managed state explicitly."
    }

    Write-Info "Installing Hermes Agent for native Windows..."
    Write-Info "The official installer can take several minutes on a clean Windows host; setup will wait safely."
    $installer = $AttemptPaths.Installer
    try {
        Save-VerifiedHermesAgentInstaller -Destination $installer
        $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installer`" " +
            "-SkipSetup -SkipComputerUse -NonInteractive -Json -Commit $($script:HermesAgentCommit) " +
            "-HermesHome `"$HermesHome`" -InstallDir `"$InstallDir`""
        Invoke-HiddenProcess -File (Get-PowerShellExecutable) -Arguments $arguments `
            -TimeoutSeconds $script:HermesInstallTimeoutSeconds `
            -StdoutPath $AttemptPaths.InstallerOut `
            -StderrPath $AttemptPaths.InstallerErr `
            -Operation "Hermes Agent installer"

        $hermes = Get-HermesExecutable
        if (-not $hermes) { throw "Hermes Agent executable was not found after installation." }
        if (-not (Test-HermesLauncher $hermes 15)) {
            throw "Hermes Agent launcher did not pass health after the official installer completed."
        }
        Write-Audit "Hermes Agent" "OK" "Installed; launcher command verified"
        return $hermes
    } catch {
        if ($script:MutationQuiescent) {
            Remove-FreshHermesInstallArtifacts -Paths $freshArtifacts
        }
        throw
    } finally {
        if ($script:MutationQuiescent) {
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }
    }
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
        # Compila en memoria sin crear __pycache__. El proceso queda contenido
        # y acotado igual que las dema?s herramientas nativas del setup.
        return Test-PythonSnippet $Python `
            'import pathlib,sys;compile(pathlib.Path(sys.argv[1]).read_bytes(),sys.argv[1],"exec")' `
            @($Path) 20
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

function Get-HermesUv {
    $candidate = Join-Path $HermesHome "bin\uv.exe"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Write-PairingQr([string]$Python, [string]$Link) {
    $qrScript = $AttemptPaths.QrScript
    $qrNew = $AttemptPaths.QrNew
    $qrSource = @'
import binascii
import struct
import sys
import zlib

import qrcode

link = sys.stdin.read()
if not link:
    raise SystemExit("empty pairing payload")
qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=4, box_size=1)
qr.add_data(link)
qr.make(fit=True)
matrix = qr.get_matrix()
scale = 8
width = len(matrix) * scale
rows = []
for row in matrix:
    pixels = bytes(value for cell in row for value in ([0] if cell else [255]) * scale)
    scanline = b"\x00" + pixels
    rows.extend([scanline] * scale)

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, width, 8, 0, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
png += chunk(b"IEND", b"")
with open(sys.argv[1], "wb") as handle:
    handle.write(png)
'@
    [IO.File]::WriteAllText($qrScript, $qrSource, $Utf8NoBom)
    $qrProcess = $Python
    $qrArguments = "`"$qrScript`" `"$qrNew`""
    if (-not (Test-PythonSnippet $Python "import qrcode" @() 10)) {
        $uv = Get-HermesUv
        if (-not $uv) {
            throw "Pairing QR generation requires the verified Hermes uv runtime."
        }
        $qrProcess = $uv
        $qrArguments = "run --isolated --no-project --python `"$Python`" --with qrcode==8.2 python `"$qrScript`" `"$qrNew`""
    }
    try {
        $qrOut = Join-Path $AuditDir "pairing-qr-$AttemptId.out.log"
        $qrErr = Join-Path $AuditDir "pairing-qr-$AttemptId.err.log"
        $result = Invoke-ContainedProcess -File $qrProcess `
            -Arguments $qrArguments -TimeoutSeconds 90 `
            -TerminationTimeoutSeconds $script:TerminationTimeoutSeconds `
            -StdoutPath $qrOut -StderrPath $qrErr -StandardInput $Link
        $validPng = $false
        if ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $qrNew)) {
            $png = [IO.File]::ReadAllBytes($qrNew)
            $validPng = $png.Length -ge 24 -and
                $png[0] -eq 0x89 -and $png[1] -eq 0x50 -and $png[2] -eq 0x4E -and $png[3] -eq 0x47 -and
                $png[4] -eq 0x0D -and $png[5] -eq 0x0A -and $png[6] -eq 0x1A -and $png[7] -eq 0x0A
        }
        if (-not $validPng) {
            throw "Pairing QR generation failed without producing a verified PNG file."
        }
        Write-AtomicBytes -Path $QrFile -Bytes $png
    } finally {
        if ($script:MutationQuiescent) {
            Remove-Item -LiteralPath $qrScript, $qrNew, $qrOut, $qrErr -Force -ErrorAction SilentlyContinue
        }
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
        if (-not (Test-HermesLauncher $hermes 15)) {
            [void]$missing.Add("Healthy Hermes Agent executable")
        }
    }

    $python = Get-HermesPython
    if (-not $python) {
        [void]$missing.Add("Hermes virtual-environment Python")
    } else {
        if (-not (Test-PythonSnippet $python "import aiohttp" @() 15)) {
            [void]$missing.Add("Python package aiohttp")
        }
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
        if (-not $persistent) { [void]$missing.Add("Exact mandatory Scheduled Task for $name") }
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
            $credentials = Invoke-HermesJsonRequest -Method Get `
                -Url "http://127.0.0.1:9131/bridge/dashboard/credentials" `
                -Token $key -TimeoutSeconds 4
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

if ($env:HERMES_SETUP_REVIEW_MODE -eq "synthetic-canary") {
    Write-Output "HERMES_SETUP_REVIEW_MODE_OK"
    return
}

function Test-OwnedListenerForHome([int]$Port, [string]$HomePath) {
    try {
        $records = @(Get-ExistingHermesPortRecords | Where-Object { $_.Port -eq $Port })
        if ($records.Count -eq 0) { return $false }
        try { Assert-OwnedPortRecords -Records $records -HermesHome $HomePath } catch { return $false }
        return $true
    } catch {
        return $false
    }
}

function New-PreflightCheck([string]$Name, [string]$Status, [string]$Detail, [string]$Remedy) {
    return [PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail; Remedy = $Remedy }
}

function Invoke-SetupPreflight {
    # Read-only environment checklist: every condition a normal run needs, with
    # one remediation line per failure. Runs before any lock, download or write.
    $checks = New-Object System.Collections.Generic.List[object]
    $nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }

    try {
        Assert-SupportedWindows
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $checks.Add((New-PreflightCheck "Windows edition" "PASS" `
            ("$(([string]$os.Caption).Trim()), build $($os.BuildNumber), $nativeArchitecture") ""))
    } catch {
        $checks.Add((New-PreflightCheck "Windows edition" "FAIL" $_.Exception.Message `
            "Use Windows 10, Windows 11 or Windows Server on x64 or ARM64."))
    }

    $psVersion = $PSVersionTable.PSVersion.ToString()
    if ($PSVersionTable.PSEdition -eq "Core" -and $PSVersionTable.PSVersion.Major -lt 7) {
        $checks.Add((New-PreflightCheck "PowerShell" "FAIL" $psVersion `
            "Use Windows PowerShell 5.1 or PowerShell 7 or newer."))
    } else {
        $checks.Add((New-PreflightCheck "PowerShell" "PASS" `
            "$psVersion ($($PSVersionTable.PSEdition))" ""))
    }

    $isElevated = $false
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isElevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {}
    $checks.Add((New-PreflightCheck "Elevation" $(if ($isElevated) { "PASS" } else { "WARN" }) `
        $(if ($isElevated) { "elevated" } else { "standard user token" }) `
        "Required only to create the restricted Windows Firewall rule; rerun from an elevated terminal if setup asks for it."))

    try {
        $resolvedHome = Resolve-HermesHome $HermesHome
        $checks.Add((New-PreflightCheck "HERMES_HOME" "PASS" $resolvedHome ""))
    } catch {
        $checks.Add((New-PreflightCheck "HERMES_HOME" "FAIL" $_.Exception.Message `
            "Set HERMES_HOME to one absolute, non-root path."))
        $resolvedHome = $null
    }

    if ($resolvedHome) {
        try {
            if (Test-Path -LiteralPath $resolvedHome) {
                $probe = Join-Path $resolvedHome (".hermes-preflight-" + [Guid]::NewGuid().ToString("N"))
                [IO.File]::WriteAllText($probe, "probe")
                Remove-Item -LiteralPath $probe -Force
                $checks.Add((New-PreflightCheck "Home writable" "PASS" "write probe removed" ""))
            } else {
                $checks.Add((New-PreflightCheck "Home writable" "PASS" "fresh home will be created" ""))
            }
        } catch {
            $checks.Add((New-PreflightCheck "Home writable" "FAIL" $_.Exception.Message `
                "Grant the current user write access to HERMES_HOME or choose another path."))
        }
    }

    foreach ($endpoint in @(
        @{ Host = "raw.githubusercontent.com"; Why = "setup, Bridge and manifest downloads" },
        @{ Host = "hermes-agent.nousresearch.com"; Why = "official Hermes Agent installer" }
    )) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $response = Invoke-WebRequest -Uri "https://$($endpoint.Host)/" -Method Head -UseBasicParsing -TimeoutSec 10
            $checks.Add((New-PreflightCheck "Reach $($endpoint.Host)" "PASS" `
                "HTTP $([int]$response.StatusCode) - $($endpoint.Why)" ""))
        } catch {
            $checks.Add((New-PreflightCheck "Reach $($endpoint.Host)" "FAIL" $_.Exception.Message `
                "Check DNS, proxy and outbound TLS; setup cannot download without it."))
        }
    }

    $pairing = $null
    try {
        $pairing = Get-PairingConfiguration
        $checks.Add((New-PreflightCheck "Phone-facing address" "PASS" `
            "$($pairing.Scheme)://$($pairing.Address):$($pairing.Port) ($($pairing.Kind))" ""))
    } catch {
        $checks.Add((New-PreflightCheck "Phone-facing address" "FAIL" $_.Exception.Message `
            "Connect Tailscale, join a private LAN, or set HERMES_PAIR_HOST with HERMES_PAIR_SCHEME=https."))
    }

    if ($pairing -and $pairing.Scheme -eq "http" -and $pairing.Kind -eq "lan" -and $pairing.InterfaceIndex) {
        try {
            $profile = Get-NetConnectionProfile -InterfaceIndex $pairing.InterfaceIndex -ErrorAction Stop
            if ($profile.NetworkCategory -eq "Private") {
                $checks.Add((New-PreflightCheck "Network profile" "PASS" "Private" ""))
            } else {
                $checks.Add((New-PreflightCheck "Network profile" "FAIL" $profile.NetworkCategory `
                    "Mark the selected network as Private: Set-NetConnectionProfile -InterfaceIndex $($pairing.InterfaceIndex) -NetworkCategory Private"))
            }
        } catch {
            $checks.Add((New-PreflightCheck "Network profile" "WARN" $_.Exception.Message `
                "Verify the network is Private before exposing Hermes on the LAN."))
        }
    }

    foreach ($service in @(
        @{ Port = 8642; Name = "Gateway" },
        @{ Port = 9119; Name = "Dashboard" },
        @{ Port = 9131; Name = "Mobile Bridge" }
    )) {
        try {
            $owner = Get-PortOwner $service.Port
            if (-not $owner) {
                $checks.Add((New-PreflightCheck "Port $($service.Port)" "PASS" "free" ""))
            } elseif ($resolvedHome -and (Test-OwnedListenerForHome $service.Port $resolvedHome)) {
                $checks.Add((New-PreflightCheck "Port $($service.Port)" "PASS" `
                    "in use by this Hermes home (PID $($owner.Pid) $($owner.Name))" ""))
            } else {
                $checks.Add((New-PreflightCheck "Port $($service.Port)" "FAIL" `
                    "occupied by PID $($owner.Pid) $($owner.Name)" `
                    "Stop the process using TCP $($service.Port) or set another HERMES_HOME."))
            }
        } catch {
            $checks.Add((New-PreflightCheck "Port $($service.Port)" "FAIL" $_.Exception.Message `
                "TCP listener ownership could not be verified on this host."))
        }
    }

    try {
        $dist = Join-Path $InstallDir "hermes_cli\web_dist\index.html"
        $nodePath = @(@(
            (Join-Path $env:ProgramFiles "nodejs\node.exe"),
            (Join-Path ${env:ProgramFiles(x86)} "nodejs\node.exe")
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($nodePath.Count -gt 0 -or $nodeCommand -or (Test-Path -LiteralPath $dist)) {
            $detail = if ($nodePath.Count -gt 0) { $nodePath[0] } elseif ($nodeCommand) { $nodeCommand.Source } else { "Dashboard already built" }
            $checks.Add((New-PreflightCheck "Dashboard toolchain" "PASS" $detail ""))
        } else {
            $checks.Add((New-PreflightCheck "Dashboard toolchain" "WARN" "Node.js not found and no existing build" `
                "Install Node.js 22 LTS (or let setup install it) so the Dashboard bundle can be built."))
        }
    } catch {
        $checks.Add((New-PreflightCheck "Dashboard toolchain" "WARN" $_.Exception.Message `
            "Verify Node.js availability for the Dashboard build."))
    }

    try {
        $root = [IO.Path]::GetPathRoot($HermesHome)
        $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($root.TrimEnd('\'))'" -ErrorAction Stop
        $freeGb = [math]::Round($drive.FreeSpace / 1GB, 1)
        if ($freeGb -ge 5) {
            $checks.Add((New-PreflightCheck "Free disk space" "PASS" "$freeGb GB on $root" ""))
        } else {
            $checks.Add((New-PreflightCheck "Free disk space" "FAIL" "$freeGb GB on $root" `
                "Free at least 5 GB: Hermes Agent, its virtual environment and the Dashboard build need room."))
        }
    } catch {
        $checks.Add((New-PreflightCheck "Free disk space" "WARN" $_.Exception.Message `
            "Verify at least 5 GB free on the HERMES_HOME volume."))
    }

    $hermes = Get-HermesExecutable
    if ($hermes -and (Test-HermesLauncher $hermes 15)) {
        try {
            $version = (& $hermes --version 2>$null | Select-Object -First 1)
        } catch { $version = "unknown" }
        $checks.Add((New-PreflightCheck "Existing Hermes Agent" "PASS" "healthy: $version" ""))
    } elseif ($hermes) {
        $checks.Add((New-PreflightCheck "Existing Hermes Agent" "FAIL" "launcher present but broken" `
            "Repair or remove the broken managed Hermes Agent tree before rerunning setup."))
    } else {
        $checks.Add((New-PreflightCheck "Existing Hermes Agent" "PASS" "not installed yet (setup will install it)" ""))
    }

    $failures = @($checks | Where-Object { $_.Status -eq "FAIL" })
    foreach ($check in $checks) {
        $suffix = if ($check.Detail) { ": $($check.Detail)" } else { "" }
        Write-Host ("[{0}] {1}{2}" -f $check.Status, $check.Name, $suffix)
        if ($check.Remedy -and $check.Status -ne "PASS") {
            Write-Host ("       -> {0}" -f $check.Remedy)
        }
    }
    $blockingNames = @()
    foreach ($failure in $failures) { $blockingNames += [string]$failure.Name }
    [PSCustomObject]@{
        ok = ($failures.Count -eq 0)
        blocking = $blockingNames
        checks = $checks.ToArray()
    } | ConvertTo-Json -Compress -Depth 4
    if ($failures.Count -gt 0) {
        throw "Preflight found $($failures.Count) blocking item(s): $($blockingNames -join ', '). Nothing was changed."
    }
}

function Protect-DiagnosticText([string]$Text) {
    if (-not $Text) { return "" }
    $safe = Protect-AuditText $Text
    # Bearer tokens, hermes:// links, basic-auth hashes and long hex secrets.
    $safe = $safe -replace '(?i)bearer\s+[A-Za-z0-9._~+/=-]{12,}', 'Bearer [REDACTED]'
    $safe = $safe -replace '(?i)(bride?ge?_?token|api_server_key|password_hash|client_secret)\s*[:=]\s*\S+', '$1=[REDACTED]'
    $safe = $safe -replace '(?i)"(token|bridge_token|password|api_key)"\s*:\s*"[^"]*"', '"$1":"[REDACTED]"'
    return $safe
}

function Add-DiagnoseSection($Lines, [System.Collections.Generic.List[string]]$Out) {
    foreach ($line in @($Lines)) { $Out.Add((Protect-DiagnosticText ([string]$line))) }
}

function Invoke-SetupDiagnose {
    # Redacted support bundle: versions, task/listener/firewall state, log tails
    # and the audit trail. No tokens, keys or pairing credentials are included.
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $report = Join-Path $AuditDir ("hermes-diagnose-$stamp.txt")
    $lines = New-Object System.Collections.Generic.List[string]
    $scriptHash = ""
    try { $scriptHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() } catch {}

    $lines.Add("Hermes Console setup diagnostic")
    $lines.Add("generated_utc: $stamp")
    $lines.Add("setup_script_sha256: $scriptHash")
    $lines.Add("powershell: $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)")
    $lines.Add("hermes_home: $HermesHome")
    $lines.Add("user: $([Environment]::UserDomainName)\$([Environment]::UserName)")
    $lines.Add("elevated: $((New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))")
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $lines.Add("os: $(([string]$os.Caption).Trim()) build $($os.BuildNumber) $($os.OSArchitecture)")
    } catch { $lines.Add("os: unavailable") }

    $lines.Add("")
    $lines.Add("== Inventory ==")
    # The inventory writes its audit trail, so the directory must exist first.
    New-Item -ItemType Directory -Force -Path $AuditDir | Out-Null
    try {
        $inventory = Invoke-SetupInventory
        $lines.Add("ready: $($inventory.ready)")
        foreach ($item in @($inventory.missing)) { $lines.Add("missing: $item") }
    } catch { $lines.Add("inventory_failed: $($_.Exception.Message)") }

    $lines.Add("")
    $lines.Add("== Scheduled tasks ==")
    foreach ($task in @(Get-IntegrationTaskNames)) {
        try {
            $info = Get-ScheduledTaskInfo -TaskName $task -ErrorAction Stop
            $state = (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).State
            $lines.Add(("{0}: state={1} lastRun={2} result={3}" -f $task, $state, $info.LastRunTime, $info.LastTaskResult))
        } catch { $lines.Add("${task}: unavailable") }
    }

    $lines.Add("")
    $lines.Add("== Listeners ==")
    try {
        foreach ($record in @(Get-ExistingHermesPortRecords)) {
            $lines.Add(("port {0}: pid {1} {2}" -f $record.Port, $record.Pid, $record.ExecutablePath))
        }
    } catch { $lines.Add("listeners_unavailable: $($_.Exception.Message)") }

    $lines.Add("")
    $lines.Add("== Firewall rules ==")
    try {
        foreach ($rule in @(Get-NetFirewallRule -DisplayName "Hermes Console*" -ErrorAction SilentlyContinue)) {
            $ports = ($rule | Get-NetFirewallPortFilter).LocalPort -join ","
            $remote = ($rule | Get-NetFirewallAddressFilter).RemoteAddress -join ","
            $lines.Add(("{0}: enabled={1} profile={2} ports={3} remote={4}" -f $rule.DisplayName, $rule.Enabled, $rule.Profile, $ports, $remote))
        }
    } catch { $lines.Add("firewall_unavailable: $($_.Exception.Message)") }

    $lines.Add("")
    $lines.Add("== Log tails ==")
    foreach ($log in @("gateway.log", "gui.log", "errors.log")) {
        $path = Join-Path $LogsDir $log
        $lines.Add("-- $log --")
        if (Test-Path -LiteralPath $path) {
            try { Add-DiagnoseSection (Get-Content -LiteralPath $path -Tail 40) $lines }
            catch { $lines.Add("unreadable: $($_.Exception.Message)") }
        } else {
            $lines.Add("absent")
        }
    }

    $lines.Add("")
    $lines.Add("== Audit trail (last 60 entries) ==")
    if (Test-Path -LiteralPath $AuditLog) {
        try { Add-DiagnoseSection (Get-Content -LiteralPath $AuditLog -Tail 60) $lines }
        catch { $lines.Add("unreadable: $($_.Exception.Message)") }
    } else {
        $lines.Add("absent")
    }

    New-Item -ItemType Directory -Force -Path $AuditDir | Out-Null
    [IO.File]::WriteAllText($report, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $Utf8NoBom)
    Write-Host "Diagnostic written: $report"
    Write-Host "No tokens, API keys or pairing credentials are included; review it before sharing."
    return $report
}

if ($Preflight) {
    Invoke-SetupPreflight
    return
}

if ($Diagnose) {
    [void](Invoke-SetupDiagnose)
    return
}

Assert-SupportedWindows
$AttemptPaths = New-SetupAttemptPaths -HermesHome $HermesHome
$BridgeNew = $AttemptPaths.BridgeNew
$ManifestFile = $AttemptPaths.ManifestFile
$PairingNew = $AttemptPaths.PairingNew
$EnvNew = $AttemptPaths.EnvNew
$SetupLockName = Get-SetupLockName $HermesHome
$SetupLockHandle = Enter-SetupLock -Name $SetupLockName -TimeoutMilliseconds ([int]$LockTimeoutSec * 1000)

try {
Assert-SetupOwnership

$Pairing = $null
if (-not $AuditOnly) {
    $Pairing = Get-PairingConfiguration
    Assert-FirewallPreflight $Pairing
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

# Snapshot every reversible Windows integration target before its first mutation.
$script:SetupTransaction = Initialize-SetupTransaction
New-Item -ItemType Directory -Force -Path $HermesHome, $ServicesDir, $LogsDir, $AuditDir | Out-Null

try {
    Write-Audit "Setup" "INFO" "Repair/install mode"
    Write-SetupPhase "Inspecting the existing installation"
    Remove-LegacyTasks
    Write-SetupPhase "Checking Hermes Agent and Python"
    $HermesExe = Install-HermesIfNeeded
    $PythonExe = Get-HermesPython
    if (-not $PythonExe) { throw "Hermes virtual-environment Python was not found." }
    if (-not (Test-PythonSnippet $PythonExe "import aiohttp" @() 15)) {
        throw "Hermes Python does not provide a working aiohttp import."
    }
    Write-Audit "Hermes Python" "OK" "Python and aiohttp are available"
    $ApiKey = Ensure-ApiKey
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
    [void](Register-HermesManualTask "HermesConsole-Restart-Dashboard" $dashboardRestartRunner)
    [void](Register-HermesManualTask "HermesConsole-Restart-MobileBridge" $bridgeRestartRunner)

    Write-SetupPhase "Checking Gateway, Dashboard and credentials"
    $gatewayChanged = [bool]$script:RunnerChanged["hermes-gateway"] -or
        [bool]$script:TaskDefinitionsChanged["HermesConsole-Gateway"]
    $bridgeChanged = $script:BridgeChanged -or [bool]$script:RunnerChanged["hermes-bridge"] -or
        [bool]$script:TaskDefinitionsChanged["HermesConsole-MobileBridge"]
    $gatewayHealthy = Test-HermesService "gateway" "http://127.0.0.1:8642" $ApiKey
    if (-not $gatewayHealthy -or ($gatewayTask -and $gatewayChanged)) {
        Start-HermesProcess "HermesConsole-Gateway" 8642
    } else {
        Write-Audit "Gateway service" "SKIP" "Already healthy and authenticated"
    }
    if (-not (Wait-HermesService "gateway" "http://127.0.0.1:8642" $ApiKey 60)) {
        throw "Gateway readiness failed. Inspect its Scheduled Task and the owner of TCP 8642."
    }
    Write-Ok "Gateway identity and authentication passed on 8642"

    $bridgeHealthy = Test-HermesService "bridge" "http://127.0.0.1:9131" $ApiKey $BridgeVersion
    if (-not $bridgeHealthy -or ($bridgeTask -and $bridgeChanged)) {
        Start-HermesProcess "HermesConsole-MobileBridge" 9131
    } else {
        Write-Audit "Mobile Bridge service" "SKIP" "Already healthy, authenticated and current"
    }
    if (-not (Wait-HermesService "bridge" "http://127.0.0.1:9131" $ApiKey 15 $BridgeVersion)) {
        throw "Mobile Bridge did not pass health, auth and self-update checks. Inspect its Scheduled Task and TCP 9131."
    }
    Write-Ok "Mobile Bridge $BridgeVersion health, auth and self-update passed"

    # Dashboard credentials must exist BEFORE the Dashboard starts: upstream
    # refuses a non-loopback bind without a registered auth provider and exits,
    # so gating Dashboard readiness first deadlocks every fresh LAN install.
    # The Bridge has no reversible compare-and-swap for this config.yaml state,
    # so a later rollback does not remove the credential; that residual only
    # gates the Dashboard and is documented as non-transactional.
    $currentCredentials = Invoke-HermesJsonRequest -Method Get `
        -Url "http://127.0.0.1:9131/bridge/dashboard/credentials" -Token $ApiKey -TimeoutSeconds 4
    if ($currentCredentials.ok -ne $true) {
        throw "Dashboard credential state could not be read through the Mobile Bridge."
    }
    if ($currentCredentials.password_set -ne $true) {
        $passwordBytes = New-Object byte[] 24
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($passwordBytes) } finally { $rng.Dispose() }
        $password = [Convert]::ToBase64String($passwordBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $username = if ($currentCredentials.username) { $currentCredentials.username } else { "admin" }
        $body = @{ username = $username; password = $password } | ConvertTo-Json -Compress
        $credentials = Invoke-HermesJsonRequest -Method Post `
            -Url "http://127.0.0.1:9131/bridge/dashboard/credentials" `
            -Token $ApiKey -Body $body -TimeoutSeconds 6
        $password = $null
        $body = $null
        if ($credentials.ok -ne $true) {
            throw "Dashboard credential provisioning was rejected by the Mobile Bridge."
        }
        Write-Audit "Dashboard credentials" "OK" "Created through the authenticated Mobile Bridge"
    } else {
        Write-Audit "Dashboard credentials" "SKIP" "Existing password retained"
    }

    $dashboardHealthy = Test-HermesService "dashboard" "http://127.0.0.1:9119" $ApiKey
    $dashboardStarting = $dashboardTask -and
        (Test-HermesTaskRunning "HermesConsole-Dashboard")
    if (-not $dashboardHealthy -and -not $dashboardStarting) {
        Start-HermesProcess "HermesConsole-Dashboard" 9119
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
        Write-AtomicBytes -Path $PairingFile -Bytes ($Utf8NoBom.GetBytes($pairingJson))
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

    Complete-SetupTransaction -Transaction $script:SetupTransaction

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
    try { Write-Audit "Setup" "ERROR" $safeError } catch {}
    $rollback = $null
    if ($script:SetupTransaction -and -not $script:IntegrationCommitted) {
        try {
            $rollback = Invoke-SetupRollback -Transaction $script:SetupTransaction
        } catch {
            $rollback = [PSCustomObject]@{ Complete = $false; Failures = @("rollback-engine") }
        }
    }
    if ($rollback -and $rollback.Complete) {
        try {
            Remove-EmptyAttemptDirectories
        } catch {
            $rollback = [PSCustomObject]@{ Complete = $false; Failures = @("directory-cleanup") }
        }
    }
    $rollbackState = if ($script:IntegrationCommitted) {
        "not-applicable-post-commit"
    } elseif ($rollback -and $rollback.Complete) {
        "complete"
    } elseif ($rollback) {
        "incomplete-$($rollback.Failures.Count)"
    } else {
        "not-started"
    }
    [PSCustomObject]@{
        ok = $false
        error = $safeError
        rollback = $rollbackState
        audit = $AuditLog
    } | ConvertTo-Json -Compress
    throw $safeError
} finally {
    if ($script:MutationQuiescent) { Remove-OwnedSetupFiles -Paths $AttemptPaths }
}
} finally {
    if ($script:MutationQuiescent) {
        Remove-OwnedSetupFiles -Paths $AttemptPaths
        Exit-SetupLock -Lock $SetupLockHandle
    } else {
        [AppDomain]::CurrentDomain.SetData("HermesConsole.UnresolvedJob", $script:UnresolvedContainedProcess)
        [AppDomain]::CurrentDomain.SetData("HermesConsole.UnresolvedSetupLock", $SetupLockHandle)
        Write-Warning "Process quiescence was not verified; this host retains the setup lock and Job Object."
    }
}
