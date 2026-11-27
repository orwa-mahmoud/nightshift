#!/usr/bin/env bats
# Work branches: start-run --branch names the branch a run works on (the current one, an existing
# work branch, or a new one from branches.base); without it a run gets a branch of its own. How a
# branch catches up with its base is a line in the plan's contract the owner edits.

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

set_rules() { jq "$2" "$1/.nightshift/rules.json" >"$1/.nightshift/r.tmp" && mv "$1/.nightshift/r.tmp" "$1/.nightshift/rules.json"; }

plan() { # <repo> <name>
  printf '# Punch List — %s\n\n## Contract\n\n- Work in the run.\n\n## Gates\n\n## Items\n\n- [ ] **1. Do %s.**\n  - Verify: true\n  - Commit: `feat: x`\n' \
    "$2" "$2" >"$1/.nightshift/staging/plans/$(printf '%s' "$2" | tr 'A-Z ' 'a-z-')".md
}

# team <name> — a remote whose base branch is develop and a clone of it with the site inside the
# repository, shared through the shipped ignore files, its new branches starting from develop.
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
  jq '.branches.base = "develop"' "$RULES_TEMPLATE" >"$a/.nightshift/rules.json"
  printf '%s\n' "$(cd -P "$a" && pwd)" >"$a/.nightshift/run/work-target"
  printf 'repository\n' >"$a/.nightshift/run/work-mode"
  share_through_git "$a"
  git -C "$a" add -A
  git -C "$a" commit -q -m "site"
  git -C "$a" push -q -u origin develop 2>/dev/null
  printf '%s' "$(cd -P "$a" && pwd)"
}

@test "two plans merged from one planning branch run one after another on one member branch" {
  a="$(team sequence)"
  git -C "$a" checkout -q -b planning
  plan "$a" "Export CSV"
  plan "$a" "Dark mode"
  git -C "$a" add -A && git -C "$a" commit -q -m "plans: export csv and dark mode"
  git -C "$a" checkout -q develop
  git -C "$a" merge -q --no-ff --no-edit planning
  run start_run "$a" "Export CSV" --branch alice/export
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'ok branch alice/export'
  first="$(printf '%s\n' "$output" | sed -n 's/^ok run //p')"
  wt="$(NIGHTSHIFT_RUN="$first" lib ns_work_target "$a")"
  [ "$(git -C "$wt" symbolic-ref --short HEAD)" = alice/export ]
  [ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$a" rev-parse develop)" ]
  # The second plan waits for the first on the same branch.
  run start_run "$a" "Dark mode" --branch alice/export
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx "refuse worktree alice/export is in use by run $first"
  : >"$a/.nightshift/runs/$first/run/.ended"
  run start_run "$a" "Dark mode" --branch alice/export
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx "ok worktree $wt branch alice/export - the run continues the branch's worktree"
  second="$(printf '%s\n' "$output" | sed -n 's/^ok run //p')"
  [ "$(NIGHTSHIFT_RUN="$second" lib ns_work_target "$a")" = "$wt" ]
}

@test "a member runs on the current branch in the checkout, and a run without --branch gets its own" {
  a="$(team current)"
  git -C "$a" checkout -q -b bob/feature
  plan "$a" "Export CSV"
  run start_run "$a" "Export CSV" --branch bob/feature
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'ok worktree none - the run works on bob/feature in the checkout itself'
  [ "$(NIGHTSHIFT_RUN="$(printf '%s\n' "$output" | sed -n 's/^ok run //p')" lib ns_work_target "$a")" = "$a" ]
  plan "$a" "Dark mode"
  run start_run "$a" "Dark mode"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$(NIGHTSHIFT_RUN="$(printf '%s\n' "$output" | sed -n 's/^ok run //p')" lib ns_work_target "$a")" symbolic-ref --short HEAD)" = "shift/$(date +%Y-%m-%d)-dark-mode" ]
  run start_run "$a" "Dark mode" --branch 'not a branch'
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'refuse branch not a branch is not a branch name'
}

@test "a new plan states a merge catch-up, and either policy brings in a moved base, conflict included" {
  a="$(team sync)"
  bash "$RUNTIME/plan-new.sh" --project "$a" --name "Merged" >/dev/null
  grep -qF 'Catching up with the base branch is a merge.' "$a/.nightshift/staging/plans/merged.md"
  # A teammate moves the base, changing a shared rule the member's branch also changed.
  b="$BATS_TEST_TMPDIR/sync/bob"
  git clone -q -b develop "$BATS_TEST_TMPDIR/sync/remote.git" "$b" 2>/dev/null
  set_rules "$b" '.runs.layout = "date"'
  git -C "$b" -c user.name=Bob -c user.email=b@example.com commit -q -am "rules: date runs"
  git -C "$b" push -q 2>/dev/null
  rm "$a/.nightshift/staging/plans/merged.md"
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

@test "native Windows runs on a named branch the same way" {
  command -v pwsh >/dev/null || skip 'pwsh is not installed'
  a="$(team windows)"
  git -C "$a" checkout -q -b bob/feature
  plan "$a" "Export CSV"
  out="$(cd "$a" && env -u NIGHTSHIFT_RUN pwsh -NoProfile -File "$RUNTIME/windows/start-run.ps1" -Project "$a" -Plan "Export CSV" -HostName claude -Branch bob/feature)"
  printf '%s\n' "$out" | grep -qx 'ok worktree none - the run works on bob/feature in the checkout itself' || { echo "$out"; return 1; }
  pwsh -NoProfile -File "$RUNTIME/windows/plan-new.ps1" -Project "$a" -Name "Merged" >/dev/null
  grep -qF 'Catching up with the base branch is a merge.' "$a/.nightshift/staging/plans/merged.md"
}
