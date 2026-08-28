# Provider-neutral process-tree termination primitive for PowerShell 5.1+ and PowerShell Core.
# This file intentionally contains no Hermes/Creation policy. It implements one contract:
# discover descendants, terminate the tree through the host adapter, and verify the tracked set.

function Test-WindowsPlatform {
    $isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    if ($null -ne $isWindowsVariable) {
        return [bool]$isWindowsVariable.Value
    }
    return $env:OS -eq 'Windows_NT'
}

function Test-ProcessAlive([int]$ProcessId) {
    try {
        [void](Get-Process -Id $ProcessId -ErrorAction Stop)
        return $true
    } catch {
        return $false
    }
}

function Get-WindowsProcessPairs {
    try {
        return @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop |
            ForEach-Object {
                [PSCustomObject]@{ Pid = [int]$_.ProcessId; ParentPid = [int]$_.ParentProcessId }
            })
    } catch {
        $wmi = Get-Command Get-WmiObject -ErrorAction SilentlyContinue
        if (-not $wmi) {
            throw 'Process-tree discovery requires Get-CimInstance or Get-WmiObject on Windows.'
        }
        return @(Get-WmiObject Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop |
            ForEach-Object {
                [PSCustomObject]@{ Pid = [int]$_.ProcessId; ParentPid = [int]$_.ParentProcessId }
            })
    }
}

function Get-UnixProcessPairs {
    $psCommand = Get-Command ps -ErrorAction SilentlyContinue
    if (-not $psCommand) {
        throw 'Process-tree discovery requires ps on non-Windows hosts.'
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($line in @(& $psCommand.Source -axo 'pid=,ppid=' 2>$null)) {
        if ($line -notmatch '^\s*(\d+)\s+(\d+)\s*$') { continue }
        $pairs.Add([PSCustomObject]@{ Pid = [int]$Matches[1]; ParentPid = [int]$Matches[2] })
    }
    return @($pairs)
}

function Get-ProcessDescendantIds([int]$RootProcessId) {
    $pairs = if (Test-WindowsPlatform) { @(Get-WindowsProcessPairs) } else { @(Get-UnixProcessPairs) }
    $childrenByParent = @{}
    foreach ($pair in $pairs) {
        if (-not $childrenByParent.ContainsKey($pair.ParentPid)) {
            $childrenByParent[$pair.ParentPid] = New-Object System.Collections.Generic.List[int]
        }
        $childrenByParent[$pair.ParentPid].Add([int]$pair.Pid)
    }

    $result = New-Object System.Collections.Generic.List[int]
    $stack = New-Object System.Collections.Stack
    $stack.Push($RootProcessId)
    while ($stack.Count -gt 0) {
        $parent = [int]$stack.Pop()
        if (-not $childrenByParent.ContainsKey($parent)) { continue }
        foreach ($child in @($childrenByParent[$parent])) {
            $result.Add([int]$child)
            $stack.Push([int]$child)
        }
    }
    return @($result)
}

function Wait-ProcessIdsExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$ProcessIds,
        [int]$WaitSeconds = 10
    )
    $tracked = @($ProcessIds | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    $deadline = if ($WaitSeconds -gt 0) {
        [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    } else {
        [DateTime]::MaxValue
    }
    do {
        $alive = @($tracked | Where-Object { Test-ProcessAlive $_ })
        if ($alive.Count -eq 0) { return @() }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return @($tracked | Where-Object { Test-ProcessAlive $_ })
}

function Stop-ProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Diagnostics.Process]$Process,
        [int]$WaitSeconds = 10
    )

    $rootPid = [int]$Process.Id
    $descendants = @()
    try { $descendants = @(Get-ProcessDescendantIds $rootPid) } catch {
        throw "Could not discover process tree rooted at PID $rootPid: $($_.Exception.Message)"
    }
    $tracked = @($rootPid) + $descendants

    if (Test-WindowsPlatform) {
        # Windows PowerShell 5.1 has no Process.Kill(entireProcessTree) overload.
        # taskkill /T /F is the native tree-aware primitive and also works from
        # modern PowerShell on Windows.
        $taskkill = $null
        if ($env:SystemRoot) {
            $candidate = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            if (Test-Path -LiteralPath $candidate) { $taskkill = $candidate }
        }
        if (-not $taskkill) {
            $command = Get-Command taskkill.exe -ErrorAction SilentlyContinue
            if ($command) { $taskkill = $command.Source }
        }
        if (-not $taskkill) {
            throw 'Process-tree termination requires taskkill.exe on Windows.'
        }
        if (Test-ProcessAlive $rootPid) {
            & $taskkill /PID $rootPid /T /F *> $null
        }
    } else {
        # PowerShell Core on Linux/macOS: stop known descendants deepest-first,
        # then the root. Stop-Process maps to the host process APIs and avoids
        # shell-specific kill syntax.
        $killOrder = @($descendants)
        [array]::Reverse($killOrder)
        foreach ($childPid in $killOrder) {
            try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {}
        }
        try { Stop-Process -Id $rootPid -Force -ErrorAction SilentlyContinue } catch {}
    }

    # The normal verification window catches fast termination. If any tracked
    # descendant survives it, do not return control to the setup lock owner yet:
    # wait until the tracked tree has actually gone instead of releasing the
    # single-flight lock after confirming only the parent process.
    $remaining = @(Wait-ProcessIdsExit -ProcessIds $tracked -WaitSeconds $WaitSeconds)
    if ($remaining.Count -gt 0) {
        [void](Wait-ProcessIdsExit -ProcessIds $remaining -WaitSeconds 0)
    }
}
