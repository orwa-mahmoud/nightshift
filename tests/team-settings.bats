#!/usr/bin/env bats
# Team rules and member settings: the team's rules.json holds the shared defaults; a member may keep
# a settings file in Git with just their overrides and select it for one run. The reader lays the
# run's own file over the member's over the team's.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
RUNTIME="$PLUGIN/runtime"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

start_run() { # <workspace> <plan> [extra args]
  local w="$1" plan="$2"
  shift 2
  (cd "$w" && env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$w" \
    bash "$RUNTIME/start-run.sh" --project "$w" --plan "$plan" --host claude "$@")
}

# setting <workspace> <run> <block> <key> — the effective value one run reads.
setting() { NIGHTSHIFT_RUN="$2" lib ns_rules_get_in "$1/.nightshift/rules.json" "$3" "$4"; }

# team_site <name> — a run-folder site with team defaults and two members' settings files.
team_site() {
  local w
  w="$(runs_site "$1")"
  jq '.shift.hours = 2 | .receipts.progressMinutes = 20' \
    "$w/.nightshift/rules.json" >"$w/.nightshift/team.tmp"
  mv "$w/.nightshift/team.tmp" "$w/.nightshift/rules.json"
  mkdir -p "$w/.nightshift/settings"
  printf '{\n  "shift": {\n    "hours": 3\n  },\n  "receipts": {\n    "progressMinutes": 5\n  }\n}\n' >"$w/.nightshift/settings/alice.json"
  printf '{\n  "shift": {\n    "hours": 6\n  }\n}\n' >"$w/.nightshift/settings/bob.json"
  printf '%s' "$w"
}

@test "a selected member file sets the run's values; an unselected one and a run with none use the team's" {
  w="$(team_site select)"
  run start_run "$w" "Export CSV" --settings alice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx "ok settings settings/alice.json over the team's rules.json, for this run"
  run start_run "$w" "Dark mode"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! printf '%s\n' "$output" | grep -q '^ok settings ' || false
  [ "$(setting "$w" export-csv shift hours)" = 3 ]
  [ "$(setting "$w" export-csv receipts progressMinutes)" = 5 ]
  [ "$(setting "$w" dark-mode shift hours)" = 2 ]
  [ "$(setting "$w" dark-mode receipts progressMinutes)" = 20 ]
  # The run's snapshot carries its effective values, so its helpers read them too.
  [ "$(jq -r .shift.hours "$w/.nightshift/runs/export-csv/run/shift-policy.json")" = 3 ]
  [ "$(jq -r .shift.hours "$w/.nightshift/runs/dark-mode/run/shift-policy.json")" = 2 ]
  # The selection is the runner's: it sits with the run's private files, not in a shared record.
  [ "$(cat "$w/.nightshift/runs/export-csv/run/member-settings")" = alice ]
  # The run's own file is narrowest.
  printf '{\n  "shift": {\n    "isolation": "worktree",\n    "hours": 4\n  }\n}\n' >"$w/.nightshift/runs/export-csv/rules.json"
  [ "$(setting "$w" export-csv shift hours)" = 4 ]
  [ "$(setting "$w" export-csv receipts progressMinutes)" = 5 ]
}

@test "a member file may change any setting, and one the reader cannot read is refused before launch" {
  w="$(team_site refuse)"
  printf '{\n  "watchMinutes": 0,\n  "shift": {\n    "hours": 6\n' >"$w/.nightshift/settings/eve.json"
  run start_run "$w" "Export CSV" --settings eve
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | sed -n 1p | grep -qx 'refuse settings eve cannot be selected for this run' || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -q '^explain settings/eve.json: '
  printf '%s\n' "$output" | grep -qx 'repair fix the file, then run this again'
  # Nothing was placed: no run folder, the plan still staged.
  [ -z "$(ls -A "$w/.nightshift/runs")" ]
  [ -f "$w/.nightshift/staging/plans/export-csv.md" ]
  run start_run "$w" "Export CSV" --settings missing
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'explain settings/missing.json is not there'
  run start_run "$w" "Export CSV" --settings ../alice
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'explain the name ../alice is not a settings name: lowercase letters, digits and hyphens'
  # Any other setting is the member's to change.
  printf '{\n  "watchMinutes": 0,\n  "receipts": {\n    "progressMinutes": 7\n  }\n}\n' >"$w/.nightshift/settings/mallory.json"
  run start_run "$w" "Export CSV" --settings mallory
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(setting "$w" export-csv watchMinutes "")" = 0 ]
  [ "$(setting "$w" export-csv receipts progressMinutes)" = 7 ]
}

@test "a selection edited into a file the reader cannot read is refused at the next Start" {
  w="$(team_site edited)"
  run start_run "$w" "Export CSV" --settings alice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # The member's file is edited in Git after the run selected it.
  printf '{\n  "shift": {\n    "hours": 3\n' >"$w/.nightshift/settings/alice.json"
  run env NIGHTSHIFT_RUN=export-csv bash "$RUNTIME/start-preflight.sh" --project "$w" --host claude
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  # The selection is read with the rules, so the refusal names the member's file.
  printf '%s\n' "$output" | grep -q '^refuse rules .*: settings/alice.json: truncated JSON$' || { echo "$output"; return 1; }
}

@test "a run whose selected file is gone fails closed, and a second selection is refused" {
  w="$(team_site gone)"
  run start_run "$w" "Export CSV" --settings alice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run start_run "$w" "Export CSV" --settings bob
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'refuse settings run export-csv already uses settings/alice.json'
  rm "$w/.nightshift/settings/alice.json"
  [ -z "$(setting "$w" export-csv shift hours)" ]
  NIGHTSHIFT_RUN=export-csv run lib ns_rules_check "$w"
  [ "$status" -eq 1 ] || { echo "status=$status $output"; return 1; }
  [ "$output" = 'settings/alice.json is selected for run export-csv but is not there' ]
}

@test "native Windows resolves the same layers and refuses the same files" {
  command -v pwsh >/dev/null || skip 'pwsh is not installed'
  w="$(team_site windows)"
  run start_run "$w" "Export CSV" --settings alice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '{\n  "shift": {\n    "isolation": "worktree"\n  }\n}\n' >"$w/.nightshift/runs/export-csv/rules.json"
  values="$(NIGHTSHIFT_RUN=export-csv pwsh -NoProfile -Command "Import-Module '$PLUGIN/lib/Nightshift.psm1' -Force -DisableNameChecking
    \$r = Get-NSRulesObject '$w'
    [Console]::Out.Write([string]\$r.shift.hours + ' ' + [string]\$r.receipts.progressMinutes)")"
  [ "$values" = '3 5' ] || { echo "$values"; return 1; }
  # A file neither runtime can read is refused by both, with the same refusal and repair.
  printf '{\n  "watchMinutes": 0,\n' >"$w/.nightshift/settings/eve.json"
  bash_out="$(start_run "$w" "Dark mode" --settings eve)" && { echo "bash started: $bash_out"; return 1; }
  ps_out="$(cd "$w" && env -u NIGHTSHIFT_RUN pwsh -NoProfile -File "$RUNTIME/windows/start-run.ps1" -Project "$w" -Plan "Dark mode" -HostName claude -Settings eve)" &&
    { echo "pwsh started: $ps_out"; return 1; }
  [ "$(printf '%s\n' "$bash_out" | grep -v '^explain ')" = "$(printf '%s\n' "$ps_out" | grep -v '^explain ')" ] ||
    { printf 'bash:\n%s\npwsh:\n%s\n' "$bash_out" "$ps_out"; return 1; }
}
