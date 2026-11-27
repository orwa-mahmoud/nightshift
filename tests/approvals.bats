#!/usr/bin/env bats
# Attribution: each plan keeps a record of who proposed it, who approved which revision, who started
# a run and who reviewed it. The record gates nothing: a team approves a plan by reviewing it in Git.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
RUNTIME="$PLUGIN/runtime"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

record() { bash "$RUNTIME/plan-record.sh" --project "$1" --plan "Export CSV" "${@:2}"; }

start_run() { # <workspace> <plan> [extra args]
  local w="$1" plan="$2"
  shift 2
  (cd "$w" && env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$w" \
    bash "$RUNTIME/start-run.sh" --project "$w" --plan "$plan" --host claude "$@")
}

set_rules() { # <workspace> <jq filter>
  jq "$2" "$1/.nightshift/rules.json" >"$1/.nightshift/team.tmp" && mv "$1/.nightshift/team.tmp" "$1/.nightshift/rules.json"
}

plan_file() { printf '%s/.nightshift/staging/plans/export-csv.md' "$1"; }

# shared_site <name> — the repository holds the site and shares it through the shipped ignore files.
# The runner's Git name is Carol.
shared_site() {
  local w="$BATS_TEST_TMPDIR/$1"
  add_repo "$BATS_TEST_TMPDIR" "$1"
  git -C "$w" config user.name Carol
  mkdir -p "$w/.nightshift/run" "$w/.nightshift/runs" "$w/.nightshift/staging/plans"
  printf '3\n' >"$w/.nightshift/state-version"
  cp "$RULES_TEMPLATE" "$w/.nightshift/rules.json"
  printf '%s\n' "$(cd -P "$w" && pwd)" >"$w/.nightshift/run/work-target"
  printf 'repository\n' >"$w/.nightshift/run/work-mode"
  printf '# Punch List — Export CSV\n\n## Contract\n\n- Work in the run.\n\n## Gates\n\n- `true`\n\n## Items\n\n- [ ] **1. Export the table.**\n  - Verify: true\n  - Commit: `feat: export`\n' \
    >"$(plan_file "$w")"
  share_through_git "$w"
  git -C "$w" add -A
  git -C "$w" commit -q -m "plan: export csv"
  printf '%s' "$(cd -P "$w" && pwd)"
}

@test "a solo owner proposes, approves and answers under their own name, and older lines read as unknown" {
  w="$(runs_site solo)"
  git -C "$w/repo" config user.name Sam
  run record "$w" --action proposed
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  rev="$(lib ns_plan_revision "$(plan_file "$w")")"
  [ "$output" = "ok record proposed by Sam at revision $rev" ]
  run record "$w" --action approved
  [ "$status" -eq 0 ]
  printf -- '- approved · 2026-11-01 09:00 (UTC+04:00) · revision aaaaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc\n' \
    >>"$w/.nightshift/staging/records/export-csv.md"
  run record "$w"
  [ "$status" -eq 0 ]
  [ "$output" = "revision $rev
record proposed by Sam at $rev
record approved by Sam at $rev
record approved by unknown at aaaaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc" ] || { echo "$output"; return 1; }
  # The older line is kept exactly as it was written.
  grep -qxF -- '- approved · 2026-11-01 09:00 (UTC+04:00) · revision aaaaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc' \
    "$w/.nightshift/staging/records/export-csv.md"
  # A parked decision answered under a name is answered; one answered before names were written too.
  mkdir -p "$w/.nightshift/runs/r/inbox"
  printf '# Parking Lot\n\n---\n\n- Which separator? · Default chosen: comma · answered by Sam: comma\n- Which encoding? · Default chosen: UTF-8 · answered: UTF-8\n- Which header? · Default chosen: none\n' \
    >"$w/.nightshift/runs/r/inbox/parking-lot.md"
  disp="$(bash -c '. "$1"; printf %s "$NS_REVIEW_DISPOSITIONS"' _ "$LIB")"
  [ "$(lib ns_open_entries "$w/.nightshift/runs/r/inbox/parking-lot.md" "$disp")" = '- Which header? · Default chosen: none' ]
  # A start is recorded under the runner's name.
  run start_run "$w" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'ok record started by Sam'
  tail -n 1 "$w/.nightshift/staging/records/export-csv.md" | grep -q '^- started · Sam · .* · run export-csv$'
}

@test "a teammate's approval is a record line, a plan starts without one, and a change shows a new revision" {
  w="$(shared_site team)"
  run record "$w" --action proposed --by Bob
  [ "$status" -eq 0 ]
  rev="$(lib ns_plan_revision "$(plan_file "$w")")"
  # Anyone may record an approval: the record says who did, Git review decides.
  run record "$w" --action approved --by Alice
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx "ok record approved by Alice at revision $rev"
  git -C "$w" add -A && git -C "$w" commit -q -m "approve: export csv"
  # A gate change after the approval is a new revision; the approval keeps naming the old one.
  sed -i.bak 's/^- `true`$/- `make test`/' "$(plan_file "$w")" && rm "$(plan_file "$w").bak"
  new="$(lib ns_plan_revision "$(plan_file "$w")")"
  [ "$new" != "$rev" ]
  run record "$w"
  [ "$output" = "revision $new
record proposed by Bob at $rev
record approved by Alice at $rev" ] || { echo "$output"; return 1; }
  # Nothing gates the start: the runner starts the plan as it stands.
  run start_run "$w" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'ok record started by Carol'
  tail -n 1 "$w/.nightshift/staging/records/export-csv.md" | grep -q "^- started · Carol · .* · revision $new · run "
}

@test "native Windows writes and reads the same record and starts the same plan" {
  command -v pwsh >/dev/null || skip 'pwsh is not installed'
  w="$(shared_site windows)"
  record "$w" --action proposed --by Bob >/dev/null
  ps_record() { pwsh -NoProfile -File "$RUNTIME/windows/plan-record.ps1" -Project "$w" -Plan "Export CSV" "$@"; }
  [ "$(record "$w")" = "$(ps_record)" ]
  run ps_record -Action approved -By Alice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(record "$w")" = "$(ps_record)" ]
  tail -n 1 "$w/.nightshift/staging/records/export-csv.md" | grep -q '^- approved · Alice · .* · revision '
  ps_start="$(cd "$w" && env -u NIGHTSHIFT_RUN pwsh -NoProfile -File "$RUNTIME/windows/start-run.ps1" -Project "$w" -Plan "Export CSV" -HostName claude)" ||
    { echo "$ps_start"; return 1; }
  printf '%s\n' "$ps_start" | grep -qx 'ok record started by Carol'
}
