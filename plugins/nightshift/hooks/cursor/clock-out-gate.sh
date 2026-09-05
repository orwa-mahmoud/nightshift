#!/usr/bin/env bash
# clock-out-gate.sh — Cursor stop hook. Same decisions as Claude's gate, in the same order;
# only the wire format differs, and that lives entirely in lib-io.sh.
#
# The punch list is the only truth. Release order on every stop attempt:
#   1. stop-work order — .nightshift/STOP exists              -> release (open boxes stay open)
#   2. done            — zero open "- [ ]" (or no punch list) -> release
#   3. quitting time   — now past .nightshift/deadline        -> write STOP, log, release
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
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh" # pure-bash path: no dirname, so a hostile PATH cannot unsource the helpers
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
PUNCH="$NS/punch-list.md"
STOP="$NS/STOP"
DEADLINE="$NS/deadline"
STALL="$NS/.stall"
NOTIFIED="$NS/.notified"
ENDED="$NS/.ended" # written when the shift actually ends; hardhat keeps the site rules armed until then
LOG="$NS/shift-log.md"
# One copy: the rules file is the config; env vars are session-start overrides only. A gate
# whose knobs are unreadable still gates (fail closed): the stall bookkeeping stands down
# loudly and the block carries the repair.
STALL_MAX="$(rule "$PROJECT_DIR" stallMax "${NIGHTSHIFT_STALL_MAX:-}")"
STALL_WARN="$(rule "$PROJECT_DIR" stallWarnEvery "${NIGHTSHIFT_STALL_WARN:-}")"
LONG_UNIT_WARN="$(rule "$PROJECT_DIR" longUnitWarnMinutes "${NIGHTSHIFT_LONG_UNIT_WARN:-}")"
STALL_OK=1
case "$STALL_MAX" in '' | *[!0-9]*) STALL_OK=0 ;; esac
case "$STALL_WARN" in '' | *[!0-9]* | 0) STALL_OK=0 ;; esac
NOTIFY="$(rule "$PROJECT_DIR" notifyCommand "${NIGHTSHIFT_NOTIFY_CMD:-}")"
GATE_MESSAGE="$(ns_expand_injected_paths "$PROJECT_DIR" "$(rule "$PROJECT_DIR" clockOutMessage "${NIGHTSHIFT_GATE_MESSAGE:-}")")"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_line() { [ -d "$NS" ] && printf '%s · %s\n' "$(ts)" "$1" >>"$LOG"; }

# Only the Items list is the shift — a checkbox above the heading is prose and holds nobody.
# ns_gate_boxes reads those counts.

# Stall progress is a tick plus either work-target HEAD (repository mode) or the artifact
# receipts fingerprint (artifact mode). ns_gate_progress_token chooses.
deadline_passed() { ns_gate_deadline_passed; }

# Morning whistle — fires at most once per shift; $1 is the summary line.
whistle() {
  [ -n "$NOTIFY" ] || return 0
  # Exclusive create: of two sessions releasing at once, exactly one owns the whistle.
  # A planted symlink is not a prior notify — replace it rather than follow it.
  [ -L "$NOTIFIED" ] && rm -f "$NOTIFIED"
  (set -C; : >"$NOTIFIED") 2>/dev/null || return 0
  NIGHTSHIFT_SUMMARY="$1" sh -c "$NOTIFY" nightshift "$1" >/dev/null 2>&1 || true
}

# Receipts snapshot — $1 is the commit subject. Signing is turned off explicitly: an owner
# with commit.gpgsign=true globally would otherwise lose every receipt to a key prompt that
# nothing is there to answer at 3am.
receipts_commit() {
  local err auto
  [ -d "$NS/.git" ] || return 0
  # Owner opt-in. Default off — a receipts git alone does not authorize headless commits.
  auto="$(rule "$PROJECT_DIR" receiptsAutoCommit "${NIGHTSHIFT_RECEIPTS_AUTO_COMMIT:-}")"
  case "$auto" in true | TRUE | 1 | yes | YES) ;; *) return 0 ;; esac
  git -C "$NS" add -A >/dev/null 2>&1 || true
  err="$(git -C "$NS" -c user.name=nightshift -c user.email=nightshift@localhost \
    -c commit.gpgsign=false commit -q -m "$1" 2>&1)" && return 0
  case "$err" in
    *"nothing to commit"* | *"nothing added"*) : ;;
    *) log_line "receipts commit failed: $(printf '%s' "$err" | head -n1)" ;;
  esac
}

release_lease() {
  ns_lease_release_retry "$NS" \
    || log_line "process lease release deferred: lease mutex remained busy"
}

# The morning receipt — the one page the owner reads over coffee. It renders from the live ledger,
# so it runs before the archive truncates it. Best effort: an absent or failing renderer leaves one
# line in the shift log and the release stands, and the archive still runs, so a night whose
# receipt could not be written still keeps its evidence. $1 is tonight's shiftId, empty when no
# policy was written.
render_morning_receipt() {
  local renderer="$_here/../../runtime/morning-receipt.sh" dir="$NS/receipts" err
  if [ ! -f "$renderer" ]; then
    log_line "morning receipt skipped: runtime/morning-receipt.sh is not installed"
    return 0
  fi
  if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
    log_line "morning receipt render failed: receipts path is not a directory"
    return 0
  fi
  mkdir -p "$dir" 2>/dev/null || {
    log_line "morning receipt render failed: cannot create $dir"
    return 0
  }
  err="$(bash "$renderer" --project "$PROJECT_DIR" --view owner \
    --out "$dir/morning-$(date '+%Y-%m-%d')${1:+-$1}.md" 2>&1)" && return 0
  log_line "morning receipt render failed: $(printf '%s' "$err" | head -n1)"
}

archive_findings_ledger() {
  local archiver="$_here/../../runtime/evidence-archive.sh" err
  [ -f "$archiver" ] || {
    log_line "findings archive skipped: runtime/evidence-archive.sh is not installed"
    return 0
  }
  err="$(bash "$archiver" --project "$PROJECT_DIR" --shift-id "$1" 2>&1)" && return 0
  log_line "findings archive failed: $(printf '%s' "$err" | head -n1)"
}

# Every shift-ending release runs through here. ENDED is what stands the site rules down —
# hardhat keeps them armed while a stop-work order is merely pending, because the agent goes on
# working until its next stop attempt.
end_shift() {
  local shift_id
  if [ -d "$NS" ]; then
    [ -L "$ENDED" ] && rm -f "$ENDED"
    : >"$ENDED"
  fi
  # The shift is over, so the site stops being on shift: without this the guards would still apply
  # to whatever ordinary session opens this project next.
  rm -f "$NS/.shift-armed"
  release_lease
  # A shift that never wrote a policy has no id, and its receipt is named for the date alone.
  shift_id="$(ns_policy_shift_id "$PROJECT_DIR" 2>/dev/null)" || shift_id=""
  render_morning_receipt "$shift_id"
  archive_findings_ledger "${shift_id:-unknown}"
  receipts_commit "$1"
  whistle "$1"
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
    end_shift "$summary"
  else
    reason="$(head -n1 "$STOP" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    end_shift "shift ended${reason:+ ($reason)}: $TICKED/$TOTAL done"
  fi
}

# Cursor cannot vouch for interactive process ancestry, so those record lines remain empty.
# A shift exists because the owner started one, never because a list exists. Nightshift Start
# writes .shift-armed; without it the punch list is a to-do file and every session stops freely —
# including the one that just wrote the list while planning.
if [ ! -f "$NS/.shift-armed" ]; then cursor_emit_release; exit 0; fi

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
  honor_stop
  cursor_emit_release
  exit 0
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

# 1. Stop-work order — honor at once; open boxes are left open on purpose.
if [ -f "$STOP" ]; then
  honor_stop
  cursor_emit_release
  exit 0
fi

# 2. Done — no punch list at all, or every box ticked. An unreadable punch
# list is not zero open: do not release.
if [ "$PUNCH_UNREADABLE" -ne 1 ]; then
  if [ ! -f "$PUNCH" ]; then
    end_shift "shift done: $TICKED/$TOTAL"
    cursor_emit_release
    exit 0
  fi
  if [ "$OPEN" -eq 0 ]; then
    end_shift "shift done: $TICKED/$TOTAL"
    cursor_emit_release
    exit 0
  fi
fi

# 3. Quitting time — mechanical deadline.
if [ -f "$DEADLINE" ] && deadline_passed; then
  log_line "quitting time — shift ended, $TICKED/$TOTAL done, items left open"
  printf 'deadline\n' >"$STOP"
  end_shift "quitting time: $TICKED/$TOTAL done, items left open"
  cursor_emit_release
  exit 0
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
      end_shift "stalled: $TICKED/$TOTAL done, $attempts attempts no progress"
      cursor_emit_release
      exit 0
    fi
  elif [ "$attempts" -ge "$STALL_WARN" ]; then
    log_line "stall warning — session active, no durable checkpoint since the last $attempts stop attempts, $TICKED/$TOTAL done; keeping shift open"
    attempts=0
  fi
  [ -L "$STALL" ] && rm -f "$STALL"
  printf '%s\n%s\n' "$FP" "$attempts" >"$STALL"
else
  log_line "stall guard down — stallMax/stallWarnEvery unreadable (.nightshift/rules.json absent or incomplete); run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex or Cursor)"
fi

if ns_long_unit_warn_due "$PROJECT_DIR" "$LONG_UNIT_WARN"; then
  log_line "long unit warning — live unit has run ${LONG_UNIT_WARN}m without a durable checkpoint; keeping shift open"
fi

# 4. Block, and re-inject the contract so the next turn resumes the shift. The reinjection
# text lives in the rules file (clockOutMessage) — the one copy; the emitter in lib-io.sh
# escapes it, so the owner's text cannot break the decision. The block itself never depends
# on config: an unreadable message still blocks, fail closed, with the repair named.
if [ -n "$GATE_MESSAGE" ]; then
  cursor_emit_block "$GATE_MESSAGE"
  exit 0
fi
cursor_emit_block "$(ns_expand_injected_paths "$PROJECT_DIR" "DO NOT STOP — the punch list (.nightshift/punch-list.md) still has open items. Work them one at a time per its contract, run each item's gate, and tick only after completion; park owner decisions in .nightshift/parking-lot.md and keep working. (nightshift: the full contract reinjection lives in .nightshift/rules.json clockOutMessage — unreadable here; run Setup again: /nightshift:setup on Claude Code, or ask Nightshift to set up on Codex.)")"
exit 0
