#!/usr/bin/env bash
# What the three watchmen share. Each watchman sets the variables these functions read.

need_value() { [ "$2" -ge 2 ] || { printf 'watchman: %s needs a value\n' "$1" >&2; usage; }; }

note() { ns_record_reason "$NS" "$1" "${2:-}"; }

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

# The pidfile is this loop's claim on the site, and a claim can change hands: Reset and Purge
# remove it, a takeover replaces the pid inside it. Removing it on the way out is only right while
# it still names this process — otherwise a watchman that has already been replaced would delete
# the new one's claim as it exits, and the site would be left watched by a loop nothing records.
holds_pidfile() {
  [ -f "$PIDFILE" ] || return 1
  [ ! -L "$PIDFILE" ] || return 1
  [ "$(sed -n 1p "$PIDFILE" 2>/dev/null)" = "$$" ]
}

# Counted below the `## Items` heading only, exactly as the gate counts them — a watchman that
# read a checkbox out of the contract prose would keep reviving a shift the gate considers done.
open_boxes() { ns_open_boxes "$PUNCH"; }

sid()        { [ -L "$SESSION_FILE" ] && return; sed -n 1p "$SESSION_FILE" 2>/dev/null; }
rec_pid()    { [ -L "$SESSION_FILE" ] && return; sed -n 3p "$SESSION_FILE" 2>/dev/null | tr -d '[:space:]'; }
rec_start()  { [ -L "$SESSION_FILE" ] && return; sed -n 4p "$SESSION_FILE" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

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
