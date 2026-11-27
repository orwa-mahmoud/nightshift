#!/usr/bin/env bats
# Attribution and approval: each plan keeps a record of who proposed it, who approved which revision,
# who started a run and who reviewed it. A team whose rules name approvers runs only an approved
# revision, and any change to the plan needs approval again.

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

# shared_site <name> — the repository holds the site and shares it through the shipped ignore files;
# the team needs a lead's approval. Alice is the lead, Bob a developer.
shared_site() {
  local w="$BATS_TEST_TMPDIR/$1"
  add_repo "$BATS_TEST_TMPDIR" "$1"
  git -C "$w" config user.name Carol
  mkdir -p "$w/.nightshift/run" "$w/.nightshift/runs" "$w/.nightshift/staging/plans"
  printf '3\n' >"$w/.nightshift/state-version"
  jq '.team.roles = {"Alice": "lead", "Bob": "developer"} | .team.approvers = ["lead"]' \
    "$RULES_TEMPLATE" >"$w/.nightshift/rules.json"
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
approval not-required
state approved
approved-by Sam $rev
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
  # Solo, no approval is required and a start is recorded under the runner's name.
  run start_run "$w" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'ok record started by Sam'
  tail -n 1 "$w/.nightshift/staging/records/export-csv.md" | grep -q '^- started · Sam · - · .* · run export-csv$'
}

@test "a developer proposes, only the lead's approval runs, and a change returns the plan to proposed" {
  w="$(shared_site leads)"
  run record "$w" --action proposed --by Bob
  [ "$status" -eq 0 ]
  run start_run "$w" "Export CSV"
  [ "$status" -eq 1 ]
  rev="$(lib ns_plan_revision "$(plan_file "$w")")"
  printf '%s\n' "$output" | grep -qx "refuse approval Export CSV revision $rev is proposed: no approver has approved it"
  [ -z "$(ls -A "$w/.nightshift/runs")" ]
  run record "$w" --action approved --by Bob
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'refuse approve Bob (developer) may not approve this plan; the team'"'"'s approvers are lead'
  run record "$w" --action approved --by Alice
  [ "$status" -eq 0 ]
  git -C "$w" add -A && git -C "$w" commit -q -m "approve: export csv"
  # Ticking a box changes nothing; a gate change returns the plan to proposed until the lead
  # approves this revision.
  sed -i.bak 's/^- \[ \] \*\*1\./- [x] **1./' "$(plan_file "$w")" && rm "$(plan_file "$w").bak"
  run record "$w"
  printf '%s\n' "$output" | grep -qx 'state approved'
  sed -i.bak 's/^- `true`$/- `make test`/' "$(plan_file "$w")" && rm "$(plan_file "$w").bak"
  run start_run "$w" "Export CSV"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q "^refuse approval Export CSV changed its gates since Alice approved revision $rev, so revision "
  git -C "$w" add -A && git -C "$w" commit -q -m "plan: gate"
  run record "$w" --action approved --by Alice
  [ "$status" -eq 0 ]
  git -C "$w" add -A && git -C "$w" commit -q -m "approve: gate"
  # The earlier approval stays in the record and in Git.
  [ "$(grep -c '^- approved · Alice · lead · ' "$w/.nightshift/staging/records/export-csv.md")" = 2 ]
  git -C "$w" show HEAD~2:.nightshift/staging/records/export-csv.md | grep -q "^- approved · Alice · lead · .* · revision $rev\$"
  run record "$w"
  printf '%s\n' "$output" | grep -qx 'state approved'
}

@test "an approver approves their own plan, a developer may not, and an item change needs approval again" {
  w="$(shared_site self)"
  record "$w" --action proposed --by Alice >/dev/null
  run record "$w" --action approved --by Alice
  [ "$status" -eq 0 ]
  run record "$w"
  printf '%s\n' "$output" | grep -qx 'state approved'
  run record "$w" --action approved --by Bob
  [ "$status" -eq 1 ]
  printf -- '- [ ] **2. Document the export.**\n  - Verify: true\n  - Commit: `docs: export`\n' >>"$(plan_file "$w")"
  run record "$w"
  printf '%s\n' "$output" | grep -qx 'state proposed'
  printf '%s\n' "$output" | grep -qx 'changed items'
}

@test "native Windows keeps the same record and refuses the same starts" {
  command -v pwsh >/dev/null || skip 'pwsh is not installed'
  w="$(shared_site windows)"
  record "$w" --action proposed --by Bob >/dev/null
  ps_record() { pwsh -NoProfile -File "$RUNTIME/windows/plan-record.ps1" -Project "$w" -Plan "Export CSV" "$@"; }
  [ "$(record "$w")" = "$(ps_record)" ]
  bash_start="$(start_run "$w" "Export CSV")" || :
  ps_start="$(cd "$w" && env -u NIGHTSHIFT_RUN pwsh -NoProfile -File "$RUNTIME/windows/start-run.ps1" -Project "$w" -Plan "Export CSV" -HostName claude)" || :
  [ "$bash_start" = "$ps_start" ] || { printf 'bash:\n%s\npwsh:\n%s\n' "$bash_start" "$ps_start"; return 1; }
  run ps_record -Action approved -By Bob
  [ "$status" -eq 1 ]
  run ps_record -Action approved -By Alice
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(record "$w")" = "$(ps_record)" ]
}
