#!/usr/bin/env bats
# Shared project records: a team keeps plans, decisions, rules, receipts and filed shifts in Git
# through .nightshift/ inside the repository. ns share lets Git see exactly what sharing.records
# names; each runner's private files stay ignored; teammates' runs never meet in one folder.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
RUNTIME="$PLUGIN/runtime"
THREAD_HEAD="$PLUGIN/skills/nightshift/references/templates/plan-record.md"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

share() { bash "$RUNTIME/share.sh" --project "$1" "${@:2}"; }

start_run_as_is() { # <workspace> <plan> [extra args]
  local w="$1" plan="$2"
  shift 2
  (cd "$w" && env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$w" \
    bash "$RUNTIME/start-run.sh" --project "$w" --plan "$plan" --host claude "$@")
}

# start_run <workspace> <plan> — a runner on a shared site reads what the run would execute and
# consents to exactly that, then starts it.
start_run() {
  local out consent
  if out="$(start_run_as_is "$1" "$2")"; then
    printf '%s\n' "$out"
    return 0
  fi
  consent="$(printf '%s\n' "$out" | sed -n 's/^repair read those inputs, then run this again with --consent //p')"
  [ -n "$consent" ] || { printf '%s\n' "$out"; return 1; }
  start_run_as_is "$1" "$2" --consent "$consent"
}

commit_all() { # <repo> <message>
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

# local_site <repo> — what Setup writes on each runner's machine: the work target and mode, which
# Git never carries.
local_site() {
  mkdir -p "$1/.nightshift/run"
  printf '%s\n' "$(cd -P "$1" && pwd)" >"$1/.nightshift/run/work-target"
  printf 'repository\n' >"$1/.nightshift/run/work-mode"
}

# team <name> [records-json] — a bare remote and the first member's clone with the site inside the
# repository, sharing every record (or the given ones), pushed. Prints the clone's path.
team() {
  local root="$BATS_TEST_TMPDIR/$1" a records="${2:-[\"plans\",\"decisions\",\"rules\",\"receipts\",\"summaries\"]}"
  git init -q --bare "$root/remote.git"
  a="$root/alice"
  git clone -q "$root/remote.git" "$a" 2>/dev/null
  git -C "$a" symbolic-ref HEAD refs/heads/main
  git -C "$a" config user.email alice@example.com
  git -C "$a" config user.name alice
  printf 'app\n' >"$a/app.txt"
  printf '.nightshift/\n' >"$a/.gitignore"
  mkdir -p "$a/.nightshift/staging/plans" "$a/.nightshift/staging/decisions"
  printf '3\n' >"$a/.nightshift/state-version"
  jq --argjson r "$records" '.sharing.records = $r' "$RULES_TEMPLATE" >"$a/.nightshift/rules.json"
  printf '# Punch List — Export CSV\n\n## Contract\n\n- Work in the run; receipts go in `$NS/receipts/`.\n\n## Gates\n\n## Items\n\n- [ ] **1. Export the table.**\n  - Verify: true\n  - Commit: `feat: export`\n' \
    >"$a/.nightshift/staging/plans/export-csv.md"
  local_site "$a"
  share "$a" --apply >/dev/null
  commit_all "$a" "plan: export csv"
  git -C "$a" push -q -u origin main 2>/dev/null
  printf '%s' "$(cd -P "$a" && pwd)"
}

# member <team-dir> <name> — another member's clone of the same remote, set up on their machine.
member() {
  local m="$BATS_TEST_TMPDIR/$1/$2"
  git clone -q -b main "$BATS_TEST_TMPDIR/$1/remote.git" "$m" 2>/dev/null
  git -C "$m" config user.email "$2@example.com"
  git -C "$m" config user.name "$2"
  local_site "$m"
  printf '%s' "$(cd -P "$m" && pwd)"
}

# receipt <repo> <run> <text> — the run's first item receipt.
receipt() {
  mkdir -p "$1/.nightshift/runs/$2/receipts"
  printf '%s\n' "$3" >"$1/.nightshift/runs/$2/receipts/01-export-the-table-ab12.md"
}

# thread <repo> <file> <topic> <open-question> — a planning question in its own thread file.
thread() {
  mkdir -p "$1/.nightshift/staging/decisions"
  { sed -n '1,/^---$/p' "$THREAD_HEAD"; printf '\n- **%s** · open since 2026-11-27 10:00 (UTC+04:00)\n  - Open: %s\n' "$3" "$4"; } \
    >"$1/.nightshift/staging/decisions/$2"
}

@test "ns share lets Git see the shared records and none of a runner's private files" {
  a="$(team see)"
  [ ! -s "$a/.gitignore" ]
  mkdir -p "$a/.nightshift/runs/export-csv-abc123/receipts/01-export-the-table-ab12" \
    "$a/.nightshift/runs/export-csv-abc123/run" "$a/.nightshift/runs/export-csv-abc123/inbox" \
    "$a/.nightshift/worktrees/w1"
  for f in runs/export-csv-abc123/punch-list.md runs/export-csv-abc123/receipts/01-export-the-table-ab12.md \
    runs/export-csv-abc123/receipts/01-export-the-table-ab12/screen.png runs/export-csv-abc123/run/shift-log.md \
    runs/export-csv-abc123/inbox/parking-lot.md runs/export-csv-abc123/inbox/messages.md \
    runs/export-csv-abc123/STOP STOP staging/plan-record.md worktrees/w1/file; do
    printf 'x\n' >"$a/.nightshift/$f"
  done
  printf '{}\n' >"$a/.nightshift/runs/export-csv-abc123/rules.json"
  seen="$(git -C "$a" add -A --dry-run | sed "s/^add '//; s/'\$//" | sort)"
  [ "$seen" = ".nightshift/runs/export-csv-abc123/inbox/parking-lot.md
.nightshift/runs/export-csv-abc123/punch-list.md
.nightshift/runs/export-csv-abc123/receipts/01-export-the-table-ab12.md
.nightshift/runs/export-csv-abc123/rules.json" ] || { echo "$seen"; return 1; }
  # Already committed: the shared rules, plan, state version and the block itself, nothing private.
  [ "$(git -C "$a" ls-files .nightshift | sort)" = ".nightshift/.gitattributes
.nightshift/.gitignore
.nightshift/rules.json
.nightshift/staging/plans/export-csv.md
.nightshift/state-version" ]
  # A second run changes nothing; the preview says so.
  run share "$a"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'ok gitignore .nightshift/.gitignore already matches'
}

@test "an owner-selected folder inside the repository shares the same records" {
  r="$BATS_TEST_TMPDIR/chosen/repo"
  add_repo "$BATS_TEST_TMPDIR/chosen" repo
  mkdir -p "$r/planning/.nightshift/staging/plans"
  printf '3\n' >"$r/planning/.nightshift/state-version"
  jq '.sharing.records = ["plans","rules"]' "$RULES_TEMPLATE" >"$r/planning/.nightshift/rules.json"
  printf '# Punch List — P\n\n## Items\n' >"$r/planning/.nightshift/staging/plans/p.md"
  printf 'x\n' >"$r/planning/.nightshift/STOP"
  printf 'planning/.nightshift/\n' >"$r/.gitignore"
  run share "$r/planning" --apply
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx "ok repository took the line planning/.nightshift/ out of $(cd -P "$r" && pwd)/.gitignore so Git can see the shared records"
  seen="$(git -C "$r" add -A --dry-run | sed "s/^add '//; s/'\$//" | grep nightshift | sort)"
  [ "$seen" = "planning/.nightshift/.gitattributes
planning/.nightshift/.gitignore
planning/.nightshift/rules.json
planning/.nightshift/staging/plans/p.md
planning/.nightshift/state-version" ] || { echo "$seen"; return 1; }
}

@test "a planning question committed in one clone is read in the other before approval, and its answer and change are traced in Git" {
  a="$(team trace)"
  b="$(member trace bob)"
  thread "$a" export-csv-separator.md "CSV separator" "comma or semicolon?"
  commit_all "$a" "question: csv separator"
  git -C "$a" push -q 2>/dev/null
  git -C "$b" pull -q 2>/dev/null
  run bash "$RUNTIME/plan-enter.sh" --project "$b"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'decision threads go in .nightshift/staging/decisions, one file each'
  printf '%s\n' "$output" | grep -qx 'open thread: export-csv-separator.md · - \*\*CSV separator\*\* · open since 2026-11-27 10:00 (UTC+04:00)'
  bash "$RUNTIME/plan-exit.sh" --project "$b" >/dev/null 2>&1 || :
  # Bob answers; Alice changes the decision later; a run's receipt follows.
  sed -i.bak 's/  - Open: comma or semicolon?/  - Decided: semicolon — the finance team opens it in a spreadsheet/' \
    "$b/.nightshift/staging/decisions/export-csv-separator.md" && rm "$b/.nightshift/staging/decisions/export-csv-separator.md.bak"
  commit_all "$b" "answer: semicolon"
  git -C "$b" push -q 2>/dev/null
  git -C "$a" pull -q 2>/dev/null
  printf '  - Decided: comma — the importer reads RFC 4180 only\n' >>"$a/.nightshift/staging/decisions/export-csv-separator.md"
  commit_all "$a" "decision: comma"
  run start_run "$a" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run_dir="$(printf '%s\n' "$output" | sed -n 's/^ok run //p')"
  receipt "$a" "$run_dir" "Comma separated."
  commit_all "$a" "receipt: export the table"
  git -C "$a" push -q 2>/dev/null
  git -C "$b" pull -q 2>/dev/null
  [ "$(git -C "$b" log --format='%an %s' -- .nightshift/staging/decisions/export-csv-separator.md)" = "alice decision: comma
bob answer: semicolon
alice question: csv separator" ]
  [ "$(git -C "$b" log --format='%an %s' -- ".nightshift/runs/$run_dir/receipts")" = "alice receipt: export the table" ]
}

@test "the same plan run in two clones keeps both runs' receipts, and the plan stays the team's record" {
  a="$(team twin)"
  b="$(member twin bob)"
  run start_run "$a" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx "ok plan Export CSV stays in .nightshift/staging/plans as the team's record; the run works from its own copy"
  ra="$(printf '%s\n' "$output" | sed -n 's/^ok run //p')"
  run start_run "$b" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  rb="$(printf '%s\n' "$output" | sed -n 's/^ok run //p')"
  [[ "$ra" == export-csv-?????? ]] && [[ "$rb" == export-csv-?????? ]] && [ "$ra" != "$rb" ]
  # The run's copy names its paths from the workspace root, never from a runner's own folders.
  grep -qF -- '- Work in the run; receipts go in `./.nightshift/receipts/`.' "$a/.nightshift/runs/$ra/punch-list.md"
  ! grep -qF "$a" "$a/.nightshift/runs/$ra/punch-list.md"
  [ -f "$a/.nightshift/staging/plans/export-csv.md" ] && [ -f "$b/.nightshift/staging/plans/export-csv.md" ]
  receipt "$a" "$ra" "alice ran it"
  receipt "$b" "$rb" "bob ran it"
  commit_all "$a" "alice: receipt"
  git -C "$a" push -q 2>/dev/null
  commit_all "$b" "bob: receipt"
  git -C "$b" pull -q --no-rebase --no-edit 2>/dev/null
  [ "$(cat "$b/.nightshift/runs/$ra/receipts/01-export-the-table-ab12.md")" = "alice ran it" ]
  [ "$(cat "$b/.nightshift/runs/$rb/receipts/01-export-the-table-ab12.md")" = "bob ran it" ]
  [ -z "$(git -C "$b" diff --name-only --diff-filter=U)" ]
  # Both starts are in the plan's record: it is appended to, so the two sides merge line by line.
  [ "$(grep -c "^- started · .* · run $ra\$\|^- started · .* · run $ra · " "$b/.nightshift/staging/records/export-csv.md")" = 1 ]
  [ "$(grep -c "^- started · .* · run $rb\$\|^- started · .* · run $rb · " "$b/.nightshift/staging/records/export-csv.md")" = 1 ]
  # Bob starting the plan again finishes his own run and never takes Alice's over.
  run start_run "$b" "Export CSV"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx "ok run $rb"
}

@test "decision threads from separate branches merge cleanly and both reopen" {
  a="$(team branches)"
  git -C "$a" checkout -q -b format
  thread "$a" export-csv-separator.md "CSV separator" "comma or semicolon?"
  commit_all "$a" "question: separator"
  git -C "$a" checkout -q main
  git -C "$a" checkout -q -b encoding
  thread "$a" export-csv-encoding.md "CSV encoding" "UTF-8 with or without BOM?"
  commit_all "$a" "question: encoding"
  git -C "$a" checkout -q main
  git -C "$a" merge -q --no-edit format encoding
  run bash "$RUNTIME/plan-enter.sh" --project "$a"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep '^open thread: ')" = "open thread: export-csv-encoding.md · - **CSV encoding** · open since 2026-11-27 10:00 (UTC+04:00)
open thread: export-csv-separator.md · - **CSV separator** · open since 2026-11-27 10:00 (UTC+04:00)" ]
}

@test "a conflicting edit to a shared rule is resolved through Git and the team's value is read" {
  a="$(team rule)"
  b="$(member rule bob)"
  jq '.runs.layout = "date"' "$a/.nightshift/rules.json" >"$a/r" && mv "$a/r" "$a/.nightshift/rules.json"
  commit_all "$a" "rules: date runs"
  git -C "$a" push -q 2>/dev/null
  jq '.runs.layout = "date-name"' "$b/.nightshift/rules.json" >"$b/r" && mv "$b/r" "$b/.nightshift/rules.json"
  commit_all "$b" "rules: date-name runs"
  run git -C "$b" pull -q --no-rebase --no-edit
  [ "$status" -ne 0 ]
  # Unresolved, the file fails closed: the shipped default, not half a file.
  [ "$(lib ns_runs_layout "$b")" = name ]
  git -C "$b" checkout -q --ours .nightshift/rules.json
  git -C "$b" add .nightshift/rules.json
  git -C "$b" commit -q --no-edit
  [ "$(lib ns_runs_layout "$b")" = date-name ]
}

@test "filing a run on a shared site tags its folder and leaves later edits to the shared plan and decisions alone" {
  a="$(team filing)"
  thread "$a" export-csv-separator.md "CSV separator" "comma or semicolon?"
  run start_run "$a" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  r="$(printf '%s\n' "$output" | sed -n 's/^ok run //p')"
  printf -- '- [ ] **2. Added after the run took its copy.**\n' >>"$a/.nightshift/staging/plans/export-csv.md"
  printf '  - Decided: comma\n' >>"$a/.nightshift/staging/decisions/export-csv-separator.md"
  plan="$(cat "$a/.nightshift/staging/plans/export-csv.md")"
  decisions="$(cat "$a/.nightshift/staging/decisions/export-csv-separator.md")"
  NIGHTSHIFT_RUN="$r" bash "$RUNTIME/archive-receipts.sh" --project "$a" --run "$r" >/dev/null 2>&1 || :
  [ "$(cat "$a/.nightshift/staging/plans/export-csv.md")" = "$plan" ]
  [ "$(cat "$a/.nightshift/staging/decisions/export-csv-separator.md")" = "$decisions" ]
  dir="$(lib ns_archive_dir "$a" 2026-11-27 0123456789abcdef)"
  [ "${dir##*/}" = 2026-11-27-012345 ]
}

@test "a solo site keeps its run names, takes the plan out of staging and writes no sharing block" {
  w="$(runs_site solo)"
  run share "$w"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'ok records none: the site stays private to its runner'
  run start_run "$w" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'ok run export-csv'
  printf '%s\n' "$output" | grep -qx 'ok plan Export CSV left staging'
  [ ! -e "$w/.nightshift/staging/plans/export-csv.md" ]
  [ ! -e "$w/.nightshift/.gitignore" ]
  [ "$(lib ns_archive_dir "$w" 2026-11-27 0123456789abcdef)" = "$w/.nightshift/archive/2026-11-27" ]
}

@test "sharing refuses a value it does not know, a one-shift layout and a receipts repo" {
  a="$(team refusals)"
  jq '.sharing.records = ["plans","secrets"]' "$a/.nightshift/rules.json" >"$a/r" && mv "$a/r" "$a/.nightshift/rules.json"
  run share "$a"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'refuse records sharing.records names secrets, which is no record'
  jq '.sharing.records = ["plans"]' "$a/.nightshift/rules.json" >"$a/r" && mv "$a/r" "$a/.nightshift/rules.json"
  git init -q "$a/.nightshift"
  run share "$a" --apply
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^refuse receipts-repo '
  rm -rf "$a/.nightshift/.git"
  printf '2\n' >"$a/.nightshift/state-version"
  run share "$a" --apply
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^refuse layout '
}
