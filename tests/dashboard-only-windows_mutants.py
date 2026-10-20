#!/usr/bin/env python3
"""One mutant per guard of hermes-dashboard-setup.ps1.

Each mutant removes or inverts exactly one guard in a copy of the script (the
file in the repository is never touched) and runs tests/dashboard-only-windows_test.py
against the copy. The run passes only when every mutant is KILLED (the named test
fails) and the unmutated script passes the same tests. A mutant that survives
means a guard that no test would miss.

Honest limit: the tests behind these mutants READ the script. Killing a mutant
here proves the guard is written and that its removal is noticed; it does not
prove the guard works on Windows. That part is tests/dashboard-only-windows.Tests.ps1
and the run on a real Windows machine.

    python3 tests/dashboard-only-windows_mutants.py            # all
    python3 tests/dashboard-only-windows_mutants.py G07 S03    # some
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "hermes-dashboard-setup.ps1"
SUITE = ROOT / "tests" / "dashboard-only-windows_test.py"

# id, what the guard is, old text, new text, name fragment of a test that must fail
MUTANTS: list[tuple[str, str, str, str, str]] = [
    ("G01", "an unexpected argument is refused", "if ($UnexpectedCount -gt 0) {", "if ($false) {", "test_G01_"),
    ("G02", "a password on the command line is refused", "if ($PasswordGiven) {", "if ($false) {", "test_G02_"),
    ("G03", "two actions at once are refused", "if ($chosen.Count -gt 1) {", "if ($false) {", "test_G03_"),
    ("G04", "-AlsoRemoveApiKey only with the retire", 'if ($AlsoRemoveApiKey -and $action -ne "retire-gateway-exposure") {', "if ($false) {", "test_G04_"),
    ("G05", "-PasswordStdin not with a retire", 'if ($PasswordStdin -and $action -ne "setup" -and $action -ne "new-access") {', "if ($false) {", "test_G05_"),
    ("G06", "an empty password on stdin is refused", "if ([string]::IsNullOrWhiteSpace($text)) {", "if ($false) {", "test_G06_"),
    ("G07", "the password must be piped", "if (-not [Console]::IsInputRedirected) {", "if ($false) {", "test_G07_"),
    ("G08", "HERMES_HOME absolute", "-not [IO.Path]::IsPathRooted($Candidate)) {", "-not $true) {", "test_G08_"),
    ("G09", "HERMES_HOME not a root", "$resolved.TrimEnd($sep) -eq $root.TrimEnd($sep)) {", "$false) {", "test_G09_"),
    ("G10", "HERMES_HOME characters", "if (Test-UnsafePathText $resolved) { throw", "if ($false) { throw", "test_G10_"),
    ("G11", "HERMES_HOME not a link", "if (Test-ReparsePoint $resolved) { throw", "if ($false) { throw", "test_G11_"),
    ("G12", "a second Hermes home", "(Test-HermesHomeEvidence $default)) {", "($false)) {", "test_G12_"),
    ("G13", "one setup at a time", "if (-not $acquired) {\n        $mutex.Dispose()", "if ($false) {\n        $mutex.Dispose()", "test_G13_"),
    ("G14", "only private and CGNAT addresses", "$b[1] -le 127) { return $true }\n    return $false\n}\n\nfunction Test-MeshAddress", "$b[1] -le 127) { return $true }\n    return $true\n}\n\nfunction Test-MeshAddress", "test_G14_"),
    ("G15", "IPv4 only", "if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }", "if ($false) { return $false }", "test_G15_"),
    ("G16", "canonical address", "if ($ip.ToString() -ne $Text) { return $false }", "if ($false) { return $false }", "test_G16_"),
    ("G17", "the address is this computer's", "if ($mine.Count -eq 0) {", "if ($false) {", "test_G17_"),
    ("G18", "a LAN bind on a Private network", '[string]$profile.NetworkCategory -ne "Private") {', "$false) {", "test_G18_"),
    ("G19", "a TCP port", "$parsed -lt 1 -or $parsed -gt 65535) {", "$false) {", "test_G19_"),
    ("G20", "a foreign Scheduled Task is refused", "        if ($task -and -not (Test-DashboardTaskOwned $task $runner)) {", "        if ($false) {", "test_G20_"),
    ("G21", "a foreign listener is refused", "if (-not (Test-PortHeldByOwnDashboard $HermesHome $portNumber $runner)) {", "if ($false) {", "test_G21_"),
    ("G22", "without a launcher that answers, it looks before it installs", "if (-not $launcher) {\n        if (Find-HermesLauncher $HermesHome -SeenOnly) {", "if (-not $launcher) {\n        if ($false) {", "test_G22_"),
    ("G23", "Hermes must run its own code", "if ($check.Code -ne 0) {", "if ($false) {", "test_G23_"),
    ("G24", "the runtime command is checked", '$command.Count -lt 4 -or $command[1] -ne "-I" -or $command[2] -ne "-c"', "$false", "test_G24_"),
    ("G25", "a launcher must answer", "if ($probe.Code -ne 0) { continue }", "if ($false) { continue }", "test_G25_"),
    ("G26", "a launcher outside the home is bound to it", "if (-not [string]::Equals($reported, $expected, [StringComparison]::OrdinalIgnoreCase)) { continue }", "if ($false) { continue }", "test_G26_"),
    ("G27", "the Dashboard binds the chosen address", "dashboard --host $BindAddress --port", "dashboard --host 0.0.0.0 --port", "test_G27_"),
    ("G28", "the service starts with the computer", "-LogonType S4U", "-LogonType Password", "test_G28_"),
    ("G29", "the service is brought back", "-RestartCount 999", "-RestartCount 1", "test_G29_"),
    ("G30", "the rule is Private only", '$profile = "Private"\n    $remote = "LocalSubnet"', '$profile = "Any"\n    $remote = "LocalSubnet"', "test_G30_"),
    ("G31", "the Tailscale rule is limited to Tailscale", '$remote = "100.64.0.0/10"', '$remote = "Any"', "test_G31_"),
    ("G32", "a different rule is replaced, not widened", "if ($have) { Remove-NetFirewallRule -Name $script:FirewallRuleName -ErrorAction Stop }", "if ($false) { Remove-NetFirewallRule -Name $script:FirewallRuleName -ErrorAction Stop }", "test_G32_"),
    ("G33", "without elevation the firewall is left alone", "} elseif (Test-CurrentProcessAdministrator) {", "} elseif ($true) {", "test_G33_"),
    ("G34", "the firewall is ready before the Dashboard listens", '            New-DashboardRule $want\n            $firewall = "created"', '            $firewall = "created"', "test_G34_"),
    ("G35", "an anonymous visitor must be refused", "$answer.Status -ne 401 -and $answer.Status -ne 403) {", "$false) {", "test_G35_"),
    ("G36", "the new sign-in must open the Dashboard", "if ($login.Status -in 400, 401, 403) { return 10 }", "if ($false) { return 10 }", "test_G36_"),
    ("G37", "the check after setup is a real sign-in", '-Mode "refuse"', '-Mode "alive"', "test_G37_"),
    ("G38", "a Dashboard that never starts fails", "if (-not $ready) {", "if ($false) {", "test_G38_"),
    ("G39", "a failing setup is rolled back", 'Write-Problem "ERROR: $($_.Exception.Message)"\n        Undo-DashboardSetup\n        return 1', 'Write-Problem "ERROR: $($_.Exception.Message)"\n        return 1', "test_G39_"),
    ("G40", "the rollback gives back the sign-in", "Invoke-HermesPython $t.Python $t.HermesHome $restore @($t.PreviousPath)", "[pscustomobject]@{ Code = 0 }", "test_G40_"),
    ("G41", "the rollback gives back the rule", "if ($t.PreviousRule) { New-DashboardRule $t.PreviousRule }", "", "test_G41_"),
    ("G42", "the whole process tree is stopped", "foreach ($id in (Get-DescendantProcessIds $roots))", "foreach ($id in @())", "test_G42_"),
    ("G43", "the work folder is private", "New-PrivateDirectory $work\n", "New-Item -ItemType Directory -Force -Path $work | Out-Null\n", "test_G43_"),
    ("G44", "an existing sign-in is not touched", "if providers:\n        say(\"existing\"", "if False:\n        say(\"existing\"", "test_G44_"),
    ("G45", "the clear-text file goes only with a new sign-in", '$login.STATE -eq "created" -and (Test-Path -LiteralPath $stale)', "(Test-Path -LiteralPath $stale)", "test_G45_"),
    ("G46", "the clear-text file is reported", "still holds the Dashboard password", "still holds the Dashboard text", "test_G46_"),
    ("G47", "a broader rule is reported", "foreach ($other in @(Get-BroaderPortRules $portNumber))", "foreach ($other in @())", "test_G47_"),
    ("G48", "retire: the key stays by default", "$removeKey = ($AlsoRemoveKey -and $keyPresent)", "$removeKey = $keyPresent", "test_G48_"),
    ("G49", "retire: a private copy of the key", "        Set-PrivateAcl $backup\n", "", "test_G49_"),
    ("G50", "retire: only the two variables leave the runner", "if ($hasRunnerExposure) { $newRunner = Remove-MatchingLines $runnerFile.Text $runnerPattern }", "if ($hasRunnerExposure) { $newRunner = Remove-MatchingLines $runnerFile.Text '^$' }", "test_G50_"),
    ("G51", "retire: no link on the path", "if (Test-ReparsePoint $guarded) { throw", "if ($false) { throw", "test_G51_"),
    ("G52", "retire: nothing to do is said", "if (-not $evidence) {", "if ($false) {", "test_G52_"),
    ("G53", "retire: only the Gateway port of its own rules", 'if ($ports -contains "$gatewayPort") { $rulesToChange += $rule }', "$rulesToChange += $rule", "test_G53_"),
    ("G54", "retire: the firewall only when elevated", "if ($isAdmin) {\n        foreach ($rule in $rulesToChange)", "if ($true) {\n        foreach ($rule in $rulesToChange)", "test_G54_"),
    ("G55", "retire: access kept on rewrite", "Set-Acl -LiteralPath $temp -AclObject (Get-Acl -LiteralPath $Path)", "$null", "test_G55_"),
    ("G56", "retire: the user's own host is reported", "your .env sets API_SERVER_HOST itself", "your .env sets a host itself", "test_G56_"),
    ("G57", "bridge: a foreign task is refused", "if ($arguments.IndexOf($services, [StringComparison]::OrdinalIgnoreCase) -lt 0) {", "if ($false) {", "test_G57_"),
    ("G58", "bridge: only this home's process", "([string]$_.CommandLine).IndexOf($target, [StringComparison]::OrdinalIgnoreCase) -ge 0", "$true", "test_G58_"),
    ("G59", "bridge: files last", "if ($failed.Count -eq 0) {\n        # The files go last", "if ($true) {\n        # The files go last", "test_G59_"),
    ("G60", "bridge: nothing to do is said", "There is no Mobile Bridge on this computer. Nothing to do.", "There is a Mobile Bridge.", "test_G60_"),
    ("G61", "Windows only", "[Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {", "$false) {", "test_G61_"),
    ("G62", "dot-sourcing runs nothing", 'if ($MyInvocation.InvocationName -eq ".") { return }\n', "", "test_G62_"),
    ("G63", "exit only for a file run", "if ($PSCommandPath) { exit $exitCode }\n", "", "test_G63_"),
    ("G64", "a message never stops the rollback", "function Write-Problem([string]$Message) { try { [Console]::Error.WriteLine($Message) } catch { } }", "function Write-Problem([string]$Message) { [Console]::Error.WriteLine($Message) }", "test_G64_"),
    ("G65", "the wait goes on only while the log grows", "if ($size -le $lastSize) { break }", "if ($false) { break }", "test_G65_"),
    ("G66", "the old service is stopped before it is replaced", "$t.TaskTouched = $true\n        if ($task) { [void](Stop-DashboardTask", "$t.TaskTouched = $true\n        if ($false) { [void](Stop-DashboardTask", "test_G66_"),
    # What the script is made of (the other classes of the static suite)
    ("S01", "no API server variable outside the retire", "$script:OfficialInstallUrl =", "$env:API_SERVER_HOST = \"x\"\n$script:OfficialInstallUrl =", "test_nothing_outside_the_retire_path_knows_the_api_server"),
    ("S02", "the retire never stops a service", "    Write-Say \"Your Gateway was not stopped or restarted. It keeps listening as it was\"", "    Stop-ScheduledTask -TaskName x\n    Write-Say \"Your Gateway was not stopped or restarted. It keeps listening as it was\"", "test_the_retire_path_never_stops_starts_or_removes"),
    ("S03", "the retire never runs Hermes", "    $removeKey = ($AlsoRemoveKey", "    $null = Find-HermesLauncher $HermesHome\n    $removeKey = ($AlsoRemoveKey", "test_the_retire_path_does_not_run_hermes"),
    ("S04", "no old pairing record outside the retire", "$script:OfficialInstallUrl =", "$q = \"pairing.json\"\n$script:OfficialInstallUrl =", "test_the_only_code_is_the_dashboard_one"),
    ("S05", "it downloads nothing but the official installer", "$script:OfficialInstallUrl =", "Invoke-WebRequest -Uri x\n$script:OfficialInstallUrl =", "test_hermes_is_installed_only_by_the_official_installer"),
    ("S06", "no firewall switched off", "$script:OfficialInstallUrl =", "Set-NetFirewallProfile -Enabled False\n$script:OfficialInstallUrl =", "test_the_firewall_is_never_switched_off"),
    ("S07", "no elevation of its own", "$script:OfficialInstallUrl =", "Start-Process x -Verb RunAs\n$script:OfficialInstallUrl =", "test_it_does_not_ask_for_elevation"),
    ("S08", "a password never in an argument list", "@($Action, $HermesHome, $statePath, $t.PreviousPath, $flag, $passwordFile)", "@($Action, $HermesHome, $statePath, $t.PreviousPath, $flag, $passwordFile, $givenPassword)", "test_the_password_variables_are_used_only"),
    ("S09", "a password never in the environment", "-InputText $stdinText", "-InputText $stdinText -Environment @{ P = $givenPassword }", "test_no_password_in_an_argument_list"),
    ("S10", "no byte-order mark", "# Hermes Console - Dashboard-only setup for native Windows", "﻿# Hermes Console - Dashboard-only setup for native Windows", "test_plain_ascii_without_a_byte_order_mark"),
    ("S11", "plain ASCII", "# Hermes Console - Dashboard-only setup for native Windows", "# Hermes Console – Dashboard-only setup for native Windows", "test_plain_ascii_without_a_byte_order_mark"),
    ("S12", "no personal path", "$script:OfficialInstallUrl =", "$p = '/home/someone'\n$script:OfficialInstallUrl =", "test_no_private_paths_names_or_hosts"),
    ("S13", "no private address written out", "$script:OfficialInstallUrl =", "$p = '192.168.1.5'\n$script:OfficialInstallUrl =", "test_no_address_written_out"),
    ("S14", "brackets balance", "function Write-Say([string]$Message = \"\") { try { Write-Host $Message } catch { } }", "function Write-Say([string]$Message = \"\") { try { Write-Host $Message } catch { }", "test_brackets_and_quotes_balance"),
    ("S15", "LF line endings", "$ErrorActionPreference = \"Stop\"\n", "$ErrorActionPreference = \"Stop\"\r\n", "test_lf_line_endings"),
    ("S16", "the auth code stays the one the shell script tests", 'letters = "abcdefghijkmnpqrstuvwxyz23456789"', 'letters = "abcdefghijkmnpqrstuvwxyz2345678"', "test_the_auth_code_is_the_one_of_the_shell_script"),
    ("S17", "the restore code stays the one the shell script tests", "basic.pop(key, None)", "basic.pop(key, 0)", "test_the_restore_code_is_the_one_of_the_shell_script"),
    ("S18", "the file says what it is", "# Hermes Console - Dashboard-only setup for native Windows", "# Setup", "test_it_says_what_it_is"),
    ("S19", "no positional arguments", "[CmdletBinding(PositionalBinding = $false)]\n", "", "test_it_is_not_a_cmdlet_with_positional_arguments"),
    ("S20", "HTTP only to the address it chose", "$request.Proxy = $null", "", "test_http_goes_only_to_the_address"),
    ("S21", "the stdin password is read as bytes", "[Console]::OpenStandardInput()", "[Console]::In", "test_the_stdin_password_is_read_as_bytes"),
    ("S22", "the generated password comes back through a private file", 'Join-Path $work "new-password"', 'Join-Path $work "pw.txt"', "test_the_generated_password_comes_back"),
    ("G67", "-Remove is an action of its own", 'if ($Remove) { $chosen += "remove" }', 'if ($false) { $chosen += "remove" }', "test_G67_"),
    ("G68", "-Remove stops before it deletes", 'if (-not (Stop-DashboardTask $HermesHome $portNumber $runner)) {\n        throw "The Dashboard could not be stopped, so', 'if ($false) {\n        throw "The Dashboard could not be stopped, so', "test_G68_"),
    ("G69", "-Remove refuses a foreign task", '$task = Get-DashboardTask\n    if ($task -and -not (Test-DashboardTaskOwned $task $runner)) {\n        throw ("A Scheduled Task', '$task = Get-DashboardTask\n    if ($false) {\n        throw ("A Scheduled Task', "test_G69_"),
    ("G70", "-Remove with nothing there does nothing", "if (-not $task -and -not $hadRunner -and -not $rule) {", "if ($false) {", "test_G70_"),
    ("G71", "the first start is announced", 'Write-Say "The first start can take a few minutes: Hermes builds its web pages once."', "$null = 0", "test_G71_"),
    ("G72", "existing access is explained and -NewAccess offered", "Run this again with -NewAccess: it makes a new password and signs out", "Run this again: it makes a new password and signs out", "test_G72_"),
    ("G73", "the final text names the three details", 'Write-Say "  address:  $base"', "$null = 0", "test_G73_"),
    ("G74", "-Remove does not touch config", '    if ($hadRunner) { Remove-Item -LiteralPath $runner -Force }', '    if ($hadRunner) { Remove-Item -LiteralPath $runner -Force }\n    Remove-Item -LiteralPath (Join-Path $HermesHome "config.yaml") -Force', "test_G74_"),
    ("S23", "every function name is unique", "function Write-Step(", "function Write-Say(", "test_every_function_has_a_body_and_a_unique_name"),
    ("G75", "a launcher that is there but does not answer is never repaired by the installer", 'Repair Hermes first, then run this again. Nothing was changed."\n            return 1', 'Repair Hermes first, then run this again. Nothing was changed."', "test_G75_"),
    ("G76", "a Hermes outside the standard place stops the setup", "if ($elsewhere) {", "if ($false) {", "test_G76_"),
    ("G77", "the result of the official installation is checked", "if (-not $installed -or -not $launcher) {", "if ($false) {", "test_G77_"),
    ("G77b", "install always: the installer runs before anything is looked at", "    $launcher = Find-HermesLauncher $HermesHome\n    if (-not $launcher) {", "    $null = Install-Hermes\n    $launcher = Find-HermesLauncher $HermesHome\n    if (-not $launcher) {", "test_G77_"),
    ("G78", "the installer keeps -NonInteractive", '@("-NonInteractive", "-SkipBrowser", "-SkipComputerUse")', '@("-SkipBrowser", "-SkipComputerUse")', "test_G78_"),
    ("G79", "an old Bridge is reported with its command", "run this setup again with -RetireBridge", "run this setup again", "test_G79_"),
    ("G79b", "setup never retires the old Gateway exposure by itself", '        $oldGateway = (Test-GatewayExposurePresent $HermesHome)', '        $null = Invoke-RetireGatewayExposure $HermesHome $false\n        $oldGateway = (Test-GatewayExposurePresent $HermesHome)', "test_G79_"),
    # S2d: the QR that Console scans
    ("Q01", "the password goes to the builder as an argument", '@("-I", "-c", $builder) `', '@("-I", "-c", $builder, $CodePassword) `', "test_G85_"),
    ("Q02", "a Gateway token goes into the code", '("user", user)] + ([("pass"', '("user", user), ("token", "x")] + ([("pass"', "test_G80_"),
    ("Q03", "the old version-1 format", '[("v", "2"), ("url", url)', '[("v", "1"), ("url", url)', "test_G80_"),
    ("Q04", "a failed drawing stops the setup", '            Write-Say "I could not draw the code here; type these three details in Console."', '            throw "I could not draw the code here; type these three details in Console."', "test_G83_"),
    ("Q05", "the drawing is kept in a temporary file", "    Write-Say $art\n", '    $art | Out-File -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) "code.txt")\n    Write-Say $art\n', "test_G85_"),
    ("Q06", "a code is drawn for another provider too", 'if ($login.STATE -ne "other" -and $login.USER) {', "if ($true) {", "test_G84_"),
    ("Q07", "uv keeps its environment", '"run", "--isolated", "--no-project"', '"run", "--no-project"', "test_G82_"),
    ("Q08", "uv takes the newest library", '"qrcode==8.2"', '"qrcode"', "test_G82_"),
    ("Q09", "the link is drawn on the command line of the drawer", '-InputText $Link -TimeoutSeconds 120', '-TimeoutSeconds 120', "test_G81_"),
    ("Q10", "the code is drawn twice", "        $codePassword = \"\"\n        if (Test-Path", "        Show-PairingCode -Base $base -UserName $login.USER -CodePassword $codePassword -Python $python -HermesHome $HermesHome\n        $codePassword = \"\"\n        if (Test-Path", "test_G86_"),
    ("Q11", "an earlier sign-in gets a password in the code", "            $codePassword = $secret\n", "", "test_G84_"),
    ("Q12", "the builder is no longer the shell one", 'safe=""))\'', 'safe="x"))\'', "test_the_builder_is_python_and_the_same_as_the_shell_one"),
    # S2e: uv where the current official installer leaves it
    ("Q14", "uv is looked for only in bin", 'if ($best) { return $best }', 'if ($false) { return $best }', "test_G87_"),
    ("Q15", "the oldest uv under tools is taken", '$version -gt $bestVersion', '$version -lt $bestVersion', "test_G87_"),
    ("Q16", "uv versions are compared as text", '$version = [version]$Matches[1]', '$version = $Matches[1]', "test_G87_"),
    ("Q17", "any uv-* folder program is taken", 'Join-Path $folder.FullName "uv.exe"', 'Join-Path $folder.FullName "*.exe"', "test_G87_"),
    ("Q18", "any folder of tools is searched", '-Directory -Filter "uv-*"', '-Directory -Filter "*"', "test_G87_"),
    ("Q19", "PATH comes before tools", '    $best = ""\n', '    $early = Get-Command uv -ErrorAction SilentlyContinue\n    if ($early) { return $early.Source }\n    $best = ""\n', "test_G87_"),
    ("Q20", "uv no longer found by Find-Uv", '$uv = Find-Uv $HermesHome', '$uv = ""', "test_G87_"),
    ("Q13", "the password is not url-encoded", "u.urlencode(pairs, quote_via=u.quote, safe=\"\")", "\"&\".join(k + \"=\" + v for k, v in pairs)", "test_the_link_has_the_version"),
    ("Q21", "no private address: Tailscale is no longer named", 'Console connects through Tailscale. Install it from https://tailscale.com/download/windows and sign in,`n', '', "test_G88_"),
    ("Q22", "no private address: 'run this command again' is dropped", 'Then run this same command again.', 'Then carry on.', "test_G88_"),
    ("Q23", "the old entry name comes back", 'In Console: Connect manually -> paste the address and the user, then type your password.', 'In Console: Type an address -> paste the address and the user, then type your password.', "test_G89_"),
]

def run_suite(script: pathlib.Path) -> tuple[int, str]:
    env = dict(os.environ, DASHBOARD_ONLY_PS1=str(script), PYTHONDONTWRITEBYTECODE="1")
    completed = subprocess.run(
        [sys.executable, "-B", str(SUITE), "-v"], capture_output=True, text=True, timeout=300, env=env, cwd=ROOT,
    )
    return completed.returncode, completed.stderr + completed.stdout


def main() -> int:
    wanted = set(sys.argv[1:])
    original = SCRIPT.read_text(encoding="ascii")
    code, output = run_suite(SCRIPT)
    if code != 0:
        print("the unmutated script does not pass the suite:\n" + output[-3000:])
        return 2
    print("unmutated script: suite passes")
    killed = survived = 0
    problems: list[str] = []
    with tempfile.TemporaryDirectory(prefix="dash-ps1-mutants-") as raw:
        for mutant_id, description, old, new, expected in MUTANTS:
            if wanted and mutant_id not in wanted:
                continue
            count = original.count(old)
            if count != 1:
                problems.append(f"{mutant_id}: the text to mutate occurs {count} times, not once")
                continue
            path = pathlib.Path(raw) / f"{mutant_id}.ps1"
            path.write_bytes(original.replace(old, new).encode("utf-8"))
            code, output = run_suite(path)
            failing = re.findall(r"^(test\w+) \(.*?\) \.\.\. (?:FAIL|ERROR)", output, re.M)
            failing += re.findall(r"^(?:FAIL|ERROR): (test\w+)", output, re.M)
            if code != 0 and any(expected in name for name in failing):
                killed += 1
                print(f"KILLED   {mutant_id}  {description}")
            else:
                survived += 1
                problems.append(f"{mutant_id}: survived or killed by the wrong test ({description}); failing: {failing[:3]}")
                print(f"SURVIVED {mutant_id}  {description}")
    total = killed + survived + len([p for p in problems if "occurs" in p])
    print(f"\n{killed}/{total} mutants killed")
    for line in problems:
        print("PROBLEM", line)
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
