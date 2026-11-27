#!/usr/bin/env bats
# The team's branch workflow: branches.base names where new work branches start, branches.start
# whether a run gets a branch of its own, works on the member's current branch, or on one the member
# chooses, and branches.catchUp how a branch catches up with the base before a pull request.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
RUNTIME="$PLUGIN/runtime"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

start_run_as_is() { # <workspace> <plan> [extra args]
  local w="$1" plan="$2"
  shift 2
  (cd "$w" && env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$w" \
    bash "$RUNTIME/start-run.sh" --project "$w" --plan "$plan" --host claude "$@")
}

# start_run <workspace> <plan> [extra args] — with the runner's consent to what it would execute.
start_run() {
  local out consent
  if out="$(start_run_as_is "$@")"; then printf '%s\n' "$out"; return 0; fi
  consent="$(printf '%s\n' "$out" | sed -n 's/^repair read those inputs, then run this again with --consent //p')"
  [ -n "$consent" ] || { printf '%s\n' "$out"; return 1; }
  start_run_as_is "$@" --consent "$consent"
}

set_rules() { jq "$2" "$1/.nightshift/rules.json" >"$1/.nightshift/r.tmp" && mv "$1/.nightshift/r.tmp" "$1/.nightshift/rules.json"; }

plan() { # <repo> <name>
  printf '# Punch List — %s\n\n## Contract\n\n- Work in the run.\n\n## Gates\n\n## Items\n\n- [ ] **1. Do %s.**\n  - Verify: true\n  - Commit: `feat: x`\n' \
    "$2" "$2" >"$1/.nightshift/staging/plans/$(printf '%s' "$2" | tr 'A-Z ' 'a-z-').md"
}

# team <name> — a remote whose base branch is develop and a clone of it with the site inside the
# repository, sharing plans and rules, its runs starting from develop.
team() {
  local root="$BATS_TEST_TMPDIR/$1" a
  git init -q --bare "$root/remote.git"
  a="$root/alice"
  git clone -q "$root/remote.git" "$a" 2>/dev/null
  git -C "$a" symbolic-ref HEAD refs/heads/develop
  git -C "$a" config user.email alice@example.com
  git -C "$a" config user.name Alice
  printf 'app\n' >"$a/app.txt"
  mkdir -p "$a/.nightshift/staging/plans" "$a/.nightshift/runs" "$a/.nightshift/run"
  printf '3\n' >"$a/.nightshift/state-version"
  jq '.sharing.records = ["plans", "rules"] | .branches.base = "develop"' "$RULES_TEMPLATE" >"$a/.nightshift/rules.json"
  printf '%s\n' "$(cd -P "$a" && pwd)" >"$a/.nightshift/run/work-target"
  printf 'repository\n' >"$a/.nightshift/run/work-mode"
  bash "$RUNTIME/share.sh" --project "$a" --apply >/dev/null
  git -C "$a" add -A
  git -C "$a" commit -q -m "site"
  git -C "$a" push -q -u origin develop 2>/dev/null
  printf '%s' "$(cd -P "$a" && pwd)"
}

@test "two plans merged from one planning branch run one after another on one member branch" {
  a="$(team sequence)"
  set_rules "$a" '.branches.start = "choose"'
  git -C "$a" checkout -q -b planning
  plan "$a" "Export CSV"
  plan "$a" "Dark mode"
  git -C "$a" add -A && git -C "$a" commit -q -m "plans: export csv and dark mode"
  git -C "$a" checkout -q develop
  git -C "$a" merge -q --no-ff --no-edit planning
  # Without a branch, the choices are listed and nothing is placed.
  run start_run "$a" "Export CSV"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'refuse branch this team chooses the branch each run works on'
  printf '%s\n' "$output" | grep -qx 'branch current develop'
  printf '%s\n' "$output" | grep -qx 'branch existing planning'
  printf '%s\n' "$output" | grep -qx 'branch base develop'
  [ -z "$(ls -A "$a/.nightshift/runs")" ]
  run start_run "$a" "Export CSV" --branch alice/export
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'ok branch alice/export'
  wt="$(NIGHTSHIFT_RUN=export-csv lib ns_work_target "$a")"
  [ "$(git -C "$wt" symbolic-ref --short HEAD)" = alice/export ]
  [ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$a" rev-parse develop)" ]
  # The second plan waits for the first on the same branch.
  run start_run "$a" "Dark mode" --branch alice/export
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'refuse worktree alice/export is in use by run export-csv'
  : >"$a/.nightshift/runs/export-csv/run/.ended"
  run start_run "$a" "Dark mode" --branch alice/export
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx "ok worktree $wt branch alice/export - the run continues the branch's worktree"
  [ "$(NIGHTSHIFT_RUN=dark-mode lib ns_work_target "$a")" = "$wt" ]
}

@test "a member plans and runs on the current branch, in the checkout itself" {
  a="$(team current)"
  set_rules "$a" '.branches.start = "current"'
  git -C "$a" checkout -q -b bob/feature
  plan "$a" "Export CSV"
  run start_run "$a" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'ok branch bob/feature'
  printf '%s\n' "$output" | grep -qx 'ok worktree none - the run works on bob/feature in the checkout itself'
  [ "$(NIGHTSHIFT_RUN=export-csv lib ns_work_target "$a")" = "$a" ]
  # The shipped rule still gives each run a branch of its own.
  set_rules "$a" '.branches.start = "per-run"'
  plan "$a" "Dark mode"
  run start_run "$a" "Dark mode"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$(NIGHTSHIFT_RUN=dark-mode lib ns_work_target "$a")" symbolic-ref --short HEAD)" = "shift/$(date +%Y-%m-%d)-dark-mode" ]
}

@test "a new plan states the team's catch-up, and each policy brings in a moved base, conflict included" {
  a="$(team sync)"
  bash "$RUNTIME/plan-new.sh" --project "$a" --name "Merged" >/dev/null
  grep -qF 'Catching up with the base branch is a merge.' "$a/.nightshift/staging/plans/merged.md"
  set_rules "$a" '.branches.catchUp = "rebase"'
  bash "$RUNTIME/plan-new.sh" --project "$a" --name "Rebased" >/dev/null
  grep -qF 'Catching up with the base branch is a rebase onto it.' "$a/.nightshift/staging/plans/rebased.md"
  ! grep -qF 'is a merge.' "$a/.nightshift/staging/plans/rebased.md" || false
  git -C "$a" checkout -q -- .nightshift/rules.json
  # A teammate moves the base, changing a shared rule the member's branch also changed.
  b="$BATS_TEST_TMPDIR/sync/bob"
  git clone -q -b develop "$BATS_TEST_TMPDIR/sync/remote.git" "$b" 2>/dev/null
  set_rules "$b" '.runs.layout = "date"'
  git -C "$b" -c user.name=Bob -c user.email=b@example.com commit -q -am "rules: date runs"
  git -C "$b" push -q 2>/dev/null
  for policy in merge rebase; do
    git -C "$a" checkout -q -b "alice/$policy" develop
    set_rules "$a" '.runs.layout = "date-name"'
    git -C "$a" commit -q -am "rules: date-name runs"
    git -C "$a" fetch -q origin
    if [ "$policy" = merge ]; then
      ! git -C "$a" merge -q --no-edit origin/develop >/dev/null 2>&1 || false
      git -C "$a" checkout -q --theirs .nightshift/rules.json
      git -C "$a" add .nightshift/rules.json
      git -C "$a" commit -q --no-edit
    else
      ! git -C "$a" rebase -q origin/develop >/dev/null 2>&1 || false
      git -C "$a" checkout -q --ours .nightshift/rules.json
      git -C "$a" add .nightshift/rules.json
      GIT_EDITOR=true git -C "$a" rebase --continue >/dev/null 2>&1
      [ "$(git -C "$a" rev-list --merges origin/develop..HEAD | wc -l | tr -d ' ')" = 0 ]
    fi
    git -C "$a" merge-base --is-ancestor origin/develop HEAD
    [ "$(lib ns_runs_layout "$a")" = date ]
    git -C "$a" checkout -q develop
  done
}

@test "native Windows lists the same choices and runs on the current branch the same way" {
  command -v pwsh >/dev/null || skip 'pwsh is not installed'
  a="$(team windows)"
  set_rules "$a" '.branches.start = "choose"'
  plan "$a" "Export CSV"
  bash_out="$(start_run_as_is "$a" "Export CSV")" || :
  ps_out="$(cd "$a" && env -u NIGHTSHIFT_RUN pwsh -NoProfile -File "$RUNTIME/windows/start-run.ps1" -Project "$a" -Plan "Export CSV" -HostName claude)" || :
  [ "$bash_out" = "$ps_out" ] || { printf 'bash:\n%s\npwsh:\n%s\n' "$bash_out" "$ps_out"; return 1; }
  set_rules "$a" '.branches.start = "current" | .branches.catchUp = "rebase"'
  git -C "$a" checkout -q -b bob/feature
  out="$(cd "$a" && env -u NIGHTSHIFT_RUN pwsh -NoProfile -File "$RUNTIME/windows/start-run.ps1" -Project "$a" -Plan "Export CSV" -HostName claude)" || :
  consent="$(printf '%s\n' "$out" | sed -n 's/^repair read those inputs, then run this again with --consent //p')"
  out="$(cd "$a" && env -u NIGHTSHIFT_RUN pwsh -NoProfile -File "$RUNTIME/windows/start-run.ps1" -Project "$a" -Plan "Export CSV" -HostName claude -Consent "$consent")"
  printf '%s\n' "$out" | grep -qx 'ok worktree none - the run works on bob/feature in the checkout itself'
  pwsh -NoProfile -File "$RUNTIME/windows/plan-new.ps1" -Project "$a" -Name "Rebased" >/dev/null
  grep -qF 'Catching up with the base branch is a rebase onto it.' "$a/.nightshift/staging/plans/rebased.md"
}
