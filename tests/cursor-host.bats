#!/usr/bin/env bats
# The Cursor host, driven through its own hooks with its own wire format.
#
# tests/shared-hook-cores.bats proves these adapters carry the same core as Claude's, byte for
# byte. That is evidence about their contents and none about their entry points: what a Cursor
# user actually gets depends on the seam that reads Cursor's payload and writes Cursor's answer,
# and on the entry points reaching the core at all. These run the real hooks.

load helpers

CURSOR="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/cursor"
CURSOR_WATCHMAN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/cursor/watchman.sh"

# cursor_tool <project> <command> [ENV=VAL ...] — a preToolUse payload as Cursor sends it, from the
# shift's own conversation.
cursor_tool() {
  local p="$1" c="$2"
  shift 2
  bind_session "$p" conv-1 cursor
  hook_payload "$(jq -nc --arg c "$c" --arg w "$p" \
    '{tool_name:"Bash",conversation_id:"conv-1",cwd:$w,tool_input:{command:$c}}')" \
    env "$@" CURSOR_PROJECT_DIR="$p" bash "$CURSOR/hardhat.sh"
}

# cursor_stop <project> — a stop payload as Cursor sends it, from the shift's own conversation.
cursor_stop() {
  local p="$1"
  shift
  bind_session "$p" conv-1 cursor
  hook_payload "$(jq -nc --arg w "$p" \
    '{conversation_id:"conv-1",cwd:$w,status:"completed",loop_count:1}')" \
    env "$@" CURSOR_PROJECT_DIR="$p" bash "$CURSOR/clock-out-gate.sh"
}

# Cursor denies with {"permission":"deny","agent_message":…} — its own shape, not Claude's.
cursor_denied() {
  printf '%s' "$1" | jq -e '.permission == "deny" and (.agent_message | length) > 0' >/dev/null
}
# Cursor keeps a session going with {"followup_message":…}; empty stdout lets it stop.
cursor_blocked() {
  printf '%s' "$1" | jq -e '(.followup_message | length) > 0' >/dev/null
}

@test "the Cursor guard denies the owner's forbidden command, in Cursor's own answer" {
  p="$(new_project cursor-forbidden)"
  punch_open "$p"
  run cursor_tool "$p" "git push origin HEAD" NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push'
  [ "$status" -eq 0 ]
  cursor_denied "$output" || { echo "not a Cursor denial: $output"; return 1; }
  printf '%s' "$output" | jq -r .agent_message | grep -qF 'forbidden list'
}

@test "the Cursor guard denies an elevation category the shift does not allow" {
  p="$(new_project cursor-elevation)"
  punch_open "$p"
  run cursor_tool "$p" "sudo apt-get install -y jq"
  cursor_denied "$output" || { echo "not a Cursor denial: $output"; return 1; }
  printf '%s' "$output" | jq -r .agent_message | grep -qF "needs allowance: sudo"
}

@test "the Cursor guard is inert when no shift is running" {
  p="$(new_project cursor-inert)"
  # new_project arms the site; an ordinary session is one that is not on shift.
  rm -f "$p/.nightshift/.shift-armed"
  run cursor_tool "$p" "sudo apt-get install -y jq"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the Cursor guard reads a here-document the way Claude's does" {
  # The rule is the shared core's, but this proves the Cursor entry point reaches it: a quoted
  # documentation write passes and the same body fed to an interpreter does not.
  p="$(new_project cursor-heredoc)"
  punch_open "$p"
  run cursor_tool "$p" "$(printf "cat > docs/e.md <<'EOF'\nsudo and doas, docker run\nEOF")"
  [ -z "$output" ]
  run cursor_tool "$p" "$(printf "bash <<'EOF'\nsudo id\nEOF")"
  cursor_denied "$output" || { echo "an interpreter payload was allowed: $output"; return 1; }
}

@test "the Cursor gate keeps the session going while a box is open" {
  p="$(new_project cursor-gate-open)"
  punch_open "$p"
  run cursor_stop "$p"
  [ "$status" -eq 0 ]
  cursor_blocked "$output" || { echo "the gate let an unfinished shift stop: $output"; return 1; }
}

@test "the Cursor gate lets the session stop once every box is ticked" {
  p="$(new_project cursor-gate-done)"
  printf '## Items\n- [x] **1. done.**\n' >"$p/.nightshift/punch-list.md"
  run cursor_stop "$p"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "the gate held a finished shift: $output"; return 1; }
  [ -f "$p/.nightshift/.ended" ]
  [ ! -f "$p/.nightshift/.shift-armed" ]
}

@test "the Cursor seam reads the same payload with no jq on PATH" {
  # The seam has a sed fallback for a host without jq. It has to find the same fields, or a
  # Cursor user without jq silently loses every guard.
  p="$(new_project cursor-no-jq)"
  punch_open "$p"
  bin="$p/bin"
  mkdir -p "$bin"
  for tool in bash sh sed grep awk tr cat sort head cut date env dirname basename ls mv cp rm find wc mkdir printf git; do
    src="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$src" "$bin/$tool"
  done
  bind_session "$p" conv-1 cursor
  payload="$(jq -nc --arg w "$p" \
    '{tool_name:"Bash",conversation_id:"conv-1",cwd:$w,tool_input:{command:"sudo id"}}')"
  run env -i PATH="$bin" HOME="$HOME" CURSOR_PROJECT_DIR="$p" \
    bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$CURSOR/hardhat.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF '"permission":"deny"' \
    || { echo "no denial without jq: $output"; return 1; }
  printf '%s' "$output" | grep -qF 'needs allowance: sudo'
}

# cursor_pulse <project> <conversation-id>
cursor_pulse() {
  env CURSOR_PROJECT_DIR="$1" bash -c 'printf "%s" "$1" | bash "$2"' _ \
    "$(jq -nc --arg id "$2" --arg w "$1" '{conversation_id:$id,cwd:$w}')" "$CURSOR/pulse.sh"
}

@test "the Cursor pulse records the session that owns the shift, and only that one" {
  p="$(new_project cursor-pulse)"
  punch_open "$p"
  printf 'conv-1\n' >"$p/.nightshift/.shift-session"

  # A pulse from some other conversation is not evidence that the shift is alive.
  run cursor_pulse "$p" conv-9
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$p/.nightshift/.shift-pulse" ] || { echo "a stranger's pulse was recorded"; return 1; }

  # The session that owns it is. Receipt duty rides on the same pulse, as additional_context.
  run cursor_pulse "$p" conv-1
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'additional_context'
  printf '%s' "$output" | grep -qF 'receipts: item'
  [ -f "$p/.nightshift/.shift-pulse" ]
  grep -qF conv-1 "$p/.nightshift/.shift-pulse"
}

@test "in a Cursor session the Claude copy's pulse records nothing and the Cursor copy's records the turn" {
  p="$(new_project cursor-one-copy)"
  punch_open "$p"
  bind_session "$p" conv-1 cursor
  usage="$(bash -c '. "$1"; ns_usage_dir "$2"' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p/.nightshift")"
  # Cursor loads the Claude plugin beside its own and hands it a transcript under ~/.cursor.
  mkdir -p "$BATS_TEST_TMPDIR/home/.cursor/projects/w/agent-transcripts"
  t="$BATS_TEST_TMPDIR/home/.cursor/projects/w/agent-transcripts/conv-1.jsonl"
  cp "$BATS_TEST_DIRNAME/fixtures/usage/claude-multiline.jsonl" "$t"
  run hook_payload "$(jq -nc --arg t "$t" '{session_id:"conv-1",transcript_path:$t,tool_name:"Bash"}')" \
    env CLAUDE_PROJECT_DIR="$p" bash "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/pulse.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$usage/marks.tsv" ] || { echo "the Claude copy wrote a mark"; return 1; }
  [ ! -e "$usage/segments.tsv" ] || { echo "the Claude copy wrote a reading"; return 1; }

  # The Cursor copy takes the turn's reading from its own stop payload, once.
  run hook_payload "$(jq -nc --arg w "$p" '{conversation_id:"conv-1",generation_id:"g1",cwd:$w,input_tokens:700,output_tokens:30}')" \
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR/pulse.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '	arm	' "$usage/marks.tsv")" = 1 ]
  [ "$(cut -f2 "$usage/segments.tsv" | sort -u)" = cursor ]
  [ "$(bash -c '. "$1"; ns_usage_total "$2"' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p/.nightshift")" = 'input=700,output=30' ]
}

@test "the Cursor pulse says nothing once the shift is over" {
  p="$(new_project cursor-pulse-ended)"
  punch_open "$p"
  printf 'conv-1\n' >"$p/.nightshift/.shift-session"
  rm -f "$p/.nightshift/.shift-armed"
  : >"$p/.nightshift/.ended"
  run cursor_pulse "$p" conv-1
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/.shift-pulse" ]
}

@test "the Cursor session end records the ending without ending the shift itself" {
  p="$(new_project cursor-session-end)"
  punch_open "$p"
  run env CURSOR_PROJECT_DIR="$p" bash -c \
    'printf "%s" "$1" | bash "$2"' _ \
    "$(jq -nc --arg w "$p" '{conversation_id:"conv-1",cwd:$w,reason:"window_close"}')" \
    "$CURSOR/session-end.sh"
  [ "$status" -eq 0 ]
  # A closed window is not a clock-out: the shift is still armed and still owes its boxes.
  [ -f "$p/.nightshift/.shift-armed" ]
  [ ! -f "$p/.nightshift/.ended" ]
}

@test "the Cursor watchman stands down on a shift that is not armed" {
  p="$(new_project cursor-watchman)"
  punch_open "$p"
  rm -f "$p/.nightshift/.shift-armed"
  # NIGHTSHIFT_WATCH_SLEEP is the suite's speed lever. Without it `--interval 1` means one minute,
  # and this test spent that long on every run to watch a stand-down that happens on the first wake.
  run env NIGHTSHIFT_WATCH_SLEEP=0 bash "$CURSOR_WATCHMAN" --project "$p" --max-wakes 1 \
    --agent 'true' --interval 1
  [ "$status" -eq 0 ]
  # It leaves no claim behind on a site it is not watching.
  [ ! -f "$p/.nightshift/.watchman" ]
}

@test "a Cursor hook records the model and freezes the permission flags" {
  p="$(new_project cursor-launch-note)"
  printf '## Items\n- [ ] **1.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  printf 'conv-1\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  jq '.recovery.cursorFlags = ["--force", "--yolo", "--trust", "--sandbox"]' \
    "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  hook_payload "$(jq -nc --arg w "$p" \
    '{hook_event_name:"postToolUse",conversation_id:"conv-1",cwd:$w}')" \
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR/pulse.sh"
  grep -qxF 'force=1' "$p/.nightshift/.cursor-launch"
  grep -qxF 'trust=1' "$p/.nightshift/.cursor-launch"
  hook_payload "$(jq -nc --arg w "$p" \
    '{hook_event_name:"postToolUse",conversation_id:"conv-1",cwd:$w,model_id:"composer-2",model:"other"}')" \
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR/pulse.sh"
  if grep -q 'composer-2' "$p/.nightshift/.cursor-launch"; then return 1; fi
  jq '.recovery.cursorFlags = []' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  hook_payload "$(jq -nc --arg w "$p" \
    '{hook_event_name:"postToolUse",conversation_id:"conv-1",cwd:$w,model_id:"other-model"}')" \
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR/pulse.sh"
  if grep -q 'other-model' "$p/.nightshift/.cursor-launch"; then return 1; fi
  grep -qxF 'force=1' "$p/.nightshift/.cursor-launch"
  if grep -q 'sandbox' "$p/.nightshift/.cursor-launch"; then return 1; fi
}

@test "a Cursor hook records the CLI ancestor's model and flags, not the payload base id" {
  p="$(new_project cursor-argv-launch)"
  printf '## Items\n- [ ] **1.**\n' >"$p/.nightshift/punch-list.md"
  stub="$BATS_TEST_TMPDIR/cursor-agent"
  cat >"$stub" <<'EOF'
#!/bin/bash
cmd=()
seen=0
for a in "$@"; do
  if [ "$seen" = 1 ]; then
    cmd+=("$a")
  elif [ "$a" = "--run" ]; then
    seen=1
  fi
done
"${cmd[@]}"
EOF
  chmod +x "$stub"
  lib="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  run "$stub" --model grok-4.7-high --force --trust --run bash -c \
    '. "$1"; ns_cursor_launch_note "$2" "$3"; ns_cursor_launch_read "$2"' _ \
    "$lib" "$p/.nightshift" '{"model_id":"grok-4.7","model":"grok-4.7"}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'grok-4.7-high\t1\t1\t1\t1\t1')" ]
  run bash -c '. "$1"; ns_cursor_launch_note "$2" "$3"; ns_cursor_launch_read "$2"' _ \
    "$lib" "$p/.nightshift" '{"model_id":"grok-4.7","model":"other"}'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'grok-4.7-high\t1\t1\t1\t1\t1')" ]
}

@test "an unreadable Cursor launch records none of the payload model" {
  p="$(new_project cursor-argv-missing)"
  lib="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  out="$BATS_TEST_TMPDIR/launch-read"
  donef="$BATS_TEST_TMPDIR/launch-done"
  script="$BATS_TEST_TMPDIR/launch-note.sh"
  rm -f "$out" "$donef"
  cat >"$script" <<EOF
#!/bin/bash
. "$lib"
ns_cursor_launch_note "$p/.nightshift" '{"model_id":"grok-4.7","model":"grok-4.7"}'
ns_cursor_launch_read "$p/.nightshift" >"$out"
touch "$donef"
EOF
  chmod +x "$script"
  # A note run from this shell can see the IDE's own cursor-agent. Reparenting to pid 1
  # leaves no CLI ancestor, which is the unreadable case.
  python3 -c '
import os, sys
if os.fork() > 0:
    os.wait()
    raise SystemExit(0)
if os.fork() > 0:
    os._exit(0)
os.setsid()
os.execv(sys.argv[1], [sys.argv[1]])
' "$script"
  i=0
  while [ ! -f "$donef" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$donef" ]
  [ "$(head -n 1 "$out")" = "$(printf '\t0\t0\t0\t0\t0')" ]
  if grep -q 'grok-4.7' "$p/.nightshift/.cursor-launch"; then return 1; fi
}

@test "the Cursor gate holds an ended shift once so the model can file it" {
  p="$(new_project cursor-auto-file)"
  printf '## Items\n- [x] **1. done.**\n' >"$p/.nightshift/punch-list.md"
  jq '.archive.automatic = true' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"

  run cursor_stop "$p"
  [ "$status" -eq 0 ]
  cursor_blocked "$output" || { echo "the shift ended without asking for its filing: $output"; return 1; }
  printf '%s' "$output" | jq -r .followup_message | grep -qF 'file it before the session terminates'
  # It really did end: the marker is written and the site is disarmed.
  [ -f "$p/.nightshift/.ended" ]
  [ ! -f "$p/.nightshift/.shift-armed" ]
  [ -f "$p/.nightshift/.pending-filing" ]

  # Stopping again releases, whether or not filing happened.
  run cursor_stop "$p"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the Cursor gate releases a finished shift that asked for nothing" {
  p="$(new_project cursor-auto-off)"
  printf '## Items\n- [x] **1. done.**\n' >"$p/.nightshift/punch-list.md"
  run cursor_stop "$p"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$p/.nightshift/.pending-filing" ]
}
