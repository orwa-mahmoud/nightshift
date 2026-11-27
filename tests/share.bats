#!/usr/bin/env bats
# Shared project records: a team keeps plans, decisions, rules, receipts and filed shifts in Git
# through .nightshift/ inside the repository. The shipped .nightshift/.gitignore decides what Git
# sees, the owner may edit it, and Nightshift reads what Git sees; each runner's private files stay
# ignored and teammates' runs never meet in one folder.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
RUNTIME="$PLUGIN/runtime"
THREAD_HEAD="$PLUGIN/skills/nightshift/references/templates/plan-record.md"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

start_run() { # <workspace> <plan> [extra args]
  local w="$1" plan="$2"
  shift 2
  (cd "$w" && env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$w" \
    bash "$RUNTIME/start-run.sh" --project "$w" --plan "$plan" --host claude "$@")
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

# team <name> — a bare remote and the first member's clone with the site inside the repository,
# sharing through the shipped ignore files, pushed. Prints the clone's path.
team() {
  local root="$BATS_TEST_TMPDIR/$1" a
  git init -q --bare "$root/remote.git"
  a="$root/alice"
  git clone -q "$root/remote.git" "$a" 2>/dev/null
  git -C "$a" symbolic-ref HEAD refs/heads/main
  git -C "$a" config user.email alice@example.com
  git -C "$a" config user.name alice
  printf 'app\n' >"$a/app.txt"
  mkdir -p "$a/.nightshift/staging/plans" "$a/.nightshift/staging/decisions"
  printf '3\n' >"$a/.nightshift/state-version"
  cp "$RULES_TEMPLATE" "$a/.nightshift/rules.json"
  share_through_git "$a"
  printf '# Punch List — Export CSV\n\n## Contract\n\n- Work in the run; receipts go in `$NS/receipts/`.\n\n## Gates\n\n## Items\n\n- [ ] **1. Export the table.**\n  - Verify: true\n  - Commit: `feat: export`\n' \
    >"$a/.nightshift/staging/plans/export-csv.md"
  local_site "$a"
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

@test "the shipped ignore file lets Git see the shared records and none of a runner's private files" {
  a="$(team see)"
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
  # A shift filed from a run folder keeps the run's layout under its folder; the same files stay private.
  filed="$a/.nightshift/archive/2026-11-27-abc123/runs/export-csv-abc123"
  mkdir -p "$filed/run" "$filed/receipts/01-export-the-table-ab12" "$filed/inbox"
  for f in run/shift-policy.json receipts/01-export-the-table-ab12.md receipts/01-export-the-table-ab12/screen.png \
    inbox/messages.md inbox/parking-lot.md; do
    printf 'x\n' >"$filed/$f"
  done
  seen="$(git -C "$a" add -A --dry-run | sed "s/^add '//; s/'\$//" | sort)"
  [ "$seen" = ".nightshift/archive/2026-11-27-abc123/runs/export-csv-abc123/inbox/parking-lot.md
.nightshift/archive/2026-11-27-abc123/runs/export-csv-abc123/receipts/01-export-the-table-ab12.md
.nightshift/runs/export-csv-abc123/inbox/parking-lot.md
.nightshift/runs/export-csv-abc123/punch-list.md
.nightshift/runs/export-csv-abc123/receipts/01-export-the-table-ab12.md
.nightshift/runs/export-csv-abc123/rules.json" ] || { echo "$seen"; return 1; }
  [ "$(git -C "$a" ls-files .nightshift | sort)" = ".nightshift/.gitattributes
.nightshift/.gitignore
.nightshift/rules.json
.nightshift/staging/plans/export-csv.md
.nightshift/state-version" ]
}

@test "an edit to the shipped ignore file changes what Nightshift treats as shared" {
  a="$(team edited)"
  for r in plans decisions rules receipts summaries; do lib ns_site_shares "$a" "$r"; done
  # The team keeps run receipts out of Git: runs get no tag, and the plan still stays staged.
  printf '/runs/\n' >>"$a/.nightshift/.gitignore"
  ! lib ns_site_shares "$a" receipts || false
  lib ns_site_shares "$a" plans
  run start_run "$a" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'ok run export-csv'
  [ -f "$a/.nightshift/staging/plans/export-csv.md" ]
  # Ignoring the whole site keeps it private; so does a receipts repository inside it.
  printf '.nightshift/\n' >"$a/.gitignore"
  ! lib ns_site_shares "$a" plans || false
  : >"$a/.gitignore"
  git init -q "$a/.nightshift"
  ! lib ns_site_shares "$a" plans || false
}

@test "an owner-selected folder inside the repository shares the same records" {
  r="$BATS_TEST_TMPDIR/chosen/repo"
  add_repo "$BATS_TEST_TMPDIR/chosen" repo
  mkdir -p "$r/planning/.nightshift/staging/plans"
  printf '3\n' >"$r/planning/.nightshift/state-version"
  cp "$RULES_TEMPLATE" "$r/planning/.nightshift/rules.json"
  share_through_git "$r/planning"
  printf '# Punch List — P\n\n## Items\n' >"$r/planning/.nightshift/staging/plans/p.md"
  printf 'x\n' >"$r/planning/.nightshift/STOP"
  seen="$(git -C "$r" add -A --dry-run | sed "s/^add '//; s/'\$//" | grep nightshift | sort)"
  [ "$seen" = "planning/.nightshift/.gitattributes
planning/.nightshift/.gitignore
planning/.nightshift/rules.json
planning/.nightshift/staging/plans/p.md
planning/.nightshift/state-version" ] || { echo "$seen"; return 1; }
  lib ns_site_shares "$r/planning" plans
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

@test "the same plan run in two clones keeps both runs' receipts and records, and the plan stays the team's record" {
  a="$(team twin)"
  b="$(member twin bob)"
  run start_run "$a" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx "ok plan Export CSV stays in .nightshift/staging/plans as the team's record; the run works from its own copy"
  ra="$(printf '%s\n' "$output" | sed -n 's/^ok run //p')"
  run start_run "$b" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  rb="$(printf '%s\n' "$output" | sed -n 's/^ok run //p')"
  [[ "$ra" == export-csv-?????? ]] && [[ "$rb" == export-csv-?????? ]] && [ "$ra" != "$rb" ] || false
  # The run's copy names its paths from the workspace root, never from a runner's own folders.
  grep -qF -- '- Work in the run; receipts go in `./.nightshift/receipts/`.' "$a/.nightshift/runs/$ra/punch-list.md"
  ! grep -qF "$a" "$a/.nightshift/runs/$ra/punch-list.md" || false
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
  [ "$(grep -c "^- started · .* · run $ra\$" "$b/.nightshift/staging/records/export-csv.md")" = 1 ]
  [ "$(grep -c "^- started · .* · run $rb\$" "$b/.nightshift/staging/records/export-csv.md")" = 1 ]
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

@test "a solo site keeps its run names, takes the plan out of staging and shares nothing" {
  w="$(runs_site solo)"
  ! lib ns_site_shares "$w" plans || false
  run start_run "$w" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'ok run export-csv'
  printf '%s\n' "$output" | grep -qx 'ok plan Export CSV left staging'
  [ ! -e "$w/.nightshift/staging/plans/export-csv.md" ]
  [ "$(lib ns_archive_dir "$w" 2026-11-27 0123456789abcdef)" = "$w/.nightshift/archive/2026-11-27" ]
}

@test "Doctor names a file Git tracks that the ignore rules keep private, on both runtimes" {
  a="$(team tracked)"
  printf 'reason\n' >"$a/.nightshift/STOP"
  git -C "$a" add -f .nightshift/STOP
  git -C "$a" commit -q -m "stop"
  run bash "$RUNTIME/doctor.sh" --project "$a"
  printf '%s\n' "$output" | grep -qF 'Git tracks .nightshift/STOP, which .nightshift/.gitignore keeps private; untrack it with git rm --cached' ||
    { echo "$output"; return 1; }
  command -v pwsh >/dev/null || skip 'pwsh is not installed'
  run pwsh -NoProfile -File "$RUNTIME/windows/doctor.ps1" -Project "$a"
  printf '%s\n' "$output" | grep -qF 'Git tracks .nightshift/STOP, which .nightshift/.gitignore keeps private; untrack it with git rm --cached' ||
    { echo "$output"; return 1; }
}

@test "native Windows reads sharing from Git the same way" {
  command -v pwsh >/dev/null || skip 'pwsh is not installed'
  a="$(team windows)"
  printf '/runs/\n' >>"$a/.nightshift/.gitignore"
  for r in plans decisions rules receipts summaries; do
    bash_says="$(lib ns_site_shares "$a" "$r" && echo yes || echo no)"
    ps_says="$(pwsh -NoProfile -Command "Import-Module '$PLUGIN/lib/Nightshift.psm1' -Force -DisableNameChecking; if (Test-NSSiteShares '$a' '$r') { 'yes' } else { 'no' }")"
    [ "$bash_says" = "$ps_says" ] || { echo "$r: bash=$bash_says pwsh=$ps_says"; return 1; }
  done
  [ "$(lib ns_site_shares "$a" receipts && echo yes || echo no)" = no ]
}
