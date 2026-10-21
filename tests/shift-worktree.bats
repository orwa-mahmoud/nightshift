#!/usr/bin/env bats
# Shift worktrees: with shift.isolation worktree, Start gives the shift its own git worktree and
# branch, prepared and recorded as its work target. The owner's checkout, index and uncommitted
# edits are never touched, and ignored files stay out unless the owner lists them.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
PREFLIGHT="$PLUGIN/runtime/start-preflight.sh"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

# site <name> [jq-filter] — a version-2 workspace beside its code repo, no shift armed, one open item,
# with the owner's shift block set by the filter. The repo ignores .env files and the owner has
# uncommitted work in it.
site() {
  local w
  w="$(new_workspace "$1")"
  rm -f "$w/.nightshift/.shift-armed"
  printf '2\n' >"$w/.nightshift/state-version"
  mkdir -p "$w/.nightshift/run"
  printf '# Punch List — Worktree trial\n\n## Items\n\n- [ ] **1. Change the app.**\n  - Verify: x\n  - Commit: `feat: x`\n' \
    >"$w/.nightshift/punch-list.md"
  printf 'app\n' >"$w/repo/app.txt"
  printf '.env*\n' >"$w/repo/.gitignore"
  git -C "$w/repo" add app.txt .gitignore
  git -C "$w/repo" commit -q -m app
  printf 'SECRET=real\n' >"$w/repo/.env"
  printf 'SECRET=test\n' >"$w/repo/.env.test"
  printf 'owner work in progress\n' >>"$w/repo/app.txt"
  jq "${2:-.}" "$w/.nightshift/rules.json" >"$w/.nightshift/rules.json.tmp"
  mv "$w/.nightshift/rules.json.tmp" "$w/.nightshift/rules.json"
  bash "$PREFLIGHT" --project "$w" --phase snapshot >/dev/null
  printf '%s' "$w"
}

@test "isolation none, or no setting, leaves the shift in the work target" {
  w="$(site plain)"
  run bash "$PREFLIGHT" --project "$w" --phase worktree
  [ "$status" -eq 0 ]
  [ "$output" = 'ok host unknown
ok workspace '"$(cd -P "$w" && pwd)"'
ok worktree none - the shift works in the work target itself' ] || { echo "$output"; return 1; }
  [ "$(lib ns_work_target "$w")" = "$(cd -P "$w/repo" && pwd)" ]
  [ ! -e "$w/.nightshift/worktrees" ]
}

@test "isolation worktree gives the shift its own prepared worktree and branch, and the checkout stays as it was" {
  w="$(site isolated '.shift.isolation = "worktree" | .shift.copyIn = [".env.test"] | .shift.prepare = "touch prepared"')"
  head_before="$(git -C "$w/repo" rev-parse HEAD)"
  status_before="$(git -C "$w/repo" status --porcelain)"
  run bash "$PREFLIGHT" --project "$w" --phase worktree
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  id="$(lib ns_policy_shift_id "$w")"
  wt="$(cd -P "$w" && pwd)/.nightshift/worktrees/$id"
  branch="shift/$(date +%Y-%m-%d)-worktree-trial"
  [[ "${lines[2]}" == "ok worktree $wt branch $branch from ${head_before:0:7} - work there"* ]] || { echo "$output"; return 1; }
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = "$branch" ]
  [ -f "$wt/prepared" ]
  [ -f "$wt/.env.test" ]
  [ ! -e "$wt/.env" ]
  [ "$(cat "$wt/app.txt")" = app ]
  [ "$(lib ns_work_target "$w")" = "$(cd -P "$wt" && pwd)" ]
  [ "$(lib ns_owner_work_target "$w")" = "$(cd -P "$w/repo" && pwd)" ]
  [ "$(lib ns_shift_worktree_field "$w" base)" = "$head_before" ]
  # A commit on the shift lands on its branch; the owner's checkout keeps its HEAD, index and edit.
  printf 'shift change\n' >"$wt/app.txt"
  git -C "$wt" -c user.name=t -c user.email=t@example.com commit -q -am 'feat: x'
  [ "$(git -C "$w/repo" rev-parse HEAD)" = "$head_before" ]
  [ "$(git -C "$w/repo" status --porcelain)" = "$status_before" ]
  grep -q 'owner work in progress' "$w/repo/app.txt"
  # Running the phase again keeps the same worktree.
  run bash "$PREFLIGHT" --project "$w" --phase worktree
  [[ "${lines[2]}" == "ok worktree $wt branch $branch - this shift's worktree, kept" ]] || { echo "$output"; return 1; }
}

@test "a prepare that fails refuses, arms nothing and leaves no worktree or branch behind" {
  w="$(site failing '.shift.isolation = "worktree" | .shift.prepare = "echo missing tool >&2; exit 3"')"
  run bash "$PREFLIGHT" --project "$w" --phase worktree
  [ "$status" -eq 1 ]
  [[ "$output" == *'refuse worktree prepare exited 3 in '*'missing tool'* ]] || { echo "$output"; return 1; }
  [ ! -e "$w/.nightshift/run/shift-worktree" ]
  [ -z "$(git -C "$w/repo" branch --list 'shift/*')" ]
  [ "$(git -C "$w/repo" worktree list | wc -l | tr -d ' ')" -eq 1 ]
  [ ! -e "$w/.nightshift/.shift-armed" ] && [ ! -e "$w/.nightshift/run/.shift-armed" ]
}

@test "a session already in a linked worktree of the work target gets no second one" {
  w="$(site hosted '.shift.isolation = "worktree"')"
  git -C "$w/repo" worktree add -q -b host-made "$w/host-wt"
  printf '%s\n' "$(cd -P "$w/host-wt" && pwd)" >"$w/.nightshift/run/work-target"
  run bash "$PREFLIGHT" --project "$w" --phase worktree
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "ok worktree host $(cd -P "$w/host-wt" && pwd) - this session already works in its own worktree" ] || { echo "$output"; return 1; }
  [ ! -e "$w/.nightshift/worktrees" ]
}

@test "a worktree record left by another shift is never followed" {
  w="$(site stale '.shift.isolation = "worktree"')"
  bash "$PREFLIGHT" --project "$w" --phase worktree >/dev/null
  sed -i.bak 's/^shift=.*/shift=someothershift/' "$w/.nightshift/run/shift-worktree"
  [ "$(lib ns_work_target "$w")" = "$(cd -P "$w/repo" && pwd)" ]
}

@test "artifact mode ignores the setting" {
  w="$(site artifact '.shift.isolation = "worktree"')"
  printf 'artifact\n' >"$w/.nightshift/run/work-mode"
  run bash "$PREFLIGHT" --project "$w" --phase worktree
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = 'ok worktree not-applicable - artifact mode works in its folder' ]
}

@test "the shift setting reaches the policy snapshot with its shipped defaults" {
  w="$(site defaults)"
  [ "$(lib ns_policy_pref "$w" shift isolation)" = none ]
  [ "$(lib ns_policy_pref "$w" shift worktreeRoot)" = .nightshift/worktrees ]
  [ "$(lib ns_policy_pref "$w" shift copyIn)" = '[]' ]
}

@test "Status, the morning page and Archive follow the shift's worktree, and Archive never deletes the branch" {
  w="$(site lifecycle '.shift.isolation = "worktree"')"
  bash "$PREFLIGHT" --project "$w" --phase worktree >/dev/null
  id="$(lib ns_policy_shift_id "$w")"
  wt="$(lib ns_shift_worktree_field "$w" path)"
  branch="$(lib ns_shift_worktree_field "$w" branch)"
  base="$(lib ns_shift_worktree_field "$w" base)"
  repo="$(cd -P "$w/repo" && pwd)"
  printf 'feature\n' >"$wt/feature.txt"
  git -C "$wt" add feature.txt
  git -C "$wt" -c user.name=t -c user.email=t@example.com commit -q -m 'feat: feature'
  run bash "$PLUGIN/runtime/status.sh" --project "$w"
  [[ "$output" == *"isolation worktree, branch $branch"* ]] || { echo "$output"; return 1; }
  run bash "$PLUGIN/runtime/morning-receipt.sh" --project "$w"
  [[ "$output" == *"- Isolation: worktree, branch $branch from ${base:0:7}"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"- Branch: 1 file changed, 1 insertion(+)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"- Merge: git -C \"$repo\" merge --ff-only $branch"* ]] || { echo "$output"; return 1; }
  # The shift ends. Unmerged, the worktree stays and is named.
  lib ns_ended_record "$w/.nightshift" "$id" archive date
  run bash "$PLUGIN/runtime/archive-receipts.sh" --project "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept the shift worktree $wt: branch $branch is not merged into $repo"* ]] || { echo "$output"; return 1; }
  [ -d "$wt" ]
  # Merged, the folder goes and the branch stays.
  git -C "$repo" stash -q
  git -C "$repo" merge -q --ff-only "$branch"
  git -C "$repo" stash pop -q
  run bash "$PLUGIN/runtime/archive-receipts.sh" --project "$w"
  [[ "$output" == *"removed the shift worktree $wt; branch $branch is merged and kept"* ]] || { echo "$output"; return 1; }
  [ ! -e "$wt" ]
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"
  [ ! -e "$w/.nightshift/run/shift-worktree" ]
  grep -q 'owner work in progress' "$w/repo/app.txt"
}

@test "artifact mode says in Status that isolation does not apply" {
  w="$(site artifact-status '.shift.isolation = "worktree"')"
  printf 'artifact\n' >"$w/.nightshift/run/work-mode"
  run bash "$PLUGIN/runtime/status.sh" --project "$w"
  [[ "$output" == *'isolation not-applicable (artifact mode)'* ]] || { echo "$output"; return 1; }
}

@test "the workspace link a revival writes into a worktree is excluded where git reads excludes" {
  w="$(site link '.shift.isolation = "worktree"')"
  bash "$PREFLIGHT" --project "$w" --phase worktree >/dev/null
  wt="$(lib ns_shift_worktree_field "$w" path)"
  lib ns_ensure_work_target_link "$w"
  [ -f "$wt/.nightshift-link" ]
  [ -z "$(git -C "$wt" status --porcelain -- .nightshift-link)" ]
}

@test "the shift skill stages only the item's own paths" {
  grep -qF 'Stage only the paths this item changed, by name, and never commit the owner'"'"'s' \
    "$PLUGIN/skills/nightshift/SKILL.md"
  grep -qF 'pre-existing edits.' "$PLUGIN/skills/nightshift/SKILL.md"
  grep -qF 'start-preflight --phase worktree' "$PLUGIN/skills/start/SKILL.md"
}
