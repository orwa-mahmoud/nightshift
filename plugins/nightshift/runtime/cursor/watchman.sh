#!/usr/bin/env bash
# watchman.sh — the night watchman for Cursor shifts. Revives a session that DIED mid-shift;
# never one that ended, and never another host's.
#
# Cursor keeps two conversation stores. The origin IDE tab records a conversation_id under
# ~/.cursor/projects/.../agent-transcripts. agent --resume talks only to ~/.cursor/chats.
# Those ids are not interchangeable: this watchman never passes the IDE id to --resume.
#
# First wake after an IDE death mints a CLI chat (agent create-chat), records it in
# .shift-worker as the revival launches, and resumes it with freshRevivalPrompt; a worker that
# exits having ticked a box is relaunched with revivalPrompt. A CLI-started shift's own id is
# the worker from the first wake.
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
#     · the recorded transcript (line 2) grew since the last wake
#     · a live worker still inside idleWindowMinutes, or any busy signal
#     · an empty recorded pid — empty pid never decides death
#     · a live .shift-lease holder still inside that same idle window
#   DEAD (mint/revive): the idle window elapsed and the tree was stopped, or
#     the process is already dead. Missing process evidence stands by.
# There is no Esc / roster / wedge ladder on Cursor.
#
# Stand-down order, checked at every wake — never override a declared ending:
#   0. the armed marker is gone (.shift-armed)        -> down (a disarmed site has no shift)
#   1. shift ended (.nightshift/run/.ended, or no punch)  -> down
#   2. another host's shift (.shift-session line 5)   -> down (its own watchman minds it)
#   3. every box ticked, STOP, or the deadline, and the
#      bound session is gone or idle                  -> the shared clock-out, no agent, then down
#   4. clean session end (.nightshift/run/.session-end)   -> down (owner closed it)
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh"
# shellcheck source=plugins/nightshift/hooks/shared/gate-core.sh
. "$_here/../../hooks/shared/gate-core.sh"
ns_copy_serves_host "$_here/../.." cursor || exit 0

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

NS_WATCHMAN_SCRIPT="$_here/watchman.sh"
case "$NS_WATCHMAN_SCRIPT" in
  /*) ;;
  *) NS_WATCHMAN_SCRIPT="$(pwd)/$NS_WATCHMAN_SCRIPT" ;;
esac
NS_WATCHMAN_SELF_VERSION="$(ns_plugin_version "$(ns_plugin_root_from_script "$NS_WATCHMAN_SCRIPT")")"

cd "$PROJECT" 2>/dev/null || exit 1
PROJECT="$PWD"
PROJECT_DIR="$PROJECT"
NS="$PROJECT/.nightshift"
WORK_TARGET="$(ns_work_target "$PROJECT" 2>/dev/null || true)"
[ -n "$WORK_TARGET" ] || WORK_TARGET="$PROJECT"
declare PUNCH LOG LOT TICK SESSION_FILE SESSION_END ENDED DEADLINE STOP MINT_FAILED
ns_layout_set PUNCH "$NS" punch-list
ns_layout_set LOG "$NS" shift-log
ns_layout_set LOT "$NS" parking-lot
ns_layout_set TICK "$NS" watchman-tick
ns_layout_set SESSION_FILE "$NS" session
ns_layout_set SESSION_END "$NS" session-end
ns_layout_set ENDED "$NS" ended
ns_layout_set DEADLINE "$NS" deadline
ns_layout_set STOP "$NS" stop
ns_layout_set MINT_FAILED "$NS" mint-failed
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
    printf 'watchman: watchMinutes missing or not whole minutes — %s absent or incomplete; run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex)\n' "$(ns_layout_name "$NS" rules)" >&2
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
    printf 'watchman: %s unreadable — %s absent or incomplete; run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex)\n' "${_req%%:*}" "$(ns_layout_name "$NS" rules)" >&2
    exit 1
  fi
done

ts() { ns_local_now second; }
log_line() { [ -d "$NS" ] && printf '%s · %s\n' "$(ts)" "$1" >>"$LOG"; }

# The marker is the shift. Without it there is nothing to revive and no reading to take, and
# the watchman never writes the marker back.
declare ARMED
ns_layout_set ARMED "$NS" armed
armed() { [ -f "$ARMED" ]; }
stand_down_disarmed() {
  note owner-disarm
  log_line "watchman: the armed marker is gone — standing down"
  exit 0
}
stand_down_unclaimed() {
  if [ -f "$PIDFILE" ] && [ ! -L "$PIDFILE" ]; then
    trap - EXIT
    note stand-down "watchman pidfile taken over"
    log_line "watchman: another watchman owns this site — standing down"
    exit 0
  fi
  note stand-down "watchman pidfile gone"
  log_line "watchman: the watchman pidfile is gone — standing down"
  exit 0
}

declare PIDFILE
ns_layout_set PIDFILE "$NS" watchman
ns_watchman_claim "$PIDFILE" "$NS_WATCHMAN_SCRIPT" || exit 1
# The pidfile is this loop's claim on the site, and a claim can change hands: Reset and Purge
# remove it, a takeover replaces the pid inside it. Removing it on the way out is only right while
# it still names this process — otherwise a watchman that has already been replaced would delete
# the new one's claim as it exits, and the site would be left watched by a loop nothing records.
holds_pidfile() {
  [ -f "$PIDFILE" ] || return 1
  [ ! -L "$PIDFILE" ] || return 1
  [ "$(sed -n 1p "$PIDFILE" 2>/dev/null)" = "$$" ]
}
trap 'holds_pidfile && rm -f "$PIDFILE"' EXIT
WATCH_CLOCK="$(date +%s)"

sid()        { [ -L "$SESSION_FILE" ] && return; sed -n 1p "$SESSION_FILE" 2>/dev/null; }
transcript() { [ -L "$SESSION_FILE" ] && return; sed -n 2p "$SESSION_FILE" 2>/dev/null; }
rec_pid()    { [ -L "$SESSION_FILE" ] && return; sed -n 3p "$SESSION_FILE" 2>/dev/null | tr -d '[:space:]'; }
rec_start()  { [ -L "$SESSION_FILE" ] && return; sed -n 4p "$SESSION_FILE" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
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

site_alive() {
  recorded_process_alive || transcript_grew || lease_pid_live || pulse_alive
}

# Resolve the CLI worker id into WORKER without recording it; WORKER_FRESH=1 when the site has
# none yet. Never the origin IDE conversation_id unless that id already lives in the CLI store
# (Start from agent). .shift-worker is written only when a revival launches under the id.
WORKER=""
WORKER_FRESH=0
resolve_worker() {
  local origin kind minted
  WORKER="$(ns_cursor_worker_id "$NS")"
  WORKER_FRESH=0
  [ -z "$WORKER" ] || return 0
  if [ -f "$MINT_FAILED" ] && [ ! -L "$MINT_FAILED" ]; then
    return 1
  fi
  WORKER_FRESH=1
  origin="$(sid)"
  kind="$(ns_cursor_store_kind "$(transcript)")"
  if [ "$kind" = cli ] && [ -n "$origin" ]; then
    WORKER="$origin"
    return 0
  fi
  if [ -n "$AGENT" ]; then
    WORKER="${NIGHTSHIFT_CURSOR_TEST_WORKER:-minted-cli-worker}"
    return 0
  fi
  minted="$(agent create-chat 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$minted" ]; then
    log_line "watchman: could not mint a CLI worker — not passing the IDE conversation to agent --resume"
    [ -L "$MINT_FAILED" ] && rm -f "$MINT_FAILED"
    printf '%s\n' "$(date +%s)" >"$MINT_FAILED"
    return 1
  fi
  WORKER="$minted"
}

# An id this wake recorded for a revival that never launched goes again, so the origin tab is
# not pointed at an empty chat. An id an earlier revival ran under stays.
forget_fresh_worker() {
  [ "$WORKER_FRESH" -eq 1 ] || return 0
  [ "$(ns_cursor_worker_id "$NS")" = "$WORKER" ] || return 0
  rm -f "$(ns_layout_path "$NS" worker)"
}

launch_worker() { # <prompt>
  local prompt="$1" fields model force trust model_known force_known trust_known
  if [ -n "$AGENT" ]; then
    # shellcheck disable=SC2086
    ns_watchman_run_child "$NS" cursor "$WORKER" "$WORK_TARGET" \
      CURSOR_PROJECT_DIR "$PROJECT" $AGENT "$prompt"
    return
  fi
  fields="$(ns_cursor_launch_read "$NS")"
  model="${fields%%$'\t'*}"
  fields="${fields#*$'\t'}"
  force="${fields%%$'\t'*}"
  fields="${fields#*$'\t'}"
  trust="${fields%%$'\t'*}"
  fields="${fields#*$'\t'}"
  model_known="${fields%%$'\t'*}"
  fields="${fields#*$'\t'}"
  force_known="${fields%%$'\t'*}"
  trust_known="${fields#*$'\t'}"
  if [ "$model_known" != 1 ] || [ "$force_known" != 1 ] || [ "$trust_known" != 1 ]; then
    if [ "${NS_CURSOR_LAUNCH_SAID:-}" != 1 ]; then
      NS_CURSOR_LAUNCH_SAID=1
      log_line "watchman: launch options that could not be read use the CLI default"
    fi
  fi
  if [ "$model_known" = 1 ] && [ -n "$model" ] && [ "${NS_CURSOR_MODEL_SAID:-}" != 1 ] && ns_cursor_model_missing "$model"; then
    NS_CURSOR_MODEL_SAID=1
    log_line "watchman: recorded model ${model} is not in the Cursor model list — not substituting another"
    ns_watchman_park "$NS" "the Cursor model ${model} is not available; the revival still asks for it and does not switch models"
  fi
  set -- agent --resume="$WORKER" -p --workspace "$PROJECT"
  [ "$model_known" = 1 ] && [ -n "$model" ] && set -- "$@" --model "$model"
  [ "$force_known" = 1 ] && [ "$force" = 1 ] && set -- "$@" --force
  [ "$trust_known" = 1 ] && [ "$trust" = 1 ] && set -- "$@" --trust
  set -- "$@" "$prompt"
  ns_watchman_run_child "$NS" cursor "$WORKER" "$WORK_TARGET" \
    CURSOR_PROJECT_DIR "$PROJECT" "$@"
}

# A headless `agent -p` turn is not what releases the shift. Cursor's hooks docs define `stop`
# for a completed, aborted, or error loop and do not exempt print mode, but a print-mode turn
# that ends in error has been seen to exit without that hook writing `.ended`. A run that ticked
# a box earns the next one; a run that ticked nothing returns to the wake cycle. Clock-out is
# the shared sequence below, not another agent.
relaunch_due() { # <open-before-the-run>
  local now dl
  armed && [ ! -f "$STOP" ] && [ -f "$PUNCH" ] || return 1
  { [ -f "$ENDED" ] && [ ! -L "$ENDED" ]; } && return 1
  { [ -f "$SESSION_END" ] && [ ! -L "$SESSION_END" ]; } && return 1
  if [ -f "$DEADLINE" ] && [ ! -L "$DEADLINE" ]; then
    dl="$(tr -d '[:space:]' <"$DEADLINE" 2>/dev/null)"
    printf '%s' "$dl" | grep -qE '^[0-9]+$' && [ "$(date +%s)" -ge "$dl" ] && return 1
  fi
  now="$(ns_open_boxes "$PUNCH")" || return 1
  [ "$now" -gt 0 ] && [ "$now" -lt "$1" ] || return 1
  ns_lease_valid "$NS" && [ -n "$NS_LEASE_NONCE" ] || return 1
  ! lease_pid_live
}

# $1 = 1 resume the stored CLI worker · 2 fresh prompt to the same worker
# Returns 0 revived · 1 failed · 2 the session came back while the worker was minted.
spawn() {
  local prompt rc scope open_before
  ns_ensure_work_target_link "$PROJECT" || true
  open_before="$(ns_open_boxes "$PUNCH")"
  if [ -z "$AGENT" ]; then
    scope="$(ns_recovery_effective_scope "$PROJECT" cursor)"
    case "$scope" in
      unavailable:*)
        log_line "watchman: $(ns_recovery_refusal "$scope"). Recovery cannot restore this configured scope."
        log_line "watchman: the work is untouched. $(ns_recovery_repair "$PROJECT" "$scope")"
        note recovery-scope-unavailable
        return 1
        ;;
    esac
  fi
  resolve_worker || return 1
  # Minting has no deadline of its own, and the tab it replaces can come back meanwhile.
  if [ "$WORKER_FRESH" -eq 1 ] && site_alive; then
    log_line "watchman: session activity while the CLI worker was minted — not reviving"
    return 2
  fi
  if [ "$WORKER_FRESH" -eq 1 ] || [ "$1" -ge 2 ]; then
    prompt="$PROMPT_FRESH"
  else
    prompt="$PROMPT_RESUME"
  fi
  if [ "$WORKER_FRESH" -eq 1 ]; then
    ns_cursor_worker_write "$NS" "$WORKER" || return 1
  fi
  [ -n "$AGENT" ] || log_line "watchman: reviving under launch scope $scope"
  launch_worker "$prompt"
  rc=$?
  if [ "$rc" -eq 3 ]; then
    log_line "watchman: process lease transfer failed — not spawning beside an unfenced session"
    forget_fresh_worker
    return 1
  fi
  if ! ns_watchman_revival_proved "$NS" "" "$INTERVAL_MIN" "$open_before"; then
    log_line "watchman: revival child returned without moving the shift — not counting it as a resume"
    return 1
  fi
  while relaunch_due "$open_before"; do
    open_before="$(ns_open_boxes "$PUNCH")"
    if [ -z "$AGENT" ]; then
      scope="$(ns_recovery_effective_scope "$PROJECT" cursor)"
      case "$scope" in
        unavailable:*)
          log_line "watchman: $(ns_recovery_refusal "$scope"). Recovery cannot restore this configured scope."
          log_line "watchman: the work is untouched. $(ns_recovery_repair "$PROJECT" "$scope")"
          note recovery-scope-unavailable
          break
          ;;
      esac
    fi
    log_line "watchman: CLI worker $WORKER exited with $open_before open — relaunching it"
    launch_worker "$PROMPT_RESUME"
    if [ "$?" -eq 3 ]; then
      log_line "watchman: process lease transfer failed — not spawning beside an unfenced session"
      break
    fi
  done
  return 0
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

# 0 when nothing live remains, or a live tree has been quiet for the whole idle window.
# A fresh pulse, a growing transcript, or a worker still inside that window is 1.
session_gone_or_idle() {
  local pids="" pid sample cpu known busy delta now window bytes changed verdict
  NS_SESSION_QUIET=gone
  transcript_grew && return 1
  pulse_alive && return 1
  if recorded_process_alive; then
    pids="$(rec_pid)"
  fi
  if lease_pid_live; then
    ns_lease_load "$NS" || true
    pid="${NS_LEASE_PID:-}"
    if [ -n "$pid" ] && [ "$pid" != "$pids" ]; then
      pids="${pids:+$pids }$pid"
    fi
  fi
  [ -n "$pids" ] || return 0
  ns_idle_load "$NS"
  # shellcheck disable=SC2086
  sample="$(ns_idle_tree_sample $pids)"
  cpu="${sample%%	*}"
  sample="${sample#*	}"
  known="${sample%%	*}"
  busy="${sample#*	}"
  delta=0
  if [ -n "$NS_IDLE_CPU" ] && [ "$known" = 1 ]; then
    delta=$((cpu - NS_IDLE_CPU))
  fi
  bytes=0
  if [ -n "$(transcript)" ] && [ -f "$(transcript)" ]; then
    bytes="$(wc -c <"$(transcript)" 2>/dev/null | tr -d '[:space:]')"
  fi
  changed=0
  if [ -n "$NS_IDLE_SINCE" ] && [ "${NS_IDLE_BYTES:-0}" != "${bytes:-0}" ]; then
    changed=1
  fi
  now="$(date +%s)"
  window="$(ns_idle_window_minutes "$PROJECT")"
  verdict="$(ns_idle_verdict stale "$changed" "$known" "$delta" "$busy" "$NS_IDLE_SINCE" "$now" "$window" "$NS_IDLE_STUCK")"
  case "$verdict" in
    due)
      # shellcheck disable=SC2086
      ns_idle_stop_tree $pids || return 2
      NS_SESSION_QUIET=idle
      return 0
      ;;
    pending)
      [ -n "$NS_IDLE_SINCE" ] || NS_IDLE_SINCE="$now"
      [ -n "$NS_IDLE_CPU" ] || NS_IDLE_CPU="$cpu"
      [ -n "$NS_IDLE_BYTES" ] || NS_IDLE_BYTES="${bytes:-0}"
      NS_IDLE_PIDS="$pids"
      NS_IDLE_EVIDENCE="pulse stale, transcript unchanged, cpu $(ns_idle_cpu_label "$delta"), no busy child"
      ns_idle_save "$NS" || return 1
      return 1
      ;;
  esac
  return 1
}

# Runs the shared ending under the site lock. 0 when .ended is real and the armed marker is gone.
clock_out_direct() { # <ticked|stop|deadline> <gone|idle>
  local why="$1" how="$2" summary reason open_now ticked total moved own_rc detail hold
  LEASE_NONCE="${NIGHTSHIFT_LEASE_NONCE:-}"
  LEASE_GENERATION="${NIGHTSHIFT_LEASE_GENERATION:-}"
  SID=""
  ns_shift_unbound cursor gate
  own_rc=$?
  if [ "$own_rc" -eq 2 ]; then
    log_line "watchman: clock-out refused: ownership — ${NS_SHIFT_FAIL:-the shift is not bound to this watchman}"
    return 1
  fi
  ns_shift_ownership cursor "" "" gate
  own_rc=$?
  if [ "$own_rc" -eq 2 ]; then
    log_line "watchman: clock-out refused: ownership — ${NS_SHIFT_FAIL:-the shift lease is unreadable}"
    return 1
  fi
  open_now="$(ns_open_boxes "$PUNCH" 2>/dev/null)" || open_now=0
  ticked="$(ns_ticked_boxes "$PUNCH" 2>/dev/null)" || ticked=0
  total=$((open_now + ticked))
  if [ "$why" = ticked ]; then
    moved="$(ns_gate_done_mismatch "$PROJECT" "$PUNCH" 2>/dev/null)" || moved=""
    if [ -n "$moved" ]; then
      log_line "watchman: clock-out refused: $moved"
      return 1
    fi
    hold="$(ns_evidence_hold "$PROJECT" "$PUNCH" 2>/dev/null || true)"
    if [ -n "$hold" ]; then
      log_line "watchman: clock-out refused: $hold"
      return 1
    fi
  fi
  if ! ns_lock "$NS"; then
    log_line "watchman: clock-out refused: site lock stayed busy"
    return 1
  fi
  case "$why" in
    stop)
      reason="$(head -n1 "$STOP" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      summary="shift ended${reason:+ ($reason)}: $ticked/$total done"
      detail="stop-work order, session $how"
      ;;
    deadline)
      printf 'deadline\n' >"$STOP"
      log_line "quitting time — shift ended, $ticked/$total done, items left open"
      summary="quitting time: $ticked/$total done, items left open"
      detail="deadline passed, session $how"
      ;;
    *)
      summary="shift done: $ticked/$total"
      detail="every box ticked, session $how"
      ;;
  esac
  log_line "watchman: clocking out — $detail"
  ns_shift_end "$PROJECT" "$summary"
  own_rc=$?
  ns_unlock "$NS"
  if [ "$own_rc" -ne 0 ]; then
    log_line "watchman: clock-out refused: the ended marker was not written"
    return 1
  fi
  return 0
}

log_line "watchman (cursor) armed · every ${INTERVAL_MIN}m"
BASE_SLEEP="${NIGHTSHIFT_WATCH_SLEEP:-$((INTERVAL_MIN * 60))}"
wake=0
baseline_transcript
: >"$TICK" 2>/dev/null || true

while :; do
  if [ "${NIGHTSHIFT_WATCH_IMMEDIATE:-}" = 1 ]; then
    unset NIGHTSHIFT_WATCH_IMMEDIATE
  else
    sleep "$BASE_SLEEP"
  fi
  wake=$((wake + 1))

  armed || stand_down_disarmed
  holds_pidfile || stand_down_unclaimed
  if [ -f "$ENDED" ] && [ ! -L "$ENDED" ]; then note completed; exit 0; fi
  if [ ! -f "$PUNCH" ]; then note stand-down "punch list missing"; exit 0; fi
  if [ -f "$SESSION_END" ] && [ ! -L "$SESSION_END" ]; then
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

  ns_watchman_settle cursor
  settle_rc=$?
  if [ "$settle_rc" -eq 1 ]; then
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi

  # An unrecorded or unsupported scope cannot change until the owner edits recovery.launchScope.
  # Say so once, then wake without spawning a revival or a clock-out.
  if [ -z "$AGENT" ]; then
    ns_watchman_recovery_hold "$NS" "$PROJECT" cursor
    hold_rc=$?
    if [ "$hold_rc" -eq 2 ]; then
      hold_scope="$(ns_reason_detail "$NS")"
      log_line "watchman: $(ns_recovery_refusal "$hold_scope"). Recovery cannot restore this configured scope."
      log_line "watchman: the work is untouched. $(ns_recovery_repair "$PROJECT" "$hold_scope")"
      log_line "watchman: unattended revival and clock-out stay refused until recovery.launchScope changes"
    fi
    if [ "$hold_rc" -ne 1 ]; then
      if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
      continue
    fi
  fi

  clock_why=""
  if [ -f "$STOP" ]; then
    clock_why=stop
  elif open_now="$(open_boxes)" && [ "$open_now" -eq 0 ] && [ -z "$(ns_evidence_hold "$PROJECT" "$PUNCH" 2>/dev/null || true)" ]; then
    clock_why=ticked
  elif ns_gate_deadline_passed; then
    clock_why=deadline
  fi
  if [ -n "$clock_why" ]; then
    session_gone_or_idle
    quiet_rc=$?
    if [ "$quiet_rc" -eq 0 ]; then
      if clock_out_direct "$clock_why" "${NS_SESSION_QUIET:-gone}"; then
        case "$clock_why" in
          stop) note owner-stop ;;
          deadline) note deadline ;;
          *) note completed ;;
        esac
        exit 0
      fi
      note clock-out-failed
      exit 0
    fi
    if [ "$quiet_rc" -eq 2 ]; then
      note clock-out-failed
      log_line "watchman: clock-out refused: idle worker could not be stopped"
      exit 0
    fi
    if [ "${NS_CLOCK_WAIT_SAID:-}" != 1 ]; then
      NS_CLOCK_WAIT_SAID=1
      log_line "watchman: clock-out waits — session still working"
    fi
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi

  rec_rc=1
  if [ -n "$(rec_pid)" ]; then
    recorded_process_alive
    rec_rc=$?
  fi
  lease_rc=1
  lease_pid_live && lease_rc=0
  # A fresh pulse or a growing transcript is work. Anything else a live process
  # can still be is the shared idle rule: stop the tree, then revive as dead.
  if transcript_grew || pulse_alive; then
    ns_idle_note_busy "$NS"
    note silent-standby
    baseline_transcript
    : >"$TICK" 2>/dev/null || true
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi
  idle_pids=""
  if [ "$rec_rc" -eq 0 ]; then
    idle_pids="$(rec_pid)"
  fi
  if [ "$lease_rc" -eq 0 ] && [ "$NS_LEASE_PID" != "$idle_pids" ]; then
    idle_pids="${idle_pids:+$idle_pids }$NS_LEASE_PID"
  fi
  if [ -n "$idle_pids" ]; then
    # shellcheck disable=SC2086
    ns_idle_take "$NS" "$PROJECT" "$(transcript)" stale $idle_pids
    idle_take=$?
    case "$idle_take" in
      10) ;;
      12)
        note process-evidence-unavailable
        log_line "watchman: process evidence unavailable — standing down, not reviving"
        if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
        continue
        ;;
      13)
        note idle-stuck
        baseline_transcript
        : >"$TICK" 2>/dev/null || true
        if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
        continue
        ;;
      *)
        note silent-standby
        baseline_transcript
        : >"$TICK" 2>/dev/null || true
        if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
        continue
        ;;
    esac
  fi
  if [ "$rec_rc" -eq 3 ] && [ "$lease_rc" -ne 0 ]; then
    note process-evidence-unavailable
    log_line "watchman: process evidence unavailable — standing down, not reviving"
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi
  if ! ns_cursor_worker_present "$NS" && [ -f "$MINT_FAILED" ] && [ ! -L "$MINT_FAILED" ]; then
    note silent-standby
    baseline_transcript
    : >"$TICK" 2>/dev/null || true
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi

  if ns_idle_revival_blocked "$NS"; then
    note idle-stuck
    baseline_transcript
    : >"$TICK" 2>/dev/null || true
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi

  attempt=0
  revived=1
  held=0
  # shellcheck disable=SC2086
  set -- $RETRY_SPACING
  total=$(( $# + 1 ))
  for gap in 0 $RETRY_SPACING; do
    [ "$gap" -gt 0 ] && sleep "$gap"
    if site_alive; then
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
    spawn "$attempt"
    spawn_rc=$?
    if [ "$spawn_rc" -eq 0 ]; then
      revived=0
      ns_idle_after_revival "$NS" revived || true
      if [ "$attempt" -ge 2 ]; then
        note fresh-fallback
      else
        note revived
      fi
      notice_revival
      break
    fi
    if [ "$spawn_rc" -eq 2 ]; then
      held=1
      ns_idle_note_busy "$NS"
      note silent-standby
      break
    fi
    baseline_transcript
  done
  if [ "$revived" -eq 1 ] && [ "$attempt" -gt 0 ] && [ "$held" -eq 0 ]; then
    ns_idle_after_revival "$NS" failed
    if [ "$?" -ne 2 ]; then
      note exhausted-retry
    fi
    # Every attempt took the lease for its own worker. A ladder that revived nothing hands it
    # back, so the recorded conversation is not left waiting on a generation nobody holds.
    ns_lease_restore_interactive "$NS" || true
  fi
  baseline_transcript
  : >"$TICK" 2>/dev/null || true

  if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
done
