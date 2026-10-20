#!/usr/bin/env python3
"""Dashboard-only setup for Windows (hermes-dashboard-setup.ps1): static contract.

There is no PowerShell on the machines that run this suite (Linux CI, the
maintainer's computers), so this file can NOT run the script. It reads it. What
it proves is what a reader can prove from the text: the file is plain ASCII with
no byte-order mark, its brackets and quotes balance, it keeps clear of the
Gateway, the API key, the old pairing record, downloads and personal data, each guard
that protects the user is written where it must be, and the Python it embeds is
the same Python hermes-dashboard-setup.sh already tests against Hermes.

What it does NOT prove is that the script works on Windows. That is shown by
tests/dashboard-only-windows.Tests.ps1 (pure functions and a stand-in
Dashboard, run by the Windows job of the CI) and by the run on a real Windows 11
machine described in the report that came with this change. A passing static test
means "the guard is still written", not "the guard works".

DASHBOARD_ONLY_PS1 points the suite at another copy of the script (the mutant
runner uses it).
"""

from __future__ import annotations

import ast
import os
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = pathlib.Path(os.environ.get("DASHBOARD_ONLY_PS1") or ROOT / "hermes-dashboard-setup.ps1")
SH_SCRIPT = ROOT / "hermes-dashboard-setup.sh"
OFFICIAL_INSTALL = "iex (irm https://hermes-agent.nousresearch.com/install.ps1)"


def strip_comments_and_strings(source: str) -> str:
    """Source without comments and without the inside of strings and here-strings.

    Enough to count brackets honestly. Not a PowerShell parser.
    """
    out: list[str] = []
    i, n = 0, len(source)
    while i < n:
        c = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if c == "#":
            while i < n and source[i] != "\n":
                i += 1
            continue
        if c == "@" and nxt in "'\"" and source[i + 2: i + 3] in ("\n", "\r"):
            quote = nxt
            end = source.find("\n" + quote + "@", i + 2)
            if end < 0:
                raise AssertionError("unterminated here-string")
            i = end + 3
            out.append('""')
            continue
        if c == "'":
            i += 1
            while i < n:
                if source[i] == "'":
                    if source[i + 1: i + 2] == "'":
                        i += 2
                        continue
                    break
                i += 1
            i += 1
            out.append("''")
            continue
        if c == '"':
            i += 1
            while i < n:
                if source[i] == "`":
                    i += 2
                    continue
                if source[i] == '"':
                    if source[i + 1: i + 2] == '"':
                        i += 2
                        continue
                    break
                i += 1
            i += 1
            out.append('""')
            continue
        out.append(c)
        i += 1
    return "".join(out)


def code_only(source: str) -> str:
    """Lines that are not comments (strings kept: they carry the commands)."""
    return "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("#"))


def here_string(source: str, variable: str) -> str:
    match = re.search(r"^" + re.escape(variable) + r" = @'\n(.*?)\n'@\n", source, re.M | re.S)
    assert match, variable
    return match.group(1)


def shell_heredoc(source: str, name: str) -> str:
    match = re.search(r"<<'" + name + r"'\n(.*?)\n" + name + r"\n", source, re.S)
    assert match, name
    return match.group(1)


class FileContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = SCRIPT.read_bytes()
        cls.source = cls.raw.decode("utf-8", errors="replace")

    def test_it_exists(self) -> None:
        self.assertTrue(SCRIPT.is_file(), "hermes-dashboard-setup.ps1 is missing")

    def test_plain_ascii_without_a_byte_order_mark(self) -> None:
        # [scriptblock]::Create(...) chokes on a mark (Hermes' own docs say so,
        # website/docs/user-guide/windows-native.md); plain ASCII needs none.
        self.assertFalse(self.raw.startswith(b"\xef\xbb\xbf"))
        self.raw.decode("ascii")

    def test_lf_line_endings_as_gitattributes_ask(self) -> None:
        self.assertNotIn(b"\r", self.raw)
        self.assertTrue(self.raw.endswith(b"\n"))

    def test_it_says_what_it_is_in_its_first_line(self) -> None:
        self.assertTrue(self.source.startswith("# Hermes Console - Dashboard-only setup for native Windows"))

    def test_brackets_and_quotes_balance(self) -> None:
        # Structural only (a real parse is the Windows job). A stray quote or
        # brace shows up here before it shows up there.
        bare = strip_comments_and_strings(self.source)
        pairs = {"(": ")", "{": "}", "[": "]"}
        stack: list[tuple[str, int]] = []
        for number, line in enumerate(bare.splitlines(), 1):
            for char in line:
                if char in pairs:
                    stack.append((char, number))
                elif char in pairs.values():
                    self.assertTrue(stack, f"closing {char} without opener at line {number}")
                    opener, at = stack.pop()
                    self.assertEqual(pairs[opener], char, f"{opener} from line {at} closed by {char} at line {number}")
        self.assertEqual(stack, [], f"unclosed: {stack[:3]}")

    def test_every_function_has_a_body_and_a_unique_name(self) -> None:
        names = re.findall(r"^function ([A-Za-z][A-Za-z0-9-]*)", self.source, re.M)
        self.assertGreater(len(names), 40)
        self.assertEqual(len(names), len(set(names)), "a function is defined twice")

    def test_it_is_not_a_cmdlet_with_positional_arguments(self) -> None:
        self.assertIn("[CmdletBinding(PositionalBinding = $false)]", self.source)


class PrivacyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SCRIPT.read_text(encoding="ascii")

    def test_no_private_paths_names_or_hosts(self) -> None:
        for fragment in ("/home/", "xpeta@", "udyat", "C:\\Users\\", "win11", "proxmox"):
            self.assertNotIn(fragment.lower(), self.source.lower(), fragment)

    def test_no_address_written_out_except_the_two_that_are_not_anyones(self) -> None:
        quads = set(re.findall(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", self.source))
        self.assertLessEqual(quads, {"0.0.0.0", "100.64.0.0", "127.0.0.1"}, quads)

    def test_this_test_file_names_no_person_either(self) -> None:
        text = pathlib.Path(__file__).read_text(encoding="utf-8")
        self.assertNotIn("/home/xp" + "eta", text)


class SurfaceTests(unittest.TestCase):
    """What the script is made of: it keeps clear of the Gateway and the API key."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SCRIPT.read_text(encoding="ascii")
        match = re.search(
            r"^# Undo what hermes-mobile-setup\.ps1 added.*?^#endregion retire-gateway-exposure\n",
            cls.source, re.M | re.S,
        )
        assert match, "the retire-gateway-exposure region is missing"
        cls.retire = match.group(0)
        cls.outside_retire = cls.source.replace(cls.retire, "")

    def test_nothing_outside_the_retire_path_knows_the_api_server(self) -> None:
        for fragment in ("API_SERVER", "gateway run", "gateway install", "gateway start", "gateway stop",
                         "hermes-gateway", "HermesConsole-Gateway", "Hermes_Gateway"):
            self.assertNotIn(fragment, self.outside_retire, fragment)

    def test_the_retire_path_never_stops_starts_or_removes_a_service_or_process(self) -> None:
        for cmdlet in ("Stop-ScheduledTask", "Start-ScheduledTask", "Unregister-ScheduledTask", "Stop-Process",
                       "Restart-", "Stop-Service", "taskkill", "Disable-ScheduledTask", "Register-ScheduledTask"):
            self.assertNotIn(cmdlet, code_only(self.retire), cmdlet)

    def test_the_retire_path_does_not_run_hermes(self) -> None:
        for fragment in ("Invoke-HermesPython", "Find-HermesLauncher", "hermes.exe", "Invoke-NativeProcess"):
            self.assertNotIn(fragment, code_only(self.retire), fragment)

    def test_the_only_code_is_the_dashboard_one_and_it_never_names_the_gateway(self) -> None:
        # S2d: one QR with v=2, url, user (and pass); no old pairing record, no Gateway field.
        self.assertEqual(code_only(self.outside_retire).count("hermes://pair"), 1)
        for fragment in ("pairing-qr", "pairing.json", "Write-PairingQr", "Render-Qr", "dash_user", "dash_pass",
                         "PAIRING", '("token"', "token=", "host=", "port="):
            self.assertNotIn(fragment, self.outside_retire, fragment)

    def test_hermes_is_installed_only_by_the_official_installer_and_only_in_one_place(self) -> None:
        # S2b: the one download is Install-Hermes; nothing else fetches or installs.
        function = re.search(r"^function Install-Hermes \{.*?^\}\n", self.source, re.M | re.S)
        self.assertIsNotNone(function)
        code = code_only(self.source.replace(function.group(0), ""))
        for fragment in ("Invoke-WebRequest", "Invoke-RestMethod", "DownloadString", "DownloadFile",
                         "Start-BitsTransfer", "WebClient", "git clone", "pip install", "irm ", "curl ",
                         "Install-Module", "winget", "choco "):
            self.assertNotIn(fragment, code, fragment)
        body = code_only(function.group(0))
        self.assertEqual(body.count("Invoke-WebRequest"), 1)
        self.assertEqual(self.source.count("https://hermes-agent.nousresearch.com/install.ps1"), 1)
        self.assertIn('@("-NonInteractive", "-SkipBrowser", "-SkipComputerUse")', self.source)
        urls = set(re.findall(r"https?://[^\s\"')]+", code))
        # the official installer, and the one address the Dashboard is probed at
        self.assertEqual(urls, {"http://$($bind.Address", "https://hermes-agent.nousresearch.com/install.ps1"}, urls)

    def test_http_goes_only_to_the_address_it_just_chose(self) -> None:
        self.assertEqual(len(re.findall(r"\[Net\.HttpWebRequest\]::Create\(", self.source)), 1)
        self.assertIn('$base = "http://$($bind.Address):$portNumber"', self.source)
        self.assertIn("$request.Proxy = $null", self.source)
        self.assertIn("$request.AllowAutoRedirect = $false", self.source)

    def test_the_firewall_is_never_switched_off_or_opened_wide(self) -> None:
        code = code_only(self.source)
        for fragment in ("Set-NetFirewallProfile", "advfirewall", "-Enabled False", "Disable-NetFirewallRule",
                         "Set-ExecutionPolicy", "-RemoteAddress Any", "-LocalAddress Any", "-LocalAddress 0.0.0.0",
                         "Set-MpPreference", "Add-MpPreference"):
            self.assertNotIn(fragment, code, fragment)

    def test_it_does_not_ask_for_elevation_by_itself(self) -> None:
        code = code_only(self.source)
        for fragment in ("-Verb", "RunAs"):
            self.assertNotIn(fragment, code, fragment)
        # The only process it starts is the official installer, in Install-Hermes.
        function = re.search(r"^function Install-Hermes \{.*?^\}\n", self.source, re.M | re.S).group(0)
        self.assertEqual(code.count("Start-Process"), 1)
        self.assertIn("Start-Process", function)


class PasswordHandlingTests(unittest.TestCase):
    """The password is in memory, on a pipe and in a private file; never on a command line."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SCRIPT.read_text(encoding="ascii")
        cls.code = code_only(cls.source)

    def test_a_password_parameter_exists_only_to_be_refused(self) -> None:
        self.assertIn("[string]$Password = $null", self.source)
        uses = [line for line in self.code.splitlines() if re.search(r"\$Password\b", line)]
        self.assertEqual(len(uses), 1, uses)

    def test_the_password_variables_are_used_only_in_the_places_that_are_meant(self) -> None:
        allowed = (
            "$givenPassword = $null", "$givenPassword = Read-PasswordFromStdin", '$stdinText = $givenPassword + "`n"',
            "$newPassword = ", "$secret = $newPassword", "if (-not $secret) { $secret = $givenPassword }",
            "$codePassword = $secret",
            "-PasswordText $secret", "Write-Say \"  password: $newPassword\"", "if ($newPassword) {",
        )
        for number, line in enumerate(self.code.splitlines(), 1):
            if re.search(r"\$(givenPassword|newPassword|secret)\b", line):
                self.assertTrue(any(item in line for item in allowed), f"line {number}: {line.strip()}")

    def test_no_password_in_an_argument_list_an_environment_variable_or_a_file_in_clear(self) -> None:
        for line in self.code.splitlines():
            if re.search(r"\$(givenPassword|newPassword|secret)\b", line):
                self.assertNotRegex(line, r"-Environment|\.EnvironmentVariables|Set-Content|Out-File|Add-Content|\bArguments\b")
        self.assertNotIn("Start-Transcript", self.code)

    def test_the_stdin_password_is_read_as_bytes_and_decoded_as_utf8(self) -> None:
        self.assertIn("[Console]::OpenStandardInput()", self.source)
        self.assertIn("$script:Utf8NoBom.GetBytes($InputText)", self.source)

    def test_the_generated_password_comes_back_through_a_private_file_not_stdout(self) -> None:
        self.assertIn('$passwordFile = Join-Path $work "new-password"', self.source)
        self.assertIn("Remove-Item -LiteralPath $passwordFile -Force", self.source)
        self.assertIn("New-PrivateDirectory $work", self.source)


class EmbeddedPythonTests(unittest.TestCase):
    """The sign-in code is the code hermes-dashboard-setup.sh already tests against Hermes."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SCRIPT.read_text(encoding="ascii")
        cls.sh = SH_SCRIPT.read_text(encoding="utf-8")

    def test_both_files_are_python(self) -> None:
        ast.parse(here_string(self.source, "$script:AuthSource"))
        ast.parse(here_string(self.source, "$script:RestoreSource"))

    def test_the_restore_code_is_the_one_of_the_shell_script(self) -> None:
        self.assertEqual(here_string(self.source, "$script:RestoreSource"), shell_heredoc(self.sh, "PY_RESTORE"))

    def test_the_auth_code_is_the_one_of_the_shell_script_but_for_the_way_it_reads_stdin(self) -> None:
        mine = here_string(self.source, "$script:AuthSource").splitlines()
        theirs = shell_heredoc(self.sh, "PY_AUTH").splitlines()
        self.assertEqual(len(mine), len(theirs))
        different = [(a, b) for a, b in zip(mine, theirs) if a != b]
        self.assertEqual(len(different), 1, different)
        self.assertIn("sys.stdin.buffer.readline().decode(\"utf-8\")", different[0][0])
        self.assertIn("sys.stdin.readline()", different[0][1])


def sh_pairing_builder(sh: str) -> str:
    match = re.search(r"\| \"\$VP\" -I -c '(import sys, urllib\.parse as u\n.*?)' 2>/dev/null\)\"", sh, re.S)
    assert match, "the pairing builder is missing from the shell script"
    return match.group(1)


def ps1_pairing_builder(source: str) -> str:
    block = re.search(r"\$builder = (.*?)\n    \$art = \"\"", source, re.S)
    assert block, "the pairing builder is missing from the PowerShell script"
    pieces = re.findall(r"'((?:[^']|'')*)'|\"(`n)\"", block.group(1))
    return "".join("\n" if newline else text.replace("''", "'") for text, newline in pieces)


class PairingCodeTextTests(unittest.TestCase):
    """S2d: the code Console scans is built by the same Python in both scripts, and it is right."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SCRIPT.read_text(encoding="ascii")
        cls.sh = SH_SCRIPT.read_text(encoding="utf-8")
        cls.builder = ps1_pairing_builder(cls.source)

    def build(self, *lines: str, builder=None) -> str:
        import subprocess
        import sys
        data = ("\n".join(lines) + "\n").encode("utf-8")
        done = subprocess.run([sys.executable, "-I", "-c", builder or self.builder], input=data,
                              capture_output=True, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr.decode())
        return done.stdout.decode("utf-8").strip()

    def test_the_builder_is_python_and_the_same_as_the_shell_one(self) -> None:
        ast.parse(self.builder)
        self.assertEqual(self.builder, sh_pairing_builder(self.sh))

    def test_the_link_has_the_version_the_address_the_user_and_the_password_in_this_order(self) -> None:
        link = self.build("http://192.0.2.7:9119", "admin", "abcde-fghij-klmno-pqrst")
        self.assertEqual(link, "hermes://pair?v=2&url=http%3A%2F%2F192.0.2.7%3A9119&user=admin"
                               "&pass=abcde-fghij-klmno-pqrst")

    def test_without_a_password_there_is_no_pass(self) -> None:
        link = self.build("http://192.0.2.7:9119", "admin", "")
        self.assertEqual(link, "hermes://pair?v=2&url=http%3A%2F%2F192.0.2.7%3A9119&user=admin")

    def test_symbols_and_accents_are_encoded_as_utf8(self) -> None:
        link = self.build("http://192.0.2.7:9119", "an\u00eda", "p&w=%1 \u00f1")
        self.assertIn("&user=an%C3%ADa&pass=p%26w%3D%251%20%C3%B1", link)

    def test_nothing_of_the_gateway_can_be_in_it(self) -> None:
        for fragment in ("token", "host=", "port=", "API_SERVER", "env"):
            self.assertNotIn(fragment, self.builder, fragment)


# ---------------------------------------------------------------------------
# One test per guard. Each says "this guard is still written, here".
# tests/dashboard-only-windows_mutants.py removes each in turn and needs the
# matching test to fail.
# ---------------------------------------------------------------------------

GUARDS: list[tuple[str, str, list[str]]] = [
    ("G01", "an unexpected argument is refused without showing it",
     [r"if \(\$UnexpectedCount -gt 0\) \{\s+throw \"Unexpected argument \(its value is not shown\)"]),
    ("G02", "a password on the command line is refused",
     [r"if \(\$PasswordGiven\) \{\s+throw \(\"A password is never taken from the command line",
      r"\$script:PasswordWasGiven = \$PSBoundParameters\.ContainsKey\(\"Password\"\)",
      r"-PasswordGiven \$script:PasswordWasGiven"]),
    ("G03", "two actions at once are refused",
     [r"if \(\$chosen\.Count -gt 1\) \{\s+throw \(\"Choose one action at a time"]),
    ("G04", "-AlsoRemoveApiKey goes only with -RetireGatewayExposure",
     [r"if \(\$AlsoRemoveApiKey -and \$action -ne \"retire-gateway-exposure\"\) \{\s+throw"]),
    ("G05", "-PasswordStdin goes only with setup or -NewAccess",
     [r"if \(\$PasswordStdin -and \$action -ne \"setup\" -and \$action -ne \"new-access\"\) \{\s+throw"]),
    ("G06", "an empty password on stdin is refused",
     [r"if \(\[string\]::IsNullOrWhiteSpace\(\$text\)\) \{\s+throw \"The password on standard input is empty"]),
    ("G07", "the password must really be piped in",
     [r"if \(-not \[Console\]::IsInputRedirected\) \{\s+throw"]),
    ("G08", "HERMES_HOME must be an absolute path",
     [r"-not \[IO\.Path\]::IsPathRooted\(\$Candidate\)\) \{\s+throw \"HERMES_HOME must be one absolute path"]),
    ("G09", "HERMES_HOME may not be a filesystem root",
     [r"\$resolved\.TrimEnd\(\$sep\) -eq \$root\.TrimEnd\(\$sep\)\) \{\s+throw \"HERMES_HOME cannot be a filesystem root"]),
    ("G10", "HERMES_HOME without characters a runner cannot carry",
     [r"if \(Test-UnsafePathText \$resolved\) \{ throw", r"\$Text -match '\[\"%\^&!\|<>\\x00-\\x1f\]'"]),
    ("G11", "HERMES_HOME may not be a link or junction",
     [r"if \(Test-ReparsePoint \$resolved\) \{ throw"]),
    ("G12", "a second Hermes home is not chosen over the one that exists",
     [r"\(Test-HermesHomeEvidence \$default\)\) \{\s+throw \"Another Hermes home exists"]),
    ("G13", "a setup that is already running refuses the second",
     [r"if \(-not \$acquired\) \{\s+\$mutex\.Dispose\(\)\s+throw \"Another Console setup is already running"]),
    ("G14", "only a private LAN or CGNAT address is a valid bind",
     [r"\$b\[0\] -eq 10\) \{ return \$true \}", r"\$b\[0\] -eq 172 -and \$b\[1\] -ge 16 -and \$b\[1\] -le 31\) \{ return \$true \}",
      r"\$b\[0\] -eq 192 -and \$b\[1\] -eq 168\) \{ return \$true \}",
      r"\$b\[0\] -eq 100 -and \$b\[1\] -ge 64 -and \$b\[1\] -le 127\) \{ return \$true \}\s+return \$false"]),
    ("G15", "the bind is IPv4 only",
     [r"\$ip\.AddressFamily -ne \[Net\.Sockets\.AddressFamily\]::InterNetwork\) \{ return \$false \}"]),
    ("G16", "the bind is written in canonical form",
     [r"if \(\$ip\.ToString\(\) -ne \$Text\) \{ return \$false \}"]),
    ("G17", "the bind must be an address of this computer",
     [r"if \(\$mine\.Count -eq 0\) \{\s+throw \"The address \$Chosen is not assigned to this computer"]),
    ("G18", "a LAN bind must be on a network marked Private",
     [r"\[string\]\$profile\.NetworkCategory -ne \"Private\"\) \{\s+throw"]),
    ("G19", "the port must be a TCP port",
     [r"\$parsed -lt 1 -or \$parsed -gt 65535\) \{\s+throw"]),
    ("G20", "a Scheduled Task that is not this home's is refused",
     [r"\n {8}if \(\$task -and -not \(Test-DashboardTaskOwned \$task \$runner\)\) \{\s+throw"]),
    ("G21", "a port held by something that is not this Dashboard is refused",
     [r"if \(-not \(Test-PortHeldByOwnDashboard \$HermesHome \$portNumber \$runner\)\) \{[^}]*return 1"]),
    ("G22", "without a launcher that answers, it looks before it installs anything",
     [r"if \(-not \$launcher\) \{\s+if \(Find-HermesLauncher \$HermesHome -SeenOnly\)"]),
    ("G75", "a launcher that is there but does not answer is never repaired by the installer",
     [r"-SeenOnly\) \{[^}]*The official installer would repair or[^}]*return 1"]),
    ("G76", "a Hermes found outside the standard place stops the setup without installing",
     [r"Get-Command hermes -ErrorAction SilentlyContinue[^}]*if \(\$elsewhere\) \{[^}]*return 1"]),
    ("G77", "the official installer runs only when nothing was found, and its result is checked",
     [r"\$installed = Install-Hermes\s+\$launcher = Find-HermesLauncher \$HermesHome\s+if \(-not \$installed -or -not \$launcher\) \{[^}]*changed nothing[^}]*return 1"]),
    ("G78", "the official installer gets exactly its non-interactive flags, in a child PowerShell",
     [r'OfficialInstallArguments = @\("-NonInteractive", "-SkipBrowser", "-SkipComputerUse"\)',
      r"\$arguments = @\(\"-NoProfile\", \"-ExecutionPolicy\", \"Bypass\", \"-File\", \$file\) \+ \$script:OfficialInstallArguments",
      r"return \(\$run\.ExitCode -eq 0\)"]),
    ("G79", "an old install is reported with the two commands and never retired by itself",
     [r"Test-GatewayExposurePresent \$HermesHome\)\s+\$oldBridge = \(Test-BridgeLeftoversPresent",
      r"run this setup again with -RetireGatewayExposure", r"run this setup again with -RetireBridge",
      r"Nothing was changed: Console 1\.2 needs them"]),
    ("G23", "Hermes must be able to run its own configuration code",
     [r"if \(\$check\.Code -ne 0\) \{\s+throw \"Hermes cannot run its own configuration code"]),
    ("G24", "the runtime command Hermes publishes is checked before it is used",
     [r"\$command\.Count -lt 4 -or \$command\[1\] -ne \"-I\" -or \$command\[2\] -ne \"-c\""]),
    ("G25", "a launcher must answer before it counts",
     [r"if \(\$probe\.Code -ne 0\) \{ continue \}"]),
    ("G26", "a launcher outside the home must be bound to this install",
     [r"if \(-not \[string\]::Equals\(\$reported, \$expected, \[StringComparison\]::OrdinalIgnoreCase\)\) \{ continue \}"]),
    ("G27", "the Dashboard binds the chosen address, never all of them, and never opens a browser",
     [r"dashboard --host \$BindAddress --port \$PortNumber --no-open\$extra"]),
    ("G28", "the service starts with the computer, without a stored password",
     [r"New-ScheduledTaskTrigger -AtStartup", r"-LogonType S4U"]),
    ("G29", "the service is brought back when it stops",
     [r"-RestartCount 999", r"-MultipleInstances IgnoreNew"]),
    ("G30", "the firewall rule is for one local address and one port, on Private only",
     [r"\$profile = \"Private\"", r"\$remote = \"LocalSubnet\"", r"LocalPort = \"\$PortNumber\"; LocalAddress = \[string\]\$Bind\.Address"]),
    ("G31", "the Tailscale rule is limited to Tailscale's own range",
     [r"\$remote = \"100\.64\.0\.0/10\""]),
    ("G32", "a rule that differs from the wanted one is replaced, not widened",
     [r"if \(\$have\) \{ Remove-NetFirewallRule -Name \$script:FirewallRuleName -ErrorAction Stop \}",
      r"if \(\[string\]\$Have\[\$key\] -ne \[string\]\$Want\[\$key\]\) \{ return \$false \}"]),
    ("G33", "without elevation the firewall is not changed and the user is told",
     [r"\} elseif \(Test-CurrentProcessAdministrator\) \{", r"\$firewall = \"needs-administrator\""]),
    ("G34", "the firewall is ready before the Dashboard starts listening",
     []),  # order check below
    ("G35", "a Dashboard that does not refuse an anonymous visitor fails the setup",
     [r"\$answer\.Status -ne 401 -and \$answer\.Status -ne 403\) \{\s+throw"]),
    ("G36", "a sign-in that was just made must really open the Dashboard",
     [r"\$login\.Status -in 400, 401, 403\) \{ return 10 \}", r"EndsWith\(\"hermes_session_at\"\)",
      r"if \(\$verified -eq 10\) \{ throw \"The Dashboard did not accept the sign-in this setup just made"]),
    ("G37", "the sign-in is verified with the password that was made, or with none",
     [r"\$verified = Test-DashboardAnswers -Base \$base -Mode \"login\" -UserName \$login\.USER -PasswordText \$secret",
      r"\$verified = Test-DashboardAnswers -Base \$base -Mode \"refuse\""]),
    ("G38", "a Dashboard that never starts fails the setup and is rolled back",
     [r"if \(-not \$ready\) \{\s+Show-DashboardFailure[^}]*throw \"The Dashboard did not start"]),
    ("G39", "a failing setup is rolled back, whatever stopped it",
     [r"\} catch \{\s+Write-Problem \"ERROR: \$\(\$_\.Exception\.Message\)\"\s+Undo-DashboardSetup\s+return 1",
      r"\} finally \{\s+if \(\$script:Txn -and \$script:Txn\.Pending\) \{ Undo-DashboardSetup \}"]),
    ("G40", "the rollback gives the sign-in settings back",
     [r"Invoke-HermesPython \$t\.Python \$t\.HermesHome \$restore @\(\$t\.PreviousPath\)"]),
    ("G41", "the rollback gives back the service, its runner and its rule",
     [r"Register-ScheduledTask -TaskName \$script:TaskName -TaskPath \"\\\" -Xml \$t\.PreviousTaskXml",
      r"Remove-NetFirewallRule -Name \$script:FirewallRuleName -ErrorAction Stop\s+\}\s+if \(\$t\.PreviousRule\) \{ New-DashboardRule \$t\.PreviousRule \}"]),
    ("G42", "stopping the Dashboard stops its whole process tree, not just the task",
     [r"foreach \(\$id in \(Get-DescendantProcessIds \$roots\)\)", r"foreach \(\$id in \(Get-OwnDashboardProcessIds \$HermesHome \$PortNumber \$Runner\)\) \{\s+Stop-Process"]),
    ("G43", "the work folder is private to its owner",
     [r"New-PrivateDirectory \$work", r"icacls\.exe \$Path /inheritance:r"]),
    ("G44", "a sign-in the user already has is not touched (auth code)",
     [r"if providers:\n        say\(\"existing\""]),
    ("G45", "the old clear-text password file is removed only when a new sign-in replaces it",
     [r"\$login\.STATE -eq \"created\" -and \(Test-Path -LiteralPath \$stale\)"]),
    ("G46", "the old clear-text password file is reported when it stays",
     [r"still holds the Dashboard password"]),
    ("G47", "a broader firewall rule of someone else is reported, not changed",
     [r"Get-BroaderPortRules \$portNumber", r"\(not made by this setup, left as it is\)"]),
    ("G48", "retire: the API key stays unless it is asked for",
     [r"\$removeKey = \(\$AlsoRemoveKey -and \$keyPresent\)"]),
    ("G49", "retire: the key line goes only when it was asked for, with a private copy",
     [r"if \(\$removeKey\) \{\s+\$newEnv = Remove-MatchingLines", r"Set-PrivateAcl \$backup", r"if \(\$removeKey\) \{ Write-TextFileKeepingAccess"]),
    ("G50", "retire: only the two variables of the earlier setup leave the runner",
     [r"API_SERVER_\(HOST\|PORT\)\"\\\)\\s\*=",
      r"if \(\$hasRunnerExposure\) \{ \$newRunner = Remove-MatchingLines \$runnerFile\.Text \$runnerPattern \}"]),
    ("G51", "retire: a link anywhere on the path stops it before anything changes",
     [r"if \(Test-ReparsePoint \$guarded\) \{ throw"]),
    ("G52", "retire: with nothing to undo it says so and changes nothing",
     [r"if \(-not \$evidence\) \{\s+Write-Say \"The earlier Console setup left nothing exposed"]),
    ("G53", "retire: only the rules the earlier setup made, and only its Gateway port",
     [r"\$rule\.Name -notlike \"HermesConsole-\*\" -or \$rule\.Name -eq \$script:FirewallRuleName",
      r"\$script:OldFirewallDisplayNames -notcontains \[string\]\$rule\.DisplayName",
      r"if \(\$ports -contains \"\$gatewayPort\"\) \{ \$rulesToChange \+= \$rule \}",
      r"\$left = @\(\$ports \| Where-Object \{ \$_ -ne \"\$gatewayPort\" \}\)"]),
    ("G54", "retire: the firewall is touched only when elevated, and it says when it could not",
     [r"if \(\$isAdmin\) \{\s+foreach \(\$rule in \$rulesToChange\)", r"NOT DONE: TCP"]),
    ("G55", "retire: the file keeps its owner-only access when it is rewritten",
     [r"Set-Acl -LiteralPath \$temp -AclObject \(Get-Acl -LiteralPath \$Path\)"]),
    ("G56", "retire: a value the user set in .env himself is reported, not removed",
     [r"your \.env sets API_SERVER_HOST itself"]),
    ("G57", "bridge: a task that is not this home's is refused before anything is removed",
     [r"\.IndexOf\(\$services, \[StringComparison\]::OrdinalIgnoreCase\) -lt 0\) \{\s+Write-Problem[^}]*return 1"]),
    ("G58", "bridge: only the process that runs this home's bridge is stopped",
     [r"\(\[string\]\$_\.CommandLine\)\.IndexOf\(\$target, \[StringComparison\]::OrdinalIgnoreCase\) -ge 0"]),
    ("G59", "bridge: the files go last and only after everything stopped",
     [r"if \(\$failed\.Count -eq 0\) \{\s+# The files go last"]),
    ("G60", "bridge: with no bridge it says so and changes nothing",
     [r"There is no Mobile Bridge on this computer\. Nothing to do\."]),
    ("G61", "the script is Windows only",
     [r"\[Environment\]::OSVersion\.Platform -ne \[PlatformID\]::Win32NT\) \{\s+throw"]),
    ("G62", "dot-sourcing defines the functions and runs nothing",
     [r"if \(\$MyInvocation\.InvocationName -eq \"\.\"\) \{ return \}"]),
    ("G63", "the exit code ends a file run but never closes the user's shell",
     [r"if \(\$PSCommandPath\) \{ exit \$exitCode \}"]),
    ("G64", "a message that cannot be written never stops the rollback",
     [r"function Write-Problem\(\[string\]\$Message\) \{ try \{ \[Console\]::Error\.WriteLine\(\$Message\) \} catch \{ \}"]),
    ("G65", "the wait goes on only while the log grows",
     [r"if \(\$size -le \$lastSize\) \{ break \}"]),
    ("G67", "-Remove is an action of its own",
     [r'if \(\$Remove\) \{ \$chosen \+= "remove" \}', r'"remove" \{ return \(Get-ExitCode \(Invoke-RemoveDashboard']),
    ("G68", "-Remove stops the Dashboard before it deletes anything",
     [r'if \(-not \(Stop-DashboardTask \$HermesHome \$portNumber \$runner\)\) \{\s+throw "The Dashboard could not be stopped, so nothing was deleted\."']),
    ("G69", "-Remove refuses a Scheduled Task that is not this home's",
     [r'\$task = Get-DashboardTask\n    if \(\$task -and -not \(Test-DashboardTaskOwned \$task \$runner\)\) \{\n        throw \("A Scheduled Task']),
    ("G70", "-Remove on a computer that never had the Dashboard does nothing",
     [r'if \(-not \$task -and -not \$hadRunner -and -not \$rule\) \{\s+Write-Say "Nothing to remove']),
    ("G71", "the first start is announced before the wait",
     [r'Write-Step "Starting the Dashboard in the background"\s+Write-Say "The first start can take a few minutes']),
    ("G72", "who already had access is told in plain words and offered -NewAccess",
     [r'(?s)"existing" \{.*?stored scrambled, so this setup cannot show it.*?Run this again with -NewAccess: it makes a new password']),
    ("G73", "the final text gives address, user and the Console steps",
     [r'  address:  \$base', r'In Console: Type an address -> paste these three details\.']),
    ("G74", "-Remove does not touch the sign-in, the Gateway or Hermes",
     []),
    ("G80", "the QR link is v=2 with url, user and pass, and nothing of the Gateway",
     [r'pairs = \[\("v", "2"\), \("url", url\), \("user", user\)\] \+ \(\[\("pass", secret\)\] if secret else \[\]\)',
      r'print\("hermes://pair\?" \+ u\.urlencode\(pairs, quote_via=u\.quote, safe=""\)\)']),
    ("G81", "the link and the password go to the drawers on standard input only",
     [r'-InputText \(\$Base \+ "`n" \+ \$UserName \+ "`n" \+ \$CodePassword \+ "`n"\)',
      r'-InputText \$Link -TimeoutSeconds 120']),
    ("G82", "the three ways of drawing, in order, with the pinned throwaway uv environment",
     [r'@\("-t", "ANSIUTF8", "-l", "M"\)',
      r'@\("-I", "-c", "import qrcode"\)\)\.Code -eq 0',
      r'@\("run", "--isolated", "--no-project", "--no-cache", "--python", \$PythonPath,\s+"--with", "qrcode==8\.2", "python", "-c", \$drawer\)']),
    ("G87", "uv is looked for in bin, then in tools\\uv-*\\uv.exe (newest version), then on PATH",
     [r'function Find-Uv\(\[string\]\$HermesHome\)',
      r'Join-Path \$HermesHome \"bin\\uv\.exe\"',
      r'Get-ChildItem -LiteralPath \(Join-Path \$HermesHome \"tools\"\) -Directory -Filter \"uv-\*\"',
      r'Join-Path \$folder\.FullName \"uv\.exe\"',
      r'\[version\]\$Matches\[1\]', r'\$version -gt \$bestVersion', r'if \(\$best\) \{ return \$best \}', r'Get-Command uv',
      r'\$uv = Find-Uv \$HermesHome']),
    ("G83", "if nothing draws the setup goes on and says what to type",
     [r'Write-Say "I could not draw the code here; type these three details in Console\."',
      r'Write-Say "I could not draw the code here; type the address and the user in Console, then the password\."\s+\}\s+return\s+\}']),
    ("G84", "a code only for a sign-in with a user, and the password only when this run made it",
     [r'if \(\$login\.STATE -ne "other" -and \$login\.USER\) \{\s+Show-PairingCode',
      r'\$secret = \$newPassword\s+if \(-not \$secret\) \{ \$secret = \$givenPassword \}\s+\$codePassword = \$secret',
      r'\$codePassword = ""\s+if \(\$login\.STATE -eq "created"\)']),
    ("G85", "the password never reaches a command line, a file or a temporary picture",
     []),
    ("G86", "the code is drawn once, after the credentials and before the leftovers warning",
     []),
    ("G66", "setup and rollback agree on the process tree of the old task",
     [r"\$t\.TaskTouched = \$true\s+if \(\$task\) \{ \[void\]\(Stop-DashboardTask"]),
]


def _make_guard_test(guard_id: str, description: str, patterns: list[str]):
    def test(self: unittest.TestCase) -> None:
        source = SCRIPT.read_text(encoding="ascii")
        if guard_id == "G34":
            rule = source.index("New-DashboardRule $want")
            start = source.index("Start-ScheduledTask -TaskName $script:TaskName -TaskPath \"\\\"\n")
            self.assertLess(rule, start, description)
            return
        if guard_id == "G77":
            # one definition, one call, and the call comes after both looks.
            self.assertEqual(len(re.findall(r"Install-Hermes\b", code_only(source))), 2, description)
            self.assertLess(source.index("-SeenOnly)"), source.index("= Install-Hermes"), description)
            self.assertLess(source.index("Get-Command hermes"), source.index("= Install-Hermes"), description)
        if guard_id == "G79":
            setup = re.search(r"^function Invoke-DashboardSetup \{.*?^\}\n", source, re.M | re.S).group(0)
            for fragment in ("Invoke-RetireGatewayExposure", "Invoke-RetireBridge", "Remove-Item -LiteralPath (Join-Path $services"):
                self.assertNotIn(fragment, code_only(setup).replace("Remove-Item -LiteralPath $work", ""), fragment)
        if guard_id == "G85":
            region = "\n".join(re.search(r"^function " + name + r".*?^\}\n", source, re.M | re.S).group(0)
                               for name in ("Invoke-QrDrawer", "Get-QrDrawing", "Show-PairingCode"))
            body = code_only(region)
            for fragment in ("Set-Content", "Out-File", "Add-Content", "GetTempPath", "GetTempFileName", "WriteAllText",
                             "WriteAllBytes", "[IO.File]", "New-Item", "Start-Transcript", "-Environment", " > ", ">>",
                             "$env:", "EnvironmentVariables", "Write-Output $Link", "Write-Say $link", "Write-Host $link"):
                self.assertNotIn(fragment, body, f"{guard_id}: {fragment}")
            for line in body.splitlines():
                if "$CodePassword" in line:
                    self.assertTrue("-InputText" in line or line.strip().startswith(("param(", "if ($CodePassword) {")),
                                    f"{guard_id}: {line.strip()}")
            self.assertEqual(body.count("-InputText"), 2, description)
            return
        if guard_id == "G87":
            find = re.search(r"^function Find-Uv\(.*?^\}\n", source, re.M | re.S).group(0)
            self.assertLess(find.index('"bin\\uv.exe"'), find.index('-Filter "uv-*"'), description)
            self.assertLess(find.index('-Filter "uv-*"'), find.index("Get-Command uv"), description)
            self.assertNotRegex(code_only(find), r'-Filter "(?!uv-\*")|"\*\.exe"|FullName \"(?!uv\.exe")', description)
        if guard_id == "G86":
            calls = [m.start() for m in re.finditer(r"Show-PairingCode -Base", source)]
            self.assertEqual(len(calls), 1, description)
            self.assertEqual(len(re.findall(r"Show-PairingCode\b", code_only(source))), 2, description)
            self.assertGreater(calls[0], source.index('Write-Say "sign-in and changed no configuration.'), description)
            self.assertLess(calls[0], source.index('Write-Say "WARNING: $services'), description)
            return
        if guard_id == "G74":
            region = re.search(r"^function Invoke-RemoveDashboard.*?^}\n", source, re.M | re.S).group(0)
            body = code_only(region)
            for fragment in ("Invoke-HermesPython", "Find-HermesLauncher", "WriteAllText", "WriteAllBytes", "Set-Content",
                             "Out-File", "API_SERVER", "gateway", 'Join-Path $HermesHome "config', '".env"'):
                self.assertNotIn(fragment, body, f"{guard_id}: {fragment}")
            self.assertEqual(body.count("Remove-Item"), 1, description)
            return
        if guard_id == "G44":
            source = here_string(source, "$script:AuthSource")
        for pattern in patterns:
            self.assertRegex(source, pattern, f"{guard_id}: {description}")

    test.__doc__ = description
    return test


class GuardTests(unittest.TestCase):
    """Each guard of the script is still written where it must be."""


for _id, _description, _patterns in GUARDS:
    setattr(GuardTests, f"test_{_id}_" + re.sub(r"[^a-z0-9]+", "_", _description.lower()).strip("_")[:60],
            _make_guard_test(_id, _description, _patterns))


if __name__ == "__main__":
    unittest.main(verbosity=2)
