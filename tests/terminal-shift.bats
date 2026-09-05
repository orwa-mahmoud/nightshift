#!/usr/bin/env bats
# A shift that ended stays ended. Adding an unchecked item afterwards, and carrying on in the same
# conversation, must not hold the session again, re-arm the guards, or let the watchman revive it.
# Starting that work as a shift takes an explicit Start and a new identity.

bats_require_minimum_version 1.5.0

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
WATCHMAN="$ROOT/plugins/nightshift/runtime/claude/watchman.sh"

# terminal <project> — the state every ordinary ending leaves behind.
terminal() {
  [ -f "$1/.nightshift/.ended" ] || { echo "no ending marker"; return 1; }
  [ ! -f "$1/.nightshift/.shift-armed" ] || { echo "still armed"; return 1; }
}

# a_new_item <project> — the owner adds work after the shift is over.
a_new_item() {
  printf '## Items\n- [x] **1. first.**\n- [ ] **2. added after the shift ended.**\n' \
    >"$1/.nightshift/punch-list.md"
}

@test "an all-ticked completion ends the shift" {
  p="$(new_project term-done)"
  punch_done "$p"
  run gate "$p"
  is_release
  terminal "$p"
}

@test "quitting time with open items ends the shift" {
  p="$(new_project term-deadline)"
  punch_open "$p"
  echo $(($(date +%s) - 60)) >"$p/.nightshift/deadline"
  run gate "$p"
  is_release
  terminal "$p"
  # The open box stays open: quitting time is not a claim that the work is done.
  grep -qF -- '- [ ] **1. first.**' "$p/.nightshift/punch-list.md"
}

@test "an explicit stop with open items ends the shift" {
  p="$(new_project term-stop)"
  punch_open "$p"
  printf 'owner said so\n' >"$p/.nightshift/STOP"
  run gate "$p"
  is_release
  terminal "$p"
  grep -qF -- '- [ ] **1. first.**' "$p/.nightshift/punch-list.md"
}

@test "the opted-in stall auto-end ends the shift" {
  p="$(new_project term-stall)"
  punch_open "$p"
  run gate "$p" NIGHTSHIFT_STALL_MAX=2
  run gate "$p" NIGHTSHIFT_STALL_MAX=2
  is_release
  terminal "$p"
}

@test "an item added after the ending never holds the session again" {
  for ending in done deadline stop; do
    p="$(new_project "term-readd-$ending")"
    case "$ending" in
      done) punch_done "$p" ;;
      deadline)
        punch_open "$p"
        echo $(($(date +%s) - 60)) >"$p/.nightshift/deadline"
        ;;
      stop)
        punch_open "$p"
        printf 'owner said so\n' >"$p/.nightshift/STOP"
        ;;
    esac
    run gate "$p"
    is_release
    terminal "$p"

    # The owner adds work and carries on in the same conversation.
    a_new_item "$p"
    run gate "$p"
    is_release || { echo "$ending: the ended shift held the session again"; return 1; }
    [ ! -f "$p/.nightshift/.shift-armed" ] \
      || { echo "$ending: the ended shift re-armed itself"; return 1; }
  done
}

@test "the guards stay down after the ending, with an open item present" {
  p="$(new_project term-guards)"
  punch_open "$p"
  # While the shift runs, the owner's own rule holds.
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
  printf 'owner said so\n' >"$p/.nightshift/STOP"
  run gate "$p"
  is_release
  terminal "$p"
  a_new_item "$p"
  # An open box is a to-do list again, not a shift: nothing here is on shift.
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_allow
}

@test "the watchman stands down on an ended shift and will not revive it" {
  p="$(new_project term-watch)"
  punch_done "$p"
  run gate "$p"
  is_release
  terminal "$p"
  a_new_item "$p"
  run env NIGHTSHIFT_WATCH_ONESHOT=1 bash "$WATCHMAN" --project "$p" --max-wakes 1 \
    --agent 'true' --interval 0
  # Whatever the exit path, no revival was attempted and nothing was re-armed.
  [ ! -f "$p/.nightshift/.shift-armed" ]
  if [ -f "$p/.nightshift/shift-log.md" ]; then
    if grep -qiF 'revived' "$p/.nightshift/shift-log.md"; then
      echo "the watchman revived a shift that had ended"
      return 1
    fi
  fi
}

@test "ending twice changes nothing the second time" {
  p="$(new_project term-twice)"
  punch_done "$p"
  run gate "$p"
  is_release
  before="$(find "$p/.nightshift" -maxdepth 1 | LC_ALL=C sort)"
  run gate "$p"
  is_release
  [ "$(find "$p/.nightshift" -maxdepth 1 | LC_ALL=C sort)" = "$before" ]
  terminal "$p"
}

@test "leftover state from the old shift does not make it live again" {
  p="$(new_project term-leftovers)"
  punch_done "$p"
  run gate "$p"
  is_release
  # Everything a finished night can leave behind, all at once.
  printf 'stopped\n' >"$p/.nightshift/STOP"
  echo $(($(date +%s) + 3600)) >"$p/.nightshift/deadline"
  printf 'fingerprint\n7\n' >"$p/.nightshift/.stall"
  printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T00:00:00Z","source":"composition","verificationLevel":"none","toolingPolicy":"existing-tools"}\n' \
    >"$p/.nightshift/shift-policy.json"
  a_new_item "$p"
  run gate "$p"
  is_release
  [ ! -f "$p/.nightshift/.shift-armed" ]
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_allow
}

@test "an explicit start is what makes the added work a shift again" {
  p="$(new_project term-restart)"
  punch_done "$p"
  run gate "$p"
  is_release
  terminal "$p"
  a_new_item "$p"

  # This is the whole difference: someone armed it on purpose.
  : >"$p/.nightshift/.shift-armed"
  rm -f "$p/.nightshift/.ended"
  run gate "$p"
  is_block "$output"
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
}

@test "an ended shift is never reported active because a record was left behind" {
  p="$(new_project term-doctor)"
  punch_done "$p"
  run gate "$p"
  is_release
  terminal "$p"
  # A watchman pidfile and a watch reason outlive the shift they belonged to.
  printf '999999\n' >"$p/.nightshift/.watchman"
  printf 'lint debt\n' >"$p/.nightshift/.watch-reason"
  a_new_item "$p"
  run bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh" --project "$p"
  [ "$status" -eq 0 ]
  # Doctor reports the shift as not armed; a leftover record is not liveness.
  printf '%s\n' "$output" | grep -qE '(armed no|shift ended|not armed)' \
    || { echo "Doctor did not say the shift is over:"; printf '%s\n' "$output" | head -30; return 1; }
  # And it does not claim a shift is running.
  if printf '%s\n' "$output" | grep -qE '^(ok|warn) armed yes'; then
    echo "Doctor called an ended shift armed"
    return 1
  fi
}

@test "a stale worker from the old shift cannot tear down the new one" {
  p="$(new_project term-stale-worker)"
  punch_done "$p"
  run gate "$p"
  is_release
  # The owner starts a fresh shift over the same folder.
  a_new_item "$p"
  rm -f "$p/.nightshift/.ended"
  : >"$p/.nightshift/.shift-armed"
  # The old shift's watchman finally wakes up. It must not stand the new shift down.
  run env NIGHTSHIFT_WATCH_ONESHOT=1 bash "$WATCHMAN" --project "$p" --max-wakes 1 \
    --agent 'true' --interval 0
  [ -f "$p/.nightshift/.shift-armed" ]
  [ ! -f "$p/.nightshift/.ended" ]
  run gate "$p"
  is_block "$output"
}
