load ../helpers

# helpers.bash anchors its paths one directory up; from tests/codex/ the repo root is two.
HOOKS="$BATS_TEST_DIRNAME/../../plugins/nightshift/hooks"
RULES_TEMPLATE="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json"
CODEX_HOOKS="$HOOKS/codex"

# codex_hardhat_bash <project> <command> [ENV=VAL ...] — the placeholder PreToolUse payload.
codex_hardhat_bash() {
  local p="$1" c="$2"
  shift 2
  jq -nc --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}' |
    env "$@" CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh"
}

# codex_hardhat_ask <project> [tool-name] [ENV=VAL ...]
codex_hardhat_ask() {
  local p="$1"
  shift
  local tool="AskUserQuestion"
  if [ "${1:-}" = "AskUserQuestion" ] || [ "${1:-}" = "request_user_input" ]; then
    tool="$1"
    shift
  fi
  jq -nc --arg tool "$tool" '{tool_name:$tool,tool_input:{}}' |
    env "$@" CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh"
}

@test "the no-push recipe denies push during an active shift" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_bash "$p" "git push origin main" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
}

@test "a scary-looking command passes when the forbidden list is unset" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_bash "$p" "kubectl delete pod api-7f9"
  is_allow
}

@test "forbidden-commands rule is shift-scoped: inert once every box is ticked" {
  p="$(new_project)"
  punch_done "$p"
  run codex_hardhat_bash "$p" "docker ps" NIGHTSHIFT_FORBIDDEN_COMMANDS='docker'
  is_allow
}

@test "a protected-dir commit is denied when configured" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_bash "$p" "git commit -m x ai_docs/notes.md" NIGHTSHIFT_PROTECTED_DIRS="ai_docs notes"
  is_deny "$output"
}

@test "a protected-dir git add is denied; unset leaves it free" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_bash "$p" "git add ai_docs/secret" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
  run codex_hardhat_bash "$p" "git add ai_docs/secret"
  is_allow
}

@test "commit under the wrong identity is denied when configured" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_bash "$p" "git commit -m x" NIGHTSHIFT_EXPECTED_EMAIL="owner@nope.io"
  is_deny "$output"
}

@test "commit under the expected identity is allowed" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_bash "$p" "git commit -m x" NIGHTSHIFT_EXPECTED_EMAIL="dev@example.com"
  is_allow
}

@test "a staged never-commit pattern is denied when configured" {
  p="$(new_project)"
  punch_open "$p"
  printf 'API_KEY=sk-secret\n' >"$p/leak.txt"
  git -C "$p" add leak.txt
  run codex_hardhat_bash "$p" "git commit -m x" NIGHTSHIFT_NEVER_COMMIT_PATTERNS="sk-secret|API_KEY"
  is_deny "$output"
}

@test "AskUserQuestion is parked with the template's own message" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_ask "$p"
  is_deny "$output"
  printf '%s' "$output" | grep -q "park" # the template's toolDeny entry, read from the file
}

@test "request_user_input is parked with its native template entry" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_ask "$p" request_user_input
  is_deny "$output"
  printf '%s' "$output" | grep -q "park"
}

@test "request_user_input remains available outside an armed shift" {
  p="$(new_project)"
  punch_open "$p"
  rm "$p/.nightshift/.shift-armed"
  run codex_hardhat_ask "$p" request_user_input
  is_allow
}

@test "an open checkbox outside Items does not activate the codex hardhat" {
  p="$(new_project)"
  printf '%s\n' '- [ ] planning example' '## Items' '- [x] **1. done.**' >"$p/.nightshift/punch-list.md"
  run codex_hardhat_ask "$p"
  is_allow
}

@test "an open checkbox under Items activates the codex hardhat" {
  p="$(new_project)"
  printf '%s\n' '- [x] planning example' '## Items' '- [ ] **1. open.**' >"$p/.nightshift/punch-list.md"
  run codex_hardhat_ask "$p"
  is_deny "$output"
}

@test "open Items remain inert until the codex shift is armed" {
  p="$(new_project)"
  punch_open "$p"
  rm "$p/.nightshift/.shift-armed"
  run codex_hardhat_ask "$p"
  is_allow
}

@test "the AskUserQuestion compatibility alias reads its exact key" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_ask "$p" \
    NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"alias park","request_user_input":"native park"}'
  is_deny "$output"
  printf '%s' "$output" | grep -q "alias park"
}

@test "request_user_input uses its own host-native message" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_ask "$p" request_user_input \
    NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"alias park","request_user_input":"native park"}'
  is_deny "$output"
  printf '%s' "$output" | grep -q "native park"
}

@test "an empty request_user_input message allows Codex to ask" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_ask "$p" request_user_input \
    NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"alias park","request_user_input":""}'
  is_allow
}

@test "a missing Codex question key is a configuration error, not an alias fallback" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_ask "$p" request_user_input \
    NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"must not leak across hosts"}'
  is_deny "$output"
  printf '%s' "$output" | grep -q "missing the required 'request_user_input' entry"
  printf '%s' "$output" | grep -qF '/nightshift:setup'
  printf '%s' "$output" | grep -qF 'ask Nightshift to set up on Codex'
}

# Hosted tools never reach the Codex hook path; the arbitrary names an owner can list are MCP
# tools, so the fixture speaks that vocabulary.
@test "a listed tool is denied with its own message; an unlisted one passes" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc '{tool_name:"mcp__web__search",tool_input:{}}' |
    env NIGHTSHIFT_TOOL_RULES='{"mcp__web__search":"no browsing tonight"}' CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "no browsing tonight"
  out="$(jq -nc '{tool_name:"mcp__web__fetch",tool_input:{query:"how to git push"}}' |
    env NIGHTSHIFT_TOOL_RULES='{"mcp__web__search":"no browsing tonight"}' \
      NIGHTSHIFT_FORBIDDEN_COMMANDS='git push' CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh")"
  [ -z "$out" ]
}

@test "a nested question-tool name cannot bypass the canonical caller rule" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc '{tool_name:"mcp__router__invoke",tool_input:{tool_name:"request_user_input"}}' |
    env NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"","request_user_input":"","mcp__router__invoke":"router blocked"}' \
      CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "router blocked"
}

@test "toolDeny can block canonical Codex Bash calls" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_bash "$p" "git status" \
    NIGHTSHIFT_TOOL_RULES='{"AskUserQuestion":"","request_user_input":"","Bash":"no shell tonight"}'
  is_deny "$output"
  printf '%s' "$output" | grep -q "no shell tonight"
}

# Codex delivers file edits as apply_patch with the patch text in tool_input.command; the
# payload's cwd is the documented way a hook finds the project — no env override here.
@test "neverCommitPatterns inspects a pathspec commit on Codex" {
  p="$(new_project)"
  punch_open "$p"
  printf 'clean\n' >"$p/leak.txt"
  git -C "$p" add leak.txt
  git -C "$p" commit -q -m seed
  printf 'API_KEY=sk-secret\n' >"$p/leak.txt"
  run codex_hardhat_bash "$p" "git commit -m pathspec-bypass leak.txt" NIGHTSHIFT_NEVER_COMMIT_PATTERNS="sk-secret"
  is_deny "$output"
}

@test "protectedDirs inspects Git paths on Codex too" {
  p="$(new_project)"
  punch_open "$p"
  mkdir -p "$p/ai_docs"
  printf 'secret\n' >"$p/ai_docs/secret.txt"
  run codex_hardhat_bash "$p" "git add -A" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
  git -C "$p" add ai_docs/secret.txt
  run codex_hardhat_bash "$p" "git commit -m protected-bypass" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
  git -C "$p" add ai_docs/secret.txt
  git -C "$p" commit -q -m protected
  rm -f "$p/ai_docs/secret.txt"
  run codex_hardhat_bash "$p" "git add -A" NIGHTSHIFT_PROTECTED_DIRS="ai_docs"
  is_deny "$output"
}

@test "the bound worker cannot unlink the armed marker or delete the punch list" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_bash "$p" "unlink .nightshift/.shift-armed"
  is_deny "$output"
  run codex_hardhat_bash "$p" "cd .nightshift && unlink .shift-armed"
  is_deny "$output"
  run codex_hardhat_bash "$p" "cd .nightshift && touch STOP"
  is_deny "$output"
  run codex_hardhat_bash "$p" "rm .nightshift/punch-list.md"
  is_deny "$output"
}

@test "an apply_patch aimed at the rules file is denied" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc --arg p "$p" '{tool_name:"apply_patch",cwd:$p,tool_input:{command:"*** Begin Patch\n*** Update File: .nightshift/rules.json\n@@\n-old\n+new\n*** End Patch"}}' |
    bash "$CODEX_HOOKS/hardhat.sh")"
  is_deny "$out"
}

@test "an MCP writer aimed at the rules file is denied" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc --arg p "$p" '{tool_name:"mcp__filesystem__write_file",cwd:$p,tool_input:{path:($p + "/.nightshift/rules.json"),content:"{}"}}' |
    bash "$CODEX_HOOKS/hardhat.sh")"
  is_deny "$out"
}

@test "a patch is not a command: forbidden text inside an edit trips no command guard" {
  p="$(new_project)"
  punch_open "$p"
  out="$(jq -nc --arg p "$p" '{tool_name:"apply_patch",cwd:$p,tool_input:{command:"*** Begin Patch\n*** Update File: docs/deploy.md\n+document .nightshift/rules.json and run git push only after review\n*** End Patch"}}' |
    env NIGHTSHIFT_FORBIDDEN_COMMANDS='git push' bash "$CODEX_HOOKS/hardhat.sh")"
  [ -z "$out" ]
}

@test "the codex hardhat records its host, and a second tab never overwrites it" {
  p="$(new_project)"
  punch_open "$p"
  jq -nc '{tool_name:"Bash",session_id:"first-tab",transcript_path:"/tmp/a.jsonl",tool_input:{command:"echo hi"}}' |
    CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "first-tab" ]
  [ "$(sed -n 2p "$p/.nightshift/.shift-session")" = "/tmp/a.jsonl" ]
  [ "$(wc -l <"$p/.nightshift/.shift-session")" -eq 5 ] # id, transcript, pid, start time, host
  [ -z "$(sed -n 3p "$p/.nightshift/.shift-session")" ] # no invented process identity
  [ "$(sed -n 5p "$p/.nightshift/.shift-session")" = "codex" ]
  jq -nc '{tool_name:"Bash",session_id:"second-tab",transcript_path:"/tmp/b.jsonl",tool_input:{command:"echo hi"}}' |
    CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "first-tab" ]
}

@test "a passive catch-all tool cannot claim the Codex shift session" {
  p="$(new_project)"
  punch_open "$p"
  jq -nc '{tool_name:"mcp__filesystem__read_file",session_id:"helper-tab",tool_input:{path:"README.md"}}' |
    CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh"
  [ ! -f "$p/.nightshift/.shift-session" ]
  jq -nc '{tool_name:"Bash",session_id:"shift-tab",tool_input:{command:"pwd"}}' |
    CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "shift-tab" ]
}

@test "the no-push recipe holds when jq is absent and Python parses tool rules" {
  p="$(new_project)"
  punch_open "$p"
  bindir="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$bindir"
  for b in bash grep sed printf cat head tr git env python3; do
    src="$(command -v "$b")" && ln -sf "$src" "$bindir/$b"
  done
  input="$(jq -nc '{tool_name:"Bash",tool_input:{command:"git push"}}')"
  out="$(printf '%s' "$input" | env PATH="$bindir" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push' CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh")"
  is_deny "$out"
}

# --- the policy files are control files, and elevation is the owner's switch ---

# rules_elevation <project> <category> <policy>
rules_elevation() {
  local f="$1/.nightshift/rules.json"
  jq --arg c "$2" --arg v "$3" '.elevation[$c].policy = $v' "$f" >"$f.new"
  mv "$f.new" "$f"
}

# shift_policy <project> [allowances JSON array]
shift_policy() {
  jq -nc --argjson a "${2:-[]}" \
    '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T02:30:00Z",
      source:"composition",deadlineEpoch:null,verificationLevel:"final",
      toolingPolicy:"existing-tools",allowances:$a}' >"$1/.nightshift/shift-policy.json"
}

codex_reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason'; }

@test "codex denies rewriting the shift policy, its defaults, and the deadline" {
  p="$(new_project)"
  punch_open "$p"
  shift_policy "$p"
  for f in shift-policy.json shift-defaults.json deadline; do
    run codex_hardhat_bash "$p" "printf 'forged' > .nightshift/$f"
    is_deny "$output" || { echo "path rewrite allowed: $f"; return 1; }
    printf '%s' "$output" | grep -qF "$f" || { echo "deny does not name $f"; return 1; }
    run codex_hardhat_bash "$p" "cd .nightshift && rm -f $f"
    is_deny "$output" || { echo "name delete allowed: $f"; return 1; }
  done
}

@test "codex denies every elevation category by default with the same repair" {
  p="$(new_project)"
  punch_open "$p"
  ws="$(cd -P "$p" && pwd -P)"
  while IFS='|' read -r category command; do
    [ -n "$category" ] || continue
    run codex_hardhat_bash "$p" "$command"
    is_deny "$output" || { echo "allowed: $command"; return 1; }
    expected="BLOCKED: this command needs the '$category' elevation category, which is denied for this shift. The owner allows it in $ws/.nightshift/rules.json (elevation.$category.policy) or for one shift in shift-policy.json before arming. Park the item in $ws/.nightshift/parking-lot.md as \"needs allowance: $category\" and keep working."
    [ "$(codex_reason "$output")" = "$expected" ] \
      || { echo "wrong message for $category: $(codex_reason "$output")"; return 1; }
  done <<'ROWS'
sudo|sudo apt-get install -y jq
containers|docker compose up -d
global-packages|brew install shellcheck
daemons|systemctl start nginx
external-services|gh auth login
ROWS
}

@test "codex honours a rules allowance and a one-shift allowance alike" {
  p="$(new_project)"
  punch_open "$p"
  rules_elevation "$p" containers allow
  run codex_hardhat_bash "$p" "docker compose up -d"
  is_allow
  q="$(new_project codex-one-shift)"
  punch_open "$q"
  shift_policy "$q" '[{"category":"daemons","scope":"category","provenance":"one-shift"}]'
  run codex_hardhat_bash "$q" "systemctl start nginx"
  is_allow
}

@test "codex reads the scrubbed command, so a commit message names nothing" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_bash "$p" "git commit -m 'sudo apt-get install jq and docker compose up'"
  is_allow
}

@test "codex create-state elevation denies bypass forms and leaves reads alone" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_bash "$p" "/usr/bin/sudo id"
  is_deny "$output"
  printf '%s' "$output" | grep -qF "needs allowance: sudo"
  run codex_hardhat_bash "$p" "sh -c 'sudo apt-get install -y jq'"
  is_deny "$output"
  printf '%s' "$output" | grep -qF "needs allowance: sudo"
  run codex_hardhat_bash "$p" "docker ps"
  is_allow
  run codex_hardhat_bash "$p" "brew list"
  is_allow
}

# ---- the owner's emergency helpers outrank the process fence; disarm is total ----

PLUGIN_ROOT="$(cd -P "$BATS_TEST_DIRNAME/../../plugins/nightshift" && pwd -P)"
FOREIGN_NONCE=codex.2.4711.8.9

# codex_sid_bash <project> <session-id> <command> [ENV=VAL ...]
codex_sid_bash() {
  local p="$1" sid="$2" c="$3"
  shift 3
  jq -nc --arg sid "$sid" --arg c "$c" \
    '{tool_name:"Bash",session_id:$sid,tool_input:{command:$c}}' |
    env "$@" CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh"
}

# codex_shift_helper_passes <project> <session-id>
codex_shift_helper_passes() {
  local p="$1" sid="$2" helper out
  for helper in "stop-shift.sh --project $p" "reset-shift.sh --project $p" \
    "purge-workspace.sh --project $p --confirm-path $p"; do
    out="$(codex_sid_bash "$p" "$sid" "bash $PLUGIN_ROOT/runtime/$helper")"
    [ -z "$out" ] || { echo "helper refused: [$sid] $helper -> $out"; return 1; }
  done
  return 0
}

@test "codex runs the owner helpers from any conversation while a live worker holds the lease" {
  p="$(new_project)"
  punch_open "$p"
  sleep 300 &
  holder=$!
  session_record "$p" shift-session "" "" "" codex
  lease_record "$p" shift-session codex 2 "$FOREIGN_NONCE" "$holder" "$(process_start "$holder")"

  codex_shift_helper_passes "$p" shift-session
  codex_shift_helper_passes "$p" helper-thread

  out="$(codex_sid_bash "$p" shift-session "echo hi")"
  is_deny "$out"
  printf '%s' "$out" | grep -q "being recovered in another process"

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

# codex_every_rule_passes <project> <session-id>
codex_every_rule_passes() {
  local p="$1" sid="$2" command out
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    out="$(codex_sid_bash "$p" "$sid" "$command" \
      NIGHTSHIFT_FORBIDDEN_COMMANDS='git push' NIGHTSHIFT_PROTECTED_DIRS='ai_docs')"
    [ -z "$out" ] || { echo "rule applied to a disarmed site: [$sid] $command -> $out"; return 1; }
  done <<'CMDS'
echo hi
git push
git add ai_docs/x
sudo apt-get install -y jq
rm -f .nightshift/.shift-lease
touch .nightshift/STOP
printf '{}' > .nightshift/rules.json
CMDS
  out="$(jq -nc --arg sid "$sid" '{tool_name:"request_user_input",session_id:$sid,tool_input:{}}' |
    env CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh")"
  [ -z "$out" ] || { echo "the question rule applied to a disarmed site: [$sid] -> $out"; return 1; }
  out="$(jq -nc --arg sid "$sid" --arg fp "$p/.nightshift/.shift-session" \
    '{tool_name:"apply_patch",session_id:$sid,tool_input:{patch:("*** Update File: " + $fp)}}' |
    env CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh")"
  [ -z "$out" ] || { echo "the control rule applied to a disarmed site: [$sid] -> $out"; return 1; }
  out="$(jq -nc --arg sid "$sid" \
    '{tool_name:"mcp__filesystem__read_file",session_id:$sid,tool_input:{path:"README.md"}}' |
    env CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh")"
  [ -z "$out" ] || { echo "the fence applied to a disarmed site: [$sid] -> $out"; return 1; }
  return 0
}

@test "codex applies no rule on an unarmed site, whatever the lease still says" {
  p="$(new_project)"
  punch_open "$p"
  sleep 300 &
  holder=$!
  session_record "$p" shift-session "" "" "" codex
  lease_record "$p" shift-session codex 2 "$FOREIGN_NONCE" "$holder" "$(process_start "$holder")"
  rm "$p/.nightshift/.shift-armed"

  codex_every_rule_passes "$p" shift-session
  codex_every_rule_passes "$p" helper-thread
  [ "$(lease_nonce "$p")" = "$FOREIGN_NONCE" ]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

@test "codex applies no rule on a stopped shift, whatever the lease still says" {
  p="$(new_project)"
  punch_open "$p"
  dead="$(reaped_pid)"
  session_record "$p" shift-session "" "" "" codex
  lease_record "$p" shift-session codex 2 "$FOREIGN_NONCE" "$dead" ""
  printf 'stopped by owner\n' >"$p/.nightshift/STOP"
  rm "$p/.nightshift/.shift-armed"

  codex_every_rule_passes "$p" shift-session
  [ "$(reclaim_log_count "$p")" -eq 0 ]
}

@test "a literal parking-lot append may name the rules file" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/parking-lot.md"
  run codex_hardhat_bash "$p" "echo 'needs a change to .nightshift/rules.json' >> .nightshift/parking-lot.md"
  is_allow
}

@test "a real write to the rules file is still refused" {
  p="$(new_project)"
  punch_open "$p"
  run codex_hardhat_bash "$p" "echo '{}' > .nightshift/rules.json"
  is_deny "$output"
}

@test "a parking-lot append through a symlink to the rules file is refused" {
  p="$(new_project)"
  punch_open "$p"
  ln -s rules.json "$p/.nightshift/parking-lot.md"
  run codex_hardhat_bash "$p" "echo 'inert looking note' >> .nightshift/parking-lot.md"
  is_deny "$output"
}

@test "an executable substitution in a parking-lot append is refused" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/parking-lot.md"
  run codex_hardhat_bash "$p" 'echo $(cat .nightshift/rules.json) >> .nightshift/parking-lot.md'
  is_deny "$output"
}

@test "a parking-lot append plus a protected write is refused" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/parking-lot.md"
  run codex_hardhat_bash "$p" "echo 'rules.json' >> .nightshift/parking-lot.md && echo '{}' > .nightshift/rules.json"
  is_deny "$output"
}
