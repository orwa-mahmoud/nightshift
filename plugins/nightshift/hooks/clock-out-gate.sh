#!/usr/bin/env bash
# clock-out-gate.sh — Stop hook.
#
# The punch list is the only truth. Release order on every stop attempt:
#   1. stop-work order — .nightshift/STOP exists              -> release (open boxes stay open)
#   2. done            — zero open "- [ ]" (or no punch list), and no ticked item
#                        whose evidence check is block with a file still missing -> release
#   3. quitting time   — now past .nightshift/run/deadline    -> write STOP, log, release
#   4. otherwise       — block, re-injecting the contract
#
# Stall guard: consecutive stop attempts with no progress are counted (progress = a tick or a
# commit in repository mode, or a tick or an artifact receipt in artifact mode). By default a stalled shift is HELD — every 3 stuck attempts a stall warning lands
# in the shift log and the gate keeps blocking; only STOP, done, or the deadline release.
# Owner opt-in: stallMax N in the rules file auto-ends the shift (write STOP, log, release)
# after N stuck attempts — the file is guarded during a shift, so only a human chooses that.
#
# Quitting time and the stall opt-in are a whistle, not an axe: a Stop hook can only run at
# a stop attempt, so neither can ever interrupt work mid-item.
#
# Morning whistle: if the rules file sets notifyCommand, any shift-ending release fires it
# exactly once with a one-line summary (both $NIGHTSHIFT_SUMMARY and $1). Empty -> silent.
#
# Receipts: any shift-ending release also snapshots .nightshift/ into its local receipts repo
# (the one Nightshift Setup created). No receipts repo -> no-op; a failed commit never blocks
# the release.
#
# Morning receipt: any shift-ending release renders the owner view of the night to
# .nightshift/receipts/morning-<YYYY-MM-DD>-<shiftId>.md before the snapshot, so the page the
# owner reads is inside it. Best effort — a renderer that is absent or fails leaves one line in
# the shift log and never blocks the release.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck disable=SC2034 # read by cold-stop.sh
NS_COLD_STOP_HOST=claude
# shellcheck source=plugins/nightshift/hooks/shared/cold-stop.sh
. "$_here/shared/cold-stop.sh"
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh" # pure-bash path: no dirname, so a hostile PATH cannot unsource the helpers
ns_copy_serves_host "$_here/.." claude || exit 0
# shellcheck source=plugins/nightshift/hooks/shared/gate-core.sh
. "$_here/shared/gate-core.sh"

# The Stop payload carries the session's identity, read under a bound so neither a manual run nor
# a descriptor that never closes hangs the hook.
INPUT="$(ns_read_stdin_bounded 2)"
if command -v jq >/dev/null 2>&1; then
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
  TPATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
else
  SID="$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  TPATH="$(printf '%s' "$INPUT" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi

HOST_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if ! PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)"; then
  printf '%s\n' '{"decision":"block","reason":"DO NOT STOP — .nightshift-link is invalid. Open the correct project task or repair the explicit link to an absolute workspace containing .nightshift/."}'
  exit 0
fi
STATE_KIND="$(ns_state_kind "$PROJECT_DIR")"
case "$STATE_KIND" in
  malformed | future)
    printf '%s\n' "{\"decision\":\"block\",\"reason\":\"DO NOT STOP — $(ns_state_refuse_message "$STATE_KIND")\"}"
    exit 0
    ;;
esac
NS="$PROJECT_DIR/.nightshift"
# shellcheck disable=SC2034 # read by gate-core.sh
declare PUNCH STOP DEADLINE STALL ARMED LOG
ns_layout_set PUNCH "$NS" punch-list
ns_layout_set STOP "$NS" stop
ns_layout_set DEADLINE "$NS" deadline
ns_layout_set STALL "$NS" stall
ns_layout_set ARMED "$NS" armed
ns_layout_set LOG "$NS" shift-log
# One copy: the rules file is the config; env vars are session-start overrides only. The
# shipped values live visibly in the file setup copies — no fallbacks hide here. A gate whose
# knobs are unreadable still gates (fail closed): the stall bookkeeping stands down loudly and
# the block carries the repair.
STALL_MAX="$(rule "$PROJECT_DIR" stallMax "${NIGHTSHIFT_STALL_MAX:-}")"
STALL_WARN="$(rule "$PROJECT_DIR" stallWarnEvery "${NIGHTSHIFT_STALL_WARN:-}")"
LONG_UNIT_WARN="$(rule "$PROJECT_DIR" longUnitWarnMinutes "${NIGHTSHIFT_LONG_UNIT_WARN:-}")"
STALL_OK=1
case "$STALL_MAX" in '' | *[!0-9]*) STALL_OK=0 ;; esac
case "$STALL_WARN" in '' | *[!0-9]* | 0) STALL_OK=0 ;; esac
GATE_MESSAGE="$(ns_expand_injected_paths "$PROJECT_DIR" "$(rule "$PROJECT_DIR" clockOutMessage "${NIGHTSHIFT_GATE_MESSAGE:-}")")"

_ns_clock_out_block() {
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$1" '{decision:"block",reason:$r}'
    return
  fi
  escaped="$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"decision":"block","reason":"%s"}\n' "$escaped"
}

ts() { ns_local_now second; }
log_line() { [ -d "$NS" ] && printf '%s · %s\n' "$(ts)" "$1" >>"$LOG"; }

# Only the Items list is the shift. A checkbox above it is prose — an owner's note, an example in
# the contract — and counting it would hold a session over something nobody queued. The heading
# must stand alone on its line, so the contract's inline `## Items` references never match.
# ns_gate_boxes reads those counts.

# Stall progress is a tick plus either work-target HEAD (repository mode) or the artifact
# receipts fingerprint (artifact mode). ns_gate_progress_token chooses.
deadline_passed() { ns_gate_deadline_passed; }

# The terminal sequence lives once, in gate-core.sh. The watchman calls the same function.
end_shift() { ns_shift_end "$PROJECT_DIR" "$1"; }

# Every ending runs through here. The shift is over by now — the marker is written and the site is
# disarmed — so asking the model to file is a request it can actually carry out, and the one hold
# left in a finished shift is that request. Asking is recorded, so the next stop releases either
# way: a session that could not file leaves the marker for the next explicit Archive rather than
# being held forever by a hook that cannot do the filing itself.
end_and_stop() {
  end_shift "$1"
  hold="$(ns_gate_ending_hold "$NS")"
  if [ -n "$hold" ]; then
    log_line "holding once so this shift's snags and filing are settled before the session ends"
    _ns_clock_out_block "$hold"
  fi
  exit 0
}

PUNCH_UNREADABLE=0
if ! ns_gate_boxes; then
  PUNCH_UNREADABLE=1
fi

honor_stop() {
  local reason summary
  if [ -f "$PUNCH" ]; then
    reason="$(head -n1 "$STOP" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    summary="shift ended${reason:+ ($reason)}: $TICKED/$TOTAL done"
    end_and_stop "$summary"
  else
    reason="$(head -n1 "$STOP" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    end_and_stop "shift ended${reason:+ ($reason)}: $TICKED/$TOTAL done"
  fi
}

# Record conversation continuity and claim the original process lease if hardhat did not already
# do it. A watchman child must present its exact nonce + generation before this Stop event may
# touch shared shift state.
ns_host_process claude "$NS" "$$"
CURRENT_PID="$NS_CURRENT_PID"
CURRENT_START="$NS_CURRENT_START"
# A shift exists because the owner started one, never because a list exists. Nightshift Start
# writes .shift-armed; without it the punch list is a to-do file and every session stops freely —
# including the one that just wrote the list while planning.
# The shift has ended and the owner asked for filing. Hold the session once more so the model can
# file before it terminates — the shift is genuinely over by now, which is what makes filing legal
# and the request executable. Asking is recorded, so stopping again releases either way.
if ns_gate_filing_due "$NS"; then
  log_line "archive.automatic is on - holding once so this shift can be filed before the session ends"
  _ns_clock_out_block "$(ns_gate_filing_message "$NS")"
  exit 0
fi
[ -f "$ARMED" ] || exit 0


# STOP is an owner capability, not a worker capability. Any Stop event may carry an existing
# owner-issued order through clock-out; process ownership must never make emergency stop unusable.
if [ -f "$STOP" ]; then
  if [ -d "$NS" ] && ns_lock "$NS"; then trap 'ns_unlock "$NS"' EXIT; fi
  # honor_stop ends the shift and terminates: every path through it releases or holds for filing.
  honor_stop
fi

# Cursor IDE also runs this Claude gate; leave Cursor's gate as the only clock-out owner.
if ns_claude_foreign_cursor_surface "$NS" "${TPATH:-}"; then
  exit 0
fi

# shellcheck disable=SC2034 # read by ownership.sh
LEASE_NONCE="${NIGHTSHIFT_LEASE_NONCE:-}"
# shellcheck disable=SC2034 # read by ownership.sh
LEASE_GENERATION="${NIGHTSHIFT_LEASE_GENERATION:-}"
ns_shift_unbound claude gate
own_rc=$?
[ "$own_rc" -eq 1 ] && exit 0
if [ "$own_rc" -eq 2 ]; then
  printf '{"decision":"block","reason":"%s"}\n' "$(printf '%s' "$NS_SHIFT_FAIL" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
  exit 0
fi
if ! ns_session_present "$NS" && [ -n "${SID:-}" ]; then
  ns_session_claim "$NS" "$SID" "${TPATH:-}" "$CURRENT_PID" "$CURRENT_START" "$(ns_claude_session_host "${TPATH:-}")" || true
fi
ns_shift_ownership claude "$CURRENT_PID" "$CURRENT_START" gate
own_rc=$?
[ "$own_rc" -eq 1 ] && exit 0
if [ "$own_rc" -eq 2 ]; then
  printf '{"decision":"block","reason":"%s"}\n' "$(printf '%s' "$NS_SHIFT_FAIL" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
  exit 0
fi

# One writer per site from here down: the stall fingerprint, the stop/ended markers, and the
# receipts commit are read-modify-write against shared files, and two sessions can attempt to
# stop at once. An unlockable site is decided unlocked — the gate must answer, never queue.
if [ -d "$NS" ] && ns_lock "$NS"; then
  trap 'ns_unlock "$NS"' EXIT
fi

# What the shift has cost so far, closed off item by item. The gate sees ticked boxes rather than
# ticks, so it catches the marks up to them: everything spent between two ticks belongs to the
# item ticked second. It runs here, once this session has been shown to own the shift and holds
# the site's lock: a stop from a second conversation on the same workspace must leave the ledger
# exactly as it found it.
if [ "$PUNCH_UNREADABLE" -ne 1 ]; then
  ns_gate_usage_sync "$NS" "$PROJECT_DIR" "$PUNCH" "$TICKED" "${TPATH:-}" || :
fi

# 1. Stop-work order — honor at once; open boxes are left open on purpose.
if [ -f "$STOP" ]; then
  honor_stop
fi

# 2. Done — no punch list at all, or every box ticked. An unreadable punch
# list is not zero open: do not release.
if [ "$PUNCH_UNREADABLE" -ne 1 ]; then
  if [ ! -f "$PUNCH" ] || [ "$OPEN" -eq 0 ]; then
    NS_DONE_MOVED="$(ns_gate_done_mismatch "$PROJECT_DIR" "$PUNCH")" || NS_DONE_MOVED=""
    if [ -n "$NS_DONE_MOVED" ]; then
      log_line "punch list changed since arming — the done clock-out is blocked until it is restored"
      _ns_clock_out_block "$NS_DONE_MOVED"
      exit 0
    fi
    NS_EVIDENCE_HOLD="$(ns_evidence_hold "$PROJECT_DIR" "$PUNCH")" || NS_EVIDENCE_HOLD=""
    if [ -n "$NS_EVIDENCE_HOLD" ]; then
      log_line "evidence missing — the done clock-out stays blocked until the named files are present"
      _ns_clock_out_block "$NS_EVIDENCE_HOLD"
      exit 0
    fi
    end_and_stop "shift done: $TICKED/$TOTAL"
  fi
fi

# 3. Quitting time — mechanical deadline. deadline_passed reads both the deadline file and the
# shift policy's deadlineEpoch and honours whichever is earlier when they disagree.
if deadline_passed; then
  log_line "quitting time — shift ended, $TICKED/$TOTAL done, items left open"
  printf 'deadline\n' >"$STOP"
  end_and_stop "quitting time: $TICKED/$TOTAL done, items left open"
fi

# Stall guard — consecutive stop attempts with no progress. Progress = a box ticked OR a
# commit (repository) / artifact receipt (artifact mode), captured in the fingerprint; either resets the counter. Held by default:
# warn in the shift log every STALL_WARN stuck attempts and keep blocking. Auto-end only on
# the owner's NIGHTSHIFT_STALL_MAX=N opt-in.
if [ "$STALL_OK" -eq 1 ]; then
  FP="$TICKED:$(ns_gate_progress_token)"
  prev_fp=""
  prev_n=0
  if [ -f "$STALL" ] && [ ! -L "$STALL" ]; then
    prev_fp="$(sed -n '1p' "$STALL")"
    prev_n="$(sed -n '2p' "$STALL")"
    prev_n="${prev_n:-0}"
  fi
  if [ "$prev_fp" = "$FP" ]; then
    attempts=$((prev_n + 1))
  else
    attempts=1
  fi
  if [ "$STALL_MAX" -gt 0 ] 2>/dev/null; then
    if [ "$attempts" -ge "$STALL_MAX" ]; then
      log_line "stalled — auto-ended, $attempts attempts no progress, $TICKED/$TOTAL done, items left open"
      printf 'stalled\n' >"$STOP"
      end_and_stop "stalled: $TICKED/$TOTAL done, $attempts attempts no progress"
    fi
  elif [ "$attempts" -ge "$STALL_WARN" ]; then
    log_line "stall warning — session active, no durable checkpoint since the last $attempts stop attempts, $TICKED/$TOTAL done; keeping shift open"
    attempts=0
  fi
  [ -L "$STALL" ] && rm -f "$STALL"
  printf '%s\n%s\n' "$FP" "$attempts" >"$STALL"
else
  log_line "stall guard down — stallMax/stallWarnEvery unreadable ($(ns_layout_name "$NS" rules) absent or incomplete); run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex)"
fi

if ns_long_unit_warn_due "$PROJECT_DIR" "$LONG_UNIT_WARN"; then
  log_line "long unit warning — live unit has run ${LONG_UNIT_WARN}m without a durable checkpoint; keeping shift open"
fi

# 4. Block, and re-inject the contract so the next turn resumes the shift. The reinjection
# text lives in the rules file (clockOutMessage) — the one copy, shipped in the template setup
# copies. jq embeds it when present; otherwise the same string is JSON-escaped in the shell.
# The block itself never depends on config: an unreadable message still blocks, fail closed,
# with the repair named.
# Which form this block takes. The push is unchanged — the turn is still blocked, with a reason
# the host feeds back — but a block that repeats a message the model read a few calls ago can say
# so in one line instead. The gate only shortens when it positively knows nothing moved.
# A contract that moved is answered in full, before any question of shortening arises: the whole
# point of the short line is that the model already holds the contract, and here it may not.
NS_CONTRACT_MOVED="$(ns_gate_contract_mismatch "$PROJECT_DIR" "$PUNCH")" || NS_CONTRACT_MOVED=""
if [ -n "$NS_CONTRACT_MOVED" ]; then
  log_line "punch list changed since arming — blocking until it is restored"
  _ns_clock_out_block "$NS_CONTRACT_MOVED"
  exit 0
fi
NS_GATE_FP="$(ns_gate_reminder_fingerprint "$OPEN" "$TICKED" "$(ns_gate_open_item "$PUNCH")" \
  "$([ -f "$STOP" ] && printf yes || printf no)" \
  "$(deadline_passed && printf passed || printf pending)" \
  "$(ns_gate_stall_state "$STALL" "$STALL_WARN")")"
if [ -n "$GATE_MESSAGE" ]; then
  _ns_clock_out_block "$(ns_gate_reminder_text "$PROJECT_DIR" "$GATE_MESSAGE" "$OPEN" "$TICKED" \
    "$(ns_gate_open_item "$PUNCH")" "$NS_GATE_FP")"
  exit 0
fi
FALLBACK="$(ns_expand_injected_paths "$PROJECT_DIR" "DO NOT STOP — the punch list ($(ns_layout_name "$NS" punch-list)) still has open items. Work them one at a time per its contract, run each item's gate, and tick only after completion; park owner decisions in $(ns_layout_name "$NS" parking-lot) and keep working. (nightshift: the full contract reinjection lives in $(ns_layout_name "$NS" rules) clockOutMessage — unreadable here; run Setup again: /nightshift:setup on Claude Code, or ask Nightshift to set up on Codex.)")"
_ns_clock_out_block "$(ns_gate_reminder_text "$PROJECT_DIR" "$FALLBACK" "$OPEN" "$TICKED" \
  "$(ns_gate_open_item "$PUNCH")" "$NS_GATE_FP")"
exit 0
