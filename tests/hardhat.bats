load helpers

PRE="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/preflight-needs.sh"
LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"

# Elevation has no NIGHTSHIFT_ session lever by design: the owner's own files are the only
# switches, so these fixtures write the files a real owner writes.

# rules_elevation <project> <category> <policy>
rules_elevation() {
  local f="$1/.nightshift/rules.json"
  jq --arg c "$2" --arg v "$3" '.elevation[$c].policy = $v' "$f" >"$f.new"
  mv "$f.new" "$f"
}

# rules_pattern <project> <category> <grep -E pattern>
rules_pattern() {
  local f="$1/.nightshift/rules.json"
  jq --arg c "$2" --arg v "$3" '.elevation[$c].pattern = $v' "$f" >"$f.new"
  mv "$f.new" "$f"
}

SHIFT_ID=9f2c40ab77e51d63

# shift_policy <project> [allowances JSON array] — tonight's snapshot, as composition writes it.
shift_policy() {
  jq -nc --arg s "$SHIFT_ID" --argjson a "${2:-[]}" \
    '{schemaVersion:1,shiftId:$s,createdAt:"2026-09-02T02:30:00Z",source:"composition",
      deadlineEpoch:null,verificationLevel:"final",toolingPolicy:"existing-tools",allowances:$a}' \
    >"$1/.nightshift/shift-policy.json"
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1
}

# plan_digest <work-target> <command>... — the digest an exact-plan allowance is bound by:
# sha256 over canonical {commands, shiftId, workTarget}.
plan_digest() {
  local target="$1"
  shift
  jq -nSc --arg t "$target" --arg s "$SHIFT_ID" \
    '$ARGS.positional as $c | {commands:$c,shiftId:$s,workTarget:$t}' --args "$@" |
    tr -d '\n' | sha256_stdin
}

work_target() { bash -c '. "$1"; ns_work_target "$2"' _ "$LIB" "$1"; }

deny_reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason'; }

# The sentence the agent acts on, in full. The hook expands the two .nightshift paths it names
# against the resolved workspace, so the expectation resolves the fixture the same way.
elevation_message() { # <project> <category>
  local ws
  ws="$(cd -P "$1" && pwd -P)"
  printf "BLOCKED: this command needs the '%s' elevation category, which is denied for this shift. The owner allows it in %s/.nightshift/rules.json (elevation.%s.policy) or for one shift in shift-policy.json before arming. Park the item in %s/.nightshift/parking-lot.md as \"needs allowance: %s\" and keep working." \
    "$2" "$ws" "$2" "$ws" "$2"
}

@test "push is allowed by default during an active shift" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git push origin main"
  is_allow
}

@test "push is allowed by default when every box is ticked" {
  p="$(new_project)"
  punch_done "$p"
  run hardhat_bash "$p" "git push"
  is_allow
}

@test "allows push when there is no punch list" {
  p="$(new_project)"
  run hardhat_bash "$p" "git push"
  is_allow
}

@test "the no-push recipe denies push during an active shift" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git push origin main" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
}

@test "a commit message containing a forbidden word is not a match" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git commit -m 'push it real good'" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_allow
}

@test "protected-dir git write is denied when configured" {
  p="$(new_project)"
  punch_open "$p"
  mkdir -p "$p/ai_docs"
  printf 'secret\n' >"$p/ai_docs/secret"
  run hardhat_bash "$p" "git add ai_docs/secret" NIGHTSHIFT_PROTECTED_DIRS="ai_docs notes"
  is_deny "$output"
}

@test "protectedDirs inspects the paths Git would add or commit" {
  p="$(new_project)"
  punch_open "$p"
  mkdir -p "$p/ai_docs"
  printf 'secret\n' >"$p/ai_docs/secret.txt"
  run hardhat_bash "$p" "git add -A" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
  run hardhat_bash "$p" "git add ." NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
  git -C "$p" add ai_docs/secret.txt
  run hardhat_bash "$p" "git commit -m protected-bypass" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
  git -C "$p" reset -q
  printf 'also\n' >"$p/tracked.txt"
  git -C "$p" add tracked.txt
  git -C "$p" commit -q -m seed
  printf 'dirty\n' >"$p/tracked.txt"
  mkdir -p "$p/ai_docs"
  printf 'secret\n' >"$p/ai_docs/secret.txt"
  git -C "$p" add ai_docs/secret.txt
  run hardhat_bash "$p" "git commit -am all" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
  git -C "$p" reset -q
  printf 'safe\n' >"$p/ok.txt"
  git -C "$p" add ok.txt
  run hardhat_bash "$p" "git commit -m ok" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_allow
  run hardhat_bash "$p" "git tag ai_docs" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
  mkdir -p "$p/ai_docs"
  printf 'secret\n' >"$p/ai_docs/secret.txt"
  git -C "$p" add ai_docs/secret.txt
  git -C "$p" commit -q -m protected
  rm -f "$p/ai_docs/secret.txt"
  run hardhat_bash "$p" "git add -A" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
}

@test "a --git-dir add is denied when a protected directory is configured" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git --git-dir=/somewhere/else/.git add x" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
  printf '%s' "$output" | grep -qF 'protected-directory guard cannot verify'
}

@test "a --work-tree commit is denied when a protected directory is configured" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git --work-tree=/somewhere/else commit -am x" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
  printf '%s' "$output" | grep -qF 'protected-directory guard cannot verify'
}

@test "protected-dir check is skipped when unset" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git add ai_docs/secret"
  is_allow
}

@test "commit under the wrong identity is denied when configured" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git commit -m x" NIGHTSHIFT_EXPECTED_EMAIL="owner@nope.io"
  is_deny "$output"
}

@test "commit under the expected identity is allowed" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git commit -m x" NIGHTSHIFT_EXPECTED_EMAIL="dev@example.com"
  is_allow
}

@test "a staged never-commit pattern is denied when configured" {
  p="$(new_project)"
  punch_open "$p"
  printf 'API_KEY=sk-secret\n' >"$p/leak.txt"
  git -C "$p" add leak.txt
  run hardhat_bash "$p" "git commit -m x" NIGHTSHIFT_NEVER_COMMIT_PATTERNS="sk-secret|API_KEY"
  is_deny "$output"
}

@test "neverCommitPatterns inspects the exact commit Git would write" {
  p="$(new_project)"
  punch_open "$p"
  printf 'clean\n' >"$p/leak.txt"
  git -C "$p" add leak.txt
  git -C "$p" commit -q -m seed
  printf 'API_KEY=sk-secret\n' >"$p/leak.txt"
  run hardhat_bash "$p" "git commit -m pathspec-bypass leak.txt" NIGHTSHIFT_NEVER_COMMIT_PATTERNS="sk-secret|API_KEY"
  is_deny "$output"
  run hardhat_bash "$p" "git commit -m x --only leak.txt" NIGHTSHIFT_NEVER_COMMIT_PATTERNS="sk-secret"
  is_deny "$output"
  run hardhat_bash "$p" "git commit -m x --include leak.txt" NIGHTSHIFT_NEVER_COMMIT_PATTERNS="sk-secret"
  is_deny "$output"
  run hardhat_bash "$p" "git commit -m index-only" NIGHTSHIFT_NEVER_COMMIT_PATTERNS="sk-secret"
  is_allow
}

@test "never-commit pattern check is skipped when unset" {
  p="$(new_project)"
  punch_open "$p"
  printf 'API_KEY=sk-secret\n' >"$p/leak.txt"
  git -C "$p" add leak.txt
  run hardhat_bash "$p" "git commit -m x"
  is_allow
}

@test "AskUserQuestion is denied during an active shift" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_ask "$p"
  is_deny "$output"
  printf '%s' "$output" | grep -qF "$p/.nightshift/parking-lot.md"
}

@test "AskUserQuestion is allowed with no active shift" {
  p="$(new_project)"
  punch_done "$p"
  run hardhat_ask "$p"
  is_allow
}

@test "an open checkbox outside Items does not activate the hardhat" {
  p="$(new_project)"
  printf '%s\n' '- [ ] planning example' '## Items' '- [x] **1. done.**' >"$p/.nightshift/punch-list.md"
  run hardhat_ask "$p"
  is_allow
}

@test "an open checkbox under Items activates the hardhat" {
  p="$(new_project)"
  printf '%s\n' '- [x] planning example' '## Items' '- [ ] **1. open.**' >"$p/.nightshift/punch-list.md"
  run hardhat_ask "$p"
  is_deny "$output"
}

@test "open Items remain inert until the shift is armed" {
  p="$(new_project)"
  punch_open "$p"
  rm "$p/.nightshift/.shift-armed"
  run hardhat_ask "$p"
  is_allow
}

@test "STOP keeps hardhat active until ENDED even with no open boxes" {
  p="$(new_project)"
  punch_done "$p"
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_allow
  : >"$p/.nightshift/STOP"
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
  : >"$p/.nightshift/.ended"
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_allow
}

@test "the no-push recipe holds when jq is absent and Python parses tool rules" {
  p="$(new_project)"
  punch_open "$p"
  bindir="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$bindir"
  for b in bash grep sed printf cat head git env python3; do
    src="$(command -v "$b")" && ln -sf "$src" "$bindir/$b"
  done
  input="$(jq -nc '{tool_name:"Bash",tool_input:{command:"git push"}}')"
  out="$(printf '%s' "$input" | env PATH="$bindir" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push' CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
}

# A stop-work order is a request, not the ending: the agent keeps working until its next stop
# attempt, so the site rules must stay armed across that window. The gate writes .ended when it
# actually releases, and only that stands them down.

@test "a pending stop-work order keeps the site rules armed" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/STOP"
  run hardhat_bash "$p" "git add ai_docs/x" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
  run hardhat_ask "$p"
  is_deny "$output"
}

@test "the site rules stand down once the gate has ended the shift" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/STOP"
  run gate "$p"                       # the release that actually ends it
  [ -f "$p/.nightshift/.ended" ]
  run hardhat_bash "$p" "git add ai_docs/x" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_allow
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_allow
}

@test "a symlink ended marker keeps the site rules armed" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/ended-plant"
  ln -s ended-plant "$p/.nightshift/.ended"
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
}

@test "forbidden-commands pattern denies during an active shift" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "docker system prune -af" NIGHTSHIFT_FORBIDDEN_COMMANDS='rm -rf|docker|kubectl'
  is_deny "$output"
}

@test "an invalid forbidden-command pattern names the session repair" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git status" NIGHTSHIFT_FORBIDDEN_COMMANDS='(unclosed'
  is_deny "$output"
  printf '%s' "$output" | grep -qF 'NIGHTSHIFT_FORBIDDEN_COMMANDS is not a valid extended regular expression'
  printf '%s' "$output" | grep -qF 'Fix the pattern in your session settings.'
}

@test "forbidden-commands rule is shift-scoped: inert once every box is ticked" {
  p="$(new_project)"
  punch_done "$p"
  run hardhat_bash "$p" "docker ps" NIGHTSHIFT_FORBIDDEN_COMMANDS='docker'
  is_allow
}

@test "a scary-looking command passes when the forbidden list is unset" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "kubectl delete pod api-7f9"
  is_allow
}

@test "deny stays valid JSON when the committer email contains a quote" {
  p="$(new_project)"
  punch_open "$p"
  git -C "$p" config user.email 'we"ird@example.com'
  run hardhat_bash "$p" "git commit -m x" NIGHTSHIFT_EXPECTED_EMAIL="owner@nope.io"
  is_deny "$output"
  printf '%s' "$output" | jq -e . >/dev/null
}

@test "deny stays valid JSON when a protected dir name contains a quote" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" 'git add we"ird/x' NIGHTSHIFT_PROTECTED_DIRS='we"ird'
  is_deny "$output"
  printf '%s' "$output" | jq -e . >/dev/null
}

# --- the recommended layout: project dir is a plain folder, the repo sits one level down ---

@test "workspace layout: a wrong committer identity is denied" {
  w="$(new_workspace)"
  punch_open "$w"
  run hardhat_bash "$w" "git commit -m x" NIGHTSHIFT_EXPECTED_EMAIL="owner@nope.io"
  is_deny "$output"
  # the repo's identity, not whatever the machine's global config happens to hold
  printf '%s' "$output" | grep -q "dev@example.com"
}

@test "workspace layout: the expected committer identity is allowed" {
  w="$(new_workspace)"
  punch_open "$w"
  run hardhat_bash "$w" "git commit -m x" NIGHTSHIFT_EXPECTED_EMAIL="dev@example.com"
  is_allow
}

@test "workspace layout: a staged never-commit pattern is denied" {
  w="$(new_workspace)"
  punch_open "$w"
  printf 'API_KEY=sk-secret\n' >"$w/repo/leak.txt"
  git -C "$w/repo" add leak.txt
  run hardhat_bash "$w" "git commit -m x" NIGHTSHIFT_NEVER_COMMIT_PATTERNS="sk-secret|API_KEY"
  is_deny "$output"
}

@test "workspace layout: a clean staged diff commits" {
  w="$(new_workspace)"
  punch_open "$w"
  printf 'ok\n' >"$w/repo/fine.txt"
  git -C "$w/repo" add fine.txt
  run hardhat_bash "$w" "git commit -m x" NIGHTSHIFT_NEVER_COMMIT_PATTERNS="sk-secret|API_KEY"
  is_allow
}

@test "the receipts repo is never mistaken for the code repo" {
  w="$(new_workspace)"
  receipts_init "$w"
  punch_open "$w"
  run hardhat_bash "$w" "git commit -m x" NIGHTSHIFT_EXPECTED_EMAIL="dev@example.com"
  is_allow
}

@test "the tool's cwd picks the repo when several sit in the workspace" {
  w="$(new_workspace)"
  add_repo "$w" other
  punch_open "$w"
  printf 'API_KEY=sk-secret\n' >"$w/repo/leak.txt"
  git -C "$w/repo" add leak.txt
  run hardhat_bash_cwd "$w" "$w/repo" "git commit -m x" NIGHTSHIFT_NEVER_COMMIT_PATTERNS="sk-secret"
  is_deny "$output"
}

@test "an undecidable repo fails closed rather than waving the commit through" {
  w="$(new_workspace)"
  add_repo "$w" other
  punch_open "$w"
  run hardhat_bash "$w" "git commit -m x" NIGHTSHIFT_EXPECTED_EMAIL="dev@example.com"
  is_deny "$output"
  printf '%s' "$output" | grep -q "cannot tell which git repository"
}

@test "an unresolvable repo leaves the string-matching guards untouched" {
  w="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$w/.nightshift"
  : >"$w/.nightshift/.shift-armed"
  punch_open "$w"
  run hardhat_bash "$w" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
}

# The commit guards resolve `git -C` and `cd X &&`, but --git-dir/--work-tree relocate a commit
# past that resolution — the guard would inspect one repository while the commit lands in
# another. Unverifiable must mean denied, not misread.
@test "a --git-dir commit is denied when a commit guard is configured" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git --git-dir=/somewhere/else/.git commit -m x" \
    NIGHTSHIFT_EXPECTED_EMAIL=dev@example.com
  is_deny "$output"
}

@test "a --work-tree commit is denied when a commit guard is configured" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git --work-tree=/somewhere/else commit -am x" \
    NIGHTSHIFT_NEVER_COMMIT_PATTERNS='SECRET'
  is_deny "$output"
}

@test "--git-dir passes when no commit guard is configured" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git --git-dir=/somewhere/else/.git commit -m x"
  is_allow
}

@test "a commit message mentioning --git-dir is not a match" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git commit -m 'document the --git-dir flag'" \
    NIGHTSHIFT_EXPECTED_EMAIL=dev@example.com
  is_allow
}

# The identity guard reads the repo's config, and a command line can override identity past that
# read. Every visible override form is denied when an expected identity is configured.
@test "an inline -c user.email override is denied when an identity is expected" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git -c user.email=evil@example.com commit -m x" \
    NIGHTSHIFT_EXPECTED_EMAIL=dev@example.com
  is_deny "$output"
}

@test "an --author override is denied when an identity is expected" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git commit --author='Evil <evil@example.com>' -m x" \
    NIGHTSHIFT_EXPECTED_EMAIL=dev@example.com
  is_deny "$output"
}

@test "a GIT_AUTHOR_EMAIL prefix is denied when an identity is expected" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "GIT_AUTHOR_EMAIL=evil@example.com git commit -m x" \
    NIGHTSHIFT_EXPECTED_EMAIL=dev@example.com
  is_deny "$output"
}

# The no-push recipe in docs/knobs.md is `git .*push` so that config injection cannot slip between the
# words. This pins the recipe itself.
@test "the isolated-branch recipe denies default-branch checkout, merge, and push" {
  p="$(new_project)"
  punch_open "$p"
  recipe="$(jq -r '.rules.forbiddenCommands' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/profiles/isolated-branch.json")"
  run hardhat_bash "$p" "git checkout main" NIGHTSHIFT_FORBIDDEN_COMMANDS="$recipe"
  is_deny "$output"
  run hardhat_bash "$p" "git switch master" NIGHTSHIFT_FORBIDDEN_COMMANDS="$recipe"
  is_deny "$output"
  run hardhat_bash "$p" "git checkout origin/main" NIGHTSHIFT_FORBIDDEN_COMMANDS="$recipe"
  is_deny "$output"
  run hardhat_bash "$p" "git merge feature" NIGHTSHIFT_FORBIDDEN_COMMANDS="$recipe"
  is_deny "$output"
  run hardhat_bash "$p" "git -C /tmp checkout main" NIGHTSHIFT_FORBIDDEN_COMMANDS="$recipe"
  is_deny "$output"
  run hardhat_bash "$p" "git -c protocol.file.allow=always merge feature" \
    NIGHTSHIFT_FORBIDDEN_COMMANDS="$recipe"
  is_deny "$output"
  run hardhat_bash "$p" "git -c http.proxy=x push origin main" NIGHTSHIFT_FORBIDDEN_COMMANDS="$recipe"
  is_deny "$output"
  run hardhat_bash "$p" "git checkout -b nightshift/product-evolution-2026-08-27" \
    NIGHTSHIFT_FORBIDDEN_COMMANDS="$recipe"
  is_allow
  run hardhat_bash "$p" "git commit -m 'merge and push later'" NIGHTSHIFT_FORBIDDEN_COMMANDS="$recipe"
  is_allow
}

@test "the no-push recipe catches git -c k=v push" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git -c http.proxy=x push origin main" \
    NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push'
  is_deny "$output"
}

# The shift records its own identity: the first session to work under an active shift writes
# .shift-session, and a second tab never overwrites it — the watchman must know WHICH
# conversation to read and revive, not guess at the newest.
@test "the first working session records itself and is never overwritten" {
  p="$(new_project)"
  punch_open "$p"
  jq -nc '{tool_name:"Bash",session_id:"first-tab",transcript_path:"/tmp/a.jsonl",tool_input:{command:"echo hi"}}' |
    CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "first-tab" ]
  jq -nc '{tool_name:"Bash",session_id:"second-tab",transcript_path:"/tmp/b.jsonl",tool_input:{command:"echo hi"}}' |
    CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "first-tab" ]
}

@test "a symlink shift-session does not block the first working session" {
  p="$(new_project)"
  punch_open "$p"
  printf 'planted-tab\n/tmp/plant.jsonl\n99999\nstart\nclaude\n' >"$p/.nightshift/session-plant"
  ln -s session-plant "$p/.nightshift/.shift-session"
  jq -nc '{tool_name:"Bash",session_id:"first-tab",transcript_path:"/tmp/a.jsonl",tool_input:{command:"echo hi"}}' |
    CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
  [ -f "$p/.nightshift/.shift-session" ]
  [ ! -L "$p/.nightshift/.shift-session" ]
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "first-tab" ]
}

# Cursor IDE loads the Claude marketplace plugin beside the Cursor host plugin. Claude-entry
# hooks must stand down so they cannot lease as host claude on a Cursor transcript.
@test "claude hardhat stands down on a cursor transcript without claiming the lease" {
  p="$(new_project)"
  punch_open "$p"
  jq -nc '{tool_name:"Bash",session_id:"cursor-tab",transcript_path:"/Users/o/.cursor/projects/x/agent-transcripts/u/u.jsonl",tool_input:{command:"echo hi"}}' |
    CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
  [ ! -f "$p/.nightshift/.shift-session" ]
  [ ! -f "$p/.nightshift/.shift-lease" ]
}

@test "a claude transcript keeps recording the claude host" {
  p="$(new_project)"
  punch_open "$p"
  jq -nc '{tool_name:"Bash",session_id:"claude-tab",transcript_path:"/Users/o/.claude/projects/x/u.jsonl",tool_input:{command:"echo hi"}}' |
    CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
  [ "$(sed -n 5p "$p/.nightshift/.shift-session")" = "claude" ]
}

@test "no active shift means no session record" {
  p="$(new_project)"
  punch_done "$p"
  jq -nc '{tool_name:"Bash",session_id:"s1",transcript_path:"",tool_input:{command:"echo hi"}}' |
    CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
  [ ! -f "$p/.nightshift/.shift-session" ]
}

# v0.5.2: the record carries process identity — the claude ancestor's pid and start time, found
# by walking the hook's own ancestry. A stubbed ps makes the walk deterministic here.
@test "the record claims the claude ancestor's pid and start time" {
  p="$(new_project)"
  punch_open "$p"
  stub="$BATS_TEST_TMPDIR/pidbin"
  mkdir -p "$stub"
  cat >"$stub/ps" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *lstart*) echo "  Mon Jan  1 00:00:00 2026  " ;;
  *comm*) echo "claude" ;;
  *) echo 1 ;;
esac
STUB
  chmod +x "$stub/ps"
  jq -nc '{tool_name:"Bash",session_id:"pid-tab",transcript_path:"/tmp/t.jsonl",tool_input:{command:"echo hi"}}' |
    PATH="$stub:$PATH" CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "pid-tab" ]
  sed -n 3p "$p/.nightshift/.shift-session" | grep -qE '^[0-9]+$'
  [ "$(sed -n 4p "$p/.nightshift/.shift-session")" = "Mon Jan  1 00:00:00 2026" ]
}

@test "no claude ancestor leaves the pid lines empty, never breaks the record" {
  p="$(new_project)"
  punch_open "$p"
  jq -nc '{tool_name:"Bash",session_id:"bare-tab",transcript_path:"",tool_input:{command:"echo hi"}}' |
    CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "bare-tab" ]
  [ "$(wc -l <"$p/.nightshift/.shift-session")" -eq 5 ]
  [ -z "$(sed -n 3p "$p/.nightshift/.shift-session")" ]
  [ "$(sed -n 5p "$p/.nightshift/.shift-session")" = "claude" ]
}

# The claim is an exclusive create: two racing first sessions cannot interleave — one record
# lands whole, id and transcript from the same writer.
@test "two racing identity claims land exactly one whole record" {
  for round in 1 2 3; do
    p="$(new_project "race$round")"
    punch_open "$p"
    jq -nc '{tool_name:"Bash",session_id:"race-a",transcript_path:"/tmp/a.jsonl",tool_input:{command:"echo hi"}}' |
      CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh" &
    one=$!
    jq -nc '{tool_name:"Bash",session_id:"race-b",transcript_path:"/tmp/b.jsonl",tool_input:{command:"echo hi"}}' |
      CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh" &
    two=$!
    wait "$one" "$two"
    [ "$(wc -l <"$p/.nightshift/.shift-session")" -eq 5 ]
    [ "$(sed -n 5p "$p/.nightshift/.shift-session")" = "claude" ]
    sid="$(sed -n 1p "$p/.nightshift/.shift-session")"
    tpath="$(sed -n 2p "$p/.nightshift/.shift-session")"
    case "$sid" in
      race-a) [ "$tpath" = "/tmp/a.jsonl" ] ;;
      race-b) [ "$tpath" = "/tmp/b.jsonl" ] ;;
      *) false ;;
    esac
  done
}

# ---- the site rules bind the shift's session; other conversations keep their tools ----

@test "another conversation is untouched by the site rules" {
  p="$(new_project)"
  punch_open "$p"
  printf 'the-shift\n\n\n\n' >"$p/.nightshift/.shift-session"
  out="$(jq -nc '{tool_name:"AskUserQuestion",tool_input:{},session_id:"helper-tab"}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ] # the question is the helper's to ask
  out="$(jq -nc '{tool_name:"Bash",tool_input:{command:"git push origin main"},session_id:"helper-tab"}' |
    env NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push' CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ] # the owner's other tab pushes if the owner pleases
}

@test "the shift session itself still answers to the site rules" {
  p="$(new_project)"
  punch_open "$p"
  printf 'the-shift\n\n\n\n' >"$p/.nightshift/.shift-session"
  out="$(jq -nc '{tool_name:"Bash",tool_input:{command:"git push origin main"},session_id:"the-shift"}' |
    env NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push' CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
}

@test "a tool call without a session id keeps the conservative reading — rules apply" {
  p="$(new_project)"
  punch_open "$p"
  printf 'the-shift\n\n\n\n' >"$p/.nightshift/.shift-session"
  run hardhat_bash "$p" "git push origin main" NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push'
  is_deny "$output"
}

@test "a passive catch-all tool cannot claim the shift session" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc '{tool_name:"Read",tool_input:{file_path:"README.md"},session_id:"helper-tab"}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ]
  [ ! -f "$p/.nightshift/.shift-session" ]
  out="$(jq -nc '{tool_name:"Bash",tool_input:{command:"pwd"},session_id:"shift-tab"}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ]
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "shift-tab" ]
}

# ---- the tool rules map: one knob, per-tool messages, owner-only (env, fixed at start) ----

@test "the map words the park denial per tool" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_ask "$p" NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"park it and keep welding"}'
  is_deny "$output"
  printf '%s' "$output" | grep -q "park it and keep welding"
}

@test "an empty message in the map lifts the question rule" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_ask "$p" \
    NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"","request_user_input":"codex only"}'
  is_allow
}

@test "a missing Claude question key is a configuration error, not a hidden policy" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_ask "$p" NIGHTSHIFT_TOOL_RULES='{"request_user_input":"codex only"}'
  is_deny "$output"
  printf '%s' "$output" | grep -q "missing the required 'AskUserQuestion' entry"
}

@test "a listed tool is denied with its own message; an unlisted one passes" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc '{tool_name:"WebSearch",tool_input:{}}' |
    env NIGHTSHIFT_TOOL_RULES='{"WebSearch":"no browsing tonight"}' CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "no browsing tonight"
  out="$(jq -nc '{tool_name:"WebFetch",tool_input:{query:"how to git push"}}' |
    env NIGHTSHIFT_TOOL_RULES='{"WebSearch":"no browsing tonight"}' \
      NIGHTSHIFT_FORBIDDEN_COMMANDS='git push' CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ]
}

@test "a nested question-tool name cannot bypass the caller's own rule" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc '{tool_name:"mcp__router__invoke",tool_input:{tool_name:"AskUserQuestion"}}' |
    env NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"","request_user_input":"","mcp__router__invoke":"router blocked"}' \
      CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "router blocked"
}

@test "toolDeny can block Bash itself before command-pattern rules" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git status" \
    NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"","request_user_input":"","Bash":"no shell tonight"}'
  is_deny "$output"
  printf '%s' "$output" | grep -q "no shell tonight"
}

@test "a map that is not a JSON object denies loudly instead of waving through" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc '{tool_name:"WebSearch",tool_input:{}}' |
    env NIGHTSHIFT_TOOL_RULES='not json' CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "toolDeny"
  out="$(jq -nc '{tool_name:"WebSearch",tool_input:{}}' |
    env NIGHTSHIFT_TOOL_RULES='{"WebSearch":1}' CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
}

@test "an explicit Ask rule holds even without jq" {
  p="$(new_project)"
  punch_open "$p"
  nojq="$BATS_TEST_TMPDIR/nojq-rules"
  mkdir -p "$nojq"
  for t in bash grep sed cat printf env sh ps dirname head tail tr awk date mkdir rm cut wc sleep kill git python3; do
    command -v "$t" >/dev/null && ln -sf "$(command -v "$t")" "$nojq/$t"
  done
  out="$(jq -nc '{tool_name:"AskUserQuestion",tool_input:{}}' |
    env PATH="$nojq" NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"welded shut"}' CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "welded shut"
}

@test "the rules-file tool map still works without jq" {
  p="$(new_project)"
  punch_open "$p"
  nojq="$BATS_TEST_TMPDIR/nojq-file-rules"
  mkdir -p "$nojq"
  for t in bash grep sed cat printf env sh ps dirname head tail tr awk date mkdir rm cut wc sleep kill git python3; do
    command -v "$t" >/dev/null && ln -sf "$(command -v "$t")" "$nojq/$t"
  done
  out="$(jq -nc '{tool_name:"AskUserQuestion",tool_input:{}}' |
    env PATH="$nojq" CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "park"
}

@test "tool rules still deny the question tool without jq or python3" {
  p="$(new_project)"
  punch_open "$p"
  noparser="$BATS_TEST_TMPDIR/no-rules-parser"
  mkdir -p "$noparser"
  for t in bash grep sed cat printf env sh ps dirname head tail tr awk date mkdir rm cut wc sleep kill git cksum; do
    command -v "$t" >/dev/null && ln -sf "$(command -v "$t")" "$noparser/$t"
  done
  out="$(jq -nc '{tool_name:"AskUserQuestion",tool_input:{}}' |
    env PATH="$noparser" CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "park"
  if printf '%s' "$out" | grep -q "jq or python3"; then
    return 1
  fi
}

# ---- one copy: the rules file IS the config; env is only a session-start override ----

@test "the guards read the rules file directly — no env needed" {
  p="$(new_project)"
  punch_open "$p"
  printf '{"forbiddenCommands":"git .*push","toolDeny":{"AskUserQuestion":"file-map says park","request_user_input":"codex park"}}\n' >"$p/.nightshift/rules.json"
  run hardhat_bash "$p" "git push origin main"
  is_deny "$output"
  run hardhat_ask "$p"
  is_deny "$output"
  printf '%s' "$output" | grep -q "file-map says park"
}

@test "an env var overrides the file for the session" {
  p="$(new_project)"
  punch_open "$p"
  printf '{"forbiddenCommands":"git .*push"}\n' >"$p/.nightshift/rules.json"
  run hardhat_bash "$p" "git push origin main" NIGHTSHIFT_FORBIDDEN_COMMANDS="never-matches-anything"
  is_allow
}

@test "the night never rewrites its own rules — file tools and commands alike" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc --arg fp "$p/.nightshift/rules.json" '{tool_name:"Write",tool_input:{file_path:$fp,content:"{}"}}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "rules file is the owner"
  run hardhat_bash "$p" "echo '{}' > .nightshift/rules.json"
  is_deny "$output"
  out="$(jq -nc --arg fp "$p/.nightshift/rules.json" '{tool_name:"mcp__filesystem__write_file",tool_input:{path:$fp,content:"{}"}}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
  out="$(jq -nc '{tool_name:"mcp__filesystem__write_file",tool_input:{directory:".nightshift",name:"rules.json",content:"{}"}}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
  out="$(jq -nc '{tool_name:"mcp__filesystem__copy",tool_input:{source:".nightshift/template.json",destination:"docs/rules.json"}}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ] # two independent paths must not be combined into a third
}

@test "file tools are free of the command guards — and free entirely outside a shift" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc '{tool_name:"Write",tool_input:{file_path:"/tmp/notes.md",content:"document .nightshift/rules.json and how to git push"}}' |
    env NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push' CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ] # file content is neither a command nor the target path
  q="$(new_project other)"
  out="$(jq -nc --arg fp "$q/.nightshift/rules.json" '{tool_name:"Write",tool_input:{file_path:$fp,content:"{}"}}' |
    env CLAUDE_PROJECT_DIR="$q" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ] # no shift, no rules — the owner edits freely
}

@test "the bound worker cannot delete or forge armed-shift control files" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "unlink .nightshift/.shift-armed"
  is_deny "$output"
  printf '%s' "$output" | grep -q "control files"
  run hardhat_bash "$p" "cd .nightshift && unlink .shift-armed"
  is_deny "$output"
  run hardhat_bash "$p" "cd .nightshift && touch STOP"
  is_deny "$output"
  run hardhat_bash "$p" "touch STOP"
  is_allow
  run hardhat_bash "$p" "unlink .shift-armed"
  is_allow
  run hardhat_bash "$p" "touch .nightshift/STOP"
  is_deny "$output"
  run hardhat_bash "$p" "echo ended > .nightshift/.ended"
  is_deny "$output"
  run hardhat_bash "$p" "echo /tmp/other > .nightshift/work-target"
  is_deny "$output"
  run hardhat_bash "$p" "rm -f .nightshift/punch-list.md"
  is_deny "$output"
  out="$(jq -nc --arg fp "$p/.nightshift/.shift-session" '{tool_name:"Write",tool_input:{file_path:$fp,content:"forged"}}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
}

@test "slash tricks and absolute twins cannot forge armed-shift control files" {
  p="$(new_project)"
  punch_open "$p"
  phys="$(cd -P "$p" && pwd -P)"
  twin="$BATS_TEST_TMPDIR/control-twin"
  ln -s "$phys" "$twin"

  deny_control() {
    local out="$1" label="$2"
    is_deny "$out" || { echo "allowed: $label -> $out"; return 1; }
    printf '%s' "$out" | grep -q "control files" || { echo "wrong deny: $label -> $out"; return 1; }
  }

  write_tool() {
    jq -nc --arg t "$1" --arg fp "$2" \
      '{tool_name:$t,tool_input:{file_path:$fp,content:"forged",old_string:"a",new_string:"b"}}' |
      env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
  }

  patch_tool() {
    jq -nc --arg proj "$p" --arg fp "$1" \
      '{tool_name:"apply_patch",cwd:$proj,tool_input:{command:("*** Begin Patch\n*** Update File: " + $fp + "\n@@\n+x\n*** End Patch")}}' |
      env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh"
  }

  check_form() {
    local form="$1"
    run hardhat_bash "$p" "touch $form"
    deny_control "$output" "Bash $form" || return 1
    deny_control "$(write_tool Write "$form")" "Write $form" || return 1
    deny_control "$(write_tool Edit "$form")" "Edit $form" || return 1
    deny_control "$(patch_tool "$form")" "apply_patch $form" || return 1
  }

  check_form '.nightshift//STOP' || return 1
  check_form '.nightshift/./STOP' || return 1
  check_form '.nightshift/../.nightshift/STOP' || return 1
  run hardhat_bash "$p" 'touch .nightshift\STOP'
  deny_control "$output" 'Bash .nightshift\\STOP' || return 1
  run hardhat_bash "$p" 'touch .nightshift\\STOP'
  deny_control "$output" 'Bash .nightshift\\\\STOP' || return 1
  deny_control "$(write_tool Write '.nightshift\STOP')" 'Write .nightshift\\STOP' || return 1
  deny_control "$(write_tool Edit '.nightshift\STOP')" 'Edit .nightshift\\STOP' || return 1
  deny_control "$(patch_tool '.nightshift\STOP')" 'apply_patch .nightshift\\STOP' || return 1
  deny_control "$(write_tool Write '.nightshift\\STOP')" 'Write .nightshift\\\\STOP' || return 1
  deny_control "$(write_tool Edit '.nightshift\\STOP')" 'Edit .nightshift\\\\STOP' || return 1
  deny_control "$(patch_tool '.nightshift\\STOP')" 'apply_patch .nightshift\\\\STOP' || return 1
  check_form "$twin/.nightshift/STOP" || return 1
  check_form "$phys/.nightshift/STOP" || return 1
  check_form "$phys/.nightshift//STOP" || return 1
}

@test "punch-list ticks stay allowed and Start can still create the armed marker" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc --arg fp "$p/.nightshift/punch-list.md" '{tool_name:"Write",tool_input:{file_path:$fp,content:"## Items\n- [x] **1.**\n"}}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ]
  run hardhat_bash "$p" "printf 'ticked\n' >> .nightshift/punch-list.md"
  is_allow
  rm "$p/.nightshift/.shift-armed"
  run hardhat_bash "$p" "touch .nightshift/.shift-armed"
  is_allow
}

@test "a helper session can still issue STOP" {
  p="$(new_project)"
  punch_open "$p"
  printf 'the-shift\n\n\n\n' >"$p/.nightshift/.shift-session"
  out="$(jq -nc --arg fp "$p/.nightshift/STOP" '{tool_name:"Write",session_id:"helper-tab",tool_input:{file_path:$fp,content:"stop"}}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ]
  out="$(jq -nc '{tool_name:"Bash",session_id:"helper-tab",tool_input:{command:"touch .nightshift/STOP"}}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ]
}

# ---- the owner's emergency helpers outrank the process fence ----

PLUGIN_ROOT="$(cd -P "$BATS_TEST_DIRNAME/../plugins/nightshift" && pwd -P)"
FOREIGN_NONCE=claude.2.4711.8.9

# shift_helper_passes <project> <session-id> — the three owner helpers, each once.
shift_helper_passes() {
  local p="$1" sid="$2" helper out
  for helper in "stop-shift.sh --project $p" "reset-shift.sh --project $p" \
    "purge-workspace.sh --project $p --confirm-path $p"; do
    out="$(hardhat_sid_bash "$p" "$sid" "bash $PLUGIN_ROOT/runtime/$helper")"
    [ -z "$out" ] || { echo "helper refused: [$sid] $helper -> $out"; return 1; }
  done
  return 0
}

@test "the owner helpers run from any conversation while a live worker holds the lease" {
  p="$(new_project)"
  punch_open "$p"
  sleep 300 &
  holder=$!
  session_record "$p" shift-session "" "" "" claude
  lease_record "$p" shift-session claude 2 "$FOREIGN_NONCE" "$holder" "$(process_start "$holder")"

  shift_helper_passes "$p" shift-session
  shift_helper_passes "$p" helper-tab
  shift_helper_passes "$p" ""

  # The allowance is exactly those helpers; ordinary work in the fenced conversation is not.
  out="$(hardhat_sid_bash "$p" shift-session "echo hi")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "being recovered in another process"

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

@test "the owner helpers run from any conversation while the lease holder is dead" {
  p="$(new_project)"
  punch_open "$p"
  dead="$(reaped_pid)"
  session_record "$p" shift-session "" "" "" claude
  lease_record "$p" shift-session claude 2 "$FOREIGN_NONCE" "$dead" ""

  shift_helper_passes "$p" shift-session
  shift_helper_passes "$p" helper-tab
  [ "$(reclaim_log_count "$p")" -eq 0 ] # a helper is not a claim on the shift
}

# ---- disarm is total ----
#
# Every rule hardhat can apply, run once against a site that is no longer armed. The lease is
# deliberately left behind, live holder and dead holder both: a disarmed site has no fence to
# stand, no tool to deny, and no command to guard.

# every_rule_passes <project> <session-id>
every_rule_passes() {
  local p="$1" sid="$2" command out
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    out="$(hardhat_sid_bash "$p" "$sid" "$command" \
      NIGHTSHIFT_FORBIDDEN_COMMANDS='git push' NIGHTSHIFT_PROTECTED_DIRS='ai_docs')"
    [ -z "$out" ] || { echo "rule applied to a disarmed site: [$sid] $command -> $out"; return 1; }
  done <<'CMDS'
echo hi
git push
git add ai_docs/x
sudo apt-get install -y jq
rm -f .nightshift/.shift-lease
touch .nightshift/STOP
unlink .nightshift/.shift-armed
printf '{}' > .nightshift/rules.json
CMDS
  out="$(jq -nc --arg sid "$sid" '{tool_name:"AskUserQuestion",session_id:$sid,tool_input:{}}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ] || { echo "the question rule applied to a disarmed site: [$sid] -> $out"; return 1; }
  out="$(jq -nc --arg sid "$sid" --arg fp "$p/.nightshift/.shift-session" \
    '{tool_name:"Write",session_id:$sid,tool_input:{file_path:$fp,content:"forged"}}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ] || { echo "the control rule applied to a disarmed site: [$sid] -> $out"; return 1; }
  out="$(jq -nc --arg sid "$sid" '{tool_name:"Read",session_id:$sid,tool_input:{file_path:"README.md"}}' |
    env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ] || { echo "the fence applied to a disarmed site: [$sid] -> $out"; return 1; }
  return 0
}

@test "an unarmed site applies no rule, whatever the lease still says" {
  p="$(new_project)"
  punch_open "$p"
  sleep 300 &
  holder=$!
  session_record "$p" shift-session "" "" "" claude
  lease_record "$p" shift-session claude 2 "$FOREIGN_NONCE" "$holder" "$(process_start "$holder")"
  rm "$p/.nightshift/.shift-armed"

  every_rule_passes "$p" shift-session
  every_rule_passes "$p" helper-tab
  [ "$(lease_nonce "$p")" = "$FOREIGN_NONCE" ] # and nothing reclaimed a shift that is over

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  q="$(new_project unarmed-dead-holder)"
  punch_open "$q"
  dead="$(reaped_pid)"
  session_record "$q" shift-session "" "" "" claude
  lease_record "$q" shift-session claude 2 "$FOREIGN_NONCE" "$dead" ""
  rm "$q/.nightshift/.shift-armed"

  every_rule_passes "$q" shift-session
  [ "$(reclaim_log_count "$q")" -eq 0 ]
}

# The Stop helper writes STOP and drops the armed marker in one act, so a stopped shift is a
# disarmed one from the next tool call — no Stop event needed. (A stop-work order that is
# merely pending, marker still in place, keeps the site rules armed; that is its own test.)
@test "a stopped shift applies no rule, whatever the lease still says" {
  p="$(new_project)"
  punch_open "$p"
  dead="$(reaped_pid)"
  session_record "$p" shift-session "" "" "" claude
  lease_record "$p" shift-session claude 2 "$FOREIGN_NONCE" "$dead" ""
  printf 'stopped by owner\n' >"$p/.nightshift/STOP"
  rm "$p/.nightshift/.shift-armed"

  every_rule_passes "$p" shift-session
  every_rule_passes "$p" helper-tab
  [ "$(reclaim_log_count "$p")" -eq 0 ]
}

# No readable rules is a fault, never permission to invent an ask policy.
@test "a missing rules file denies the question and names the repair" {
  p="$(new_project)"
  punch_open "$p"
  rm "$p/.nightshift/rules.json"
  run hardhat_ask "$p"
  is_deny "$output"
  printf '%s' "$output" | grep -qF '/nightshift:setup'
  printf '%s' "$output" | grep -qF 'ask Nightshift to set up on Codex'
}

# --- the policy files are control files, and elevation is the owner's switch ---

@test "the bound worker cannot rewrite or delete the shift policy, its defaults, or the deadline" {
  p="$(new_project)"
  punch_open "$p"
  shift_policy "$p"
  printf '{"schemaVersion":1}\n' >"$p/.nightshift/shift-defaults.json"
  printf '4102444800\n' >"$p/.nightshift/deadline"
  for f in shift-policy.json shift-defaults.json deadline; do
    run hardhat_bash "$p" "printf 'forged' > .nightshift/$f"
    is_deny "$output" || { echo "path rewrite allowed: $f"; return 1; }
    printf '%s' "$output" | grep -qF "$f" || { echo "deny does not name $f"; return 1; }
    run hardhat_bash "$p" "rm -f .nightshift/$f"
    is_deny "$output" || { echo "path delete allowed: $f"; return 1; }
    run hardhat_bash "$p" "cd .nightshift && printf 'forged' > $f"
    is_deny "$output" || { echo "name rewrite allowed: $f"; return 1; }
    run hardhat_bash "$p" "cd .nightshift && unlink $f"
    is_deny "$output" || { echo "name delete allowed: $f"; return 1; }
    out="$(jq -nc --arg fp "$p/.nightshift/$f" \
      '{tool_name:"Write",tool_input:{file_path:$fp,content:"forged"}}' |
      env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
    is_deny "$out" || { echo "Write allowed: $f"; return 1; }
    out="$(jq -nc --arg fp "$p/.nightshift/$f" \
      '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"a",new_string:"b"}}' |
      env CLAUDE_PROJECT_DIR="$p" bash "$HOOKS/hardhat.sh")"
    is_deny "$out" || { echo "Edit allowed: $f"; return 1; }
  done
  # The bare name outside .nightshift is somebody else's file.
  run hardhat_bash "$p" "printf 'x' > deadline"
  is_allow
}

@test "every elevation category is denied by default with the exact repair" {
  p="$(new_project)"
  punch_open "$p"
  while IFS='|' read -r category command; do
    [ -n "$category" ] || continue
    run hardhat_bash "$p" "$command"
    is_deny "$output" || { echo "allowed: $command"; return 1; }
    [ "$(deny_reason "$output")" = "$(elevation_message "$p" "$category")" ] \
      || { echo "wrong message for $category: $(deny_reason "$output")"; return 1; }
  done <<'ROWS'
sudo|sudo apt-get install -y jq
containers|docker compose up -d
global-packages|brew install shellcheck
daemons|systemctl start nginx
external-services|gh auth login
ROWS
}

@test "a rules allowance lifts its own category permanently and no other" {
  p="$(new_project)"
  punch_open "$p"
  rules_elevation "$p" containers allow
  run hardhat_bash "$p" "docker compose up -d"
  is_allow
  run hardhat_bash "$p" "sudo id"
  is_deny "$output"
  printf '%s' "$output" | grep -qF "needs allowance: sudo"
}

@test "a one-shift allowance lifts the category for tonight only" {
  p="$(new_project)"
  punch_open "$p"
  shift_policy "$p" '[{"category":"containers","scope":"category","provenance":"one-shift"}]'
  run hardhat_bash "$p" "docker compose up -d"
  is_allow
  # Tonight's snapshot is the whole authority: without it the shipped deny is back.
  rm "$p/.nightshift/shift-policy.json"
  run hardhat_bash "$p" "docker compose up -d"
  is_deny "$output"
}

@test "an exact-plan allowance permits its listed command and names the mismatch" {
  p="$(new_project)"
  punch_open "$p"
  target="$(work_target "$p")"
  digest="$(plan_digest "$target" "docker compose up -d")"
  shift_policy "$p" "$(jq -nc --arg t "$target" --arg d "$digest" \
    '[{category:"containers",scope:"exact-plan",provenance:"one-shift",
       plan:{commands:["docker compose up -d"],workTarget:$t,digest:$d}}]')"
  run hardhat_bash "$p" "docker compose up -d"
  is_allow
  # Whitespace is normalized on both sides, so the same command still matches.
  run hardhat_bash "$p" "docker   compose  up -d"
  is_allow
  run hardhat_bash "$p" "docker compose down"
  is_deny "$output"
  [ "$(deny_reason "$output")" = "BLOCKED: this command needs the 'containers' elevation category, which is denied for this shift. An exact-plan allowance exists but this command is not one of its approved commands." ]
}

@test "an exact-plan allowance is bound to the plan the owner approved" {
  p="$(new_project)"
  punch_open "$p"
  target="$(work_target "$p")"
  # The binding lives in ns_policy_allowed, which the guard reads for the whole answer.
  # A digest that does not cover the plan's own commands, work target and shift is not the plan
  # the owner approved.
  shift_policy "$p" "$(jq -nc --arg t "$target" \
    '[{category:"containers",scope:"exact-plan",provenance:"one-shift",
       plan:{commands:["docker compose up -d"],workTarget:$t,
             digest:"0000000000000000000000000000000000000000000000000000000000000000"}}]')"
  run hardhat_bash "$p" "docker compose up -d"
  is_deny "$output"
  # A plan approved for another work target does not travel to this one.
  digest="$(plan_digest /work/elsewhere "docker compose up -d")"
  shift_policy "$p" "$(jq -nc --arg d "$digest" \
    '[{category:"containers",scope:"exact-plan",provenance:"one-shift",
       plan:{commands:["docker compose up -d"],workTarget:"/work/elsewhere",digest:$d}}]')"
  run hardhat_bash "$p" "docker compose up -d"
  is_deny "$output"
}

@test "a category named only inside a commit message is not a command" {
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "git commit -m 'run docker compose up and sudo apt-get install jq'"
  is_allow
  run hardhat_bash "$p" "git commit --message='brew install shellcheck; systemctl start nginx'"
  is_allow
}

@test "the forbidden list and the elevation categories are independent guards" {
  p="$(new_project)"
  punch_open "$p"
  rules_elevation "$p" containers allow
  # An allowed category is still subject to the owner's own list.
  run hardhat_bash "$p" "docker compose up -d" NIGHTSHIFT_FORBIDDEN_COMMANDS='docker'
  is_deny "$output"
  printf '%s' "$output" | grep -qF "forbidden list"
  # And a command the list ignores can still need an allowance.
  run hardhat_bash "$p" "sudo id" NIGHTSHIFT_FORBIDDEN_COMMANDS='kubectl'
  is_deny "$output"
  printf '%s' "$output" | grep -qF "needs allowance: sudo"
}

@test "an invalid elevation pattern fails closed and names the field" {
  p="$(new_project)"
  punch_open "$p"
  rules_pattern "$p" daemons '(unclosed'
  run hardhat_bash "$p" "git status"
  is_deny "$output"
  printf '%s' "$output" | grep -qF 'elevation.daemons.pattern is not a valid extended regular expression'
  printf '%s' "$output" | grep -qF 'so the guard it configures cannot run'
}

@test "using what already runs is never elevation" {
  p="$(new_project)"
  punch_open "$p"
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    run hardhat_bash "$p" "$command"
    is_allow || { echo "denied: $command -> $output"; return 1; }
  done <<'CMDS'
psql -c 'select 1'
curl http://localhost:3000
npm test
git commit -m ship
CMDS
}

@test "create-state elevation denies bypass forms and leaves read-only forms alone" {
  p="$(new_project)"
  punch_open "$p"
  while IFS='|' read -r category command; do
    [ -n "$category" ] || continue
    run hardhat_bash "$p" "$command"
    is_deny "$output" || { echo "allowed: $command"; return 1; }
    [ "$(deny_reason "$output")" = "$(elevation_message "$p" "$category")" ] \
      || { echo "wrong message for $command: $(deny_reason "$output")"; return 1; }
  done <<'ROWS'
sudo|/usr/bin/sudo id
sudo|sudo;id
sudo|eval 'sudo id'
sudo|sh -c 'sudo apt-get install -y jq'
containers|docker run alpine
containers|docker create alpine
containers|docker start web
containers|docker build .
containers|curl --unix-socket /var/run/docker.sock http://localhost/info
global-packages|pip install black
global-packages|cargo install ripgrep
global-packages|go install example.com/cmd@latest
global-packages|apt-get upgrade jq
global-packages|brew uninstall shellcheck
ROWS
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    run hardhat_bash "$p" "$command"
    is_allow || { echo "denied: $command -> $output"; return 1; }
  done <<'CMDS'
docker ps
docker logs web
brew list
CMDS
}

@test "elevation rules are shift-scoped: inert once every box is ticked" {
  p="$(new_project)"
  punch_done "$p"
  run hardhat_bash "$p" "sudo apt-get install -y jq"
  is_allow
}

@test "the permission preflight and the guard agree on the same commands" {
  p="$(new_project)"
  cat >"$p/.nightshift/punch-list.md" <<'MD'
## Items

- [ ] **1. Bring up the database.**
  - `docker compose up -d`
- [ ] **2. Install jq system-wide.**
  - `sudo apt-get install -y jq`
- [ ] **3. Run the tests.**
  - `npm test`
- [ ] **4. Query the dev stack.**
  - `psql -c 'select 1'`
MD
  needs="$(bash "$PRE" --project "$p" --json)"
  while IFS='|' read -r title command; do
    [ -n "$title" ] || continue
    gapped="$(printf '%s' "$needs" | jq --arg t "$title" '[.gaps[] | select(.title == $t)] | length')"
    run hardhat_bash "$p" "$command"
    if [ "$gapped" -gt 0 ]; then
      is_deny "$output" || { echo "preflight gapped, guard allowed: $command"; return 1; }
    else
      is_allow || { echo "preflight clear, guard denied: $command -> $output"; return 1; }
    fi
  done <<'ROWS'
1. Bring up the database.|docker compose up -d
2. Install jq system-wide.|sudo apt-get install -y jq
3. Run the tests.|npm test
4. Query the dev stack.|psql -c 'select 1'
ROWS
}

# ---------------------------------------------------------------------------------------------
# A quoted here-document body is the file being written, not a command. Writing documentation about
# Nightshift — its elevation categories, its owner file, its control files — must not read as a
# request to do any of it. What the command actually writes to is still inspected exactly as before.

# hd <delimiter-quote> <target> <body> — a here-document command.
hd() {
  printf 'cat > %s <<%s%s%s\n%s\n%s' "$2" "$1" EOF "$1" "$3" EOF
}

@test "a quoted heredoc naming every elevation category is documentation" {
  p="$(new_project hd-elevation)"
  punch_open "$p"
  run hardhat_bash "$p" \
    "$(hd "'" docs/elevation.md 'sudo and doas, docker run, brew install -g, systemctl, gh auth login')"
  is_allow
}

@test "a quoted heredoc naming the owner file and control files is documentation" {
  p="$(new_project hd-names)"
  punch_open "$p"
  run hardhat_bash "$p" "$(hd "'" docs/knobs.md 'edit .nightshift/rules.json to set a knob')"
  is_allow
  run hardhat_bash "$p" \
    "$(hd "'" .nightshift/shift-log.md 'work-mode, deadline and STOP were all read this cycle')"
  is_allow
}

@test "what the heredoc writes to is still what decides" {
  p="$(new_project hd-target)"
  punch_open "$p"
  # The body is harmless; the target is the owner's file.
  run hardhat_bash "$p" "$(hd "'" .nightshift/rules.json 'harmless words')"
  is_deny "$output"
  run hardhat_bash "$p" "$(hd "'" .nightshift/work-mode 'artifact')"
  is_deny "$output"
}

@test "an unquoted heredoc body is still code" {
  p="$(new_project hd-unquoted)"
  punch_open "$p"
  # No quotes on the delimiter: the shell expands this, and the substitution really runs.
  run hardhat_bash "$p" "$(printf 'cat > out.txt <<EOF\n$(sudo id)\nEOF')"
  is_deny "$output"
}

@test "an unterminated quoted heredoc is never treated as data" {
  p="$(new_project hd-unterminated)"
  punch_open "$p"
  run hardhat_bash "$p" "$(printf "cat > x.md <<'EOF'\nsudo apt-get install ripgrep")"
  is_deny "$output"
}

@test "a real command after a closed heredoc is still a real command" {
  p="$(new_project hd-after)"
  punch_open "$p"
  run hardhat_bash "$p" "$(printf "cat > d.md <<'EOF'\nharmless\nEOF\nsudo id")"
  is_deny "$output"
}

# An interpreter reading its script from a quoted here-document is still an interpreter. Quoting
# the delimiter stops the outer shell expanding the body; it does not stop bash from running it.
# These feed strings to the hook and assert its decision — no payload is ever executed.

@test "a quoted heredoc fed to an interpreter is code, not documentation" {
  p="$(new_project hd-interpreter)"
  punch_open "$p"
  run hardhat_bash "$p" "$(printf "bash <<'EOF'\nsudo id\nEOF")"
  is_deny "$output"
  run hardhat_bash "$p" "$(printf "sh <<'EOF'\nsudo id\nEOF")"
  is_deny "$output"
  run hardhat_bash "$p" "$(printf "python3 - <<'PY'\nrun('sudo id')\nPY")"
  is_deny "$output"
}

@test "a heredoc piped into an interpreter is code" {
  p="$(new_project hd-pipe)"
  punch_open "$p"
  run hardhat_bash "$p" "$(printf "cat <<'EOF' | bash\nsudo id\nEOF")"
  is_deny "$output"
  run hardhat_bash "$p" "$(printf "tee /dev/null <<'EOF' | sh\nsudo id\nEOF")"
  is_deny "$output"
}

@test "eval and source forms keep their heredoc bodies visible" {
  p="$(new_project hd-eval)"
  punch_open "$p"
  run hardhat_bash "$p" "$(printf "eval <<'EOF'\nsudo id\nEOF")"
  is_deny "$output"
  run hardhat_bash "$p" "$(printf ". /dev/stdin <<'EOF'\nsudo id\nEOF")"
  is_deny "$output"
}

@test "a backslash-quoted delimiter is not an exemption either" {
  p="$(new_project hd-backslash)"
  punch_open "$p"
  run hardhat_bash "$p" "$(printf 'bash <<\\EOF\nsudo id\nEOF')"
  is_deny "$output"
}

@test "a substituted or non-literal destination keeps its body visible" {
  p="$(new_project hd-dynamic)"
  punch_open "$p"
  # Where it writes is not on the line, so the body is not taken on trust.
  run hardhat_bash "$p" "$(printf 'cat > "$out" <<%s\nsudo id\nEOF' "'EOF'")"
  is_deny "$output"
  run hardhat_bash "$p" "$(printf 'cat > "$(mktemp)" <<%s\nsudo id\nEOF' "'EOF'")"
  is_deny "$output"
}

@test "a command list on the opening line keeps its body visible" {
  p="$(new_project hd-list)"
  punch_open "$p"
  run hardhat_bash "$p" "$(printf "true; cat > d.md <<'EOF'\nsudo id\nEOF")"
  is_deny "$output"
  run hardhat_bash "$p" "$(printf "cat > d.md <<'EOF' &\nsudo id\nEOF")"
  is_deny "$output"
}

@test "tee writes and tab-stripped bodies are still documentation" {
  p="$(new_project hd-tee)"
  punch_open "$p"
  run hardhat_bash "$p" "$(printf "tee docs/e.md <<'EOF'\nsudo and doas, docker run, systemctl\nEOF")"
  is_allow
  run hardhat_bash "$p" "$(printf "tee -a docs/e.md <<'EOF'\nbrew install -g something\nEOF")"
  is_allow
  run hardhat_bash "$p" "$(printf "cat > docs/e.md <<-'EOF'\n\tsudo and doas\n\tEOF")"
  is_allow
}

@test "one documentation heredoc does not exempt the next interpreter one" {
  p="$(new_project hd-multi)"
  punch_open "$p"
  run hardhat_bash "$p" \
    "$(printf "cat > d.md <<'A'\nharmless words\nA\nbash <<'B'\nsudo id\nB")"
  is_deny "$output"
  # And the reverse order: the first body is inspected even though a safe write follows.
  run hardhat_bash "$p" \
    "$(printf "bash <<'A'\nsudo id\nA\ncat > d.md <<'B'\nharmless words\nB")"
  is_deny "$output"
}

@test "two heredocs on one line are never exempt" {
  p="$(new_project hd-two-on-one)"
  punch_open "$p"
  run hardhat_bash "$p" "$(printf "cat <<'A' <<'B'\nsudo id\nA\nB")"
  is_deny "$output"
}

@test "the owner's own forbidden pattern still holds inside and outside a heredoc" {
  p="$(new_project hd-owner-rule)"
  punch_open "$p"
  # The owner's pattern is theirs: a real push is denied.
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push'
  is_deny "$output"
  # And documentation about it is documentation.
  run hardhat_bash "$p" "$(hd "'" docs/push.md 'the owner may forbid git push for the night')" \
    NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push'
  is_allow
}
