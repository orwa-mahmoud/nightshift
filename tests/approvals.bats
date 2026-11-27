#!/usr/bin/env bats
# Attribution and approval: each plan keeps a record of who proposed it, who approved which revision,
# who started a run and who reviewed it. A team whose rules name approvers runs only an approved
# revision, and on a site that shares its plans the runner consents to exactly what a run executes
# before anything of it runs.

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

# shared_site <name> — the repository holds the site and shares plans, decisions and rules; the
# team needs a lead's approval for contract and gate changes. Alice is the lead, Bob a developer.
shared_site() {
  local w="$BATS_TEST_TMPDIR/$1"
  add_repo "$BATS_TEST_TMPDIR" "$1"
  git -C "$w" config user.name Carol
  mkdir -p "$w/.nightshift/run" "$w/.nightshift/runs" "$w/.nightshift/staging/plans"
  printf '3\n' >"$w/.nightshift/state-version"
  jq '.sharing.records = ["plans", "decisions", "rules"] | .team.roles = {"Alice": "lead", "Bob": "developer"}
      | .team.approvers = ["lead"] | .team.reviewChanges = ["contract", "gates"]' \
    "$RULES_TEMPLATE" >"$w/.nightshift/rules.json"
  printf '%s\n' "$(cd -P "$w" && pwd)" >"$w/.nightshift/run/work-target"
  printf 'repository\n' >"$w/.nightshift/run/work-mode"
  printf '# Punch List — Export CSV\n\n## Contract\n\n- Work in the run.\n\n## Gates\n\n- `true`\n\n## Items\n\n- [ ] **1. Export the table.**\n  - Verify: true\n  - Commit: `feat: export`\n' \
    >"$(plan_file "$w")"
  bash "$RUNTIME/share.sh" --project "$w" --apply >/dev/null
  git -C "$w" add -A
  git -C "$w" commit -q -m "plan: export csv"
  printf '%s' "$(cd -P "$w" && pwd)"
}

consent_of() { printf '%s\n' "$1" | sed -n 's/^repair read those inputs, then run this again with --consent //p'; }

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

@test "a developer proposes, only the lead's approval runs, and a gate change returns the plan to proposed" {
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
  # An item change is not one this team reviews.
  printf -- '- [ ] **2. Document the export.**\n  - Verify: true\n  - Commit: `docs: export`\n' >>"$(plan_file "$w")"
  run record "$w"
  printf '%s\n' "$output" | grep -qx 'state approved'
  # A gate change is: the plan is proposed again until the lead approves this revision.
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

@test "a lead may submit an approved plan directly when the team allows it, and a developer may not" {
  w="$(shared_site self)"
  set_rules "$w" '.team.approvers = ["reviewer"] | .team.selfApprove = ["lead"]'
  record "$w" --action proposed --by Alice >/dev/null
  run record "$w" --action approved --by Alice
  [ "$status" -eq 0 ]
  run record "$w"
  printf '%s\n' "$output" | grep -qx 'state approved'
  record "$w" --action proposed --by Bob >/dev/null
  run record "$w" --action approved --by Bob
  [ "$status" -eq 1 ]
  # Bob proposing the same revision again leaves Alice's approval of her own proposal standing.
  run record "$w"
  printf '%s\n' "$output" | grep -qx 'state approved'
  printf '%s\n' "$output" | grep -q '^approved-by Alice '
}

@test "a runner consents to exactly what a run executes, and nothing runs before" {
  w="$(shared_site consent)"
  set_rules "$w" '.team.approvers = [] | .baselineGates = true | .team.memberSettings = ["shift.prepare"]'
  sed -i.bak "s|^- \`true\`\$|- \`touch $BATS_TEST_TMPDIR/gate-ran\`|" "$(plan_file "$w")" && rm "$(plan_file "$w").bak"
  run start_run "$w" "Export CSV"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'refuse consent read what this run would execute before it starts'
  printf '%s\n' "$output" | grep -qx "input gate touch $BATS_TEST_TMPDIR/gate-ran"
  printf '%s\n' "$output" | grep -qx 'input baseline-gates true'
  consent="$(consent_of "$output")"
  [ -n "$consent" ]
  [ ! -e "$BATS_TEST_TMPDIR/gate-ran" ]
  [ -z "$(ls -A "$w/.nightshift/runs")" ]
  # A member's settings that change the prepare command change the consent.
  mkdir -p "$w/.nightshift/settings"
  printf '{\n  "shift": {\n    "prepare": "npm ci"\n  }\n}\n' >"$w/.nightshift/settings/carol.json"
  run start_run "$w" "Export CSV" --settings carol --consent "$consent"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx "refuse consent what this run would execute changed since consent $consent was given"
  printf '%s\n' "$output" | grep -qx 'input prepare npm ci'
  [ ! -e "$BATS_TEST_TMPDIR/gate-ran" ]
  # With the consent for these inputs, the run starts and its gate runs once, as approved.
  run start_run "$w" "Export CSV" --consent "$consent"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx "ok consent $consent covers what this run executes"
  [ -e "$BATS_TEST_TMPDIR/gate-ran" ]
  tail -n 1 "$w/.nightshift/staging/records/export-csv.md" | grep -q "^- started · Carol · - · .* · inputs $consent\$"
  # A changed gate after the runner reviewed it needs fresh consent.
  sed -i.bak 's|gate-ran`$|gate-ran-again`|' "$(plan_file "$w")" && rm "$(plan_file "$w").bak"
  run start_run "$w" "Export CSV" --consent "$consent"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx "refuse consent what this run would execute changed since consent $consent was given"
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
  set_rules "$w" '.team.approvers = ["lead"]'
  bash_start="$(start_run "$w" "Export CSV")" || :
  ps_start="$(cd "$w" && env -u NIGHTSHIFT_RUN pwsh -NoProfile -File "$RUNTIME/windows/start-run.ps1" -Project "$w" -Plan "Export CSV" -HostName claude)" || :
  [ "$bash_start" = "$ps_start" ] || { printf 'bash:\n%s\npwsh:\n%s\n' "$bash_start" "$ps_start"; return 1; }
  printf '%s\n' "$bash_start" | grep -q '^refuse consent '
}
