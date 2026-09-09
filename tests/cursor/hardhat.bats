load ../helpers

HOOKS="$BATS_TEST_DIRNAME/../../plugins/nightshift/hooks"
CURSOR_HOOKS="$HOOKS/cursor"
FIXTURES="$BATS_TEST_DIRNAME/../fixtures/hooks/v1/cursor"
RULES_TEMPLATE="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json"

is_cursor_deny() {
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.permission == "deny"' >/dev/null
}

@test "AskQuestion is parked with the template's own message" {
  p="$(new_project)"
  punch_open "$p"
  jq -nc --arg p "$p" \
    '{tool_name:"AskQuestion",conversation_id:"cursor-tab",transcript_path:"",cwd:$p,tool_input:{}}' \
    >"$BATS_TEST_TMPDIR/ask-question.json"
  run env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh" <"$BATS_TEST_TMPDIR/ask-question.json"
  is_cursor_deny
  printf '%s' "$output" | grep -q "park"
}

@test "cursor hardhat denies a forbidden Shell command during a shift" {
  p="$(new_project)"
  punch_open "$p"
  run env CURSOR_PROJECT_DIR="$p" NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push' \
    bash "$CURSOR_HOOKS/hardhat.sh" <"$FIXTURES/shell-forbidden.json"
  is_cursor_deny
}

@test "cursor hardhat records the cursor host from a cursor transcript path" {
  p="$(new_project)"
  punch_open "$p"
  jq -nc --arg p "$p" \
    '{tool_name:"Shell",conversation_id:"cursor-tab",transcript_path:"/Users/o/.cursor/projects/x/agent-transcripts/u/u.jsonl",cwd:$p,tool_input:{command:"echo hi"}}' |
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "cursor-tab" ]
  [ "$(sed -n 5p "$p/.nightshift/.shift-session")" = "cursor" ]
  [ "$(sed -n 2p "$p/.nightshift/.shift-lease")" = "cursor" ]
}

@test "cursor hardhat reclaims a claude-contaminated lease for the same session" {
  p="$(new_project)"
  punch_open "$p"
  printf '%s\n' cursor-tab \
    '/Users/o/.cursor/projects/x/agent-transcripts/u/u.jsonl' '' '' cursor \
    >"$p/.nightshift/.shift-session"
  printf '%s\n' cursor-tab claude 1 '' '' '' >"$p/.nightshift/.shift-lease"
  chmod 600 "$p/.nightshift/.shift-session" "$p/.nightshift/.shift-lease"
  jq -nc --arg p "$p" \
    '{tool_name:"Shell",conversation_id:"cursor-tab",transcript_path:"/Users/o/.cursor/projects/x/agent-transcripts/u/u.jsonl",cwd:$p,tool_input:{command:"echo hi"}}' |
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh"
  [ "$(sed -n 1p "$p/.nightshift/.shift-lease")" = "cursor-tab" ]
  [ "$(sed -n 2p "$p/.nightshift/.shift-lease")" = "cursor" ]
}

# ---- the site rules bind the shift's session; other conversations keep their tools ----

@test "another conversation is untouched by the site rules" {
  p="$(new_project)"
  punch_open "$p"
  printf 'the-shift\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  out="$(jq -nc --arg p "$p" \
    '{tool_name:"Shell",conversation_id:"helper-tab",transcript_path:"",cwd:$p,tool_input:{command:"git push origin main"}}' |
    env NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push' CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh")"
  [ -z "$out" ]
}

@test "the shift session itself still answers to the site rules" {
  p="$(new_project)"
  punch_open "$p"
  printf 'the-shift\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  jq -nc --arg p "$p" \
    '{tool_name:"Shell",conversation_id:"the-shift",transcript_path:"",cwd:$p,tool_input:{command:"git push origin main"}}' \
    >"$BATS_TEST_TMPDIR/held-shell.json"
  run env NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push' CURSOR_PROJECT_DIR="$p" \
    bash "$CURSOR_HOOKS/hardhat.sh" <"$BATS_TEST_TMPDIR/held-shell.json"
  is_cursor_deny
}

@test "origin tab is pointed at the live CLI worker" {
  p="$(new_project)"
  punch_open "$p"
  printf 'origin-ide\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  printf 'live-cli-worker\n' >"$p/.nightshift/.shift-worker"
  jq -nc --arg p "$p" \
    '{tool_name:"Shell",conversation_id:"origin-ide",transcript_path:"",cwd:$p,tool_input:{command:"echo hi"}}' \
    >"$BATS_TEST_TMPDIR/origin-shell.json"
  run env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh" <"$BATS_TEST_TMPDIR/origin-shell.json"
  is_cursor_deny
  printf '%s' "$output" | grep -q 'agent --resume='
  printf '%s' "$output" | grep -q 'live-cli-worker'
  printf '%s' "$output" | grep -q -- "--workspace"
  printf '%s' "$output" | grep -q 'terminal'
  printf '%s' "$output" | grep -q 'ask Nightshift to stop'
}

@test "origin tab can still run the stop helper while a worker is live" {
  p="$(new_project)"
  punch_open "$p"
  printf 'origin-ide\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  printf 'live-cli-worker\n' >"$p/.nightshift/.shift-worker"
  plugin="$BATS_TEST_DIRNAME/../../plugins/nightshift"
  jq -nc --arg p "$p" --arg cmd "bash $plugin/runtime/stop-shift.sh --project $p" \
    '{tool_name:"Shell",conversation_id:"origin-ide",transcript_path:"",cwd:$p,tool_input:{command:$cmd}}' \
    >"$BATS_TEST_TMPDIR/origin-stop-helper.json"
  run env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh" <"$BATS_TEST_TMPDIR/origin-stop-helper.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "another conversation stays free while a CLI worker is recorded" {
  p="$(new_project)"
  punch_open "$p"
  printf 'origin-ide\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  printf 'live-cli-worker\n' >"$p/.nightshift/.shift-worker"
  out="$(jq -nc --arg p "$p" \
    '{tool_name:"Shell",conversation_id:"helper-tab",transcript_path:"",cwd:$p,tool_input:{command:"git push origin main"}}' |
    env NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push' CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh")"
  [ -z "$out" ]
}

@test "cursor binding probe is recognized on Shell" {
  p="$(new_project)"
  punch_open "$p"
  jq -nc --arg p "$p" \
    '{tool_name:"Shell",conversation_id:"bind-me",transcript_path:"",cwd:$p,tool_input:{command:": nightshift-binding-probe"}}' |
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "bind-me" ]
  [ "$(sed -n 5p "$p/.nightshift/.shift-session")" = "cursor" ]
}

# --- the policy files are control files, and elevation is the owner's switch ---

# cursor_shell <project> <command> — the Shell payload this host sends.
cursor_shell() {
  local p="$1" c="$2"
  jq -nc --arg p "$p" --arg c "$c" \
    '{tool_name:"Shell",conversation_id:"cursor-tab",transcript_path:"",cwd:$p,tool_input:{command:$c}}' |
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh"
}

@test "cursor denies rewriting the shift policy, its defaults, and the deadline" {
  p="$(new_project)"
  punch_open "$p"
  for f in shift-policy.json shift-defaults.json deadline; do
    run cursor_shell "$p" "printf 'forged' > .nightshift/$f"
    is_cursor_deny || { echo "path rewrite allowed: $f"; return 1; }
    printf '%s' "$output" | grep -qF "$f" || { echo "deny does not name $f"; return 1; }
    run cursor_shell "$p" "cd .nightshift && rm -f $f"
    is_cursor_deny || { echo "name delete allowed: $f"; return 1; }
  done
}

@test "cursor denies an elevation category by default and honours an allowance" {
  p="$(new_project)"
  punch_open "$p"
  run cursor_shell "$p" "docker compose up -d"
  is_cursor_deny
  printf '%s' "$output" | grep -qF "needs allowance: containers"
  printf '%s' "$output" | grep -qF "elevation.containers.policy"
  jq -nc '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T02:30:00Z",
    source:"composition",deadlineEpoch:null,verificationLevel:"final",
    toolingPolicy:"existing-tools",
    allowances:[{category:"containers",scope:"category",provenance:"one-shift"}]}' \
    >"$p/.nightshift/shift-policy.json"
  run cursor_shell "$p" "docker compose up -d"
  is_allow
}

@test "cursor leaves a command that only uses the dev stack alone" {
  p="$(new_project)"
  punch_open "$p"
  run cursor_shell "$p" "psql -c 'select 1'"
  is_allow
  run cursor_shell "$p" "git commit -m 'sudo apt-get install jq'"
  is_allow
}

@test "cursor create-state elevation denies bypass forms and leaves reads alone" {
  p="$(new_project)"
  punch_open "$p"
  run cursor_shell "$p" "/usr/bin/sudo id"
  is_cursor_deny
  printf '%s' "$output" | grep -qF "needs allowance: sudo"
  run cursor_shell "$p" "docker run alpine"
  is_cursor_deny
  printf '%s' "$output" | grep -qF "needs allowance: containers"
  run cursor_shell "$p" "docker ps"
  is_allow
  run cursor_shell "$p" "brew list"
  is_allow
}

# ---- the owner's emergency helpers outrank the process fence; disarm is total ----

PLUGIN_ROOT="$(cd -P "$BATS_TEST_DIRNAME/../../plugins/nightshift" && pwd -P)"
FOREIGN_NONCE=cursor.2.4711.8.9

# cursor_sid_shell <project> <conversation-id> <command> [ENV=VAL ...]
cursor_sid_shell() {
  local p="$1" sid="$2" c="$3"
  shift 3
  jq -nc --arg p "$p" --arg sid "$sid" --arg c "$c" \
    '{tool_name:"Shell",conversation_id:$sid,transcript_path:"",cwd:$p,tool_input:{command:$c}}' |
    env "$@" CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh"
}

# cursor_shift_helper_passes <project> <conversation-id>
cursor_shift_helper_passes() {
  local p="$1" sid="$2" helper out
  for helper in "stop-shift.sh --project $p" "reset-shift.sh --project $p" \
    "purge-workspace.sh --project $p --confirm-path $p"; do
    out="$(cursor_sid_shell "$p" "$sid" "bash $PLUGIN_ROOT/runtime/$helper")"
    [ -z "$out" ] || { echo "helper refused: [$sid] $helper -> $out"; return 1; }
  done
  return 0
}

@test "cursor runs the owner helpers from any conversation while a live worker holds the lease" {
  p="$(new_project)"
  punch_open "$p"
  sleep 300 &
  holder=$!
  session_record "$p" cursor-tab "" "" "" cursor
  lease_record "$p" cursor-tab cursor 2 "$FOREIGN_NONCE" "$holder" "$(process_start "$holder")"

  cursor_shift_helper_passes "$p" cursor-tab
  cursor_shift_helper_passes "$p" helper-tab

  run cursor_sid_shell "$p" cursor-tab "echo hi"
  is_cursor_deny
  printf '%s' "$output" | grep -q "being recovered in another process"

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

# cursor_every_rule_passes <project> <conversation-id>
cursor_every_rule_passes() {
  local p="$1" sid="$2" command out
  while IFS= read -r command; do
    [ -n "$command" ] || continue
    out="$(cursor_sid_shell "$p" "$sid" "$command" \
      NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push' NIGHTSHIFT_PROTECTED_DIRS='ai_docs')"
    [ -z "$out" ] || { echo "rule applied to a disarmed site: [$sid] $command -> $out"; return 1; }
  done <<'CMDS'
echo hi
git push origin main
git add ai_docs/x
sudo apt-get install -y jq
rm -f .nightshift/.shift-lease
touch .nightshift/STOP
printf '{}' > .nightshift/rules.json
CMDS
  out="$(jq -nc --arg p "$p" --arg sid "$sid" \
    '{tool_name:"request_user_input",conversation_id:$sid,transcript_path:"",cwd:$p,tool_input:{}}' |
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh")"
  [ -z "$out" ] || { echo "the question rule applied to a disarmed site: [$sid] -> $out"; return 1; }
  out="$(jq -nc --arg p "$p" --arg sid "$sid" --arg fp "$p/.nightshift/.shift-session" \
    '{tool_name:"Write",conversation_id:$sid,transcript_path:"",cwd:$p,tool_input:{file_path:$fp,content:"forged"}}' |
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh")"
  [ -z "$out" ] || { echo "the control rule applied to a disarmed site: [$sid] -> $out"; return 1; }
  out="$(jq -nc --arg p "$p" --arg sid "$sid" \
    '{tool_name:"Read",conversation_id:$sid,transcript_path:"",cwd:$p,tool_input:{file_path:"README.md"}}' |
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh")"
  [ -z "$out" ] || { echo "the fence applied to a disarmed site: [$sid] -> $out"; return 1; }
  return 0
}

@test "cursor applies no rule on an unarmed site, whatever the lease still says" {
  p="$(new_project)"
  punch_open "$p"
  sleep 300 &
  holder=$!
  session_record "$p" cursor-tab "" "" "" cursor
  lease_record "$p" cursor-tab cursor 2 "$FOREIGN_NONCE" "$holder" "$(process_start "$holder")"
  rm "$p/.nightshift/.shift-armed"

  cursor_every_rule_passes "$p" cursor-tab
  cursor_every_rule_passes "$p" helper-tab
  [ "$(lease_nonce "$p")" = "$FOREIGN_NONCE" ]

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

@test "cursor applies no rule on a stopped shift, whatever the lease still says" {
  p="$(new_project)"
  punch_open "$p"
  dead="$(reaped_pid)"
  session_record "$p" cursor-tab "" "" "" cursor
  lease_record "$p" cursor-tab cursor 2 "$FOREIGN_NONCE" "$dead" ""
  printf 'stopped by owner\n' >"$p/.nightshift/STOP"
  rm "$p/.nightshift/.shift-armed"

  cursor_every_rule_passes "$p" cursor-tab
  [ "$(reclaim_log_count "$p")" -eq 0 ]
}

@test "cursor reclaims a lease left by a dead recovery attempt for the recorded tab" {
  p="$(new_project)"
  punch_open "$p"
  dead="$(reaped_pid)"
  session_record "$p" cursor-tab "" "" "" cursor
  lease_record "$p" cursor-tab cursor 2 "$FOREIGN_NONCE" "$dead" ""

  run cursor_sid_shell "$p" cursor-tab "echo hi"
  is_allow
  [ "$(lease_generation "$p")" = "3" ]
  [ -z "$(lease_nonce "$p")" ]
  [ "$(reclaim_log_count "$p" 2 3)" -eq 1 ]
}

@test "a literal parking-lot append may name the rules file" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/parking-lot.md"
  run cursor_sid_shell "$p" cursor-tab "echo 'needs a change to .nightshift/rules.json' >> .nightshift/parking-lot.md"
  is_allow
}

@test "a real write to the rules file is still refused" {
  p="$(new_project)"
  punch_open "$p"
  run cursor_sid_shell "$p" cursor-tab "echo '{}' > .nightshift/rules.json"
  is_cursor_deny
}

@test "a parking-lot append through a symlink to the rules file is refused" {
  p="$(new_project)"
  punch_open "$p"
  ln -s rules.json "$p/.nightshift/parking-lot.md"
  run cursor_sid_shell "$p" cursor-tab "echo 'inert looking note' >> .nightshift/parking-lot.md"
  is_cursor_deny
}

@test "an executable substitution in a parking-lot append is refused" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/parking-lot.md"
  run cursor_sid_shell "$p" cursor-tab 'echo $(cat .nightshift/rules.json) >> .nightshift/parking-lot.md'
  is_cursor_deny
}

@test "a parking-lot append plus a protected write is refused" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/parking-lot.md"
  run cursor_sid_shell "$p" cursor-tab "echo 'rules.json' >> .nightshift/parking-lot.md && echo '{}' > .nightshift/rules.json"
  is_cursor_deny
}
