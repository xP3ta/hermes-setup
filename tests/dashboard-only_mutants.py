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
WRP = "WrapperTests."
PWD = "PasswordShapeTests."
ADR = "RunnerAddressTests."
RMV = "RemoveTests."
RMS = "RemoveSystemdTests."
TXT = "SetupTextTests."
INS = "InstallIfMissingTests."
OLD = "OldInstallNoticeTests."

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
     [OPT + "test_a_password_option_with_a_retire_action_is_refused",
      RMV + "test_a_password_or_a_key_option_does_not_go_with_it"]),
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
    ("M17", "without Hermes and without an installer it says so and creates nothing",
     ('if [ -z "$HB" ]; then', "if false; then"),
     [SET + "test_without_hermes_and_without_a_working_installer_it_says_so_and_creates_nothing"]),
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
     ('dashboard --host "$2" --port', 'dashboard --host 0.0.0.0 --port'),
     [SET + "test_a_hermes_without_a_sign_in_gets_the_dashboard_on_one_address_and_one_password"]),
    ("M37", "a process that is not the Dashboard is never signalled",
     ("if not recorded_start or not recorded_exe or start != recorded_start or exe != recorded_exe:", "if False:"),
     [SET + "test_a_dashboard_pid_that_is_now_another_process_is_never_signalled"]),
    ("M38", "the setup never touches the Gateway",
     ('PORT="$DASHBOARD_PORT"\nLOG=', 'PORT="$DASHBOARD_PORT"\nexport API_SERVER_HOST="$PIN_HOST"\nLOG='),
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
    ("M52", "native Windows is sent to the PowerShell script, not half-run",
     ('    echo "was changed. On Windows run hermes-dashboard-setup.ps1 from Windows PowerShell 5.1 or newer."\n    exit 2',
      '    echo "was changed. On Windows run hermes-dashboard-setup.ps1 from Windows PowerShell 5.1 or newer."\n    exit 0'),
     [SRC + "test_native_windows_is_sent_to_the_powershell_script"]),
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
    ("M60", "a written-down sign-in that is only parked is not replaced (P2-1)",
     ('    if configured:\n        # The user', '    if False:\n        # The user'),
     [SET + "test_a_sign_in_that_is_written_down_but_parked_is_switched_on_not_replaced"]),
    ("M61", "a parked sign-in switched on is remembered for the rollback (P2-5)",
     ('        if reenabled:\n            remember({}, reenabled)\n            save_config(cfg)', '        if reenabled:\n            save_config(cfg)'),
     [SET + "test_a_parked_sign_in_comes_back_parked_when_setup_fails"]),
    ("M62", "the rollback parks the plugin again (P2-5)",
     ('    for name in parked:\n        if name not in disabled:\n            disabled.append(name)', '    for name in parked:\n        pass'),
     [SET + "test_a_parked_sign_in_comes_back_parked_when_setup_fails",
      SET + "test_a_plugin_this_run_switched_on_is_switched_off_again_when_setup_fails"]),
    ("M63", "a new sign-in remembers the plugin it switched on (P2-5)",
     ('remember(previous, enable_basic_plugin())', 'enable_basic_plugin()\nremember(previous, [])'),
     [SET + "test_a_plugin_this_run_switched_on_is_switched_off_again_when_setup_fails"]),
    ("M64", "the password file is private from the start (P2-3)",
     ('( umask 077; : > "$NEW_PASSWORD_FILE" ) || exit 1', ': > "$NEW_PASSWORD_FILE" || exit 1'),
     [SET + "test_the_password_file_is_private_from_the_start_and_gone_before_the_dashboard_starts"]),
    ("M65", "the password file is gone before the Dashboard starts (P2-3)",
     ('rm -f "$NEW_PASSWORD_FILE"\nif [ "$auth_status" -ne 0 ]; then', 'if [ "$auth_status" -ne 0 ]; then'),
     [SET + "test_the_password_file_is_private_from_the_start_and_gone_before_the_dashboard_starts"]),
    ("M66", "the password comes through the file, not standard output (P2-3)",
     ('    pathlib.Path(password_out).write_text(password, encoding="utf-8")', '    sys.stdout.write(password)'),
     [SET + "test_a_line_printed_while_hermes_loads_does_not_become_part_of_the_password"]),
    ("M67", "what Hermes prints while it loads is shown, not mixed into the answer (P2-3)",
     ('"$LOGIN_PW_FILE_FLAG" "$NEW_PASSWORD_FILE" 1>&2 || auth_status=$?', '"$LOGIN_PW_FILE_FLAG" "$NEW_PASSWORD_FILE" || auth_status=$?'),
     [SET + "test_a_line_printed_while_hermes_loads_does_not_become_part_of_the_password"]),
    ("M68", "the unit cannot end up failed for good on a slow network (P2-4)",
     ('Wants=network-online.target\nStartLimitIntervalSec=0\n[Service]', 'Wants=network-online.target\n[Service]\nStartLimitIntervalSec=0'),
     [SYS + "test_a_slow_network_cannot_leave_the_unit_failed_for_good"]),
    ("M69", "a clear password record that is kept is warned about at setup (P2-6)",
     ('if [ -f "$SERVICES/dashboard-login.json" ]; then\n  echo ""\n  echo "WARNING:', 'if false; then\n  echo ""\n  echo "WARNING:'),
     [SET + "test_a_clear_password_record_that_is_kept_is_warned_about_at_setup"]),
    ("M70", "external secret sources not being read is said (P2-2)",
     ('    echo "A sign-in kept only in an external secret source (a secret manager Hermes is set up"',
      '    echo "A sign-in kept only elsewhere (a secret manager Hermes is set up"'),
     [SET + "test_a_new_password_says_that_external_secret_sources_were_not_read"]),
    ("M71", "no GNU-only alternation in a basic regular expression (P2-7)",
     ("""grep -Eq '^export API_SERVER_(HOST|PORT)=' "$runner" """.rstrip(),
      """grep -q '^export API_SERVER_\\(HOST\\|PORT\\)=' "$runner" """.rstrip()),
     [SRC + "test_no_gnu_only_alternation_in_a_basic_regular_expression"]),
    # S2a: the one-function wrapper, the password, the runner address, --remove, the texts.
    ("M72", "a cut download runs nothing: the end marker is required",
     ('if [ "${_hermes_last:-}" != "--end-of-script" ]; then', "if false; then"),
     [WRP + "test_a_download_cut_anywhere_runs_nothing_and_changes_nothing"]),
    ("M73", "the password has no look-alike symbols",
     ('letters = "abcdefghijkmnpqrstuvwxyz23456789"', 'letters = "abcdefghijklmnopqrstuvwxyz234567"'),
     [PWD + "test_four_groups_of_five_without_look_alikes"]),
    ("M74", "the password is drawn with secrets",
     ('"".join(secrets.choice(letters) for _ in range(5))', '"".join(__import__("random").choice(letters) for _ in range(5))'),
     [PWD + "test_it_is_drawn_with_secrets_not_with_random"]),
    ("M75", "the runner does not carry the address found at setup",
     ('PIN="$PIN_HOST"', 'PIN="${BIND_HOST:-$PIN_HOST}"'),
     [ADR + "test_the_runner_does_not_carry_the_address_it_found_at_setup"]),
    ("M76", "an address chosen by hand stays chosen",
     ('if [ -n "$PIN" ]; then echo "chosen $PIN"; return 0; fi', 'if false; then echo "chosen $PIN"; return 0; fi'),
     [ADR + "test_an_address_chosen_by_hand_stays_chosen"]),
    ("M77", "Tailscale comes before the LAN",
     ('case "$found" in [0-9]*.[0-9]*.[0-9]*.[0-9]*) echo "mesh $found"; return 0 ;; esac', 'case "$found" in x) ;; esac'),
     [ADR + "test_it_follows_the_network_the_way_setup_chose_it"]),
    ("M78", "with no address yet the runner waits instead of ending",
     ('  [ -z "${2:-}" ] || break\n', '  break\n'),
     [ADR + "test_with_no_address_yet_it_waits_and_says_so_once"]),
    ("M79", "a changed address is logged",
     ('then say "address changed: $before -> $2"; fi', 'then :; fi'),
     [ADR + "test_a_changed_address_is_the_one_the_dashboard_starts_on_and_the_change_is_logged"]),
    ("M80", "--remove keeps the sign-in (config.yaml is not ours to change)",
     ('  echo "The Dashboard was stopped and its service removed."', '  rm -f "$HH/config.json"\n  echo "The Dashboard was stopped and its service removed."'),
     [RMV + "test_it_removes_the_service_and_keeps_the_sign_in_and_the_gateway"]),
    ("M81", "--remove stops the Dashboard before it deletes the service",
     ('"$remove_python" "$DASH_HELPER" stop "$DASHBOARD_RUNNER" "$SERVICES" "$LOGS" || remove_rc=$?', 'true'),
     [RMV + "test_it_removes_the_service_and_keeps_the_sign_in_and_the_gateway"]),
    ("M82", "--remove has nothing to do on a computer that never had the Dashboard",
     ('    if [ -e "$item" ] || [ -L "$item" ]; then found=1; fi', '    found=1'),
     [RMV + "test_a_computer_that_never_had_the_dashboard_gets_nothing_created"]),
    ("M83", "--remove takes the systemd unit away and reloads",
     ('      rm -f "$DASH_UNIT"\n      systemctl --user daemon-reload >/dev/null 2>&1 || true', '      systemctl --user daemon-reload >/dev/null 2>&1 || true'),
     [RMS + "test_the_unit_is_stopped_disabled_and_deleted"]),
    ("M85", "the first start says it can take minutes before it waits",
     ('echo "The first start can take a few minutes: Hermes builds its web pages once."', ':'),
     [TXT + "test_the_wait_is_announced_before_it_starts_and_the_end_speaks_console"]),
    ("M86", "the final text gives address, user and the Console steps",
     ('      echo "In Console: Type an address -> paste these three details."', '      :'),
     [TXT + "test_the_wait_is_announced_before_it_starts_and_the_end_speaks_console"]),
    ("M87", "who already had access is told how to get a new one",
     ('echo "Forgot it? Run this again with --new-access: it makes a new password and signs out"', 'echo "Forgot it? Ask for a new one: it makes a new password and signs out"'),
     [TXT + "test_who_already_had_access_is_told_in_plain_words_and_offered_new_access"]),
    ("M88", "the firewall line names the real network",
     ('  [ -n "$FIREWALL_NET" ] || FIREWALL_NET="<your network, in CIDR form>"\nfi', '  FIREWALL_NET="<your network>"\nfi'),
     [TXT + "test_an_active_firewall_gets_the_real_network_not_a_blank_to_fill"]),
    ("M89", "install always: the official installer runs even when Hermes is there",
     ('HB="$(find_hermes_launcher || true)"\nif [ -z "$HB" ]; then\n  if find_hermes_launcher seen; then', 'HB=""\nif [ -z "$HB" ]; then\n  if false; then'),
     [INS + "test_with_hermes_present_the_official_installer_is_never_fetched"]),
    ("M90", "the installer is not told to be non-interactive",
     ('OFFICIAL_INSTALL_FLAGS="--non-interactive --skip-browser', 'OFFICIAL_INSTALL_FLAGS="--skip-browser'),
     [INS + "test_without_hermes_the_official_installer_runs_once_with_the_exact_flags_and_setup_goes_on",
      SRC + "test_hermes_is_installed_only_with_the_official_installer_and_its_exact_flags"]),
    ("M91", "a launcher that does not answer is not repaired by the installer",
     ('  if find_hermes_launcher seen; then\n    echo "Hermes is installed under', '  if false; then\n    echo "Hermes is installed under'),
     [INS + "test_a_launcher_that_does_not_answer_is_never_fixed_by_running_the_installer"]),
    ("M92", "a Hermes elsewhere on PATH stops the setup",
     ('  if [ -n "$hermes_elsewhere" ]; then', '  if false; then'),
     [INS + "test_a_hermes_outside_the_standard_place_stops_the_setup_without_installing"]),
    ("M93", "an installation that put nothing in place is not noticed",
     ('  if [ -z "$HB" ] || [ "$install_rc" -ne 0 ]; then', '  if false; then'),
     [INS + "test_an_installer_that_fails_or_installs_nothing_ends_with_nothing_changed"]),
    ("M94", "an installer that failed is trusted if Hermes appeared",
     ('  if [ -z "$HB" ] || [ "$install_rc" -ne 0 ]; then', '  if [ -z "$HB" ]; then'),
     [INS + "test_an_installer_that_fails_or_installs_nothing_ends_with_nothing_changed"]),
    ("M95", "the installer is fetched without the curl failure flag",
     ('curl -fsSL "$OFFICIAL_INSTALL_URL"', 'curl -sS "$OFFICIAL_INSTALL_URL"'),
     [INS + "test_an_installer_that_fails_or_installs_nothing_ends_with_nothing_changed"]),
    ("M96", "an exposed Gateway is not reported",
     ('if gateway_exposure_present; then old_gateway=1; fi', 'if false; then old_gateway=1; fi'),
     [OLD + "test_an_exposed_gateway_is_reported_with_the_command_and_left_alone",
      OLD + "test_a_pairing_record_alone_counts_as_exposure"]),
    ("M97", "the old Bridge is not reported",
     ('if [ -n "$(bridge_leftovers)" ]; then old_bridge=1; fi', 'if false; then old_bridge=1; fi'),
     [OLD + "test_the_old_bridge_is_reported_with_its_command_and_left_alone"]),
    ("M98", "a pairing record alone is not exposure",
     ('  [ ! -f "$HH/console-services/pairing.env" ] || return 0\n  return 1', '  return 1'),
     [OLD + "test_a_pairing_record_alone_counts_as_exposure"]),
    ("M99", "setup retires the old Bridge by itself",
     ('if [ "$old_gateway" -eq 1 ] || [ "$old_bridge" -eq 1 ]; then\n  echo ""', 'if [ "$old_bridge" -eq 1 ]; then rm -f "$HH/hermes_bridge.py"; fi\nif [ "$old_gateway" -eq 1 ] || [ "$old_bridge" -eq 1 ]; then\n  echo ""'),
     [OLD + "test_the_old_bridge_is_reported_with_its_command_and_left_alone"]),
    ("M100", "setup retires the Gateway exposure by itself",
     ('if [ "$old_gateway" -eq 1 ] || [ "$old_bridge" -eq 1 ]; then\n  echo ""', 'if [ "$old_gateway" -eq 1 ]; then rm -f "$HH/console-services/hermes-gateway.sh"; fi\nif [ "$old_gateway" -eq 1 ] || [ "$old_bridge" -eq 1 ]; then\n  echo ""'),
     [OLD + "test_an_exposed_gateway_is_reported_with_the_command_and_left_alone"]),
    ("M101", "a clean computer gets a notice",
     ('if [ "$old_gateway" -eq 1 ] || [ "$old_bridge" -eq 1 ]; then\n  echo ""', 'if true; then\n  echo ""'),
     [OLD + "test_a_clean_computer_gets_no_notice"]),
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
