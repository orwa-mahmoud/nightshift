#!/usr/bin/env bash
# watchman.sh — the night watchman for Codex shifts. Revives a session that DIED mid-shift;
# never one that ended, and never another host's.
#
# A hook can only act inside a living session; a session killed by an API outage, a crash, or a
# closed terminal fires nothing, and the punch list just sits there. This is the outside half for
# Codex: armed at shift start, it wakes every interval and, only when the site is mid-shift and
# provably dead quiet, resumes the shift's own conversation —
#
#   codex exec resume -c 'sandbox_mode="danger-full-access"' <session-id> "<revival order>"
#
# A persisted .nightshift/work-target keeps the resumed session aimed at the same child repository
# when run state lives in a parent workspace. The command appends to the same rollout the session
# was writing when it died (verified live: a
# SIGKILLed session's rollout ends mid-event with no terminal marker, and the resume continues
# that very file). The fallback is a fresh headless run; the punch list on disk is its handover.
# Before either spawn, the watchman advances a process lease and passes its generation/nonce to
# the child. An older Desktop or terminal process on that conversation then loses observed tools.
#
# The sandbox grant is the owner's to choose, in rules.json under recovery.launchScope. The
# shipped host-grant starts a revived session with danger-full-access, because the workspace-write
# sandbox protects .git — a revived session could edit but never commit (verified live: "Git
# cannot create .git/index.lock"), and one commit per item IS the contract in repository mode.
# host-default passes no sandbox argument at all and takes whatever the host gives, which is
# narrower and may leave a revived session unable to commit. Whichever is in force is named in the
# shift log on every revival, and a failed rung is retried at the same scope, never a broader one.
# Artifact mode writes a receipt instead. The fence around that access is
# nightshift's own guards: the hardhat denies what the owner forbade, in every mode — the same
# trade Claude Code makes with bypassPermissions.
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
#     · the recorded pid (line 3) exists and its start time matches line 4
#     · any process whose executable is exactly `codex` has this project as its cwd
#     · the recorded rollout (line 2) grew since the last wake
#   DEAD (revive): none of the above, boxes open, and the site armed.
# Evidence, conservative by construction — revive only on strong positive evidence of death:
#   ALIVE (stand by), any of:
#     · a fresh .shift-pulse (epoch within 2 * watchMinutes)
#     · a missing pulse still inside the first two wake intervals after arm
#     · the recorded pid (line 3) exists and its start time matches line 4
#     · an empty recorded pid — empty pid never decides death unless the pulse is stale
#     · any process whose executable is exactly `codex` has this project as its cwd
#     · the recorded rollout (line 2) grew since the last wake
#   DEAD (revive): pulse stale, no rollout growth, no .session-end, boxes open, site armed.
# Missing process evidence stands by. The 500-wedge signature (an API error as the rollout's
# last word) has not been observed on Codex and is deliberately not guessed at; a
# live-but-erroring session reads as alive and is left alone.
#
# Stand-down order, checked at every wake — never override a declared ending:
#   0. the armed marker is gone (.shift-armed)        -> down (a disarmed site has no shift)
#   1. stop-work order (.nightshift/STOP)             -> down
#   2. shift ended (.nightshift/.ended, or no punch)  -> down
#   3. clean session end (.nightshift/.session-end)   -> down (owner closed it; Start re-arms)
#   4. another host's shift (.shift-session line 5)   -> down (its own watchman minds it)
#   5. every box ticked                                -> one clock-out spawn if .ended missing,
#                                                        then down (a crash at the finish line
#                                                        still gets receipts and the whistle)
#   6. deadline passed                                 -> one clock-out spawn, then down
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh" # pure-bash path — no dirname dependency

PROJECT="$PWD"
INTERVAL_MIN="${NIGHTSHIFT_WATCH:-}"
# Resolved from rules watchAgent (env override) after the project is known.
AGENT=""
MAX_WAKES=0

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
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
[ "$INTERVAL_MIN" -gt 0 ] || exit 0 # 0 = disabled, by design

# Empty watchAgent keeps Codex's default resume/fresh ladder; non-empty is owner verbatim.
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

# One watchman per site — either host's. A stale pidfile from a dead holder is taken over.
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
rollout()    { [ -L "$NS/.shift-session" ] && return; sed -n 2p "$NS/.shift-session" 2>/dev/null; }
rec_pid()    { [ -L "$NS/.shift-session" ] && return; sed -n 3p "$NS/.shift-session" 2>/dev/null | tr -d '[:space:]'; }
rec_start()  { [ -L "$NS/.shift-session" ] && return; sed -n 4p "$NS/.shift-session" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
open_boxes() { ns_open_boxes "$PUNCH"; }

# The recorded pid counts only as the exact recorded process: pid + start time, a pair that pid
# reuse cannot counterfeit.
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

# Any codex working in this project stands the watchman by — matched on the exact executable
# name, never a substring: unrelated processes carry "codex" deep in their environment.
codex_in_project() {
  local p cwd
  ns_have_cmd pgrep || return 2
  for p in $(pgrep -x codex 2>/dev/null); do
    cwd="$(ns_proc_cwd "$p")" || continue
    [ "$cwd" = "$PROJECT" ] && return 0
  done
  return 1
}

# The rollout is the session's own pulse: a live session streams events into it. Growth since
# the last wake is life; the sentinel is re-baselined every wake and after every failed spawn so
# the watchman's own attempts never read as site activity.
ROLLOUT_SEEN=""
baseline_rollout() {
  local r
  r="$(rollout)"
  [ -n "$r" ] && [ -f "$r" ] && ROLLOUT_SEEN="$(wc -c <"$r" 2>/dev/null | tr -d ' ')" || ROLLOUT_SEEN=""
}
rollout_grew() {
  local r now
  r="$(rollout)"
  [ -n "$r" ] && [ -f "$r" ] || return 1
  now="$(wc -c <"$r" 2>/dev/null | tr -d ' ')"
  [ -n "$ROLLOUT_SEEN" ] && [ "$now" != "$ROLLOUT_SEEN" ]
}

# Spawn one revival attempt. Ownership transfers atomically before the child starts; every hook
# in that child inherits the new generation/nonce, and an older Desktop or terminal process on
# the same conversation is fenced. Rung 1 resumes the recorded conversation; rung 2 is a fresh
# headless run with the punch list as its handover.
# A non-resumable recorded id is never passed to `codex exec resume` and never treated as a
# successful resume of that thread.
# A fresh headless run at the resolved scope. The scope never widens between rungs: a revival that
# failed is retried at the same permissions, never at broader ones.
spawn_fresh() {
  local mode
  log_line "watchman: reviving under launch scope $1"
  case "$1" in
    host-default)
      ns_watchman_run_child "$NS" codex "$(sid)" "$WORK_TARGET" \
        CODEX_PROJECT_DIR "$PROJECT" \
        codex exec "$PROMPT_FRESH"
      return $?
      ;;
    recorded:*)
      mode="${1#recorded:}"
      ns_watchman_run_child "$NS" codex "$(sid)" "$WORK_TARGET" \
        CODEX_PROJECT_DIR "$PROJECT" \
        codex exec -s "$mode" "$PROMPT_FRESH"
      return $?
      ;;
  esac
  # host-grant, and only host-grant: the owner wrote it in their own file.
  ns_watchman_run_child "$NS" codex "$(sid)" "$WORK_TARGET" \
    CODEX_PROJECT_DIR "$PROJECT" \
    codex exec -s danger-full-access "$PROMPT_FRESH"
}

# Set once when a revival is refused because the recorded scope cannot be reproduced. Retrying
# cannot change that answer, so the ladder stops instead of spending its rungs on it.
RECOVERY_REFUSED=0

spawn() { # $1 = rung (1|2)
  local prompt kind rc scope
  scope="$(ns_recovery_effective_scope "$PROJECT" codex)"
  case "$scope" in
    unavailable:*)
      RECOVERY_REFUSED=1
      log_line "watchman: the shift recorded sandbox mode '${scope#unavailable:}', which codex exec has no way to be asked for. Not reviving at a scope this host cannot reproduce."
      log_line "watchman: the work is untouched. Resume the shift yourself, or name the scope a revival may use by setting recovery.launchScope to host-default or host-grant in .nightshift/rules.json."
      note recovery-scope-unavailable
      return 1
      ;;
  esac
  if [ -n "$AGENT" ]; then
    if [ "$1" -eq 1 ]; then prompt="$PROMPT_RESUME"; else prompt="$PROMPT_FRESH"; fi
    # shellcheck disable=SC2086 # owner-provided command line; splitting is intentional
    ns_watchman_run_child "$NS" codex "$(sid)" "$WORK_TARGET" \
      CODEX_PROJECT_DIR "$PROJECT" $AGENT "$prompt"
  elif [ "$1" -eq 1 ]; then
    kind="$(ns_codex_identity_kind "$(sid)")"
    if [ "$kind" = "resumable" ]; then
      log_line "watchman: reviving under launch scope $scope"
      case "$scope" in
        host-default)
          ns_watchman_run_child "$NS" codex "$(sid)" "$WORK_TARGET" \
            CODEX_PROJECT_DIR "$PROJECT" \
            codex exec resume "$(sid)" "$PROMPT_RESUME"
          ;;
        recorded:*)
          ns_watchman_run_child "$NS" codex "$(sid)" "$WORK_TARGET" \
            CODEX_PROJECT_DIR "$PROJECT" \
            codex exec resume -c "sandbox_mode=\"${scope#recorded:}\"" "$(sid)" "$PROMPT_RESUME"
          ;;
        *)
          ns_watchman_run_child "$NS" codex "$(sid)" "$WORK_TARGET" \
            CODEX_PROJECT_DIR "$PROJECT" \
            codex exec resume -c 'sandbox_mode="danger-full-access"' "$(sid)" "$PROMPT_RESUME"
          ;;
      esac
    else
      spawn_fresh "$scope"
    fi
  else
    spawn_fresh "$scope"
  fi
  rc=$?
  if [ "$rc" -eq 3 ]; then
    log_line "watchman: process lease transfer failed — not spawning beside an unfenced session"
    return 1
  fi
  return "$rc"
}

rung_name() { if [ "$1" -eq 1 ] && [ -n "$(sid)" ]; then printf 'resuming the recorded conversation'; else printf 'fresh session'; fi; }

log_line "watchman (codex) armed · every ${INTERVAL_MIN}m"
BASE_SLEEP="${NIGHTSHIFT_WATCH_SLEEP:-$((INTERVAL_MIN * 60))}"
wake=0
baseline_rollout
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

  # Another host's shift is another watchman's business: resuming it from here would spawn
  # codex against a conversation a different agent owns.
  host="$(ns_session_host "$NS")"
  if [ "$host" != codex ]; then
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

  # Life, in evidence order: the recorded process, any codex in the project, the rollout pulse.
  # Missing optional tools are not death — stand down rather than revive beside a living session.
  rec_rc=1
  if [ -n "$(rec_pid)" ]; then
    recorded_process_alive
    rec_rc=$?
    if [ "$rec_rc" -eq 0 ]; then
      note silent-standby
      baseline_rollout
      : >"$TICK" 2>/dev/null || true
      if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
      continue
    fi
  fi
  codex_in_project
  in_rc=$?
  if [ "$in_rc" -eq 0 ] || rollout_grew; then
    note silent-standby
    baseline_rollout
    : >"$TICK" 2>/dev/null || true
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi
  if pulse_alive; then
    note silent-standby
    baseline_rollout
    : >"$TICK" 2>/dev/null || true
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi
  if [ "$rec_rc" -eq 3 ] || { [ "$in_rc" -eq 2 ] && [ "$rec_rc" -ne 1 ]; }; then
    note process-evidence-unavailable
    log_line "watchman: process evidence unavailable — standing down, not reviving"
    if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
    continue
  fi

  # A recorded identity that cannot be resumed is not a missing first-record (that still gets
  # the fresh fallback). Guessing, or starting an unrelated conversation, would claim a thread
  # this watchman did not resume.
  if [ -z "$AGENT" ]; then
    kind="$(ns_codex_identity_kind "$(sid)")"
    if [ "$kind" != "resumable" ] && [ "$kind" != "missing" ]; then
      note non-resumable-session "$kind"
      log_line "watchman: recorded Codex identity is $kind — standing down; not resuming and not starting a fresh thread"
      exit 0
    fi
  fi

  # Dead quiet, mid-shift: revive. Attempts = watchRetrySeconds values + 1, re-checking
  # life between them — a site that comes back mid-wake cancels the rest.
  attempt=0
  revived=1
  # shellcheck disable=SC2086  # RETRY_SPACING is a space-separated list; splitting is the point
  set -- $RETRY_SPACING
  total=$(( $# + 1 ))
  for gap in 0 $RETRY_SPACING; do
    [ "$gap" -gt 0 ] && sleep "$gap"
    if recorded_process_alive || codex_in_project || rollout_grew || pulse_alive; then
      note silent-standby
      log_line "watchman: session activity during retries — holding the remaining attempts"
      break
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -le "$total" ] || break
    log_line "watchman: site dead quiet mid-shift — resume attempt $attempt ($(rung_name $attempt))"
    if [ "$RECOVERY_REFUSED" -eq 1 ]; then break; fi
    if spawn "$attempt"; then
      revived=0
      if [ "$attempt" -ge 2 ] || [ -z "$(sid)" ]; then
        note fresh-fallback
      else
        note revived
      fi
      log_line "watchman: revival returned — the night continues: codex exec resume $(sid)"
      break
    fi
    baseline_rollout
  done
  if [ "$revived" -eq 1 ] && [ "$attempt" -gt 0 ]; then
    note exhausted-retry
    # Every attempt took the lease for its own child. A ladder that revived nothing hands it
    # back, so the recorded conversation is not left waiting on a generation nobody holds.
    ns_lease_restore_interactive "$NS" || true
  fi
  baseline_rollout
  : >"$TICK" 2>/dev/null || true

  if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 0; fi
done
