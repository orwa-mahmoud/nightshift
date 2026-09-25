load ../helpers

# helpers.bash anchors its paths one directory up; from tests/codex/ the repo root is two.
HOOKS="$BATS_TEST_DIRNAME/../../plugins/nightshift/hooks"
RULES_TEMPLATE="$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json"
CODEX_HOOKS="$HOOKS/codex"

# Codex Stop expects JSON on stdout even when the stop is permitted — empty stdout is the
# Claude convention, not this host's. A release is {"continue":true} and never a block.
is_codex_release() {
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.continue == true' >/dev/null
  if printf '%s' "$output" | grep -q '"decision":"block"'; then
    return 1
  fi
}

# codex_gate <project> [ENV=VAL ...] — pipes a minimal Stop payload from the shift's own
# conversation to the Codex gate, with CODEX_PROJECT_DIR as the explicit override lever.
codex_gate() {
  local p="$1"
  shift
  bind_session "$p" test-shift-session codex
  hook_payload "$(jq -nc '{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}')" \
    env "$@" CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/clock-out-gate.sh"
}

@test "codex gate blocks while a box is open" {
  p="$(new_project)"
  punch_open "$p"
  run codex_gate "$p"
  is_block "$output"
}

# The payload's cwd is the documented carrier of the working directory (transcript_path may be
# null); the gate must find the shift from stdin alone, with no env override set.
@test "the payload cwd alone locates the shift" {
  p="$(new_project)"
  punch_open "$p"
  bind_session "$p" test-shift-session codex
  out="$(jq -nc --arg p "$p" '{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:null,cwd:$p}' |
    bash "$CODEX_HOOKS/clock-out-gate.sh")"
  is_block "$out"
}

@test "codex gate releases when every box is ticked" {
  p="$(new_project)"
  punch_done "$p"
  run codex_gate "$p"
  is_codex_release
}

@test "codex gate missing punch list still ends through end_shift" {
  p="$(new_project)"
  rm -f "$p/.nightshift/punch-list.md"
  run codex_gate "$p"
  is_codex_release
  [ -f "$p/.nightshift/.ended" ]
  [ ! -f "$p/.nightshift/.shift-armed" ]
}

@test "codex gate honors a stop-work order even with open boxes" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/STOP"
  run codex_gate "$p"
  is_codex_release
}

@test "codex gate releases at quitting time, writes STOP and a shift-log line" {
  p="$(new_project)"
  punch_open "$p"
  echo $(($(date +%s) - 60)) >"$p/.nightshift/deadline"
  run codex_gate "$p"
  is_codex_release
  [ -f "$p/.nightshift/STOP" ]
  grep -q 'quitting time' "$p/.nightshift/shift-log.md"
}

@test "an unarmed site releases freely — a list alone is not a shift" {
  p="$(new_project)"
  rm "$p/.nightshift/.shift-armed"
  punch_open "$p"
  run codex_gate "$p"
  is_codex_release
  [ ! -f "$p/.nightshift/.shift-session" ]
}

@test "the codex gate holds the session its binding probe recorded with codex as its host" {
  p="$(new_project)"
  punch_open "$p"
  jq -nc '{tool_name:"Bash",session_id:"test-shift-session",transcript_path:"",tool_input:{command:": nightshift-binding-probe"}}' |
    CODEX_PROJECT_DIR="$p" bash "$CODEX_HOOKS/hardhat.sh"
  run codex_gate "$p"
  is_block "$output"
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "test-shift-session" ]
  [ "$(wc -l <"$p/.nightshift/.shift-session")" -eq 5 ] # id, transcript, pid, start time, host
  # No codex process ancestry is claimed — an invented pid would send a watchman after the
  # wrong process. The host line is what keeps Claude's watchman off this shift.
  [ -z "$(sed -n 3p "$p/.nightshift/.shift-session")" ]
  [ "$(sed -n 5p "$p/.nightshift/.shift-session")" = "codex" ]
}

@test "another conversation's stop is not the shift's business — released" {
  p="$(new_project)"
  punch_open "$p"
  printf 'the-shift\n\n\n\ncodex\n' >"$p/.nightshift/.shift-session"
  run codex_gate "$p" # this stop arrives as test-shift-session, not the-shift
  is_codex_release
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "the-shift" ] # record untouched
  [ ! -f "$p/.nightshift/.ended" ]
}

@test "the stall opt-in ends the shift after N no-progress stop attempts" {
  p="$(new_project)"
  punch_open "$p"
  run codex_gate "$p" NIGHTSHIFT_STALL_MAX=2
  is_block "$output"
  run codex_gate "$p" NIGHTSHIFT_STALL_MAX=2
  is_codex_release
  grep -q 'stalled' "$p/.nightshift/STOP"
  grep -q 'stalled — auto-ended' "$p/.nightshift/shift-log.md"
}

@test "a symlink stall does not auto-end the Codex shift" {
  p="$(new_project)"
  punch_open "$p"
  run codex_gate "$p" NIGHTSHIFT_STALL_MAX=2
  is_block "$output"
  fp="$(sed -n 1p "$p/.nightshift/.stall")"
  printf '%s\n99\n' "$fp" >"$p/.nightshift/stall-plant"
  rm -f "$p/.nightshift/.stall"
  ln -s stall-plant "$p/.nightshift/.stall"
  run codex_gate "$p" NIGHTSHIFT_STALL_MAX=2
  is_block "$output"
  [ -f "$p/.nightshift/.stall" ]
  [ ! -L "$p/.nightshift/.stall" ]
  [ "$(sed -n 2p "$p/.nightshift/.stall")" = "1" ]
  [ ! -f "$p/.nightshift/STOP" ]
}

# The owner's text routes through the seam's emitter, so a quote in it must never break the
# JSON and void the block.
@test "the owner's clock-out message survives the codex emitter intact" {
  p="$(new_project)"
  punch_open "$p"
  run codex_gate "$p" NIGHTSHIFT_GATE_MESSAGE='back to the bench — "boxes" are open'
  is_block "$output"
  printf '%s' "$output" | grep -q 'back to the bench'
}

# Zero open boxes reached by deleting work, or by editing the contract, is not done.
@test "codex gate blocks a done clock-out after the open item was deleted" {
  p="$(new_project)"
  punch_open "$p"
  arm_snapshot "$p"
  printf '## Items\n- [x] **2. done.**\n' >"$p/.nightshift/punch-list.md"
  run codex_gate "$p"
  is_block "$output"
  [ ! -e "$p/.nightshift/.ended" ]
}

@test "codex gate blocks a done clock-out after the punch list was deleted" {
  p="$(new_project)"
  punch_open "$p"
  arm_snapshot "$p"
  rm "$p/.nightshift/punch-list.md"
  run codex_gate "$p"
  is_block "$output"
  [ ! -e "$p/.nightshift/.ended" ]
}

@test "codex gate releases a list finished by ticks alone" {
  p="$(new_project)"
  punch_open "$p"
  arm_snapshot "$p"
  punch_done "$p"
  run codex_gate "$p"
  is_codex_release
  [ -e "$p/.nightshift/.ended" ]
}

@test "codex clock-out files the shift policy into the folder it claims for the shift" {
  p="$(new_project)"
  punch_done "$p"
  printf '%s\n' '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-25T00:00:00Z","source":"composition","verificationLevel":"none","toolingPolicy":"existing-tools"}' >"$p/.nightshift/shift-policy.json"
  run codex_gate "$p"
  is_codex_release
  d="$p/.nightshift/archive/$(sed -n 's/^archiveFolder=//p' "$p/.nightshift/.ended")"
  [ "$(cat "$d/.shift-id")" = 9f2c40ab77e51d63 ]
  jq -e '.shiftId == "9f2c40ab77e51d63"' "$d/shift-policy.json" >/dev/null
  [ ! -e "$p/.nightshift/shift-policy.json" ]
}
