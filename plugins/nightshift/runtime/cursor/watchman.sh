#!/usr/bin/env bash
# watchman.sh — the night watchman for Cursor shifts. Revives a session that DIED mid-shift;
# never one that ended, and never another host's.
#
# Cursor keeps two conversation stores. The origin IDE tab records a conversation_id under
# ~/.cursor/projects/.../agent-transcripts. agent --resume talks only to ~/.cursor/chats.
# Those ids are not interchangeable: this watchman never passes the IDE id to --resume.
#
# First wake after an IDE death mints a CLI chat (agent create-chat), records it in
# .shift-worker, and resumes that id with freshRevivalPrompt. Later wakes resume the same
# CLI id with revivalPrompt. A shift that started from the CLI already has a CLI id — that
# id is recorded as the worker and resumed from the first wake.
#
#   watchman.sh [--project DIR] [--interval MIN] [--agent CMD] [--max-wakes N]
#
#   --interval  minutes between wakes (default: the rules file's watchMinutes, overridable by
#               $NIGHTSHIFT_WATCH; 0 exits immediately — the "disabled" spelling)
#   --agent     override the spawn command entirely (the test suite's lever). It is invoked as
#               $AGENT "<prompt>" with the project as cwd.
#   --max-wakes bound the number of wakes (0 = unbounded; tests use this)
#
# Evidence, conservative by construction — revive only on strong positive evidence of death:
#   ALIVE (stand by), any of:
#     · a fresh .shift-pulse (epoch within 2 * watchMinutes)
#     · a missing pulse still inside the first two wake intervals after arm
#     · the recorded pid (line 3) exists and its start time matches line 4
#     · an empty recorded pid — empty pid never decides death
#     · the recorded transcript (line 2) grew since the last wake
#     · a live .shift-lease pid+start (a recovered CLI that holds the lease)
#   DEAD (mint/revive): pulse stale, no transcript growth, no .session-end, and
#     the lease pid is missing or dead. Missing process evidence stands by.
# There is no Esc / roster / wedge ladder on Cursor.
#
# Stand-down order, checked at every wake — never override a declared ending:
#   0. the armed marker is gone (.shift-armed)        -> down (a disarmed site has no shift)
#   1. stop-work order (.nightshift/STOP)             -> down
#   2. shift ended (.nightshift/.ended, or no punch)  -> down
#   3. clean session end (.nightshift/.session-end)   -> down (owner closed it)
#   4. another host's shift (.shift-session line 5)   -> down (its own watchman minds it)
#   5. every box ticked                                -> one clock-out spawn if .ended missing,
#                                                        then down
#   6. deadline passed                                 -> one clock-out spawn, then down
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh"

PROJECT="$PWD"
INTERVAL_MIN="${NIGHTSHIFT_WATCH:-}"
AGENT=""
MAX_WAKES=0

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
need_value() { [ "$2" -ge 2 ] || { printf 'watchman: %s needs a value\n' "$1" >&2; usage; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --project) need_value "$1" $#; PROJECT="$2"; shift 2 ;;
    --interval) need_value "$1" $#; INTERVAL_MIN="$2"; shift 2 ;;
    --agent) need_value "$1" $#; AGENT="$2"; shift 2 ;;
    --max-wakes) need_value "$1" $#; MAX_WAKES="$2"; shift 2 ;;
    -h | --help) usage ;;
    *) printf 'watchman: unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

cd "$PROJECT" 2>/dev/null || exit 1
PROJECT="$PWD"
NS="$PROJECT/.nightshift"
WORK_TARGET="$(ns_work_target "$PROJECT" 2>/dev/null || true)"
[ -n "$WORK_TARGET" ] || WORK_TARGET="$PROJECT"
PUNCH="$NS/punch-list.md"
LOG="$NS/shift-log.md"
LOT="$NS/parking-lot.md"
TICK="$NS/.watchman-tick"
note() { ns_record_reason "$NS" "$1" "${2:-}"; }
STATE_KIND="$(ns_state_kind "$PROJECT")"
case "$STATE_KIND" in
  malformed | future)
    note unsupported-state "$STATE_KIND"
    printf 'watchman: %s\n' "$(ns_state_refuse_message "$STATE_KIND")" >&2
    exit 1
    ;;
esac

[ -n "$INTERVAL_MIN" ] || INTERVAL_MIN="$(rule "$PROJECT" watchMinutes "")"
case "$INTERVAL_MIN" in
  '' | *[!0-9]*)
    note unreadable-rules watchMinutes
    printf 'watchman: watchMinutes missing or not whole minutes — .nightshift/rules.json absent or incomplete; run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex)\n' >&2
    exit 1
    ;;
esac
[ "$INTERVAL_MIN" -gt 0 ] || exit 0

[ -n "$AGENT" ] || AGENT="$(rule "$PROJECT" watchAgent "${NIGHTSHIFT_WATCH_AGENT:-}")"

RETRY_SPACING="$(rule "$PROJECT" watchRetrySeconds "${NIGHTSHIFT_WATCH_RETRY:-}")"
PROMPT_RESUME="$(ns_expand_injected_paths "$PROJECT" "$(rule "$PROJECT" revivalPrompt "${NIGHTSHIFT_REVIVAL_PROMPT:-}")")"
PROMPT_FRESH="$(ns_expand_injected_paths "$PROJECT" "$(rule "$PROJECT" freshRevivalPrompt "${NIGHTSHIFT_FRESH_PROMPT:-}")")"
for _req in "watchRetrySeconds:$RETRY_SPACING" "revivalPrompt:$PROMPT_RESUME" "freshRevivalPrompt:$PROMPT_FRESH"; do
  if [ -z "${_req#*:}" ]; then
    note unreadable-rules "${_req%%:*}"
    printf 'watchman: %s unreadable — .nightshift/rules.json absent or incomplete; run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex)\n' "${_req%%:*}" >&2
    exit 1
  fi
done

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_line() { [ -d "$NS" ] && printf '%s · %s\n' "$(ts)" "$1" >>"$LOG"; }

# The marker is the shift. Without it there is nothing to revive and no reading to take, and
# the watchman never writes the marker back.
ARMED="$NS/.shift-armed"
armed() { [ -f "$ARMED" ]; }
stand_down_disarmed() {
  note owner-disarm
  log_line "watchman: the armed marker is gone — standing down"
  exit 0
}

PIDFILE="$NS/.watchman"
if [ -L "$PIDFILE" ]; then
  rm -f "$PIDFILE"
elif [ -f "$PIDFILE" ]; then
  oldpid="$(sed -n 1p "$PIDFILE" 2>/dev/null)"
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    printf 'watchman: already watching (pid %s)\n' "$oldpid" >&2
    exit 1
  fi
fi
printf '%s\n' "$$" >"$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
WATCH_CLOCK="$(date +%s)"

sid()        { [ -L "$NS/.shift-session" ] && return; sed -n 1p "$NS/.shift-session" 2>/dev/null; }
transcript() { [ -L "$NS/.shift-session" ] && return; sed -n 2p "$NS/.shift-session" 2>/dev/null; }
rec_pid()    { [ -L "$NS/.shift-session" ] && return; sed -n 3p "$NS/.shift-session" 2>/dev/null | tr -d '[:space:]'; }
rec_start()  { [ -L "$NS/.shift-session" ] && return; sed -n 4p "$NS/.shift-session" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
open_boxes() { ns_open_boxes "$PUNCH"; }

recorded_process_alive() {
  local p s
  p="$(rec_pid)"; s="$(rec_start)"
  [ -n "$p" ] || return 1
  ns_recorded_process "$p" "$s"
}

pulse_alive() {
  ns_pulse_fresh "$NS" "$INTERVAL_MIN" && return 0
  ns_pulse_stale "$NS" "$INTERVAL_MIN" "$WATCH_CLOCK" && return 1
  return 0
}

lease_pid_live() {
  ns_lease_pid_live "$NS"
}

TRANSCRIPT_SEEN=""
baseline_transcript() {
  local t
  t="$(transcript)"
  [ -n "$t" ] && [ -f "$t" ] && TRANSCRIPT_SEEN="$(wc -c <"$t" 2>/dev/null | tr -d ' ')" || TRANSCRIPT_SEEN=""
}
transcript_grew() {
  local t now
  t="$(transcript)"
  [ -n "$t" ] && [ -f "$t" ] || return 1
  now="$(wc -c <"$t" 2>/dev/null | tr -d ' ')"
  [ -n "$TRANSCRIPT_SEEN" ] && [ "$now" != "$TRANSCRIPT_SEEN" ]
}

# Resolve the CLI worker id. Never returns the origin IDE conversation_id unless that id
# already lives in the CLI store (Start from agent).
ensure_worker() {
  local existing origin kind minted
  existing="$(ns_cursor_worker_id "$NS")"
  if [ -n "$existing" ]; then
    printf '%s' "$existing"
    return 0
  fi
  if [ -f "$NS/.mint-failed" ] && [ ! -L "$NS/.mint-failed" ]; then
    return 1
  fi
  origin="$(sid)"
  kind="$(ns_cursor_store_kind "$(transcript)")"
  if [ "$kind" = cli ] && [ -n "$origin" ]; then
    ns_cursor_worker_write "$NS" "$origin" || return 1
    printf '%s' "$origin"
    return 0
  fi
  if [ -n "$AGENT" ]; then
    minted="${NIGHTSHIFT_CURSOR_TEST_WORKER:-minted-cli-worker}"
    ns_cursor_worker_write "$NS" "$minted" || return 1
    printf '%s' "$minted"
    return 0
  fi
  minted="$(agent create-chat 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$minted" ]; then
    log_line "watchman: could not mint a CLI worker — not passing the IDE conversation to agent --resume"
    [ -L "$NS/.mint-failed" ] && rm -f "$NS/.mint-failed"
    printf '%s\n' "$(date +%s)" >"$NS/.mint-failed"
    return 1
  fi
  ns_cursor_worker_write "$NS" "$minted" || return 1
  printf '%s' "$minted"
}

# $1 = 1 resume the stored CLI worker · 2 fresh CLI worker (same id, fresh prompt)
spawn() {
  local worker prompt rc freshly scope
  freshly=0
  if ! ns_cursor_worker_present "$NS"; then
    freshly=1
  fi
  worker="$(ensure_worker)" || return 1
  if [ "$freshly" -eq 1 ] || [ "$1" -ge 2 ]; then
    prompt="$PROMPT_FRESH"
  else
    prompt="$PROMPT_RESUME"
  fi
  if [ -n "$AGENT" ]; then
    # shellcheck disable=SC2086
    ns_watchman_run_child "$NS" cursor "$worker" "$WORK_TARGET" \
      CURSOR_PROJECT_DIR "$PROJECT" $AGENT "$prompt"
  else
    scope="$(ns_recovery_launch_scope "$PROJECT")"
    log_line "watchman: reviving under launch scope $scope"
    if [ "$scope" = host-default ]; then
      ns_watchman_run_child "$NS" cursor "$worker" "$WORK_TARGET" \
        CURSOR_PROJECT_DIR "$PROJECT" \
        agent --resume="$worker" -p --workspace "$PROJECT" "$prompt"
    else
      ns_watchman_run_child "$NS" cursor "$worker" "$WORK_TARGET" \
        CURSOR_PROJECT_DIR "$PROJECT" \
        agent --resume="$worker" -p --trust --yolo --workspace "$PROJECT" "$prompt"
    fi
  fi
  rc=$?
  if [ "$rc" -eq 3 ]; then
    log_line "watchman: process lease transfer failed — not spawning beside an unfenced session"
    return 1
  fi
  return "$rc"
}

notice_revival() {
  local worker cmd
  worker="$(ns_cursor_worker_id "$NS")"
  [ -n "$worker" ] || return 0
  cmd="$(ns_cursor_resume_command "$NS" "$PROJECT")" || return 0
  log_line "watchman: revived in a CLI worker — $cmd"
  [ -d "$NS" ] || return 0
  printf -- '- [notice] %s — the shift session died and the watchman revived it in a CLI worker. To see it, run this in a terminal: %s. To stop it, ask Nightshift to stop.\n' \
    "$(ts)" "$cmd" >>"$LOT"
}

log_line "watchman (cursor) armed · every ${INTERVAL_MIN}m"
BASE_SLEEP="${NIGHTSHIFT_WATCH_SLEEP:-$((INTERVAL_MIN * 60))}"
wake=0
baseline_transcript
: >"$TICK" 2>/dev/null || true

while :; do
  sleep "$BASE_SLEEP"
  wake=$((wake + 1))

  armed || stand_down_disarmed
  if [ -f "$NS/STOP" ]; then note owner-stop; log_line "watchman: stop-work order — standing down"; exit 0; fi
  if [ -f "$NS/.ended" ] && [ ! -L "$NS/.ended" ]; then note completed; exit 0; fi
  if [ ! -f "$PUNCH" ]; then note stand-down "punch list missing"; exit 0; fi
  if [ -f "$NS/.session-end" ] && [ ! -L "$NS/.session-end" ]; then
    note clean-session-end
    log_line "watchman: clean session end — the owner closed it; standing down (start re-arms)"
    exit 0
  fi

  host="$(ns_session_host "$NS")"
  if [ "$host" != cursor ]; then
    note wrong-host "$host"
    log_line "watchman: shift is owned by $host — standing down"
    exit 0
  fi

  if [ "$(open_boxes)" -eq 0 ]; then
    log_line "watchman: every box ticked but the shift never clocked out — spawning the clock-out (attempt 1/1)"
    spawn 1 || true
    ns_watchman_clockout_pending "$NS" "$TICK"
    clock_rc=$?
    if [ "$clock_rc" -eq 0 ]; then
      note completed
      exit 0
    fi
    note clock-out-failed
    log_line "watchman: clock-out attempt 1/1 returned without releasing the shift — standing down"
    exit 0
  fi
  if [ -f "$NS/deadline" ] && [ ! -L "$NS/deadline" ]; then
    dl="$(tr -d '[:space:]' <"$NS/deadline" 2>/dev/null)"
    if printf '%s' "$dl" | grep -qE '^[0-9]+$' && [ "$(date +%s)" -ge "$dl" ]; then
      log_line "watchman: past the deadline with the session gone — spawning the clock-out (attempt 1/1)"
      spawn 1 || true
      ns_watchman_clockout_pending "$NS" "$TICK"
      clock_rc=$?
      if [ "$clock_rc" -eq 0 ]; then
        note deadline
        exit 0
      fi
      note clock-out-failed
      log_line "watchman: clock-out attempt 1/1 returned without releasing the shift — standing down"
      exit 0
    fi
  fi

  rec_rc=1
  if [ -n "$(rec_pid)" ]; then
    recorded_process_alive
    rec_rc=$?
    if [ "$rec_rc" -eq 0 ]; then
      note silent-standby
      baseline_transcript
      : >"$TICK" 2>/dev/null || true
      if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
      continue
    fi
  fi
  if transcript_grew; then
    note silent-standby
    baseline_transcript
    : >"$TICK" 2>/dev/null || true
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi
  if lease_pid_live; then
    note silent-standby
    baseline_transcript
    : >"$TICK" 2>/dev/null || true
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi
  if pulse_alive; then
    note silent-standby
    baseline_transcript
    : >"$TICK" 2>/dev/null || true
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi
  if [ "$rec_rc" -eq 3 ]; then
    note process-evidence-unavailable
    log_line "watchman: process evidence unavailable — standing down, not reviving"
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi
  if ! ns_cursor_worker_present "$NS" && [ -f "$NS/.mint-failed" ] && [ ! -L "$NS/.mint-failed" ]; then
    note silent-standby
    baseline_transcript
    : >"$TICK" 2>/dev/null || true
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi

  attempt=0
  revived=1
  # shellcheck disable=SC2086
  set -- $RETRY_SPACING
  total=$(( $# + 1 ))
  for gap in 0 $RETRY_SPACING; do
    [ "$gap" -gt 0 ] && sleep "$gap"
    if recorded_process_alive || transcript_grew || lease_pid_live || pulse_alive; then
      note silent-standby
      log_line "watchman: session activity during retries — holding the remaining attempts"
      break
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -le "$total" ] || break
    if ns_cursor_worker_present "$NS"; then
      log_line "watchman: site dead quiet mid-shift — resume attempt $attempt (resuming CLI worker $(ns_cursor_worker_id "$NS"))"
    else
      log_line "watchman: site dead quiet mid-shift — resume attempt $attempt (minting a CLI worker)"
    fi
    if spawn "$attempt"; then
      revived=0
      if [ "$attempt" -ge 2 ]; then
        note fresh-fallback
      else
        note revived
      fi
      notice_revival
      break
    fi
    baseline_transcript
  done
  if [ "$revived" -eq 1 ] && [ "$attempt" -gt 0 ]; then
    note exhausted-retry
    # Every attempt took the lease for its own worker. A ladder that revived nothing hands it
    # back, so the recorded conversation is not left waiting on a generation nobody holds.
    ns_lease_restore_interactive "$NS" || true
  fi
  baseline_transcript
  : >"$TICK" 2>/dev/null || true

  if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
done
