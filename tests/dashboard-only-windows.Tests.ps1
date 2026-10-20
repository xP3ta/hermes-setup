# Behaviour tests for hermes-dashboard-setup.ps1 that need real Windows PowerShell 5.1:
# the pure functions, the Dashboard probe against a stand-in server on loopback, and
# the two clean-ups in a throw-away Hermes home. No Hermes, no installation, no
# network beyond 127.0.0.1, nothing outside the temporary folder it makes (the
# clean-ups only LOOK at Scheduled Tasks and firewall rules, they find none of
# theirs). The static suite (dashboard-only-windows_test.py) reads the script; this
# one runs it.
param()

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Script = Join-Path $Root "hermes-dashboard-setup.ps1"
. $Script

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Count = 0
function Check([string]$Name, [bool]$Condition, [string]$Detail = "") {
    $script:Count++
    if ($Condition) { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name $Detail"; $script:Failures.Add($Name) }
}
function Throws([scriptblock]$Block, [string]$Pattern) {
    try { & $Block | Out-Null } catch { return ($_.Exception.Message -match $Pattern) }
    return $false
}

# -- options ---------------------------------------------------------------
function Action([hashtable]$Given) {
    $a = @{ NewAccess = $false; PasswordStdin = $false; RetireGatewayExposure = $false; AlsoRemoveApiKey = $false
            RetireBridge = $false; Help = $false; PasswordGiven = $false; UnexpectedCount = 0 }
    foreach ($k in $Given.Keys) { $a[$k] = $Given[$k] }
    return (Get-RequestedAction @a)
}
Check "no option is a setup" ((Action @{}) -eq "setup")
Check "-NewAccess" ((Action @{ NewAccess = $true }) -eq "new-access")
Check "-NewAccess -PasswordStdin" ((Action @{ NewAccess = $true; PasswordStdin = $true }) -eq "new-access")
Check "-RetireGatewayExposure -AlsoRemoveApiKey" ((Action @{ RetireGatewayExposure = $true; AlsoRemoveApiKey = $true }) -eq "retire-gateway-exposure")
Check "two actions are refused" (Throws { Action @{ NewAccess = $true; RetireBridge = $true } } "one action at a time")
Check "a password on the command line is refused" (Throws { Action @{ PasswordGiven = $true } } "never taken from the command line")
Check "an unexpected argument is refused" (Throws { Action @{ UnexpectedCount = 1 } } "not shown")
Check "-AlsoRemoveApiKey alone is refused" (Throws { Action @{ AlsoRemoveApiKey = $true } } "only goes with")
Check "-PasswordStdin with a retire is refused" (Throws { Action @{ PasswordStdin = $true; RetireBridge = $true } } "only goes with")

# -- ports and addresses ---------------------------------------------------
Check "port 9119" ((Get-BoundedPort "p" "9119") -eq 9119)
foreach ($bad in "0", "65536", "-1", "abc", "", "1e3", "99999") {
    Check "port '$bad' is refused" (Throws { Get-BoundedPort "p" $bad } "TCP port")
}
foreach ($good in "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.0.10", "100.64.0.1", "100.127.255.254") {
    Check "bind $good is allowed" (Test-AllowedBindAddress $good)
}
foreach ($bad in "0.0.0.0", "127.0.0.1", "169.254.1.1", "8.8.8.8", "172.15.0.1", "172.32.0.1", "100.63.0.1", "100.128.0.1",
                 "192.169.0.1", "::1", "fe80::1", "fd00::1", "010.1.2.3", "10.1.2", "10.1.2.3.4", "localhost", "", "255.255.255.255") {
    Check "bind '$bad' is refused" (-not (Test-AllowedBindAddress $bad))
}
Check "100.100.1.1 is a mesh address" (Test-MeshAddress "100.100.1.1")
Check "192.168.1.1 is not a mesh address" (-not (Test-MeshAddress "192.168.1.1"))
Check "an address that is not this computer's is refused" (Throws { Select-BindAddress "10.254.254.254" } "not assigned to this computer")
Check "a public address is refused" (Throws { Select-BindAddress "8.8.8.8" } "private LAN or Tailscale")

# -- Hermes home -----------------------------------------------------------
Check "a relative HERMES_HOME is refused" (Throws { Resolve-HermesHome "relative\home" } "absolute")
Check "an empty HERMES_HOME is refused" (Throws { Resolve-HermesHome "" } "absolute")
Check "a drive root is refused" (Throws { Resolve-HermesHome "C:\" } "root")
Check "a quote in HERMES_HOME is refused" (Throws { Resolve-HermesHome 'C:\Temp\a"b' } "unsupported")
Check "a percent sign in HERMES_HOME is refused" (Throws { Resolve-HermesHome 'C:\Temp\a%b' } "unsupported")
Check "an ampersand in HERMES_HOME is refused" (Throws { Resolve-HermesHome 'C:\Temp\a&b' } "unsupported")
Check "a plain path with spaces is accepted and normalised" ((Resolve-HermesHome 'C:\Temp\a b\..\c d\') -eq 'C:\Temp\c d')

$work = Join-Path ([IO.Path]::GetTempPath()) ("dash-ps1-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $linkTarget = Join-Path $work "real"
    New-Item -ItemType Directory -Force -Path $linkTarget | Out-Null
    $junction = Join-Path $work "junction"
    & cmd.exe /c mklink /J "$junction" "$linkTarget" | Out-Null
    Check "a junction as HERMES_HOME is refused" (Throws { Resolve-HermesHome $junction } "symbolic link or junction")

    # -- command-line quoting survives Windows' own parser ---------------------
    Add-Type -Namespace B2Test -Name Argv -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError = true)]
public static extern System.IntPtr CommandLineToArgvW([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string lpCmdLine, out int pNumArgs);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr LocalFree(System.IntPtr hMem);
'@
    function Split-CommandLine([string]$Line) {
        $n = 0
        $ptr = [B2Test.Argv]::CommandLineToArgvW($Line, [ref]$n)
        $out = @()
        for ($i = 0; $i -lt $n; $i++) {
            $item = [Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $i * [IntPtr]::Size)
            $out += [Runtime.InteropServices.Marshal]::PtrToStringUni($item)
        }
        [void][B2Test.Argv]::LocalFree($ptr)
        return $out
    }
    $nasty = @('plain', 'with space', 'a"quote', 'trailing\', 'trailing space\ ', 'two\\', 'C:\Program Files\x y\', 'say "hi" there', '', 'x\"y', 'é-ñ')
    $line = "prog " + (($nasty | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join " ")
    $parsed = @(Split-CommandLine $line)
    $same = ($parsed.Count -eq $nasty.Count + 1)
    for ($i = 0; $same -and $i -lt $nasty.Count; $i++) { if ($parsed[$i + 1] -ne $nasty[$i]) { $same = $false } }
    Check "arguments round-trip through CommandLineToArgvW" $same ($parsed -join "|")

    # -- the runner ------------------------------------------------------------
    $spaced = Join-Path $work "home with spaces"
    New-Item -ItemType Directory -Force -Path (Join-Path $spaced "logs") | Out-Null
    $fake = Join-Path $spaced "fake launcher.cmd"
    Set-Content -Path $fake -Value "@echo off`r`necho ran %* host=%HERMES_HOME%`r`nexit /b 0" -Encoding ASCII
    $log = Join-Path $spaced "logs\dashboard.log"
    $text = New-DashboardRunnerText -HermesHome $spaced -Launcher $fake -BindAddress "192.0.2.10" -PortNumber 9119 -LogPath $log -SkipBuild $true
    Check "the runner binds the chosen address" ($text.Contains("--host 192.0.2.10 --port 9119 --no-open --skip-build"))
    Check "the runner never binds every address" (-not $text.Contains("0.0.0.0"))
    Check "the runner starts the Dashboard again after an error" ($text.Contains("If rc = 0 Then Exit Do") -and $text.Contains("WScript.Sleep 5000"))
    $vbs = Join-Path $spaced "hermes-dashboard.vbs"
    Write-RunnerFile $vbs $text
    $b = [IO.File]::ReadAllBytes($vbs)
    Check "the runner is UTF-16LE with its mark" ($b[0] -eq 0xFF -and $b[1] -eq 0xFE)
    $p = Start-Process -FilePath "$env:SystemRoot\System32\wscript.exe" -ArgumentList "//B", "//NoLogo", "`"$vbs`"" -PassThru
    $done = $p.WaitForExit(30000)
    $logText = ""
    if (Test-Path -LiteralPath $log) { $logText = (Get-Content -LiteralPath $log -Raw) }
    Check "the runner runs a launcher in a folder with spaces and logs its output" ($done -and $logText -match "ran dashboard --host 192.0.2.10 --port 9119 --no-open --skip-build" -and $logText -match [regex]::Escape("host=$spaced")) $logText
    if (-not $done) { Stop-Process -Id $p.Id -Force }

    # -- text edits keep line endings, encoding and what is not theirs -----------
    $crlf = "A=1`r`nAPI_SERVER_KEY=secret`r`nB=2`r`n"
    Check "Remove-MatchingLines keeps CRLF and the other lines" ((Remove-MatchingLines $crlf '^API_SERVER_KEY=') -eq "A=1`r`nB=2`r`n")
    Check "Remove-MatchingLines keeps a last line without a newline" ((Remove-MatchingLines "A=1`nAPI_SERVER_KEY=x" '^API_SERVER_KEY=') -eq "A=1`n")
    Check "Remove-MatchingLines leaves a text with no match alone" ((Remove-MatchingLines "A=1`nB=2`n" '^API_SERVER_KEY=') -eq "A=1`nB=2`n")

    # -- the Dashboard probe against a stand-in on loopback ----------------------
    $listenerPort = Get-Random -Minimum 20000 -Maximum 40000
    $base = "http://127.0.0.1:$listenerPort"
    $standIn = {
        param($Port, $Mode)
        $l = New-Object Net.HttpListener
        $l.Prefixes.Add("http://127.0.0.1:$Port/")
        $l.Start()
        try {
            while ($l.IsListening) {
                $ctx = $l.GetContext()
                $req = $ctx.Request; $res = $ctx.Response
                $path = $req.Url.AbsolutePath
                $body = '{"ok":true}'; $status = 200
                if ($path -eq "/api/status") {
                } elseif ($path -eq "/api/stop") { $res.Close(); break
                } elseif ($path -eq "/auth/password-login") {
                    $raw = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
                    $data = $raw | ConvertFrom-Json
                    if ($data.username -eq "admin" -and $data.password -eq ("pass-" + [char]0xF1 + "-ok")) {
                        $res.Headers.Add("Set-Cookie", "hermes_session_at=good; Path=/; HttpOnly")
                        $res.Headers.Add("Set-Cookie", "hermes_session_rt=other; Path=/; HttpOnly")
                    } else { $status = 401; $body = '{"detail":"no"}' }
                } else {
                    $cookie = [string]$req.Headers["Cookie"]
                    if ($Mode -ne "open" -and $cookie -notmatch "hermes_session_at=good") { $status = 401; $body = '{"detail":"auth"}' }
                }
                $res.StatusCode = $status
                $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                $res.Close()
            }
        } finally { $l.Stop() }
    }
    function Start-StandIn([int]$Port, [string]$Mode) {
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($standIn).AddArgument($Port).AddArgument($Mode)
        $handle = $ps.BeginInvoke()
        for ($i = 0; $i -lt 100; $i++) {
            try { $c = New-Object Net.Sockets.TcpClient; $c.Connect("127.0.0.1", $Port); $c.Close(); break } catch { Start-Sleep -Milliseconds 100 }
        }
        return @{ Ps = $ps; Handle = $handle; Port = $Port }
    }
    function Stop-StandIn($S) {
        try { [void](Invoke-HttpRequest ("http://127.0.0.1:" + $S.Port + "/api/stop")) } catch { }
        $S.Ps.Stop(); $S.Ps.Dispose()
    }
    $secretWithEnye = "pass-" + [char]0xF1 + "-ok"
    $server = Start-StandIn $listenerPort "closed"
    try {
        Check "probe alive: a Dashboard that answers" ((Test-DashboardAnswers -Base $base -Mode alive -Quiet) -eq 0)
        Check "probe refuse: anonymous and invalid sessions are turned away" ((Test-DashboardAnswers -Base $base -Mode refuse -Quiet) -eq 0)
        Check "probe login: the right password opens a protected page" ((Test-DashboardAnswers -Base $base -Mode login -UserName admin -PasswordText $secretWithEnye -Quiet) -eq 0)
        Check "probe login: a wrong password gives 10" ((Test-DashboardAnswers -Base $base -Mode login -UserName admin -PasswordText "wrong" -Quiet) -eq 10)
        Check "probe login: a wrong user gives 10" ((Test-DashboardAnswers -Base $base -Mode login -UserName other -PasswordText $secretWithEnye -Quiet) -eq 10)
    } finally { Stop-StandIn $server }
    $openPort = Get-Random -Minimum 40001 -Maximum 50000
    $open = Start-StandIn $openPort "open"
    try {
        Check "probe refuse: a Dashboard that lets anyone in fails" ((Test-DashboardAnswers -Base "http://127.0.0.1:$openPort" -Mode refuse -Quiet) -eq 1)
        Check "probe alive: still alive" ((Test-DashboardAnswers -Base "http://127.0.0.1:$openPort" -Mode alive -Quiet) -eq 0)
    } finally { Stop-StandIn $open }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    Check "probe alive: nothing listening fails" ((Test-DashboardAnswers -Base "http://127.0.0.1:$(Get-Random -Minimum 50001 -Maximum 60000)" -Mode alive -Quiet) -eq 1)

    # -- -RetireGatewayExposure in a throw-away home ---------------------------
    $env:HERMES_GATEWAY_PORT = "8642"
    $home1 = Join-Path $work "retire home"
    $svc = Join-Path $home1 "console-services"
    New-Item -ItemType Directory -Force -Path $svc | Out-Null
    $vbsText = "Option Explicit`r`nsh.Environment(`"Process`")(`"HERMES_HOME`") = home`r`nsh.Environment(`"Process`")(`"API_SERVER_HOST`") = `"192.0.2.10`"`r`nsh.Environment(`"Process`")(`"API_SERVER_PORT`") = `"8642`"`r`nsh.Environment(`"Process`")(`"MINE`") = `"keep`"`r`n"
    $enc = New-Object Text.UnicodeEncoding($false, $true)
    function Seed {
        [IO.File]::WriteAllBytes((Join-Path $svc "hermes-gateway.vbs"), [byte[]]($enc.GetPreamble() + $enc.GetBytes($vbsText)))
        Set-Content (Join-Path $svc "pairing.json") "{}"; Set-Content (Join-Path $svc "pairing-qr.png") "x"
        [IO.File]::WriteAllText((Join-Path $home1 ".env"), "FIRST=1`r`nAPI_SERVER_KEY=test-key-not-real`r`nLAST=2`r`n", (New-Object Text.UTF8Encoding $false))
    }
    Seed
    $out = Invoke-RetireGatewayExposure -HermesHome $home1 -AlsoRemoveKey $false 6>&1 | Out-String
    $runnerBytes = [IO.File]::ReadAllBytes((Join-Path $svc "hermes-gateway.vbs"))
    $runnerNow = [Text.Encoding]::Unicode.GetString($runnerBytes)
    Check "retire: the two variables are gone from the runner" (-not ($runnerNow -match "API_SERVER"))
    Check "retire: the runner keeps its own other lines and its encoding" ($runnerNow -match 'MINE' -and $runnerBytes[0] -eq 0xFF -and $runnerBytes[1] -eq 0xFE)
    Check "retire: the pairing record is gone" (-not (Test-Path (Join-Path $svc "pairing.json")) -and -not (Test-Path (Join-Path $svc "pairing-qr.png")))
    Check "retire: the API key stays by default" ((Get-Content -Raw (Join-Path $home1 ".env")) -eq "FIRST=1`r`nAPI_SERVER_KEY=test-key-not-real`r`nLAST=2`r`n")
    Check "retire: it says the key was kept" ($out -match "(?s)Your\s+API\s+key.*?was\s+kept")
    $out2 = Invoke-RetireGatewayExposure -HermesHome $home1 -AlsoRemoveKey $false 6>&1 | Out-String
    Check "retire: again says there is nothing to do" ($out2 -match "Nothing to do")
    $out3 = Invoke-RetireGatewayExposure -HermesHome $home1 -AlsoRemoveKey $true 6>&1 | Out-String
    Check "retire -AlsoRemoveApiKey: the key line is gone and the rest of .env is not touched" ((Get-Content -Raw (Join-Path $home1 ".env")) -eq "FIRST=1`r`nLAST=2`r`n")
    $copies = @(Get-ChildItem (Join-Path $home1 "backups\gateway-exposure") -ErrorAction SilentlyContinue)
    Check "retire -AlsoRemoveApiKey: a private copy of the line is kept" ($copies.Count -eq 1 -and (Get-Content $copies[0].FullName -Raw) -eq "API_SERVER_KEY=test-key-not-real`r`n")
    $out4 = Invoke-RetireGatewayExposure -HermesHome $home1 -AlsoRemoveKey $true 6>&1 | Out-String
    Check "retire -AlsoRemoveApiKey: again says there is nothing to do" ($out4 -match "Nothing to do")
    # a link on the path stops it before anything changes
    $home2 = Join-Path $work "retire link"
    New-Item -ItemType Directory -Force -Path $home2, (Join-Path $work "elsewhere") | Out-Null
    & cmd.exe /c mklink /J "$(Join-Path $home2 'console-services')" "$(Join-Path $work 'elsewhere')" | Out-Null
    Set-Content (Join-Path $work "elsewhere\pairing.json") "{}"
    Check "retire: a linked console-services is refused" (Throws { Invoke-RetireGatewayExposure -HermesHome $home2 -AlsoRemoveKey $false } "symbolic link")
    Check "retire: and nothing behind the link was removed" (Test-Path (Join-Path $work "elsewhere\pairing.json"))

    # -- -RetireBridge in a throw-away home ------------------------------------
    $home3 = Join-Path $work "bridge home"
    New-Item -ItemType Directory -Force -Path (Join-Path $home3 "console-services") | Out-Null
    $outNone = Invoke-RetireBridge $home3 6>&1 | Out-String
    Check "bridge: nothing there says so" ($outNone -match "no Mobile Bridge")
    foreach ($f in "hermes_bridge.py", "hermes_bridge.py.rollback", "bridge_token", "console-services\hermes-bridge.vbs", "console-services\restart-hermes-bridge.vbs") {
        Set-Content (Join-Path $home3 $f) "x"
    }
    $outDone = Invoke-RetireBridge $home3 6>&1 | Out-String
    Check "bridge: its files are removed" (@(Get-ChildItem $home3 -Recurse -File).Count -eq 0) $outDone
    Check "bridge: and it says what it did" ($outDone -match "stopped and removed")

    # S2e: uv where the current official installer leaves it (hermes\tools\uv-<version>-<platform>\uv.exe)
    $uvHome = Join-Path $work "uv-home"
    foreach ($name in "uv-0.9.0-win32-x64", "uv-0.12.3-win32-x64", "uv-0.10.11-win32-x64") {
        New-Item -ItemType Directory -Path (Join-Path $uvHome "tools\$name") -Force | Out-Null
        Set-Content (Join-Path $uvHome "tools\$name\uv.exe") "x"
    }
    New-Item -ItemType Directory -Path (Join-Path $uvHome "tools\zz-other") -Force | Out-Null
    Set-Content (Join-Path $uvHome "tools\zz-other\uv.exe") "x"
    New-Item -ItemType Directory -Path (Join-Path $uvHome "tools\uv-0.99.0-win32-x64") -Force | Out-Null
    Set-Content (Join-Path $uvHome "tools\uv-0.99.0-win32-x64\uv-helper.exe") "x"
    Check "uv: the newest version under tools wins, by version and not by spelling" ((Find-Uv $uvHome) -eq (Join-Path $uvHome "tools\uv-0.12.3-win32-x64\uv.exe")) (Find-Uv $uvHome)
    New-Item -ItemType Directory -Path (Join-Path $uvHome "bin") -Force | Out-Null
    Set-Content (Join-Path $uvHome "bin\uv.exe") "x"
    Check "uv: the old place still comes first" ((Find-Uv $uvHome) -eq (Join-Path $uvHome "bin\uv.exe"))
} finally {
    Remove-Item Env:\HERMES_GATEWAY_PORT -ErrorAction SilentlyContinue
    cmd.exe /c rmdir "$work\junction" 2>$null | Out-Null
    cmd.exe /c rmdir "$work\retire link\console-services" 2>$null | Out-Null
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("{0} checks, {1} failed" -f $script:Count, $script:Failures.Count)
if ($script:Failures.Count -gt 0) { $script:Failures | ForEach-Object { Write-Host "  FAILED: $_" }; exit 1 }
