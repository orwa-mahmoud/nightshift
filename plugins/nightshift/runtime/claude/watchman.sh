#!/usr/bin/env bash
# watchman.sh — the night watchman. Revives a session that DIES mid-shift; never one that ended.
#
# A Stop hook can only act inside a living session. A session killed by an API outage, a crash,
# or a closed terminal fires no hooks — the punch list survives on disk, but nothing re-invokes
# the agent, and the night is lost. The watchman is the outside half: armed at shift start, it
# wakes every interval and, only when the site is BOTH mid-shift and dead quiet, resumes the
# shift's OWN conversation by id — the hours of context it already had, not a briefing. Only if
# that conversation is itself unusable does it fall back, and the punch list on disk is what
# carries a fresh session when it must. A persisted .nightshift/work-target tells that session
# which child repository contains the code when run state lives in a parent workspace.
# Before every spawn, the watchman advances a process lease and passes its generation/nonce to
# the child. An older terminal or IDE process on that conversation then loses observed tools.
#
#   watchman.sh [--project DIR] [--interval MIN] [--agent CMD] [--max-wakes N]
#
#   --interval  minutes between wakes (default: the rules file's watchMinutes, overridable by
#               $NIGHTSHIFT_WATCH; 0 exits immediately — the "disabled" spelling)
#   --agent     the resume command. Default: the SHIFT'S OWN conversation, by id — the hooks
#               record the first working session into .nightshift/.shift-session, and the
#               revival is "claude --resume <that id> -p", one unbroken thread in the terminal
#               and the IDE extension alike. On the default agent the attempts of a wake walk a
#               chain, each rung logged: the recorded conversation first, "claude --continue -p"
#               next (no record starts here), and a fresh "claude -p" last — if the conversation
#               itself is what broke, resuming it would fail every wake forever, and the punch
#               list on disk is enough for a fresh session to carry on.
#   --max-wakes bound the number of wakes (0 = unbounded; tests use this)
#
# Stand-down order, checked at every wake — the watchman never overrides a declared ending:
#   0. the armed marker is gone (.shift-armed)       -> down; a disarmed site has no shift to
#                                                       revive, and the marker is never written
#                                                       back from here. The pidfile going with
#                                                       it — reset, purge, a takeover — is the
#                                                       same answer: this loop is not the one
#                                                       watching any more
#   1. stop-work order (.nightshift/STOP)            -> down (STOP is the pause while armed)
#   2. shift ended (.nightshift/.ended, or no punch) -> down
#   3. every box ticked                              -> one clock-out spawn if .ended is missing
#                                                       (crash at the finish line still gets
#                                                       receipts + whistle), then down
#   4. quitting time passed                          -> one clock-out spawn, then down
#   5. clean session end (.nightshift/.session-end)  -> down; the owner closed it on purpose
#
# Liveness is a ladder, session-first — revival needs strong positive evidence of death,
# because spawning beside a living process is still harmful: the process lease fences its next
# observed tool, but cannot cancel work already in flight or refresh a stale UI. Only the
# session's own signals testify; project files never vote — a detached loop, a build, or a sync writing
# files can neither mute the owner's Esc nor mask a dead session as alive:
#   1. interrupt marker in the transcript tail       -> owner pressed Esc; stand by
#   2. the shift's transcript moved since last wake  -> alive (a session streams every turn)
#      a fresh .shift-pulse (epoch within 2 * watchMinutes) is the same tell for a quiet tab
#   3. recorded pid alive (start time verified)      -> transcript's last word is the host's own
#                                                       API-error event? the 500 wedge: alive but
#                                                       errored, nobody home — revive.
#                                                       Otherwise -> long silent work; stand by
#   4. `claude agents --json` (the host's roster)    -> id present: alive, wedge rule as above —
#                                                       it even rescues a stale recorded pid;
#                                                       a clean roster without it: dead; revive
#   5. pid provably dead, or roster without the id   -> dead; revive
#   6. neither oracle answered                       -> a claude process working in the project
#                                                       stands it by; else dead; revive
#   7. no identity recorded at all                   -> transcript ends in the error -> the
#                                                       wedge again (a 500 can land before the
#                                                       first tool call records identity;
#                                                       --continue resumes that conversation);
#                                                       a claude process in the project stands
#                                                       it by; else dead; revive
# Every retry attempt re-runs the whole ladder first — a site that comes back to life mid-wake
# is left alone — and each failed attempt re-baselines the sentinel so its own transcript writes
# never read as site life.
#
# Esc still means stop. Claude Code records a user interrupt in the session transcript
# ("Request interrupted by user"), and a 500 or a crash never writes one — that is the tell, read
# from the tail of THE SHIFT'S OWN transcript (recorded in .shift-session by the hooks). A second
# tab's Esc proves nothing and is ignored. With no record yet, the newest transcript in the
# project is the fallback tell. Unreadable defaults to reviving: waking a paused session costs an
# apology, a lost night costs the night. $NIGHTSHIFT_WATCH_TRANSCRIPTS overrides the transcript
# directory (tests use it).
#
# API outages: per wake, spawn attempts = watchRetrySeconds values + 1
# (shipped "30 120"; $NIGHTSHIFT_WATCH_RETRY overrides). A wake that fails entirely just waits
# for the next one — the watchman knocks every interval, all night, until the API answers. When
# the transcript's last error names the limit that refused the work (a rate or usage limit, 429,
# 529, an api error), the wait doubles instead: an account with nothing left to spend is knocked
# on less and less often, up to an hour apart, and the first pulse or revival puts the wait back
# to the configured interval.
# Exit: 0 stood down · 1 usage/lock · 7 wake cap (tests).
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh" # pure-bash path — no dirname dependency

PROJECT="$PWD"
INTERVAL_MIN="${NIGHTSHIFT_WATCH:-}" # resolved from the rules file once the project is known
# Owner agent starts empty; after the project is known, rules watchAgent (env override) decides.
# Empty = host default resume ladder. Non-empty = verbatim on every rung.
AGENT=""
AGENT_IS_DEFAULT=1
MAX_WAKES=0

usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
  exit 1
}
need_value() { [ "$2" -ge 2 ] || { printf 'watchman: %s needs a value\n' "$1" >&2; usage; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project) need_value "$1" $#; PROJECT="$2"; shift 2 ;;
    --interval) need_value "$1" $#; INTERVAL_MIN="$2"; shift 2 ;;
    --agent) need_value "$1" $#; AGENT="$2"; AGENT_IS_DEFAULT=0; shift 2 ;;
    --max-wakes) need_value "$1" $#; MAX_WAKES="$2"; shift 2 ;;
    -h | --help) usage ;;
    *) printf 'watchman: unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

cd "$PROJECT" 2>/dev/null || exit 1
PROJECT="$PWD"
WORK_TARGET="$(ns_work_target "$PROJECT" 2>/dev/null || true)"
[ -n "$WORK_TARGET" ] || WORK_TARGET="$PROJECT"

cd "$PROJECT" || { printf 'watchman: cannot cd to %s\n' "$PROJECT" >&2; exit 1; }
PROJECT="$PWD"

# One copy: the rules file is the config; a flag or env var is a session-start override. The
# shipped values live visibly in the file setup copies — there are no fallbacks hiding here,
# and a missing knob refuses to arm, loudly, naming the repair.
NS="$PROJECT/.nightshift"
[ -d "$NS" ] || { printf 'watchman: no .nightshift at %s\n' "$PROJECT" >&2; exit 1; }
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
RETRY_SPACING="$(rule "$PROJECT" watchRetrySeconds "${NIGHTSHIFT_WATCH_RETRY:-}")"
# watchAgent: empty (shipped) keeps the resume ladder; non-empty is used verbatim every attempt.
# Env NIGHTSHIFT_WATCH_AGENT overrides the file for the session. --agent on the CLI wins first.
# A missing key reads as empty. Do not overwrite a CLI --agent that already cleared the default.
if [ "$AGENT_IS_DEFAULT" -eq 1 ]; then
  AGENT="$(rule "$PROJECT" watchAgent "${NIGHTSHIFT_WATCH_AGENT:-}")"
  if [ -n "$AGENT" ]; then
    AGENT_IS_DEFAULT=0
  else
    AGENT="claude --continue -p"
  fi
fi
NOTIFY="$(rule "$PROJECT" notifyCommand "${NIGHTSHIFT_NOTIFY_CMD:-}")" # empty = silent, a configured value
PUNCH="$NS/punch-list.md"
PIDFILE="$NS/.watchman"
SENTINEL="$NS/.watchman-tick"
ARMED="$NS/.shift-armed" # read exactly as the hooks read it, so both agree on "a shift is running"

# Claude Code keeps transcripts under ~/.claude/projects/<project path, non-alnum -> dashes>.
TRANSCRIPTS="${NIGHTSHIFT_WATCH_TRANSCRIPTS:-$HOME/.claude/projects/$(printf '%s' "$PROJECT" | tr -c 'A-Za-z0-9' '-')}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_line() { printf '%s · %s\n' "$(ts)" "$1" >>"$NS/shift-log.md"; }

# The marker is the shift. Without it there is nothing to revive, nothing to clock out, and no
# reading to take — the owner ended the arming, and the watchman is the outside half of a shift
# that no longer exists.
armed() { [ -f "$ARMED" ]; }
stand_down_disarmed() {
  note owner-disarm
  log_line "watchman: the armed marker is gone — standing down"
  exit 0
}

# The pidfile is this loop's claim on the site. Reset and purge remove it; a takeover replaces
# the pid inside it. Either way the watching is somebody else's now, and a pidfile that is no
# longer ours is never cleaned up on the way out — not here, and not from the exit trap.
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
holds_pidfile() {
  [ -f "$PIDFILE" ] || return 1
  [ ! -L "$PIDFILE" ] || return 1
  [ "$(sed -n 1p "$PIDFILE" 2>/dev/null)" = "$$" ]
}

# One watchman per site. A stale pidfile (dead pid) is taken over silently.
# A planted symlink is not a live owner — replace it rather than follow it.
if [ -L "$PIDFILE" ]; then
  rm -f "$PIDFILE"
elif [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  printf 'watchman: already watching (pid %s)\n' "$(cat "$PIDFILE")" >&2
  exit 1
fi
printf '%s\n' "$$" >"$PIDFILE"
trap 'holds_pidfile && rm -f "$PIDFILE"' EXIT

# Counted below the `## Items` heading only, exactly as the gate counts them — a watchman that
# read a checkbox out of the contract prose would keep reviving a shift the gate considers done.
open_boxes() { ns_open_boxes "$PUNCH"; }

deadline_passed() {
  local dl
  [ -L "$NS/deadline" ] && return 1
  [ -f "$NS/deadline" ] || return 1
  dl="$(tr -d '[:space:]' <"$NS/deadline" 2>/dev/null || true)"
  [ -n "$dl" ] || return 1
  case "$dl" in *[!0-9]*) return 1 ;; esac # start/hunt write epochs; anything else is not ours to judge
  [ "$(date +%s)" -ge "$dl" ]
}

# The hooks write the shift's identity at first work: session id, transcript path, and the
# claude ancestor's pid + start time. Read fresh each use — the record appears after the
# watchman was armed.
shift_session_id() { [ -L "$NS/.shift-session" ] && return; sed -n 1p "$NS/.shift-session" 2>/dev/null; }
shift_transcript() { [ -L "$NS/.shift-session" ] && return; sed -n 2p "$NS/.shift-session" 2>/dev/null; }
shift_pid() { [ -L "$NS/.shift-session" ] && return; sed -n 3p "$NS/.shift-session" 2>/dev/null; }
shift_pid_start() { [ -L "$NS/.shift-session" ] && return; sed -n 4p "$NS/.shift-session" 2>/dev/null; }

# Attempts of a wake walk a chain of rungs on the default agent: the recorded conversation
# first, --continue next (and first when nothing was recorded), a fresh session last — each a
# weaker but sturdier claim on the night. An owner-supplied agent is used verbatim on every rung.
rung_agent() { # $1 attempt, $2 total attempts this wake
  local sid
  if [ "$AGENT_IS_DEFAULT" -ne 1 ]; then printf '%s' "$AGENT"; return; fi
  if [ "$1" -ge "$2" ] && [ "$2" -gt 1 ]; then printf 'claude -p'; return; fi
  sid="$(shift_session_id)"
  if [ "$1" -eq 1 ] && [ -n "$sid" ]; then printf 'claude --resume %s -p' "$sid"; else printf 'claude --continue -p'; fi
}
rung_label() { # morning-readable name for the rung, mirrors rung_agent
  if [ "$AGENT_IS_DEFAULT" -ne 1 ]; then printf 'owner agent'; return; fi
  if [ "$1" -ge "$2" ] && [ "$2" -gt 1 ]; then printf 'fresh-session fallback'; return; fi
  if [ "$1" -eq 1 ] && [ -n "$(shift_session_id)" ]; then printf 'resuming the recorded conversation'; else printf -- '--continue fallback'; fi
}
# Clock-out spawns take the strongest single rung: the recorded conversation, else --continue.
resolve_agent() { rung_agent 1 2; }

# A resumed conversation carries its own context — the thread IS the instruction, and the gate
# does the enforcing. Its order is one line: you were cut off, keep going. Only the
# fresh-session fallback, which starts empty, gets the full pointer at the punch list. Both are
# the owner's to word (rules file keys: revivalPrompt, freshRevivalPrompt).
PROMPT_RESUME="$(ns_expand_injected_paths "$PROJECT" "$(rule "$PROJECT" revivalPrompt "${NIGHTSHIFT_REVIVAL_PROMPT:-}")")"
PROMPT_FRESH="$(ns_expand_injected_paths "$PROJECT" "$(rule "$PROJECT" freshRevivalPrompt "${NIGHTSHIFT_FRESH_PROMPT:-}")")"
for _req in "watchRetrySeconds:$RETRY_SPACING" "revivalPrompt:$PROMPT_RESUME" "freshRevivalPrompt:$PROMPT_FRESH"; do
  if [ -z "${_req#*:}" ]; then
    note unreadable-rules "${_req%%:*}"
    printf 'watchman: %s missing — .nightshift/rules.json absent or incomplete; run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex)\n' "${_req%%:*}" >&2
    log_line "watchman: rules.json is missing ${_req%%:*} — cannot arm; run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex)"
    exit 1
  fi
done

# Resumed rungs get the short order; the fresh rung gets the map. Attempts mirror rung_agent.
rung_prompt() { # $1 attempt, $2 total attempts this wake
  if [ "$1" -ge "$2" ] && [ "$2" -gt 1 ]; then printf '%s' "$PROMPT_FRESH"; else printf '%s' "$PROMPT_RESUME"; fi
}

# One spawn attempt. Ownership transfers before the child starts: the new generation/nonce is
# inherited by every hook in that process, while an older process on the same conversation loses
# tool access immediately. The child shell's pid + start time make the holder inspectable; the
# Claude hook replaces them with the exact Claude ancestor when its first tool arrives.
# The owner-provided $AGENT command line is intentionally word-split below.
spawn() { # $1 optionally overrides the agent for this one attempt; $2 the order for its rung
  local a="${1:-$AGENT}" p="${2:-$PROMPT_RESUME}" rc
  # NIGHTSHIFT_REVIVAL marks the child for the hooks: a revival session ending is never the
  # owner's hand on the door — without the mark, the worker's own exit would write .session-end
  # under the recorded id and stand the watchman down mid-outage.
  # The owner-provided $a command line is intentionally word-split below.
  # shellcheck disable=SC2086
  ns_watchman_run_child "$NS" claude "$(shift_session_id)" "$WORK_TARGET" \
    CLAUDE_PROJECT_DIR "$PROJECT" $a "$p"
  rc=$?
  if [ "$rc" -eq 3 ]; then
    log_line "watchman: process lease transfer failed — not spawning beside an unfenced session"
    return 1
  fi
  return "$rc"
}

# Ownership goes back where it came from. Every attempt of a wake took the lease for its own
# child; a ladder that revived nothing leaves that generation held by a process which no longer
# exists, and the recorded conversation is the one that has to be able to work. The recorded
# process is named on the lease only while it is provably alive — an interactive lease is that
# process's to hold — and left empty otherwise, so any process reopening the conversation is
# served. A live holder is left alone: that is a worker, not a corpse.
restore_recorded_lease() {
  local host generation nonce holder holder_start sid recorded pid start rc
  ns_lease_lock "$NS" || return 1
  if ! ns_lease_valid "$NS"; then
    ns_lease_unlock "$NS"
    return 1
  fi
  host="$NS_LEASE_HOST"
  generation="$NS_LEASE_GENERATION"
  nonce="$NS_LEASE_NONCE"
  holder="$NS_LEASE_PID"
  holder_start="$NS_LEASE_START"
  sid="$NS_LEASE_SID"
  if [ -z "$nonce" ]; then # already interactive: nothing was taken, nothing to give back
    ns_lease_unlock "$NS"
    return 0
  fi
  if [ -n "$holder" ]; then
    ns_recorded_process "$holder" "$holder_start"
    rc=$?
    if [ "$rc" -ne 1 ]; then
      ns_lease_unlock "$NS"
      return 1
    fi
  fi
  recorded="$(shift_session_id)" # the record is the truth: a fresh rung may have rebound it
  [ -z "$recorded" ] || sid="$recorded"
  if [ -z "$sid" ]; then # no conversation to name; an unowned lease fences nobody
    rm -f "$NS/.shift-lease"
    rc=$?
    ns_lease_unlock "$NS"
    return "$rc"
  fi
  pid="$(shift_pid | tr -d '[:space:]')"
  start="$(shift_pid_start)"
  if ! ns_recorded_process "$pid" "$start"; then
    pid=""
    start=""
  fi
  ns_lease_write_unlocked "$NS" "$sid" "$host" "$((generation + 1))" "" "$pid" "$start"
  rc=$?
  ns_lease_unlock "$NS"
  return "$rc"
}

# The transcript the tells read: the shift's own, recorded by the hooks; the newest in the
# project's transcript directory is the fallback before the record exists.
resolve_transcript() {
  local f latest=""
  latest="$(shift_transcript)"
  if [ -n "$latest" ] && [ -f "$latest" ]; then printf '%s' "$latest"; return; fi
  latest=""
  for f in "$TRANSCRIPTS"/*.jsonl; do
    [ -f "$f" ] || continue
    if [ -z "$latest" ] || [ "$f" -nt "$latest" ]; then latest="$f"; fi
  done
  printf '%s' "$latest"
}

# The Esc tell: the owner's interrupt matters only as the transcript's LAST WORD — the same
# rule as the wedge. An interrupt the owner already resumed past has newer conversation events
# after it and is history, not a pause; process death right after such a resume must read as
# death. Trailing bookkeeping lines are not conversation and cannot mask the marker.
owner_paused() {
  local t
  t="$(resolve_transcript)"
  [ -n "$t" ] || return 1
  tail -n 25 "$t" 2>/dev/null | awk '
    /[^\\]"type"[[:space:]]*:[[:space:]]*"(user|assistant)"/ {
      esc = /Request interrupted by user/
    }
    END { exit esc ? 0 : 1 }'
}

# The wedge tell: Claude Code records an API failure as its own synthetic assistant event,
# flagged "isApiErrorMessage":true at the top level — an owner pasting "API Error: 500" into a
# prompt carries no such field, and prose quoting the field arrives with its quotes escaped,
# which the [^\\] guard skips. The wedge is the session sitting at that errored prompt NOW, so
# the flag must be on the LAST conversation event (user or assistant): anything after it —
# a retry, an answer, the owner's next prompt — means somebody already acted, and a session
# whose owner is awake at the keyboard is not the watchman's to touch. Trailing bookkeeping
# lines (summaries, snapshots) are not conversation and cannot mask the wedge.
errored_tail() {
  local t
  t="$(resolve_transcript)"
  [ -n "$t" ] || return 1
  tail -n 25 "$t" 2>/dev/null | awk '
    /[^\\]"type"[[:space:]]*:[[:space:]]*"(user|assistant)"/ {
      wedge = /[^\\]"isApiErrorMessage"[[:space:]]*:[[:space:]]*true/
    }
    END { exit wedge ? 0 : 1 }'
}

# The outage tell, read after a whole ladder of attempts has failed: the last error the host
# itself recorded names the thing that refused the work. A rate or usage limit, a 429, a 529, or
# an api error is an account or a service the next knock cannot argue with either — worth waiting
# out. Anything else (a broken transcript, a bad agent command) is not, and keeps the interval.
#
# Only a line the host marked as its own API error counts. The same words typed by a person, or
# quoted back inside a tool result, are text about a failure and not a failure: without that
# marker the watchman keeps its ordinary interval rather than standing down for an hour on
# something it read in a message.
api_limited_tail() {
  local t
  t="$(resolve_transcript)"
  [ -n "$t" ] || return 1
  tail -n 25 "$t" 2>/dev/null | awk '
    /[^\\]"isApiErrorMessage"[[:space:]]*:[[:space:]]*true/ { last = tolower($0) }
    END {
      exit (last ~ /(rate|usage)[ _-]?limit/ ||
            last ~ /(^|[^0-9])(429|529)([^0-9]|$)/ ||
            last ~ /(^|[^a-z])api([^a-z]|$)/) ? 0 : 1
    }'
}

# Primary pulse: a live session streams every turn into its transcript, even when the work
# writes no project files — long reasoning, research, a wall of tool output.
transcript_pulse() {
  local t
  t="$(resolve_transcript)"
  [ -n "$t" ] && [ "$t" -nt "$SENTINEL" ]
}

# The process witness. 0: the recorded process is alive — pid checked with kill -0 and the start
# time re-read, because a reused pid wears the number but not the birthday. 1: provably dead.
# 2: nothing recorded to check.
shift_process_alive() {
  ns_recorded_process "$(shift_pid)" "$(shift_pid_start)"
}

# Fallback witness when no pid was recorded: any claude process whose working directory is this
# project. Not the shift's identity — just reason enough not to spawn beside it.
project_has_claude() {
  local p comm cwd
  ns_have_cmd pgrep || return 2
  for p in $(pgrep -f claude 2>/dev/null); do
    if ns_have_cmd ps; then
      comm="$(ps -o comm= -p "$p" 2>/dev/null)"
      case "${comm##*/}" in claude) ;; *) continue ;; esac
    fi
    cwd="$(ns_proc_cwd "$p")" || continue
    case "$cwd" in "$PROJECT" | "$PROJECT"/*) return 0 ;; esac
  done
  return 1
}

# The registry witness: `claude agents --json` is the host's own roster of every live session,
# interactive and background. The recorded id present is the host saying the shift is alive; a
# clean roster without it is the host saying it is gone. 0 present · 1 absent · 2 no record, or
# a CLI without the command — which proves nothing.
registry_state() {
  local sid out
  sid="$(shift_session_id)"
  [ -n "$sid" ] || return 2
  out="$(claude agents --json 2>/dev/null)" || return 2
  case "$out" in \[*) ;; *) return 2 ;; esac
  printf '%s' "$out" | grep -qF "\"$sid\"" && return 0
  return 1
}

# The verdict, session-first. The session's own signals decide — the owner's Esc above all,
# then the shift's transcript, then its process, then the host's registry. Project files never
# vote: folder noise (a detached loop, a build, a sync) must never mute the owner's Esc, and
# must never mask a dead session as alive.
site_verdict() { # prints: esc | alive | silent | wedge | tabs | dead | unavailable
  local sid ps rg ph
  if owner_paused; then printf 'esc'; return; fi
  if transcript_pulse; then printf 'alive'; return; fi
  if ns_pulse_fresh "$NS" "$INTERVAL_MIN"; then printf 'alive'; return; fi
  sid="$(shift_session_id)"
  if [ -n "$sid" ]; then
    shift_process_alive
    ps=$?
    if [ "$ps" -eq 0 ]; then
      if errored_tail; then printf 'wedge'; else printf 'silent'; fi
      return
    fi
    registry_state
    rg=$?
    if [ "$rg" -eq 0 ]; then
      # The pid may be stale or unrecorded, but the host lists the session — alive.
      if errored_tail; then printf 'wedge'; else printf 'silent'; fi
      return
    fi
    if [ "$ps" -eq 1 ] || [ "$rg" -eq 1 ]; then printf 'dead'; return; fi
    project_has_claude
    ph=$?
    if [ "$ph" -eq 0 ]; then printf 'tabs'; return; fi
    if [ "$ps" -eq 3 ] || [ "$ph" -eq 2 ]; then printf 'unavailable'; return; fi
    printf 'dead'
    return
  fi
  # No identity recorded — a 500 can land before the first tool call writes one. The newest
  # conversation ending in the host's error event is the wedge; --continue resumes it.
  if errored_tail; then printf 'wedge'; return; fi
  project_has_claude
  ph=$?
  if [ "$ph" -eq 0 ]; then printf 'tabs'; return; fi
  if [ "$ph" -eq 2 ]; then printf 'unavailable'; return; fi
  printf 'dead'
}

# Re-evaluated before every retry attempt: a declared ending arriving, the session coming back
# to life, or the owner acting mid-wake cancels the remaining attempts. Empty means revival is
# still warranted.
hold_reason() {
  if [ -f "$NS/STOP" ]; then printf 'stop-work order'; return; fi
  if { [ -f "$NS/.ended" ] && [ ! -L "$NS/.ended" ]; } || [ ! -f "$PUNCH" ]; then printf 'shift ended'; return; fi
  if [ "$(open_boxes)" -eq 0 ]; then printf 'all boxes ticked'; return; fi
  if deadline_passed; then printf 'deadline passed'; return; fi
  if [ -f "$NS/.session-end" ] && [ ! -L "$NS/.session-end" ]; then printf 'clean session end'; return; fi
  case "$(site_verdict)" in
    alive) printf 'session activity' ;;
    esc) printf 'owner Esc' ;;
    silent) printf 'live shift session' ;;
    tabs) printf 'a live claude session in the project' ;;
    unavailable) printf 'process evidence unavailable' ;;
  esac
}

log_line "watchman armed · every ${INTERVAL_MIN}m"
: >"$SENTINEL"
wake=0
standby_prev=""
down_notified=0

# NIGHTSHIFT_WATCH_SLEEP overrides the base sleep in seconds — the test suite's speed lever.
BASE_SLEEP="${NIGHTSHIFT_WATCH_SLEEP:-$((INTERVAL_MIN * 60))}"

# The wait before the next wake, in minutes: the configured interval, doubled by every ladder
# that failed on a limit, never past an hour — and never shorter than the interval the owner
# configured, whatever that is.
WAIT_MIN="$INTERVAL_MIN"
WAIT_CAP=60
[ "$WAIT_CAP" -ge "$INTERVAL_MIN" ] || WAIT_CAP="$INTERVAL_MIN"
back_off() {
  WAIT_MIN=$((WAIT_MIN * 2))
  [ "$WAIT_MIN" -le "$WAIT_CAP" ] || WAIT_MIN="$WAIT_CAP"
}
# Seconds before the next wake: the base sleep, scaled by however far the wait has backed off.
wake_wait() {
  case "$BASE_SLEEP" in
    '' | *[!0-9]*) printf '%s' "$BASE_SLEEP"; return ;; # not whole seconds — pass it through
  esac
  printf '%s' "$((BASE_SLEEP * WAIT_MIN / INTERVAL_MIN))"
}

while :; do
  sleep "$(wake_wait)"
  wake=$((wake + 1))

  armed || stand_down_disarmed
  holds_pidfile || stand_down_unclaimed
  if [ -f "$NS/STOP" ]; then note owner-stop; log_line "watchman: stop-work order — standing down"; exit 0; fi
  if [ -f "$NS/.ended" ] && [ ! -L "$NS/.ended" ]; then note completed; exit 0; fi
  if [ ! -f "$PUNCH" ]; then note stand-down "punch list missing"; exit 0; fi
  # This watchman revives Claude sessions. A record naming another host belongs to that host's
  # watchman: resuming it here would spawn claude against a shift another agent is working.
  host="$(ns_session_host "$NS")"
  if [ "$host" != claude ]; then
    note wrong-host "$host"
    log_line "watchman: shift is owned by $host — standing down"
    exit 0
  fi
  if [ "$(open_boxes)" -eq 0 ]; then
    log_line "watchman: every box ticked but the shift never clocked out — spawning the clock-out (attempt 1/1)"
    spawn "$(resolve_agent)" "$(rung_prompt 1 2)" || true
    ns_watchman_clockout_pending "$NS" "$SENTINEL"
    clock_rc=$?
    if [ "$clock_rc" -eq 0 ]; then
      note completed
      exit 0
    fi
    note clock-out-failed
    log_line "watchman: clock-out attempt 1/1 returned without releasing the shift — standing down"
    exit 0
  fi
  if deadline_passed; then
    log_line "watchman: quitting time passed with the site dead — spawning the clock-out (attempt 1/1)"
    spawn "$(resolve_agent)" "$(rung_prompt 1 2)" || true
    ns_watchman_clockout_pending "$NS" "$SENTINEL"
    clock_rc=$?
    if [ "$clock_rc" -eq 0 ]; then
      note deadline
      exit 0
    fi
    note clock-out-failed
    log_line "watchman: clock-out attempt 1/1 returned without releasing the shift — standing down"
    exit 0
  fi
  if [ -f "$NS/.session-end" ] && [ ! -L "$NS/.session-end" ]; then
    note clean-session-end
    log_line "watchman: clean session end — the owner closed it; standing down (start re-arms)"
    exit 0
  fi

  # The liveness ladder, session-first (site_verdict). Revival needs strong positive evidence
  # of death — the one truly harmful failure is a second agent beside a living one, so every
  # uncertain reading stands by. Esc is read before everything else: if the owner resumes and a
  # 500 kills it later, the next wake finds an errored tail, not an interrupt, and revives.
  verdict="$(site_verdict)"
  case "$verdict" in
      alive)
        standby_prev=""
        down_notified=0
        WAIT_MIN="$INTERVAL_MIN" # the site answered; knock at the configured cadence again
        ;;
      esc)
        note esc-standby
        [ "$standby_prev" = "esc" ] || log_line "watchman: owner pressed Esc — standing by, not resuming (STOP ends the shift; resuming re-arms)"
        standby_prev="esc"
        down_notified=0
        ;;
      silent)
        note silent-standby
        [ "$standby_prev" = "silent" ] || log_line "watchman: the shift session is alive with a quiet transcript — long silent work; standing by"
        standby_prev="silent"
        down_notified=0
        ;;
      tabs)
        note silent-standby "live claude in project"
        [ "$standby_prev" = "tabs" ] || log_line "watchman: a claude session is live in this project — standing by"
        standby_prev="tabs"
        down_notified=0
        ;;
      unavailable)
        note process-evidence-unavailable
        [ "$standby_prev" = "unavailable" ] || log_line "watchman: process evidence unavailable — standing down, not reviving"
        standby_prev="unavailable"
        down_notified=0
        ;;
      wedge | dead)
        standby_prev=""
        sid="$(shift_session_id)"
        [ "$verdict" != "wedge" ] || log_line "watchman: probable wedge — a session sits at an errored prompt with nobody there; reviving its conversation"
        attempt=0
        revived=1
        aborted=""
        # shellcheck disable=SC2086  # RETRY_SPACING is a space-separated list; splitting is the point
        set -- $RETRY_SPACING ""
        total=$#
        for spacing in "$@"; do
          attempt=$((attempt + 1))
          # Disarming mid-ladder ends it here: the fresh-session rung, which starts a worker on
          # nothing but the punch list, must never fire at a site the owner just stood down.
          armed || stand_down_disarmed
          if [ "$attempt" -gt 1 ]; then
            # Re-check the whole ladder: a site that came back to life mid-wake — or an owner
            # who acted — cancels the remaining attempts.
            aborted="$(hold_reason)"
            if [ -n "$aborted" ]; then
              log_line "watchman: $aborted during retries — holding the remaining attempts"
              break
            fi
          fi
          log_line "watchman: site quiet ${INTERVAL_MIN}m+ with open boxes — resume attempt $attempt ($(rung_label "$attempt" "$total"))"
          if spawn "$(rung_agent "$attempt" "$total")" "$(rung_prompt "$attempt" "$total")"; then
            revived=0
            break
          fi
          # Re-baseline: the failed attempt may have appended its own error to the transcript.
          # Only what moves AFTER this line is site life.
          : >"$SENTINEL"
          [ -n "$spacing" ] || break
          sleep "$spacing"
        done
        # A ladder that revived nothing hands ownership back before the wake ends, so the
        # recorded conversation is never left waiting on a generation no process holds.
        if [ "$revived" -ne 0 ] && [ "$attempt" -gt 0 ]; then
          restore_recorded_lease || true
        fi
        # A successful revival is morning news, not a page: it lands in the parking lot — the
        # file the owner reads — with the thread's handles. The page is reserved for the one
        # night event that needs the owner: a dead session no attempt could bring back, rung
        # once per outage, not once per wake.
        if [ "$revived" -eq 0 ]; then
          down_notified=0
          WAIT_MIN="$INTERVAL_MIN"
          if [ "$AGENT_IS_DEFAULT" -eq 1 ] && [ "$attempt" -ge "$total" ] && [ "$total" -gt 1 ]; then
            note fresh-fallback
          elif [ -z "$sid" ]; then
            note fresh-fallback
          else
            note revived
          fi
          if [ -n "$sid" ]; then
            log_line "watchman: resumed session returned — the night is one thread: claude --resume $sid · vscode://anthropic.claude-code/open?session=$sid"
            printf -- '- [notice] %s — the shift session died and the watchman revived it. One thread: claude --resume %s · cursor://anthropic.claude-code/open?session=%s · vscode://anthropic.claude-code/open?session=%s\n' \
              "$(ts)" "$sid" "$sid" "$sid" >>"$NS/parking-lot.md"
          else
            log_line "watchman: resumed session returned — re-checking next wake"
            printf -- '- [notice] %s — the shift session died and the watchman revived it (details in shift-log.md).\n' "$(ts)" >>"$NS/parking-lot.md"
          fi
        elif [ -z "$aborted" ]; then
          note exhausted-retry
          if api_limited_tail; then
            back_off
            log_line "watchman: all $attempt attempts failed (api down?) — backing off, knocking again in ${WAIT_MIN}m"
          else
            log_line "watchman: all $attempt attempts failed (api down?) — knocking again in ${WAIT_MIN}m"
          fi
          if [ -n "$NOTIFY" ] && [ "$down_notified" -eq 0 ]; then
            down_notified=1
            summary="nightshift: the shift session is down and revival failed — it needs you${sid:+: claude --resume $sid}"
            NIGHTSHIFT_SUMMARY="$summary" sh -c "$NOTIFY" nightshift "$summary" >/dev/null 2>&1 || true
          fi
        fi
        ;;
  esac

  : >"$SENTINEL" # after all actions, so the watchman's own writes never read as site life
  if [ "$MAX_WAKES" -gt 0 ] && [ "$wake" -ge "$MAX_WAKES" ]; then exit 7; fi
done
