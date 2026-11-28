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

# ---------------------------------------------------------------- named runs
START_RUN="$PLUGIN/runtime/start-run.sh"

start_run() { # <workspace> <plan> [extra args]
  local w="$1" plan="$2"
  shift 2
  (cd "$w" && env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$w" \
    bash "$START_RUN" --project "$w" --plan "$plan" --host claude "$@")
}

# fake_agent — a headless worker stand-in: records where it runs, its run and its lease, then stays
# alive long enough to be found. Echoes its path.
fake_agent() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/fake-agent" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$PWD" "$NIGHTSHIFT_RUN" "$NIGHTSHIFT_LEASE_GENERATION" "$NIGHTSHIFT_LEASE_NONCE" >>"$FAKE_AGENT_CALLS"
sleep 30
STUB
  chmod +x "$bin/fake-agent"
  printf '%s' "$bin/fake-agent"
}

# stop_run_processes <workspace> <run> — the run's watchman and worker, ended after the test.
stop_run_processes() {
  local f pid
  for f in "$1/.nightshift/runs/$2/run/.watchman" "$1/.nightshift/runs/$2/run/.shift-lease"; do
    [ -f "$f" ] || continue
    if [ "${f##*/}" = .watchman ]; then pid="$(sed -n 1p "$f")"; else pid="$(sed -n 5p "$f")"; fi
    case "$pid" in '' | *[!0-9]*) ;; *) pkill -P "$pid" 2>/dev/null || :; kill "$pid" 2>/dev/null || : ;; esac
  done
}

@test "two plans started from a dirty owner checkout get two run folders and two worktrees" {
  w="$(runs_site "two plans")"
  before="$(owner_state "$w/repo")"
  run start_run "$w" "Export CSV"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'ok run export-csv'
  run start_run "$w" "Dark mode"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'ok run dark-mode'
  [ -f "$w/.nightshift/runs/export-csv/punch-list.md" ]
  [ -f "$w/.nightshift/runs/dark-mode/punch-list.md" ]
  [ ! -e "$w/.nightshift/staging/plans/export-csv.md" ]
  [ ! -e "$w/.nightshift/staging/plans/dark-mode.md" ]
  # Each run works in its own worktree, on its own branch.
  [ "$(git -C "$w/repo" worktree list | wc -l | tr -d ' ')" = 3 ]
  git -C "$w/repo" show-ref --verify --quiet "refs/heads/shift/$(date +%Y-%m-%d)-export-csv"
  git -C "$w/repo" show-ref --verify --quiet "refs/heads/shift/$(date +%Y-%m-%d)-dark-mode"
  [ "$(NIGHTSHIFT_RUN=export-csv lib ns_work_target "$w")" != "$(NIGHTSHIFT_RUN=dark-mode lib ns_work_target "$w")" ]
  # The owner's checkout, index and files are exactly as they were.
  [ "$(owner_state "$w/repo")" = "$before" ]
  # Each run's rules give it its worktree; the shared rules are unchanged.
  [ "$(jq -r .shift.isolation "$w/.nightshift/runs/export-csv/rules.json")" = worktree ]
  [ "$(jq -r .shift.isolation "$w/.nightshift/rules.json")" = none ]
}

@test "a failed worktree step leaves the plan staged and the owner's checkout unchanged" {
  w="$(runs_site "failed worktree")"
  git -C "$w/repo" branch "shift/$(date +%Y-%m-%d)-export-csv"
  before="$(owner_state "$w/repo")"
  run start_run "$w" "Export CSV"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^refuse worktree '
  [ -f "$w/.nightshift/staging/plans/export-csv.md" ]
  [ "$(git -C "$w/repo" worktree list | wc -l | tr -d ' ')" = 1 ]
  [ "$(owner_state "$w/repo")" = "$before" ]
  # Run again once the cause is gone: the same run is finished, not a second one made.
  git -C "$w/repo" branch -D "shift/$(date +%Y-%m-%d)-export-csv" >/dev/null
  run start_run "$w" "Export CSV"
  [ "$status" -eq 0 ]
  [ "$(ls "$w/.nightshift/runs")" = export-csv ]
  [ ! -e "$w/.nightshift/staging/plans/export-csv.md" ]
}

# A background start leaves a worker and a watchman running; each call closes Bats's descriptor 3 so
# those processes do not hold the test open.
@test "a background start cut short after its run folder exists, then retried, leaves exactly one worker" {
  w="$(runs_site "background run")"
  agent="$(fake_agent)"
  export FAKE_AGENT_CALLS="$BATS_TEST_TMPDIR/agent-calls"
  # The worker cannot start: the run folder and its punch list exist, the plan stays staged, and
  # nothing is armed.
  run env NIGHTSHIFT_WATCH_AGENT="$BATS_TEST_TMPDIR/bin/missing-agent" bash -c '
    cd "$1" && env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$1" \
      bash "$2" --project "$1" --plan "Dark mode" --host claude --background' _ "$w" "$START_RUN" 3>&-
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^refuse worker .*missing-agent is not installed'
  [ -f "$w/.nightshift/runs/dark-mode/punch-list.md" ]
  [ -f "$w/.nightshift/staging/plans/dark-mode.md" ]
  [ ! -e "$w/.nightshift/runs/dark-mode/run/.shift-armed" ]
  # Retried with a worker that starts: one worker, in the run's worktree, holding the run's lease.
  for _ in 1 2; do
    run env NIGHTSHIFT_WATCH_AGENT="$agent" bash -c '
      cd "$1" && env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$1" \
        bash "$2" --project "$1" --plan "Dark mode" --host claude --background' _ "$w" "$START_RUN" 3>&-
    [ "$status" -eq 0 ]
  done
  printf '%s\n' "$output" | grep -q '^ok worker already running for dark-mode'
  sleep 1
  stop_run_processes "$w" dark-mode
  [ "$(wc -l <"$FAKE_AGENT_CALLS" | tr -d ' ')" = 1 ]
  IFS='|' read -r where run_name generation nonce <"$FAKE_AGENT_CALLS"
  [ "$run_name" = dark-mode ]
  [ "$where" = "$(NIGHTSHIFT_RUN=dark-mode lib ns_work_target "$w")" ]
  # The host names the worker's worktree as its project; the worktree leads its hooks back to the
  # workspace, and git does not see the link as a change.
  [ "$(lib ns_workspace_root "$where")" = "$w" ]
  [ -z "$(git -C "$where" status --porcelain)" ]
  [ "$generation" = "$(sed -n 3p "$w/.nightshift/runs/dark-mode/run/.shift-lease")" ]
  [ "$nonce" = "$(sed -n 4p "$w/.nightshift/runs/dark-mode/run/.shift-lease")" ]
  [ -f "$w/.nightshift/runs/dark-mode/run/.shift-armed" ]
  [ ! -e "$w/.nightshift/staging/plans/dark-mode.md" ]
}

@test "a background worker in a worktree is given the workspace that holds its run folder" {
  w="$(runs_site "added folder")"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >>"$FAKE_AGENT_CALLS"
sleep 30
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export FAKE_AGENT_CALLS="$BATS_TEST_TMPDIR/agent-calls"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c '
    cd "$1" && env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID -u NIGHTSHIFT_WATCH_AGENT CLAUDE_PROJECT_DIR="$1" \
      bash "$2" --project "$1" --plan "Dark mode" --host claude --background' _ "$w" "$START_RUN" 3>&-
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  sleep 1
  stop_run_processes "$w" dark-mode
  IFS='|' read -r where args <"$FAKE_AGENT_CALLS"
  [ "$where" = "$(NIGHTSHIFT_RUN=dark-mode lib ns_work_target "$w")" ]
  case "$args" in "--add-dir $(cd -P "$w" && pwd) -p "*) ;; *) echo "$args"; return 1 ;; esac
}

@test "a background worker that exits at once is reported with its own last words, and nothing stays armed" {
  w="$(runs_site "worker exits")"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nprintf "Workspace Trust Required\\nPass --trust if you trust this directory\\n"\nexit 1\n' \
    >"$BATS_TEST_TMPDIR/bin/untrusted-agent"
  chmod +x "$BATS_TEST_TMPDIR/bin/untrusted-agent"
  run env NIGHTSHIFT_WATCH_AGENT="$BATS_TEST_TMPDIR/bin/untrusted-agent" NIGHTSHIFT_WORKER_SETTLE_SECONDS=2 bash -c '
    cd "$1" && env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$1" \
      bash "$2" --project "$1" --plan "Dark mode" --host claude --background' _ "$w" "$START_RUN" 3>&-
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'refuse worker the claude CLI exited at once: Workspace Trust Required Pass --trust if you trust this directory' ||
    { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -q '^repair run .*untrusted-agent once in .* and settle what it asks, then run this again$'
  ! printf '%s\n' "$output" | grep -q '^ok worker started' || false
  [ ! -e "$w/.nightshift/runs/dark-mode/run/.shift-armed" ]
  [ ! -e "$w/.nightshift/runs/dark-mode/run/.watchman" ]
}

# stop_shift <workspace> — end the shift as clock-out does after a stop-work order: the policy is
# archived, the ending names the shift, and STOP stays behind.
stop_shift() {
  local w="$1" id
  id="$(lib ns_policy_shift_id "$w")"
  lib ns_ended_record "$w/.nightshift" "$id" archive date >/dev/null
  bash "$PLUGIN/runtime/shift-policy.sh" --project "$w" archive >/dev/null
  : >"$(lib ns_layout_path "$w/.nightshift" stop)"
}

@test "a stopped shift started again keeps its worktree, its branch, its commits and its file map" {
  w="$(site resumed '.shift.isolation = "worktree" | .receipts.evidence.fileMap = "on"')"
  bash "$PREFLIGHT" --project "$w" --phase worktree >/dev/null
  wt="$(lib ns_shift_worktree_field "$w" path)"
  branch="$(lib ns_shift_worktree_field "$w" branch)"
  base="$(lib ns_filemap_field "$w" base)"
  [ -n "$base" ]
  printf 'shift change\n' >"$wt/app.txt"
  git -C "$wt" -c user.name=t -c user.email=t@example.com commit -q -am 'feat: x'
  work="$(git -C "$wt" rev-parse HEAD)"
  stop_shift "$w"
  run bash "$PREFLIGHT" --project "$w" --host claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  bash "$PREFLIGHT" --project "$w" --phase snapshot >/dev/null
  run bash "$PREFLIGHT" --project "$w" --phase worktree
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "${lines[2]}" == "ok worktree $wt branch $branch - this shift's worktree, kept" ]] || { echo "$output"; return 1; }
  # The record and the file map now name the new shift, and the map still starts where the shift did.
  id="$(lib ns_policy_shift_id "$w")"
  [ "$(lib ns_shift_worktree_field "$w" shift)" = "$id" ]
  [ "$(lib ns_filemap_field "$w" shift)" = "$id" ]
  [ "$(lib ns_filemap_field "$w" base)" = "$base" ]
  [ "$(git -C "$wt" rev-parse HEAD)" = "$work" ]
  [ "$(lib ns_work_target "$w")" = "$wt" ]
}

@test "a run stopped part way is finished by start-run on the same worktree and branch" {
  w="$(runs_site "resumed run")"
  run start_run "$w" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  wt="$(NIGHTSHIFT_RUN=export-csv lib ns_shift_worktree_field "$w" path)"
  printf 'run change\n' >"$wt/run.txt"
  git -C "$wt" add run.txt
  git -C "$wt" -c user.name=t -c user.email=t@example.com commit -q -m 'feat: run'
  NIGHTSHIFT_RUN=export-csv stop_shift "$w"
  run start_run "$w" "Export CSV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qxF "ok worktree $wt branch shift/$(date +%Y-%m-%d)-export-csv - this shift's worktree, kept" ||
    { echo "$output"; return 1; }
  [ "$(git -C "$w/repo" worktree list | wc -l | tr -d ' ')" = 2 ]
  [ -f "$wt/run.txt" ]
}
