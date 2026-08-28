# Provider-neutral process-tree termination primitive for PowerShell 5.1+ and PowerShell Core.
# This file intentionally contains no Hermes/Creation policy. It only implements one contract:
# terminate a process and all descendants, then prove that the root process is gone.

Set-StrictMode -Version Latest

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

function Get-UnixDescendantProcessIds([int]$RootProcessId) {
    $psCommand = Get-Command ps -ErrorAction SilentlyContinue
    if (-not $psCommand) {
        throw 'Process-tree termination requires ps on non-Windows hosts.'
    }

    $childrenByParent = @{}
    foreach ($line in @(& $psCommand.Source -axo 'pid=,ppid=' 2>$null)) {
        if ($line -notmatch '^\s*(\d+)\s+(\d+)\s*$') { continue }
        $pidValue = [int]$Matches[1]
        $ppidValue = [int]$Matches[2]
        if (-not $childrenByParent.ContainsKey($ppidValue)) {
            $childrenByParent[$ppidValue] = New-Object System.Collections.Generic.List[int]
        }
        $childrenByParent[$ppidValue].Add($pidValue)
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

function Stop-ProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Diagnostics.Process]$Process,
        [int]$WaitSeconds = 10
    )

    $rootPid = [int]$Process.Id
    try {
        $Process.Refresh()
        if ($Process.HasExited) { return }
    } catch {
        if (-not (Test-ProcessAlive $rootPid)) { return }
    }

    if (Test-WindowsPlatform) {
        # Windows PowerShell 5.1 has no Process.Kill(entireProcessTree) overload.
        # taskkill /T /F is the native tree-aware primitive and works from both
        # Windows PowerShell 5.1 and modern PowerShell on Windows.
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
        & $taskkill /PID $rootPid /T /F *> $null
    } else {
        # PowerShell Core on Linux/macOS: derive the descendant graph from ps,
        # stop descendants deepest-first, then stop the root. Stop-Process maps
        # to the host process APIs and avoids shell-specific kill syntax.
        $descendants = @(Get-UnixDescendantProcessIds $rootPid)
        [array]::Reverse($descendants)
        foreach ($childPid in $descendants) {
            try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {}
        }
        try { Stop-Process -Id $rootPid -Force -ErrorAction SilentlyContinue } catch {}
    }

    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $WaitSeconds))
    while ((Test-ProcessAlive $rootPid) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (Test-ProcessAlive $rootPid) {
        throw "Process tree rooted at PID $rootPid did not terminate within ${WaitSeconds}s."
    }
}
