#!/usr/bin/env bats
# A team's whole workflow across clones of one repository: a developer proposes work and asks a
# question, the lead answers and approves the revised plan, the runner selects their settings, runs
# it and files its receipts sharing one screenshot, and a teammate records the review. A fresh clone
# traces every stage and who took it.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
RUNTIME="$PLUGIN/runtime"
THREAD_HEAD="$PLUGIN/skills/nightshift/references/templates/plan-record.md"
BASE=01-export-the-table-ab12

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }
record() { bash "$RUNTIME/plan-record.sh" --project "$1" --plan "$2" "${@:3}"; }

start_run_as_is() { # <workspace> <plan> [extra args]
  local w="$1" plan="$2"
  shift 2
  (cd "$w" && env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$w" \
    bash "$RUNTIME/start-run.sh" --project "$w" --plan "$plan" --host claude "$@")
}

save() { git -C "$1" add -A && git -C "$1" commit -q -m "$2" && git -C "$1" push -q 2>/dev/null; }
pull() { git -C "$1" pull -q --no-rebase --no-edit 2>/dev/null; }

# member <team> <name> — a clone set up on that member's machine.
member() {
  local m="$BATS_TEST_TMPDIR/$1/$2"
  git clone -q -b main "$BATS_TEST_TMPDIR/$1/remote.git" "$m" 2>/dev/null
  git -C "$m" config user.email "$2@example.com"
  git -C "$m" config user.name "$2"
  mkdir -p "$m/.nightshift/run" "$m/.nightshift/staging/plans"
  printf '%s\n' "$(cd -P "$m" && pwd)" >"$m/.nightshift/run/work-target"
  printf 'repository\n' >"$m/.nightshift/run/work-mode"
  printf '%s' "$(cd -P "$m" && pwd)"
}

# team <name> <team-jq> — the remote and the project the lead sets up: the site inside the
# repository, shared through the shipped ignore files, and the team block given.
team() {
  local root="$BATS_TEST_TMPDIR/$1" a
  git init -q --bare "$root/remote.git"
  a="$root/Alice"
  git clone -q "$root/remote.git" "$a" 2>/dev/null
  git -C "$a" symbolic-ref HEAD refs/heads/main
  git -C "$a" config user.email alice@example.com
  git -C "$a" config user.name Alice
  printf 'app\n' >"$a/app.txt"
  mkdir -p "$a/.nightshift/staging/plans" "$a/.nightshift/settings" "$a/.nightshift/run"
  printf '3\n' >"$a/.nightshift/state-version"
  jq '.team.roles = {"Alice": "lead", "Bob": "developer"}'"$2" "$RULES_TEMPLATE" >"$a/.nightshift/rules.json"
  printf '{\n  "shift": {\n    "hours": 3\n  }\n}\n' >"$a/.nightshift/settings/bob.json"
  printf '%s\n' "$(cd -P "$a" && pwd)" >"$a/.nightshift/run/work-target"
  printf 'repository\n' >"$a/.nightshift/run/work-mode"
  share_through_git "$a"
  git -C "$a" add -A
  git -C "$a" commit -q -m "site: shared project records"
  git -C "$a" push -q -u origin main 2>/dev/null
  printf '%s' "$(cd -P "$a" && pwd)"
}

plan_text() { # <name> <item>
  printf '# Punch List — %s\n\n## Contract\n\n- Work in the run.\n\n## Gates\n\n- `true`\n\n## Items\n\n- [ ] **1. %s.**\n  - Verify: true\n  - Commit: `feat: export`\n' "$1" "$2"
}

# run_and_file <clone> <plan> [start args] — the runner starts the run, works the item with two
# screenshots, files the shift, and shares the first screenshot as the Archive skill says: a copy in
# the filed run's evidence/ folder, the receipt's link pointed at it, the other link made a label.
run_and_file() {
  local w="$1" plan="$2" out run id folder ns filed
  shift 2
  out="$(start_run_as_is "$w" "$plan" "$@")" || { printf '%s\n' "$out"; return 1; }
  run="$(printf '%s\n' "$out" | sed -n 's/^ok run //p')"
  ns="$w/.nightshift"
  mkdir -p "$ns/runs/$run/receipts/$BASE"
  printf 'before\n' >"$ns/runs/$run/receipts/$BASE/before.png"
  printf 'after\n' >"$ns/runs/$run/receipts/$BASE/after.png"
  printf '# 1. Export the table.\n\n![Before](./%s/before.png) ![After](./%s/after.png)\n' "$BASE" "$BASE" >"$ns/runs/$run/receipts/$BASE.md"
  sed -i.bak 's/^- \[ \] \*\*1\./- [x] **1./' "$ns/runs/$run/punch-list.md" && rm "$ns/runs/$run/punch-list.md.bak"
  id="$(NIGHTSHIFT_RUN="$run" lib ns_policy_shift_id "$w")"
  folder="$(NIGHTSHIFT_RUN="$run" lib ns_archive_dir "$w" "$(date +%Y-%m-%d)" "$id")"
  NIGHTSHIFT_RUN="$run" lib ns_ended_record "$ns" "$id" archive date "$plan" "${folder##*/}" claude
  out="$(NIGHTSHIFT_RUN="$run" bash "$RUNTIME/archive-receipts.sh" --project "$w" --run "$run" --retire "$BASE.md" 2>&1)" || { printf 'archive:\n%s\n' "$out"; return 1; }
  filed="$folder/runs/$run"
  mkdir -p "$filed/evidence/$BASE"
  cp "$filed/receipts/$BASE/before.png" "$filed/evidence/$BASE/before.png"
  sed -i.bak "s|(./$BASE/before.png)|(../evidence/$BASE/before.png)|; s|!\[After\](./$BASE/after.png)|After (private evidence: $BASE/after.png)|" \
    "$filed/receipts/$BASE.md" && rm "$filed/receipts/$BASE.md.bak"
  printf '%s %s\n' "$run" "${folder##*/}"
}

@test "a developer's proposal, the lead's answer and approval, a run with one shared screenshot and a review trace in a fresh clone" {
  a="$(team flow '| .team.approvers = ["lead"]')"
  b="$(member flow Bob)"
  # Bob proposes the work and asks a question.
  plan_text "Export CSV" "Export the table" >"$b/.nightshift/staging/plans/export-csv.md"
  mkdir -p "$b/.nightshift/staging/decisions"
  { sed -n '1,/^---$/p' "$THREAD_HEAD"; printf '\n- **CSV separator** · open since 2026-11-27 10:00 (UTC+04:00)\n  - Open: comma or semicolon?\n'; } \
    >"$b/.nightshift/staging/decisions/export-csv-separator.md"
  record "$b" "Export CSV" --action proposed >/dev/null
  save "$b" "propose: export csv"
  # Alice answers, revises the plan and approves the revision.
  pull "$a"
  bash "$RUNTIME/plan-enter.sh" --project "$a" | grep -qx 'open thread: export-csv-separator.md · - \*\*CSV separator\*\* · open since 2026-11-27 10:00 (UTC+04:00)'
  bash "$RUNTIME/plan-exit.sh" --project "$a" >/dev/null 2>&1 || :
  sed -i.bak 's/  - Open: comma or semicolon?/  - Decided: comma — the importer reads RFC 4180/' "$a/.nightshift/staging/decisions/export-csv-separator.md"
  rm "$a/.nightshift/staging/decisions/export-csv-separator.md.bak"
  plan_text "Export CSV" "Export the table as comma-separated values" >"$a/.nightshift/staging/plans/export-csv.md"
  run start_run_as_is "$a" "Export CSV"
  printf '%s\n' "$output" | grep -q '^refuse approval Export CSV revision .* is proposed: no approver has approved it$'
  record "$a" "Export CSV" --action approved >/dev/null
  approved="$(lib ns_plan_revision "$a/.nightshift/staging/plans/export-csv.md")"
  save "$a" "approve: export csv"
  # Bob runs it with his settings and files it, sharing one screenshot.
  pull "$b"
  filed="$(run_and_file "$b" "Export CSV" --settings bob)" || { echo "$filed"; return 1; }
  run_name="${filed% *}"
  folder="${filed#* }"
  [ "$(NIGHTSHIFT_RUN="$run_name" lib ns_rules_get_in "$b/.nightshift/rules.json" shift hours)" = 3 ]
  save "$b" "file: export csv"
  # Alice reviews the outcome.
  pull "$a"
  record "$a" "Export CSV" --action reviewed --run "$run_name" --note "export reads correctly" >/dev/null
  save "$a" "review: export csv"
  # A fresh clone traces every stage and who took it.
  c="$(member flow Carol)"
  run record "$c" "Export CSV"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx "approved-by Alice $approved"
  printf '%s\n' "$output" | grep -qx 'state approved'
  [ "$(printf '%s\n' "$output" | sed -n 's/^record \([a-z]*\) by \([A-Za-z]*\) at .*/\1 \2/p')" = "proposed Bob
approved Alice
started Bob
reviewed Alice" ] || { echo "$output"; return 1; }
  grep -q "^- started · Bob · developer · .* · revision $approved · run $run_name\$" "$c/.nightshift/staging/records/export-csv.md"
  [ "$(git -C "$c" log --format='%an %s' -- .nightshift/staging/decisions/export-csv-separator.md)" = "Alice approve: export csv
Bob propose: export csv" ]
  receipts="$c/.nightshift/archive/$folder/runs/$run_name/receipts"
  link="$(sed -n 's/.*!\[Before\](\([^)]*\)).*/\1/p' "$receipts/$BASE.md")"
  [ "$(cat "$receipts/$link")" = before ]
  grep -qF "After (private evidence: $BASE/after.png)" "$receipts/$BASE.md"
  [ -z "$(find "$c/.nightshift" -name after.png)" ]
  [ -z "$(git -C "$c" ls-files | grep -E '(^|/)(STOP|\.shift-lease|messages\.md)$|/run/')" ]
}

@test "a lead approves their own plan directly, and a project with other rules runs without approval" {
  a="$(team lead '| .team.approvers = ["lead"]')"
  plan_text "Dark mode" "Add a dark theme" >"$a/.nightshift/staging/plans/dark-mode.md"
  record "$a" "Dark mode" --action proposed >/dev/null
  record "$a" "Dark mode" --action approved >/dev/null
  save "$a" "plan: dark mode, approved by its lead"
  b="$(member lead Bob)"
  plan_text "Print view" "Add a print view" >"$b/.nightshift/staging/plans/print-view.md"
  record "$b" "Print view" --action proposed >/dev/null
  run record "$b" "Print view" --action approved
  [ "$status" -eq 1 ]
  run start_run_as_is "$b" "Print view"
  printf '%s\n' "$output" | grep -q '^refuse approval Print view revision .* is proposed'
  filed="$(run_and_file "$b" "Dark mode")" || { echo "$filed"; return 1; }
  # A project whose rules need no approval runs a plan as soon as its runner starts it.
  o="$(team open '| .team.approvers = []')"
  plan_text "Search" "Add search" >"$o/.nightshift/staging/plans/search.md"
  filed="$(run_and_file "$o" "Search")" || { echo "$filed"; return 1; }
  grep -q '^- started · Alice · lead · ' "$o/.nightshift/staging/records/search.md"
}
