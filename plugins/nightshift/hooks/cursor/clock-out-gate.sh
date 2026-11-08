#!/usr/bin/env bash
# clock-out-gate.sh — Cursor stop hook. Same decisions as Claude's gate, in the same order;
# only the wire format differs, and that lives entirely in lib-io.sh.
#
# The punch list is the only truth. Release order on every stop attempt:
#   1. stop-work order — .nightshift/STOP exists              -> release (open boxes stay open)
#   2. done            — zero open "- [ ]" (or no punch list) -> release
#   3. quitting time   — now past .nightshift/run/deadline    -> write STOP, log, release
#   4. otherwise       — block, re-injecting the contract
#
# Stall guard: consecutive stop attempts with no progress are counted (progress = a tick or a
# commit in repository mode, or a tick or an artifact receipt in artifact mode). By default a stalled shift is HELD — every 3 stuck attempts a stall warning lands
# in the shift log and the gate keeps blocking; only STOP, done, or the deadline release.
# Owner opt-in: stallMax N in the rules file auto-ends the shift after N stuck attempts.
#
# Morning whistle, the morning receipt, and receipts behave exactly as in Claude's gate: any
# shift-ending release renders the owner view of the night to
# .nightshift/receipts/morning-<YYYY-MM-DD>-<shiftId>.md, fires notifyCommand once, and
# snapshots .nightshift/ into its receipts repo; none of them can block the release.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
NS_COLD_STOP_HOST=cursor
# shellcheck source=plugins/nightshift/hooks/shared/cold-stop.sh
. "$_here/../shared/cold-stop.sh"
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh" # pure-bash path: no dirname, so a hostile PATH cannot unsource the helpers
ns_copy_serves_host "$_here/../.." cursor || exit 0
# shellcheck source=plugins/nightshift/hooks/shared/gate-core.sh
. "$_here/../shared/gate-core.sh"
# shellcheck source=plugins/nightshift/hooks/cursor/lib-io.sh
. "$_here/lib-io.sh"

cursor_read_input "$@"
SID="$CURSOR_SESSION_ID"
TPATH="$CURSOR_TRANSCRIPT_PATH"

HOST_DIR="$(cursor_project_dir)"
if ! PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)"; then
  cursor_emit_block "DO NOT STOP — .nightshift-link is invalid. Open the correct project task or repair the explicit link to an absolute workspace containing .nightshift/."
  exit 0
fi
STATE_KIND="$(ns_state_kind "$PROJECT_DIR")"
case "$STATE_KIND" in
  malformed | future)
    cursor_emit_block "DO NOT STOP — $(ns_state_refuse_message "$STATE_KIND")"
    exit 0
    ;;
esac
NS="$PROJECT_DIR/.nightshift"
ns_hook_copy_note "$NS" cursor "${SID:-}" "$_here/../.."
declare PUNCH STOP DEADLINE STALL ARMED LOG
ns_layout_set PUNCH "$NS" punch-list
ns_layout_set STOP "$NS" stop
ns_layout_set DEADLINE "$NS" deadline
ns_layout_set STALL "$NS" stall
ns_layout_set ARMED "$NS" armed
ns_layout_set LOG "$NS" shift-log
# One copy: the rules file is the config; env vars are session-start overrides only. A gate
# whose knobs are unreadable still gates (fail closed): the stall bookkeeping stands down
# loudly and the block carries the repair.
STALL_MAX="$(rule "$PROJECT_DIR" stallMax "${NIGHTSHIFT_STALL_MAX:-}")"
STALL_WARN="$(rule "$PROJECT_DIR" stallWarnEvery "${NIGHTSHIFT_STALL_WARN:-}")"
LONG_UNIT_WARN="$(rule "$PROJECT_DIR" longUnitWarnMinutes "${NIGHTSHIFT_LONG_UNIT_WARN:-}")"
STALL_OK=1
case "$STALL_MAX" in '' | *[!0-9]*) STALL_OK=0 ;; esac
case "$STALL_WARN" in '' | *[!0-9]* | 0) STALL_OK=0 ;; esac
GATE_MESSAGE="$(ns_expand_injected_paths "$PROJECT_DIR" "$(rule "$PROJECT_DIR" clockOutMessage "${NIGHTSHIFT_GATE_MESSAGE:-}")")"

ts() { ns_local_now second; }
log_line() { [ -d "$NS" ] && printf '%s · %s\n' "$(ts)" "$1" >>"$LOG"; }

# Only the Items list is the shift — a checkbox above the heading is prose and holds nobody.
# ns_gate_boxes reads those counts.

# Stall progress is a tick plus either work-target HEAD (repository mode) or the artifact
# receipts fingerprint (artifact mode). ns_gate_progress_token chooses.
deadline_passed() { ns_gate_deadline_passed; }

# The terminal sequence lives once, in gate-core.sh. The watchman calls the same function.
end_shift() { ns_shift_end "$PROJECT_DIR" "$1"; }

# Every ending runs through here. The shift is over by now, so asking the model to file is a
# request it can carry out, and that request is the one hold left in a finished shift. Asking is
# recorded, so the next stop releases either way.
end_and_stop() {
  end_shift "$1"
  hold="$(ns_gate_ending_hold "$NS")"
  if [ -n "$hold" ]; then
    log_line "holding once so this shift's snags and filing are settled before the session ends"
    cursor_emit_block "$hold"
  else
    cursor_emit_release
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

# Cursor cannot vouch for interactive process ancestry, so those record lines remain empty.
# A shift exists because the owner started one, never because a list exists. Nightshift Start
# writes .shift-armed; without it the punch list is a to-do file and every session stops freely —
# including the one that just wrote the list while planning.
if [ ! -f "$ARMED" ]; then cursor_emit_release; exit 0; fi


# Owner interrupt — live Stop button sends status "aborted" (Cursor 3.17.21).
# Same meaning as Claude Esc: release, do not reinject, do not clock out.
# "error" is not owner-stop.
if [ "${CURSOR_STOP_STATUS:-}" = "aborted" ]; then
  cursor_emit_release
  exit 0
fi


# STOP is an owner capability, not a worker capability. Any Stop event may carry an existing
# owner-issued order through clock-out; process ownership must never make emergency stop unusable.
if [ -f "$STOP" ]; then
  if [ -d "$NS" ] && ns_lock "$NS"; then trap 'ns_unlock "$NS"' EXIT; fi
  # honor_stop ends the shift and terminates: every path through it releases or holds.
  honor_stop
fi

LEASE_NONCE="${NIGHTSHIFT_LEASE_NONCE:-}"
LEASE_GENERATION="${NIGHTSHIFT_LEASE_GENERATION:-}"
ns_shift_unbound cursor gate
own_rc=$?
if [ "$own_rc" -eq 1 ]; then
  cursor_emit_release
  exit 0
fi
if [ "$own_rc" -eq 2 ]; then
  cursor_emit_block "$NS_SHIFT_FAIL"
  exit 0
fi
if ! ns_session_present "$NS" && [ -n "${SID:-}" ]; then
  ns_session_claim "$NS" "$SID" "${TPATH:-}" "" "" cursor || true
fi
if ns_cursor_stale_origin "$NS" "${SID:-}"; then
  cursor_emit_release
  exit 0
fi
ns_shift_ownership cursor "" "" gate
own_rc=$?
if [ "$own_rc" -eq 1 ]; then
  cursor_emit_release
  exit 0
fi
if [ "$own_rc" -eq 2 ]; then
  cursor_emit_block "$NS_SHIFT_FAIL"
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
  ns_gate_usage_sync "$NS" "$PROJECT_DIR" "$PUNCH" "$TICKED" || :
fi

# 1. Stop-work order — honor at once; open boxes are left open on purpose.
if [ -f "$STOP" ]; then
  # honor_stop ends the shift and terminates: every path through it releases or holds.
  honor_stop
fi

# 2. Done — no punch list at all, or every box ticked. An unreadable punch
# list is not zero open: do not release.
if [ "$PUNCH_UNREADABLE" -ne 1 ]; then
  if [ ! -f "$PUNCH" ] || [ "$OPEN" -eq 0 ]; then
    NS_DONE_MOVED="$(ns_gate_done_mismatch "$PROJECT_DIR" "$PUNCH")" || NS_DONE_MOVED=""
    if [ -n "$NS_DONE_MOVED" ]; then
      log_line "punch list changed since arming — the done clock-out is blocked until it is restored"
      cursor_emit_block "$NS_DONE_MOVED"
      exit 0
    fi
    NS_EVIDENCE_HOLD="$(ns_evidence_hold "$PROJECT_DIR" "$PUNCH")" || NS_EVIDENCE_HOLD=""
    if [ -n "$NS_EVIDENCE_HOLD" ]; then
      log_line "evidence missing — the done clock-out stays blocked until the named files are present"
      cursor_emit_block "$NS_EVIDENCE_HOLD"
      exit 0
    fi
    end_and_stop "shift done: $TICKED/$TOTAL"
  fi
fi

# 3. Quitting time — mechanical deadline.
if [ -f "$DEADLINE" ] && deadline_passed; then
  log_line "quitting time — shift ended, $TICKED/$TOTAL done, items left open"
  printf 'deadline\n' >"$STOP"
  end_and_stop "quitting time: $TICKED/$TOTAL done, items left open"
fi

# Stall guard — consecutive stop attempts with no progress. Progress = a box ticked OR a
# commit (repository) / artifact receipt (artifact mode), captured in the fingerprint; either resets the counter. Held by default:
# warn in the shift log every STALL_WARN stuck attempts and keep blocking. Auto-end only on
# the owner's stallMax opt-in.
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
  log_line "stall guard down — stallMax/stallWarnEvery unreadable ($(ns_layout_name "$NS" rules) absent or incomplete); run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex or Cursor)"
fi

if ns_long_unit_warn_due "$PROJECT_DIR" "$LONG_UNIT_WARN"; then
  log_line "long unit warning — live unit has run ${LONG_UNIT_WARN}m without a durable checkpoint; keeping shift open"
fi

# 4. Block, and re-inject the contract so the next turn resumes the shift. The reinjection
# text lives in the rules file (clockOutMessage) — the one copy; the emitter in lib-io.sh
# escapes it, so the owner's text cannot break the decision. The block itself never depends
# on config: an unreadable message still blocks, fail closed, with the repair named.
# Which form this block takes. The push is unchanged — the turn is still blocked, with a reason
# the host feeds back — but a block that repeats a message the model read a few calls ago can say
# so in one line instead. The gate only shortens when it positively knows nothing moved.
# A contract that moved is answered in full, before any question of shortening arises: the whole
# point of the short line is that the model already holds the contract, and here it may not.
NS_CONTRACT_MOVED="$(ns_gate_contract_mismatch "$PROJECT_DIR" "$PUNCH")" || NS_CONTRACT_MOVED=""
if [ -n "$NS_CONTRACT_MOVED" ]; then
  log_line "punch list changed since arming — blocking until it is restored"
  cursor_emit_block "$NS_CONTRACT_MOVED"
  exit 0
fi
NS_GATE_FP="$(ns_gate_reminder_fingerprint "$OPEN" "$TICKED" "$(ns_gate_open_item "$PUNCH")" \
  "$([ -f "$STOP" ] && printf yes || printf no)" \
  "$(deadline_passed && printf passed || printf pending)" \
  "$(ns_gate_stall_state "$STALL" "$STALL_WARN")")"
if [ -n "$GATE_MESSAGE" ]; then
  cursor_emit_block "$(ns_gate_reminder_text "$PROJECT_DIR" "$GATE_MESSAGE" "$OPEN" "$TICKED" \
    "$(ns_gate_open_item "$PUNCH")" "$NS_GATE_FP")"
  exit 0
fi
cursor_emit_block "$(ns_gate_reminder_text "$PROJECT_DIR" "$(ns_expand_injected_paths "$PROJECT_DIR" "DO NOT STOP — the punch list ($(ns_layout_name "$NS" punch-list)) still has open items. Work them one at a time per its contract, run each item's gate, and tick only after completion; park owner decisions in $(ns_layout_name "$NS" parking-lot) and keep working. (nightshift: the full contract reinjection lives in $(ns_layout_name "$NS" rules) clockOutMessage — unreadable here; run Setup again: /nightshift:setup on Claude Code, or ask Nightshift to set up on Codex.)")" "$OPEN" "$TICKED" "$(ns_gate_open_item "$PUNCH")" "$NS_GATE_FP")"
exit 0
