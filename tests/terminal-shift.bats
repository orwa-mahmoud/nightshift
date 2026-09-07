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
  run env bash "$WATCHMAN" --project "$p" --max-wakes 1 \
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

  # Start's own preflight is what runs, not a hand-placed marker: it has to clear the leftovers of
  # the shift that ended and agree the site may arm again.
  rm -f "$p/.nightshift/.shift-session" "$p/.nightshift/.shift-lease"
  run bash "$ROOT/plugins/nightshift/runtime/start-preflight.sh" --project "$p" --host claude
  [ "$status" -eq 0 ] || { echo "preflight refused a site the owner may restart:"; echo "$output"; return 1; }
  # It clears the ending itself rather than leaving the next shift to trip over it.
  [ ! -f "$p/.nightshift/.ended" ]
  # And it does not arm anything: that is still a deliberate act.
  [ ! -f "$p/.nightshift/.shift-armed" ]
  run gate "$p"
  is_release

  # Arming is the whole difference.
  : >"$p/.nightshift/.shift-armed"
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
  # The old shift's watchman finally wakes up and takes a real wake, long enough to look at the
  # site and decide. --interval is in minutes, so the sleep itself is set in seconds: a genuine
  # wake, not the degenerate one an interval of zero produces.
  run env NIGHTSHIFT_WATCH_SLEEP=1 bash "$WATCHMAN" \
    --project "$p" --max-wakes 1 --agent 'true' --interval 10
  [ -f "$p/.nightshift/.shift-armed" ]
  [ ! -f "$p/.nightshift/.ended" ]
  run gate "$p"
  is_block "$output"
}

@test "a watchman that has been replaced does not delete the new one's claim on its way out" {
  # The exit trap is the danger: a loop that has already lost the site would otherwise remove the
  # pidfile naming its replacement, leaving the site watched by a loop nothing records.
  p="$(new_project term-pidfile-handover)"
  punch_open "$p"
  pidfile="$p/.nightshift/.watchman"

  : >"$p/.nightshift/.shift-armed"
  # A watchman that sleeps long enough to be replaced while it waits. Two seconds of sleep, not
  # two minutes: --interval is in minutes and NIGHTSHIFT_WATCH_SLEEP is the seconds it actually
  # waits, so the window is real and the test still finishes.
  env NIGHTSHIFT_WATCH_SLEEP=2 bash "$WATCHMAN" \
    --project "$p" --max-wakes 1 --agent 'true' --interval 10 >/dev/null 2>&1 &
  old=$!
  claimed=""
  for _ in $(seq 1 40); do
    if [ -s "$pidfile" ]; then
      claimed="$(sed -n 1p "$pidfile")"
      break
    fi
    sleep 0.1
  done
  [ -n "$claimed" ] || { kill "$old" 2>/dev/null; echo "the watchman never claimed the site"; return 1; }

  # Its replacement takes the site over by putting its own pid in the file, the way a takeover
  # does, and the owner disarms — so the old loop wakes, finds the shift over, and exits by the
  # ordinary route rather than the one that notices a lost claim.
  printf '424242\n' >"$pidfile"
  rm -f "$p/.nightshift/.shift-armed"

  # Bounded: a test that waits forever on a child takes the whole suite with it.
  gone=0
  for _ in $(seq 1 100); do
    kill -0 "$old" 2>/dev/null || { gone=1; break; }
    sleep 0.1
  done
  if [ "$gone" -ne 1 ]; then
    kill "$old" 2>/dev/null
    echo "the watchman did not stand down within ten seconds"
    return 1
  fi

  # The claim that outlived it is the replacement's, not a file the old loop swept away.
  [ -f "$pidfile" ] || { echo "the old watchman deleted its replacement's claim"; return 1; }
  [ "$(sed -n 1p "$pidfile")" = 424242 ]
}

@test "every watchman guards that trap, so no host loses a claim on exit" {
  # One line each, and all three have to have it: the bash halves share this shape rather than
  # this file.
  for host in claude codex cursor; do
    w="$ROOT/plugins/nightshift/runtime/$host/watchman.sh"
    grep -qF "trap 'holds_pidfile && rm -f \"\$PIDFILE\"' EXIT" "$w" \
      || { echo "$host removes the pidfile unconditionally"; return 1; }
  done
}
