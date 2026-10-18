#!/usr/bin/env python3
"""One mutant per guard of hermes-dashboard-setup.sh.

Each mutant removes or inverts exactly one guard in a copy of the script (the
file in the repository is never touched) and runs the tests that are meant to
notice. The run passes only when every mutant is KILLED (the tests fail) and the
unmutated script passes the same tests. A mutant that survives means a guard
that no test would miss.

    python3 tests/dashboard-only_mutants.py            # all
    python3 tests/dashboard-only_mutants.py M07 M12    # some

Not part of CI (about a minute per ten mutants); run it when the script changes.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "hermes-dashboard-setup.sh"
SUITE = ROOT / "tests" / "dashboard-only_test.py"

OPT = "OptionTests."
SRC = "SourceContractTests."
SET = "SetupTests."
SYS = "SystemdTests."
RET = "RetireGatewayExposureTests."
BRG = "RetireBridgeStillWorks."

# id, what the guard is, (old, new[, all]), tests that must fail
MUTANTS = [
    ("M01", "an unknown option stops the run",
     ('      echo "Run it with --help to see what it can do."\n      exit 2', '      echo "Run it with --help to see what it can do."\n      exit 0'),
     [OPT + "test_an_unknown_option_stops_before_anything_happens"]),
    ("M02", "two actions at once are refused",
     ('if [ -n "$ACTION_SET" ] && [ "$ACTION_SET" != "$_hermes_next" ]; then', "if false; then"),
     [OPT + "test_two_actions_at_once_are_refused_before_anything_happens"]),
    ("M03", "a password on the command line is refused",
     ('echo "to choose your own, or give none and one is generated."\n      exit 2', 'echo "to choose your own, or give none and one is generated."\n      exit 0'),
     [OPT + "test_a_password_cannot_be_given_on_the_command_line"]),
    ("M04", "--password-stdin does not go with a retire action",
     ('    if [ "$PASSWORD_STDIN" -eq 1 ]; then\n      echo "--password-stdin only goes with setup or --new-access."', '    if false; then\n      echo "--password-stdin only goes with setup or --new-access."'),
     [OPT + "test_a_password_option_with_a_retire_action_is_refused"]),
    ("M05", "a piped script cannot also read the password from stdin",
     ('  if [ ! -f "$0" ]; then', "  if false; then"),
     [OPT + "test_a_script_piped_into_sh_cannot_also_read_a_password_from_stdin"]),
    ("M06", "an empty password is refused",
     ("""  if [ -z "$(printf '%s' "$DASH_PASSWORD" | tr -d '[:space:]')" ]; then""", "  if false; then"),
     [SET + "test_an_empty_password_on_stdin_is_refused_before_anything_changes"]),
    ("M07", "WSL: no guessed address",
     ('      if [ -z "${HERMES_DASHBOARD_HOST:-}" ]; then\n        echo "WSL detected.', '      if false; then\n        echo "WSL detected.'),
     [SET + "test_a_wsl_address_is_not_guessed"]),
    ("M08", "HERMES_HOME may not be a symbolic link",
     ('  if [ -L "$candidate" ]; then', "  if false; then"),
     [SET + "test_a_hermes_home_that_is_not_a_plain_absolute_path_is_refused"]),
    ("M09", "HERMES_HOME must be absolute",
     ('*) echo "ERROR: HERMES_HOME must be an absolute path." >&2; return 1 ;;', "*) ;;"),
     [SET + "test_a_hermes_home_that_is_not_a_plain_absolute_path_is_refused"]),
    ("M10", "HERMES_HOME without characters a runner cannot carry",
     ("""grep -q '[[:cntrl:]\\\\$`"]'; then""", "grep -q 'NEVER-MATCHES-ANYTHING'; then", "all"),
     [SET + "test_a_hermes_home_that_is_not_a_plain_absolute_path_is_refused"]),
    ("M11", "a second Hermes home is not chosen over the existing one",
     ('hermes_home_has_evidence "$DEFAULT_HH"; then', "false; then"),
     [SET + "test_a_second_hermes_home_is_not_chosen_over_the_one_that_exists"]),
    ("M12", "a lock whose owner is alive refuses",
     ('       ! kill -0 "$lock_owner" 2>/dev/null; then', "       true; then"),
     [SET + "test_the_setup_lock_is_taken_and_released"]),
    ("M13", "a lock left by a dead run is taken over",
     ('    if [ -n "$lock_owner" ] && [ "$lock_try" -le 3 ] && \\', "    if false && \\"),
     [SET + "test_a_lock_left_by_a_dead_run_does_not_lock_anyone_out"]),
    ("M14", "a Dashboard unit of another home is refused (systemd)",
     ("      assert_systemd_unit_owner hermes-dashboard.service || return 1", "      true"),
     [SYS + "test_a_unit_of_another_home_is_refused_and_nothing_changes"]),
    ("M15", "a stale launchd definition next to systemd is refused",
     ('      [ ! -e "$DASH_PLIST" ] || {', "      true || {"),
     [SYS + "test_a_stale_launchd_definition_next_to_systemd_is_refused"]),
    ("M16", "a linked services/logs folder is refused",
     ('  if [ -L "$managed_dir" ]; then', "  if false; then"),
     [SET + "test_a_services_folder_that_is_a_link_is_refused"]),
    ("M17", "without Hermes it says so and creates nothing",
     ('if [ -z "$HB" ]; then', "if false; then"),
     [SET + "test_without_hermes_it_says_which_official_command_installs_it_and_creates_nothing"]),
    ("M18", "Hermes' libraries must run",
     ("""if ! HERMES_HOME="$HH" "$HP" -c 'import hermes_cli.config, plugins.dashboard_auth.basic' >/dev/null 2>&1; then""", "if false; then"),
     [SET + "test_a_hermes_whose_libraries_cannot_run_is_refused_untouched"]),
    ("M19", "only private/Tailscale addresses (public accepted)",
     ("raise SystemExit(0 if (private or cgnat or ula) and not ip.is_unspecified else 1)", "raise SystemExit(0)"),
     [SET + "test_only_a_lan_or_tailscale_address_may_be_chosen"]),
    ("M20", "loopback and link-local are not phone addresses",
     ("private = ip.version == 4 and ip.is_private and not ip.is_loopback and not ip.is_link_local", "private = ip.version == 4 and ip.is_private"),
     [SET + "test_only_a_lan_or_tailscale_address_may_be_chosen"]),
    ("M21", "0.0.0.0 is never an address",
     ("(private or cgnat or ula) and not ip.is_unspecified", "(private or cgnat or ula)"),
     [SET + "test_only_a_lan_or_tailscale_address_may_be_chosen"]),
    ("M22", "the port is a number",
     ("  *[!0-9]*|'') echo \"ERROR: HERMES_DASHBOARD_PORT must be a TCP port. Nothing was changed.\" >&2; exit 1 ;;", "  NEVER) exit 1 ;;"),
     [SET + "test_a_port_that_is_not_a_port_is_refused_before_anything_changes"]),
    ("M23", "the port is in range",
     ('if [ "$DASHBOARD_PORT" -lt 1 ] || [ "$DASHBOARD_PORT" -gt 65535 ]; then', "if false; then"),
     [SET + "test_a_port_that_is_not_a_port_is_refused_before_anything_changes"]),
    ("M24", "a port taken by something else is refused",
     ('if port_listening "$DASHBOARD_PORT" && ! dashboard_active; then', "if false; then"),
     [SET + "test_a_port_taken_by_something_else_is_refused_and_left_alone"]),
    ("M25", "a sign-in provider that exists is not touched",
     ('    if providers:\n        say("existing"', '    if False:\n        say("existing"'),
     [SET + "test_an_authentication_provider_that_is_already_there_is_not_touched",
      SET + "test_running_it_again_keeps_the_sign_in_and_shows_no_password"]),
    ("M26", "--new-access does not replace a pinned sign-in",
     ('    if pinned:\n        say("pinned"', '    if False:\n        say("pinned"'),
     [SET + "test_new_access_does_not_touch_a_sign_in_it_did_not_make"]),
    ("M27", "--new-access does not replace another provider",
     ('    if other:\n        say("other")', '    if False:\n        say("other")'),
     [SET + "test_new_access_leaves_another_provider_alone"]),
    ("M28", "the plaintext password is never stored",
     ('basic["password"] = ""  # never persist the plaintext', 'basic["password"] = password'),
     [SET + "test_a_hermes_without_a_sign_in_gets_the_dashboard_on_one_address_and_one_password"]),
    ("M29", "the hash is Hermes' own",
     ('basic["password_hash"] = hash_password(password)', 'basic["password_hash"] = password'),
     [SET + "test_a_hermes_without_a_sign_in_gets_the_dashboard_on_one_address_and_one_password"]),
    ("M30", "--new-access ends the old sessions",
     ('if action == "new-access" or not str(basic.get("secret") or "").strip():', 'if not str(basic.get("secret") or "").strip():'),
     [SET + "test_new_access_replaces_the_password_and_ends_old_sessions"]),
    ("M31", "the password is in no argument",
     ('login "$LOGIN_USER" || verify_status=$?', 'login "$LOGIN_USER" "${NEW_PASSWORD:-$DASH_PASSWORD}" || verify_status=$?'),
     [SET + "test_a_hermes_without_a_sign_in_gets_the_dashboard_on_one_address_and_one_password"]),
    ("M32", "a sign-in taken back when setup fails",
     ("rollback_dashboard_access() {\n  [ -n \"$TRANSACTION_DIR\" ] || return 0", "rollback_dashboard_access() {\n  return 0"),
     [SET + "test_a_setup_that_fails_gives_back_the_sign_in_that_was_there"]),
    ("M33", "files taken back when setup fails",
     ('    if ! restore_transaction_file "$key"; then rollback_failed=1; fi\n  done\n  if [ "$SERVICE_LIFECYCLE_TOUCHED" -eq 1 ]; then\n    case', '    true\n  done\n  if [ "$SERVICE_LIFECYCLE_TOUCHED" -eq 1 ]; then\n    case'),
     [SYS + "test_a_failed_start_puts_the_previous_unit_back",
      SET + "test_a_setup_that_fails_gives_back_the_sign_in_that_was_there"]),
    ("M34", "the new sign-in must really open the Dashboard",
     ('if mode == "login":', "if False:"),
     [SET + "test_a_setup_that_fails_gives_back_the_sign_in_that_was_there"]),
    ("M35", "the Dashboard must refuse whoever is not signed in",
     ('    if status not in (401, 403):\n        raise SystemExit("the Dashboard did not refuse', '    if False:\n        raise SystemExit("the Dashboard did not refuse'),
     [SET + "test_a_dashboard_that_does_not_protect_its_pages_is_not_accepted"]),
    ("M36", "the Dashboard listens on one address only",
     ('dashboard --host "$BIND_HOST" --port', 'dashboard --host 0.0.0.0 --port'),
     [SET + "test_a_hermes_without_a_sign_in_gets_the_dashboard_on_one_address_and_one_password"]),
    ("M37", "a process that is not the Dashboard is never signalled",
     ("if not recorded_start or not recorded_exe or start != recorded_start or exe != recorded_exe:", "if False:"),
     [SET + "test_a_dashboard_pid_that_is_now_another_process_is_never_signalled"]),
    ("M38", "the setup never touches the Gateway",
     ('echo "Gateway: not touched"', 'echo "Gateway: not touched"\nexport API_SERVER_HOST="$BIND_HOST"'),
     [SRC + "test_nothing_outside_the_retire_path_knows_the_api_server"]),
    ("M39", "a stale clear-text record goes with the new sign-in",
     ('  rm -f "$SERVICES/dashboard-login.json"', "  true"),
     [RET + "test_new_access_over_an_old_install_drops_its_clear_password_record"]),
    ("M40", "retire: a linked file is refused whole",
     ('    if [ -L "$guarded" ]; then', "    if false; then"),
     [RET + "test_a_drop_in_that_is_a_symbolic_link_is_refused_whole"]),
    ("M41", "retire: nothing to do without evidence",
     ('  if [ "$evidence" -eq 0 ]; then', "  if false; then"),
     [RET + "test_without_any_trace_nothing_is_created",
      RET + "test_a_key_without_the_old_setup_record_is_not_ours_and_stays"]),
    ("M42", "retire: a key without the old record is not ours",
     ('  [ "$has_pairing" -eq 0 ] || evidence=1\n', '  [ "$has_pairing" -eq 0 ] || evidence=1\n  ! grep -q "^API_SERVER_KEY=" "$env_file" 2>/dev/null || evidence=1\n'),
     [RET + "test_a_key_without_the_old_setup_record_is_not_ours_and_stays"]),
    ("M43", "retire: settings of the user in the drop-in stay",
     ("""if grep -qv '^[[:space:]]*\\(\\[Service\\]\\)\\{0,1\\}[[:space:]]*$' "$prepared/dropin"; then""", "if false; then"),
     [RET + "test_a_drop_in_with_settings_of_its_own_keeps_them"]),
    ("M44", "retire: every other line of .env stays",
     ("""awk '!/^API_SERVER_KEY=/' "$env_file" > "$prepared/env" """.rstrip(), """: > "$prepared/env" """.rstrip()),
     [RET + "test_the_key_goes_only_when_asked_and_a_private_copy_stays"]),
    ("M45", "retire: the removed key is kept privately",
     ('    chmod 600 "$backup"', '    chmod 644 "$backup"'),
     [RET + "test_the_key_goes_only_when_asked_and_a_private_copy_stays"]),
    ("M46", "retire: the Gateway is never restarted",
     ('  rm -f "$pairing"\n', '  rm -f "$pairing"\n  systemctl --user restart hermes-gateway >/dev/null 2>&1 || true\n'),
     [RET + "test_the_systemd_drop_in_goes_and_the_gateway_is_never_stopped"]),
    ("M47", "retire: the runner keeps everything but the address",
     ("""awk '!/^export API_SERVER_(HOST|PORT)=/' "$runner" > "$prepared/runner" """.rstrip(), """: > "$prepared/runner" """.rstrip()),
     [RET + "test_it_removes_what_the_old_script_added_and_leaves_the_running_gateway_alone"]),
    ("M48", "retire-bridge: a unit of another home is refused",
     ("    if ! assert_systemd_unit_owner hermes-bridge.service; then", "    if false; then"),
     [BRG + "test_a_bridge_unit_of_another_home_is_refused_whole"]),
    ("M49", "retire-bridge: a bridge that keeps running is not deleted",
     ("    if systemctl --user is-active --quiet hermes-bridge.service; then", "    if false; then"),
     [BRG + "test_a_bridge_that_keeps_running_is_not_deleted_under_itself"]),
    ("M50", "retire-bridge: a process that is not the bridge is left alone",
     ("    if not (same_start and runs_bridge):", "    if False:"),
     [BRG + "test_a_recorded_pid_that_is_now_something_else_is_left_running"]),
    ("M51", "retire-bridge: no service manager, no removal",
     ('    if [ "$SERVICE_MANAGER" != "systemd" ]; then\n      echo "ERROR: the Mobile Bridge service', '    if false; then\n      echo "ERROR: the Mobile Bridge service'),
     [BRG + "test_a_unit_without_its_service_manager_is_refused_whole"]),
    ("M52", "native Windows is refused, not half-run",
     ('    echo "setup yet, so nothing was changed. This setup covers Linux and macOS only."\n    exit 2',
      '    echo "setup yet, so nothing was changed. This setup covers Linux and macOS only."\n    exit 0'),
     [SRC + "test_native_windows_is_told_there_is_no_version_for_it_yet"]),
    # -- corrections after the independent review (REVIEW-B) -------------------
    ("M53", "--also-remove-api-key only goes with the gateway retire",
     ('if [ "$ALSO_REMOVE_KEY" -eq 1 ] && [ "$ACTION" != "retire-gateway-exposure" ]; then', "if false; then"),
     [OPT + "test_removing_the_api_key_is_an_option_of_the_gateway_retire_only"]),
    ("M54", "retire: the API key is kept unless asked to remove it (P1-1)",
     ('  if [ "$ALSO_REMOVE_KEY" -eq 1 ] && [ "$key_present" -eq 1 ]; then\n    removed_key=1',
      '  if [ "$key_present" -eq 1 ]; then\n    removed_key=1'),
     [RET + "test_a_key_that_was_already_there_before_the_old_setup_is_still_there_after",
      RET + "test_it_removes_what_the_old_script_added_and_leaves_the_running_gateway_alone"]),
    ("M55", "retire: asking for the key to go is enough on its own",
     ('  if [ "$ALSO_REMOVE_KEY" -eq 1 ] && [ "$key_present" -eq 1 ]; then\n    evidence=1',
      '  if false; then\n    evidence=1'),
     [RET + "test_the_key_can_be_removed_in_a_second_step_after_the_default_retire"]),
    ("M56", "retire: removing the key says what it costs",
     ('    echo "WARNING: without a usable API key Hermes does not start its API server. After the"',
      '    echo "Note: the key was removed. After the"'),
     [RET + "test_the_key_goes_only_when_asked_and_a_private_copy_stays"]),
    ("M57", "retire: a kept key is said to be kept",
     ('  elif [ "$key_present" -eq 1 ]; then', "  elif false; then"),
     [RET + "test_it_removes_what_the_old_script_added_and_leaves_the_running_gateway_alone"]),
    ("M58", "retire: no false promise that cron is not affected",
     ('  echo "and the rest of your .env were not changed."', '  echo "Telegram, cron and your other bots are not affected."'),
     [RET + "test_it_removes_what_the_old_script_added_and_leaves_the_running_gateway_alone"]),
    ("M59", "retire: the address and port leave the runner and the pairing record goes",
     ('  rm -f "$pairing"\n', '  true\n'),
     [RET + "test_a_key_that_was_already_there_before_the_old_setup_is_still_there_after"]),
]


def apply(source: str, mutant) -> str:
    _id, _what, change, _tests = mutant
    old, new = change[0], change[1]
    every = len(change) > 2 and change[2] == "all"
    found = source.count(old)
    if found == 0 or (found != 1 and not every):
        raise SystemExit(f"{_id}: the text to mutate occurs {found} times: {old[:70]!r}")
    return source.replace(old, new)


def run_suite(script: pathlib.Path, tests, timeout=300):
    return subprocess.run(
        [sys.executable, str(SUITE), *tests],
        capture_output=True, text=True, timeout=timeout,
        env={**os.environ, "DASHBOARD_ONLY_SCRIPT": str(script)},
    )


def main() -> int:
    wanted = set(sys.argv[1:])
    source = SCRIPT.read_text(encoding="utf-8")
    chosen = [m for m in MUTANTS if not wanted or m[0] in wanted]
    survivors = []
    with tempfile.TemporaryDirectory(prefix="hermes-mutants-") as raw:
        raw = pathlib.Path(raw)
        # The unmutated script, through the same copy mechanism, must pass.
        clean = raw / "clean.sh"
        clean.write_text(source, encoding="utf-8")
        needed = sorted({test for m in chosen for test in m[3]})
        baseline = run_suite(clean, needed)
        print(f"baseline ({len(needed)} tests, unmutated): {'PASS' if baseline.returncode == 0 else 'FAIL'}")
        if baseline.returncode != 0:
            print(baseline.stderr[-3000:])
            return 1
        for mutant in chosen:
            path = raw / f"{mutant[0]}.sh"
            path.write_text(apply(source, mutant), encoding="utf-8")
            result = run_suite(path, mutant[3])
            failed = [line.split(" (")[0].replace("FAIL: ", "").replace("ERROR: ", "")
                      for line in result.stderr.splitlines() if line.startswith(("FAIL:", "ERROR:"))]
            killed = result.returncode != 0
            print(f"{mutant[0]} {'KILLED  ' if killed else 'SURVIVED'} {mutant[1]}"
                  + (f"  [{', '.join(sorted(set(failed)))[:140]}]" if killed else ""))
            if not killed:
                survivors.append(mutant[0])
    print(f"{len(chosen) - len(survivors)}/{len(chosen)} mutants killed" + (f"; SURVIVED: {survivors}" if survivors else ""))
    return 1 if survivors else 0


if __name__ == "__main__":
    raise SystemExit(main())
