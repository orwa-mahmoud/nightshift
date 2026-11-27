#!/usr/bin/env bats
# Team rules and member settings: the team's rules.json holds the shared defaults, the roles and the
# approval policy; a member may keep a settings file in Git with just their overrides and select it
# for one run. The reader lays the run's own file over the member's over the team's, and a member's
# file changes only what the team allows.

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

# team_site <name> — a run-folder site whose team lets a member change shift.hours and
# receipts.progressMinutes, needs a lead's approval, and has two members' settings files.
team_site() {
  local w
  w="$(runs_site "$1")"
  jq '.team.roles = {"Alice": "lead", "Bob": "developer"} | .team.approvers = ["lead"]
      | .team.reviewChanges = ["contract", "gates"]
      | .team.memberSettings = ["shift.hours", "receipts.progressMinutes"]
      | .shift.hours = 2 | .receipts.progressMinutes = 20' \
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
  ! printf '%s\n' "$output" | grep -q '^ok settings '
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

@test "a member file that relaxes a required approval or changes a kept setting is refused before launch" {
  w="$(team_site refuse)"
  printf '{\n  "team": {\n    "approvers": []\n  },\n  "watchMinutes": 0\n}\n' >"$w/.nightshift/settings/eve.json"
  run start_run "$w" "Export CSV" --settings eve
  [ "$status" -eq 1 ]
  [ "$output" = "refuse settings eve cannot be selected for this run
explain settings/eve.json changes team.approvers, which only the team's rules.json sets
explain settings/eve.json changes watchMinutes, which the team does not let a member change
repair take those settings out of the file, or ask the team to allow them in team.memberSettings, then run this again" ] || { echo "$output"; return 1; }
  # Nothing was placed: no run folder, the plan still staged.
  [ -z "$(ls -A "$w/.nightshift/runs")" ]
  [ -f "$w/.nightshift/staging/plans/export-csv.md" ]
  run start_run "$w" "Export CSV" --settings missing
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'explain settings/missing.json is not there'
  run start_run "$w" "Export CSV" --settings ../alice
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'explain the name ../alice is not a settings name: lowercase letters, digits and hyphens'
}

@test "neither a run's file nor a member's changes the team's own rules, and an edited selection is refused at the next Start" {
  w="$(team_site owned)"
  run start_run "$w" "Export CSV" --settings alice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '{\n  "shift": {\n    "isolation": "worktree"\n  },\n  "team": {\n    "approvers": []\n  },\n  "sharing": {\n    "records": ["plans"]\n  }\n}\n' \
    >"$w/.nightshift/runs/export-csv/rules.json"
  [ "$(setting "$w" export-csv team approvers)" = '["lead"]' ]
  [ "$(setting "$w" export-csv sharing records)" = '[]' ]
  # The member's file gains a setting the team keeps after the run selected it.
  printf '{\n  "shift": {\n    "hours": 3\n  },\n  "team": {\n    "approvers": []\n  }\n}\n' >"$w/.nightshift/settings/alice.json"
  [ "$(setting "$w" export-csv team approvers)" = '["lead"]' ]
  [ "$(setting "$w" export-csv shift hours)" = 3 ]
  run env NIGHTSHIFT_RUN=export-csv bash "$RUNTIME/start-preflight.sh" --project "$w" --host claude
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'refuse settings alice cannot be used for this run'
  printf '%s\n' "$output" | grep -qx "explain settings/alice.json changes team.approvers, which only the team's rules.json sets"
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
  printf '{\n  "shift": {\n    "isolation": "worktree"\n  },\n  "team": {\n    "approvers": []\n  }\n}\n' \
    >"$w/.nightshift/runs/export-csv/rules.json"
  values="$(NIGHTSHIFT_RUN=export-csv pwsh -NoProfile -Command "Import-Module '$PLUGIN/lib/Nightshift.psm1' -Force -DisableNameChecking
    \$r = Get-NSRulesObject '$w'
    [Console]::Out.Write([string]\$r.shift.hours + ' ' + [string]\$r.receipts.progressMinutes + ' ' + (@(\$r.team.approvers) -join ','))")"
  [ "$values" = '3 5 lead' ] || { echo "$values"; return 1; }
  printf '{\n  "team": {\n    "approvers": []\n  },\n  "watchMinutes": 0\n}\n' >"$w/.nightshift/settings/eve.json"
  bash_out="$(start_run "$w" "Dark mode" --settings eve)" || :
  ps_out="$(cd "$w" && env -u NIGHTSHIFT_RUN pwsh -NoProfile -File "$RUNTIME/windows/start-run.ps1" -Project "$w" -Plan "Dark mode" -HostName claude -Settings eve)" || :
  [ "$bash_out" = "$ps_out" ] || { printf 'bash:\n%s\npwsh:\n%s\n' "$bash_out" "$ps_out"; return 1; }
}
